using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;

namespace SatoEdit {
  /// 自己点検 (satoruEditor.exe --selftest=フォルダ [--fixtures=Mac 版の見本のフォルダ]):
  /// 実機で動くかを確かめ、画面の画像と結果 (report.json) をそのフォルダに書いて終了する。core/selftest.js と同じ考え方
  class SelfTest {
    readonly MainForm form;
    readonly string dir;
    readonly JObj steps = new JObj();
    readonly List<object> errors = new List<object>();
    CoreWebView2 Web => form.Web;

    public SelfTest(MainForm form, string dir) { this.form = form; this.dir = dir; }

    static Task Wait(int ms) => Task.Delay(ms);

    /// 画面の中で JavaScript を動かす (Promise は終わるまで待つ) → 値 (JSON から読んだもの)
    async Task<object> Js(string code) {
      var r = await Web.CallDevToolsProtocolMethodAsync("Runtime.evaluate", Json.Stringify(new JObj {
        { "expression", code }, { "awaitPromise", true }, { "returnByValue", true },
      }));
      var o = Json.Parse(r) as JObj;
      if (o?.Obj("exceptionDetails") is JObj ex) {
        var msg = ex.Obj("exception")?.Str("description") ?? ex.Str("text");
        throw new Exception("JS: " + msg);
      }
      return o?.Obj("result")?["value"];
    }

    async Task Shot(string name) {
      try {
        using (var fs = File.Create(Path.Combine(dir, name + ".png"))) {
          var cap = Web.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, fs);
          if (await Task.WhenAny(cap, Task.Delay(6000)) != cap) errors.Add("画面を撮れませんでした: " + name);
        }
      } catch (Exception e) { errors.Add("shot " + name + ": " + e.Message); }
    }

    async Task Step(string name, Func<Task<object>> fn) {
      Log.Write("selftest: " + name);
      try {
        var t = fn();
        if (await Task.WhenAny(t, Task.Delay(60000)) != t) { errors.Add(name + ": 時間切れ"); return; }
        steps[name] = await t;
      } catch (Exception e) { errors.Add(name + ": " + e); }
      // 途中で止まっても、そこまでの結果は残す
      try { File.WriteAllText(Path.Combine(dir, "report-partial.json"), Json.Pretty(new JObj { { "steps", steps }, { "errors", errors } }), new UTF8Encoding(false)); } catch { }
    }

    async Task Key(string key, string code, int vk, int modifiers = 0, string text = null) {
      var down = new JObj { { "type", text != null ? "keyDown" : "rawKeyDown" }, { "key", key }, { "code", code }, { "windowsVirtualKeyCode", (double)vk }, { "modifiers", (double)modifiers } };
      if (text != null) down["text"] = text;
      await Web.CallDevToolsProtocolMethodAsync("Input.dispatchKeyEvent", Json.Stringify(down));
      await Web.CallDevToolsProtocolMethodAsync("Input.dispatchKeyEvent", Json.Stringify(new JObj { { "type", "keyUp" }, { "key", key }, { "code", code }, { "windowsVirtualKeyCode", (double)vk }, { "modifiers", (double)modifiers } }));
    }

    async Task Type(string text) => await Web.CallDevToolsProtocolMethodAsync("Input.insertText", Json.Stringify(new JObj { { "text", text } }));

    static string Q(string s) => Json.Quote(s);

    public async Task Run() {
      try {
        Directory.CreateDirectory(dir);
        for (int i = 0; i < 200 && (Web == null || !form.RendererReady); i++) await Wait(100);
        for (int i = 0; i < 100; i++) {
          try { if (await Js("document.body.classList.contains('ready')") is bool b && b) break; } catch { }
          await Wait(100);
        }
        await Wait(1000);
        await Web.CallDevToolsProtocolMethodAsync("Runtime.enable", "{}");
        Web.GetDevToolsProtocolEventReceiver("Runtime.exceptionThrown").DevToolsProtocolEventReceived += (s, e) => errors.Add("exception: " + Short(e.ParameterObjectAsJson));
        Web.GetDevToolsProtocolEventReceiver("Runtime.consoleAPICalled").DevToolsProtocolEventReceived += (s, e) => {
          var o = Json.TryParse(e.ParameterObjectAsJson) as JObj;
          if (o?.Str("type") == "error") errors.Add("console: " + Short(e.ParameterObjectAsJson));
        };
        await RunSteps();
      } catch (Exception e) {
        errors.Add("selftest: " + e);
      }
      try { File.WriteAllText(Path.Combine(dir, "report.json"), Json.Pretty(new JObj { { "steps", steps }, { "errors", errors } }), new UTF8Encoding(false)); } catch { }
      form.CloseNow();
    }

    static string Short(string s) => s.Length > 600 ? s.Substring(0, 600) : s;

    public static string FixturesArg;

    async Task RunSteps() {
      // テキスト一覧の覚えごとは、点検の前のものに戻す (点検で開いたファイルを一覧に残さない)
      var keep = new[] { "libraryFiles", "libraryPinned", "sharedLinks", "libraryFolderOrder", "libraryFolderIcons", "librarySelectedGroup", "libraryFolderExpanded", "lastPaperMode", "genkoHorizontal", "librarySeeded", "libraryVisible", "libraryCustomFolder", "libraryCustomRecent", "libraryExternalFolders", "libraryFolderPaneHeight", "libraryModes" };
      var saved = keep.ToDictionary(k => k, k => Json.Stringify(Store.Prefs[k]));
      try { await RunStepsInner(); } finally {
        foreach (var kv in saved) { Store.Prefs[kv.Key] = Json.Parse(kv.Value); }
        Store.SavePrefsNow();
      }
    }

