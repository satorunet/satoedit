using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace SatoEdit {
  /// テキスト一覧 (Mac 版 TextLibrary.swift と同じ考え方)。
  /// 新しく書いた文書の置き場所は「ドキュメント\さとるエディタ」。中にフォルダを作って分けられる。
  /// ファイルごとの表示 (原稿用紙の縦・横、A4) と版の履歴の番号は、ファイルの見えない所 (NTFS の代替データストリーム) に書く。
  /// Mac 版は拡張属性 (net.satoru.satoruEditor.mode#S) に書いている。中身の文字は変えない
  static class Library {
    public const string ModeStream = "net.satoru.satoruEditor.mode";
    public const string HistoryStream = "net.satoru.satoruEditor.history";
    public const string BlankBaseName = "新規テキスト";

    /// ▼ ボタンの「任意フォルダ…」で選んだフォルダ (null = ローカル)。選んでいるあいだは、ここがテキスト一覧の基準になる
    public static volatile string Custom;

    /// ふだんの置き場所。動作確認では SATORU_LIBRARY_DIR で別の場所にする (本物のドキュメントに触れないように)
    public static string DefaultRoot {
      get {
        var o = Environment.GetEnvironmentVariable("SATORU_LIBRARY_DIR");
        if (!string.IsNullOrEmpty(o)) return Path.GetFullPath(o);
        // 表示の言語を変えても同じ場所を使うよう、名前は訳さない
        if (Portable.On) return Path.Combine(Portable.Data, "さとるエディタ"); // ポータブル版は exe の横
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "さとるエディタ");
      }
    }

    /// 置き場所 (任意フォルダを選んでいれば、そこ)
    public static string Root {
      get {
        var c = Custom;
        return c != null && Directory.Exists(c) ? c : DefaultRoot;
      }
    }
    public static bool UsesCustom { get { var c = Custom; return c != null && Directory.Exists(c); } }

    public static string Norm(string p) {
      try { return Path.GetFullPath(p).TrimEnd('\\'); } catch { return p ?? ""; }
    }
    public static bool Same(string a, string b) => string.Equals(Norm(a), Norm(b), StringComparison.OrdinalIgnoreCase);

    // ---------- 代替データストリーム ----------

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sec, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool DeleteFileW(string name);
    const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000;
    const uint SHARE_ALL = 1 | 2 | 4, OPEN_EXISTING = 3, CREATE_ALWAYS = 2;

    /// ファイルの見えない所に書いた値 (なければ null)
    public static string ReadStream(string file, string name) {
      try {
        if (!File.Exists(file)) return null;
        using (var h = CreateFileW(file + ":" + name, GENERIC_READ, SHARE_ALL, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero)) {
          if (h.IsInvalid) return null;
          using (var fs = new FileStream(h, FileAccess.Read)) {
            var buf = new byte[256];
            int n = fs.Read(buf, 0, buf.Length);
            return n > 0 ? Encoding.UTF8.GetString(buf, 0, n) : null;
          }
        }
      } catch { return null; }
    }

    /// 見えない所に書く (null なら消す)。ファイルの更新日時は変えない。書けない (ロック中・FAT など) ときは false
    public static bool WriteStream(string file, string name, string value) {
      try {
        if (!File.Exists(file)) return false;
        if ((File.GetAttributes(file) & FileAttributes.ReadOnly) != 0) return false;
        if (ReadStream(file, name) == value) return true;
        var mtime = File.GetLastWriteTimeUtc(file);
        bool ok;
        if (value == null) {
          ok = DeleteFileW(file + ":" + name);
        } else {
          using (var h = CreateFileW(file + ":" + name, GENERIC_WRITE, SHARE_ALL, IntPtr.Zero, CREATE_ALWAYS, 0, IntPtr.Zero)) {
            if (h.IsInvalid) return false;
            using (var fs = new FileStream(h, FileAccess.Write)) {
              var b = Encoding.UTF8.GetBytes(value);
              fs.Write(b, 0, b.Length);
            }
          }
          ok = true;
        }
        try { File.SetLastWriteTimeUtc(file, mtime); } catch { }
        return ok;
      } catch { return false; }
    }

    static readonly string[] Modes = { "genko", "genkoH", "a4" };
    public static string FileMode(string file) {
      var v = ReadStream(file, ModeStream);
      return v != null && Modes.Contains(v) ? v : null;
    }

    // ---------- フォルダ ----------

    /// その文書がどのフォルダのものか: "" = さとるエディタ直下、"旅行/京都" = 中のフォルダ、null = ほかの場所
    public static string Group(string file) {
      var root = Norm(Root);
      var parent = Norm(Path.GetDirectoryName(Norm(file)) ?? "");
      if (string.Equals(parent, root, StringComparison.OrdinalIgnoreCase)) return "";
      if (!parent.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase)) return null;
      return parent.Substring(root.Length + 1).Replace('\\', '/');
    }

    public static string FolderPath(string rel) => string.IsNullOrEmpty(rel) ? Root : Path.Combine(Root, rel.Replace('/', '\\'));

    static readonly StringComparer Ja = StringComparer.Create(new System.Globalization.CultureInfo("ja-JP"), true);

    /// すぐ下のフォルダ (道すじ)。order に並べた順、ないものは名前の順で後ろ
    public static List<string> ChildFolders(string rel, List<string> order) {
      var dir = FolderPath(rel);
      if (!Directory.Exists(dir)) return new List<string>();
      var names = new DirectoryInfo(dir).GetDirectories()
        .Where(d => !d.Name.StartsWith(".") && (d.Attributes & (FileAttributes.Hidden | FileAttributes.System)) == 0)
        .Select(d => string.IsNullOrEmpty(rel) ? d.Name : rel + "/" + d.Name).ToList();
      int Rank(string p) { var i = order.FindIndex(o => string.Equals(o, p, StringComparison.OrdinalIgnoreCase)); return i < 0 ? int.MaxValue : i; }
      return names.OrderBy(Rank).ThenBy(p => p, Ja).ToList();
    }

    /// フォルダの木: [{ rel, name, children }] (深さ 8 まで)
    public static List<object> Tree(string rel, List<string> order, int depth = 0) {
      var outl = new List<object>();
      if (depth >= 8) return outl;
      foreach (var c in ChildFolders(rel, order)) {
        double created = 0;
        try { created = Ms(Directory.GetCreationTimeUtc(FolderPath(c))); } catch { }
        outl.Add(new JObj { { "rel", c }, { "name", c.Split('/').Last() }, { "created", created }, { "children", Tree(c, order, depth + 1) } });
      }
      return outl;
    }

    public static List<string> Subfolders(List<string> order) {
      var outl = new List<string>();
      void Walk(string rel, int depth) {
        if (depth >= 8) return;
        foreach (var c in ChildFolders(rel, order)) { outl.Add(c); Walk(c, depth + 1); }
      }
      Walk("", 0);
      return outl;
    }

    public static string CleanName(string s) {
      var n = new string((s ?? "").Where(c => "/\\:*?\"<>|".IndexOf(c) < 0 && c >= 0x20).ToArray()).Trim();
      return n == "" || n.StartsWith(".") ? null : n;
    }

    // ---------- 一覧 ----------

    /// テキストとして扱わない拡張子 (PDF・画像・音・動画・圧縮・Office など)
    static readonly HashSet<string> NonText = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
      "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "odt", "ods", "odp",
      "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "pkg", "app", "exe", "dll", "so", "dylib", "o", "class", "jar",
      "sqlite", "db", "bin", "dat", "iso", "psd", "ai", "sketch", "fig", "msi", "lnk", "cab", "obj", "pdb", "lib",
      "png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "webp", "heic", "ico", "icns", "raw", "cr2", "nef",
      "mp3", "wav", "aac", "m4a", "flac", "ogg", "wma", "aif", "aiff", "mid", "midi",
      "mp4", "mov", "avi", "mkv", "wmv", "m4v", "webm", "flv", "mpg", "mpeg",
      "ttf", "otf", "woff", "woff2", "eot", "satorubackup", "satorukey",
    };
    public static bool IsNonText(string file) {
      var ext = Path.GetExtension(file).TrimStart('.');
      return ext != "" && NonText.Contains(ext);
    }

    static byte[] Head(string file, int n) {
      using (var fs = new FileStream(file, System.IO.FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
        var buf = new byte[Math.Min(n, (int)Math.Min(int.MaxValue, fs.Length))];
        int got = 0;
        while (got < buf.Length) { int k = fs.Read(buf, got, buf.Length - got); if (k <= 0) break; got += k; }
        if (got < buf.Length) Array.Resize(ref buf, got);
        return buf;
      }
    }

    static double Ms(DateTime utc) => (utc - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;

    /// 一覧の 1 件。テキストでないものは null
    public static JObj Item(string file) {
      if (IsNonText(file)) return null;
      var fi = new FileInfo(file);
      if (!fi.Exists) return null;
      byte[] head;
      try { head = Head(file, 6000); } catch { return null; }
      var group = Group(file);
      bool inFolder = group != null;
      var o = new JObj { { "path", fi.FullName }, { "name", fi.Name }, { "modified", Ms(fi.LastWriteTimeUtc) }, { "created", Ms(fi.CreationTimeUtc) },
        { "size", (double)fi.Length }, { "group", group }, { "inFolder", inFolder }, { "locked", (fi.Attributes & FileAttributes.ReadOnly) != 0 } };
      if (FileCrypto.IsEncrypted(head)) {
        o["encrypted"] = true;
        o["title"] = Path.GetFileNameWithoutExtension(file);
        o["snippet"] = "";
        o["mode"] = null;
        return o;
      }
      if (Binary.LooksBinary(head)) return null;
      string text;
      try { text = Codec.Decode(head).Text; } catch { text = ""; }
      if (text.EndsWith("�")) text = text.Substring(0, text.Length - 1);
      text = text.Replace("\r\n", "\n").Replace('\r', '\n');
      o["encrypted"] = false;
      o["title"] = Path.GetFileNameWithoutExtension(file);   // 題名はいつもファイルの名前 (Mac 版と同じ。1 行目ではない)
      var mode = FileMode(file);
      o["mode"] = mode;
      bool genko = mode == "genko" || mode == "genkoH";
      var body = text.Trim();
      // 原稿用紙は 1 枚ぶん (400 字と改行) を描けるよう、少し長めに持つ
      o["snippet"] = genko ? (text.Length > 700 ? text.Substring(0, 700) : text) : (body.Length > 400 ? body.Substring(0, 400) : body);
      return o;
    }

    /// 一覧: さとるエディタのフォルダの中すべてと、開いた・保存したファイル (known)
    public static List<object> Items(List<string> known, List<string> order) {
      var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
      var files = new List<string>();
      void Add(string f) {
        var p = Norm(f);
        if (seen.Contains(p) || !File.Exists(p)) return;
        seen.Add(p);
        files.Add(p);
      }
      if (Directory.Exists(Root)) {
        foreach (var dir in new[] { Root }.Concat(Subfolders(order).Select(FolderPath))) {
          try {
            foreach (var f in new DirectoryInfo(dir).GetFiles()) {
              if (f.Name.StartsWith(".") || (f.Attributes & (FileAttributes.Hidden | FileAttributes.System)) != 0) continue;
              Add(f.FullName);
            }
          } catch { }
        }
      }
      foreach (var k in known) Add(k);
      var outl = new List<object>();
      foreach (var f in files) {
        try { var it = Item(f); if (it != null) outl.Add(it); } catch { }
      }
      return outl;
    }

    static bool Hidden(FileSystemInfo f) => f.Name.StartsWith(".") || (f.Attributes & (FileAttributes.Hidden | FileAttributes.System)) != 0;

    static JObj Lite(FileInfo fi, string group) => new JObj { { "path", fi.FullName }, { "name", fi.Name }, { "title", Path.GetFileNameWithoutExtension(fi.Name) },
      { "modified", Ms(fi.LastWriteTimeUtc) }, { "created", Ms(fi.CreationTimeUtc) }, { "group", group }, { "inFolder", group != null },
      { "locked", (fi.Attributes & FileAttributes.ReadOnly) != 0 } };

    /// 一覧に出すファイルを集める (中身は読まない。速い): さとるエディタのフォルダの中すべて、開いた・保存したファイル (known)、
    /// 開いたほかの場所のフォルダ (externals。中のフォルダも 3 段まで、2000 件まで)。フォルダの木もいっしょに返す
    public static JObj Scan(List<string> known, List<string> order, List<string> externals) {
      var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
      var files = new List<object>();
      var root = Root;
      var rootNorm = Norm(root);
      if (Directory.Exists(root)) {
        foreach (var rel in new[] { "" }.Concat(Subfolders(order))) {
          var dir = rel == "" ? rootNorm : rootNorm + "\\" + rel.Replace('/', '\\');
          try {
            foreach (var f in new DirectoryInfo(dir).GetFiles()) {
              if (Hidden(f) || IsNonText(f.Name) || !seen.Add(f.FullName)) continue;
              files.Add(Lite(f, rel));
            }
          } catch { }
        }
      }
      foreach (var k in known) {
        try {
          var p = Norm(k);
          if (seen.Contains(p) || IsNonText(p)) continue;
          var fi = new FileInfo(p);
          if (!fi.Exists) continue;
          seen.Add(fi.FullName);
          files.Add(Lite(fi, Group(fi.FullName)));
        } catch { }
      }
      var ext = new List<object>();
      foreach (var e in externals) {
        var top = Norm(e);
        if (!Directory.Exists(top)) continue;
        int n = 0;
        void Walk(string dir, int depth) {
          if (n >= 2000) return;
          try {
            var di = new DirectoryInfo(dir);
            foreach (var f in di.GetFiles()) {
              if (Hidden(f) || IsNonText(f.Name)) continue;
              if (seen.Add(f.FullName)) { files.Add(Lite(f, Group(f.FullName))); if (++n >= 2000) return; }
            }
            if (depth < 3) foreach (var d in di.GetDirectories()) if (!Hidden(d)) Walk(d.FullName, depth + 1);
          } catch { }
        }
        Walk(top, 0);
        ext.Add(ExtTree(top, 0));
      }
      return new JObj { { "root", root }, { "files", files }, { "tree", Tree("", order) }, { "externals", ext } };
    }

    /// 開いたほかの場所のフォルダの木 (3 段まで。1 段 200 個まで)
    static JObj ExtTree(string path, int depth) {
      var kids = new List<object>();
      if (depth < 3) {
        try {
          foreach (var d in new DirectoryInfo(path).GetDirectories().Where(d => !Hidden(d)).OrderBy(d => d.Name, Ja).Take(200)) kids.Add(ExtTree(d.FullName, depth + 1));
        } catch { }
      }
      return new JObj { { "path", path }, { "name", Path.GetFileName(path.TrimEnd('\\')) is string nm && nm != "" ? nm : path }, { "children", kids } };
    }

    /// 中身 (題名・本文のはじめ・表示) を読む。テキストでないものは null
    public static List<object> Read(List<string> paths) {
      var outl = new List<object>();
      foreach (var p in paths) { try { outl.Add(Item(p)); } catch { outl.Add(null); } }
      return outl;
    }

    /// 重ならない名前: dir\base.ext → dir\base 2.ext …
    public static string Unique(string dir, string baseName, string ext, Func<int, string> name = null) {
      name = name ?? (n => n == 1 ? baseName : baseName + " " + n);
      for (int n = 1; ; n++) {
        var p = Path.Combine(dir, name(n) + ext);
        if (!File.Exists(p) && !Directory.Exists(p)) return p;
      }
    }

    public static bool IsBlankPlaceholder(string file) {
      if (string.IsNullOrEmpty(file) || Group(file) == null) return false;
      var n = Path.GetFileNameWithoutExtension(file);
      return n == BlankBaseName || n.StartsWith(BlankBaseName + " ");
    }
  }
}
