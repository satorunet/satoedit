using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;

namespace SatoEdit {
  /// テキストごとの版の記録 (Mac 版 VersionStore.swift と同じ考え方。Mac は git を使うが、Windows では git の要らない自前の置き場)。
  /// 置き場所: %USERPROFILE%\.satoruEditor\history\<履歴の番号>\  (meta.json = いまの場所、index.json = 版の一覧、v\*.dat = 版の中身)。
  /// どのテキストの履歴かは、ファイルの見えない所 (代替データストリーム) に書いた番号で見分ける。
  ///   エクスプローラーで動かしても・名前を変えても番号はついていく。コピーしたもの (番号も写る) は、そこまでの履歴を写して別の番号にする。
  /// テキストをアプリから削除したら、その履歴も消す。暗号化した文書は入れない
  static class Versions {
    public static int Interval = 20; // 自動保存が続くときに版を作る間隔 (秒)
    static readonly object gate = new object();
    static readonly Dictionary<string, Timer> pending = new Dictionary<string, Timer>(StringComparer.OrdinalIgnoreCase);
    static readonly Dictionary<string, DateTime> lastCommit = new Dictionary<string, DateTime>(StringComparer.OrdinalIgnoreCase);

    public static string Root {
      get {
        var o = Environment.GetEnvironmentVariable("SATORU_VERSIONS_DIR");
        return !string.IsNullOrEmpty(o) ? Path.GetFullPath(o) : Store.F("history");
      }
    }
    public static bool IsOn => (!(Store.Prefs["versionHistory"] is bool b) || b) && (!(Store.Prefs["libraryEnabled"] is bool l) || l);
    public static int MaxVersions => Store.Prefs["versionHistoryMax"] is double d && d > 0 ? (int)d : 20;   // 既定は 20 (Mac と同じ)

