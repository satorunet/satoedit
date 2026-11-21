using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading;
using SatoEdit;
// 本体の部品が増えたときのテストはここに足す
static class Extra {
  static void Ok(bool c, string what) { if (!c) throw new Exception("失敗: " + what); }
  public static readonly List<KeyValuePair<string, Action>> All = new List<KeyValuePair<string, Action>> {
    new KeyValuePair<string, Action>("共同編集の通信: 正しいコードならやりとりでき、違うコードはすぐ切れる", () => {
      var got = new List<string>();
      var closes = new List<string>();
      var code = CollabCipher.NewCode();
      var host = CollabNet.Host(0, code, new CollabNet.Events { OnOpen = (i, a) => { }, OnMessage = (i, m) => { lock (got) got.Add("H" + i + Json.Stringify(m)); }, OnClose = (i, info) => { lock (closes) closes.Add("H" + i + Json.Stringify(info)); } });
      var guest = CollabNet.Join("127.0.0.1", host.Port, code, new CollabNet.Events { OnOpen = (i, a) => { }, OnMessage = (i, m) => { lock (got) got.Add("G" + Json.Stringify(m)); }, OnClose = (i, info) => { } });
      Thread.Sleep(400);
      guest.Send(0, new JObj { { "t", "hello" } });
      Thread.Sleep(300);
      host.Send(1, new JObj { { "t", "welcome" }, { "text", "やあ😀" } });
      Thread.Sleep(300);
      var bad = CollabNet.Join("127.0.0.1", host.Port, "OTHERCODE", new CollabNet.Events { OnOpen = (i, a) => { }, OnMessage = (i, m) => { }, OnClose = (i, info) => { } });
      Thread.Sleep(300);
      bad.Send(0, new JObj { { "t", "hello" } });
      Thread.Sleep(500);
      guest.Stop(); host.Stop();
      lock (got) Ok(got.Contains("H1{\"t\":\"hello\"}") && got.Contains("G{\"t\":\"welcome\",\"text\":\"やあ😀\"}"), string.Join(",", got));
      lock (closes) Ok(closes.Any(c => c.StartsWith("H2") && c.Contains("\"decryptFailed\":true")), string.Join(",", closes));
    }),
    new KeyValuePair<string, Action>("バイナリの見分け (shared/binary.js と同じ)", () => {
      Ok(!Binary.LooksBinary(Encoding.UTF8.GetBytes("普通の文章\n")), "文章");
      Ok(Binary.LooksBinary(new byte[] { 0x89, 0x50, 0, 1, 2, 3 }), "NUL");
      Ok(!Binary.LooksBinary(new byte[] { 0xFF, 0xFE, 0x41, 0 }), "UTF-16 BOM");
      Ok(!Binary.LooksBinary(Encoding.Unicode.GetBytes("abcdefgh")), "UTF-16 LE");
      Ok(Binary.LooksBinary(new byte[] { 1, 2, 3, 4, 5, 6, 7, 0x41 }), "制御文字");
      Ok(Binary.ImageType("a.PNG") == "image/png" && Binary.ImageType("a.svg") == null, "画像");
    }),
  };
}
