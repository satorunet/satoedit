using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace SatoEdit {
  /// 共同編集の TCP の接続 (core/collabnet.js と同じ)。メッセージは JSON を共有コードの鍵で暗号化し、base64 にして 1 行ずつ送る。
  /// ここは通信だけ。だれが参加しているか・文章のすり合わせは画面側 (renderer/src/collab.js) が行う
  public static class CollabNet {
    public const int DefaultPort = 7650;
    const int MaxLine = 64 * 1024 * 1024;

    public class Events {
      public Action<int, string> OnOpen;
      public Action<int, JObj> OnMessage;
      public Action<int, JObj> OnClose; // { decryptedAny, decryptFailed }
    }

    /// 1 本の接続
    public class Peer {
      readonly TcpClient client;
      readonly CollabCipher cipher;
      NetworkStream stream;
      readonly object writeLock = new object();
      bool decryptedAny, decryptFailed;
      int closed;
      public Action<JObj> OnMessage = _ => { };
      public Action<JObj> OnClose = _ => { };
      public bool DecryptedAny => decryptedAny;

      public Peer(TcpClient client, CollabCipher cipher) { this.client = client; this.cipher = cipher; client.NoDelay = true; }

      public string RemoteAddress {
        get {
          try {
            var ep = (IPEndPoint)client.Client.RemoteEndPoint;
            var a = ep.Address.IsIPv4MappedToIPv6 ? ep.Address.MapToIPv4() : ep.Address;
            return a.ToString();
          } catch { return ""; }
        }
      }

      /// 受け取りを始める (裏のスレッドで 1 行ずつ読む)
      public void Start() {
        stream = client.GetStream();
        var t = new Thread(ReadLoop) { IsBackground = true, Name = "collab" };
        t.Start();
      }

      void ReadLoop() {
        var line = new MemoryStream();
        var buf = new byte[65536];
        try {
          while (true) {
            int n = stream.Read(buf, 0, buf.Length);
            if (n <= 0) break;
            int start = 0;
            for (int i = 0; i < n; i++) {
              if (buf[i] != (byte)'\n') continue;
              line.Write(buf, start, i - start);
              start = i + 1;
              var text = Encoding.UTF8.GetString(line.ToArray());
              line.SetLength(0);
              // 鍵が違う・改ざん・順番違いなら、その場で切る
              var plain = cipher.Open(text);
              JObj obj = null;
              if (plain != null) { try { obj = Json.Parse(Encoding.UTF8.GetString(plain)) as JObj; } catch { obj = null; } }
              if (obj == null) { decryptFailed = true; Cancel(); return; }
              decryptedAny = true;
              OnMessage(obj);
            }
            line.Write(buf, start, n - start);
            if (line.Length > MaxLine) { Cancel(); return; }
          }
        } catch { }
        Finish();
      }

      public void Send(JObj message) {
        if (closed != 0 || stream == null) return;
        var data = Encoding.ASCII.GetBytes(cipher.Seal(Encoding.UTF8.GetBytes(Json.Stringify(message))) + "\n");
        try { lock (writeLock) stream.Write(data, 0, data.Length); } catch { Cancel(); }
      }

      public void Cancel() {
        try { client.Close(); } catch { }
        Finish();
      }

      void Finish() {
        if (Interlocked.Exchange(ref closed, 1) != 0) return;
        try { client.Close(); } catch { }
        OnClose(new JObj { { "decryptedAny", decryptedAny }, { "decryptFailed", decryptFailed } });
      }
    }

    public interface ILink {
      int Port { get; }
      void Send(int id, JObj msg);
      void Close(int id);
      void Stop();
    }

    /// この PC のアドレス (IPv4、ループバックとリンクローカルを除く)
    public static List<string> LocalAddresses() {
      var outl = new List<string>();
      try {
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces()) {
          if (ni.OperationalStatus != OperationalStatus.Up || ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
          foreach (var ua in ni.GetIPProperties().UnicastAddresses) {
            var a = ua.Address;
            if (a.AddressFamily != AddressFamily.InterNetwork || IPAddress.IsLoopback(a)) continue;
            var s = a.ToString();
            if (s.StartsWith("169.254.")) continue;
            if (!outl.Contains(s)) outl.Add(s);
          }
        }
      } catch { }
      return outl;
    }

    class HostLink : ILink {
      public TcpListener Listener;
      public readonly ConcurrentDictionary<int, Peer> Peers = new ConcurrentDictionary<int, Peer>();
      public int Port { get; set; }
      public void Send(int id, JObj msg) { if (Peers.TryGetValue(id, out var p)) p.Send(msg); }
      public void Close(int id) { if (Peers.TryGetValue(id, out var p)) p.Cancel(); }
      public void Stop() {
        try { Listener.Stop(); } catch { }
        foreach (var p in Peers.Values.ToList()) p.Cancel();
        Peers.Clear();
      }
    }

    /// 共有を始める (ホスト)。ポートが使われていれば SocketException (AddressAlreadyInUse)
    public static ILink Host(int port, string code, Events events) {
      var link = new HostLink();
      var listener = new TcpListener(IPAddress.IPv6Any, port);
      try { listener.Server.DualMode = true; } catch { listener = new TcpListener(IPAddress.Any, port); }
      listener.Start();
      link.Listener = listener;
      link.Port = ((IPEndPoint)listener.LocalEndpoint).Port;
      int next = 1;
      var t = new Thread(() => {
        while (true) {
          TcpClient c;
          try { c = listener.AcceptTcpClient(); } catch { return; }
          int id = next++;
          var peer = new Peer(c, new CollabCipher(code, true));
          link.Peers[id] = peer;
          peer.OnMessage = obj => events.OnMessage(id, obj);
          peer.OnClose = info => { link.Peers.TryRemove(id, out _); events.OnClose(id, info); };
          events.OnOpen(id, peer.RemoteAddress);
          peer.Start();
        }
      }) { IsBackground = true, Name = "collab-accept" };
      t.Start();
      return link;
    }

    class GuestLink : ILink {
      public Peer Peer;
      public int Port { get; set; }
      public void Send(int id, JObj msg) { Peer?.Send(msg); }
      public void Close(int id) { Peer?.Cancel(); }
      public void Stop() { Peer?.Cancel(); }
    }

    /// 参加する (ゲスト)。つながったら events.OnOpen(0, address)。15 秒たっても 1 通も読めなければ切る
    public static ILink Join(string address, int port, string code, Events events) {
      var link = new GuestLink { Port = port };
      var client = new TcpClient(AddressFamily.InterNetworkV6) { NoDelay = true };
      try { client.Client.DualMode = true; } catch { client = new TcpClient(); }
      var peer = new Peer(client, new CollabCipher(code, false));
      link.Peer = peer;
      peer.OnMessage = obj => events.OnMessage(0, obj);
      peer.OnClose = info => events.OnClose(0, info);
      var t = new Thread(() => {
        try {
          var ar = client.BeginConnect(address, port, null, null);
          if (!ar.AsyncWaitHandle.WaitOne(15000)) { peer.Cancel(); return; }
          client.EndConnect(ar);
        } catch {
          peer.Cancel();
          return;
        }
        events.OnOpen(0, address);
        peer.Start();
        // 鍵が合っていれば、すぐに 1 通目が届く
        ThreadPool.QueueUserWorkItem(_ => { Thread.Sleep(15000); if (!peer.DecryptedAny) peer.Cancel(); });
      }) { IsBackground = true, Name = "collab-join" };
      t.Start();
      return link;
    }
  }
}