    static string Dir(string id) => Path.Combine(Root, id);
    static bool ValidId(string id) => id != null && id.Length >= 16 && id.Length <= 32 && id.All(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'));
    static string NewId() => string.Concat(Primitives.Random(16).Select(b => b.ToString("x2")));

    static string MetaPath(string id) {
      var o = Json.TryParse(Store.ReadText(Path.Combine(Dir(id), "meta.json"))) as JObj;
      return o?.Str("path");
    }
    static void WriteMeta(string id, string path) {
      Directory.CreateDirectory(Dir(id));
      Store.WriteAtomic(Path.Combine(Dir(id), "meta.json"), Json.Stringify(new JObj { { "path", path } }));
    }

    public class Version { public string Key; public double Date; public string Message; public string File; }

    static List<Version> Index(string id) {
      var list = Json.TryParse(Store.ReadText(Path.Combine(Dir(id), "index.json"))) as List<object> ?? new List<object>();
      return list.OfType<JObj>().Select(o => new Version { Key = o.Str("file"), File = o.Str("file"), Date = o.Num("date"), Message = o.Str("message") })
        .Where(v => v.File != "" && v.File.IndexOfAny(new[] { '\\', '/', ':' }) < 0).ToList();
    }
    static void WriteIndex(string id, List<Version> list) {
      Store.WriteAtomic(Path.Combine(Dir(id), "index.json"), Json.Pretty(list.Select(v => (object)new JObj { { "date", v.Date }, { "message", v.Message }, { "file", v.File } }).ToList()));
    }

    static string ReadId(string file) {
      var v = Library.ReadStream(file, Library.HistoryStream);
      return ValidId(v) ? v : null;
    }

    /// そのテキストの履歴の番号を決める (gate の中で)。create = なければ作る
    static string Resolve(string file, bool create) {
      var p = Library.Norm(file);
      var id = ReadId(p);
      if (id != null && Directory.Exists(Dir(id))) {
        var m = MetaPath(id);
        if (m != null && Library.Same(m, p)) return id;
        if (m != null && File.Exists(m) && ReadId(m) == id) {
          // コピー: そこまでの履歴を写した、別の番号にする
          if (!create) return id;
          var nid = NewId();
          CopyDir(Dir(id), Dir(nid));
          WriteMeta(nid, p);
          Library.WriteStream(p, Library.HistoryStream, nid);
          return nid;
        }
        WriteMeta(id, p); // 移動・名前の変更 (エクスプローラーでも)
        return id;
      }
      // 番号がない (書けない場所など): 同じ場所の履歴を探す
      if (Directory.Exists(Root)) {
        foreach (var d in Directory.GetDirectories(Root)) {
          var name = Path.GetFileName(d);
          if (!ValidId(name)) continue;
          var m = MetaPath(name);
          if (m != null && Library.Same(m, p)) { Library.WriteStream(p, Library.HistoryStream, name); return name; }
        }
      }
      if (!create) return null;
      var newId = NewId();
      WriteMeta(newId, p);
      Library.WriteStream(p, Library.HistoryStream, newId);
      return newId;
    }

    static void CopyDir(string from, string to) {
      Directory.CreateDirectory(to);
      foreach (var f in Directory.GetFiles(from)) File.Copy(f, Path.Combine(to, Path.GetFileName(f)), true);
      foreach (var d in Directory.GetDirectories(from)) CopyDir(d, Path.Combine(to, Path.GetFileName(d)));
    }

    static bool Excluded(string file) {
      var p = Library.Norm(file);
      if (p.StartsWith(Library.Norm(Root) + "\\", StringComparison.OrdinalIgnoreCase)) return true;
      if (p.StartsWith(Library.Norm(Path.GetTempPath()) + "\\", StringComparison.OrdinalIgnoreCase)) return true;
      try {
        using (var fs = new FileStream(p, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
          var b = new byte[16];
          int n = fs.Read(b, 0, 16);
          Array.Resize(ref b, n);
          return FileCrypto.IsEncrypted(b); // 暗号化した文書は入れない (中身が漏れないように)
        }
      } catch { return true; }
    }

    static double Now() => Math.Floor((DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds);

    /// 今のファイルの中身を記録する (前と同じなら何もしない)
    static void Commit(string file, string message) {
      lock (gate) {
        try {
          if (!File.Exists(file) || Excluded(file)) return;
          var data = File.ReadAllBytes(file);
          if (data.Length > 20000000) return;
          var id = Resolve(file, true);
          if (id != null) CommitData(data, id, message, null);
        } catch (Exception e) { Log.Error("versions", e); }
      }
    }

    static void CommitData(byte[] data, string id, string message, double? date) {
      var list = Index(id);
      var vdir = Path.Combine(Dir(id), "v");
      Directory.CreateDirectory(vdir);
      if (list.Count > 0) {
        var last = Path.Combine(vdir, list[list.Count - 1].File);
        if (File.Exists(last) && File.ReadAllBytes(last).SequenceEqual(data)) return;
      }
      var t = date ?? Now();
      // 名前: 時刻 + 番号 (同じ秒に 2 つ作っても重ならない)
      var name = ((long)t).ToString("D12") + "-" + NewId().Substring(0, 8) + ".dat";
      File.WriteAllBytes(Path.Combine(vdir, name), data);
      list.Add(new Version { File = name, Key = name, Date = t, Message = message });
      // 自動の記録は、上限を少し超えたら古いものを消す (10 個ぶんまとめて)
      WriteIndex(id, date == null ? Prune(id, list, MaxVersions, 10) : list);
    }

    static List<Version> Prune(string id, List<Version> list, int keep, int slack) {
      if (list.Count <= keep + slack) return list;
      var drop = list.Take(list.Count - keep).ToList();
      foreach (var v in drop) { try { File.Delete(Path.Combine(Dir(id), "v", v.File)); } catch { } }
      return list.Skip(list.Count - keep).ToList();
    }

    /// 保存したら: 前の版から 20 秒たっていればすぐ版を作る。たっていなければ、その時刻に (そのあいだの保存をまとめて) 1 つ作る
    public static void NoteSaved(string file, bool now) {
      if (!IsOn || string.IsNullOrEmpty(file)) return;
      var k = Library.Norm(file);
      lock (pending) {
        var since = (DateTime.UtcNow - (lastCommit.TryGetValue(k, out var lc) ? lc : DateTime.MinValue)).TotalSeconds;
        if (!now && since < Interval && pending.ContainsKey(k)) return; // もう予約してある
        if (pending.TryGetValue(k, out var old)) { old.Dispose(); pending.Remove(k); }
        var wait = now || since >= Interval ? 0 : (int)((Interval - since) * 1000);
        Timer timer = null;
        timer = new Timer(_ => {
          lock (pending) { if (pending.TryGetValue(k, out var cur) && cur == timer) pending.Remove(k); lastCommit[k] = DateTime.UtcNow; }
          timer?.Dispose();
          Commit(k, "保存: " + Path.GetFileName(k));
        }, null, Timeout.Infinite, Timeout.Infinite);
        pending[k] = timer;
        if (wait == 0) {
          pending.Remove(k);
          lastCommit[k] = DateTime.UtcNow;
          timer.Dispose();
          System.Threading.Tasks.Task.Run(() => Commit(k, "保存: " + Path.GetFileName(k)));
        } else {
          timer.Change(wait, Timeout.Infinite);
        }
      }
    }

    /// 待っている記録を、いますぐ済ませる (閉じるとき・アプリを終えるとき)。file を省くと全部
    public static void Flush(string file = null) {
      List<string> keys;
      lock (pending) {
        keys = pending.Keys.Where(k => file == null || Library.Same(k, file)).ToList();
        foreach (var k in keys) { pending[k].Dispose(); pending.Remove(k); lastCommit[k] = DateTime.UtcNow; }
      }
      foreach (var k in keys) Commit(k, "保存: " + Path.GetFileName(k));
    }

    /// 開いたとき: まだ版がないテキストなら、開いたときの中身を最初の版として残す
    public static void NoteOpened(string file) {
      if (!IsOn || string.IsNullOrEmpty(file)) return;
      lock (gate) {
        try {
          if (!File.Exists(file) || Excluded(file)) return;
          var id = Resolve(file, true);
          if (id == null || Index(id).Count > 0) return;
          var data = File.ReadAllBytes(file);
          if (data.Length <= 20000000) CommitData(data, id, "開いたときの中身: " + Path.GetFileName(file), null);
        } catch (Exception e) { Log.Error("versions", e); }
      }
    }

    /// そのテキストの版 (新しい順)
    public static List<Version> History(string file) {
      lock (gate) {
        var id = File.Exists(file) ? Resolve(file, false) : null;
        if (id == null) return new List<Version>();
        var list = Index(id);
        list.Reverse();
        return list;
      }
    }

    public static byte[] Content(string file, string key) {
      lock (gate) {
        var id = Resolve(file, false);
        if (id == null || string.IsNullOrEmpty(key) || key.IndexOfAny(new[] { '\\', '/', ':' }) >= 0) return null;
        var f = Path.Combine(Dir(id), "v", key);
        return File.Exists(f) ? File.ReadAllBytes(f) : null;
      }
    }

    /// アプリの中で名前や場所を変えた: 履歴の場所を付け替える (フォルダなら中のテキストすべて)
    public static void Repath(string oldPath, string newPath) {
      lock (gate) {
        if (!Directory.Exists(Root)) return;
        var o = Library.Norm(oldPath);
        var n = Library.Norm(newPath);
        foreach (var d in Directory.GetDirectories(Root)) {
          var id = Path.GetFileName(d);
          if (!ValidId(id)) continue;
          var m = MetaPath(id);
          if (m == null) continue;
          var mm = Library.Norm(m);
          if (string.Equals(mm, o, StringComparison.OrdinalIgnoreCase)) WriteMeta(id, n);
          else if (mm.StartsWith(o + "\\", StringComparison.OrdinalIgnoreCase)) WriteMeta(id, n + mm.Substring(o.Length));
        }
      }
    }

    /// テキスト (またはフォルダ) を削除する: その履歴も消す。消す前に呼ぶ
    public static void Forget(IEnumerable<string> paths) {
      lock (gate) {
        var ids = new HashSet<string>();
        var plain = new List<string>();
        foreach (var p0 in paths) {
          var p = Library.Norm(p0);
          if (Directory.Exists(p)) {
            try { foreach (var f in Directory.GetFiles(p, "*", SearchOption.AllDirectories)) { var id = ReadId(f); if (id != null) ids.Add(id); } } catch { }
            plain.Add(p + "\\");
          } else {
            var id = ReadId(p);
            if (id != null) ids.Add(id);
            plain.Add(p);
          }
        }
        if (!Directory.Exists(Root)) return;
        foreach (var d in Directory.GetDirectories(Root)) {
          var id = Path.GetFileName(d);
          if (!ValidId(id)) continue;
          var m = MetaPath(id);
          if (m == null) continue;
          var mm = Library.Norm(m);
          if (plain.Any(x => x.EndsWith("\\") ? mm.StartsWith(x, StringComparison.OrdinalIgnoreCase) : string.Equals(mm, x, StringComparison.OrdinalIgnoreCase))) ids.Add(id);
        }
        foreach (var id in ids) { try { Directory.Delete(Dir(id), true); } catch { } }
      }
    }

    /// 上限を変えたとき: すべての履歴を新しい上限まで減らす
    public static void PruneAll(int keep) {
      lock (gate) {
        if (!Directory.Exists(Root)) return;
        foreach (var d in Directory.GetDirectories(Root)) {
          var id = Path.GetFileName(d);
          if (!ValidId(id)) continue;
          var list = Index(id);
          if (list.Count > keep) WriteIndex(id, Prune(id, list, keep, 0));
        }
      }
    }

    // ---------- バックアップ ----------

    /// そのテキストの版すべて (古い順): [{ date (1970 からの秒), message, data }]
    public static List<(double date, string message, byte[] data)> Export(string file) {
      var outl = new List<(double, string, byte[])>();
      lock (gate) {
        var id = File.Exists(file) ? Resolve(file, false) : null;
        if (id == null) return outl;
        foreach (var v in Index(id)) {
          var f = Path.Combine(Dir(id), "v", v.File);
          if (File.Exists(f)) outl.Add((v.Date, v.Message, File.ReadAllBytes(f)));
        }
      }
      return outl;
    }

    /// バックアップから戻した: 版を古い順に入れ直す (日時もそのまま)。戻したファイルは新しい番号にする
    public static void Import(List<(double date, string message, byte[] data)> versions, string file) {
      if (versions.Count == 0) return;
      lock (gate) {
        var id = NewId();
        WriteMeta(id, Library.Norm(file));
        Library.WriteStream(file, Library.HistoryStream, id);
        foreach (var v in versions) CommitData(v.data, id, v.message, v.date);
        var list = Index(id);
        if (list.Count > MaxVersions) WriteIndex(id, Prune(id, list, MaxVersions, 0));
      }
    }
  }
}
