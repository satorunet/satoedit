using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace SatoEdit {
  /// ふりがな (Windows の日本語入力に読みを聞く)・関連付けと右クリックメニュー
  partial class Bridge {
    void RegisterTools() {
      OnAsync("furigana", a => Furigana.WordsAsync(S(a, 0)).ContinueWith(t => (object)t.Result));
      On("assocStatus", a => Assoc.Status());
      OnBg("assocApply", a => {
        var o = O(a, 0);
        var labels = o.Obj("labels") ?? new JObj();
        var r = Assoc.Apply(System.Reflection.Assembly.GetExecutingAssembly().Location, (o.Arr("extensions") ?? new List<object>()).Select(x => Convert.ToString(x)).ToList(),
          o.Bool("fileMenu"), o.Bool("folderMenu"), labels.Str("open", "さとるエディタで開く"), labels.Str("grep", "さとるエディタで grep"));
        return r == "" ? new JObj { { "status", "ok" } } : new JObj { { "status", "error" }, { "message", r } };
      });
    }
  }

  /// 自動ふりがな: 文章を Windows の日本語入力 (MS-IME) に渡して、単語ごとの読みを聞く。
  /// 読みは IME の辞書まかせなので、人名などは外れることがある。送りがなを分けるのは画面側 (host.js)
  static class Furigana {
    [ComImport, Guid("019F7152-E6DB-11d0-83C3-00C04FDDB82E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IFELanguage {
      [PreserveSig] int Open();
      [PreserveSig] int Close();
      [PreserveSig] int GetJMorphResult(uint dwRequest, uint dwCMode, int cwchInput, [MarshalAs(UnmanagedType.LPWStr)] string pwchInput, IntPtr pfCInfo, out IntPtr ppResult);
      [PreserveSig] int GetConversionModeCaps(out uint pdwCaps);
      [PreserveSig] int GetPhonetic([MarshalAs(UnmanagedType.BStr)] string str, int start, int length, [MarshalAs(UnmanagedType.BStr)] out string result);
      [PreserveSig] int GetConversion([MarshalAs(UnmanagedType.BStr)] string str, int start, int length, [MarshalAs(UnmanagedType.BStr)] out string result);
    }

    const uint FELANG_REQ_REV = 0x00030000;
    const uint FELANG_CMODE_HIRAGANAOUT = 0x0;
    const uint FELANG_CMODE_NOINVISIBLECHAR = 0x40000000;
    const uint FELANG_CMODE_PRECONV = 0x00000200;

    static IFELanguage ime;
    static bool loggedOnce;
    static bool tried;
    static readonly Regex Kanji = new Regex("[㐀-䶿一-鿿豈-﫿々〆ヵヶ]");

    static IFELanguage Ime() {
      if (tried) return ime;
      tried = true;
      try {
        Log.Write("furigana: opening IME");
        var type = Type.GetTypeFromProgID("MSIME.Japan");
        if (type == null) return null;
        var o = (IFELanguage)Activator.CreateInstance(type);
        if (o.Open() != 0) return null;
        ime = o;
        Log.Write("furigana: IME ready");
      } catch (Exception e) { Log.Error("ime", e); }
      return ime;
    }

    public static bool Available => Ime() != null;

    // IME は専用のスレッド (STA) で呼ぶ。固まっても画面は止めない
    static System.Threading.Thread worker;
    static readonly System.Collections.Concurrent.BlockingCollection<Action> queue = new System.Collections.Concurrent.BlockingCollection<Action>();
    static bool hung;

    public static async Task<List<object>> WordsAsync(string text) {
      if (hung) return new List<object>();
      if (worker == null) {
        worker = new System.Threading.Thread(() => { foreach (var job in queue.GetConsumingEnumerable()) job(); }) { IsBackground = true, Name = "ime" };
        worker.SetApartmentState(System.Threading.ApartmentState.STA);
        worker.Start();
      }
      var tcs = new TaskCompletionSource<List<object>>();
      queue.Add(() => { try { tcs.TrySetResult(Words(text)); } catch (Exception e) { tcs.TrySetException(e); } });
      var limit = Task.Delay(Math.Max(15000, text.Length * 5));
      if (await Task.WhenAny(tcs.Task, limit) != tcs.Task) {
        hung = true;
        Log.Write("furigana: IME did not answer");
        return new List<object>();
      }
      return await tcs.Task;
    }

    /// 文章 → [{ at, surface, reading }] (at は文章の先頭からの位置。漢字を含む単語だけ)
    public static List<object> Words(string text) {
      var outl = new List<object>();
      var fe = Ime();
      if (fe == null) return outl;
      int baseAt = 0;
      foreach (var line in text.Split('\n')) {
        if (line.Length <= 20000 && Kanji.IsMatch(line)) {
          // IME には短く区切って渡す (句読点や空白で区切る)
          foreach (Match m in Regex.Matches(line, @"[^。、！？!?\s　「」『』（）()]{1,120}")) {
            if (!Kanji.IsMatch(m.Value)) continue;
            foreach (var w in Morph(fe, m.Value)) {
              w["at"] = (double)(baseAt + m.Index + (int)(double)w["at"]);
              outl.Add(w);
            }
          }
        }
        baseAt += line.Length + 1;
      }
      return outl;
    }

    /// GetJMorphResult (逆変換) の結果から、単語の表記と読みを取り出す
    static List<JObj> Morph(IFELanguage fe, string input) {
      var outl = new List<JObj>();
      IntPtr res = IntPtr.Zero;
      try {
        if (!loggedOnce) { loggedOnce = true; Log.Write("furigana: calling IME"); }
        if (fe.GetJMorphResult(FELANG_REQ_REV, FELANG_CMODE_HIRAGANAOUT | FELANG_CMODE_NOINVISIBLECHAR | FELANG_CMODE_PRECONV, input.Length, input, IntPtr.Zero, out res) != 0 || res == IntPtr.Zero) return outl;
        // MORRSLT の並び: 結果はひとかたまりのメモリ (先頭から dwSize バイト) なので、指す先がその中に収まる並び方を選ぶ
        // (64 ビットの普通の並び、または 1 バイト詰め)
        long start = res.ToInt64();
        int size = Marshal.ReadInt32(res, 0);
        if (size < 32 || size > 16 * 1024 * 1024) return outl;
        bool InBlock(IntPtr p, int bytes) => p != IntPtr.Zero && p.ToInt64() >= start && p.ToInt64() + bytes <= start + size;
        int[][] layouts = { new[] { 8, 16, 24, 32, 72, 80 }, new[] { 4, 12, 14, 22, 56, 64 } };
        int[] L = null;
        foreach (var l in layouts) {
          if (l[5] + 4 > size) continue;
          var po = Marshal.ReadIntPtr(res, l[0]);
          int co = (ushort)Marshal.ReadInt16(res, l[1]);
          var pw = Marshal.ReadIntPtr(res, l[4]);
          int cw = Marshal.ReadInt32(res, l[5]);
          if (InBlock(po, co * 2) && cw >= 0 && cw < 10000 && (cw == 0 || InBlock(pw, cw * 24))) { L = l; break; }
        }
        if (L == null) { Log.Write("furigana: unknown MORRSLT layout, size " + size); return outl; }
        var pOut = Marshal.ReadIntPtr(res, L[0]);
        int cchOut = (ushort)Marshal.ReadInt16(res, L[1]);
        var pRead = Marshal.ReadIntPtr(res, L[2]);
        int cchRead = (ushort)Marshal.ReadInt16(res, L[3]);
        var pWdd = Marshal.ReadIntPtr(res, L[4]);
        int cWdd = Marshal.ReadInt32(res, L[5]);
        var output = Marshal.PtrToStringUni(pOut, cchOut);
        var read = InBlock(pRead, cchRead * 2) ? Marshal.PtrToStringUni(pRead, cchRead) : input;
        // 逆変換では、出力 (Disp) が読み、Read が入力の表記
        for (int i = 0; i < cWdd; i++) {
          var p = pWdd + i * 24;
          int dispPos = (ushort)Marshal.ReadInt16(p, 0), readPos = (ushort)Marshal.ReadInt16(p, 2), cchDisp = (ushort)Marshal.ReadInt16(p, 4), cchR = (ushort)Marshal.ReadInt16(p, 6);
          if (readPos + cchR > read.Length || dispPos + cchDisp > output.Length) continue;
          var surface = read.Substring(readPos, cchR);
          var reading = output.Substring(dispPos, cchDisp);
          int at = input.IndexOf(surface, Math.Min(readPos, input.Length), StringComparison.Ordinal);
          if (at < 0) at = input.IndexOf(surface, StringComparison.Ordinal);
          if (at < 0 || !Kanji.IsMatch(surface) || reading == surface) continue;
          outl.Add(new JObj { { "at", (double)at }, { "surface", surface }, { "reading", reading } });
        }
      } catch (Exception e) {
        Log.Error("furigana", e);
      } finally {
        if (res != IntPtr.Zero) Marshal.FreeCoTaskMem(res);
      }
      return outl;
    }
  }

  /// Windows の関連付けと、エクスプローラーの右クリックメニュー (core/winassoc.js と同じ)。
  /// どれも「いまのユーザー」の設定 (HKEY_CURRENT_USER) だけを書き換えるので、管理者の権限は要らず、外せば元に戻る
  static class Assoc {
    const string Classes = @"Software\Classes";
    // レジストリの中の名前は画面に出ない。前の版で登録したものを消せるよう、そのままにしておく
    const string ProgId = "satoEdit.Document";
    static readonly List<object> Defaults = new List<object> { "txt", "log", "md", "ini", "csv", "json", "xml", "html", "htm", "css", "js", "ts", "py", "c", "cpp", "h", "cs", "java", "php", "rb", "go", "rs", "sql", "bat", "ps1", "yml", "yaml", "sh" };

    static List<string> Clean(IEnumerable<string> list) =>
      list.Select(e => Regex.Replace((e ?? "").Trim().ToLowerInvariant(), @"^\*?\.", "")).Where(e => Regex.IsMatch(e, "^[a-z0-9_+-]{1,16}$")).Distinct().ToList();

    static bool Exists(string key) { using (var k = Registry.CurrentUser.OpenSubKey(key)) return k != null; }

    public static JObj Status() {
      var exts = new List<string>();
      using (var k = Registry.CurrentUser.OpenSubKey(Classes + "\\" + ProgId)) {
        if (k?.GetValue("Extensions") is string s) exts = Clean(Regex.Split(s, @"\s+"));
      }
      return new JObj {
        { "supported", true }, { "defaults", Defaults }, { "extensions", exts.Cast<object>().ToList() },
        { "fileMenu", Exists(Classes + @"\*\shell\satoEdit") }, { "folderMenu", Exists(Classes + @"\Directory\shell\satoEditGrep") },
      };
    }

    static void Set(string key, string name, string value) {
      using (var k = Registry.CurrentUser.CreateSubKey(key)) k.SetValue(name ?? "", value, RegistryValueKind.String);
    }
    static void Remove(string key) { try { Registry.CurrentUser.DeleteSubKeyTree(key, false); } catch { } }

    /// → 失敗したものの名前 (なければ "")
    public static string Apply(string exe, List<string> extensions, bool fileMenu, bool folderMenu, string openLabel, string grepLabel) {
      var failures = new List<string>();
      void Must(Action fn, string what) { try { fn(); } catch { failures.Add(what); } }
      var before = ((List<object>)Status()["extensions"]).Cast<string>().ToList();
      var exts = Clean(extensions);
      foreach (var e in before.Where(x => !exts.Contains(x))) {
        try { using (var k = Registry.CurrentUser.OpenSubKey(Classes + "\\." + e + "\\OpenWithProgids", true)) k?.DeleteValue(ProgId, false); } catch { }
      }
      if (exts.Count > 0) {
        Must(() => Set(Classes + "\\" + ProgId, null, "さとるエディタ"), "ProgID");
        Must(() => Set(Classes + "\\" + ProgId, "Extensions", string.Join(" ", exts)), "ProgID");
        Must(() => Set(Classes + "\\" + ProgId + "\\DefaultIcon", null, $"\"{exe}\",0"), "icon");
        Must(() => Set(Classes + "\\" + ProgId + @"\shell\open\command", null, $"\"{exe}\" \"%1\""), "command");
        foreach (var e in exts) {
          Must(() => { using (var k = Registry.CurrentUser.CreateSubKey(Classes + "\\." + e + "\\OpenWithProgids")) k.SetValue(ProgId, new byte[0], RegistryValueKind.None); }, "." + e);
        }
      } else {
        Remove(Classes + "\\" + ProgId);
      }
      if (fileMenu) {
        Must(() => Set(Classes + @"\*\shell\satoEdit", null, openLabel), "file menu");
        Must(() => Set(Classes + @"\*\shell\satoEdit", "Icon", $"\"{exe}\",0"), "file menu");
        Must(() => Set(Classes + @"\*\shell\satoEdit\command", null, $"\"{exe}\" \"%1\""), "file menu");
      } else {
        Remove(Classes + @"\*\shell\satoEdit");
      }
      if (folderMenu) {
        Must(() => Set(Classes + @"\Directory\shell\satoEditGrep", null, grepLabel), "folder menu");
        Must(() => Set(Classes + @"\Directory\shell\satoEditGrep", "Icon", $"\"{exe}\",0"), "folder menu");
        Must(() => Set(Classes + @"\Directory\shell\satoEditGrep\command", null, $"\"{exe}\" \"--grep=%1\""), "folder menu");
      } else {
        Remove(Classes + @"\Directory\shell\satoEditGrep");
      }
      return string.Join(", ", failures);
    }
  }
}
