using System;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace SatoEdit {
  /// さとるエディタ 軽量版の入口。1 つしか起動しないようにして、2 つめはファイルを 1 つめに渡して終わる
  static class Program {
    /// アプリの版 (AssemblyInfo.cs の AssemblyInformationalVersion。package.json の版とそろえる)
    public static readonly string Version =
      (System.Reflection.Assembly.GetExecutingAssembly().GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
        is object[] attrs && attrs.Length > 0 ? ((System.Reflection.AssemblyInformationalVersionAttribute)attrs[0]).InformationalVersion : null) ?? "0.0.0";
    static Mutex mutex;

    /// アプリの画面の部品 (renderer・assets) が入っているフォルダ
    public static string AppRoot {
      get {
        var exeDir = AppDomain.CurrentDomain.BaseDirectory;
        var packed = Path.Combine(exeDir, "app");
        if (Directory.Exists(Path.Combine(packed, "renderer"))) return packed;
        // 開発中: windows/build/host-bin/ から見た windows/
        var dev = Path.GetFullPath(Path.Combine(exeDir, "..", ".."));
        return Directory.Exists(Path.Combine(dev, "renderer")) ? dev : packed;
      }
    }

    static string PipeName => "satoruEditor-" + Environment.UserName.Replace('\\', '_') + "-open";

    [STAThread]
    static void Main(string[] args) {
      var selftest = args.FirstOrDefault(a => a.StartsWith("--selftest="));
      // 自己点検のときは、ほかに起動していても動く (そのときは受け取り口は作らない)
      mutex = new Mutex(true, "Local\\satoruEditor-single-instance", out bool first);
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

  /// うまく動かなかったことの記録 (%LOCALAPPDATA%\satoruEditor\host.log)。小さく保つ
  static class Log {
    public static string Dir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "satoruEditor");
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
}
