using System;
using System.IO;

namespace SatoEdit {
  /// 巨大なファイルの「一部分だけ」を読み書きする (Mac 版 PartialFile.swift と同じ)。
  /// 読むときは行の切れ目に合わせ、保存するときは「前の部分 + 書き換えた部分 + 後ろの部分」をつないで書き出す
  public static class PartialFile {
    public struct Part {
      /// ファイルの先頭からのバイト位置
      public long Offset;
      /// 読み込んだバイト数
      public long Length;
      /// 読んだときのファイル全体の大きさ
      public long FileSize;
      public long End => Offset + Length;
      public bool IsWholeFile => Offset == 0 && Length >= FileSize;
      public Part(long offset, long length, long fileSize) { Offset = offset; Length = length; FileSize = fileSize; }
    }

    const int Window = 1 << 20;
    /// 行の切れ目を探すのをあきらめる長さ (これより長い 1 行は途中で切る)
    const long MaxSeek = 16L << 20;

    static FileStream OpenRead(string file) => new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 16);

    /// from から先で最初の改行 (LF) の次の位置。見つからなければ -1
    static long AfterNewline(FileStream fs, long from, long size) {
      var buf = new byte[Window];
      long pos = from;
      while (pos < size && pos - from < MaxSeek) {
        fs.Position = pos;
        int n = fs.Read(buf, 0, (int)Math.Min(buf.Length, size - pos));
        if (n <= 0) break;
        int i = Array.IndexOf(buf, (byte)0x0A, 0, n);
        if (i >= 0) return pos + i + 1;
        pos += n;
      }
      return -1;
    }

    /// 希望の範囲を、行の切れ目に合わせる (先頭は次の行頭へ、末尾はその行の終わりまで)
    public static Part Align(string file, long offset, long length) {
      using (var fs = OpenRead(file)) {
        long size = fs.Length;
        long start = Math.Max(0, Math.Min(offset, size));
        if (start > 0) {
          // ちょうど行頭ならそのまま (1 つ前が改行)
          fs.Position = start - 1;
          if (fs.ReadByte() != 0x0A) {
            var s = AfterNewline(fs, start, size);
            if (s >= 0) start = s;
          }
        }
        long end = Math.Min(size, Math.Max(start, offset) + Math.Max(length, 1));
        if (end < size) {
          fs.Position = end - 1;
          if (fs.ReadByte() != 0x0A) {
            var e = AfterNewline(fs, end, size);
            end = e >= 0 ? e : (end + MaxSeek >= size ? size : end);
          }
        }
        return new Part(start, Math.Max(0, end - start), size);
      }
    }

    public static byte[] Read(string file, Part part) {
      using (var fs = OpenRead(file)) {
        fs.Position = part.Offset;
        var buf = new byte[part.Length];
        int got = 0;
        while (got < buf.Length) {
          int n = fs.Read(buf, got, buf.Length - got);
          if (n <= 0) break;
          got += n;
        }
        if (got < buf.Length) Array.Resize(ref buf, got);
        return buf;
      }
    }

    /// 先頭から max バイトまで (暗号化・バイナリかどうかを見るため)
    public static byte[] Head(string file, int max) {
      using (var fs = OpenRead(file)) {
        var buf = new byte[(int)Math.Min(max, fs.Length)];
        int got = 0;
        while (got < buf.Length) { int n = fs.Read(buf, got, buf.Length - got); if (n <= 0) break; got += n; }
        return buf;
      }
    }

    /// data の中で、先頭から upTo バイトまでにある改行 (LF) の数 = upTo の位置が何行目か (0 始まり)
    public static int LinesBefore(byte[] data, long upTo) {
      int n = 0, end = (int)Math.Max(0, Math.Min(data.Length, upTo));
      for (int i = 0; i < end; i++) if (data[i] == 0x0A) n++;
      return n;
    }

    /// data の line 行目 (0 始まり) の行頭のバイト位置 (data の中の位置)。行が足りなければ data の終わり
    public static long LineStart(byte[] data, int line) {
      if (line <= 0) return 0;
      int n = 0;
      for (int i = 0; i < data.Length; i++) {
        if (data[i] != 0x0A) continue;
        if (++n == line) return i + 1;
      }
      return data.Length;
    }

    /// original の part の所を replacement に差し替えたものを dest に書く (original は変えない)
    public static void Write(string original, Part part, byte[] replacement, string dest) {
      using (var src = OpenRead(original))
      using (var outs = new FileStream(dest, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16)) {
        long size = src.Length;
        var buf = new byte[4 << 20];
        void Copy(long from, long to) {
          src.Position = from;
          long pos = from;
          while (pos < to) {
            int n = src.Read(buf, 0, (int)Math.Min(buf.Length, to - pos));
            if (n <= 0) break;
            outs.Write(buf, 0, n);
            pos += n;
          }
        }
        Copy(0, Math.Min(part.Offset, size));
        outs.Write(replacement, 0, replacement.Length);
        Copy(Math.Min(part.End, size), size);
      }
    }
  }
}
