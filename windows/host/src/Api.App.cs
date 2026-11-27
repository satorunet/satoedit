using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace SatoEdit {
  /// 起動・設定・メニュー・ウインドウ・ダイアログ
  partial class Bridge {
    void RegisterApp() {
      On("init", a => {
        form.RendererReady = true;
        var files = form.PendingFiles;
        form.PendingFiles = new List<string>();
        var grepRoot = form.PendingGrep;
        form.PendingGrep = "";
        return new JObj {
          { "prefs", Store.Prefs }, { "themeText", Store.ReadText(Store.ThemeFile) }, { "profilesText", Store.ReadText(Store.ProfilesFile) },
          { "pricesText", Store.ReadText(Store.PricesFile) },
          { "platform", "win32" }, { "version", Program.Version }, { "files", files.Cast<object>().ToList() }, { "grepRoot", grepRoot },
          { "secretsAvailable", Store.SecretsAvailable }, { "configDir", Store.ConfigDir }, { "homeDir", Store.Home },
          { "userName", Environment.UserName }, { "hostName", Environment.MachineName }, { "locale", CultureInfo.CurrentUICulture.Name },
          { "release", OsRelease() }, { "host", "webview2" },
        };
      });
      On("getPrefs", a => Store.Prefs);
      On("setPref", a => {
        var key = S(a, 0);
        if (!Store.PrefDefaults.Has(key)) return false;
        Store.Prefs[key] = Arg(a, 1);
        Store.SavePrefsSoon();
        if (key == "iconColor") form.SetIcon(S(a, 1));
        return true;
      });
      // すべて初期状態に戻す (自分のデータは残す) → 戻したあとの設定
      On("resetSettings", a => { Store.ResetPrefs(); form.SetIcon(Store.Prefs.Str("iconColor")); return Store.Prefs; });
      // 画面側で作った中身 (theme.json・profiles.json) を書く
      On("writeConfig", a => {
        var name = S(a, 0);
        if (name != "theme.json" && name != "profiles.json") throw new ArgumentException("name");
        Store.WriteAtomic(Store.F(name), S(a, 1));
        return true;
      });
      On("setMenu", a => { form.SetMenu(Arg(a, 0) as List<object> ?? new List<object>()); return true; });
      // ウインドウ枠の明るさ: 'light' | 'dark' | 'auto' (OS に合わせる)。画面の prefers-color-scheme もこれに合わせる
      On("setTheme", a => {
        var scheme = S(a, 0, "light");
        try {
          Web.Profile.PreferredColorScheme = scheme == "dark" ? Microsoft.Web.WebView2.Core.CoreWebView2PreferredColorScheme.Dark
            : scheme == "auto" ? Microsoft.Web.WebView2.Core.CoreWebView2PreferredColorScheme.Auto : Microsoft.Web.WebView2.Core.CoreWebView2PreferredColorScheme.Light;
        } catch (Exception ex) { Log.Error("scheme", ex); }
        form.SetDark(scheme == "dark" || (scheme == "auto" && SystemIsDark()));
        return true;
      });
      // 設定フォルダの小さなファイル (AI の利用の記録)
      On("readConfig", a => ConfigName(S(a, 0)) is string f ? Store.ReadText(f) : null);
      On("deleteConfig", a => { if (ConfigName(S(a, 0)) is string f && File.Exists(f)) File.Delete(f); return true; });
      OnBg("appendUsage", a => {
        lock (usageLock) {
          var list = Store.ReadJSON(Store.UsageFile, null) as List<object> ?? new List<object>();
          list.Add(O(a, 0));
          Directory.CreateDirectory(Store.ConfigDir);
          File.WriteAllText(Store.UsageFile, Json.Pretty(list), new System.Text.UTF8Encoding(false));
        }
        return true;
      });

      OnAsync("exportSettings", async a => {
        var o = O(a, 0);
        await Task.Yield();
        var file = Dialogs.Save(form, new JObj { { "title", o.Str("title") }, { "defaultPath", "satoru-editor-settings.json" }, { "filters", o.Arr("filters") } });
        if (file == null) return false;
        var kept = Store.Prefs.Clone();
        kept["recent"] = new List<object>();
        kept["carets"] = new JObj();
        kept["windowBounds"] = null;
        var profiles = Store.ReadJSON(Store.ProfilesFile, null) as List<object> ?? new List<object>();
        Store.WriteAtomic(file, Json.Pretty(new JObj { { "app", "satoru-editor" }, { "version", 1.0 }, { "prefs", kept }, { "theme", o["theme"] }, { "profiles", profiles } }));
        return true;
      });
      OnAsync("importSettings", async a => {
        var o = O(a, 0);
        await Task.Yield();
        var files = Dialogs.Open(form, new JObj { { "title", o.Str("title") }, { "single", true }, { "filters", o.Arr("filters") } });
        if (files.Count == 0) return new JObj { { "status", "cancel" } };
        var s = Store.ReadJSON(files[0], null) as JObj;
        if (s == null || s.Str("app") != "satoru-editor") return new JObj { { "status", "error" }, { "message", "エディタβの設定ファイルではありません。" } };
        var p = s.Obj("prefs");
        if (p != null) {
          foreach (var k in Store.PrefDefaults.Keys) {
            if (p.Has(k) && k != "recent" && k != "carets" && k != "windowBounds") Store.Prefs[k] = p[k];
          }
        }
        Store.SavePrefsNow();
        if (s["profiles"] is List<object> list) Store.WriteAtomic(Store.ProfilesFile, Json.Pretty(list));
        return new JObj { { "status", "ok" }, { "theme", s["theme"] }, { "prefs", Store.Prefs } };
      });

      // ダイアログ (題名や種類の名前は画面側が今の言語で渡す)
      OnAsync("openDialog", async a => { await Task.Yield(); return Dialogs.Open(form, O(a, 0)).Cast<object>().ToList(); });
      OnAsync("saveDialog", async a => { await Task.Yield(); return Dialogs.Save(form, O(a, 0)); });
      OnAsync("about", async a => {
        var o = O(a, 0);
        await Task.Yield();
        var buttons = (o.Arr("buttons") ?? new List<object> { "OK" }).Select(x => x as string ?? "").ToList();
        var r = Dialogs.Message(form, o.Str("title"), o.Str("message"), o.Str("detail"), buttons, 0, 0, form.Icon);
        if (r == 1 && o.Str("url") != "") MainForm.OpenExternal(o.Str("url"));
        return true;
      });

      // ウインドウ
      On("setTitle", a => { form.Text = S(a, 0); return true; });
      On("closeWindow", a => { form.BeginInvoke((Action)form.CloseNow); return true; });
      On("quit", a => { form.BeginInvoke((Action)form.Close); return true; });
      On("attention", a => { if (!form.ContainsFocus) Win32.Flash(form.Handle); return true; });
      On("growWindow", a => {
        if (form.WindowState != FormWindowState.Normal) return false;
        var add = (int)Math.Max(0, Math.Min(2000, Math.Round(N(a, 0)))) ;
        if (add == 0) return false;
        add = (int)Math.Round(add * form.DeviceDpi / 96.0);
        var b = form.Bounds;
        var area = Screen.FromControl(form).WorkingArea;
        var width = Math.Min(b.Width + add, area.Width);
        var x = b.X;
        if (x + width > area.X + area.Width) x = Math.Max(area.X, area.X + area.Width - width); // 右にはみ出すなら左へ
        form.Bounds = new System.Drawing.Rectangle(x, b.Y, width, b.Height);
        return true;
      });
      On("editCommand", a => { form.EditCommand(S(a, 0)); return true; });

      // シェル
      On("reveal", a => {
        var f = S(a, 0);
        try { Process.Start("explorer.exe", "/select,\"" + f + "\""); } catch (Exception e) { Log.Error("reveal", e); }
        return true;
      });
      On("openPath", a => {
        try { Process.Start(new ProcessStartInfo(S(a, 0)) { UseShellExecute = true }); return ""; } catch (Exception e) { return e.Message; }
      });
      On("openExternal", a => { MainForm.OpenExternal(S(a, 0)); return true; });
      On("copyText", a => { SetClipboardText(S(a, 0)); return true; });
      On("readClipboard", a => { try { return Clipboard.ContainsText() ? Clipboard.GetText() : ""; } catch { return ""; } });
      On("pathInfo", a => {
        var f = S(a, 0);
        return new JObj { { "dir", SafeDir(f) }, { "base", Path.GetFileName(f) }, { "sep", "\\" }, { "home", Store.Home } };
      });
      var icons = new Dictionary<string, string>();
      On("fileIcon", a => {
        var e = new string(S(a, 0, "txt").ToLowerInvariant().Where(c => (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')).Take(10).ToArray());
        if (e == "") e = "txt";
        if (icons.TryGetValue(e, out var url)) return url;
        try {
          var png = Win32.FileIconPng(e);
          url = png == null ? "" : "data:image/png;base64," + Convert.ToBase64String(png);
        } catch { url = ""; }
        icons[e] = url;
        return url;
      });
      // アプリの中のファイル (PDF の読み込みに使う文字の表など)
      OnBg("readAppFile", a => {
        var rel = S(a, 0).Replace('/', '\\');
        if (rel.Contains("..")) throw new ArgumentException("path");
        return Convert.ToBase64String(File.ReadAllBytes(Path.Combine(Program.AppRoot, rel)));
      });
    }

    static readonly object usageLock = new object();
    static string ConfigName(string name) => name == "ai-usage.json" ? Store.UsageFile : null;

    static bool SystemIsDark() {
      try {
        using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")) {
          return k?.GetValue("AppsUseLightTheme") is int v && v == 0;
        }
      } catch { return false; }
    }

    public static string SafeDir(string f) {
      try { return Path.GetDirectoryName(f) ?? f; } catch { return ""; }
    }

    public static void SetClipboardText(string text) {
      for (int i = 0; i < 5; i++) {
        try { Clipboard.SetText(text ?? "", TextDataFormat.UnicodeText); return; } catch { System.Threading.Thread.Sleep(40); }
      }
      if (string.IsNullOrEmpty(text)) Clipboard.Clear();
    }

    /// "10.0.19045" のような版 (Node の os.release() と同じ形)
    public static string OsRelease() {
      try {
        using (var k = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion")) {
          var major = k?.GetValue("CurrentMajorVersionNumber");
          var minor = k?.GetValue("CurrentMinorVersionNumber");
          var build = k?.GetValue("CurrentBuildNumber") as string;
          if (major != null && build != null) return $"{major}.{minor ?? 0}.{build}";
        }
      } catch { }
      var v = Environment.OSVersion.Version;
      return $"{v.Major}.{v.Minor}.{v.Build}";
    }

    /// ウインドウに落としたファイル (画面側が postMessageWithAdditionalObjects で渡す) → 開く
    void Dropped(Microsoft.Web.WebView2.Core.CoreWebView2WebMessageReceivedEventArgs e) {
      var files = new List<object>();
      try {
        foreach (var o in e.AdditionalObjects) {
          if (o is Microsoft.Web.WebView2.Core.CoreWebView2File f && File.Exists(f.Path)) files.Add(f.Path);
        }
      } catch (Exception ex) { Log.Error("drop", ex); }
      if (files.Count > 0) Send("open-files", files);
    }
  }
}