    async Task RunStepsInner() {
      var work = Path.Combine(dir, "work");
      Directory.CreateDirectory(work);
      string P(string f) => Q(Path.Combine(work, f));

      await Step("environment", async () => new JObj {
        { "os", Bridge.OsRelease() }, { "clr", Environment.Version.ToString() }, { "webview", Web.Environment.BrowserVersionString },
        { "locale", System.Globalization.CultureInfo.CurrentUICulture.Name }, { "language", await Js("document.documentElement.lang") },
        { "menu", form.MainMenuStrip.Items.Cast<ToolStripItem>().Select(m => (object)m.Text).ToList() },
        { "title", form.Text }, { "configDir", Store.ConfigDir },
      });
      await Step("prepare", async () => {
        File.WriteAllBytes(Path.Combine(work, "sjis.txt"), Codec.Encode("日本語 Shift_JIS のファイル\n2 行目\tタブ　全角 半角\nhttps://example.com/\n", "shiftJIS", "crlf"));
        File.WriteAllText(Path.Combine(work, "sample.js"), "// コメント\nconst s = \"文字列\"; // 42\nfunction f(a) {\n\treturn a + 1;\n}\n");
        File.WriteAllText(Path.Combine(work, "sakubun.txt"), "春の遠足\n山田太郎\n\n先週の金曜日、学校の遠足で動物園に行きました。天気はとても良くて、朝から楽しみでした。\n「早く行こう。」\nと、友だちが言いました。\n");
        File.WriteAllBytes(Path.Combine(work, "euc.txt"), Codec.Encode("EUC-JP の文章 ①\n", "eucJP", "lf"));
        File.WriteAllBytes(Path.Combine(work, "jis.txt"), Codec.Encode("JIS の文章 ｶﾅ\n", "iso2022JP", "lf"));
        await Task.Yield();
        return true;
      });
      await Step("libraryAtStart", async () => await Js("({ pref: __app.prefs.libraryVisible, hidden: document.getElementById('library-pane').hidden, startTab: __app.tabs[0].paperMode, paperEnabled: __app.prefs.paperEnabled })"));
      await Step("openFiles", async () => {
        await Js("(async () => { await __app.openPath(" + P("sjis.txt") + "); await __app.openPath(" + P("euc.txt") + "); await __app.openPath(" + P("jis.txt") + "); await __app.openPath(" + P("sample.js") + "); })()");
        await Wait(600);
        return await Js("({ tabs: __app.tabs.map(t => t.name + ':' + t.encoding + ':' + t.lineEnding), status: document.getElementById('status-cells').innerText,"
          + " font: getComputedStyle(document.querySelector('.cm-scroller')).fontFamily, tokens: document.querySelectorAll('[class^=tok-]').length, title: document.title })");
      });
      steps["windowTitle"] = form.Text;
      await Shot("1-editor");
      await Step("saveRoundTrip", async () => {
        var saved = await Js("(async () => { __app.prefs.encryptionEnabled = false; __app.activate(__app.tabs.find(t => t.name === 'sjis.txt'));"
          + " __app.active.editor.insertAtCursorEnd('追記①'); const ok = await __app.save(__app.active); return ok; })()");
        var d = Codec.Decode(File.ReadAllBytes(Path.Combine(work, "sjis.txt")));
        return new JObj { { "saved", saved }, { "encoding", d.Encoding }, { "lineEnding", d.LineEnding }, { "hasAppend", d.Text.Contains("追記①") }, { "recent", Store.Prefs.Arr("recent")?.FirstOrDefault() } };
      });
      await Step("deviceEncryption", async () => {
        return await Js("(async () => { const k = await window.api.makeKey({ kind: 'device' }); const file = " + P("secret.txt") + ";"
          + " const w = await window.api.writeFile({ path: file, text: 'ひみつ\\n', encoding: 'utf8', lineEnding: 'lf', encToken: k.enc.token });"
          + " const back = await window.api.readFile(file, {}); return { make: k.status, label: k.enc.label, write: w.status, text: back.text, backLabel: back.enc && back.enc.label }; })()");
      });
      await Step("passwordEncryption", async () => {
        return await Js("(async () => { const k = await window.api.makeKey({ kind: 'password', password: 'password-123' }); const file = " + P("pw.txt") + ";"
          + " await window.api.writeFile({ path: file, text: 'パスワード\\n', encoding: 'shiftJIS', lineEnding: 'crlf', encToken: k.enc.token });"
          + " const locked = await window.api.readFile(file, {}); const wrong = await window.api.readFile(file, { creds: { password: 'x' } });"
          + " const ok = await window.api.readFile(file, { creds: { password: 'password-123' } });"
          + " const short = await window.api.makeKey({ kind: 'password', password: 'abc' });"
          + " return { locked: locked.status + ':' + locked.need, wrong: wrong.status + ':' + wrong.code + ':' + wrong.message, ok: ok.text + ':' + ok.encoding, short: short.message }; })()");
      });
      if (FixturesArg != null && Directory.Exists(FixturesArg)) {
        await Step("macFixtures", async () => {
          string F(string n) => Q(Path.Combine(FixturesArg, n));
          return await Js("(async () => { const r = {};"
            + " for (const e of ['utf8','utf8BOM','shiftJIS','eucJP','iso2022JP','utf16LE','utf16BE']) { const x = await window.api.readFile(" + Q(FixturesArg + "\\mac-") + " + e + '.txt', {}); r[e] = x.encoding + ':' + x.lineEnding + ':' + JSON.stringify(x.text); }"
            + " const pw = await window.api.readFile(" + F("mac-password.enc") + ", { creds: { password: 'ひみつのpassword' } }); r.password = pw.status + ':' + JSON.stringify(pw.text);"
            + " const pc = await window.api.readFile(" + F("mac-passcode.enc") + ", { creds: { password: '123456' } }); r.passcode = pc.status + ':' + JSON.stringify(pc.text);"
            + " const kf = await window.api.readFile(" + F("mac-keyfile.enc") + ", { creds: { keyFile: " + F("mac.satorukey") + " } }); r.keyfile = kf.status + ':' + JSON.stringify(kf.text);"
            + " const ts = await window.api.readFile(" + F("mac-twostep.enc") + ", {}); r.twoStep = ts.status + ':' + (ts.need || ts.code);"
            + " return r; })()");
        });
      }
      await Step("grep", async () => {
        return await Js("new Promise(resolve => { const found = []; const id = 'g' + Date.now();"
          + " window.api.on('grep:matches', (gid, list) => { if (gid === id) list.forEach(m => found.push(m.file.split('\\\\').pop() + ':' + m.line)); });"
          + " window.api.on('grep:done', (gid, r) => { if (gid === id) resolve({ found, r }); });"
          + " window.api.grepStart(id, " + Q(work) + ", { pattern: '遠足' }); })");
      });
      await Step("treeAndFiles", async () => {
        return await Js("(async () => { const list = await window.api.listDir(" + Q(work) + "); const c = await window.api.createEntry(" + Q(work) + ", 'new.txt', false);"
          + " const r = await window.api.renameEntry(c.path, 'renamed.txt'); const bad = await window.api.createEntry(" + Q(work) + ", 'a:b', false);"
          + " const tr = await window.api.trashEntry(r.path); const info = await window.api.fileInfo(r.path); const find = await window.api.findFiles(" + Q(work) + ", 'sjis');"
          + " return { list: list.map(e => e.name).join(','), created: c.status, renamed: r.status, bad: bad.message, trashed: tr.status, exists: info.exists, find: find.files.length }; })()");
      });
      await Step("genko", async () => {
        await Js("(async () => { __app.prefs.paperEnabled = true; __app.prefs.genkoFurigana = true; __app.applyPrefs(); await __app.openPath(" + P("sakubun.txt") + "); __app.setPaperMode(__app.active, 1); })()");
        await Wait(2500);
        return await Js("({ status: document.getElementById('status-cells').innerText, ruby: document.querySelectorAll('.gk-ruby').length, sheets: document.querySelectorAll('.genko-sheet').length })");
      });
      await Shot("2-genko");
      await Step("genkoPDF", async () => {
        var ok = await Js("__app.exportPDF(__app.active, " + Q(Path.Combine(dir, "genko.pdf")) + ")");
        return new JObj { { "ok", ok }, { "size", File.Exists(Path.Combine(dir, "genko.pdf")) ? (double)new FileInfo(Path.Combine(dir, "genko.pdf")).Length : 0 } };
      });
      await Step("a4", async () => {
        await Js("__app.setPaperMode(__app.active, 2)");
        await Wait(500);
        var ok = await Js("__app.exportPDF(__app.active, " + Q(Path.Combine(dir, "a4.pdf")) + ")");
        var docx = await Js("window.api.exportDocx({ path: " + Q(Path.Combine(dir, "a4.docx")) + ", paragraphs: [{ text: '春の遠足', align: 'center' }, { text: '山田太郎', align: 'right' }, { text: '本文です。', indent: true }] })");
        return new JObj { { "ok", ok }, { "docx", docx }, { "size", File.Exists(Path.Combine(dir, "a4.pdf")) ? (double)new FileInfo(Path.Combine(dir, "a4.pdf")).Length : 0 } };
      });
      await Shot("3-a4");
      await Step("plainPDF", async () => {
        await Js("(async () => { __app.setPaperMode(__app.active, 0); __app.activate(__app.tabs.find(t => t.name === 'sample.js')); })()");
        var ok = await Js("__app.exportPDF(__app.active, " + Q(Path.Combine(dir, "plain.pdf")) + ")");
        return new JObj { { "ok", ok }, { "size", File.Exists(Path.Combine(dir, "plain.pdf")) ? (double)new FileInfo(Path.Combine(dir, "plain.pdf")).Length : 0 } };
      });
      await Step("keyboard", async () => {
        form.Activate();
        form.View.Focus();
        await Js("__app.focusEditor()");
        var before = await Js("__app.active.editor.getText()") as string;
        await Type("xあ");
        await Wait(300);
        var typed = await Js("__app.active.editor.getText()") as string;
        await Key("z", "KeyZ", 0x5A, 2);
        await Key("z", "KeyZ", 0x5A, 2);
        await Wait(300);
        var undone = (await Js("__app.active.editor.getText()") as string) == before;
        await Key("g", "KeyG", 0x47, 2);
        await Wait(400);
        var dialog = await Js("(document.querySelector('.modal-title') || {}).textContent || ''");
        await Key("Escape", "Escape", 0x1B);
        await Wait(300);
        var closed = await Js("!document.querySelector('.modal-title')");
        // メニューバーの項目を押したときも同じ動作になるか (Ctrl+G の項目)
        ToolStripMenuItem found = null;
        void Walk(ToolStripItemCollection items) { foreach (var it in items.OfType<ToolStripMenuItem>()) { if (it.ShortcutKeyDisplayString == "Ctrl+G") found = it; Walk(it.DropDownItems); } }
        Walk(form.MainMenuStrip.Items);
        found?.PerformClick();
        await Wait(500);
        var fromMenu = await Js("(document.querySelector('.modal-title') || {}).textContent || ''");
        await Key("Escape", "Escape", 0x1B);
        await Wait(200);
        // 編集メニューのコピー・貼り付け (本体から送る編集の命令)
        await Js("(() => { const v = __app.active.editor.view; v.dispatch({ selection: { anchor: 0, head: 5 } }); v.focus(); })()");
        Clipboard.Clear();
        form.EditCommand("copy");
        await Wait(500);
        var copied = Clipboard.ContainsText() ? Clipboard.GetText() : "";
        return new JObj { { "typed", (double)((typed?.Length ?? 0) - (before?.Length ?? 0)) }, { "undone", undone }, { "dialog", dialog }, { "closed", closed }, { "fromMenu", fromMenu }, { "menuItem", found?.Text }, { "copied", copied } };
      });
      await Step("altMenu", async () => {
        // Alt+F でメニューバーの「ファイル」が開くか (文字を打っている WebView から)
        form.Activate();
        form.View.Focus();
        await Js("__app.focusEditor()");
        await Wait(300);
        SendKeys.SendWait("%f");
        await Wait(600);
        var first = form.MainMenuStrip.Items[0] as ToolStripMenuItem;
        var opened = first?.DropDown.Visible ?? false;
        SendKeys.SendWait("{ESC}{ESC}");
        await Wait(300);
        return new JObj { { "opened", opened }, { "foreground", Form.ActiveForm == form } };
      });
      await Step("secondInstance", async () => {
        // もう 1 つ起動すると、ファイルはこのウインドウのタブで開く
        var file = Path.Combine(work, "second.txt");
        File.WriteAllText(file, "2 つめの起動から\n");
        var p = System.Diagnostics.Process.Start(Application.ExecutablePath, "\"" + file + "\"");
        var exited = await Task.Run(() => p.WaitForExit(15000));
        await Wait(1500);
        return new JObj { { "exited", exited }, { "tabs", await Js("__app.tabs.map(t => t.name).join(',')") } };
      });
      await Step("screenshot", async () => {
        var visible = await Js("window.api.screenshot({ mode: 'visible', rect: { x: 0, y: 60, width: 600, height: 300 }, action: 'save', path: " + Q(Path.Combine(dir, "shot-visible.png")) + " })");
        var whole = await Js("window.api.screenshot({ mode: 'whole', width: 700, action: 'save', path: " + Q(Path.Combine(dir, "shot-whole.png")) + ", html: '<!doctype html><meta charset=\"utf-8\"><body style=\"margin:0;background:#2b2b2b;color:#eee;font:14px monospace\">' + Array.from({ length: 120 }, (x, i) => '<div>' + (i + 1) + ' 行目 全体の画像</div>').join('') + '</body>' })");
        var copy = await Js("window.api.screenshot({ mode: 'visible', rect: { x: 0, y: 0, width: 200, height: 100 }, action: 'copy' })");
        var img = Clipboard.GetImage();
        return new JObj { { "visible", visible }, { "whole", whole }, { "copy", copy }, { "clipboard", img == null ? "none" : img.Width + "x" + img.Height } };
      });
      await Step("pdfImport", async () => await Js("(async () => { const r = {}; for (const n of ['a4', 'plain', 'genko']) { const x = await window.api.importPDF(" + Q(dir + "\\") + " + n + '.pdf'); r[n] = x.status === 'ok' ? x.text.split('\\n').slice(0, 4).join(' / ') + ' (' + x.pages + ')' : x.message; } return r; })()"));
      await Step("association", async () => {
        return await Js("(async () => { const before = await window.api.assocStatus();"
          + " const applied = await window.api.assocApply({ extensions: ['txt', 'satoedittest'], fileMenu: true, folderMenu: true });"
          + " const during = await window.api.assocStatus();"
          + " const restored = await window.api.assocApply({ extensions: before.extensions, fileMenu: before.fileMenu, folderMenu: before.folderMenu });"
          + " const after = await window.api.assocStatus();"
          + " return { before: [before.fileMenu, before.folderMenu, before.extensions], applied, during: [during.fileMenu, during.folderMenu, during.extensions], restored, after: [after.fileMenu, after.folderMenu, after.extensions] }; })()");
      });
      await Step("customization", async () => {
        await Js("__app.run('settings.open:keys')");
        await Wait(600);
        var rows = await Js("document.querySelectorAll('.key-row').length");
        await Shot("5-keys");
        await Js("document.querySelector('.modal-buttons button').click()");
        return rows;
      });
      await Step("pluginsReal", async () => {
        var folder = Path.Combine(Store.ConfigDir, "plugins", "selftest-plugin");
        Directory.CreateDirectory(folder);
        File.WriteAllText(Path.Combine(folder, "manifest.json"), "{\"id\":\"selftest-plugin\",\"name\":\"Selftest\",\"version\":\"1.0.0\",\"main\":\"main.js\",\"permissions\":[]}");
        File.WriteAllText(Path.Combine(folder, "main.js"), "satoru.commands.register({ id: 'up', title: 'Upper', key: 'cmd+shift+u' }, () => {"
          + " const s = satoru.editor.getText(); satoru.editor.setText(s.toUpperCase() + '\\n' + satoru.editor.language()); satoru.storage.set('n', 3); console.log('n=' + satoru.storage.get('n', 0)); });"
          + " satoru.on('beforeSave', () => console.log('beforeSave'));");
        await Js("(async () => { __app.newTab(); __app.active.editor.setText('hello plugin', true); await __app.plugins.loadAll(); })()");
        await Wait(800);
        await Js("__app.run('plugin.run:selftest-plugin/up')");
        await Wait(1500);
        var r = await Js("({ text: __app.active.editor.getText(), log: __app.plugins.plugins.filter(p => p.manifest.id === 'selftest-plugin').map(p => p.log.map(l => l.text)) })");
        Directory.Delete(folder, true);
        await Js("__app.plugins.loadAll()");
        return r;
      });
      await Step("pluginInstall", async () => {
        // フォルダから入れる → 一覧に出る → 外す
        var src = Path.Combine(work, "plug-src");
        Directory.CreateDirectory(src);
        File.WriteAllText(Path.Combine(src, "manifest.json"), "{\"id\":\"selftest-install\",\"name\":\"Install\",\"version\":\"1.0.0\",\"main\":\"main.js\",\"permissions\":[\"network\"]}");
        File.WriteAllText(Path.Combine(src, "main.js"), "console.log('hi');");
        return await Js("(async () => { const p = await window.api.pluginPrepare({ path: " + Q(src) + " }); const c = await window.api.pluginCommit(p.token);"
          + " const list = (await window.api.pluginList()).map(x => x.manifest.id); const u = await window.api.pluginUninstall('selftest-install');"
          + " const bad = await window.api.pluginPrepare({ url: 'ftp://x' }); return { prepared: p.ok, committed: c.ok, list, uninstalled: u, bad: bad.error }; })()");
      });
      await Step("fileIcon", async () => await Js("(async () => { const u = await window.api.fileIcon('html'); return u ? u.slice(0, 22) + '… (' + u.length + ')' : ''; })()"));
      await Step("diffPanel", async () => {
        await Js("(async () => { await __app.openPath(" + P("sample.js") + "); const v = __app.active.editor.view; v.dispatch({ changes: { from: 0, insert: '// ADDED\\n' }, userEvent: 'input' }); __app.run('view.diff'); })()");
        await Wait(900);
        var r = await Js("({ rows: document.querySelectorAll('#diff-pane .diff-row').length, added: Array.from(document.querySelectorAll('#diff-pane .diff-added')).map(e => e.textContent) })");
        await Shot("7-diff");
        await Js("__app.run('view.diff')");
        return r;
      });
      await Step("collab", async () => {
        // 同じ PC の中で、ホストとゲストを本体の部品どうしでつなぐ (Mac 版と同じ暗号の 1 行ずつのやりとり)
        var got = new List<object>();
        var code = CollabCipher.NewCode();
        var hostEv = new CollabNet.Events { OnOpen = (i, a) => { }, OnMessage = (i, m) => { lock (got) got.Add("host<-" + Json.Stringify(m)); }, OnClose = (i, info) => { } };
        var host = CollabNet.Host(0, code, hostEv);
        var guestEv = new CollabNet.Events { OnOpen = (i, a) => { }, OnMessage = (i, m) => { lock (got) got.Add("guest<-" + Json.Stringify(m)); }, OnClose = (i, info) => { } };
        var guest = CollabNet.Join("127.0.0.1", host.Port, code, guestEv);
        await Wait(800);
        guest.Send(0, new JObj { { "t", "hello" }, { "name", "ゲスト" } });
        await Wait(500);
        host.Send(1, new JObj { { "t", "welcome" }, { "text", "こんにちは😀" } });
        await Wait(500);
        var closed = new List<object>();
        var badEv = new CollabNet.Events { OnOpen = (i, a) => { }, OnMessage = (i, m) => { }, OnClose = (i, info) => { lock (closed) closed.Add(Json.Stringify(info)); } };
        var bad = CollabNet.Join("127.0.0.1", host.Port, "WRONGCODE", badEv);
        await Wait(300);
        bad.Send(0, new JObj { { "t", "hello" } });
        await Wait(800);
        guest.Stop(); bad.Stop(); host.Stop();
        lock (got) return new JObj { { "messages", got.ToList() }, { "port", (double)host.Port }, { "wrongCodeClosed", closed.ToList() }, { "addresses", CollabNet.LocalAddresses().Cast<object>().ToList() } };
      });
      await Step("collabApi", async () => await Js("(async () => { const r = await window.api.collabHost(0); await window.api.collabStop(); return { status: r.status, code: /^[A-Z2-9]{4}-/.test(r.code || ''), port: r.port > 0, addresses: (r.addresses || []).length }; })()"));
      await Step("servers", async () => {
        return await Js("(async () => { const s = await window.api.serverSave({ name: 'test', kind: 'sftp', host: '127.0.0.1', port: 1, user: 'x', auth: 'password' }, 'pw');"
          + " const has = await window.api.serverHasPassword(s.server.id); const r = await window.api.remoteCall(s.server.id, 'list', '/');"
          + " const f = await window.api.serverSave({ name: 'ftp', kind: 'ftp', host: '127.0.0.1', port: 1, user: 'x' }, 'pw'); const r2 = await window.api.remoteCall(f.server.id, 'list', '/');"
          + " await window.api.serverDelete(s.server.id); await window.api.serverDelete(f.server.id); return { saved: s.status, has, sftp: r.message, ftp: r2.message }; })()");
      });
      // 本物のサーバ (Mac の test/servers.js を外から見えるように動かしたもの) があれば、読み書きまで確かめる
      foreach (var kind in new[] { "sftp", "ftp" }) {
        var at = Environment.GetEnvironmentVariable("SATOEDIT_TEST_" + kind.ToUpperInvariant());
        if (string.IsNullOrEmpty(at)) continue;
        var hp = at.Split(':');
        await Step("server-" + kind, async () => await Js("(async () => { const s = (await window.api.serverSave({ name: 't', kind: " + Q(kind) + ", host: " + Q(hp[0]) + ", port: " + hp[1] + ", user: 'taro', auth: 'password' }, 'ひみつ pw')).server;"
          + " const out = {}; const home = await window.api.remoteCall(s.id, 'home'); out.home = home.value;"
          + " const list = await window.api.remoteCall(s.id, 'list', '/www'); out.list = list.status === 'ok' ? list.value.map(e => e.name + (e.dir ? '/' : '')) : list.message;"
          + " const r = await window.api.remoteRead(s.id, '/www/index.html', {}); out.read = r.status + ':' + r.encoding + ':' + r.lineEnding + ':' + JSON.stringify(r.text) + ':' + (r.remote && r.remote.url);"
          + " const w = await window.api.remoteWrite(s.id, '/www/index.html', { text: r.text + '<p>追記</p>\\n', encoding: r.encoding, lineEnding: r.lineEnding }); out.write = w.status;"
          + " const r2 = await window.api.remoteRead(s.id, '/www/index.html', {}); out.reread = JSON.stringify(r2.text);"
          + " out.mkdir = (await window.api.remoteCall(s.id, 'mkdir', '/www/sub')).status; out.create = (await window.api.remoteCall(s.id, 'create', '/www/sub/new.txt')).status;"
          + " out.rename = (await window.api.remoteCall(s.id, 'rename', '/www/sub/new.txt', '/www/sub/renamed.txt')).status;"
          + " out.removeFile = (await window.api.remoteCall(s.id, 'remove', '/www/sub/renamed.txt', false)).status; out.removeDir = (await window.api.remoteCall(s.id, 'remove', '/www/sub', true)).status;"
          + " await window.api.serverDelete(s.id);"
          + " const bad = (await window.api.serverSave({ name: 'b', kind: " + Q(kind) + ", host: " + Q(hp[0]) + ", port: " + hp[1] + ", user: 'taro', auth: 'password' }, 'wrong')).server;"
          + " out.wrong = (await window.api.remoteCall(bad.id, 'list', '/')).message; await window.api.serverDelete(bad.id); return out; })()"));
      }
      var aiAt = Environment.GetEnvironmentVariable("SATOEDIT_TEST_AI");
      if (!string.IsNullOrEmpty(aiAt)) {
        // OpenAI 互換の見本サーバに送って、少しずつ届く答えと使用量の記録を確かめる
        await Step("aiStream", async () => await Js("(async () => { await window.api.setPref('aiCustomBaseURL', 'http://" + aiAt + "/v1'); __app.prefs.aiCustomBaseURL = 'http://" + aiAt + "/v1';"
          + " await window.api.aiSetKey('custom', 'sk-test'); const models = await window.api.aiListModels('custom');"
          + " const deltas = []; const off1 = window.api.on('ai:delta', (id, t) => { if (id === 'st2') deltas.push(t); });"
          + " const done = new Promise(res => window.api.on('ai:done', (id, r) => { if (id === 'st2') res(r); }));"
          + " await window.api.aiSend('st2', { provider: 'custom', model: 'mock-a', system: 's', prompt: 'p' }); const r = await done; off1();"
          + " const usage = await window.api.aiUsage(); await window.api.aiSetKey('custom', ''); await window.api.setPref('aiCustomBaseURL', 'http://localhost:11434/v1');"
          + " return { models: models.models, deltas, usage: r.usage, logged: usage.summary.total.count }; })()"));
      }
      await Step("ai", async () => await Js("(async () => { const s = await window.api.aiStatus(); const u = await window.api.aiUsage();"
        + " const done = new Promise(res => window.api.on('ai:done', (id, r) => { if (id === 'st1') res(r); })); window.api.aiSend('st1', { provider: 'custom', model: 'x', system: 's', prompt: 'p', noLog: true });"
        + " const r = await done; return { providers: Object.keys(s), usage: !!u.summary, custom: r.error ? r.error.slice(0, 80) : 'ok' }; })()"));
      await Step("localLLM", async () => {
        await Js("__app.run('ai.localLLM')");
        await Wait(2500);
        var r = await Js("({ compat: (document.querySelector('.llm-compat') || {}).textContent, state: (document.querySelector('.llm-state') || {}).textContent, rows: document.querySelectorAll('.llm-row').length })");
        await Shot("8-localllm");
        await Js("(document.querySelector('.float-window .float-close') || { click() {} }).click()");
        return r;
      });
      await Step("settings", async () => {
        await Js("__app.run('settings.open:theme')");
        await Wait(800);
        return await Js("({ cards: document.querySelectorAll('.theme-card').length, icons: Array.from(document.querySelectorAll('.icon-color img')).filter(i => i.naturalWidth > 0).length })");
      });
      await Shot("4-settings");
      await Step("english", async () => {
        await Js("window.api.setPref('language', 'en')");
        await Wait(400);
        var menu = form.MainMenuStrip.Items.Cast<ToolStripItem>().Select(m => (object)m.Text).ToList();
        await Js("window.api.setPref('language', 'auto')");
        await Wait(300);
        return menu;
      });
await Step("furigana", async () => await Js("window.api.furigana('先週の金曜日、学校の遠足で美味しいお寿司を食べました').then(r => r.map(x => x.reading))"));
      await RunLibrarySteps(work);
      await RunMacParitySteps();
      await RunUpdateSteps(work);
      await Step("closeFlow", async () => {
        await Js("(() => { for (let i = 0; i < 3; i++) { const b = document.querySelector('.modal-buttons button'); if (b) b.click(); } })()");
        await Wait(300);
        // 変更のある文書があると、閉じる前に確かめる画面が出る
        await Js("(() => { __app.newTab(); __app.active.editor.setText('未保存', false); __app.active.editor.view.dispatch({ changes: { from: 0, insert: 'x' } }); })()");
        form.Close();
        await Wait(800);
        var title = await Js("(document.querySelector('.modal-title') || {}).textContent || ''");
        await Shot("9-close");
        await Js("(() => { const b = Array.from(document.querySelectorAll('.modal-buttons button')).find(x => x.textContent.includes('キャンセル') || x.textContent.includes('Cancel')); if (b) b.click(); })()");
        await Wait(300);
        return new JObj { { "asked", title }, { "stillOpen", !form.IsDisposed } };
      });
    }
  
