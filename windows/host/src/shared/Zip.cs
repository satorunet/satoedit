using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Text;

namespace SatoEdit {
  /// 小さな zip の読み書き (Word の .docx の入れ物と、拡張機能の zip に使う)。core/zip.js と同じ
  public static class Zip {
    static uint[] table;
    public static uint Crc32(byte[] buf) {
      if (table == null) {
        var t = new uint[256];
        for (uint n = 0; n < 256; n++) {
          uint c = n;
          for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
          t[n] = c;
        }
        table = t;
      }
      uint crc = 0xFFFFFFFF;
      foreach (var b in buf) crc = table[(crc ^ b) & 0xFF] ^ (crc >> 8);
      return crc ^ 0xFFFFFFFF;
    }

    public class Entry { public string Name; public byte[] Data; }

    static byte[] Deflate(byte[] data) {
      var ms = new MemoryStream();
      using (var d = new DeflateStream(ms, CompressionLevel.Optimal, true)) d.Write(data, 0, data.Length);
      return ms.ToArray();
    }

    static byte[] Inflate(byte[] data) {
      var outp = new MemoryStream();
      using (var d = new DeflateStream(new MemoryStream(data), CompressionMode.Decompress)) d.CopyTo(outp);
      return outp.ToArray();
    }

    static void U16(Stream s, int v) { s.WriteByte((byte)v); s.WriteByte((byte)(v >> 8)); }
    static void U32(Stream s, uint v) { s.WriteByte((byte)v); s.WriteByte((byte)(v >> 8)); s.WriteByte((byte)(v >> 16)); s.WriteByte((byte)(v >> 24)); }

    /// entries → zip ファイルの中身
    public static byte[] Make(IList<Entry> entries) {
      var body = new MemoryStream();
      var central = new MemoryStream();
      foreach (var e in entries) {
        var name = Encoding.UTF8.GetBytes(e.Name);
        var packed = Deflate(e.Data);
        var crc = Crc32(e.Data);
        uint offset = (uint)body.Length;
        U32(body, 0x04034B50); U16(body, 20); U16(body, 0x0800); U16(body, 8); U16(body, 0); U16(body, 0x21);
        U32(body, crc); U32(body, (uint)packed.Length); U32(body, (uint)e.Data.Length); U16(body, name.Length); U16(body, 0);
        body.Write(name, 0, name.Length);
        body.Write(packed, 0, packed.Length);

        U32(central, 0x02014B50); U16(central, 20); U16(central, 20); U16(central, 0x0800); U16(central, 8); U16(central, 0); U16(central, 0x21);
        U32(central, crc); U32(central, (uint)packed.Length); U32(central, (uint)e.Data.Length); U16(central, name.Length);
        U16(central, 0); U16(central, 0); U16(central, 0); U16(central, 0); U32(central, 0); U32(central, offset);
        central.Write(name, 0, name.Length);
      }
      uint centralOffset = (uint)body.Length;
      var c = central.ToArray();
      body.Write(c, 0, c.Length);
      U32(body, 0x06054B50); U16(body, 0); U16(body, 0); U16(body, entries.Count); U16(body, entries.Count);
      U32(body, (uint)c.Length); U32(body, centralOffset); U16(body, 0);
      return body.ToArray();
    }

    static int R16(byte[] b, int p) => b[p] | (b[p + 1] << 8);
    static uint R32(byte[] b, int p) => (uint)(b[p] | (b[p + 1] << 8) | (b[p + 2] << 16) | (b[p + 3] << 24));

    /// zip ファイルの中身を読む (保存のみ・deflate)。フォルダの外へ書き出す名前 (../ や / で始まる) があれば、全部を断る
    public static List<Entry> Extract(byte[] buf, long maxTotal = 200L * 1024 * 1024) {
      int eocd = -1;
      for (int i = buf.Length - 22; i >= Math.Max(0, buf.Length - 65557); i--) {
        if (R32(buf, i) == 0x06054b50) { eocd = i; break; }
      }
      if (eocd < 0) throw new InvalidDataException("not a zip");
      int count = R16(buf, eocd + 10);
      int p = (int)R32(buf, eocd + 16);
      var outl = new List<Entry>();
      long total = 0;
      for (int n = 0; n < count; n++) {
        if (R32(buf, p) != 0x02014b50) throw new InvalidDataException("broken zip");
        int method = R16(buf, p + 10);
        uint csize = R32(buf, p + 20), usize = R32(buf, p + 24);
        int nameLen = R16(buf, p + 28), extraLen = R16(buf, p + 30), commentLen = R16(buf, p + 32);
        int local = (int)R32(buf, p + 42);
        var name = Encoding.UTF8.GetString(buf, p + 46, nameLen).Replace('\\', '/');
        p += 46 + nameLen + extraLen + commentLen;
        if (name.StartsWith("/") || System.Text.RegularExpressions.Regex.IsMatch(name, "^[A-Za-z]:") || Array.IndexOf(name.Split('/'), "..") >= 0) throw new InvalidDataException("unsafe path: " + name);
        if (name.EndsWith("/")) continue;
        if (R32(buf, local) != 0x04034b50) throw new InvalidDataException("broken zip");
        int start = local + 30 + R16(buf, local + 26) + R16(buf, local + 28);
        var raw = new byte[Math.Min(csize, (uint)Math.Max(0, buf.Length - start))];
        Buffer.BlockCopy(buf, start, raw, 0, raw.Length);
        total += usize;
        if (total > maxTotal) throw new InvalidDataException("too large");
        byte[] data;
        if (method == 0) data = raw;
        else if (method == 8) data = Inflate(raw);
        else throw new InvalidDataException("unsupported compression: " + method);
        outl.Add(new Entry { Name = name, Data = data });
      }
      return outl;
    }
  }
}
