// satoEdit (Windows) のインストーラー / アンインストーラー
//   satoruEditorSetup.exe                 画面を出して入れる
//   satoruEditorSetup.exe /S              画面を出さずに入れる (確認用)
//   satoruEditorSetup.exe /update [/wait-pid=N] [/S]
//                                         アップデート: アプリ (プロセス N) が閉じるのを待ち、今の入れ方 (デスクトップのショートカットの有無) のまま
//                                         確かめずに入れ替えて、satoEditを起動し直す。/S なら進み具合の小窓も出さない (起動もしない)
//   uninstall.exe /uninstall [/S]         消す (入れた先に置く。「設定 > アプリ」からも呼ばれる)
// 入れる先: %LOCALAPPDATA%\Programs\satoruEditor (管理者の許可は要らない)。設定 (%USERPROFILE%\.satoruEditor) は消さない
using System;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography.X509Certificates;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace SatoEditSetup
{
    static class Setup
    {
        const string AppName = "satoEdit";
        const string AppNameEn = "satoEdit";
        const string ExeName = "satoruEditor.exe";
        const string Key = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\satoruEditor";
        static readonly bool Ja = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ja";
        static string T(string ja, string en) => Ja ? ja : en;
        static string Name => Ja ? AppName : AppNameEn;
        static string Version => Assembly.GetExecutingAssembly().GetName().Version.ToString(3);

        static string InstallDir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "satoruEditor");
        static string StartMenuLink => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), Name + ".lnk");
        static string DesktopLink => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), Name + ".lnk");
        /// 前の版の名前で作ったショートカット (1.0.3 までは「さとるエディタ」、1.0.4 は「エディタβ」)。入れ直すとき・消すときに片付ける
        static readonly string[] OldNames = { "さとるエディタ", "Satoru Editor", "エディタβ", "Editor β", AppName, AppNameEn };
        static string[] OldStartMenuLinks => OldNames.Where(n => n != Name).Select(n => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), n + ".lnk")).ToArray();
        static string[] OldDesktopLinks => OldNames.Where(n => n != Name).Select(n => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), n + ".lnk")).ToArray();

        [STAThread]
        static int Main(string[] args)
        {
            bool silent = args.Any(a => a.Equals("/S", StringComparison.OrdinalIgnoreCase));
            try
            {
                // アンインストール: 自分 (uninstall.exe) は消せないので、一時フォルダに写してから、そちらで消す
                var tempRun = Array.FindIndex(args, a => a == "/uninstall-from");
                if (tempRun >= 0 && tempRun + 1 < args.Length) return Uninstall(args[tempRun + 1], silent);
                if (args.Any(a => a.Equals("/uninstall", StringComparison.OrdinalIgnoreCase)))
                {
                    if (!silent && MessageBox.Show(T(AppName + " をこのパソコンから削除しますか？\n\n設定や、書いたファイルは消えません。",
                                                     "Remove " + AppNameEn + " from this PC?\n\nYour settings and files are kept."),
                                                   Name, MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return 1;
                    var self = Assembly.GetExecutingAssembly().Location;
                    var tmp = Path.Combine(Path.GetTempPath(), "satoruEditor-uninstall-" + Guid.NewGuid().ToString("N") + ".exe");
                    File.Copy(self, tmp, true);
                    Process.Start(new ProcessStartInfo(tmp, "/uninstall-from \"" + Path.GetDirectoryName(self) + "\"" + (silent ? " /S" : "")) { UseShellExecute = false });
                    return 0;
                }
                // ポータブル版のアップデート: その場所の中身だけ入れ替えて、起動し直す (ショートカットやアンインストールの登録は作らない)
                var portableArg = args.FirstOrDefault(a => a.StartsWith("/portable=", StringComparison.OrdinalIgnoreCase));
                if (portableArg != null)
                {
                    var pidArg = args.FirstOrDefault(a => a.StartsWith("/wait-pid=", StringComparison.OrdinalIgnoreCase));
                    if (pidArg != null && int.TryParse(pidArg.Substring("/wait-pid=".Length), out var pid)) WaitForExit(pid, 60000);
                    var dir = Path.GetFullPath(portableArg.Substring("/portable=".Length).Trim('"')).TrimEnd('\\');
                    if (!File.Exists(Path.Combine(dir, "data", "portable.txt")) && !File.Exists(Path.Combine(dir, "portable.txt"))) throw new InvalidOperationException(T("ポータブル版のフォルダではありません: ", "Not a portable folder: ") + dir);
                    // 前の版の部品 (いまは exe の中に入っている) を片付ける。data と目印には触れない
                    try { if (Directory.Exists(Path.Combine(dir, "app"))) Directory.Delete(Path.Combine(dir, "app"), true); } catch { }
                    foreach (var old in Directory.GetFiles(dir, "*.dll").Concat(Directory.GetFiles(dir, "*.exe.config"))) TryDelete(old);
                    for (int i = 0; ; i++)
                    {
                        try { Extract(dir, true); break; }
                        catch (IOException) when (i < 10) { Thread.Sleep(500); } // まだ閉じきっていない
                    }
                    if (!silent) Process.Start(new ProcessStartInfo(Path.Combine(dir, ExeName)) { UseShellExecute = true, WorkingDirectory = dir });
                    return 0;
                }
                if (args.Any(a => a.Equals("/update", StringComparison.OrdinalIgnoreCase)))
                {
                    var pidArg = args.FirstOrDefault(a => a.StartsWith("/wait-pid=", StringComparison.OrdinalIgnoreCase));
                    if (pidArg != null && int.TryParse(pidArg.Substring("/wait-pid=".Length), out var pid)) WaitForExit(pid, 60000);
                    bool desktop = File.Exists(DesktopLink) || OldDesktopLinks.Any(File.Exists) || !(File.Exists(StartMenuLink) || OldStartMenuLinks.Any(File.Exists)); // 前に入れたときの選び方を引き継ぐ (前の名前のショートカットも見る)
                    if (silent) { Install(desktop, false, null); return 0; }
                    Application.EnableVisualStyles();
                    Application.SetCompatibleTextRenderingDefault(false);
                    Application.Run(new UpdateForm(desktop));
                    return 0;
                }
                if (silent) { Install(true, false, null); return 0; }
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new SetupForm());
                return 0;
            }
            catch (Exception e)
            {
                if (!silent) MessageBox.Show(T("うまくいきませんでした:\n", "Something went wrong:\n") + e.Message, Name, MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 2;
            }
        }

        /// アップデートを始めたアプリが、自分で閉じ終わるのを待つ (保存の確かめは済んでいる)
        static void WaitForExit(int pid, int ms)
        {
            try
            {
                using (var p = Process.GetProcessById(pid)) p.WaitForExit(ms);
            }
            catch { } // もう閉じている
        }

        /// 動いているsatoEditを閉じる (ファイルを差し替えるため)
        static void StopRunningApp()
        {
            foreach (var p in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(ExeName)))
            {
                try
                {
                    var path = p.MainModule?.FileName ?? "";
                    if (!path.StartsWith(InstallDir, StringComparison.OrdinalIgnoreCase)) continue;
                    p.CloseMainWindow();
                    if (!p.WaitForExit(5000)) p.Kill();
                }
                catch { }
            }
        }

        /// 中身 (payload.zip) を dir に広げる。portable なら data フォルダと portable.txt には触れない
        static void Extract(string dir, bool portable)
        {
            using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))
            using (var zip = new ZipArchive(s, ZipArchiveMode.Read))
            {
                foreach (var e in zip.Entries)
                {
                    // zip の中は「satoruEditor/…」。先頭のフォルダは外して入れる
                    var rel = e.FullName.Replace('/', '\\');
                    var cut = rel.IndexOf('\\');
                    if (cut < 0) continue;
                    rel = rel.Substring(cut + 1);
                    if (rel.Length == 0) continue;
                    var target = Path.GetFullPath(Path.Combine(dir, rel));
                    if (!target.StartsWith(dir + "\\", StringComparison.OrdinalIgnoreCase)) continue; // 外へ書き出すものは入れない
                    if (portable && (rel.StartsWith("data\\", StringComparison.OrdinalIgnoreCase) || rel.Equals("portable.txt", StringComparison.OrdinalIgnoreCase))) continue;
                    if (rel.EndsWith("\\")) { Directory.CreateDirectory(target); continue; }
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    e.ExtractToFile(target, true);
                }
            }
        }

        /// 入れる: zip を広げ、ショートカットとアンインストールの登録を作る
        public static void Install(bool desktop, bool launch, Action<string> progress)
        {
            progress?.Invoke(T("準備しています…", "Preparing…"));
            StopRunningApp();
            var dir = InstallDir;
            // 前に入れたものは、いったん消してから入れ直す (古い部品が残らないように)
            if (Directory.Exists(dir))
            {
                for (int i = 0; ; i++)
                {
                    try { Directory.Delete(dir, true); break; }
                    catch when (i < 10) { Thread.Sleep(500); }
                }
            }
            Directory.CreateDirectory(dir);
            progress?.Invoke(T("ファイルを入れています…", "Copying files…"));
            Extract(dir, false);
            var uninstaller = Path.Combine(dir, "uninstall.exe");

            File.Copy(Assembly.GetExecutingAssembly().Location, uninstaller, true);
            var exe = Path.Combine(dir, ExeName);

            progress?.Invoke(T("ショートカットを作っています…", "Creating shortcuts…"));
            foreach (var old in OldStartMenuLinks.Concat(OldDesktopLinks)) TryDelete(old); // 前の名前のショートカットは消して、今の名前で作り直す
            MakeShortcut(StartMenuLink, exe, dir);
            if (desktop) MakeShortcut(DesktopLink, exe, dir);
            else TryDelete(DesktopLink);

            // 「設定 > アプリ」の一覧に出す (このユーザーだけ)
            using (var k = Registry.CurrentUser.CreateSubKey(Key))
            {
                k.SetValue("DisplayName", Name);
                k.SetValue("DisplayVersion", Version);
                k.SetValue("Publisher", "satoru.net");
                k.SetValue("DisplayIcon", exe + ",0");
                k.SetValue("InstallLocation", dir);
                k.SetValue("UninstallString", "\"" + uninstaller + "\" /uninstall");
                k.SetValue("QuietUninstallString", "\"" + uninstaller + "\" /uninstall /S");
                k.SetValue("URLInfoAbout", "https://docs.satoru.net/");
                k.SetValue("NoModify", 1, RegistryValueKind.DWord);
                k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
                long kb = new DirectoryInfo(dir).EnumerateFiles("*", SearchOption.AllDirectories).Sum(f => f.Length) / 1024;
                k.SetValue("EstimatedSize", (int)kb, RegistryValueKind.DWord);
            }
            // 画面の表示に使う Microsoft Edge WebView2 ランタイムが無ければ、一緒に入れる
            if (!HasWebView2())
            {
                progress?.Invoke(T("Microsoft Edge WebView2 ランタイムを入れています (インターネットから取ってきます。少しかかります)…",
                                   "Installing the Microsoft Edge WebView2 Runtime (downloading; this may take a moment)…"));
                InstallWebView2();
            }
            if (launch) Process.Start(new ProcessStartInfo(exe) { WorkingDirectory = dir, UseShellExecute = true });
        }

        const string WebView2Client = @"Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";
        const string BootstrapperURL = "https://go.microsoft.com/fwlink/p/?LinkId=2124703";

        /// WebView2 ランタイムが入っているか (このパソコン全体か、このユーザーに)
        static bool HasWebView2()
        {
            foreach (var (root, path) in new[] {
                (Registry.LocalMachine, @"SOFTWARE\WOW6432Node\" + WebView2Client),
                (Registry.LocalMachine, @"SOFTWARE\" + WebView2Client),
                (Registry.CurrentUser, @"Software\" + WebView2Client) })
            {
                try
                {
                    using (var k = root.OpenSubKey(path))
                    {
                        var pv = k?.GetValue("pv") as string;
                        if (!string.IsNullOrEmpty(pv) && pv != "0.0.0.0") return true;
                    }
                }
                catch { }
            }
            return false;
        }

        /// Microsoft の配布元から小さなインストーラ (Evergreen Bootstrapper) を取ってきて、画面を出さずに入れる。
        /// 管理者の権限が無ければ、このユーザーだけに入る。うまくいかなくても、satoEditの起動時にもう一度入れ方を案内する
        static void InstallWebView2()
        {
            var file = Path.Combine(Path.GetTempPath(), "MicrosoftEdgeWebview2Setup-" + Guid.NewGuid().ToString("N") + ".exe");
            try
            {
                ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
                using (var c = new HttpClient { Timeout = TimeSpan.FromMinutes(5) })
                    File.WriteAllBytes(file, c.GetByteArrayAsync(BootstrapperURL).GetAwaiter().GetResult());
                // Microsoft の正しい署名かを確かめてから動かす
                var subject = new X509Certificate2(X509Certificate.CreateFromSignedFile(file)).Subject;
                if (subject.IndexOf("O=Microsoft Corporation", StringComparison.OrdinalIgnoreCase) < 0) throw new Exception("signature: " + subject);
                using (var p = Process.Start(new ProcessStartInfo(file, "/silent /install") { UseShellExecute = false, CreateNoWindow = true }))
                    p.WaitForExit(10 * 60 * 1000);
            }
            catch (Exception e)
            {
                // 入れられなくても、satoEditは入っている (起動したときに、もう一度入れ方を案内する)
                try { File.AppendAllText(Path.Combine(Path.GetTempPath(), "satoruEditorSetup.log"), DateTime.Now + " webview2: " + e + "\r\n"); } catch { }
            }
            finally
            {
                try { File.Delete(file); } catch { }
            }
        }

        /// 消す (一時フォルダに写した自分から呼ばれる)
        static int Uninstall(string dir, bool silent)
        {
            Thread.Sleep(800); // 呼び出した uninstall.exe が終わるのを待つ
            StopRunningApp();
            TryDelete(StartMenuLink);
            TryDelete(DesktopLink);
            foreach (var old in OldStartMenuLinks.Concat(OldDesktopLinks)) TryDelete(old);
            try { Registry.CurrentUser.DeleteSubKeyTree(Key, false); } catch { }
            // 入れた先のフォルダだけ消す (念のため、satoEditの exe がある所に限る)
            if (Directory.Exists(dir) && File.Exists(Path.Combine(dir, ExeName)))
            {
                for (int i = 0; i < 20; i++)
                {
                    try { Directory.Delete(dir, true); break; } catch { Thread.Sleep(500); }
                }
            }
            if (!silent) MessageBox.Show(T(AppName + " を削除しました。", AppNameEn + " was removed."), Name, MessageBoxButtons.OK, MessageBoxIcon.Information);
            // 一時フォルダの自分は、終わったあとで消す
            var self = Assembly.GetExecutingAssembly().Location;
            Process.Start(new ProcessStartInfo("cmd.exe", "/c ping 127.0.0.1 -n 3 > nul & del \"" + self + "\"") { CreateNoWindow = true, UseShellExecute = false });
            return 0;
        }

        static void MakeShortcut(string link, string target, string workDir)
        {
            var type = Type.GetTypeFromProgID("WScript.Shell");
            dynamic shell = Activator.CreateInstance(type);
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(link));
                dynamic sc = shell.CreateShortcut(link);
                sc.TargetPath = target;
                sc.WorkingDirectory = workDir;
                sc.IconLocation = target + ",0";
                sc.Description = Name;
                sc.Save();
            }
            finally { System.Runtime.InteropServices.Marshal.FinalReleaseComObject(shell); }
        }

        static void TryDelete(string f) { try { if (File.Exists(f)) File.Delete(f); } catch { } }

        /// アップデートの間だけ出す小窓 (確かめることは無い。終わったら、satoEditを起動して閉じる)
        sealed class UpdateForm : Form
        {
            readonly Label status = new Label { AutoSize = true, ForeColor = SystemColors.GrayText };

            public UpdateForm(bool desktop)
            {
                Text = Name;
                Font = new Font(Ja ? "Yu Gothic UI" : "Segoe UI", 9.5f);
                FormBorderStyle = FormBorderStyle.FixedDialog;
                MaximizeBox = MinimizeBox = false;
                ControlBox = false;
                StartPosition = FormStartPosition.CenterScreen;
                AutoSize = true;
                AutoSizeMode = AutoSizeMode.GrowAndShrink;
                Padding = new Padding(20);
                try { Icon = Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location); } catch { }
                var title = new Label { AutoSize = true, Text = T(AppName + " を " + Version + " に更新しています…", "Updating " + AppNameEn + " to " + Version + "…"), Font = new Font(Font.FontFamily, 11f, FontStyle.Bold) };
                var bar = new ProgressBar { Style = ProgressBarStyle.Marquee, Width = 360, Height = 16, MarqueeAnimationSpeed = 30 };
                var stack = new TableLayoutPanel { AutoSize = true, ColumnCount = 1, Dock = DockStyle.Fill };
                foreach (Control c in new Control[] { title, bar, status })
                {
                    c.Margin = new Padding(0, 4, 0, 4);
                    stack.Controls.Add(c);
                }
                Controls.Add(stack);
                Shown += (s, e) =>
                {
                    var t = new Thread(() =>
                    {
                        try
                        {
                            Install(desktop, true, msg => BeginInvoke((Action)(() => status.Text = msg)));
                            BeginInvoke((Action)Close);
                        }
                        catch (Exception ex)
                        {
                            BeginInvoke((Action)(() =>
                            {
                                MessageBox.Show(this, T("更新できませんでした:\n", "The update failed:\n") + ex.Message, Name, MessageBoxButtons.OK, MessageBoxIcon.Error);
                                Close();
                            }));
                        }
                    }) { IsBackground = true };
                    t.SetApartmentState(ApartmentState.STA); // ショートカットを作る COM のため
                    t.Start();
                };
            }
        }

        /// インストールの画面 (1 枚だけ)
        sealed class SetupForm : Form
        {
            readonly CheckBox desktop = new CheckBox { AutoSize = true, Checked = true };
            readonly CheckBox launch = new CheckBox { AutoSize = true, Checked = true };
            readonly Button go = new Button { AutoSize = true };
            readonly Button cancel = new Button { AutoSize = true };
            readonly Label status = new Label { AutoSize = true, ForeColor = SystemColors.GrayText };

            public SetupForm()
            {
                Text = T(AppName + " のインストール", AppNameEn + " Setup");
                Font = new Font(Ja ? "Yu Gothic UI" : "Segoe UI", 9.5f);
                FormBorderStyle = FormBorderStyle.FixedDialog;
                MaximizeBox = MinimizeBox = false;
                StartPosition = FormStartPosition.CenterScreen;
                AutoSize = true;
                AutoSizeMode = AutoSizeMode.GrowAndShrink;
                Padding = new Padding(20);
                try { Icon = Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location); } catch { }

                var title = new Label { AutoSize = true, Text = Name + " " + Version, Font = new Font(Font.FontFamily, 14f, FontStyle.Bold) };
                var info = new Label
                {
                    AutoSize = true, MaximumSize = new Size(420, 0),
                    Text = T("書く・まとめる・共有する、がサクサクできるテキストエディタです。\n\n入れる場所: ",
                             "A text editor for writing, organizing and sharing.\n\nInstall location: ") + InstallDir
                           + T("\n(このユーザーだけ。管理者の許可は要りません)", "\n(for this user only; no administrator rights needed)")
                };
                desktop.Text = T("デスクトップにショートカットを作る", "Create a desktop shortcut");
                launch.Text = T("インストールが終わったら起動する", "Launch when finished");
                go.Text = T("インストール", "Install");
                cancel.Text = T("キャンセル", "Cancel");
                go.Click += (s, e) => DoInstall();
                cancel.Click += (s, e) => Close();
                AcceptButton = go;
                CancelButton = cancel;

                var buttons = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.RightToLeft, Dock = DockStyle.Fill, Margin = new Padding(0, 14, 0, 0) };
                buttons.Controls.Add(go);
                buttons.Controls.Add(cancel);
                var stack = new TableLayoutPanel { AutoSize = true, ColumnCount = 1, Dock = DockStyle.Fill };
                foreach (Control c in new Control[] { title, info, desktop, launch, status, buttons })
                {
                    c.Margin = new Padding(0, 4, 0, 4);
                    stack.Controls.Add(c);
                }
                Controls.Add(stack);
            }

            void DoInstall()
            {
                go.Enabled = cancel.Enabled = desktop.Enabled = launch.Enabled = false;
                bool d = desktop.Checked, l = launch.Checked;
                var t = new Thread(() =>
                {
                    try
                    {
                        Install(d, l, msg => BeginInvoke((Action)(() => status.Text = msg)));
                        BeginInvoke((Action)(() =>
                        {
                            if (!l) MessageBox.Show(this, T("インストールしました。スタートメニューの「" + AppName + "」から起動できます。",
                                                            "Installed. Start it from \"" + AppNameEn + "\" in the Start menu."), Name);
                            Close();
                        }));
                    }
                    catch (Exception e)
                    {
                        BeginInvoke((Action)(() =>
                        {
                            MessageBox.Show(this, T("インストールできませんでした:\n", "Installation failed:\n") + e.Message, Name, MessageBoxButtons.OK, MessageBoxIcon.Error);
                            status.Text = "";
                            go.Enabled = cancel.Enabled = desktop.Enabled = launch.Enabled = true;
                        }));
                    }
                }) { IsBackground = true };
                t.SetApartmentState(ApartmentState.STA); // ショートカットを作る COM のため
                t.Start();
            }
        }
    }
}
