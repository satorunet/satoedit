using System;
using System.Linq;
using System.Net.Sockets;

namespace SatoEdit {
  /// 共同編集: 通信だけをここで行い、メッセージは画面側に渡す (main.js と同じ)
  partial class Bridge {
    CollabNet.ILink collabLink;

    CollabNet.Events CollabEvents() => new CollabNet.Events {
      OnOpen = (id, address) => Send("collab:open", (double)id, address),
      OnMessage = (id, msg) => Send("collab:message", (double)id, msg),
      OnClose = (id, info) => Send("collab:close", (double)id, info),
    };

    void CollabStop() {
      try { collabLink?.Stop(); } catch { }
      collabLink = null;
    }

    void RegisterCollab() {
      On("collabHost", a => {
        CollabStop();
        var code = CollabCipher.NewCode();
        var port = (int)N(a, 0, 0);
        if (port <= 0) port = CollabNet.DefaultPort;
        try {
          collabLink = CollabNet.Host(port, code, CollabEvents());
        } catch (SocketException e) when (e.SocketErrorCode == SocketError.AddressAlreadyInUse) {
          var k = "ポート {port} はほかで使われています。別の番号にしてください。";
          var p = new JObj { { "port", S(a, 0, port.ToString()) } };
          return new JObj { { "status", "error" }, { "message", k.Replace("{port}", S(a, 0, port.ToString())) }, { "key", k }, { "params", p } };
        } catch (Exception e) {
          return new JObj { { "status", "error" }, { "message", e.Message } };
        }
        return new JObj { { "status", "ok" }, { "code", code }, { "port", (double)collabLink.Port }, { "addresses", CollabNet.LocalAddresses().Cast<object>().ToList() }, { "hostName", Environment.MachineName } };
      });
      On("collabJoin", a => {
        CollabStop();
        var port = (int)N(a, 1, CollabNet.DefaultPort);
        if (port <= 0) port = CollabNet.DefaultPort;
        collabLink = CollabNet.Join(S(a, 0).Trim(), port, S(a, 2), CollabEvents());
        return new JObj { { "status", "ok" } };
      });
      On("collabSend", a => { collabLink?.Send((int)N(a, 0), O(a, 1)); return true; });
      On("collabClose", a => { collabLink?.Close((int)N(a, 0)); return true; });
      On("collabStop", a => { CollabStop(); return true; });
    }
  }
}
