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
    new KeyValuePair<string, Action>("巨大ファイルの一部分: 行の切れ目にそろえて読み、その範囲だけを差し替えて書く", () => {
      var dir = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "satoedit-partial-" + Guid.NewGuid().ToString("N"));
      System.IO.Directory.CreateDirectory(dir);
      try {
        var f = System.IO.Path.Combine(dir, "big.txt");
        var sb = new StringBuilder();
        for (int i = 0; i < 1000; i++) sb.Append("行").Append(i.ToString("D4")).Append('\n');
        var all = Encoding.UTF8.GetBytes(sb.ToString());
        System.IO.File.WriteAllBytes(f, all);
        int lineBytes = Encoding.UTF8.GetByteCount("行0000\n");
        // 行の途中から頼んでも、次の行頭から・行の終わりまでにそろう
        var p = PartialFile.Align(f, lineBytes * 10 + 2, lineBytes * 5);
        Ok(p.Offset == lineBytes * 11 && p.End % lineBytes == 0 && p.FileSize == all.Length, $"align {p.Offset} {p.Length}");
        var text = Encoding.UTF8.GetString(PartialFile.Read(f, p));
        Ok(text.StartsWith("行0011\n") && text.EndsWith("\n"), text);
        Ok(PartialFile.LinesBefore(PartialFile.Read(f, p), lineBytes * 3) == 3, "LinesBefore");
        Ok(PartialFile.LineStart(PartialFile.Read(f, p), 2) == lineBytes * 2, "LineStart");
        // 差し替え: 前後はそのまま
        var repl = Encoding.UTF8.GetBytes("★\n" + text);
        var tmp = f + ".new";
        PartialFile.Write(f, p, repl, tmp);
        var outText = Encoding.UTF8.GetString(System.IO.File.ReadAllBytes(tmp));
        Ok(outText == sb.ToString().Insert(sb.ToString().IndexOf("行0011"), "★\n"), "write");
        // 先頭・末尾
        var head = PartialFile.Align(f, 0, 1);
        Ok(head.Offset == 0 && head.Length == lineBytes, "head");
        var tail = PartialFile.Align(f, all.Length - 3, 100);
        Ok(tail.Offset == all.Length && tail.Length == 0, $"tail {tail.Offset} {tail.Length}");
      } finally { try { System.IO.Directory.Delete(dir, true); } catch { } }
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
