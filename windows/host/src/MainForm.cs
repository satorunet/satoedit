using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace SatoEdit {
  /// ウインドウ: 上にメニューバー、その下いっぱいに WebView2 (画面は Electron 版と同じ renderer をそのまま使う)
  partial class MainForm : Form {
    public const string HostName = "satorueditor.local";
    public static string StartURL => "https://" + HostName + "/renderer/index.html";

    public readonly WebView2 View;
    public CoreWebView2 Web => View?.CoreWebView2;
    public CoreWebView2Environment Env;
    readonly MenuStrip menu;
    public readonly Bridge Bridge;
    public bool RendererReady;
    public bool AllowClose;
    public List<string> PendingFiles;
    public string PendingGrep;
    readonly string selftestDir;
    readonly bool devtools;

    public MainForm(string[] args, string selftestDir) {
      this.selftestDir = selftestDir;
      devtools = args.Contains("--devtools");
      Win32.SetAppId("net.satoru.editor");
      Store.LoadPrefs();
      PendingFiles = ExistingFiles(args, Environment.CurrentDirectory);
      PendingGrep = GrepArg(args);

      Text = "さとるエディタ";
      BackColor = Color.FromArgb(0xf0, 0xf0, 0xf0);
      AutoScaleMode = AutoScaleMode.Dpi;
      KeyPreview = false;
      SetIcon(Store.Prefs.Str("iconColor", "ai"));

      View = new WebView2 { Dock = DockStyle.Fill, DefaultBackgroundColor = Color.FromArgb(0xf0, 0xf0, 0xf0) };
      menu = new MenuStrip { Dock = DockStyle.Top, RenderMode = ToolStripRenderMode.System };
      Controls.Add(View);
      Controls.Add(menu);
      MainMenuStrip = menu;
      Bridge = new Bridge(this);
      ApplySavedBounds();
      Load += async (s, e) => await StartWebView();
      FormClosing += OnClosing;
      Shown += (s, e) => { if (Store.Prefs.Obj("windowBounds")?.Bool("maximized") == true) WindowState = FormWindowState.Maximized; };
    }

    float Scale96 => DeviceDpi / 96f;

    void ApplySavedBounds() {
      var b = Store.Prefs.Obj("windowBounds");
      var dpi = Screen.PrimaryScreen != null ? Win32Dpi() / 96f : 1f;
      int W(double v) => (int)Math.Round(v * dpi);
      MinimumSize = new Size(W(480), W(320));
      if (b != null && b.Num("width") > 0) {
        var r = new Rectangle(W(b.Num("x")), W(b.Num("y")), W(b.Num("width")), W(b.Num("height")));
        // 画面の外 (外したモニター) には出さない
        if (Screen.AllScreens.Any(s => s.WorkingArea.IntersectsWith(new Rectangle(r.X, r.Y, Math.Max(100, r.Width), 40)))) {
          StartPosition = FormStartPosition.Manual;
          Bounds = r;
          return;
        }
        Size = new Size(r.Width, r.Height);
      } else {
        Size = new Size(W(1100), W(760));
      }
      StartPosition = FormStartPosition.CenterScreen;
    }

    static int Win32Dpi() {
      using (var g = Graphics.FromHwnd(IntPtr.Zero)) return (int)g.DpiX;
    }

    public void SetIcon(string color) {
      var names = new[] { "ai", "shu", "hinoki", "sumi", "yamabuki", "murasaki", "asagi", "kinari" };
      if (!names.Contains(color)) color = "ai";
      try {
        using (var bmp = new Bitmap(Path.Combine(Program.AppRoot, "assets", "icons", color + ".png"))) {
          var old = Icon;
          Icon = Icon.FromHandle(bmp.GetHicon());
        }
      } catch (Exception e) { Log.Error("icon", e); }
    }

    async Task StartWebView() {
      Log.Write("start webview " + Program.AppRoot);
      try {
        var userData = Path.Combine(Log.Dir, "WebView2");
        var scheme = new CoreWebView2CustomSchemeRegistration("satoplug") { TreatAsSecure = true, HasAuthorityComponent = true };
        scheme.AllowedOrigins.Add("*");
        var opts = new CoreWebView2EnvironmentOptions(null, null, null, false, new List<CoreWebView2CustomSchemeRegistration> { scheme });
        opts.AreBrowserExtensionsEnabled = false;
        Env = await CoreWebView2Environment.CreateAsync(BrowserFolder(), userData, opts);
        await View.EnsureCoreWebView2Async(Env);
      } catch (WebView2RuntimeNotFoundException) {
        Log.Write("WebView2 runtime not found");
        if (selftestDir != null) { try { Directory.CreateDirectory(selftestDir); File.WriteAllText(Path.Combine(selftestDir, "report.json"), "{ \"steps\": {}, \"errors\": [\"WebView2 runtime not found\"] }"); } catch { } }
        if (selftestDir == null && await RuntimeSetup.Offer(this)) { await StartWebView(); return; }
        AllowClose = true;
        Close();
        return;
      } catch (Exception e) {
        Log.Error("webview", e);
        MessageBox.Show(this, "画面を表示できませんでした。\n" + e.Message, "さとるエディタ", MessageBoxButtons.OK, MessageBoxIcon.Error);
        AllowClose = true;
        Close();
        return;
      }
      Log.Write("webview ready " + Env.BrowserVersionString);
      var s = Web.Settings;
      s.AreDevToolsEnabled = devtools;
      s.IsStatusBarEnabled = false;
      s.IsZoomControlEnabled = false;
      s.AreBrowserAcceleratorKeysEnabled = false; // Ctrl+F・F5 などはブラウザではなく画面側で受ける
      s.IsGeneralAutofillEnabled = false;
      s.IsPasswordAutosaveEnabled = false;
      s.IsSwipeNavigationEnabled = false;
      s.AreHostObjectsAllowed = false;
      s.AreDefaultScriptDialogsEnabled = true;
      Web.SetVirtualHostNameToFolderMapping(HostName, Program.AppRoot, CoreWebView2HostResourceAccessKind.Allow);
      Web.WebMessageReceived += (o, e) => Bridge.Receive(e);
      Web.NewWindowRequested += (o, e) => { e.Handled = true; OpenExternal(e.Uri); };
      Web.NavigationStarting += (o, e) => {
        // 文中のリンクなどで、アプリの画面が別のページに変わらないようにする (読み込み直しはよい)
        if (!e.Uri.StartsWith(StartURL, StringComparison.OrdinalIgnoreCase)) { e.Cancel = true; OpenExternal(e.Uri); }
      };
      Web.ContextMenuRequested += OnContextMenu;
      HookMenuKeys();
      Web.ProcessFailed += (o, e) => Log.Write("process failed: " + e.ProcessFailedKind + " " + e.Reason);
      Bridge.StartPluginScheme();
      Web.Navigate(StartURL);
      if (selftestDir != null) _ = new SelfTest(this, selftestDir).Run();
    }

    /// 決まった版の WebView2 ランタイム (Fixed Version) を使うとき: exe の隣の WebView2 フォルダか、環境変数 SATOEDIT_WEBVIEW2
    static string BrowserFolder() {
      foreach (var d in new[] { Environment.GetEnvironmentVariable("SATOEDIT_WEBVIEW2"), Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "WebView2") }) {
        if (!string.IsNullOrEmpty(d) && File.Exists(Path.Combine(d, "msedgewebview2.exe"))) return d;
      }
      return null;
    }

    // ---------- Alt キーでメニューバー ----------
    // 文字を打っているのは WebView2 なので、Alt+F や Alt だけを押したときのメニューバーの操作は、ここで拾って渡す
    bool altAlone;
    void HookMenuKeys() {
      try {
        var f = typeof(WebView2).GetField("_coreWebView2Controller", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
        if (!(f?.GetValue(View) is CoreWebView2Controller c)) { Log.Write("menu keys: no controller"); return; }
        c.AcceleratorKeyPressed += (s, e) => {
          var kind = e.KeyEventKind;
          uint vk = e.VirtualKey;
          bool ctrl = (Control.ModifierKeys & Keys.Control) != 0;
          if (kind == CoreWebView2KeyEventKind.SystemKeyDown && vk == 0x12) { if (e.PhysicalKeyStatus.WasKeyDown == 0) altAlone = true; return; }
          if (kind == CoreWebView2KeyEventKind.SystemKeyUp && vk == 0x12) {
            if (altAlone) { altAlone = false; BeginInvoke((Action)(() => { menu.Focus(); if (menu.Items.Count > 0) menu.Items[0].Select(); })); }
            return;
          }
          if (kind == CoreWebView2KeyEventKind.KeyDown || kind == CoreWebView2KeyEventKind.SystemKeyDown) altAlone = false;
          if (kind == CoreWebView2KeyEventKind.SystemKeyDown && !ctrl && ((vk >= 0x41 && vk <= 0x5A) || (vk >= 0x30 && vk <= 0x39))) {
            var item = menu.Items.OfType<ToolStripMenuItem>().FirstOrDefault(m => Mnemonic(m.Text) == char.ToUpperInvariant((char)vk));
            if (item == null) return;
            e.Handled = true;
            BeginInvoke((Action)(() => { menu.Focus(); item.ShowDropDown(); if (item.DropDownItems.Count > 0) item.DropDownItems[0].Select(); }));
          }
          if (kind == CoreWebView2KeyEventKind.KeyDown && vk == 0x79 && !ctrl) { // F10
            e.Handled = true;
            BeginInvoke((Action)(() => { menu.Focus(); if (menu.Items.Count > 0) menu.Items[0].Select(); }));
          }
        };
      } catch (Exception e) { Log.Error("menu keys", e); }
    }

    static char Mnemonic(string text) {
      int i = (text ?? "").IndexOf('&');
      while (i >= 0 && i + 1 < text.Length) {
        if (text[i + 1] != '&') return char.ToUpperInvariant(text[i + 1]);
        i = text.IndexOf('&', i + 2);
      }
      return '\0';
    }

    /// 右クリックのメニューは、文字の編集 (切り取り・コピー・貼り付けなど) だけにする
    void OnContextMenu(object sender, CoreWebView2ContextMenuRequestedEventArgs e) {
      var keep = new HashSet<string> { "undo", "redo", "cut", "copy", "paste", "pasteAndMatchStyle", "selectAll" };
      var items = e.MenuItems;
      for (int i = items.Count - 1; i >= 0; i--) {
        if (!keep.Contains(items[i].Name) && items[i].Kind != CoreWebView2ContextMenuItemKind.Separator) items.RemoveAt(i);
      }
      // 区切り線だけが残らないように
      for (int i = items.Count - 1; i >= 0; i--) {
        bool sep = items[i].Kind == CoreWebView2ContextMenuItemKind.Separator;
        if (sep && (i == 0 || i == items.Count - 1 || items[i - 1].Kind == CoreWebView2ContextMenuItemKind.Separator)) items.RemoveAt(i);
      }
      if (items.Count == 0) e.Handled = true;
    }

    public static void OpenExternal(string url) {
      if (string.IsNullOrEmpty(url) || !System.Text.RegularExpressions.Regex.IsMatch(url, "^(https?|mailto):", System.Text.RegularExpressions.RegexOptions.IgnoreCase)) return;
      try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true }); } catch (Exception e) { Log.Error("open", e); }
    }

    // ---------- 閉じる ----------

    void OnClosing(object sender, FormClosingEventArgs e) {
      SaveBounds();
      Store.SavePrefsNow();
      if (AllowClose || !RendererReady) return;
      e.Cancel = true;
      Bridge.Send("app:request-close"); // 保存していない文書がないか画面側で確かめる
    }

    public void SaveBounds() {
      if (WindowState == FormWindowState.Minimized) return;
      var r = WindowState == FormWindowState.Normal ? Bounds : RestoreBounds;
      var k = Scale96;
      Store.Prefs["windowBounds"] = new JObj {
        { "x", Math.Round(r.X / k) }, { "y", Math.Round(r.Y / k) }, { "width", Math.Round(r.Width / k) }, { "height", Math.Round(r.Height / k) },
        { "maximized", WindowState == FormWindowState.Maximized },
      };
    }

    public void CloseNow() {
      AllowClose = true;
      Close();
    }

    // ---------- 2 つめの起動から ----------

    public void SecondInstance(string[] args, string cwd) {
      Log.Write("second instance: " + args.Length + " args");
      if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
      Activate();
      Win32.SetForegroundWindow(Handle);
      var files = ExistingFiles(args, cwd);
      if (files.Count > 0) Bridge.Send("open-files", files.Cast<object>().ToList());
      var root = GrepArg(args);
      if (root != "") Bridge.Send("open-grep", root);
    }

    public static List<string> ExistingFiles(IEnumerable<string> args, string cwd) {
      var outl = new List<string>();
      foreach (var a in args) {
        if (string.IsNullOrEmpty(a) || a.StartsWith("-")) continue;
        try {
          var full = Path.GetFullPath(Path.Combine(cwd ?? Environment.CurrentDirectory, a));
          if (File.Exists(full)) outl.Add(full);
        } catch { }
      }
      return outl;
    }

    /// エクスプローラーの右クリック「さとるエディタで grep」から渡されるフォルダ (--grep=フォルダ)
    public static string GrepArg(IEnumerable<string> args) {
      var a = args.FirstOrDefault(x => x.StartsWith("--grep="));
      if (a == null) return "";
      var dir = a.Substring(7).Replace("\"", "");
      return Directory.Exists(dir) ? dir : "";
    }

    // ---------- メニューバー ----------

    /// 画面側で組み立てたメニューの木 (shared/menu.js の build の結果) を、そのまま Windows のメニューにする
    public void SetMenu(List<object> items) {
      menu.SuspendLayout();
      var old = menu.Items.Cast<ToolStripItem>().ToList();
      menu.Items.Clear();
      foreach (var o in items) if (o is JObj m) menu.Items.Add(MakeItem(m));
      foreach (var x in old) x.Dispose();
      if (darkMenu) ApplyMenuColors(menu.Items, true);
      menu.ResumeLayout();
    }

    ToolStripItem MakeItem(JObj m) {
      if (m.Str("type") == "separator") return new ToolStripSeparator();
      if (m.Bool("header")) return new ToolStripMenuItem("― " + m.Str("label") + " ―") { Enabled = false };
      var item = new ToolStripMenuItem(m.Str("label"));
      var sub = m.Arr("submenu");
      if (sub != null) {
        foreach (var o in sub) if (o is JObj c) item.DropDownItems.Add(MakeItem(c));
        return item;
      }
      item.Enabled = !(m["enabled"] is bool en) || en;
      var type = m.Str("type");
      if (type == "checkbox" || type == "radio") item.Checked = m.Bool("checked");
      var accel = m.Str("accel");
      if (accel != "") { item.ShortcutKeyDisplayString = accel; item.ShowShortcutKeys = true; } // キーは画面側で受ける (ここでは表示だけ)
      var role = m.Str("role");
      var id = m.Str("id");
      item.Click += (s, e) => {
        if (role != "") EditCommand(role);
        else if (id != "") Bridge.Send("command", id);
      };
      return item;
    }

    /// 切り取り・コピー・貼り付け: いま文字を打っている所に、OS の編集の命令を送る
    public async void EditCommand(string name) {
      if (Web == null) return;
      var map = new Dictionary<string, (string key, string code, int vk)> {
        { "cut", ("x", "KeyX", 0x58) }, { "copy", ("c", "KeyC", 0x43) }, { "paste", ("v", "KeyV", 0x56) },
        { "undo", ("z", "KeyZ", 0x5A) }, { "redo", ("y", "KeyY", 0x59) }, { "selectAll", ("a", "KeyA", 0x41) }, { "selectall", ("a", "KeyA", 0x41) },
      };
      if (!map.TryGetValue(name, out var k)) return;
      var command = name == "selectall" ? "selectAll" : name;
      View.Focus();
      try {
        await Web.CallDevToolsProtocolMethodAsync("Input.dispatchKeyEvent", Json.Stringify(new JObj {
          { "type", "rawKeyDown" }, { "key", k.key }, { "code", k.code }, { "windowsVirtualKeyCode", (double)k.vk }, { "modifiers", 2.0 }, { "commands", new List<object> { command } },
        }));
        await Web.CallDevToolsProtocolMethodAsync("Input.dispatchKeyEvent", Json.Stringify(new JObj {
          { "type", "keyUp" }, { "key", k.key }, { "code", k.code }, { "windowsVirtualKeyCode", (double)k.vk }, { "modifiers", 2.0 },
        }));
      } catch (Exception e) { Log.Error("edit", e); }
    }

    /// テーマに合わせてタイトルバーとメニューを暗くする
    public void SetDark(bool dark) {
      try { Win32.DarkTitleBar(Handle, dark); } catch { }
      menu.RenderMode = dark ? ToolStripRenderMode.Professional : ToolStripRenderMode.System;
      if (dark) menu.Renderer = new ToolStripProfessionalRenderer(new DarkColors());
      menu.BackColor = dark ? Color.FromArgb(0x2b, 0x2b, 0x2b) : SystemColors.MenuBar;
      menu.ForeColor = dark ? Color.FromArgb(0xe8, 0xe8, 0xe8) : SystemColors.MenuText;
      BackColor = dark ? Color.FromArgb(0x2b, 0x2b, 0x2b) : Color.FromArgb(0xf0, 0xf0, 0xf0);
      ApplyMenuColors(menu.Items, dark);
      darkMenu = dark;
    }
    bool darkMenu;

    void ApplyMenuColors(ToolStripItemCollection items, bool dark) {
      foreach (ToolStripItem i in items) {
        i.ForeColor = dark ? Color.FromArgb(0xe8, 0xe8, 0xe8) : SystemColors.MenuText;
        if (i is ToolStripMenuItem m) {
          m.DropDown.BackColor = dark ? Color.FromArgb(0x2b, 0x2b, 0x2b) : SystemColors.Menu;
          ApplyMenuColors(m.DropDownItems, dark);
        }
      }
    }

    public void RefreshMenuColors() { if (darkMenu) ApplyMenuColors(menu.Items, true); }

    class DarkColors : ProfessionalColorTable {
      static readonly Color Bg = Color.FromArgb(0x2b, 0x2b, 0x2b), Hi = Color.FromArgb(0x45, 0x45, 0x45), Line = Color.FromArgb(0x55, 0x55, 0x55);
      public override Color MenuStripGradientBegin => Bg;
      public override Color MenuStripGradientEnd => Bg;
      public override Color ToolStripDropDownBackground => Bg;
      public override Color ImageMarginGradientBegin => Bg;
      public override Color ImageMarginGradientMiddle => Bg;
      public override Color ImageMarginGradientEnd => Bg;
      public override Color MenuItemSelected => Hi;
      public override Color MenuItemSelectedGradientBegin => Hi;
      public override Color MenuItemSelectedGradientEnd => Hi;
      public override Color MenuItemPressedGradientBegin => Hi;
      public override Color MenuItemPressedGradientEnd => Hi;
      public override Color MenuItemBorder => Line;
      public override Color MenuBorder => Line;
      public override Color SeparatorDark => Line;
      public override Color SeparatorLight => Bg;
      public override Color CheckBackground => Hi;
      public override Color CheckSelectedBackground => Hi;
      public override Color CheckPressedBackground => Hi;
    }
  }
}
