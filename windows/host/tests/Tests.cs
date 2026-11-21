using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using SatoEdit;

// 部品のテスト (test/run.js から、本体の C# に移した部分を写したもの)。Mac 版が作った見本 test/fixtures/mac-* を読めることも確かめる
static class Tests {
  static readonly string Fixtures = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../test/fixtures"));
  static byte[] Fx(string n) => File.ReadAllBytes(Path.Combine(Fixtures, n));
  static readonly byte[] Plain = Encoding.UTF8.GetBytes("こんにちは、Windows 版。\n2 行目 ABC 123\n");
  const string Sample = "日本語テキスト、漢字\nabc 123\n";
  static readonly byte[] Secret = Enumerable.Range(0, 20).Select(i => (byte)(i * 7 + 1)).ToArray();
  static int failed = 0, passed = 0;

  static void Ok(bool cond, string what) { if (!cond) throw new Exception("失敗: " + what); }
  static void Eq<T>(T a, T b, string what = "") { if (!Equals(a, b)) throw new Exception($"失敗: {what} 期待 [{b}] 実際 [{a}]"); }
  static void Throws(Action fn, string what, Func<Exception, bool> check = null) {
    try { fn(); } catch (Exception e) { if (check == null || check(e)) return; throw new Exception("違う例外: " + what + " " + e.Message); }
    throw new Exception("例外が出ない: " + what);
  }
  static bool Same(byte[] a, byte[] b) => a.SequenceEqual(b);

  static void Test(string name, Action fn) {
    try { fn(); passed++; Console.WriteLine("ok   " + name); } catch (Exception e) { failed++; Console.WriteLine("NG   " + name + "\n     " + e.Message); }
  }

