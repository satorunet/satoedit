using System;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace SatoEdit {
  /// エディタβ 軽量版の入口。1 つしか起動しないようにして、2 つめはファイルを 1 つめに渡して終わる
  static class Program {
    /// アプリの版 (AssemblyInfo.cs の AssemblyInformationalVersion。package.json の版とそろえる)
    public static readonly string Version =
      (System.Reflection.Assembly.GetExecutingAssembly().GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
        is object[] attrs && attrs.Length > 0 ? ((System.Reflection.AssemblyInformationalVersionAttribute)attrs[0]).InformationalVersion : null) ?? "0.0.0";
    static Mutex mutex;

    /// アプリの画面の部品 (renderer・assets) が入っているフォルダ
    public static string AppRoot {
      get {
        // 配布物は exe 1 つ。画面の部品は exe の中に入っていて、はじめて使うときに広げる
        var unpacked = Embedded.AppDir();
        if (unpacked != null) return unpacked;
        var exeDir = AppDomain.CurrentDomain.BaseDirectory;
        var packed = Path.Combine(exeDir, "app");
        if (Directory.Exists(Path.Combine(packed, "renderer"))) return packed;
        // 開発中: windows/build/host-bin/ から見た windows/
        var dev = Path.GetFullPath(Path.Combine(exeDir, "..", ".."));
        return Directory.Exists(Path.Combine(dev, "renderer")) ? dev : packed;
      }
    }

    static string PipeName => "satoruEditor-" + Environment.UserName.Replace('\\', '_') + Portable.Tag + "-open";

    [STAThread]
    static void Main(string[] args) {
      // exe の中に入れた部品 (DLL) を読めるようにしてから、本体を動かす (本体の型を読む前に)
      Embedded.Hook();
      Run(args);
    }

    [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
    static void Run(string[] args) {
      Embedded.PrepareNative();
      var selftest = args.FirstOrDefault(a => a.StartsWith("--selftest="));
      // 自己点検のときは、ほかに起動していても動く (そのときは受け取り口は作らない)
      mutex = new Mutex(true, "Local\\satoruEditor-single-instance" + Portable.Tag, out bool first);
      if (!first && selftest == null && Forward(args)) return;
      Store.MigrateConfigDir();
      Application.EnableVisualStyles();
      Application.SetCompatibleTextRenderingDefault(false);
      Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
      Application.ThreadException += (s, e) => Log.Error("ui", e.Exception);
      AppDomain.CurrentDomain.UnhandledException += (s, e) => Log.Error("app", e.ExceptionObject as Exception);
      // アップデートを確かめる先を変える (試験用。この PC の JSON ファイルでもよい)
      Updater.UrlOverride = args.FirstOrDefault(a => a.StartsWith("--update-url="))?.Substring("--update-url=".Length).Trim('"');
      SelfTest.FixturesArg = args.FirstOrDefault(a => a.StartsWith("--fixtures="))?.Substring("--fixtures=".Length).Trim('"');
      if (selftest != null) {
        // 自己点検では、本物のドキュメントと版の記録に触れないよう、点検のフォルダの中を使う
        var dir = selftest.Substring("--selftest=".Length).Trim('"');
        Environment.SetEnvironmentVariable("SATORU_LIBRARY_DIR", Path.Combine(dir, "library"));
        Environment.SetEnvironmentVariable("SATORU_VERSIONS_DIR", Path.Combine(dir, "history"));
        Versions.Interval = 2;
        Updater.AutoDisabled = true; // 点検の間は GitHub に問い合わせない
      }
      var form = new MainForm(args, selftest?.Substring("--selftest=".Length).Trim('"'));
      if (first) Listen(form);
      Application.Run(form);
      try { Versions.Flush(); } catch (Exception e) { Log.Error("versions", e); } // 待っている版の記録を済ませる
      GC.KeepAlive(mutex);
    }

    /// すでに起動しているほうへ、作業フォルダと引数を渡す
    static bool Forward(string[] args) {
      var msg = new JObj { { "cwd", Environment.CurrentDirectory }, { "args", args.Cast<object>().ToList() } };
      var data = Encoding.UTF8.GetBytes(Json.Stringify(msg));
      for (int i = 0; i < 25; i++) {
        try {
          using (var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.Out)) {
            pipe.Connect(200);
            Win32.AllowSetForegroundWindow(-1); // 前のウインドウを前に出せるように
            pipe.Write(data, 0, data.Length);
            pipe.Flush();
            return true;
          }
        } catch {
          Thread.Sleep(200);
        }
      }
      return false;
    }

    static void Listen(MainForm form) {
      var t = new Thread(() => {
        while (true) {
          try {
            using (var pipe = new NamedPipeServerStream(PipeName, PipeDirection.In, 1)) {
              pipe.WaitForConnection();
              var ms = new MemoryStream();
              pipe.CopyTo(ms);
              var o = Json.TryParse(Encoding.UTF8.GetString(ms.ToArray())) as JObj;
              if (o == null) continue;
              var cwd = o.Str("cwd");
              var list = (o.Arr("args") ?? new System.Collections.Generic.List<object>()).Select(x => x as string ?? "").ToArray();
              form.BeginInvoke((Action)(() => form.SecondInstance(list, cwd)));
            }
          } catch (Exception e) {
            Log.Error("pipe", e);
            Thread.Sleep(500);
          }
        }
      });
      t.IsBackground = true;
      t.Start();
    }
  }

  /// ポータブル版: exe の横に portable.txt があれば、設定・テキスト・記録をすべて exe の横の data フォルダに置く
  /// (USB メモリなどに入れて、その場ですぐ動かす。この PC には何も残さない)
  static class Portable {
    public static readonly string ExeDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
    /// 目印: data\portable.txt (前の版は exe の横の portable.txt)
    public static readonly bool On = File.Exists(Path.Combine(ExeDir, "data", "portable.txt")) || File.Exists(Path.Combine(ExeDir, "portable.txt"));
    public static string Data => Path.Combine(ExeDir, "data");
    /// インストール版や、別の場所のポータブル版と同時に動かせるよう、1 つだけ起動の印に場所を混ぜる
    public static string Tag {
      get {
        if (!On) return "";
        uint h = 2166136261;
        foreach (var c in ExeDir.ToLowerInvariant()) { h ^= c; h *= 16777619; }
        return "-p" + h.ToString("x8");
      }
    }
  }

  /// うまく動かなかったことの記録 (%LOCALAPPDATA%\satoruEditor\host.log。ポータブル版は data\local)。小さく保つ
  static class Log {
    public static string Dir => Portable.On ? Path.Combine(Portable.Data, "local")
      : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "satoruEditor");
    public static void Error(string where, Exception e) => Write(where + ": " + e);
    public static void Write(string line) {
      try {
        Directory.CreateDirectory(Dir);
        var f = Path.Combine(Dir, "host.log");
        if (File.Exists(f) && new FileInfo(f).Length > 512 * 1024) File.Delete(f);
        File.AppendAllText(f, DateTime.Now.ToString("s") + " " + line + "\r\n");
      } catch { }
    }
  }

  /// exe 1 つで動かすため、exe の中に入れた部品 (package-host.js が入れる):
  ///   lib/*.dll                  … WebView2・SSH などの部品。読むときにメモリから読む
  ///   native/WebView2Loader.dll  … WebView2 の入口。ファイルでないと読めないので、ローカルの置き場に書き出す
  ///   app.zip                    … 画面 (renderer・assets・pdfjs)。ローカルの置き場に広げる
  /// 開発中の exe (build/host-bin) には入っていないので、そのときは今までどおり横のファイルを使う
  static class Embedded {
    static readonly System.Reflection.Assembly Me = typeof(Embedded).Assembly;
    static string cacheDir;

    static bool Has(string name) => Me.GetManifestResourceInfo(name) != null;

    public static void Hook() {
      AppDomain.CurrentDomain.AssemblyResolve += (s, e) => {
        try {
          var name = new System.Reflection.AssemblyName(e.Name).Name;
          using (var st = Me.GetManifestResourceStream("lib/" + name + ".dll")) {
            if (st == null) return null;
            var ms = new MemoryStream();
            st.CopyTo(ms);
            return System.Reflection.Assembly.Load(ms.ToArray());
          }
        } catch { return null; }
      };
    }

    /// 広げる先: %LOCALAPPDATA%\satoruEditor\bin\<版>-<作った回の印> (ポータブル版は data\local\bin\…)。版が変わったら古いものは消す
    static string CacheDir {
      get {
        if (cacheDir != null) return cacheDir;
        var root = Path.Combine(Log.Dir, "bin");
        var dir = Path.Combine(root, Program.Version + "-" + Me.ManifestModule.ModuleVersionId.ToString("N").Substring(0, 12));
        try {
          if (Directory.Exists(root))
            foreach (var old in Directory.GetDirectories(root))
              if (!string.Equals(old, dir, StringComparison.OrdinalIgnoreCase)) { try { Directory.Delete(old, true); } catch { } } // 動いている別の版が使っていれば残る
        } catch { }
        return cacheDir = dir;
      }
    }

    [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
    public static void PrepareNative() {
      try {
        if (!Has("native/WebView2Loader.dll")) return;
        var dir = Path.Combine(CacheDir, "native");
        var f = Path.Combine(dir, "WebView2Loader.dll");
        if (!File.Exists(f)) {
          Directory.CreateDirectory(dir);
          var tmp = f + "." + Guid.NewGuid().ToString("N");
          using (var st = Me.GetManifestResourceStream("native/WebView2Loader.dll"))
          using (var o = File.Create(tmp)) st.CopyTo(o);
          try { File.Move(tmp, f); } catch { File.Delete(tmp); } // ほかの起動が先に書いた
        }
        Microsoft.Web.WebView2.Core.CoreWebView2Environment.SetLoaderDllFolderPath(dir);
      } catch (Exception e) { Log.Error("native", e); }
    }

    static string appDir;
    /// 画面の部品を広げたフォルダ (exe に入っていなければ null)
    public static string AppDir() {
      if (appDir != null) return appDir;
      if (!Has("app.zip")) return null;
      var dir = Path.Combine(CacheDir, "app");
      var done = Path.Combine(dir, ".ok");
      if (!File.Exists(done)) {
        var tmp = dir + "." + Guid.NewGuid().ToString("N");
        using (var st = Me.GetManifestResourceStream("app.zip"))
        using (var zip = new System.IO.Compression.ZipArchive(st, System.IO.Compression.ZipArchiveMode.Read)) {
          var top = Path.GetFullPath(tmp) + "\\";
          foreach (var e in zip.Entries) {
            if (e.FullName.EndsWith("/")) continue;
            var target = Path.GetFullPath(Path.Combine(tmp, e.FullName.Replace('/', '\\')));
            if (!target.StartsWith(top, StringComparison.OrdinalIgnoreCase)) continue;
            Directory.CreateDirectory(Path.GetDirectoryName(target));
            using (var i = e.Open()) using (var o = File.Create(target)) i.CopyTo(o);
          }
        }
        File.WriteAllText(Path.Combine(tmp, ".ok"), Program.Version);
        try {
          if (Directory.Exists(dir)) Directory.Delete(dir, true);
          Directory.Move(tmp, dir);
        } catch {
          try { Directory.Delete(tmp, true); } catch { }
          if (!File.Exists(done)) throw;
        }
      }
      return appDir = dir;
    }
  }
}
