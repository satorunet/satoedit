using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace SatoEdit {
  /// テキスト一覧・版の履歴・バックアップ (画面側は renderer/src/library.js・versions.js)
  partial class Bridge {
    static List<string> Strings(object o) => (o as List<object> ?? new List<object>()).OfType<string>().ToList();
    readonly ConcurrentDictionary<string, JObj> openedBackups = new ConcurrentDictionary<string, JObj>();

    void RegisterLibrary() {
      On("libraryInfo", a => LibraryInfo());
      // 任意フォルダを基準にする (null = ローカルに戻す)
      On("librarySetRoot", a => {
        var p = Arg(a, 0) as string;
        Library.Custom = !string.IsNullOrEmpty(p) && Directory.Exists(p) ? Library.Norm(p) : null;
        return LibraryInfo();
      });
      OnBg("libraryScan", a => Library.Scan(Strings(Arg(a, 0)), Strings(Arg(a, 1)), Strings(Arg(a, 2))));
      OnBg("libraryRead", a => Library.Read(Strings(Arg(a, 0))));
      On("beep", a => { System.Media.SystemSounds.Beep.Play(); return true; });
      OnBg("libraryItems", a => Library.Items(Strings(Arg(a, 0)), Strings(Arg(a, 1))));
      OnBg("libraryTree", a => Library.Tree("", Strings(Arg(a, 0))));
      OnBg("libraryCreateFolder", a => {
        try {
          var name = Library.CleanName(S(a, 0));
          if (name == null) throw new UserError("使えない文字が入っています。");
          var parent = S(a, 1);
          var rel = parent == "" ? name : parent + "/" + name;
          var full = Library.FolderPath(rel);
          if (Directory.Exists(full) || File.Exists(full)) throw new UserError("同じ名前のものがあります。");
          Directory.CreateDirectory(full);
          return new JObj { { "status", "ok" }, { "rel", rel } };
        } catch (Exception e) { return Fail(e); }
      });
      // フォルダの名前を変える・別のフォルダの中へ移す → { rel, from, to } (道すじの付け替えは画面側で)
      OnBg("libraryRenameFolder", a => {
        try {
          var rel = S(a, 0);
          var name = Library.CleanName(S(a, 1));
          if (name == null) throw new UserError("使えない文字が入っています。");
          var parent = rel.Contains("/") ? rel.Substring(0, rel.LastIndexOf('/')) : "";
          return MoveFolder(rel, parent == "" ? name : parent + "/" + name);
        } catch (Exception e) { return Fail(e); }
      });
      OnBg("libraryMoveFolder", a => {
        try {
          var rel = S(a, 0);
          var parent = S(a, 1);
          if (parent == rel || parent.StartsWith(rel + "/")) throw new UserError("フォルダを自分の中へは移せません。");
          var name = rel.Split('/').Last();
          return MoveFolder(rel, parent == "" ? name : parent + "/" + name);
        } catch (Exception e) { return Fail(e); }
      });
      OnBg("libraryTrash", a => {
        var done = new List<object>();
        var failed = new List<object>();
        var paths = Strings(Arg(a, 0));
        Versions.Forget(paths); // 版の履歴も消す
        foreach (var p in paths) {
          try { Win32.Trash(p); done.Add(p); } catch (Exception e) { failed.Add(p + ": " + e.Message); }
        }
        return new JObj { { "status", "ok" }, { "done", done }, { "failed", failed } };
      });
      // 空の「新規テキスト」を作る (dir: フォルダの道すじ)。mode があれば表示も書いておく
      OnBg("libraryCreateBlank", a => {
        try {
          var dir = Library.FolderPath(S(a, 0));
          if (!Directory.Exists(dir)) dir = Library.Root;
          Directory.CreateDirectory(dir);
          var file = Library.Unique(dir, Library.BlankBaseName, ".txt");
          using (new FileStream(file, FileMode.CreateNew)) { }
          if (S(a, 1) != "") Library.WriteStream(file, Library.ModeStream, S(a, 1));
          return new JObj { { "status", "ok" }, { "path", file } };
        } catch (Exception e) { return Fail(e); }
      });
      OnBg("libraryGetMode", a => Library.FileMode(S(a, 0)));
      OnBg("librarySetMode", a => Library.WriteStream(S(a, 0), Library.ModeStream, Arg(a, 1) as string));
      OnBg("librarySetLocked", a => {
        try {
          var f = S(a, 0);
          var attr = File.GetAttributes(f);
          File.SetAttributes(f, B(a, 1) ? attr | FileAttributes.ReadOnly : attr & ~FileAttributes.ReadOnly);
          return new JObj { { "status", "ok" } };
        } catch (Exception e) { return Fail(e); }
      });
      // 同じフォルダに「〜 のコピー」を作る (表示・履歴の番号も写る。履歴は次の保存のときに分かれる)。コピーはロックしない
      OnBg("libraryDuplicate", a => {
        try {
          var f = S(a, 0);
          var one = S(a, 1, "{name} のコピー");
          var many = S(a, 2, "{name} のコピー {n}");
          var baseName = Path.GetFileNameWithoutExtension(f);
          var to = Library.Unique(Path.GetDirectoryName(f), baseName, Path.GetExtension(f),
            n => (n == 1 ? one : many.Replace("{n}", n.ToString())).Replace("{name}", baseName));
          File.Copy(f, to);
          File.SetAttributes(to, File.GetAttributes(to) & ~FileAttributes.ReadOnly);
          return new JObj { { "status", "ok" }, { "path", to } };
        } catch (Exception e) { return Fail(e); }
      });
      // 好きなフォルダへ移す (同じ名前があれば番号を付ける)
      OnBg("libraryMove", a => {
        try {
          var f = S(a, 0);
          var dir = S(a, 1);
          Directory.CreateDirectory(dir);
          if (Library.Same(Path.GetDirectoryName(f), dir)) return new JObj { { "status", "ok" }, { "path", f } };
          var to = Library.Unique(dir, Path.GetFileNameWithoutExtension(f), Path.GetExtension(f));
          File.Move(f, to);
          Versions.Repath(f, to);
          return new JObj { { "status", "ok" }, { "path", to } };
        } catch (Exception e) { return Fail(e); }
      });
      OnBg("libraryFolderPath", a => { var d = Library.FolderPath(S(a, 0)); Directory.CreateDirectory(d); return d; });
      // ファイルを読む (開かない・最近使ったファイルに入れない)。暗号化されていれば中身は返さない
      OnBg("libraryReadText", a => {
        try {
          var f = S(a, 0);
          var info = new FileInfo(f);
          var r = new JObj { { "status", "ok" }, { "size", (double)info.Length }, { "created", (info.CreationTimeUtc - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds },
            { "modified", MTime(f) }, { "locked", (info.Attributes & FileAttributes.ReadOnly) != 0 }, { "mode", Library.FileMode(f) } };
          if (info.Length > 50L * 1024 * 1024) { r["tooLarge"] = true; return r; }
          var buf = File.ReadAllBytes(f);
          if (FileCrypto.IsEncrypted(buf)) { r["encrypted"] = true; return r; }
          var d = Codec.Decode(buf);
          r["text"] = d.Text; r["encoding"] = d.Encoding; r["lineEnding"] = d.LineEnding;
          return r;
        } catch (Exception e) { return Fail(e); }
      });
      // 何も書かないまま閉じた「新規テキスト」を消す (中身が空白だけのときだけ)
      OnBg("libraryRemoveEmpty", a => {
        try {
          var f = S(a, 0);
          if (!Library.IsBlankPlaceholder(f) || !File.Exists(f)) return false;
          var buf = File.ReadAllBytes(f);
          if (buf.Length > 4096 || Codec.Decode(buf).Text.Trim().Length > 0) return false;
          Versions.Forget(new[] { f });
          File.Delete(f);
          var pdf = Path.ChangeExtension(f, ".pdf");
          if (File.Exists(pdf)) File.Delete(pdf);
          return true;
        } catch { return false; }
      });
      // 名前を付けて保存したあとの、元の「新規テキスト」と、横に作った PDF を消す
      OnBg("libraryRemovePlaceholder", a => {
        try {
          var f = S(a, 0);
          if (!Library.IsBlankPlaceholder(f)) return false;
          if (File.Exists(f)) File.Delete(f);
          var pdf = Path.ChangeExtension(f, ".pdf");
          if (File.Exists(pdf)) File.Delete(pdf);
          return true;
        } catch { return false; }
      });
      OnBg("librarySame", a => Library.Same(S(a, 0), S(a, 1)));

      // 版の履歴
      OnBg("versionNoteSaved", a => { Versions.NoteSaved(S(a, 0), B(a, 1)); return true; });
      OnBg("versionNoteOpened", a => { Versions.NoteOpened(S(a, 0)); return true; });
      OnBg("versionFlush", a => { Versions.Flush(S(a, 0) == "" ? null : S(a, 0)); return true; });
      OnBg("versionList", a => Versions.History(S(a, 0)).Select(v => (object)new JObj { { "key", v.Key }, { "date", v.Date * 1000 }, { "message", v.Message } }).ToList());
      OnBg("versionContent", a => {
        var data = Versions.Content(S(a, 0), S(a, 1));
        if (data == null) return null;
        try { var d = Codec.Decode(data); return new JObj { { "text", d.Text }, { "encoding", d.Encoding } }; } catch { return null; }
      });
      OnBg("versionRepath", a => { Versions.Repath(S(a, 0), S(a, 1)); return true; });
      OnBg("versionForget", a => { Versions.Forget(Strings(Arg(a, 0))); return true; });
      OnBg("versionPruneAll", a => { Versions.PruneAll((int)N(a, 0, 100)); return true; });
      On("versionReveal", a => { Directory.CreateDirectory(Versions.Root); System.Diagnostics.Process.Start("explorer.exe", "\"" + Versions.Root + "\""); return true; });

      // バックアップ (.satorubackup)。Mac 版 LibraryBackup.swift と同じ中身 (JSON の Archive をパスワードで暗号化)
      OnBg("backupExport", a => {
        try { return BackupExport(O(a, 0)); } catch (Exception e) { return Fail(e); }
      });
      OnBg("backupOpen", a => {
        try {
          var o = O(a, 0);
          var buf = File.ReadAllBytes(o.Str("path"));
          if (!FileCrypto.IsEncrypted(buf)) return new JObj { { "status", "notBackup" } };
          byte[] plain;
          try { plain = FileCrypto.OpenWithPassword(buf, o.Str("password")).Plain; } catch (FileCrypto.CryptoError) { return new JObj { { "status", "wrong" } }; }
          var arc = Json.TryParse(Encoding.UTF8.GetString(plain)) as JObj;
          if (arc == null || arc.Str("format") != BackupFormat) return new JObj { { "status", "notBackup" } };
          if (arc.Num("version") > BackupVersion) return new JObj { { "status", "newer" } };
          var token = NewToken();
          openedBackups[token] = arc;
          return new JObj { { "status", "ok" }, { "token", token }, { "createdAt", arc.Num("createdAt") * 1000 },
            { "entries", (double)(arc.Arr("entries")?.Count ?? 0) }, { "folders", (double)(arc.Arr("folders")?.Count ?? 0) } };
        } catch (Exception e) { return Fail(e); }
      });
      OnBg("backupRestore", a => {
        try {
          if (!openedBackups.TryRemove(S(a, 0), out var arc)) throw new UserError("もう一度バックアップを選んでください。");
          return BackupRestore(arc, S(a, 1, "ほかの場所から戻したもの"), S(a, 2, "(バックアップ)"), S(a, 3, "(バックアップ {n})"));
        } catch (Exception e) { return Fail(e); }
      });
    }

    static JObj LibraryInfo() => new JObj { { "root", Library.Root }, { "history", Versions.Root }, { "custom", Library.UsesCustom },
      { "name", Path.GetFileName(Library.Root.TrimEnd('\\')) }, { "defaultRoot", Library.DefaultRoot } };

    static string NewToken() => string.Concat(Primitives.Random(12).Select(b => b.ToString("x2")));

    static JObj MoveFolder(string rel, string newRel) {
      if (string.Equals(rel, newRel, StringComparison.Ordinal)) return new JObj { { "status", "ok" }, { "rel", rel }, { "from", Library.FolderPath(rel) }, { "to", Library.FolderPath(rel) } };
      var from = Library.FolderPath(rel);
      var to = Library.FolderPath(newRel);
      if (Directory.Exists(to) || File.Exists(to)) {
        if (!string.Equals(rel, newRel, StringComparison.OrdinalIgnoreCase)) throw new UserError("同じ名前のものがあります。");
      }
      if (string.Equals(rel, newRel, StringComparison.OrdinalIgnoreCase)) {
        // 大文字・小文字だけ変える: いったん別の名前を通す
        var tmp = from + ".rename-" + NewToken();
        Directory.Move(from, tmp);
        Directory.Move(tmp, to);
      } else {
        Directory.Move(from, to);
      }
      Versions.Repath(from, to);
      return new JObj { { "status", "ok" }, { "rel", newRel }, { "from", from }, { "to", to } };
    }

    const string BackupFormat = "satoruEditor.libraryBackup";
    const int BackupVersion = 1;
    static double Secs(DateTime utc) => (utc - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
    static DateTime FromSecs(double s) => new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(s);

    /// o: { path, password, withHistory, pinned: [パス], folderIcons, folderOrder, sharedLinks (JSON の文字列 か null), other: [ほかの場所のパス] }
    JObj BackupExport(JObj o) {
      var root = Library.Norm(Library.Root);
      var pinned = Strings(o["pinned"]);
      bool withHistory = o.Bool("withHistory");
      var entries = new List<object>();
      var folders = new List<object>();
      JObj Entry(string file, string path) {
        var data = File.ReadAllBytes(file);
        var fi = new FileInfo(file);
        var e = new JObj { { "path", path }, { "data", Convert.ToBase64String(data) } };
        var mode = Library.FileMode(file);
        if (mode != null) e["mode"] = mode;
        e["pinned"] = pinned.Any(p => Library.Same(p, file));
        e["locked"] = (fi.Attributes & FileAttributes.ReadOnly) != 0;
        e["created"] = Secs(fi.CreationTimeUtc);
        e["modified"] = Secs(fi.LastWriteTimeUtc);
        if (withHistory) {
          var hist = Versions.Export(file);
          if (hist.Count > 0) e["history"] = hist.Select(h => (object)new JObj { { "date", h.date }, { "message", h.message }, { "data", Convert.ToBase64String(h.data) } }).ToList();
        }
        return e;
      }
      if (Directory.Exists(root)) {
        void Walk(string dir) {
          foreach (var d in Directory.GetDirectories(dir)) {
            var di = new DirectoryInfo(d);
            if (di.Name.StartsWith(".") || (di.Attributes & FileAttributes.Hidden) != 0) continue;
            folders.Add(d.Substring(root.Length + 1).Replace('\\', '/'));
            Walk(d);
          }
          foreach (var f in Directory.GetFiles(dir)) {
            var fi = new FileInfo(f);
            if (fi.Name.StartsWith(".") || (fi.Attributes & FileAttributes.Hidden) != 0) continue;
            if (fi.Extension.Equals(".satorubackup", StringComparison.OrdinalIgnoreCase)) continue;
            try { entries.Add(Entry(f, "folder/" + f.Substring(root.Length + 1).Replace('\\', '/'))); } catch { }
          }
        }
        Walk(root);
      }
      // 一覧に出ている「ほかの場所」のテキスト (同じ名前があれば番号を付ける)
      var used = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
      foreach (var f in Strings(o["other"])) {
        if (!File.Exists(f) || Library.Group(f) != null) continue;
        var name = Path.GetFileName(f);
        for (int n = 2; used.Contains(name); n++) name = Path.GetFileNameWithoutExtension(f) + " " + n + Path.GetExtension(f);
        used.Add(name);
        try { entries.Add(Entry(f, "other/" + name)); } catch { }
      }
      var arc = new JObj {
        { "format", BackupFormat }, { "version", (double)BackupVersion }, { "createdAt", Secs(DateTime.UtcNow) }, { "app", "さとるエディタ" },
        { "entries", entries }, { "folders", folders }, { "folderIcons", o.Obj("folderIcons") ?? new JObj() }, { "folderOrder", o.Arr("folderOrder") ?? new List<object>() },
      };
      if (o["sharedLinks"] is string links && links != "") arc["sharedLinks"] = Convert.ToBase64String(Encoding.UTF8.GetBytes(links));
      var plain = Encoding.UTF8.GetBytes(Json.Stringify(arc));
      var sealedData = FileCrypto.Seal(plain, FileCrypto.DeriveKey(o.Str("password")));
      Store.WriteAtomic(o.Str("path"), sealedData);
      return new JObj { { "status", "ok" }, { "count", (double)entries.Count }, { "size", (double)sealedData.Length } };
    }

    /// 戻すときの場所の中身: "folder/a/b.txt" → "a\b.txt"。外へ出る道すじ (..) や絶対の道すじは受け付けない
    static string SafeRelative(string path, string prefix) {
      if (path == null || !path.StartsWith(prefix + "/")) return null;
      var rel = path.Substring(prefix.Length + 1);
      var parts = rel.Split('/');
      if (rel == "" || parts.Any(p => p == "" || p == "." || p == ".." || p.IndexOfAny(new[] { '\\', ':', '*', '?', '"', '<', '>', '|' }) >= 0)) return null;
      return string.Join("\\", parts);
    }

    JObj BackupRestore(JObj arc, string otherFolder, string bakOne, string bakMany) {
      var root = Library.Root;
      int added = 0, skipped = 0, renamed = 0, failed = 0;
      var pinned = new List<object>();
      foreach (var f in Strings(arc["folders"])) {
        var rel = SafeRelative("folder/" + f, "folder");
        if (rel != null) { try { Directory.CreateDirectory(Path.Combine(root, rel)); } catch { } }
      }
      foreach (var e in (arc.Arr("entries") ?? new List<object>()).OfType<JObj>()) {
        string target;
        var p = e.Str("path");
        var rel = SafeRelative(p, "folder");
        var other = rel == null ? SafeRelative(p, "other") : null;
        if (rel != null) target = Path.Combine(root, rel);
        else if (other != null && !other.Contains("\\")) target = Path.Combine(root, otherFolder, other);
        else { failed++; continue; }
        byte[] data;
        try { data = Convert.FromBase64String(e.Str("data")); } catch { failed++; continue; }
        if (File.Exists(target)) {
          try { if (File.ReadAllBytes(target).SequenceEqual(data)) { skipped++; continue; } } catch { }
          // 中身が違う: 「(バックアップ)」を付けた名前で置く
          var dir = Path.GetDirectoryName(target);
          var baseName = Path.GetFileNameWithoutExtension(target);
          target = Library.Unique(dir, baseName, Path.GetExtension(target), n => baseName + " " + (n == 1 ? bakOne : bakMany.Replace("{n}", n.ToString())));
          renamed++;
        } else {
          added++;
        }
        try {
          Directory.CreateDirectory(Path.GetDirectoryName(target));
          File.WriteAllBytes(target, data);
        } catch { failed++; continue; }
        try {
          if (e["created"] is double c) File.SetCreationTimeUtc(target, FromSecs(c));
          if (e["modified"] is double m) File.SetLastWriteTimeUtc(target, FromSecs(m));
        } catch { }
        if (e["mode"] is string mode) Library.WriteStream(target, Library.ModeStream, mode);
        var hist = (e.Arr("history") ?? new List<object>()).OfType<JObj>()
          .Select(h => { try { return (h.Num("date"), h.Str("message"), Convert.FromBase64String(h.Str("data"))); } catch { return (0.0, "", (byte[])null); } })
          .Where(h => h.Item3 != null).ToList();
        if (hist.Count > 0) { try { Versions.Import(hist, target); } catch (Exception ex) { Log.Error("backup history", ex); } }
        if (e.Bool("pinned")) pinned.Add(target);
        if (e.Bool("locked")) { try { File.SetAttributes(target, File.GetAttributes(target) | FileAttributes.ReadOnly); } catch { } }
      }
      string links = null;
      if (arc["sharedLinks"] is string s && s != "") { try { links = Encoding.UTF8.GetString(Convert.FromBase64String(s)); } catch { } }
      return new JObj {
        { "status", "ok" }, { "added", (double)added }, { "skipped", (double)skipped }, { "renamed", (double)renamed }, { "failed", (double)failed },
        { "pinned", pinned }, { "folderIcons", arc.Obj("folderIcons") ?? new JObj() }, { "folderOrder", arc.Arr("folderOrder") ?? new List<object>() }, { "sharedLinks", links },
      };
    }
  }
}