  static int Main() {
    Test("JSON: 読み書きが JSON.stringify(v, null, 2) と同じ形", () => {
      var o = (JObj)Json.Parse("{\"a\":1,\"b\":[true,null,\"x\\u3042\\n\"],\"c\":{},\"d\":[],\"e\":1.5,\"f\":-0.25,\"g\":1e-7}");
      Eq(Json.Pretty(o), "{\n  \"a\": 1,\n  \"b\": [\n    true,\n    null,\n    \"xあ\\n\"\n  ],\n  \"c\": {},\n  \"d\": [],\n  \"e\": 1.5,\n  \"f\": -0.25,\n  \"g\": 1e-7\n}");
      Eq(Json.Stringify(o), "{\"a\":1,\"b\":[true,null,\"xあ\\n\"],\"c\":{},\"d\":[],\"e\":1.5,\"f\":-0.25,\"g\":1e-7}");
      Eq(Json.Number(1700000000123), "1700000000123");
      Eq(Json.Number(0.1 + 0.2), "0.30000000000000004");
      Throws(() => Json.Parse("{a:1}"), "壊れた JSON");
    });
    Test("文字コード: Mac 版が書いた 7 種類を自動判定して読める", () => {
      foreach (var e in Codec.Encodings) {
        var d = Codec.Decode(Fx($"mac-{e.Id}.txt"));
        Eq(d.Encoding, e.Id, e.Id);
        Eq(d.Text, Sample, e.Id);
        Eq(d.LineEnding, "crlf", e.Id);
      }
    });
    Test("文字コード: 書いたものが Mac 版の出力とバイト単位で同じ", () => {
      foreach (var e in Codec.Encodings) Ok(Same(Codec.Encode(Sample, e.Id, "crlf"), Fx($"mac-{e.Id}.txt")), e.Id);
    });
    Test("文字コード: 機種依存文字は Shift_JIS で往復でき、書けない文字はエラー", () => {
      var s = "①㈱髙﨑 ｶﾅ\n";
      Eq(Codec.Decode(Codec.Encode(s, "shiftJIS", "lf"), "shiftJIS").Text, s);
      Throws(() => Codec.Encode("絵文字😀", "shiftJIS", "lf"), "絵文字", e => e.Message.Contains("保存できない文字"));
      Throws(() => Codec.Encode("한국어", "eucJP", "lf"), "ハングル", e => e.Message.Contains("保存できない文字"));
      var kana = "ｶﾅ と 漢字\n";
      Eq(Codec.Decode(Codec.Encode(kana, "iso2022JP", "lf")).Text, kana);
    });
    Test("文字コード: 改行の判定と正規化", () => {
      Eq(Codec.DetectLineEnding("a\rb"), "cr");
      Eq(Codec.NormalizeLineEndings("a\r\nb\rc\n"), "a\nb\nc\n");
      Eq(Codec.Decode(Encoding.UTF8.GetBytes("a\rb")).LineEnding, "cr");
      Eq(Encoding.UTF8.GetString(Codec.Encode("a\nb", "utf8", "cr")), "a\rb");
      Eq(Codec.Decode(new byte[0]).Encoding, "utf8");
    });
    Test("文字コード: 壊れたバイトは指定の文字コードでは読めず、自動なら置換して開く", () => {
      var bad = new byte[] { 0x82, 0xA0, 0xFF, 0xFF, 0x80 };
      Throws(() => Codec.Decode(bad, "utf8"), "utf8");
      Ok(Codec.Decode(bad).Text != null, "自動");
    });
    Test("暗号化: Mac 版で暗号化した文書を開ける (パスワード・パスコード・鍵ファイル・二段階)", () => {
      Ok(Same(FileCrypto.OpenWithPassword(Fx("mac-password.enc"), "ひみつのpassword").Plain, Plain), "password");
      Ok(Same(FileCrypto.OpenWithPassword(Fx("mac-passcode.enc"), "123456").Plain, Plain), "passcode");
      var secret = FileCrypto.KeyFileSecret(Fx("mac.satorukey"));
      Ok(secret != null, "鍵ファイル");
      Ok(Same(FileCrypto.OpenWithKeyFile(Fx("mac-keyfile.enc"), secret).Plain, Plain), "keyfile");
      Ok(Same(FileCrypto.OpenTwoStep(Fx("mac-twostep.enc"), "pw-two-step", Secret).Plain, Plain), "twoStep");
      Eq(FileCrypto.ReadHeader(Fx("mac-passcode.enc")).Kind, "passcode");
    });
    Test("暗号化: 違うパスワード・改ざん・違う鍵ファイルは開けない", () => {
      Throws(() => FileCrypto.OpenWithPassword(Fx("mac-password.enc"), "ちがう"), "違うパスワード", e => ((FileCrypto.CryptoError)e).Code == "wrong");
      var key = FileCrypto.DeriveKey("pw", "password", null, 10000);
      var sealedB = FileCrypto.Seal(Plain, key);
      Ok(Same(FileCrypto.Open(sealedB, key), Plain), "往復");
      foreach (var i in new[] { 5, 12, 13, 20, sealedB.Length - 1, sealedB.Length - 20 }) {
        var t = (byte[])sealedB.Clone();
        t[i] ^= 1;
        Throws(() => FileCrypto.Open(t, key), "位置 " + i);
      }
      var other = FileCrypto.KeyFileSecret(FileCrypto.NewKeyFileContents());
      Throws(() => FileCrypto.OpenWithKeyFile(Fx("mac-keyfile.enc"), other), "違う鍵ファイル", e => ((FileCrypto.CryptoError)e).Code == "wrongKeyFile");
      Ok(!FileCrypto.IsEncrypted(Encoding.UTF8.GetBytes("普通の文章")), "普通の文章");
      Throws(() => FileCrypto.ReadHeader(Encoding.UTF8.GetBytes("普通の文章")), "notEncrypted", e => ((FileCrypto.CryptoError)e).Code == "notEncrypted");
      Eq(FileCrypto.KeyFileSecret(Encoding.UTF8.GetBytes("SATORU-KEYFILE-1\r\n# x\r\nAAAA\r\n")), null);
    });
    Test("暗号化: 保存のたびに中身が変わり、空の文書も扱える。この PC の鍵も往復できる", () => {
      var dk = FileCrypto.NewDeviceKey();
      Ok(!Same(FileCrypto.Seal(Plain, dk), FileCrypto.Seal(Plain, dk)), "nonce");
      Eq(FileCrypto.Open(FileCrypto.Seal(new byte[0], dk), FileCrypto.DeviceKey(dk.Bytes, dk.Salt)).Length, 0);
      Throws(() => FileCrypto.Open(FileCrypto.Seal(Plain, dk), FileCrypto.NewDeviceKey()), "別の鍵");
      var pk = new FileCrypto.Key { Bytes = dk.Bytes, Salt = dk.Salt, Iterations = 600000, Kind = "password" };
      var v1 = FileCrypto.Seal(Plain, pk, 1);
      Eq(FileCrypto.ReadHeader(v1).Version, 1);
      Ok(Same(FileCrypto.Open(v1, pk), Plain), "版 1");
    });
    Test("ワンタイム認証: 公式の検証値 (RFC 6238) と Mac 版の値に一致", () => {
      var rfc = Encoding.ASCII.GetBytes("12345678901234567890");
      Eq(Totp.Code(Secret, 1700000000), "107393");
      Eq(Totp.Base32(Secret), "AEEA6FQ5EQVTEOKAI5HFKXDDNJYXQ74G");
      Eq(Totp.Uri(Secret, "文書 A.txt", "さとるエディタ"),
        "otpauth://totp/%E3%81%95%E3%81%A8%E3%82%8B%E3%82%A8%E3%83%87%E3%82%A3%E3%82%BF:%E6%96%87%E6%9B%B8%20A.txt?secret=AEEA6FQ5EQVTEOKAI5HFKXDDNJYXQ74G&issuer=%E3%81%95%E3%81%A8%E3%82%8B%E3%82%A8%E3%83%87%E3%82%A3%E3%82%BF&algorithm=SHA1&digits=6&period=30");
      Ok(Totp.Verify("107 393", Secret, 1700000000), "空白入り");
      Ok(Totp.Verify("107393", Secret, 1700000000 + 30), "30 秒後");
      Ok(!Totp.Verify("107393", Secret, 1700000000 + 90), "90 秒後");
      Ok(!Totp.Verify("10739", Secret, 1700000000), "5 桁");
      Eq(Totp.CodeAt(rfc, 1), "287082"); // RFC の 8 桁 94287082 の下 6 桁
    });
    Test("grep: マスク・正規表現・バイナリ除外・Shift_JIS のファイル", () => {
      var dir = Path.Combine(Path.GetTempPath(), "satoru-grep-" + Guid.NewGuid().ToString("N"));
      Directory.CreateDirectory(Path.Combine(dir, "sub"));
      Directory.CreateDirectory(Path.Combine(dir, "node_modules"));
      File.WriteAllText(Path.Combine(dir, "a.txt"), "りんご\nみかん Apple\n");
      File.WriteAllBytes(Path.Combine(dir, "sub", "b.md"), Codec.Encode("apple パイ\n", "shiftJIS", "crlf"));
      File.WriteAllBytes(Path.Combine(dir, "c.bin"), new byte[] { 0x61, 0, 0x70, 0x70, 0x6C, 0x65 });
      File.WriteAllText(Path.Combine(dir, "node_modules", "d.txt"), "apple");
      List<string> Run(string pattern, bool regex = false, bool cs = false, string mask = "", bool rec = true) {
        var r = new List<string>();
        Grep.Search(dir, pattern, regex, cs, mask, rec, 0, m => r.Add(Path.GetFileName(m.File) + ":" + m.Line + ":" + m.Text), () => false);
        return r;
      }
      Eq(string.Join("|", Run("apple")), "a.txt:2:みかん Apple|b.md:1:apple パイ");
      Eq(string.Join("|", Run("apple", cs: true)), "b.md:1:apple パイ");
      Eq(string.Join("|", Run("apple", mask: "*.txt")), "a.txt:2:みかん Apple");
      Eq(string.Join("|", Run("apple", rec: false)), "a.txt:2:みかん Apple");
      Eq(string.Join("|", Run("^り.+ご$", regex: true)), "a.txt:1:りんご");
      Eq(string.Join("|", Run("a.c")), "");
      Directory.Delete(dir, true);
    });
    Test("zip: 作ったファイルを unzip で取り出せ、読み戻せる。フォルダの外へ出る名前は断る", () => {
      var big = string.Concat(Enumerable.Repeat("<x>あ</x>", 500));
      var data = Zip.Make(new[] { new Zip.Entry { Name = "a.txt", Data = Encoding.UTF8.GetBytes("hello") }, new Zip.Entry { Name = "dir/b.xml", Data = Encoding.UTF8.GetBytes(big) } });
      var dir = Path.Combine(Path.GetTempPath(), "satoru-zip-" + Guid.NewGuid().ToString("N"));
      Directory.CreateDirectory(dir);
      File.WriteAllBytes(Path.Combine(dir, "t.zip"), data);
      var p = System.Diagnostics.Process.Start("unzip", new[] { "-q", Path.Combine(dir, "t.zip"), "-d", Path.Combine(dir, "out") });
      p.WaitForExit();
      Eq(File.ReadAllText(Path.Combine(dir, "out", "a.txt")), "hello");
      Eq(File.ReadAllText(Path.Combine(dir, "out", "dir", "b.xml")), big);
      Directory.Delete(dir, true);
      var back = Zip.Extract(data);
      Eq(string.Join(",", back.Select(e => e.Name)), "a.txt,dir/b.xml");
      Eq(Encoding.UTF8.GetString(back[1].Data), big);
      Throws(() => Zip.Extract(Zip.Make(new[] { new Zip.Entry { Name = "../evil.js", Data = new byte[] { 1 } } })), "unsafe", e => e.Message.Contains("unsafe"));
      Throws(() => Zip.Extract(Encoding.ASCII.GetBytes("not a zip at all, definitely not")), "not a zip", e => e.Message.Contains("not a zip"));
    });
    Test("ChaCha20-Poly1305: RFC 8439 の検証値", () => {
      byte[] Hex(string s) => Enumerable.Range(0, s.Length / 2).Select(i => Convert.ToByte(s.Substring(i * 2, 2), 16)).ToArray();
      var key = Hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
      var nonce = Hex("070000004041424344454647");
      var aad = Hex("50515253c0c1c2c3c4c5c6c7");
      var pt = Encoding.ASCII.GetBytes("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.");
      var ct = ChaChaPoly.Seal(key, nonce, pt, aad);
      var hex = BitConverter.ToString(ct).Replace("-", "").ToLowerInvariant();
      Ok(hex.StartsWith("d31a8d34648e60db7b86afbc53ef7ec2"), "暗号文");
      Ok(hex.EndsWith("1ae10b594f09e26a7e902ecbd0600691"), "タグ " + hex.Substring(hex.Length - 32));
      Ok(Same(ChaChaPoly.Open(key, nonce, ct, aad), pt), "復号");
      for (int n = 0; n < 70; n++) {
        var m = Primitives.Random(n);
        Ok(Same(ChaChaPoly.Open(key, nonce, ChaChaPoly.Seal(key, nonce, m)), m), "長さ " + n);
      }
    });
    Test("共同編集の暗号: Mac 版が書いた 5 通を開け、順番違い・コード違い・改ざんは受け付けない", () => {
      var lines = Encoding.UTF8.GetString(Fx("mac-collab.txt")).Split('\n').Where(l => l.Length > 0).ToList();
      var guestSide = new CollabCipher("AB2C DEFG hjkm-npqr", false);
      var hostSide = new CollabCipher("ab2cdefghjkmnpqr", true);
      var got = lines.Select(l => { var p = (l[0] == 'H' ? guestSide : hostSide).Open(l.Substring(2)); return p == null ? "null" : Json.Stringify(Json.Parse(Encoding.UTF8.GetString(p))); }).ToList();
      Eq(string.Join("|", got), "{\"t\":\"welcome\",\"text\":\"こんにちは😀\"}|{\"t\":\"op\",\"loc\":1}|{\"t\":\"bye\"}|{\"t\":\"hello\",\"name\":\"Mac\"}|{\"t\":\"chat\",\"text\":\"やあ\"}");
      Eq(new CollabCipher("AB2CDEFGHJKMNPQR", false).Open(lines[1].Substring(2)), null);
      var g3 = new CollabCipher("AB2CDEFGHJKMNPQR", false);
      Ok(g3.Open(lines[0].Substring(2)) != null, "1 通目");
      Eq(g3.Open(lines[0].Substring(2)), null);
      Eq(new CollabCipher("ZZZZDEFGHJKMNPQR", false).Open(lines[0].Substring(2)), null);
      var b = Convert.FromBase64String(lines[0].Substring(2)); b[20] ^= 1;
      Eq(new CollabCipher("AB2CDEFGHJKMNPQR", false).Open(Convert.ToBase64String(b)), null);
      var host = new CollabCipher("k", true);
      var guest = new CollabCipher("k", false);
      var line = host.Seal(Encoding.UTF8.GetBytes("{\"t\":\"op\"}"));
      Ok(!line.Contains("\n"), "改行なし");
      Eq(new CollabCipher("k", true).Open(line), null);
      Eq(Encoding.UTF8.GetString(guest.Open(line)), "{\"t\":\"op\"}");
      var code = CollabCipher.NewCode();
      Ok(System.Text.RegularExpressions.Regex.IsMatch(code, "^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$"), code);
      Eq(CollabCipher.Normalize(code).Length, 16);
    });
    foreach (var extra in Extra.All) Test(extra.Key, extra.Value);
    Console.WriteLine($"\n{passed} 件成功, {failed} 件失敗");
    return failed == 0 ? 0 : 1;
  }
}
