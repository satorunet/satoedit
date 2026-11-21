using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Renci.SshNet;

namespace SatoEdit {
  /// サーバのファイルのやりとり (SFTP / FTP / FTPS)。core/remote.js と同じ決まり。
  /// SFTP で初めてつなぐサーバの鍵は自動で登録し、あとで変わったときは接続を止める (なりすまし対策)
  partial class Bridge {
    interface IRemote {
      string Home();
      List<object> List(string dir);
      byte[] Read(string file);
      void Write(string file, byte[] data);
      void Mkdir(string dir);
      void Remove(string file, bool isDir);
      void Rename(string from, string to);
      void Close();
    }

    const long MaxRemoteFile = 50L * 1024 * 1024;
    const int RemoteTimeout = 20000;
    static readonly string[,] Kinds = { { "sftp", "22" }, { "ftp", "21" }, { "ftps", "21" } };
    static string KindId(string k) => k == "ftp" || k == "ftps" ? k : "sftp";
    static int KindPort(string k) => KindId(k) == "sftp" ? 22 : 21;

    static List<object> SortEntries(List<JObj> list) =>
      list.Where(e => e.Str("name") != "." && e.Str("name") != "..")
        .OrderBy(e => e.Bool("dir") ? 0 : 1).ThenBy(e => e.Str("name"), JaOrder).Cast<object>().ToList();

    static string Fingerprint(byte[] key) => "SHA256:" + Convert.ToBase64String(Primitives.Sha256(key)).TrimEnd('=');

    /// 覚えているサーバの鍵 (known-hosts.json) と比べる。初めてなら登録する
    static bool CheckHostKey(JObj server, byte[] key) {
      var known = Store.ReadJSON(Store.KnownHostsFile, null) as JObj ?? new JObj();
      var id = server.Str("host") + ":" + Json.Number(server.Num("port"));
      var fp = Fingerprint(key);
      if (!known.Has(id)) {
        known[id] = fp;
        Directory.CreateDirectory(Store.ConfigDir);
        File.WriteAllText(Store.KnownHostsFile, Json.Pretty(known), new UTF8Encoding(false));
        return true;
      }
      return known.Str(id) == fp;
    }

    static void ForgetHostKey(JObj server) {
      if (!(Store.ReadJSON(Store.KnownHostsFile, null) is JObj known)) return;
      known.Remove(server.Str("host") + ":" + Json.Number(server.Num("port")));
      File.WriteAllText(Store.KnownHostsFile, Json.Pretty(known), new UTF8Encoding(false));
    }

    static UserError LoginError() => new UserError("ログインできませんでした。ユーザー名とパスワード (または鍵) を確かめてください。");

    // ---------- SFTP ----------

    class Sftp : IRemote {
      readonly JObj server; readonly string secret;
      SftpClient client;
      public Sftp(JObj server, string secret) { this.server = server; this.secret = secret; }

      SftpClient C() {
        if (client != null && client.IsConnected) return client;
        var user = server.Str("user");
        AuthenticationMethod auth;
        if (server.Str("auth") == "key") {
          PrivateKeyFile key;
          try {
            using (var fs = File.OpenRead(server.Str("keyFile"))) key = string.IsNullOrEmpty(secret) ? new PrivateKeyFile(fs) : new PrivateKeyFile(fs, secret);
          } catch (Exception e) when (e is IOException || e is UnauthorizedAccessException || e is ArgumentException) {
            throw new UserError("鍵ファイルを読めません: {file}", new JObj { { "file", server.Str("keyFile") } });
          }
          auth = new PrivateKeyAuthenticationMethod(user, key);
        } else {
          // パスワードを「キーボード入力」として聞いてくるサーバにも答える
          var kb = new KeyboardInteractiveAuthenticationMethod(user);
          kb.AuthenticationPrompt += (s, e) => { foreach (var p in e.Prompts) p.Response = secret ?? ""; };
          auth = new PasswordAuthenticationMethod(user, secret ?? "");
          var info0 = new ConnectionInfo(server.Str("host"), (int)server.Num("port", 22), user, auth, kb) { Timeout = TimeSpan.FromMilliseconds(RemoteTimeout) };
          return Connect(info0);
        }
        var info = new ConnectionInfo(server.Str("host"), (int)server.Num("port", 22), user, auth) { Timeout = TimeSpan.FromMilliseconds(RemoteTimeout) };
        return Connect(info);
      }