    /// 思ったとおりでなければエラーに数える
    void Expect(bool ok, string what) { if (!ok) errors.Add("期待と違う: " + what); }

    /// アップデート: 新しい版を見つける・最新のとき・とばした版・インストーラーを取ってくる・知らせる画面・設定とメニュー。
    /// GitHub には問い合わせず、点検のフォルダに置いた JSON (releases/latest と同じ形) とファイルを使う
    async Task RunUpdateSteps(string work) {
      var upd = Path.Combine(work, "update");
      Directory.CreateDirectory(upd);
      var payload = new byte[256 * 1024];
      new Random(7).NextBytes(payload);
      payload[0] = (byte)'M'; payload[1] = (byte)'Z';
      var fake = Path.Combine(upd, "fake-setup.exe");
      File.WriteAllBytes(fake, payload);
      string Release(string tag, long size, params string[] names) => Json.Pretty(new JObj {
        { "tag_name", tag }, { "name", tag }, { "draft", false }, { "prerelease", false },
        { "html_url", "https://github.com/satorunet/satoedit/releases/tag/" + tag },
        { "assets", names.Select(n => (object)new JObj { { "name", n }, { "size", (double)size }, { "browser_download_url", new Uri(fake).AbsoluteUri } }).ToList() },
      });
      var newer = Path.Combine(upd, "newer.json");
      File.WriteAllText(newer, Release("v9.9.9", payload.Length, "satoruEditor-9.9.9-mac.dmg", "SatoruEditor-9.9.9-win-x64-setup.exe"));
      var same = Path.Combine(upd, "same.json");
      File.WriteAllText(same, Release("v" + Program.Version, payload.Length, "SatoruEditor-" + Program.Version + "-win-x64-setup.exe"));
      var older = Path.Combine(upd, "older.json");
      File.WriteAllText(older, Release("v0.9.0", payload.Length, "SatoruEditor-0.9.0-win-x64-setup.exe"));
      var badSize = Path.Combine(upd, "badsize.json");
      File.WriteAllText(badSize, Release("v9.9.9", payload.Length + 10, "SatoruEditor-9.9.9-win-x64-setup.exe"));

      await Step("updateCheck", async () => {
        var n = await Updater.Check(newer, Program.Version);
        var s = await Updater.Check(same, Program.Version);
        var o = await Updater.Check(older, Program.Version);
        var missing = await Updater.Check(Path.Combine(upd, "none.json"), Program.Version);
        Expect(n.Str("status") == "update" && n.Str("version") == "9.9.9", "新しい版を見つける " + Json.Stringify(n));
        Expect(n.Obj("asset")?.Str("name") == "SatoruEditor-9.9.9-win-x64-setup.exe", "Windows 用のファイルを選ぶ");
        Expect(s.Str("status") == "latest" && o.Str("status") == "latest", "同じ版・古い版なら最新");
        Expect(missing.Str("status") == "error", "読めなければエラー");
        Expect(Program.Version == typeof(Program).Assembly.GetName().Version.ToString(3), "版 " + Program.Version);
        return new JObj { { "current", Program.Version }, { "newer", n.Str("status") + ":" + n.Str("version") }, { "same", s.Str("status") }, { "older", o.Str("status") }, { "missing", missing.Str("status") }, { "url", Updater.DefaultURL } };
      });
      await Step("updateSkip", async () => {
        await Task.Yield();
        var skipped = UpdateInfo.Decide(await Updater.Check(newer, Program.Version), true, "9.9.9").Str("status");
        var other = UpdateInfo.Decide(await Updater.Check(newer, Program.Version), true, "9.9.8").Str("status");
        var manual = UpdateInfo.Decide(await Updater.Check(newer, Program.Version), false, "9.9.9").Str("status");
        double now = 1.8e12, h = 3600 * 1000.0;
        var gates = string.Join(",", UpdateInfo.AutoGate(false, 0, now), UpdateInfo.AutoGate(true, now - h, now), UpdateInfo.AutoGate(true, now - 25 * h, now));
        Expect(skipped == "skipped" && other == "update" && manual == "update", "とばした版 " + skipped + "/" + other + "/" + manual);
        Expect(gates == "off,notyet,go", "自動で確かめる間隔 " + gates);
        // 本体の呼び出し口: 自己点検の間は自動の確認をしない
        var auto = await Js("window.api.updateCheck({ auto: true }).then(r => r.status)");
        Expect(auto as string == "off", "点検中の自動の確認 " + auto);
        return new JObj { { "skipped", skipped }, { "otherSkip", other }, { "manual", manual }, { "gates", gates }, { "autoDuringSelftest", auto } };
      });
      await Step("updateDownload", async () => {
        var asset = (await Updater.Check(newer, Program.Version)).Obj("asset");
        long reported = 0;
        var file = await Updater.Download(asset, (got, total) => reported = got, System.Threading.CancellationToken.None);
        var same2 = File.ReadAllBytes(file).SequenceEqual(payload);
        string bad = "";
        try { await Updater.Download((await Updater.Check(badSize, Program.Version)).Obj("asset"), null, System.Threading.CancellationToken.None); } catch (Exception e) { bad = e.Message; }
        // 画面からの呼び出し (進み具合が届く)
        var viaUI = await Js("(async () => { let n = 0; const off = window.api.on('update:progress', () => { n++; }); const r = await window.api.updateDownload(" + Json.Stringify(asset) + "); off(); return { status: r.status, name: (r.path || '').split('\\\\').pop(), progress: n }; })()") as JObj;
        Expect(File.Exists(file) && same2 && reported == payload.Length, "ダウンロードした中身と大きさ");
        Expect(Path.GetDirectoryName(file).StartsWith(Path.GetTempPath().TrimEnd('\\'), StringComparison.OrdinalIgnoreCase), "一時フォルダに置く " + file);
        Expect(bad.Contains("大きさ"), "大きさが違えばエラー: " + bad);
        Expect(viaUI?.Str("status") == "ok" && viaUI.Num("progress") > 0, "画面からのダウンロード " + Json.Stringify(viaUI));
        Expect(!File.Exists(file + ".part"), "途中のファイルを残さない");
        var args = Updater.InstallerArgs(Updater.InstallDir, 1234) + " | " + Updater.InstallerArgs(Path.GetTempPath(), 1234);
        Expect(args == "/update /wait-pid=1234 | ", "インストーラーに渡す引数 " + args);
        try { File.Delete(file); } catch { }
        return new JObj { { "file", Path.GetFileName(file) }, { "bytes", (double)payload.Length }, { "same", same2 }, { "badSize", bad }, { "ui", viaUI }, { "installerArgs", args } };
      });
      var keepSkip = Store.Prefs["updateSkipVersion"];
      try {
        await Step("updateDialog", async () => {
          Updater.UrlOverride = newer;
          await Js("(() => { window.__upd = __app.checkForUpdates({ manual: true }); return true; })()");
          await Wait(1200);
          var shown = await Js("({ title: (Array.from(document.querySelectorAll('.update-dialog .modal-title')).pop() || {}).textContent || '', text: (document.querySelector('.update-dialog .modal-body') || {}).innerText || '',"
            + " buttons: Array.from(document.querySelectorAll('.update-dialog .modal-buttons button')).map(b => b.textContent), notes: !!document.querySelector('.update-dialog a.update-notes') })") as JObj;
          await Shot("11-update");
          // 「この版はとばす」→ 覚える
          await Js("(() => { const b = Array.from(document.querySelectorAll('.update-dialog .modal-buttons button')).pop(); b.click(); return true; })()");
          var answer = await Js("window.__upd.then(r => r && r.answer)");
          await Wait(400);
          var remembered = Store.Prefs.Str("updateSkipVersion");
          // もう一度: 「あとで」
          await Js("(() => { window.__upd = __app.checkForUpdates({ manual: true }); return true; })()");
          await Wait(1200);
          await Js("(() => { const b = document.querySelectorAll('.update-dialog .modal-buttons button')[1]; b.click(); return true; })()");
          var later = await Js("window.__upd.then(r => r && r.answer)");
          // 最新のとき
          Updater.UrlOverride = same;
          await Js("(() => { window.__upd = __app.checkForUpdates({ manual: true }); return true; })()");
          await Wait(1200);
          var latest = await Js("(Array.from(document.querySelectorAll('.modal-body')).pop() || {}).innerText || ''") as string;
          await Shot("12-update-latest");
          await Js("(() => { const b = Array.from(document.querySelectorAll('.modal-buttons button')).pop(); if (b) b.click(); return true; })()");
          await Js("window.__upd.then(r => r && r.status)");
          var title = shown?.Str("title") ?? "";
          Expect(title == "新しい版があります" || title == "A New Version Is Available", "知らせる画面の題 " + title);
          Expect((shown?.Str("text") ?? "").Contains("9.9.9") && (shown?.Str("text") ?? "").Contains(Program.Version), "新しい版と今の版を書く");
          Expect((shown?.Arr("buttons")?.Count ?? 0) == 3 && shown.Bool("notes"), "ボタン 3 つとリリースノート");
          Expect(answer as string == "skip" && remembered == "9.9.9", "とばした版を覚える " + answer + " " + remembered);
          Expect(later as string == "later", "あとで " + later);
          Expect(latest.Contains("最新の版です") || latest.Contains("latest version"), "最新の版です: " + latest);
          return new JObj { { "dialog", shown }, { "answer", answer }, { "remembered", remembered }, { "later", later }, { "latest", latest } };
        });
      } finally {
        Updater.UrlOverride = null;
        Store.Prefs["updateSkipVersion"] = keepSkip;
        Store.SavePrefsNow();
        await Js("(() => { __app.prefs.updateSkipVersion = " + Json.Stringify(keepSkip) + "; for (let i = 0; i < 3; i++) { const b = Array.from(document.querySelectorAll('.modal-buttons button')).pop(); if (b) b.click(); } return true; })()");
      }
      await Step("updateSettings", async () => {
        var menuHas = MenuTexts().Any(x => x == "アップデートを確認…" || x == "Check for Updates…");
        await Js("(() => { __app.run('settings.open:general'); return true; })()");
        await Wait(800);
        var r = await Js("(() => { const box = Array.from(document.querySelectorAll('.check-row')).find(l => /アップデートを自動で確認|Check for updates automatically/.test(l.textContent));"
          + " return { found: !!box, checked: !!(box && box.querySelector('input').checked), pref: __app.prefs.autoUpdateCheck }; })()") as JObj;
        await Shot("13-update-settings");
        await Js("(() => { for (let i = 0; i < 3; i++) { const b = Array.from(document.querySelectorAll('.modal-buttons button')).pop(); if (b) b.click(); } return true; })()");
        await Wait(300);
        Expect(menuHas, "メニュー「アップデートを確認…」");
        Expect(r != null && r.Bool("found") && r.Bool("checked") == r.Bool("pref"), "設定「アップデートを自動で確認」 " + Json.Stringify(r));
        Expect(Store.PrefDefaults.Bool("autoUpdateCheck"), "既定はオン");
        return new JObj { { "menu", menuHas }, { "settings", r } };
      });
    }

