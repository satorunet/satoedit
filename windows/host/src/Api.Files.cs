using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

namespace SatoEdit {
  /// ファイルの読み書き・フォルダツリー・grep
  partial class Bridge {
    static readonly StringComparer JaOrder = StringComparer.Create(new CultureInfo("ja-JP"), false);
    readonly ConcurrentDictionary<string, bool> grepJobs = new ConcurrentDictionary<string, bool>();

    static double MTime(string file) => (File.GetLastWriteTimeUtc(file) - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;

    void RegisterFiles() {
      OnBg("readFile", a => {
        var file = S(a, 0);
        try { return ReadDocument(file, O(a, 1)); } catch (Exception e) { return Fail(e); }
      });
      OnBg("writeFile", a => {
        try { return WriteDocument(O(a, 0)); } catch (Exception e) { return Fail(e); }
      });
      OnBg("fileInfo", a => {
        var f = S(a, 0);
        try {
          if (!File.Exists(f)) return new JObj { { "exists", false } };
          return new JObj { { "exists", true }, { "mtime", MTime(f) }, { "size", (double)new FileInfo(f).Length } };
        } catch { return new JObj { { "exists", false } }; }
      });
      On("clearRecent", a => {
        Store.Prefs["recent"] = new List<object>();
        Store.SavePrefsSoon();
        Win32.ClearRecentDocuments();
        Send("__recent", Store.Prefs["recent"]);
        return true;
      });
      OnBg("readBytes", a => Convert.ToBase64String(File.ReadAllBytes(S(a, 0))));

      // フォルダツリー
      OnBg("listDir", a => {
        try {
          var di = new DirectoryInfo(S(a, 0));
          return di.GetFileSystemInfos()
            .Where(e => !e.Name.StartsWith("."))
            .Select(e => new { e.Name, Dir = (e.Attributes & FileAttributes.Directory) != 0 })
            .OrderBy(e => e.Dir ? 0 : 1).ThenBy(e => e.Name, JaOrder)
            .Select(e => (object)new JObj { { "name", e.Name }, { "dir", e.Dir } }).ToList();
        } catch { return new List<object>(); }
      });
      OnBg("findFiles", a => {
        var q = S(a, 1).ToLowerInvariant();
        var outl = new List<object>();
        bool truncated = false;
        foreach (var f in Grep.Files(S(a, 0), true)) {
          if (!Path.GetFileName(f).ToLowerInvariant().Contains(q)) continue;
          if (outl.Count >= 500) { truncated = true; break; }
          outl.Add(f);
        }
        return new JObj { { "files", outl }, { "truncated", truncated } };
      });
      OnBg("createEntry", a => {
        try {
          var name = S(a, 1);
          CheckName(name);
          var full = Path.Combine(S(a, 0), name);
          if (File.Exists(full) || Directory.Exists(full)) throw new UserError("同じ名前のものがあります。");
          if (B(a, 2)) Directory.CreateDirectory(full);
          else using (new FileStream(full, FileMode.CreateNew)) { }
          return new JObj { { "status", "ok" }, { "path", full } };
        } catch (Exception e) { return Fail(e); }
      });
      OnBg("renameEntry", a => {
        try {
          var file = S(a, 0);
          var name = S(a, 1);
          CheckName(name);
          var to = Path.Combine(Path.GetDirectoryName(file), name);
          bool sameName = string.Equals(to, file, StringComparison.OrdinalIgnoreCase);
          if (!sameName && (File.Exists(to) || Directory.Exists(to))) throw new UserError("同じ名前のものがあります。");
          if (Directory.Exists(file)) Directory.Move(file, to); else File.Move(file, to);
          return new JObj { { "status", "ok" }, { "path", to } };
        } catch (Exception e) { return Fail(e); }
      });
      On("trashEntry", a => {
        try { Win32.Trash(S(a, 0)); return new JObj { { "status", "ok" } }; } catch (Exception e) { return Fail(e); }
      });

      // grep (見つけたものは 200 件ずつ送る)
      On("grepStart", a => {
        var id = Arg(a, 0);
        var key = Json.Stringify(id);
        var root = S(a, 1);
        var o = O(a, 2);
        grepJobs[key] = false;
        Task.Run(() => {
          var batch = new List<object>();
          void Flush() { if (batch.Count > 0) { Send("grep:matches", id, batch); batch = new List<object>(); } }
          try {
            var r = Grep.Search(root, o.Str("pattern"), o.Bool("useRegex"), o.Bool("caseSensitive"), o.Str("fileMask"), !(o["recursive"] is bool rec) || rec,
              (int)o.Num("maxResults"), m => {
                batch.Add(new JObj { { "file", m.File }, { "line", (double)m.Line }, { "text", m.Text } });
                if (batch.Count >= 200) Flush();
              }, () => grepJobs.TryGetValue(key, out var c) && c);
            Flush();
            Send("grep:done", id, new JObj { { "cancelled", grepJobs.TryGetValue(key, out var c2) && c2 }, { "count", (double)r.Count }, { "scanned", (double)r.Scanned }, { "truncated", r.Truncated } });
          } catch (Exception e) {
            Flush();
            Send("grep:done", id, new JObj { { "error", e.Message } });
          } finally {
            grepJobs.TryRemove(key, out _);
          }
        });
        return true;
      });
      On("grepCancel", a => { var key = Json.Stringify(Arg(a, 0)); if (grepJobs.ContainsKey(key)) grepJobs[key] = true; return true; });
    }

    static void CheckName(string name) {
      if (string.IsNullOrEmpty(name) || name.IndexOfAny(new[] { '\\', '/', ':', '*', '?', '"', '<', '>', '|' }) >= 0) throw new UserError("使えない文字が入っています。");
    }

    void AddRecent(string file) {
      var list = (Store.Prefs.Arr("recent") ?? new List<object>()).OfType<string>().Where(f => f != file).ToList();
      list.Insert(0, file);
      Store.Prefs["recent"] = list.Take(12).Cast<object>().ToList();
      Store.SavePrefsSoon();
      Win32.AddRecentDocument(file);
      Send("__recent", Store.Prefs["recent"]);
    }

    /// ファイルの中身 (バイト列) → 文章。暗号化されていれば鍵を使って開く
    JObj DecodeDocument(byte[] buf, JObj opts, string name) {
      // 画像やバイナリは、エディタではなく見るだけの画面で開く (「テキストとして開く」を選んだときは文字として)
      if (!opts.Bool("forceText") && !FileCrypto.IsEncrypted(buf)) {
        var mime = Binary.ImageType(name);
        if (mime != null && buf.Length <= 50 * 1024 * 1024) return new JObj { { "status", "viewer" }, { "kind", "image" }, { "mime", mime }, { "base64", Convert.ToBase64String(buf) }, { "size", (double)buf.Length } };
        if (Binary.LooksBinary(buf)) {
          const int max = 16 * 1024 * 1024;
          return new JObj { { "status", "viewer" }, { "kind", "hex" }, { "base64", Convert.ToBase64String(buf, 0, Math.Min(max, buf.Length)) }, { "size", (double)buf.Length }, { "truncated", buf.Length > max } };
        }
      }
      var body = buf;
      object enc = null;
      if (FileCrypto.IsEncrypted(buf)) {
        var r = Unlock(buf, opts.Obj("creds") ?? new JObj());
        if (r.Need != null) return new JObj { { "status", "locked" }, { "need", r.Need }, { "kind", FileCrypto.ReadHeader(buf).Kind } };
        body = r.Plain;
        enc = EncInfo(r.Key);
      }
      var d = Codec.Decode(body, opts.Str("encoding") == "" ? null : opts.Str("encoding"));
      return new JObj { { "status", "ok" }, { "text", d.Text }, { "encoding", d.Encoding }, { "lineEnding", d.LineEnding }, { "enc", enc } };
    }

    JObj ReadDocument(string file, JObj opts) {
      var r = DecodeDocument(File.ReadAllBytes(file), opts, file);
      if (r.Str("status") != "ok") return r;
      AddRecent(file);
      r["path"] = file;
      r["mode"] = Library.FileMode(file);
      r["locked"] = (File.GetAttributes(file) & FileAttributes.ReadOnly) != 0;
      r["mtime"] = MTime(file);
      return r;
    }

    /// 文章 → ファイルに書く中身 (文字コードを変換し、鍵があれば暗号化する)
    byte[] EncodeDocument(JObj o) {
      var body = Codec.Encode(o.Str("text"), o.Str("encoding", "utf8"), o.Str("lineEnding", "lf"));
      var token = o.Str("encToken");
      if (token != "") {
        if (!keys.TryGetValue(token, out var key)) throw new UserError("暗号化の鍵が見つかりません。もう一度「暗号化して保存…」を選んでください。");
        body = FileCrypto.Seal(body, key);
      }
      return body;
    }

    JObj WriteDocument(JObj o) {
      var body = EncodeDocument(o);
      var path = o.Str("path");
      // ロックした (読み取り専用の) ファイルは書き換えない
      if (File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReadOnly) != 0) throw new UserError("ロックしているので保存できません。テキスト一覧の右クリックで「ロックを外す」を選んでください。", "locked");
      if (o.Bool("backup") && File.Exists(path)) {
        try { File.Copy(path, path + ".bak", true); } catch { } // バックアップが作れなくても保存はする
      }
      // 置き換えて書くと、見えない所 (表示・版の履歴の番号) が消えるので、書き直す
      var mode = o.Has("mode") ? o["mode"] as string : Library.FileMode(path);
      var history = Library.ReadStream(path, Library.HistoryStream);
      Store.WriteAtomic(path, body);
      if (mode != null) Library.WriteStream(path, Library.ModeStream, mode);
      if (history != null) Library.WriteStream(path, Library.HistoryStream, history);
      AddRecent(path);
      // 版の記録 (暗号化した文書は入れない)。Ctrl+S・閉じるときはすぐ、自動保存は 20 秒ごとにまとめて
      if (o.Str("encToken") == "" && !o.Bool("noVersion")) Versions.NoteSaved(path, o.Bool("versionNow"));
      return new JObj { { "status", "ok" }, { "mtime", MTime(path) } };
    }
  }
}