      SftpClient Connect(ConnectionInfo info) {
        var c = new SftpClient(info) { KeepAliveInterval = TimeSpan.FromSeconds(15), OperationTimeout = TimeSpan.FromMilliseconds(60000) };
        bool keyChanged = false;
        c.HostKeyReceived += (s, e) => {
          var ok = CheckHostKey(server, e.HostKey);
          if (!ok) keyChanged = true;
          e.CanTrust = ok;
        };
        try {
          c.Connect();
        } catch (Exception e) {
          c.Dispose();
          if (keyChanged) throw new UserError("サーバの鍵が前と違います。なりすましのおそれがあるので接続をやめました。サーバを作り直したのなら、サーバの設定で「覚えている鍵を忘れる」を押してください。");
          if (e is Renci.SshNet.Common.SshAuthenticationException) throw LoginError();
          if (e is UserError) throw;
          throw UserError.With("接続できませんでした: ", e.InnerException?.Message ?? e.Message);
        }
        client = c;
        return c;
      }

      public string Home() => C().WorkingDirectory;
      public List<object> List(string dir) {
        var c = C();
        var outl = new List<JObj>();
        foreach (var it in c.ListDirectory(dir)) {
          bool isDir = it.IsDirectory;
          // リンクは、指している先がフォルダかどうかを見る
          if (it.IsSymbolicLink) { try { isDir = c.GetAttributes(it.FullName).IsDirectory; } catch { isDir = false; } }
          outl.Add(new JObj { { "name", it.Name }, { "dir", isDir }, { "size", (double)it.Length }, { "mtime", Math.Floor((it.LastWriteTimeUtc - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds) * 1000 } });
        }
        return SortEntries(outl);
      }
      public byte[] Read(string file) {
        var c = C();
        if (c.GetAttributes(file).Size > MaxRemoteFile) throw new UserError("大きすぎるファイルです (50 MB まで)。");
        return c.ReadAllBytes(file);
      }
      public void Write(string file, byte[] data) {
        // 権限 (実行できる・できない など) は、もとのファイルのまま残す (上書きは中身だけを入れ替える)
        using (var ms = new MemoryStream(data)) C().UploadFile(ms, file, true);
      }
      public void Mkdir(string dir) => C().CreateDirectory(dir);
      public void Remove(string file, bool isDir) { if (isDir) C().DeleteDirectory(file); else C().DeleteFile(file); }
      public void Rename(string from, string to) => C().RenameFile(from, to);
      public void Close() { try { client?.Dispose(); } catch { } client = null; }
    }

    // ---------- FTP / FTPS (Windows に入っている FtpWebRequest を使う) ----------

    class Ftp : IRemote {
      readonly JObj server; readonly string secret;
      readonly object gate = new object(); // 1 つずつ順番に行う
      readonly string group = "satoruEditor-" + Guid.NewGuid().ToString("N");
      public Ftp(JObj server, string secret) { this.server = server; this.secret = secret; }

      Uri UriOf(string path) {
        var segs = (path ?? "").Split('/').Where(x => x != "").Select(Uri.EscapeDataString);
        var abs = (path ?? "").StartsWith("/") ? "%2F" : "";
        return new Uri($"ftp://{server.Str("host")}:{(int)server.Num("port", 21)}/{abs}{string.Join("/", segs)}");
      }

      FtpWebRequest Req(string path, string method) {
        var r = (FtpWebRequest)WebRequest.Create(UriOf(path));
        r.Method = method;
        r.Credentials = new NetworkCredential(server.Str("user") == "" ? "anonymous" : server.Str("user"), secret ?? "");
        r.EnableSsl = server.Str("kind") == "ftps";
        r.UsePassive = true;
        r.UseBinary = true;
        r.KeepAlive = true;
        r.ConnectionGroupName = group;
        r.Timeout = RemoteTimeout;
        r.ReadWriteTimeout = 60000;
        r.Proxy = null;
        return r;
      }

