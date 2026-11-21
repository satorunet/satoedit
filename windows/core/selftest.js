'use strict';
// 自己点検 (satoruEditor.exe --selftest=フォルダ): 実機で動くかを確かめ、画面の画像と結果 (report.json) をそのフォルダに書いて終了する
const fs = require('fs');
const path = require('path');
const codec = require('./codec');
const fc = require('./filecrypto');
const grep = require('./grep');
const furigana = require('./furigana');
const i18n = require('../shared/i18n');

/// ctx: 本体 (main.js) から渡してもらうもの
module.exports = async function selfTest(dir, ctx) {
  const { app, Menu, getWindow, isReady, makeKey, keep, writeDocument, readDocument, docxData, secretsAvailable, setLanguage, configDir } = ctx;
  const report = { steps: {}, errors: [] };
  const wait = ms => new Promise(r => setTimeout(r, ms));
  const win = () => getWindow();
  const js = code => win().webContents.executeJavaScript(code, true);
  const shot = async name => {
    // ウインドウが描画されていない (画面が休止している) と撮れないので、待ちすぎない
    const image = await Promise.race([win().webContents.capturePage(), new Promise(r => setTimeout(() => r(null), 6000))]);
    if (image) fs.writeFileSync(path.join(dir, name + '.png'), image.toPNG());
    else report.errors.push('画面を撮れませんでした: ' + name);
  };
  const step = async (name, fn) => {
    try { report.steps[name] = await fn(); } catch (e) { report.errors.push(name + ': ' + ((e && e.stack) || e)); }
  };
  try {
    fs.mkdirSync(dir, { recursive: true });
    for (let i = 0; i < 100 && !isReady(); i++) await wait(100);
    await wait(1500);
    win().webContents.on('console-message', (e, level, message) => { if (level >= 2) report.errors.push('console: ' + message); });
    await step('environment', () => ({
      electron: process.versions.electron, chrome: process.versions.chrome, platform: process.platform, locale: app.getLocale(),
      language: i18n.language(), secrets: secretsAvailable(), configDir,
      menu: Menu.getApplicationMenu().items.map(m => m.label),
    }));
    const work = path.join(dir, 'work');
    fs.mkdirSync(work, { recursive: true });
    await step('prepare', () => {
      fs.writeFileSync(path.join(work, 'sjis.txt'), codec.encode('日本語 Shift_JIS のファイル\n2 行目\tタブ　全角 半角\nhttps://example.com/\n', 'shiftJIS', 'crlf'));
      fs.writeFileSync(path.join(work, 'sample.js'), '// コメント\nconst s = "文字列"; // 42\nfunction f(a) {\n\treturn a + 1;\n}\n');
      fs.writeFileSync(path.join(work, 'sakubun.txt'), '春の遠足\n山田太郎\n\n先週の金曜日、学校の遠足で動物園に行きました。天気はとても良くて、朝から楽しみでした。\n「早く行こう。」\nと、友だちが言いました。\n');
      return true;
    });
    const p = f => JSON.stringify(path.join(work, f));
    await step('openFiles', async () => {
      await js('(async () => { await __app.openPath(' + p('sjis.txt') + '); await __app.openPath(' + p('sample.js') + '); })()');
      await wait(600);
      return js('({ tabs: __app.tabs.map(t => t.name + ":" + t.encoding + ":" + t.lineEnding), status: document.getElementById("status-cells").innerText,'
        + ' font: getComputedStyle(document.querySelector(".cm-scroller")).fontFamily,'
        + ' fonts: ["BIZ UDGothic", "MS Gothic", "Yu Mincho", "MS Mincho", "Yu Gothic UI", "Meiryo UI"].filter(n => document.fonts.check("12px \\"" + n + "\\"")),'
        + ' charWidth: __app.active.editor.view.defaultCharacterWidth, tokens: document.querySelectorAll("[class^=tok-]").length })');
    });
    await shot('1-editor');
    await step('saveRoundTrip', async () => {
      // 流出防止をいったん切って普通に保存 → Shift_JIS・CRLF のまま書けているか
      const saved = await js('(async () => { __app.prefs.encryptionEnabled = false; __app.activate(__app.tabs.find(t => t.name === "sjis.txt"));'
        + ' __app.active.editor.insertAtCursorEnd("追記①"); const ok = await __app.save(__app.active); __app.prefs.encryptionEnabled = true; return ok; })()');
      const d = codec.decode(fs.readFileSync(path.join(work, 'sjis.txt')));
      return { saved, encoding: d.encoding, lineEnding: d.lineEnding, hasAppend: d.text.includes('追記①') };
    });
    await shot('1b-sjis');
    await step('deviceEncryption', async () => {
      const key = await makeKey({ kind: 'device' });
      const file = path.join(work, 'secret.txt');
      writeDocument({ path: file, text: 'ひみつ\n', encoding: 'utf8', lineEnding: 'lf', encToken: keep(key) });
      const raw = fs.readFileSync(file);
      const back = await readDocument(file, {});
      return { encryptedOnDisk: fc.isEncrypted(raw), kind: fc.header(raw).kind, text: back.text, label: back.enc && back.enc.label };
    });
    await step('grep', async () => {
      const found = [];
      const r = await grep.search(work, { pattern: '遠足' }, m => found.push(path.basename(m.file) + ':' + m.line));
      return { found, scanned: r.scanned };
    });
    await step('furigana', async () => (await furigana.ruby('先週の金曜日、学校の遠足')).map(x => x.reading));
    await step('genko', async () => {
      await js('(async () => { __app.prefs.paperEnabled = true; __app.prefs.genkoFurigana = true; __app.applyPrefs(); await __app.openPath(' + p('sakubun.txt') + '); __app.setPaperMode(__app.active, 1); })()');
      await wait(2500);
      return js('({ status: document.getElementById("status-cells").innerText, ruby: document.querySelectorAll(".gk-ruby").length,'
        + ' sheets: document.querySelectorAll(".genko-sheet").length, font: getComputedStyle(document.querySelector(".gk")).fontFamily })');
    });
    await shot('2-genko');
    await step('genkoTyping', async () => {
      const wc = win().webContents;
      win().focus();
      wc.focus();
      await js('__app.active.paper.focus(); __app.active.paper.select(0, 0)');
      const before = await js('__app.active.paper.info().chars');
      wc.sendInputEvent({ type: 'char', keyCode: '新' });
      await wait(400);
      const after = await js('__app.active.paper.info().chars');
      const first = await js('__app.active.paper.getText().slice(0, 3)');
      wc.sendInputEvent({ type: 'keyDown', keyCode: 'Z', modifiers: ['control'] });
      wc.sendInputEvent({ type: 'keyUp', keyCode: 'Z', modifiers: ['control'] });
      await wait(400);
      return { before, after, first, undone: (await js('__app.active.paper.info().chars')) === before };
    });
    await step('genkoPDF', async () => {
      const ok = await js('__app.exportPDF(__app.active, ' + JSON.stringify(path.join(dir, 'genko.pdf')) + ')');
      return { ok, size: fs.statSync(path.join(dir, 'genko.pdf')).size };
    });
    await step('a4', async () => {
      await js('__app.setPaperMode(__app.active, 2)');
      await wait(500);
      const ok = await js('__app.exportPDF(__app.active, ' + JSON.stringify(path.join(dir, 'a4.pdf')) + ')');
      fs.writeFileSync(path.join(dir, 'a4.docx'), docxData([{ text: '春の遠足', align: 'center' }, { text: '山田太郎', align: 'right' }, { text: '本文です。', indent: true }]));
      return { ok, size: fs.statSync(path.join(dir, 'a4.pdf')).size };
    });
    await shot('3-a4');
    await step('plainPDF', async () => {
      await js('(async () => { __app.setPaperMode(__app.active, 0); __app.activate(__app.tabs.find(t => t.name === "sample.js")); })()');
      const ok = await js('__app.exportPDF(__app.active, ' + JSON.stringify(path.join(dir, 'plain.pdf')) + ')');
      return { ok, size: fs.statSync(path.join(dir, 'plain.pdf')).size };
    });
    await step('keyboard', async () => {
      // 本物のキー入力: 文字を打つ → Ctrl+Z で戻す → Ctrl+G で「指定行へ移動」が出る
      const wc = win().webContents;
      win().focus();
      wc.focus();
      await js('__app.focusEditor()');
      const before = await js('__app.active.editor.getText()');
      wc.sendInputEvent({ type: 'char', keyCode: 'x' });
      wc.sendInputEvent({ type: 'char', keyCode: 'あ' });
      await wait(300);
      const typed = await js('__app.active.editor.getText()');
      const press = (keyCode, modifiers) => {
        wc.sendInputEvent({ type: 'keyDown', keyCode, modifiers });
        wc.sendInputEvent({ type: 'keyUp', keyCode, modifiers });
      };
      press('Z', ['control']);
      press('Z', ['control']);
      await wait(300);
      const undone = (await js('__app.active.editor.getText()')) === before;
      press('G', ['control']);
      await wait(400);
      const dialog = await js('(document.querySelector(".modal-title") || {}).textContent || ""');
      press('Escape', []);
      await wait(200);
      const closed = await js('!document.querySelector(".modal-title")');
      press('F', ['control']);
      await wait(400);
      const find = await js('(document.querySelector(".float-title span") || {}).textContent || ""');
      press('Escape', []);
      await wait(200);
      // メニューバーの項目を選んだときも同じ動作になるか (検索 > 指定行へ移動…)
      const all = [];
      const walk = items => items.forEach(m => { all.push(m); if (m.submenu) walk(m.submenu.items); });
      walk(Menu.getApplicationMenu().items);
      const item = all.find(m => m.accelerator === 'CmdOrCtrl+G');
      if (item) item.click();
      await wait(400);
      const fromMenu = await js('(document.querySelector(".modal-title") || {}).textContent || ""');
      press('Escape', []);
      await wait(200);
      return { typed: typed.length - before.length, undone, dialog, closed, find, fromMenu };
    });
    await step('screenshot', async () => {
      const visible = await ctx.screenshot({ mode: 'visible', rect: { x: 0, y: 60, width: 600, height: 300 }, action: 'save', path: path.join(dir, 'shot-visible.png') });
      const whole = await ctx.screenshot({ mode: 'whole', width: 700, action: 'save', path: path.join(dir, 'shot-whole.png'),
        html: '<!doctype html><meta charset="utf-8"><body style="margin:0;background:#2b2b2b;color:#eee;font:14px monospace">' + Array.from({ length: 120 }, (x, i) => '<div>' + (i + 1) + ' 行目 全体の画像</div>').join('') + '</body>' });
      const copy = await ctx.screenshot({ mode: 'visible', rect: { x: 0, y: 0, width: 200, height: 100 }, action: 'copy' });
      const clip = ctx.clipboard.readImage().getSize();
      // 本物の手順: ダイアログで「文書全体」を選んで「コピー」→ クリップボードの画像をファイルに書いて確かめる
      const viaDialog = async name => {
        ctx.clipboard.clear();
        await js('__app.run("file.screenshot")');
        await wait(400);
        await js('document.querySelectorAll("input[name=shot-mode]")[1].click(); document.querySelector(".modal-buttons button.primary").click()');
        for (let i = 0; i < 40 && ctx.clipboard.readImage().isEmpty(); i++) await wait(250);
        const image = ctx.clipboard.readImage();
        if (!image.isEmpty()) fs.writeFileSync(path.join(dir, name + '.png'), image.toPNG());
        return image.getSize();
      };
      const plainWhole = await viaDialog('shot-dialog-plain');
      await js('(async () => { __app.activate(__app.tabs.find(t => t.name === "sakubun.txt")); __app.setPaperMode(__app.active, 1); })()');
      await wait(1500);
      const genkoWhole = await viaDialog('shot-dialog-genko');
      await js('(async () => { __app.setPaperMode(__app.active, 0); __app.activate(__app.tabs.find(t => t.name === "sample.js")); })()');
      await wait(300);
      return { visible, whole, copy, clipboard: clip, plainWhole, genkoWhole };
    });
    await step('pdfImport', async () => {
      const { importPDF } = require('./pdfimport');
      const a4 = await importPDF(path.join(dir, 'a4.pdf'));
      const plain = await importPDF(path.join(dir, 'plain.pdf'));
      const vertical = await importPDF(path.join(dir, 'genko.pdf'));
      return { a4: a4.text.split('\n').slice(0, 4), plain: plain.text.split('\n').slice(0, 3), vertical: vertical.text.split('\n').slice(0, 5), pages: [a4.pages, plain.pages, vertical.pages] };
    });
    await step('association', async () => {
      const winassoc = require('./winassoc');
      const before = await winassoc.status();
      const applied = await winassoc.apply({ exe: process.execPath, extensions: ['txt', 'sakubuntest'], fileMenu: true, folderMenu: true, labels: { open: 'さとるエディタで開く', grep: 'さとるエディタで grep' } });
      const during = await winassoc.status();
      // 点検で書いたものは消して、元の状態に戻す
      const restored = await winassoc.apply({ exe: process.execPath, extensions: before.extensions, fileMenu: before.fileMenu, folderMenu: before.folderMenu, labels: { open: 'さとるエディタで開く', grep: 'さとるエディタで grep' } });
      const after = await winassoc.status();
      return { before: [before.fileMenu, before.folderMenu, before.extensions], applied, during: [during.fileMenu, during.folderMenu, during.extensions], restored, after: [after.fileMenu, after.folderMenu, after.extensions] };
    });
    await step('customization', async () => {
      await js('__app.run("settings.open:keys")');
      await wait(600);
      const rows = await js('document.querySelectorAll(".key-row").length');
      await shot('5-keys');
      await js('document.querySelector(".modal-buttons button").click()');
      return { rows };
    });
    await step('modules', async () => {
      // 配布物に入れた部品が Windows の上で読み込めるか (つなぐ先がないので、読み込みと鍵の指紋の計算まで)
      const remote = require('./remote');
      const ssh2 = require('ssh2');
      const ftp = require('basic-ftp');
      const models = require('../shared/aimodels');
      const refused = await remote.connect({ kind: 'sftp', host: '127.0.0.1', port: 1, user: 'x', auth: 'password' }, 'x', path.join(dir, 'known.json')).list('/').then(() => 'connected?', e => e.message);
      return { ssh2: typeof ssh2.Client, ftp: typeof ftp.Client, fingerprint: remote.fingerprint(Buffer.from('abc')), refused, presets: Object.keys(models.PRESETS), luna: models.priceOf('gpt-6-luna') };
    });
    await step('aiPanel', async () => {
      await js('(async () => { Object.assign(__app.prefs, { aiEnabled: true, aiVisible: true }); __app.applyPrefs(); })()');
      await wait(500);
      const r = await js('({ badge: document.querySelector(".ai-badge").textContent, status: (document.querySelector(".status-cell[data-id=ai]") || {}).textContent, chips: document.querySelectorAll(".ai-chip").length, composer: !!document.querySelector(".ai-composer .ai-input") })');
      await shot('6-ai');
      await js('(async () => { Object.assign(__app.prefs, { aiEnabled: false, aiVisible: false }); __app.applyPrefs(); })()');
      return r;
    });
    // ---- Mac 版から移した機能 ----
    await step('pluginsReal', async () => {
      // 本物の Worker と satoplug:// の通り道で、拡張機能が本文を読み書きできるか (同期の呼び出し)
      const folder = path.join(configDir, 'plugins', 'selftest-plugin');
      fs.mkdirSync(folder, { recursive: true });
      fs.writeFileSync(path.join(folder, 'manifest.json'), JSON.stringify({ id: 'selftest-plugin', name: 'Selftest', version: '1.0.0', main: 'main.js', permissions: [] }));
      fs.writeFileSync(path.join(folder, 'main.js'), "satoru.commands.register({ id: 'up', title: 'Upper', key: 'cmd+shift+u' }, () => {"
        + " const s = satoru.editor.getText(); satoru.editor.setText(s.toUpperCase() + '\\n' + satoru.editor.language()); satoru.storage.set('n', 3); console.log('n=' + satoru.storage.get('n', 0)); });"
        + " satoru.on('beforeSave', () => console.log('beforeSave'));");
      await js('(async () => { __app.newTab(); __app.active.editor.setText("hello plugin", true); await __app.plugins.loadAll(); })()');
      await wait(800);
      await js('__app.run("plugin.run:selftest-plugin/up")');
      await wait(1500);
      const r = await js('({ text: __app.active.editor.getText(), log: __app.plugins.plugins.filter(p => p.manifest.id === "selftest-plugin").map(p => p.log.map(l => l.text)) })');
      fs.rmSync(folder, { recursive: true, force: true });
      await js('__app.plugins.loadAll()');
      return r;
    });
    await step('fileIcon', async () => js('(async () => { const u = await window.api.fileIcon("html"); return u ? u.slice(0, 22) + "… (" + u.length + ")" : ""; })()'));
    await step('diffPanel', async () => {
      await js('(async () => { await __app.openPath(' + p('sample.js') + '); const v = __app.active.editor.view; v.dispatch({ changes: { from: 0, insert: "// ADDED\\n" }, userEvent: "input" }); __app.run("view.diff"); })()');
      await wait(900);
      const r = await js('({ rows: document.querySelectorAll("#diff-pane .diff-row").length, added: Array.from(document.querySelectorAll("#diff-pane .diff-added")).map(e => e.textContent), editedNumbers: Array.from(document.querySelectorAll(".cm-gutterElement.cm-edited-line")).map(e => e.textContent), tab: document.querySelector(".tab.active .tab-name").textContent })');
      await shot('7-diff');
      await js('__app.run("view.diff")');
      return r;
    });
    await step('localLLM', async () => {
      await js('__app.run("ai.localLLM")');
      await wait(2500);
      const r = await js('({ compat: (document.querySelector(".llm-compat") || {}).textContent, state: (document.querySelector(".llm-state") || {}).textContent, rows: document.querySelectorAll(".llm-row").length })');
      await shot('8-localllm');
      await js('(document.querySelector(".float-window .float-close") || { click() {} }).click()');
      return r;
    });
    await step('settings', async () => {
      await js('__app.run("settings.open:theme")');
      await wait(800);
      return js('({ cards: document.querySelectorAll(".theme-card").length, icons: Array.from(document.querySelectorAll(".icon-color img")).filter(i => i.naturalWidth > 0).length })');
    });
    await shot('4-settings');
    await step('english', async () => {
      setLanguage('en');
      const menu = Menu.getApplicationMenu().items.map(m => m.label);
      setLanguage('auto');
      return menu;
    });
  } catch (e) {
    report.errors.push('selftest: ' + ((e && e.stack) || e));
  }
  try { fs.writeFileSync(path.join(dir, 'report.json'), JSON.stringify(report, null, 2)); } catch (e) { /* 書けなければあきらめる */ }
  ctx.quit();
};