    /// メニューの項目の字をすべて (子メニューも)
    List<string> MenuTexts() {
      var texts = new List<string>();
      void Walk(ToolStripItemCollection items) {
        foreach (var it in items.OfType<ToolStripMenuItem>()) { texts.Add(it.Text.Replace("&", "")); Walk(it.DropDownItems); }
      }
      Walk(form.MainMenuStrip.Items);
      return texts;
    }

    /// Mac 版にそろえたところ: テキスト一覧の並べ方と行・フォルダの開け閉め・サーバツリーとの入れ替え・AI の欄とつまみ・
    /// 入力欄の伸び方・用紙切替の候補・各機能の設定のメニュー・すべて初期状態に戻す
    async Task RunMacParitySteps() {
      await Js("(() => { for (let i = 0; i < 4; i++) { const b = Array.from(document.querySelectorAll('.modal-buttons button')).pop(); if (b) b.click(); } document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); })()");
      await Wait(300);
      await Step("libraryLayout", async () => await Js(@"(async () => { const lib = __app.library, el = document.getElementById('library-pane'), bad = [], out = {};
        const wait = ms => new Promise(r => setTimeout(r, ms));
        __app.setPref('libraryVisible', true); await wait(500);
        if (__app.prefs.libraryOneColumn === undefined) bad.push('libraryOneColumn の既定がない');
        __app.setPref('libraryOneColumn', true); lib.arrange();
        out.stacked = el.classList.contains('stacked');
        const order = () => Array.from(el.querySelectorAll('.lib-list-pane, .lib-folder-pane')).map(e => e.className.includes('list') ? 'list' : 'folders').join(',');
        out.stackedOrder = order();
        await wait(100);
        const lr = el.querySelector('.lib-list-pane').getBoundingClientRect(), fr = el.querySelector('.lib-folder-pane').getBoundingClientRect();
        const col = el.querySelector('.lib-column').getBoundingClientRect(), dv = el.querySelector('.lib-stack-divider');
        out.folderShare = Math.round(fr.height / col.height * 100);
        if (!out.stacked || out.stackedOrder !== 'folders,list' || !(lr.top >= fr.bottom - 1)) bad.push('上下: フォルダが上・一覧が下になっていない ' + out.stackedOrder);
        // フォルダの欄の高さは中身 (見出し + 見えている行) に合わせる。80px 以上・半分まで。一覧は残りぜんぶ
        const fp = el.querySelector('.lib-folder-pane'), natural = fp.querySelector('.lib-head').offsetHeight + fp.querySelector('.lib-folders').scrollHeight;
        out.folderHeight = Math.round(fr.height); out.folderNatural = natural;
        if (fr.height < 79 || fr.height > col.height * 0.5 + 1) bad.push('フォルダの欄の高さが 80px〜半分に入っていない: ' + Math.round(fr.height) + ' / ' + Math.round(col.height));
        if (fr.height < Math.min(natural, col.height * 0.5) - 1) bad.push('フォルダの欄が中身より低い: ' + Math.round(fr.height) + ' < ' + natural);
        if (Math.abs(lr.bottom - col.bottom) > 2) bad.push('一覧が残りの高さを使っていない');
        const dr = dv && dv.isConnected ? dv.getBoundingClientRect() : null;
        out.divider = dr ? Math.round(dr.height) : 0;
        if (!dr || dr.height < 18 || dr.height > 22 || dr.top < fr.bottom - 1 || dr.bottom > lr.top + 1) bad.push('フォルダの欄と一覧の間に仕切りがない');
        // 開け閉めで高さが変わる
        const h0 = fr.height; const sub = (lib.tree || []).find(n => n.children && n.children.length);
        if (sub) { lib.toggleExpand('sub:' + sub.rel); await wait(100); out.folderHeightToggled = Math.round(fp.getBoundingClientRect().height); lib.toggleExpand('sub:' + sub.rel); await wait(100); }
        el.querySelector('.lib-layout').click(); await wait(100);
        out.sideOrder = order(); out.side = !el.classList.contains('stacked') && __app.prefs.libraryOneColumn === false;
        const lr2 = el.querySelector('.lib-list-pane').getBoundingClientRect(), fr2 = el.querySelector('.lib-folder-pane').getBoundingClientRect();
        if (!out.side || out.sideOrder !== 'folders,list' || !(fr2.right <= lr2.left + 6)) bad.push('左右: フォルダが左にない');
        el.querySelector('.lib-layout').click(); await wait(100);
        if (!el.classList.contains('stacked')) bad.push('上下に戻らない');
        // 行: 1 行目 = ファイルの名前 (拡張子なし) と右はしの拡張子、2 行目 = フォルダと時間。本文は出さない
        lib.select('all'); await lib.reload();
        const row = Array.from(document.querySelectorAll('.lib-row')).find(r => r.title.split('\n')[0].endsWith('メモ一.txt'));
        if (!row) bad.push('メモ一.txt の行がない');
        else {
          out.name = row.querySelector('.lib-rname').textContent; out.ext = (row.querySelector('.lib-ext') || {}).textContent;
          out.folder = (row.querySelector('.lib-ftag') || {}).textContent; out.time = row.querySelector('.lib-time').textContent;
          const rr = row.getBoundingClientRect(), er = row.querySelector('.lib-ext').getBoundingClientRect();
          out.extAtRight = rr.right - er.right < 14;
          if (out.name !== 'メモ一' || out.ext !== 'txt' || !out.extAtRight) bad.push('1 行目: ' + out.name + ' / ' + out.ext);
          if (!out.folder || !out.time) bad.push('2 行目: フォルダ・時間がない');
        }
        out.snippets = document.querySelectorAll('.lib-snip').length;
        if (out.snippets) bad.push('本文のはじめが出ている');
        // フォルダ: 閉じているものを押すと選んで開き、選んでいて開いているものを押すと閉じる
        await window.api.libraryCreateFolder('宿', '旅行'); __app.setPref('libraryFolderExpanded', []); await lib.reload(); lib.select('all');
        const click = () => document.querySelector('.lib-frow[data-key=""sub:旅行""]').click();
        const isOpen = () => (__app.prefs.libraryFolderExpanded || []).includes('sub:旅行');
        click(); out.click1 = [lib.selected, isOpen()].join(':');
        click(); out.click2 = [lib.selected, isOpen()].join(':');
        click(); out.click3 = [lib.selected, isOpen()].join(':');
        if (out.click1 !== 'sub:旅行:true' || out.click2 !== 'sub:旅行:false' || out.click3 !== 'sub:旅行:true') bad.push('フォルダの開け閉め: ' + [out.click1, out.click2, out.click3].join(' '));
        lib.select('all');
        // サーバツリーを出しているあいだは、テキスト一覧を隠す
        const srv = __app.prefs.serverEnabled, tree = __app.prefs.remoteTreeVisible, rt = __app.remoteTree, rtServer = rt.server;
        rt.server = rtServer || { id: '__selftest' }; // 点検ではサーバにつながない
        __app.setPref('serverEnabled', true); __app.setPref('remoteTreeVisible', true); await wait(700);
        out.withTree = [document.getElementById('remote-pane').hidden, el.hidden].join(':');
        __app.setPref('remoteTreeVisible', tree); __app.setPref('serverEnabled', srv); await wait(700);
        out.afterTree = el.hidden; rt.server = rtServer;
        if (out.withTree !== 'false:true' || out.afterTree) bad.push('サーバツリーとの入れ替え: ' + out.withTree + ' / ' + out.afterTree);
        if (bad.length) throw new Error(bad.join(' ; '));
        return out; })()"));
      await Shot("14-library-stacked");
      await Step("aiDrawer", async () => await Js(@"(async () => { const bad = [], out = {}, pane = document.getElementById('ai-pane');
        const wait = ms => new Promise(r => setTimeout(r, ms));
        const aiOn = __app.prefs.aiEnabled; __app.setPref('aiEnabled', true); __app.setPref('aiVisible', false); await wait(500);
        const tab = document.getElementById('ai-tab');
        out.tab = !!tab && !tab.hidden;
        if (!out.tab) bad.push('閉じているのに右はしのつまみがない');
        else {
          const cs = getComputedStyle(tab), r = tab.getBoundingClientRect(), main = document.getElementById('main').getBoundingClientRect();
          out.cursor = cs.cursor; out.bg = cs.backgroundColor; out.right = Math.round(main.right - r.right);
          if (cs.cursor !== 'pointer') bad.push('つまみのカーソルが指でない');
          if (!(r.right > main.right)) bad.push('つまみの右の角が外に出ていない');
          if (cs.backgroundColor === 'rgba(0, 0, 0, 0)' || cs.backgroundColor === 'transparent') bad.push('つまみの背景がない');
        }
        const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches || document.hidden;
        const w0 = document.getElementById('center').getBoundingClientRect().width;
        __app.setPref('aiVisible', true); await wait(90);
        out.sliding = pane.dataset.sliding || (reduce ? 'reduced' : '');
        const wMid = document.getElementById('center').getBoundingClientRect().width;
        await wait(600);
        const w1 = document.getElementById('center').getBoundingClientRect().width;
        out.widths = [Math.round(w0), Math.round(wMid), Math.round(w1)].join(',');
        if (!reduce && (out.sliding !== 'in' || !(wMid < w0 && wMid > w1))) bad.push('右から滑って出ない: ' + out.sliding + ' ' + out.widths);
        if (pane.hidden || !tab.hidden) bad.push('開いたあと: 欄が出ていない / つまみが残っている');
        // 入力欄: 書いた文字に合わせて高くなる (欄の 4 割まで)
        const input = pane.querySelector('.ai-input'); const h0 = input.getBoundingClientRect().height;
        input.value = 'あいうえお'.repeat(30); input.dispatchEvent(new Event('input')); await wait(50);
        const h1 = input.getBoundingClientRect().height;
        input.value = 'かきくけこ\n'.repeat(80); input.dispatchEvent(new Event('input')); await wait(50);
        const h2 = input.getBoundingClientRect().height, limit = Math.max(140, Math.min(360, pane.clientHeight * 0.4));
        out.input = [Math.round(h0), Math.round(h1), Math.round(h2), Math.round(limit), getComputedStyle(input).overflowY].join(',');
        if (!(h1 > h0 + 10) || h2 > limit + 2 || getComputedStyle(input).overflowY !== 'auto') bad.push('入力欄の伸び方: ' + out.input);
        input.value = ''; input.dispatchEvent(new Event('input'));
        // 取り出して ✕ を押すと、閉じずに横に戻る
        __app.ai.toggleDetached(); await wait(100);
        pane.querySelector('.ai-head button[aria-label=""' + __app.t('閉じる') + '""]').click(); await wait(100);
        out.redock = [__app.ai.detached, __app.prefs.aiVisible, pane.hidden].join(':');
        if (out.redock !== 'false:true:false') bad.push('取り出した欄の ✕: ' + out.redock);
        __app.setPref('aiVisible', false); await wait(600);
        if (!pane.hidden) bad.push('しまえない');
        window.__aiOn = aiOn;
        if (bad.length) throw new Error(bad.join(' ; '));
        return out; })()"));
      await Shot("15-ai-tab");
      await Js("__app.setPref('aiEnabled', window.__aiOn !== false)");
      await Step("paperCandidates", async () => {
        var r = await Js(@"(async () => { const bad = [], out = {}; const wait = ms => new Promise(r => setTimeout(r, ms));
          const tab = __app.newTab(); tab.editor.setText('用紙の点検', false); __app.setPaperMode(tab, 0, { remember: false });
          const saved = __app.prefs.paperCandidates;
          __app.setPref('paperCandidates', ['normal', 'a4']);
          __app.run('paper.cycle'); await wait(300); out.c1 = tab.paperMode;
          __app.run('paper.cycle'); await wait(300); out.c2 = tab.paperMode;
          if (out.c1 !== 2 || out.c2 !== 0) bad.push('チェックしたものだけを順に: ' + out.c1 + ',' + out.c2);
          __app.statusClicked('paper', document.querySelector('.status-cell[data-id=""paper""]')); await wait(200);
          out.popup = Array.from(document.querySelectorAll('.popup-menu .popup-label')).map(e => e.textContent);
          document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
          if (out.popup.length !== 2) bad.push('下の欄の候補: ' + out.popup.join('/'));
          __app.setPref('paperCandidates', []); __app.run('paper.cycle'); await wait(300); out.none = tab.paperMode;
          if (out.none !== 0) bad.push('1 つも無いときは標準エディタ');
          await wait(400);
          out.menu = true;
          __app.setPref('paperCandidates', saved === undefined ? null : saved);
          window.__paperTab = tab;
          if (bad.length) throw new Error(bad.join(' ; '));
          return out; })()");
        await Wait(500);
        return r;
      });
      await Step("settingsLinks", async () => {
        await Js("__app.setPref('paperCandidates', ['normal', 'a4'])");
        await Wait(800);
        var texts = MenuTexts();
        await Js("__app.setPref('paperCandidates', null)");
        return await Js(@"(() => { const menu = " + Json.Stringify(texts) + @", bad = [];
          const has = s => menu.includes(__app.t(s));
          for (const s of ['用紙モードの設定…', 'テキスト管理の設定…', 'リンクで公開共有…', 'リンクで公開共有の設定…', 'すべて初期状態に戻す…']) if (!has(s)) bad.push('メニューに無い: ' + s);
          if (has('リンクで公開…')) bad.push('古い「リンクで公開…」が残っている');
          if (has('原稿用紙 (縦書き 400 字詰め)')) bad.push('用紙メニューに、チェックしていない候補が出ている');
          if (!has('A4 用紙 (横書き 40 字 × 36 行)')) bad.push('用紙メニューに A4 がない');
          if (!__app.prefs.serverEnabled && has('サーバの設定…')) bad.push('サーバを切っているのにサーバの設定が出ている');
          if (bad.length) throw new Error(bad.join(' ; '));
          return { checked: menu.length }; })()");
      });
      await Step("versionMaxDefault", async () => { await Task.Yield(); var v = Store.PrefDefaults["versionHistoryMax"]; if (!(v is double d && d == 20)) throw new Exception("版の履歴の既定の数が 20 でない: " + v); return v; });
      await Step("resetAll", async () => {
        // 色・フォントとファイルタイプ別の設定は消えるので、点検のあとに戻す
        var theme = Store.ReadText(Store.ThemeFile); var profiles = Store.ReadText(Store.ProfilesFile);
        var keep = new JObj();
        foreach (var k in Store.PrefDefaults.Keys) if (!Store.KeepOnReset.Contains(k)) keep[k] = Json.Parse(Json.Stringify(Store.Prefs[k]));
        try {
          return await Js(@"(async () => { const bad = [], out = {}; const wait = ms => new Promise(r => setTimeout(r, ms));
            const files = JSON.stringify(__app.prefs.libraryFiles), links = JSON.stringify(__app.prefs.sharedLinks), servers = JSON.stringify(__app.prefs.servers);
            for (const [k, v] of [['libraryOneColumn', false], ['aiWidth', 520], ['shareDays', 7], ['versionHistoryMax', 200], ['encryptAlways', true], ['remoteAutoUpload', false],
              ['shareEnabled', false], ['aiApply', 'auto'], ['libraryVisible', false], ['librarySelectedGroup', 'root'], ['diffVisible', true], ['paperCandidates', ['a4']]]) __app.setPref(k, v);
            await wait(300);
            const p = __app.resetAllSettings(); await wait(400);
            out.asked = (document.querySelector('.modal-title') || {}).textContent || '';
            document.querySelector('.modal-buttons button.primary').click();
            out.done = await p; await wait(700);
            const pr = __app.prefs;
            out.values = [pr.libraryOneColumn, pr.aiWidth, pr.shareDays, pr.versionHistoryMax, pr.encryptAlways, pr.remoteAutoUpload, pr.shareEnabled, pr.aiApply, pr.libraryVisible, pr.librarySelectedGroup, pr.diffVisible, pr.paperCandidates].join(',');
            if (out.values !== 'true,340,30,20,false,true,true,confirm,true,all,false,') bad.push('戻っていない: ' + out.values);
            if (JSON.stringify(pr.libraryFiles) !== files || JSON.stringify(pr.sharedLinks) !== links || JSON.stringify(pr.servers) !== servers) bad.push('自分のデータが消えた');
            out.panes = [document.getElementById('library-pane').hidden, document.getElementById('library-pane').classList.contains('stacked'), document.getElementById('diff-pane').hidden, document.getElementById('ai-pane').style.width].join(',');
            if (out.panes !== 'false,true,true,340px') bad.push('欄が戻っていない: ' + out.panes);
            if (bad.length) throw new Error(bad.join(' ; '));
            return out; })()");
        } finally {
          foreach (var kv in keep) Store.Prefs[kv.Key] = kv.Value;
          Store.SavePrefsNow();
          if (theme != null) Store.WriteAtomic(Store.ThemeFile, theme);
          if (profiles != null) Store.WriteAtomic(Store.ProfilesFile, profiles);
          await Js("(() => { Object.assign(__app.prefs, " + Json.Stringify(Store.Prefs) + "); __app.library.arrange(); __app.applyPrefs(); })()");
        }
      });
    }

    /// テキスト一覧・表示の記録・版の履歴・バックアップ・リンクで公開・横書きの原稿用紙 (Mac 版と同じ動き)
    async Task RunLibrarySteps(string work) {
      var lib = Library.Root;
      // 前の点検で開いたままの画面 (設定など) を閉じる
      await Js("(() => { for (let i = 0; i < 4; i++) { const b = Array.from(document.querySelectorAll('.modal-buttons button')).pop(); if (b) b.click(); } })()");
      await Wait(300);
      await Step("defaults", async () => await Js(@"({ menus: Array.from(new Set(" + Q(string.Join("|", form.MainMenuStrip.Items.Cast<ToolStripItem>().Select(m => m.Text))) + @".split('|'))),
        collab: __app.prefs.collabEnabled, folderTree: __app.prefs.folderTreeEnabled, encryption: __app.prefs.encryptionEnabled, paper: __app.prefs.paperEnabled, share: __app.prefs.shareEnabled,
        furigana: __app.prefs.genkoFurigana, libraryVisible: !document.getElementById('library-pane').hidden,
        features: (await import('data:text/javascript,')) && null })".Replace("features: (await import('data:text/javascript,')) && null", "startTab: __app.tabs[0] ? __app.tabs[0].paperMode : -1")));
      await Step("libraryFolders", async () => await Js(@"(async () => { const api = window.api; const out = {};
        const a = await api.libraryCreateFolder('旅行', ''); const b = await api.libraryCreateFolder('京都', '旅行'); const bad = await api.libraryCreateFolder('a:b', '');
        out.created = [a.status, b.status, b.rel, bad.status];
        const r = await api.libraryRenameFolder('旅行/京都', '奈良'); out.renamed = r.rel;
        const m = await api.libraryMoveFolder('旅行/奈良', ''); out.moved = m.rel;
        const self = await api.libraryMoveFolder('旅行', '旅行'); out.selfMove = self.status;
        await __app.library.reload(); out.tree = JSON.stringify(__app.library.tree.map(n => n.rel));
        return out; })()"));
      await Step("libraryTexts", async () => await Js(@"(async () => { const api = window.api, lib = __app.library; const out = {};
        __app.prefs.lastPaperMode = 'genko'; __app.prefs.genkoHorizontal = false;
        lib.select('sub:旅行');
        await lib.createBlank();
        const tab = __app.active; out.placeholder = lib.isPlaceholder(tab.path); out.inTravel = lib.group(tab.path); out.mode = __app.modeString(tab);
        tab.paper.insertAtCursorEnd('京都の思い出\n楽しかった。');
        await new Promise(r => setTimeout(r, 2600));
        const back = await api.libraryReadText(tab.path); out.autosaved = back.text; out.dirty = tab.isDirty(); out.fileMode = back.mode;
        out.stillPlaceholder = lib.isPlaceholder(tab.path);
        await lib.reload(); const it = lib.itemFor(tab.path); out.item = it && [it.title, it.mode, it.group].join('|');
        // 表示を変えると、ファイルの見えない所に書く (中身は変えない)
        __app.setPaperMode(tab, 2); await new Promise(r => setTimeout(r, 300)); out.a4 = await api.libraryGetMode(tab.path);
        __app.setPaperMode(tab, 3); await new Promise(r => setTimeout(r, 300)); out.genkoH = await api.libraryGetMode(tab.path);
        out.sheetsH = document.querySelectorAll('.genko-sheet.h').length;
        return out; })()"));
      await Shot("10-library");
      await Step("libraryOps", async () => await Js(@"(async () => { const api = window.api, lib = __app.library; const out = {};
        const file = " + Q(Path.Combine(lib, "メモ一.txt")) + @";
        await api.writeFile({ path: file, text: '一行目\n本文', encoding: 'utf8', lineEnding: 'crlf', mode: 'genko', versionNow: true });
        out.mode = await api.libraryGetMode(file);
        const d = await api.libraryDuplicate(file, '{name} のコピー', '{name} のコピー {n}'); out.dup = d.path.split('\\').pop(); out.dupMode = await api.libraryGetMode(d.path);
        await api.librarySetLocked(file, true); const w = await api.writeFile({ path: file, text: 'x', encoding: 'utf8', lineEnding: 'crlf' }); out.lockedWrite = w.status + ':' + w.code;
        await api.librarySetLocked(file, false);
        lib.setPinned(true, file);
        const mv = await api.libraryMove(d.path, await api.libraryFolderPath('旅行')); out.moved = lib.group(mv.path);
        await lib.reload(); out.order = lib.items.slice(0, 2).map(x => x.name).join(',');
        out.pinnedFirst = lib.items[0] && lib.items[0].path === file;
        // 開いて、右クリックのメニュー
        await __app.openPath(file, { browse: true }); out.openedMode = __app.modeString(__app.active);
        lib.select('all'); lib.renderList();
        const row = Array.from(document.querySelectorAll('.lib-row')).find(r => r.title.startsWith(file));
        row.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, clientX: 300, clientY: 200 }));
        await new Promise(r => setTimeout(r, 600));
        out.menu = Array.from(document.querySelectorAll('.popup-menu .popup-label')).map(e => e.textContent).slice(0, 6);
        return out; })()"));
      await Shot("11-library-menu");
      await Js("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))");
      await Step("versions", async () => await Js(@"(async () => { const api = window.api; const out = {};
        const file = " + Q(Path.Combine(lib, "履歴.txt")) + @";
        await api.writeFile({ path: file, text: '第一版', encoding: 'utf8', lineEnding: 'crlf', versionNow: true });
        await new Promise(r => setTimeout(r, 400));
        await api.writeFile({ path: file, text: '第二版です', encoding: 'utf8', lineEnding: 'crlf', versionNow: true });
        await new Promise(r => setTimeout(r, 400));
        // 自動保存 (20 秒の決まり。点検では 2 秒) はまとめる
        await api.writeFile({ path: file, text: '自動 1', encoding: 'utf8', lineEnding: 'crlf' });
        await api.writeFile({ path: file, text: '自動 2', encoding: 'utf8', lineEnding: 'crlf' });
        await new Promise(r => setTimeout(r, 3000));
        let list = await api.versionList(file); out.count = list.length;
        out.latest = (await api.versionContent(file, list[0].key)).text; out.oldest = (await api.versionContent(file, list[list.length - 1].key)).text;
        // コピーは履歴を分ける
        const d = await api.libraryDuplicate(file, '{name} のコピー', '{name} のコピー {n}');
        await api.writeFile({ path: d.path, text: 'コピーだけ', encoding: 'utf8', lineEnding: 'crlf', versionNow: true });
        await new Promise(r => setTimeout(r, 500));
        out.copyCount = (await api.versionList(d.path)).length; out.origCount = (await api.versionList(file)).length;
        // 名前を変えても (エクスプローラーと同じ動き) ついていく
        const moved = await api.libraryMove(file, await api.libraryFolderPath('旅行')); out.afterMove = (await api.versionList(moved.path)).length;
        await api.libraryTrash([d.path]); out.trashedHistory = (await api.versionList(d.path)).length;
        await __app.versions.show(moved.path);
        return out; })()".Replace("await __app.versions.show(moved.path);", "__app.versions.show(moved.path); await new Promise(r => setTimeout(r, 800)); document.querySelectorAll('.ver-row')[2].click(); await new Promise(r => setTimeout(r, 300)); document.querySelectorAll('.ver-seg button')[2].click(); await new Promise(r => setTimeout(r, 500)); out.word = document.querySelectorAll('.ver-removed, .ver-added').length;")));
      await Shot("12-history");
      await Js("(() => { const b = Array.from(document.querySelectorAll('.modal-buttons button')).pop(); if (b) b.click(); })()");
      await Step("backup", async () => {
        var bak = Path.Combine(dir, "test.satorubackup");
        return await Js(@"(async () => { const api = window.api; const out = {};
          const r = await api.backupExport({ path: " + Q(bak) + @", password: 'backup-pass-1', withHistory: true, pinned: __app.prefs.libraryPinned, folderIcons: { '旅行': 'star|red' }, folderOrder: ['旅行'], sharedLinks: '[]', other: [] });
          out.export = r.status + ':' + r.count;
          out.wrong = (await api.backupOpen({ path: " + Q(bak) + @", password: 'nope-nope' })).status;
          const o = await api.backupOpen({ path: " + Q(bak) + @", password: 'backup-pass-1' }); out.open = o.status + ':' + o.entries + ':' + o.folders;
          const x = await api.backupRestore(o.token, 'ほかの場所から戻したもの', '(バックアップ)', '(バックアップ {n})'); out.restore = [x.added, x.skipped, x.renamed, x.failed].join(',');
          return out; })()");
      });
      if (FixturesArg != null && File.Exists(Path.Combine(FixturesArg, "mac-backup.satorubackup"))) {
        await Step("macBackup", async () => await Js(@"(async () => { const api = window.api;
          const o = await api.backupOpen({ path: " + Q(Path.Combine(FixturesArg, "mac-backup.satorubackup")) + @", password: 'mac-backup-pass' });
          if (o.status !== 'ok') return o;
          const x = await api.backupRestore(o.token, 'ほかの場所から戻したもの', '(バックアップ)', '(バックアップ {n})');
          await __app.library.reload();
          const it = __app.library.items.find(i => i.name === 'mac-genko.txt');
          return { entries: o.entries, restore: [x.added, x.skipped, x.renamed, x.failed].join(','), mode: it && it.mode, history: it ? (await api.versionList(it.path)).length : -1, pinned: x.pinned.length }; })()"));
      }
      await Step("privacy", async () => {
        await Js(@"(async () => { const tab = __app.newTab(); tab.editor.setText('連絡先 090-1234-5678\nメール taro@example.com\n', false);
          __app.prefs.sharePrivacyCheckOff = false; __app.share.publishCurrent(); })()");
        await Wait(800);
        var title = await Js("(document.querySelector('.modal-title') || {}).textContent || ''");
        await Shot("13-privacy");
        await Js("(() => { const b = Array.from(document.querySelectorAll('.modal-buttons button')).find(x => x.textContent.includes('見直す') || x.textContent.includes('Review')); if (b) b.click(); })()");
        await Wait(500);
        return new JObj { { "asked", title }, { "selected", await Js("__app.active.editor.view.state.selection.ranges.map(r => __app.active.editor.view.state.sliceDoc(r.from, r.to))") } };
      });
      // テキスト一覧の新しい動き: 空のときのしるし・新しいしるし・区切りのバー・任意フォルダ・開いたフォルダ・公開共有中・名前の変更・削除で空のテキストに・公開の期限
      var customDir = Path.Combine(work, "custom-root");
      var extDir = Path.Combine(work, "ext-folder");
      Directory.CreateDirectory(Path.Combine(customDir, "子フォルダ"));
      File.WriteAllText(Path.Combine(customDir, "任意.txt"), "任意フォルダのテキスト", new UTF8Encoding(false));
      File.WriteAllText(Path.Combine(customDir, "子フォルダ", "中.txt"), "中のテキスト", new UTF8Encoding(false));
      Directory.CreateDirectory(Path.Combine(extDir, "下"));
      File.WriteAllText(Path.Combine(extDir, "下", "外.txt"), "開いたフォルダのテキスト", new UTF8Encoding(false));
      await Js("(() => { __app.prefs.libraryVisible = true; __app.applyLibrary(); __app.library.arrange(); })()");
      await Wait(500);
      await Step("libraryEmptyAndNew", async () => await Js(@"(async () => { const lib = __app.library, api = window.api; const out = {};
        const fail = m => { throw new Error('libraryEmptyAndNew: ' + m + ' ' + JSON.stringify(out)); };
        const wait = ms => new Promise(r => setTimeout(r, ms));
        await api.libraryCreateFolder('空のフォルダ', ''); await lib.reload(); lib.select('sub:空のフォルダ'); await wait(200);
        const es = document.querySelector('.lib-list .lib-empty-state');
        out.empty = es ? es.innerText.replace(/\s+/g, ' ') : null;
        if (!es || !out.empty.includes('NO DATA')) fail('empty state');
        const link = es.querySelector('.lib-hint-link'); out.hint = link && link.textContent;
        link.dispatchEvent(new MouseEvent('mouseenter')); out.hop = lib.newTextButton.classList.contains('lib-hop');
        link.dispatchEvent(new MouseEvent('mouseleave')); out.hopStop = !lib.newTextButton.classList.contains('lib-hop');
        if (!out.hop || !out.hopStop) fail('hop');
        out.divider = lib.dividerLabel.textContent; if (!out.divider.includes('空のフォルダ')) fail('divider');
        out.zeroShown = Array.from(document.querySelectorAll('.lib-count')).some(c => c.textContent === '0'); if (out.zeroShown) fail('zero count');
        out.folderDot = !!document.querySelector('.lib-frow[data-key=""sub:空のフォルダ""] .lib-new-dot'); if (!out.folderDot) fail('folder dot');
        lib.query = 'zzzqqqxxx'; lib.renderList(); out.noMatch = (document.querySelector('.lib-empty-state') || {}).innerText; lib.query = ''; lib.renderList();
        if (!String(out.noMatch).includes('NO MATCH')) fail('no match');
        return out; })()"));
      await Shot("14-library-empty");
      await Step("libraryNewMark", async () => await Js(@"(async () => { const lib = __app.library; const out = {};
        const fail = m => { throw new Error('libraryNewMark: ' + m + ' ' + JSON.stringify(out)); };
        const wait = ms => new Promise(r => setTimeout(r, ms));
        await lib.createBlank(); await wait(400);
        out.dot = !!document.querySelector('.lib-row .lib-new-dot'); if (!out.dot) fail('file dot');
        out.blankPath = __app.active.path;
        out.trashButton = !!document.querySelector('.lib-list-pane .lib-head .lib-trash');
        out.folderHead = !!document.querySelector('.lib-folder-pane .lib-head .lib-newfolder') && !document.querySelector('.lib-add');
        out.storage = lib.storageButton.textContent;
        return out; })()"));
      await Shot("14-library-new");
      await Step("libraryDeleteOpen", async () => {
        // 開いているテキストのフォルダを削除: タブは閉じずに空の新しいテキストになる
        var before = await Js("__app.tabs.length");
        await Js("(() => { __app.library.trashFolders(['空のフォルダ']); })()");
        await Wait(500);
        var title = await Js("(document.querySelector('.modal-title') || {}).textContent || ''");
        await Js("(() => { const b = document.querySelector('.modal-buttons button.primary'); if (b) b.click(); })()");
        await Wait(1500);
        var after = await Js("({ tabs: __app.tabs.length, path: __app.active.path, text: __app.active.getText(), folder: !!__app.library.findRel('空のフォルダ') })") as JObj;
        if (after == null || after["path"] != null || after.Bool("folder") || Convert.ToInt32(after["tabs"]) != Convert.ToInt32(before)) errors.Add("libraryDeleteOpen: " + Json.Stringify(after));
        return new JObj { { "asked", title }, { "after", after } };
      });
      await Step("libraryCustomRoot", async () => await Js(@"(async () => { const lib = __app.library; const out = {};
        const fail = m => { throw new Error('libraryCustomRoot: ' + m + ' ' + JSON.stringify(out)); };
        const local = lib.root;
        await lib.useCustom(" + Q(customDir) + @");
        out.root = lib.root; out.name = lib.rootName; out.storage = lib.storageButton.textContent;
        out.tree = lib.tree.map(n => n.rel).join(',');
        out.items = lib.items.map(i => (i.group === null ? '?' : i.group) + '/' + i.name).filter(x => !x.startsWith('?')).sort().join(',');
        out.recent = (__app.prefs.libraryCustomRecent || []).length;
        out.rootRow = (document.querySelector('.lib-frow[data-key=""root""] .lib-fname') || {}).textContent;
        if (out.name !== 'custom-root' || out.tree !== '子フォルダ' || out.items !== '/任意.txt,子フォルダ/中.txt' || out.rootRow !== 'custom-root') fail('custom');
        lib.select('sub:子フォルダ'); out.divider = lib.dividerLabel.textContent;
        await lib.useLocal(); out.back = lib.root === local && !lib.customName;
        if (!out.back) fail('back to local');
        // 開いたほかの場所のフォルダ (中のフォルダもたどれる)
        lib.setPref('libraryExternalFolders', [" + Q(extDir) + @"]); await lib.reload();
        lib.select('ext:' + " + Q(extDir) + @"); await new Promise(r => setTimeout(r, 200));
        out.ext = lib.rows.map(r => r.name).join(','); out.extTree = lib.extTree.map(n => n.name + ':' + n.children.map(c => c.name).join('|')).join(',');
        if (out.ext !== '外.txt' || out.extTree !== 'ext-folder:下') fail('external');
        await lib.removeExternalFolder(" + Q(extDir) + @"); out.extGone = lib.extTree.length === 0;
        return out; })()"));
      await Step("libraryRenameShared", async () => await Js(@"(async () => { const lib = __app.library, api = window.api, s = __app.share; const out = {};
        const fail = m => { throw new Error('libraryRenameShared: ' + m + ' ' + JSON.stringify(out)); };
        const file = " + Q(Path.Combine(lib, "改名前.txt")) + @";
        await api.writeFile({ path: file, text: '名前を変える', encoding: 'utf8', lineEnding: 'crlf', mode: 'genko', versionNow: true });
        await new Promise(r => setTimeout(r, 500));
        lib.setPinned(true, file);
        // 公開共有中 (リンクで公開しているものがあるときだけ出る)
        s.records = [{ id: 'selftest-x', url: 'https://docs.satoru.net/r/selftest-x', token: 'x', title: 't', visibility: 'unlisted', created: 0, path: file }].concat(s.records);
        await lib.reload(); out.sharedRow = !!document.querySelector('.lib-frow[data-key=""shared""]');
        await __app.openPath(file, { browse: true });
        const to = await lib.renameTo(file, '改名後');
        out.to = to && to.split('\\').pop(); out.tab = __app.active.path === to; out.pinned = lib.isPinned(to);
        out.mode = await api.libraryGetMode(to); out.versions = (await api.versionList(to)).length; out.record = !!s.recordFor(to);
        lib.select('shared'); out.sharedRows = lib.rows.map(r => r.name).join(',');
        const dup = await api.libraryDuplicate(to, '{name} のコピー', '{name} のコピー {n}');
        const again = await lib.renameTo(dup.path, '改名後.txt'); out.exists = (document.querySelector('.modal-title') || {}).textContent; out.again = again;
        const b = document.querySelector('.modal-buttons button'); if (b) b.click();
        s.records = s.records.filter(r => r.id !== 'selftest-x');
        lib.setPinned(false, to); lib.select('all');
        if (out.to !== '改名後.txt' || !out.tab || !out.pinned || out.mode !== 'genko' || !out.versions || !out.record || !out.sharedRow || out.sharedRows !== '改名後.txt' || again !== null) fail('rename');
        return out; })()".Replace("const again = await lib.renameTo(dup.path, '改名後.txt');", "const pending = lib.renameTo(dup.path, '改名後.txt'); await new Promise(r => setTimeout(r, 400));").Replace("out.again = again;", "").Replace("const b = document.querySelector('.modal-buttons button'); if (b) b.click();", "const b = document.querySelector('.modal-buttons button'); if (b) b.click(); const again = await pending; out.again = again;")));
      await Step("shareExpiry", async () => await Js(@"(() => { const s = __app.share; const out = {};
        const now = new Date(2026, 10, 22, 10, 0, 0).getTime();
        out.today = s.expiryFor(-3, now) === new Date(2026, 10, 22, 23, 59, 59).getTime();
        out.tomorrow = s.expiryFor(-4, now) === new Date(2026, 10, 23, 23, 59, 59).getTime();
        out.period = s.expiryFor(-2, now, { period: 3 * 86400 + 4 * 3600 }) === now + (3 * 86400 + 4 * 3600) * 1000;
        out.date = s.expiryFor(-1, now, { date: now + 5000 }) === now + 5000;
        out.days = s.expiryFor(7, now) === null;
        out.text = s.periodText(3 * 86400 + 4 * 3600);
        out.order = s.dayChoices.map(c => c[0]).join(',');
        if (!out.today || !out.tomorrow || !out.period || !out.date || !out.days || out.order !== '-3,-4,1,3,7,30,365,0,-2,-1') throw new Error('shareExpiry ' + JSON.stringify(out));
        return out; })()"));
      await Step("shareExpiryForm", async () => {
        await Js("(() => { window.__form = __app.share.form({ title: '点検' }); })()");
        await Wait(500);
        var opts = await Js("Array.from(document.querySelectorAll('.share-form select option')).map(o => o.textContent)");
        // 「みんなのメモ」に掲載: 「公開」を選んでいるときだけ出る
        var listed = await Js("(() => { const f = document.querySelector('.share-form'); const row = f.querySelector('.share-listed'); const r = f.querySelectorAll('input[type=radio]');"
          + " r[1].click(); const a = row.hidden; r[0].click(); const b = row.hidden; r[1].click(); return { hiddenUnlisted: a, shownPublic: !b }; })()") as JObj;
        if (listed == null || !listed.Bool("hiddenUnlisted") || !listed.Bool("shownPublic")) errors.Add("shareListed: " + Json.Stringify(listed));
        // 期間を指定… を選ぶと小窓が出る。やめると前の選び方に戻る
        await Js("(() => { const sel = document.querySelector('.share-form select'); sel.value = '-2'; sel.dispatchEvent(new Event('change')); })()");
        await Wait(500);
        var periodTitle = await Js("(Array.from(document.querySelectorAll('.modal-title')).pop() || {}).textContent");
        var fields = await Js("document.querySelectorAll('.period-dialog .period-field').length");
        await Shot("15-share-period");
        await Js("(() => { const b = Array.from(document.querySelectorAll('.period-dialog .modal-buttons button')).pop(); b.click(); })()");
        await Wait(300);
        var back = await Js("document.querySelector('.share-form select').value");
        await Js("(() => { const sel = document.querySelector('.share-form select'); sel.value = '-1'; sel.dispatchEvent(new Event('change')); })()");
        await Wait(500);
        var days = await Js("document.querySelectorAll('.date-dialog .cal-day').length");
        await Js("(() => { const b = Array.from(document.querySelectorAll('.date-dialog .modal-buttons button')).pop(); b.click(); })()");
        await Wait(300);
        await Js("(() => { const b = Array.from(document.querySelectorAll('.modal-buttons button')).pop(); b.click(); })()");
        await Wait(300);
        if (Convert.ToInt32(fields) != 4 || Convert.ToInt32(days) < 28 || !(back is string bs && bs != "-2" && bs != "-1")) errors.Add("shareExpiryForm: " + fields + " " + days + " " + back);
        return new JObj { { "options", opts }, { "listed", listed }, { "period", periodTitle }, { "fields", fields }, { "back", back }, { "calendarDays", days } };
      });
      if (Environment.GetEnvironmentVariable("SATOEDIT_NO_NET") == null) {
        await Step("shareServer", async () => await Js(@"(async () => { const s = __app.share; const out = {};
          const text = 'さとるエディタ Windows 版の点検 (すぐ消します)\n' + new Date().toISOString();
          const r = await s.upload({ text, title: '点検', mode: 'editor', visibility: 'unlisted', password: '', days: 1, keepHistory: true, file: null, tab: null, quiet: true });
          if (!r) return { error: 'upload failed' };
          out.url = /^https:\/\/docs\.satoru\.net\//.test(r.url); out.id = r.id.length;
          out.update = await s.update(r, text + '\n更新', 'editor', null, { quiet: true });
          out.settings = await s.editSettings(s.records.find(x => x.id === r.id), { quiet: true, values: { title: '点検2', visibility: 'unlisted', password: '', days: 1, keepExpiry: false, keepHistory: false, clearHistory: true } });
          out.title = s.records.find(x => x.id === r.id).title;
          out.deleted = await s.unpublish(s.records.find(x => x.id === r.id));
          out.left = s.records.some(x => x.id === r.id);
          return out; })()"));
      }
    }
}
}
