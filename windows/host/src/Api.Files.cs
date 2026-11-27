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
      // 巨大なファイル: 読んでいる範囲の近くを読み直す (スクロールで端に近づいたとき・位置へ移動)
      OnBg("hugeSlide", a => {
        try { return HugeSlide(S(a, 0), O(a, 1)); } catch (Exception e) { return Fail(e); }
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
      var r = ReadHugeDocument(file, opts) ?? DecodeDocument(File.ReadAllBytes(file), opts, file);
      if (r.Str("status") != "ok") return r;
      AddRecent(file);
      r["path"] = file;
      r["mode"] = Library.FileMode(file);
      r["locked"] = (File.GetAttributes(file) & FileAttributes.ReadOnly) != 0;
      r["mtime"] = MTime(file);
      return r;
    }

    // ---------- 巨大なファイル (Mac 版 HugeFileWindow.swift と同じ考え方) ----------
    // 大きなファイルは全部は読まず、先頭の近く (はじめは 8 MB) だけを読んで、すぐに開く。
    // スクロールで読んだ範囲の端に近づいたら、今見ている行のまわりを読み直す (画面側 app.js の huge*)。保存すると、その範囲だけをファイルに書き戻す

    static long MB(string key, double fallback) => (long)(Store.Prefs.Num(key, fallback) * 1048576);
    static long HugeThreshold => Math.Max(0, MB("hugeFileMB", 32));
    static long HugeWindow => Math.Max(1L << 20, MB("hugeWindowMB", 8));

    static JObj PartObj(PartialFile.Part p) => new JObj { { "offset", (double)p.Offset }, { "length", (double)p.Length }, { "fileSize", (double)p.FileSize } };
    static PartialFile.Part PartOf(JObj o) => new PartialFile.Part((long)o.Num("offset"), (long)o.Num("length"), (long)o.Num("fileSize"));

    /// 大きなファイルなら一部分だけ読む。全部読むもの (小さい・暗号化・画像・UTF-16・「全部読む」) は null
    JObj ReadHugeDocument(string file, JObj opts) {
      var want = opts.Obj("part");
      if (want == null) {
        long size = new FileInfo(file).Length;
        if (opts.Bool("whole") || HugeThreshold <= 0 || size < HugeThreshold) return null;
        var head = PartialFile.Head(file, 64 * 1024);
        if (FileCrypto.IsEncrypted(head) || Binary.ImageType(file) != null) return null;
      }
      var part = want != null ? PartialFile.Align(file, (long)want.Num("offset"), Math.Max(1, (long)want.Num("length"))) : PartialFile.Align(file, 0, HugeWindow);
      var data = PartialFile.Read(file, part);
      if (!opts.Bool("forceText") && Binary.LooksBinary(data)) {
        // バイナリは、見るだけの画面で先頭の 16 MB だけを出す
        var hex = PartialFile.Read(file, new PartialFile.Part(0, Math.Min(16L << 20, part.FileSize), part.FileSize));
        return new JObj { { "status", "viewer" }, { "kind", "hex" }, { "base64", Convert.ToBase64String(hex) }, { "size", (double)part.FileSize }, { "truncated", part.FileSize > hex.Length } };
      }
      var enc = opts.Str("encoding");
      var d = Codec.Decode(data, enc == "" ? null : enc);
      if (d.Encoding.StartsWith("utf16")) return null; // 行の切れ目 (LF のバイト) で切れないので、全部読む
      return new JObj { { "status", "ok" }, { "text", d.Text }, { "encoding", d.Encoding }, { "lineEnding", d.LineEnding }, { "enc", null }, { "partial", PartObj(part) } };
    }

    /// 読み直す: o = { part (今の範囲), topLine (今いちばん上に見えている行。範囲の中の 0 始まり), back (新しい範囲で、その行より前に置く割合 0〜1),
    ///   fraction (位置へ移動のとき: ファイル全体の 0〜1), encoding }
    /// → { status, text, partial, line (今の行が新しい範囲の何行目か) }
    JObj HugeSlide(string file, JObj o) {
      var cur = PartOf(o.Obj("part") ?? new JObj());
      long size = new FileInfo(file).Length, w = HugeWindow;
      long anchor;
      if (o.Has("fraction")) {
        anchor = (long)(size * Math.Max(0, Math.Min(1, o.Num("fraction"))));
      } else {
        // 今の範囲の topLine 行目の行頭の、ファイルの中の位置
        var data = PartialFile.Read(file, cur);
        anchor = cur.Offset + PartialFile.LineStart(data, (int)o.Num("topLine"));
      }
      long back = (long)(w * Math.Max(0, Math.Min(1, o.Num("back", 0.5))));
      var part = PartialFile.Align(file, Math.Max(0, anchor - back), w);
      // 行の頭にそろえたので、anchor が範囲より前になることがある (1 行がとても長いとき)
      if (anchor < part.Offset) anchor = part.Offset;
      var bytes = PartialFile.Read(file, part);
      var enc = o.Str("encoding");
      var d = Codec.Decode(bytes, enc == "" ? null : enc);
      return new JObj { { "status", "ok" }, { "text", d.Text }, { "encoding", d.Encoding }, { "lineEnding", d.LineEnding },
        { "partial", PartObj(part) }, { "line", (double)PartialFile.LinesBefore(bytes, anchor - part.Offset) } };
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
      // 巨大なファイルの一部分だけを読んでいるとき: その範囲だけを差し替える (前後はファイルのまま)
      if (o.Obj("part") is JObj pj && File.Exists(path)) {
        var part = PartOf(pj);
        var info = Codec.EncodingInfo(o.Str("encoding", "utf8"));
        if (part.Offset > 0 && info.Bom != null && info.Bom.Length > 0 && body.Length >= info.Bom.Length && body.Take(info.Bom.Length).SequenceEqual(info.Bom)) body = body.Skip(info.Bom.Length).ToArray(); // BOM は先頭にだけ
        var tmp = path + ".part-" + System.Diagnostics.Process.GetCurrentProcess().Id;
        try {
          PartialFile.Write(path, part, body, tmp);
          Win32.ReplaceFile(tmp, path);
        } catch { try { File.Delete(tmp); } catch { } throw; }
        if (mode != null) Library.WriteStream(path, Library.ModeStream, mode);
        if (history != null) Library.WriteStream(path, Library.HistoryStream, history);
        AddRecent(path);
        var size = new FileInfo(path).Length;
        return new JObj { { "status", "ok" }, { "mtime", MTime(path) }, { "partial", PartObj(new PartialFile.Part(part.Offset, body.Length, size)) } };
      }
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