      T Do<T>(Func<T> fn) {
        lock (gate) {
          try { return fn(); } catch (WebException e) {
            if (e.Response is FtpWebResponse fr && (fr.StatusCode == FtpStatusCode.NotLoggedIn || (int)fr.StatusCode == 430)) throw LoginError();
            if (e.Response is FtpWebResponse fr2 && !string.IsNullOrWhiteSpace(fr2.StatusDescription)) throw new UserError(fr2.StatusDescription.Trim());
            throw UserError.With("接続できませんでした: ", e.Message);
          } catch (Exception e) when (!(e is UserError)) {
            Log.Error("ftp", e);
            throw UserError.With("接続できませんでした: ", e.Message);
          }
        }
      }

      public string Home() => Do(() => {
        using (var res = (FtpWebResponse)Req("", WebRequestMethods.Ftp.PrintWorkingDirectory).GetResponse()) {
          var m = Regex.Match(res.StatusDescription ?? "", "\"(.*)\"");
          return m.Success ? m.Groups[1].Value.Replace("\"\"", "\"") : "/";
        }
      });

      public List<object> List(string dir) => Do(() => {
        var lines = new List<string>();
        using (var res = (FtpWebResponse)Req(dir.EndsWith("/") ? dir : dir + "/", WebRequestMethods.Ftp.ListDirectoryDetails).GetResponse())
        using (var sr = new StreamReader(res.GetResponseStream(), Encoding.UTF8)) {
          string l;
          while ((l = sr.ReadLine()) != null) if (l.Trim() != "") lines.Add(l);
        }
        return SortEntries(lines.Select(ParseListLine).Where(x => x != null).ToList());
      });

      static readonly Regex Unix = new Regex(@"^([\-dlbcps])[rwxsStT\-]{9}[+@.]?\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\w{3}\s+\d{1,2}\s+(?:\d{1,2}:\d{2}|\d{4}))\s+(.+)$");
      static readonly Regex Dos = new Regex(@"^(\d{2}-\d{2}-\d{2,4})\s+(\d{1,2}:\d{2}(?:AM|PM)?)\s+(<DIR>|\d+)\s+(.+)$", RegexOptions.IgnoreCase);

