using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace SatoEdit {
  /// 文字コードの判定と変換 (core/codec.js・Mac 版 TextCodec.swift と同じ決まり)
  public static class Codec {
    public class Info { public string Id, Name; public byte[] Bom; }
    public static readonly Info[] Encodings = {
      new Info { Id = "utf8", Name = "UTF-8", Bom = new byte[0] },
      new Info { Id = "utf8BOM", Name = "UTF-8 (BOM付)", Bom = new byte[] { 0xEF, 0xBB, 0xBF } },
      new Info { Id = "shiftJIS", Name = "Shift_JIS", Bom = new byte[0] },
      new Info { Id = "eucJP", Name = "EUC-JP", Bom = new byte[0] },
      new Info { Id = "iso2022JP", Name = "JIS", Bom = new byte[0] },
      new Info { Id = "utf16LE", Name = "UTF-16 LE", Bom = new byte[] { 0xFF, 0xFE } },
      new Info { Id = "utf16BE", Name = "UTF-16 BE", Bom = new byte[] { 0xFE, 0xFF } },
    };

    public static Info EncodingInfo(string id) {
      foreach (var e in Encodings) if (e.Id == id) return e;
      return Encodings[0];
    }
    public static string EncodingName(string id) => EncodingInfo(id).Name;
    public static string LineEndingString(string id) => id == "crlf" ? "\r\n" : id == "cr" ? "\r" : "\n";

    /// 文字コードで読めない・書けないとき。key と params は画面側で訳すのに使う
    public class CodecError : Exception {
      public string Key; public JObj Params;
      public CodecError(string key, JObj prms, string message) : base(message) { Key = key; Params = prms; }
    }

    static bool StartsWith(byte[] buf, byte[] bytes) {
      if (bytes.Length == 0 || buf.Length < bytes.Length) return false;
      for (int i = 0; i < bytes.Length; i++) if (buf[i] != bytes[i]) return false;
      return true;
    }

    static bool ContainsJISEscape(byte[] b) {
      for (int i = 0; i + 2 < b.Length; i++) {
        if (b[i] != 0x1B) continue;
        if ((b[i + 1] == 0x24 && (b[i + 2] == 0x42 || b[i + 2] == 0x40)) || (b[i + 1] == 0x28 && b[i + 2] == 0x4A)) return true;
      }
      return false;
    }

    public static bool IsValidShiftJIS(byte[] b, int start = 0) {
      int i = start;
      while (i < b.Length) {
        int c = b[i];
        if (c < 0x80 || (c >= 0xA1 && c <= 0xDF)) {
          i += 1;
        } else if ((c >= 0x81 && c <= 0x9F) || (c >= 0xE0 && c <= 0xFC)) {
          if (i + 1 >= b.Length) return false;
          int t = b[i + 1];
          if (!((t >= 0x40 && t <= 0x7E) || (t >= 0x80 && t <= 0xFC))) return false;
          i += 2;
        } else {
          return false;
        }
      }
      return true;
    }

    public static bool IsValidEUCJP(byte[] b, int start = 0) {
      int i = start;
      bool Hi(int x) => x >= 0xA1 && x <= 0xFE;
      while (i < b.Length) {
        int c = b[i];
        if (c < 0x80) {
          i += 1;
        } else if (c == 0x8E) {
          if (!(i + 1 < b.Length && b[i + 1] >= 0xA1 && b[i + 1] <= 0xDF)) return false;
          i += 2;
        } else if (c == 0x8F) {
          if (!(i + 2 < b.Length && Hi(b[i + 1]) && Hi(b[i + 2]))) return false;
          i += 3;
        } else if (Hi(c)) {
          if (!(i + 1 < b.Length && Hi(b[i + 1]))) return false;
          i += 2;
        } else {
          return false;
        }
      }
      return true;
    }

    static readonly UTF8Encoding StrictUTF8 = new UTF8Encoding(false, true);

    public static bool IsValidUTF8(byte[] buf) {
      try { StrictUTF8.GetString(buf); return true; } catch { return false; }
    }

    public static string DetectEncoding(byte[] buf) {
      if (StartsWith(buf, new byte[] { 0xEF, 0xBB, 0xBF })) return "utf8BOM";
      if (StartsWith(buf, new byte[] { 0xFF, 0xFE })) return "utf16LE";
      if (StartsWith(buf, new byte[] { 0xFE, 0xFF })) return "utf16BE";
      bool ascii = true;
      foreach (var x in buf) if (x >= 0x80) { ascii = false; break; }
      if (ascii) return ContainsJISEscape(buf) ? "iso2022JP" : "utf8";
      if (IsValidUTF8(buf)) return "utf8";
      bool sjis = IsValidShiftJIS(buf), euc = IsValidEUCJP(buf);
      if (sjis && !euc) return "shiftJIS";
      if (!sjis && euc) return "eucJP";
      // 普通の Shift_JIS は 0x81-0x9F の先行バイトを含むので EUC としては不正になる。両方通るなら EUC-JP の可能性が高い
      if (sjis && euc) return "eucJP";
      return "shiftJIS";
    }

    public static string DetectLineEnding(string s) {
      if (s.IndexOf("\r\n", StringComparison.Ordinal) >= 0) return "crlf";
      if (s.IndexOf('\r') >= 0) return "cr";
      return "lf";
    }

    public static string NormalizeLineEndings(string s) {
      if (s.IndexOf('\r') < 0) return s;
      return s.Replace("\r\n", "\n").Replace('\r', '\n');
    }

    // JIS (ISO-2022-JP) ⇔ EUC-JP のバイト列。文字の表は EUC-JP と同じなので、切り替えの印だけ付け外しする
    static byte[] JisToEUC(byte[] buf, int start) {
      var o = new MemoryStream();
      int mode = 0; // 0 = ASCII, 1 = 漢字, 2 = 半角カナ
      int i = start;
      while (i < buf.Length) {
        int c = buf[i];
        if (c == 0x1B && i + 2 < buf.Length) {
          int a = buf[i + 1], b = buf[i + 2];
          if (a == 0x24 && (b == 0x42 || b == 0x40)) { mode = 1; i += 3; continue; }
          if (a == 0x28 && (b == 0x42 || b == 0x4A)) { mode = 0; i += 3; continue; }
          if (a == 0x28 && b == 0x49) { mode = 2; i += 3; continue; }
          return null;
        }
        if (c == 0x0A || c == 0x0D) { o.WriteByte((byte)c); i += 1; continue; }
        if (c >= 0x80) return null;
        if (mode == 1) {
          if (i + 1 >= buf.Length) return null;
          o.WriteByte((byte)(c | 0x80)); o.WriteByte((byte)(buf[i + 1] | 0x80));
          i += 2;
        } else if (mode == 2) {
          o.WriteByte(0x8E); o.WriteByte((byte)(c | 0x80));
          i += 1;
        } else {
          o.WriteByte((byte)c);
          i += 1;
        }
      }
      return o.ToArray();
    }

    static byte[] EucToJIS(byte[] buf) {
      var o = new List<byte>();
      int mode = 0;
      void Set(int m) {
        if (m == mode) return;
        mode = m;
        if (m == 0) o.AddRange(new byte[] { 0x1B, 0x28, 0x42 });
        else if (m == 1) o.AddRange(new byte[] { 0x1B, 0x24, 0x42 });
        else o.AddRange(new byte[] { 0x1B, 0x28, 0x49 });
      }
      int i = 0;
      while (i < buf.Length) {
        int c = buf[i];
        if (c < 0x80) {
          Set(0); o.Add((byte)c); i += 1;
        } else if (c == 0x8E) {
          Set(2); o.Add((byte)(buf[i + 1] & 0x7F)); i += 2;
        } else if (c == 0x8F) {
          return null; // 補助漢字は JIS では書けない
        } else {
          Set(1); o.Add((byte)(c & 0x7F)); o.Add((byte)(buf[i + 1] & 0x7F)); i += 2;
        }
      }
      Set(0);
      return o.ToArray();
    }

    static Encoding strictCache932, strictCache51932;
    static Encoding Strict(int cp) {
#if !NET48
      try { Encoding.RegisterProvider(CodePagesEncodingProvider.Instance); } catch { }
#endif
      if (cp == 932) return strictCache932 ?? (strictCache932 = Encoding.GetEncoding(932, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback));
      return strictCache51932 ?? (strictCache51932 = Encoding.GetEncoding(51932, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback));
    }

    static string StrictDecode(int cp, byte[] b, int start) {
      try {
        var s = Strict(cp).GetString(b, start, b.Length - start);
        return s.IndexOf('�') >= 0 ? null : s;
      } catch { return null; }
    }

    /// 読めなければ null (壊れたバイトを黙って置き換えない)
    public static string DecodeRaw(byte[] buf, string encoding) {
      var info = EncodingInfo(encoding);
      int start = 0;
      if (info.Bom.Length > 0 && StartsWith(buf, info.Bom)) start = info.Bom.Length;
      switch (encoding) {
        case "utf8": case "utf8BOM":
          try { return StrictUTF8.GetString(buf, start, buf.Length - start); } catch { return null; }
        case "shiftJIS":
          if (!IsValidShiftJIS(buf, start)) return null;
          return StrictDecode(932, buf, start);
        case "eucJP":
          if (!IsValidEUCJP(buf, start)) return null;
          return StrictDecode(51932, buf, start);
        case "iso2022JP": {
          var euc = JisToEUC(buf, start);
          if (euc == null) return null;
          return StrictDecode(51932, euc, 0);
        }
        case "utf16LE":
          if ((buf.Length - start) % 2 != 0) return null;
          return new UnicodeEncoding(false, false).GetString(buf, start, buf.Length - start);
        case "utf16BE":
          if ((buf.Length - start) % 2 != 0) return null;
          return new UnicodeEncoding(true, false).GetString(buf, start, buf.Length - start);
        default:
          return null;
      }
    }

    public class Decoded { public string Text, Encoding, LineEnding; }

    /// encoding を省くと自動判別。返す Text の改行は LF にそろえてある
    public static Decoded Decode(byte[] buf, string encoding = null) {
      Decoded Make(string raw, string e) => new Decoded { Text = NormalizeLineEndings(raw), Encoding = e, LineEnding = DetectLineEnding(raw) };
      if (!string.IsNullOrEmpty(encoding)) {
        var raw = DecodeRaw(buf, encoding);
        if (raw == null) {
          const string key = "{name} として読み込めませんでした。別の文字コードを指定して開き直してください。";
          var name = EncodingName(encoding);
          throw new CodecError(key, new JObj { { "name", name } }, key.Replace("{name}", name));
        }
        return Make(raw, encoding);
      }
      var guess = DetectEncoding(buf);
      var tried = new List<string>();
      foreach (var e in new[] { guess, "utf8", "shiftJIS", "eucJP" }) {
        if (tried.Contains(e)) continue;
        tried.Add(e);
        var raw = DecodeRaw(buf, e);
        if (raw != null) return Make(raw, e);
      }
      // 最後の手段: 壊れたバイトを置換文字にして UTF-8 として開く
      return Make(new UTF8Encoding(false, false).GetString(buf), "utf8");
    }

    /// text は LF 改行の前提。その文字コードで書けない文字があればエラー
    public static byte[] Encode(string text, string encoding, string lineEnding) {
      var eol = LineEndingString(lineEnding);
      var converted = eol == "\n" ? text : text.Replace("\n", eol);
      var info = EncodingInfo(encoding);
      CodecError Fail() {
        const string key = "{name} では保存できない文字が含まれています。文字コードを UTF-8 などに変更してから保存してください。";
        return new CodecError(key, new JObj { { "name", info.Name } }, key.Replace("{name}", info.Name));
      }
      byte[] body;
      switch (encoding) {
        case "utf8": case "utf8BOM": body = new UTF8Encoding(false, false).GetBytes(converted); break;
        case "utf16LE": body = new UnicodeEncoding(false, false).GetBytes(converted); break;
        case "utf16BE": body = new UnicodeEncoding(true, false).GetBytes(converted); break;
        case "shiftJIS":
          try { body = Strict(932).GetBytes(converted); } catch { throw Fail(); }
          if (StrictDecode(932, body, 0) != converted) throw Fail();
          break;
        case "eucJP": case "iso2022JP": {
          byte[] euc;
          try { euc = Strict(51932).GetBytes(converted); } catch { throw Fail(); }
          if (StrictDecode(51932, euc, 0) != converted) throw Fail();
          body = encoding == "eucJP" ? euc : EucToJIS(euc);
          if (body == null) throw Fail();
          break;
        }
        default: throw Fail();
      }
      var outb = new byte[info.Bom.Length + body.Length];
      Buffer.BlockCopy(info.Bom, 0, outb, 0, info.Bom.Length);
      Buffer.BlockCopy(body, 0, outb, info.Bom.Length, body.Length);
      return outb;
    }
  }
}