      /// LIST の 1 行 (Unix 形式・Windows の IIS 形式) を読む
      static JObj ParseListLine(string line) {
        var m = Unix.Match(line);
        if (m.Success) {
          var name = m.Groups[4].Value;
          bool link = m.Groups[1].Value == "l";
          if (link) { int i = name.IndexOf(" -> ", StringComparison.Ordinal); if (i >= 0) name = name.Substring(0, i); }
          double.TryParse(m.Groups[2].Value, out var size);
          return new JObj { { "name", name }, { "dir", m.Groups[1].Value == "d" || (link && size == 0) }, { "size", size }, { "mtime", UnixDate(m.Groups[3].Value) } };
        }
        m = Dos.Match(line);
        if (m.Success) {
          bool dir = m.Groups[3].Value.ToUpperInvariant() == "<DIR>";
          double.TryParse(dir ? "0" : m.Groups[3].Value, out var size);
          double mt = 0;
          if (DateTime.TryParse(m.Groups[1].Value + " " + m.Groups[2].Value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out var d)) mt = (d.ToUniversalTime() - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;
          return new JObj { { "name", m.Groups[4].Value }, { "dir", dir }, { "size", size }, { "mtime", mt } };
        }
        return null;
      }

      static double UnixDate(string s) {
        var parts = Regex.Split(s.Trim(), @"\s+");
        try {
          int month = Array.IndexOf(new[] { "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" }, parts[0].ToLowerInvariant()) + 1;
          int day = int.Parse(parts[1]);
          DateTime d;
          if (parts[2].Contains(":")) {
            var hm = parts[2].Split(':');
            var now = DateTime.UtcNow;
            d = new DateTime(now.Year, month, day, int.Parse(hm[0]), int.Parse(hm[1]), 0, DateTimeKind.Utc);
            if (d > now.AddDays(1)) d = d.AddYears(-1);
          } else {
            d = new DateTime(int.Parse(parts[2]), month, day, 0, 0, 0, DateTimeKind.Utc);
          }
          return (d - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;
        } catch { return 0; }
      }

      public byte[] Read(string file) => Do(() => {
        using (var res = (FtpWebResponse)Req(file, WebRequestMethods.Ftp.DownloadFile).GetResponse())
        using (var s = res.GetResponseStream()) {
          var ms = new MemoryStream();
          var buf = new byte[65536];
          int n;
          while ((n = s.Read(buf, 0, buf.Length)) > 0) {
            ms.Write(buf, 0, n);
            if (ms.Length > MaxRemoteFile) throw new UserError("大きすぎるファイルです (50 MB まで)。");
          }
          return ms.ToArray();
        }
      });

      public void Write(string file, byte[] data) => Do(() => {
        var r = Req(file, WebRequestMethods.Ftp.UploadFile);
        r.ContentLength = data.Length;
        using (var s = r.GetRequestStream()) s.Write(data, 0, data.Length);
        using (r.GetResponse()) { }
        return true;
      });

      void Simple(string path, string method, Action<FtpWebRequest> setup = null) => Do(() => {
        var r = Req(path, method);
        setup?.Invoke(r);
        using (r.GetResponse()) { }
        return true;
      });

      public void Mkdir(string dir) => Simple(dir, WebRequestMethods.Ftp.MakeDirectory);
      public void Remove(string file, bool isDir) => Simple(file, isDir ? WebRequestMethods.Ftp.RemoveDirectory : WebRequestMethods.Ftp.DeleteFile);
      public void Rename(string from, string to) => Simple(from, WebRequestMethods.Ftp.Rename, r => r.RenameTo = to);
      public void Close() { try { ServicePointManager.FindServicePoint(UriOf("/")).CloseConnectionGroup(group); } catch { } }
    }

    // ---------- つなぎ方 (しばらく使い回す。2 分使わなければ切る) ----------

    class Conn { public IRemote Client; public Timer Timer; public readonly object Gate = new object(); }
    readonly ConcurrentDictionary<string, Conn> connections = new ConcurrentDictionary<string, Conn>();

    static JObj FindServer(string id) => (Store.Prefs.Arr("servers") ?? new List<object>()).OfType<JObj>().FirstOrDefault(x => x.Str("id") == id);

    Conn Connection(string id) {
      var s = FindServer(id);
      if (s == null) throw new UserError("サーバの設定が見つかりません。");
      var entry = connections.GetOrAdd(id, _ => {
        var secret = Store.GetSecret("server." + id) ?? "";
        return new Conn { Client = s.Str("kind") == "sftp" ? new Sftp(s, secret) : (IRemote)new Ftp(s, secret) };
      });
      entry.Timer?.Dispose();
      entry.Timer = new Timer(_ => DropConnection(id), null, 120000, Timeout.Infinite);
      return entry;
    }

    void DropConnection(string id) {
      if (!connections.TryRemove(id, out var entry)) return;
      entry.Timer?.Dispose();
      try { entry.Client.Close(); } catch { } // もう切れている
    }

    /// 接続を使う (同じ接続では 1 つずつ)。失敗したら切る (切れた接続を使い回さない)
    T WithRemote<T>(string id, Func<IRemote, T> fn) {
      var c = Connection(id);
      try {
        lock (c.Gate) return fn(c.Client);
      } catch {
        DropConnection(id);
        throw;
      }
    }

    static string RemoteURL(JObj s, string file) {
      var kind = KindId(s.Str("kind"));
      var port = s.Num("port") > 0 && (int)s.Num("port") != KindPort(kind) ? ":" + Json.Number(s.Num("port")) : "";
      var user = s.Str("user") != "" ? s.Str("user") + "@" : "";
      return $"{kind}://{user}{s.Str("host")}{port}{file}";
    }

    static JObj RemoteFail(Exception e) {
      while (e is AggregateException ag && ag.InnerException != null) e = ag.InnerException;
      if (!(e is UserError) && !(e is Codec.CodecError) && !(e is FileCrypto.CryptoError)) e = new UserError(e.Message);
      return Fail(e);
    }

    void RegisterServers() {
      OnBg("serverSave", a => {
        try {
          var server = O(a, 0);
          var kind = KindId(server.Str("kind"));
          var portText = server["port"] is double d ? Json.Number(d) : server.Str("port");
          var port = int.TryParse(Regex.Match(portText ?? "", @"^\s*\d+").Value.Trim(), out var p) && p > 0 ? p : KindPort(kind);
          var s = new JObj {
            { "id", server.Str("id") != "" ? server.Str("id") : Hex(Primitives.Random(8)) }, { "name", server.Str("name").Trim() },
            { "kind", kind }, { "host", server.Str("host").Trim() }, { "port", (double)port },
            { "user", server.Str("user").Trim() }, { "auth", server.Str("auth") == "key" ? "key" : "password" }, { "keyFile", server.Str("keyFile") }, { "root", server.Str("root").Trim() },
          };
          if (s.Str("host") == "") throw new UserError("サーバのアドレスを入れてください。");
          if (Arg(a, 1) is string pw) Store.SetSecret("server." + s.Str("id"), pw); // 渡されなければ前のまま
          var list = (Store.Prefs.Arr("servers") ?? new List<object>()).OfType<JObj>().Where(x => x.Str("id") != s.Str("id")).Cast<object>().ToList();
          list.Add(s);
          Store.Prefs["servers"] = list;
          Store.SavePrefsSoon();
          DropConnection(s.Str("id"));
          return new JObj { { "status", "ok" }, { "server", s } };
        } catch (Exception e) { return Fail(e); }
      });
      OnBg("serverDelete", a => {
        var id = S(a, 0);
        Store.Prefs["servers"] = (Store.Prefs.Arr("servers") ?? new List<object>()).OfType<JObj>().Where(x => x.Str("id") != id).Cast<object>().ToList();
        Store.SavePrefsSoon();
        try { Store.SetSecret("server." + id, null); } catch { } // 残っても使われない
        DropConnection(id);
        return true;
      });
      OnBg("serverForgetKey", a => {
        var s = FindServer(S(a, 0));
        if (s != null) ForgetHostKey(s);
        DropConnection(S(a, 0));
        return true;
      });
      OnBg("serverHasPassword", a => !string.IsNullOrEmpty(Store.GetSecret("server." + S(a, 0))));
      OnBg("remoteCall", a => {
        var id = S(a, 0);
        try {
          switch (S(a, 1)) {
            case "home": return new JObj { { "status", "ok" }, { "value", WithRemote(id, c => c.Home()) } };
            case "list": return new JObj { { "status", "ok" }, { "value", WithRemote(id, c => c.List(S(a, 2))) } };
            case "mkdir": WithRemote(id, c => { c.Mkdir(S(a, 2)); return true; }); return new JObj { { "status", "ok" } };
            case "remove": WithRemote(id, c => { c.Remove(S(a, 2), B(a, 3)); return true; }); return new JObj { { "status", "ok" } };
            case "rename": WithRemote(id, c => { c.Rename(S(a, 2), S(a, 3)); return true; }); return new JObj { { "status", "ok" } };
            case "create": WithRemote(id, c => { c.Write(S(a, 2), new byte[0]); return true; }); return new JObj { { "status", "ok" } };
            default: throw new UserError("unknown action");
          }
        } catch (Exception e) { DropConnection(id); return RemoteFail(e); }
      });
      OnBg("remoteRead", a => {
        var id = S(a, 0);
        var file = S(a, 1);
        try {
          var s = FindServer(id);
          var buf = WithRemote(id, c => c.Read(file));
          var r = DecodeDocument(buf, O(a, 2), file);
          var remote = new JObj { { "id", id }, { "path", file }, { "url", RemoteURL(s, file) } };
          if (r.Str("status") == "viewer") { r["remote"] = remote; return r; }
          if (r.Str("status") != "ok") return r;
          r["size"] = (double)buf.Length;
          r["remote"] = remote;
          return r;
        } catch (Exception e) { DropConnection(id); return RemoteFail(e); }
      });
      OnBg("remoteWrite", a => {
        var id = S(a, 0);
        try {
          var body = EncodeDocument(O(a, 2));
          WithRemote(id, c => { c.Write(S(a, 1), body); return true; });
          return new JObj { { "status", "ok" }, { "size", (double)body.Length } };
        } catch (Exception e) { DropConnection(id); return RemoteFail(e); }
      });
    }
  }
}
