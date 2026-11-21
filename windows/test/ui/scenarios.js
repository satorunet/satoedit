// 画面の確認用の手順 (test/ui/shot.sh から ?scenario=名前 で呼ぶ)。本物のアプリには入らない
window.__scenarios = {
  // サーバ: 開くと右上に知らせ・エディタ横にサーバツリー (状態の色)・ログ。書き換えると「編集中」、保存で「更新」
  async remoteParity(app, wait) {
    app.prefs.servers = [{ id: 's1', name: 'テスト', kind: 'sftp', host: 'example.com', port: 22, user: 'taro', root: '/mock/src' }];
    app.setPref('serverEnabled', true);
    await app.openRemote('s1', '/mock/src/sample.js');
    await wait(500);
    const rowState = () => Array.from(document.querySelectorAll('.rtree-row')).map(r => r.querySelector('.tree-name').textContent + ':' + r.querySelector('.rtree-state').textContent);
    const opened = { tree: !document.getElementById('remote-pane').hidden, rows: rowState(), toast: (document.querySelector('.rtoast-title') || {}).textContent };
    const v = app.active.editor.view;
    v.dispatch({ changes: { from: 0, insert: '// edit\n' }, userEvent: 'input' });
    await wait(200);
    const editing = rowState();
    await app.saveRemote(app.active, true);
    await wait(200);
    return { opened, editing, saved: rowState(), log: Array.from(document.querySelectorAll('.rlog-lines div')).map(d => d.textContent.slice(9)) };
  },

  // 画像・バイナリは、エディタではなく見るだけの画面で開く
  async viewers(app, wait) {
    await app.openPath('/mock/data.bin');
    await wait(300);
    const hexRows = Array.from(document.querySelectorAll('.hex-row')).map(r => r.textContent);
    const tabsAfterBin = app.tabs.length;
    await app.openPath('/mock/picture.png');
    await wait(400);
    return { hexRows, tabsAfterBin, image: !!document.querySelector('.viewer-image'), windows: Array.from(document.querySelectorAll('.float-title span')).map(e => e.textContent) };
  },

  // JS 拡張機能: Worker の中で動き、コマンドがメニューに出て、追加機能の画面に一覧で出る
  async plugins(app, wait) {
    window.__mock.plugins = [{
      manifest: { id: 'hello', name: 'Hello', version: '1.0.0', author: 'me', description: 'あいさつする見本', main: 'main.js', permissions: ['clipboard'], icon: '👋' },
      folder: '/mock/.satoruEditor/plugins/hello', icon: '👋', error: null,
      source: "satoru.commands.register({ id: 'hi', title: 'Say hi', key: 'cmd+shift+h' }, () => console.log('hi run')); console.log('loaded!');",
    }];
    await app.plugins.loadAll();
    await wait(400);
    const p = app.plugins.plugins[0];
    app.run('plugin.run:hello/hi');
    await wait(300);
    const menuEntries = app.plugins.menuEntries();
    app.run('settings.open:features');
    await wait(400);
    const rows = Array.from(document.querySelectorAll('.feature-row .feature-name')).map(e => e.textContent);
    return { running: p.running, commands: p.commands, log: p.log.map(l => l.text), menuEntries, rows,
      addButton: !!document.querySelector('.add-row button'), groups: Array.from(document.querySelectorAll('.settings-group')).map(e => e.textContent) };
  },

  // 入力補完: 打つと候補が出て、関数のかっこの中では引数のヒントが出る
  async completion(app, wait) {
    await app.openPath('/mock/src/sample.js');
    await wait(150);
    const v = app.active.editor.view;
    v.focus();
    const end = v.state.doc.length;
    v.dispatch({ changes: { from: end, insert: '\ncons' }, selection: { anchor: end + 5 }, userEvent: 'input.type' });
    await wait(600);
    const options = Array.from(document.querySelectorAll('.cm-tooltip-autocomplete li')).slice(0, 6).map(li => li.textContent);
    // 一番上を選ぶ (Enter)
    v.contentDOM.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', keyCode: 13, bubbles: true, cancelable: true }));
    await wait(200);
    const afterAccept = v.state.doc.line(v.state.doc.lines).text;
    // 関数の引数ヒント
    const e2 = v.state.doc.length;
    v.dispatch({ changes: { from: e2, insert: '\nadd(1, ' }, selection: { anchor: e2 + 8 }, userEvent: 'input.type' });
    await wait(400);
    const hint = (document.querySelector('.cm-signature') || {}).innerHTML;
    return { options, afterAccept, hint };
  },

  // AI の欄: 答えを ひとこと と 中身 に分け、中身を自動で反映。ローカル LLM の画面も開く
  async aiParity(app, wait) {
    app.setPref('aiEnabled', true);
    app.setPref('aiModels', { openai: 'gpt-test' });
    app.setPref('aiVerified', { openai: 'ok|' });
    app.setPref('aiApply', 'auto');
    app.setPref('aiVisible', true);
    app.newTab();
    await wait(200);
    window.__mock.next.aiAnswer = '関数を書きました。\n<result>function add(a, b) {\n  return a + b;\n}\nconsole.log(add(1, 2));</result>';
    app.ai.prompt.value = 'add 関数を書いて';
    app.ai.runCustom();
    await wait(800);
    const msg = document.querySelector('.ai-msg.ai');
    const r = {
      note: msg && msg.querySelector('.ai-text').textContent, content: msg && msg.querySelector('.ai-content').textContent,
      editor: app.active.editor.getText(), language: app.active.profile && app.active.profile.name,
      badge: document.querySelector('.ai-badge').textContent, footer: (document.querySelector('.status-cell[data-id="ai"]') || {}).textContent,
      more: !!document.querySelector('.ai-more:not([hidden])'), template: !!document.querySelector('.ai-template'),
    };
    app.run('ai.localLLM');
    await wait(400);
    r.llmRows = document.querySelectorAll('.llm-row').length;
    r.llmCompat = (document.querySelector('.llm-compat') || {}).textContent;
    return r;
  },

  // 差分の欄: エディタの右に、行の高さをそろえて出る
  async diff(app, wait) {
    await app.openPath('/mock/src/sample.js');
    await wait(150);
    const v = app.active.editor.view;
    const l2 = v.state.doc.line(2);
    v.dispatch({ changes: { from: l2.from, to: l2.to, insert: 'const greeting = "CHANGED";' }, userEvent: 'input' });
    const l5 = v.state.doc.line(5);
    v.dispatch({ changes: { from: l5.to, insert: '\n// NEW LINE' }, userEvent: 'input' });
    app.active.editor.goToLine(4, 1);
    app.run('view.diff');
    await wait(700);
    const rows = Array.from(document.querySelectorAll('#diff-pane .diff-row'));
    const edLines = Array.from(v.dom.querySelectorAll('.cm-line'));
    const rowFor = n => rows.find(r => r.dataset.line === String(n) && !r.querySelector('.diff-num.removed'));
    const tops = [1, 4, 6].map(n => [Math.round(edLines[n - 1].getBoundingClientRect().top), Math.round(rowFor(n).getBoundingClientRect().top)]);
    return { rows: rows.map(r => r.textContent), tops, current: (document.querySelector('.diff-row.current') || {}).textContent };
  },

  // Mac 版から移した細かい機能: 編集した所の太字・タブの ＊・Tab の字下げ・フッターの用紙・設定の見出し
  async parity1(app, wait) {
    app.setPref('paperEnabled', true);
    await app.openPath('/mock/src/sample.js');
    await wait(150);
    const tab = app.active, v = tab.editor.view;
    // 2 行目に字を足す
    const l2 = v.state.doc.line(2);
    v.dispatch({ changes: { from: l2.to, insert: ' // ADDED' }, userEvent: 'input' });
    // 4 行目の中を選んで Tab (1 行の中でも、行ごと右へ)
    const l4 = v.state.doc.line(4);
    v.dispatch({ selection: { anchor: l4.from + 1, head: l4.from + 3 } });
    v.focus();
    const ev = new KeyboardEvent('keydown', { key: 'Tab', code: 'Tab', keyCode: 9, bubbles: true, cancelable: true });
    v.contentDOM.dispatchEvent(ev);
    await wait(200);
    const line4 = v.state.doc.line(4).text;
    const added = Array.from(v.dom.querySelectorAll('.cm-added')).map(e => e.textContent);
    const editedNumbers = Array.from(v.dom.querySelectorAll('.cm-gutterElement.cm-edited-line')).map(e => e.textContent);
    const tabText = document.querySelector('.tab.active .tab-name').textContent;
    const status = document.getElementById('status-cells').innerText.replace(/\n/g, ' | ');
    const toolbarFirst = (document.querySelector('.tb-button') || {}).title;
    return { line4, added, editedNumbers, tabText, status, toolbarFirst, title: document.title };
  },

  // 左右に分割: 2 つの画面が横に並び、同じ文章を映す
  async splitSide(app, wait) {
    await app.openPath('/mock/src/sample.js');
    await wait(150);
    app.run('view.splitSide');
    await wait(250);
    const tab = app.active;
    const a = tab.primary.getBoundingClientRect(), b = tab.secondary.getBoundingClientRect();
    const sideBySide = Math.abs(a.top - b.top) < 2 && b.left >= a.right - 4;
    app.run('view.split');
    await wait(200);
    const c = tab.primary.getBoundingClientRect(), d = tab.secondary.getBoundingClientRect();
    const stacked = d.top >= c.bottom - 4;
    app.run('view.splitSide');
    await wait(200);
    return { sideBySide, stacked, stillSplit: !!tab.editor.secondary, widths: [Math.round(a.width), Math.round(b.width)] };
  },

  // 通常のエディタ: 色分け・記号・ルーラー・タブ・ステータスバー
  async basic(app, wait) {
    await app.openPath('/mock/メモ.txt');
    await app.openPath('/mock/src/sample.js');
    await wait(200);
    const tab = app.active;
    tab.editor.goToLine(3, 5);
    await wait(200);
    const dom = tab.editor.view.dom;
    return {
      tabs: app.tabs.map(x => x.name), status: document.getElementById('status-cells').innerText.replace(/\n/g, ' | '),
      tokens: Array.from(dom.querySelectorAll('[class^="tok-"]')).slice(0, 6).map(e => e.className + ':' + e.textContent),
      newlineMarks: dom.querySelectorAll('.cm-inv-nl').length, eof: dom.querySelectorAll('.cm-inv-eof').length,
      tabMarks: dom.querySelectorAll('.cm-inv-tab').length, spaces: dom.querySelectorAll('.cm-inv-sp').length,
      menus: Array.from(document.querySelectorAll('.mock-menu')).map(e => e.textContent),
      toolbar: document.querySelectorAll('.tb-button').length, title: document.title,
    };
  },

  // 編集の操作と検索・置換
  async editing(app, wait) {
    const tab = app.active, e = tab.editor;
    e.setText('banana\napple\ncherry\napple\n  indented\n', false);
    app.run('edit.selectAll');
    app.run('line.sort');
    const sorted = e.getText();
    app.run('line.unique');
    const unique = e.getText();
    e.goToLine(1);
    app.run('line.duplicate');
    const dup = e.getText().split('\n').slice(0, 3);
    app.run('edit.undo');
    const undone = e.getText() === unique;
    app.find.spec.text = 'a';
    app.find.show(true);
    await wait(100);
    const count = document.querySelector('.find-status').textContent;
    app.find.next(false);
    const first = e.selectionText() + '@' + e.info().line;
    app.find.spec = Object.assign(app.find.spec, { text: '(\\w)pp', replace: '$1PP', regexp: true });
    app.find.replaceAll(false);
    const replaced = e.getText();
    const replaceStatus = document.querySelector('.find-status').textContent;
    app.find.spec = Object.assign(app.find.spec, { text: 'zzz', regexp: false });
    app.find.next(false);
    const notFound = document.querySelector('.find-status').textContent;
    app.find.spec = Object.assign(app.find.spec, { text: '[', regexp: true });
    app.find.refreshCount();
    const invalid = document.querySelector('.find-status').textContent;
    app.find.spec = Object.assign(app.find.spec, { text: 'an', regexp: false, replace: '' });
    app.find.refreshCount();
    await wait(100);
    return { sorted, unique, dup, undone, count, first, replaced, replaceStatus, notFound, invalid, dirty: tab.isDirty(), highlights: e.view.dom.querySelectorAll('.cm-searchMatch').length };
  },

  // 保存: 流出防止の確認 → 暗号化のしかた → 保存、開き直し
  async crypto(app, wait) {
    const tab = app.active;
    tab.editor.setText('ひみつの文章', true);
    const saving = app.save(tab);
    await wait(150);
    const ask = document.querySelector('.modal-title').textContent;
    const askButtons = Array.from(document.querySelectorAll('.modal-buttons button')).map(b => b.textContent);
    document.querySelector('.modal-buttons button.primary').click();
    await wait(200);
    const title = document.querySelector('.modal-title').textContent;
    const kinds = Array.from(document.querySelectorAll('.kind-label')).map(x => x.textContent);
    const checked = document.querySelector('input[name="enc-kind"]:checked').value;
    document.querySelector('input[name="enc-kind"][value="twoStep"]').click();
    await wait(300);
    return { ask, askButtons, title, kinds, checked, qr: !!document.querySelector('.qr-box svg'), saving: typeof saving };
  },

  async cryptoSave(app, wait) {
    const tab = app.active;
    tab.editor.setText('ひみつの文章', true);
    const saving = app.save(tab);
    await wait(150);
    document.querySelector('.modal-buttons button.primary').click();
    await wait(200);
    document.querySelector('input[name="enc-kind"][value="password"]').click();
    await wait(100);
    const inputs = document.querySelectorAll('.crypto-fields input[type="password"]');
    inputs[0].value = 'short'; inputs[1].value = 'short';
    document.querySelector('.modal-buttons button.primary').click();
    await wait(100);
    const tooShort = document.querySelector('.crypto-modal .find-status').textContent;
    inputs[0].value = 'long-password'; inputs[1].value = 'long-passwor';
    document.querySelector('.modal-buttons button.primary').click();
    await wait(100);
    const mismatch = document.querySelector('.crypto-modal .find-status').textContent;
    inputs[1].value = 'long-password';
    document.querySelector('.modal-buttons button.primary').click();
    const saved = await saving;
    await wait(100);
    const afterSave = { saved, name: tab.name, enc: tab.enc && tab.enc.kind, dirty: tab.isDirty(), title: document.title, notes: document.getElementById('status-notes').textContent };
    // いったん閉じて、パスワードを間違えてから正しく入れて開く
    const path = tab.path;
    await app.closeTab(tab);
    const opening = app.openPath(path);
    await wait(150);
    const unlockTitle = document.querySelector('.modal-title').textContent;
    document.querySelector('.modal-body input[type="password"]').value = 'wrong';
    document.querySelector('.modal-buttons button.primary').click();
    await wait(200);
    const wrongMessage = document.querySelector('.modal-body .find-status').textContent;
    document.querySelector('.modal-body input[type="password"]').value = 'long-password';
    document.querySelector('.modal-buttons button.primary').click();
    const reopened = await opening;
    return { tooShort, mismatch, afterSave, unlockTitle, wrongMessage, reopenedText: reopened && reopened.getText(), reopenedEnc: reopened && reopened.enc && reopened.enc.kind };
  },

  // 原稿用紙: 枠・自動整形・ふりがな・文字数
  async genko(app, wait) {
    app.prefs.paperEnabled = true;
    app.prefs.genkoFurigana = true;
    app.applyPrefs();
    await app.openPath('/mock/作文.txt');
    app.setPaperMode(app.active, 1);
    await wait(900);
    const p = app.active.paper;
    return {
      status: document.getElementById('status-cells').innerText.replace(/\n/g, ' | '), info: p.info(),
      sheets: document.querySelectorAll('.genko-sheet').length, chars: document.querySelectorAll('.gk:not(.sel)').length,
      ruby: Array.from(document.querySelectorAll('.gk-ruby')).slice(0, 5).map(e => e.textContent),
      format: !document.getElementById('status-format').hidden && document.getElementById('status-format').textContent,
      menus: Array.from(document.querySelectorAll('.mock-menu')).map(e => e.textContent),
    };
  },

  // 原稿用紙での入力・カーソル移動・選択
  async genkoTyping(app, wait) {
    app.prefs.paperEnabled = true;
    app.applyPrefs();
    app.setPaperMode(app.active, 1);
    await wait(200);
    const p = app.active.paper;
    p.focus();
    const type = s => document.execCommand('insertText', false, s);
    const key = (k, o) => p.input.dispatchEvent(new KeyboardEvent('keydown', Object.assign({ key: k, bubbles: true, cancelable: true }, o || {})));
    type('はじめての作文');
    key('Enter'); type('\n');
    type('佐藤花子');
    const before = p.getText();
    key('Enter'); // 自動整形: 名前のあとは 1 列空く
    await wait(50);
    const afterName = JSON.stringify(p.getText());
    type('あ'.repeat(45));
    await wait(50);
    const cellEnd = p.info();
    key('ArrowRight'); // 1 つ右の列 (前の列) へ
    const afterRight = p.info();
    key('ArrowUp', { shiftKey: true }); key('ArrowUp', { shiftKey: true });
    await wait(50);
    const selected = p.selectionText();
    await wait(100);
    return { before: JSON.stringify(before), afterName, cellEnd, afterRight, selected, selCells: document.querySelectorAll('.gk.sel').length,
      synced: app.active.editor.getText() === p.getText() || 'pending', dirty: app.active.isDirty(), text: p.getText().length };
  },

  async a4(app, wait) {
    app.prefs.paperEnabled = true;
    app.applyPrefs();
    await app.openPath('/mock/作文.txt');
    app.setPaperMode(app.active, 2);
    await wait(300);
    const p = app.active.paper;
    return { status: document.getElementById('status-cells').innerText.replace(/\n/g, ' | '),
      aligns: p.paragraphs().map(x => x.style.textAlign + '/' + x.style.textIndent), text: p.getText() === app.active.editor.getText() };
  },

  // 印刷・PDF 用の HTML をそのまま画面に出す (原稿用紙)
  async genkoPrint(app, wait) {
    app.prefs.paperEnabled = true;
    app.prefs.genkoFurigana = true;
    app.applyPrefs();
    await app.openPath('/mock/作文.txt');
    app.setPaperMode(app.active, 1);
    await wait(800);
    await app.exportPDF(app.active, '/mock/out.pdf');
    const job = window.__mock.lastPrint;
    document.open(); document.write(job.html.replace('--u: 1mm', '--u: 3.9px')); document.close();
    await wait(200);
    return { landscape: job.landscape, sheets: document.querySelectorAll('.genko-sheet').length };
  },

  async settingsTheme(app, wait) {
    app.run('settings.open:theme');
    await wait(300);
    return { cards: document.querySelectorAll('.theme-card').length, colors: document.querySelectorAll('.color-row').length, tabs: Array.from(document.querySelectorAll('.settings-tab')).map(e => e.textContent) };
  },
  async settingsGeneral(app, wait) { app.run('settings.open:general'); await wait(300); return { checks: document.querySelectorAll('.settings-content input[type=checkbox]').length }; },
  async settingsFeatures(app, wait) { app.run('settings.open:features'); await wait(300); return { features: Array.from(document.querySelectorAll('.feature-head strong')).map(e => e.textContent) }; },
  async settingsFileTypes(app, wait) { await app.openPath('/mock/src/sample.js'); app.run('settings.open:filetypes'); await wait(300); return { langs: document.querySelector('.settings-content select').options.length }; },

  // フォルダツリー・AI・grep・分割・ライトテーマを一度に
  async panels(app, wait) {
    Object.assign(app.prefs, { folderTreeEnabled: true, folderTreeVisible: true, aiEnabled: true, aiVisible: true, aiModels: { openai: 'mock-model-large' }, aiVerified: { openai: 'ok|' }, encryptionEnabled: false });
    app.theme.preset = 'ライト';
    app.applyPrefs();
    await app.tree.setRoot('/mock');
    await app.openPath('/mock/src/sample.js');
    const row = Array.from(document.querySelectorAll('.tree-row')).find(r => r.textContent.includes('src'));
    row.click();
    await wait(200);
    app.run('view.split');
    app.find.grepOptions = Object.assign(app.find.grepOptions, { pattern: 'です', root: '/mock' });
    app.find.startGrep();
    app.active.editor.view.dispatch({ selection: { anchor: 0, head: 7 } });
    app.ai.runAction('summarize');
    await wait(600);
    return {
      tree: Array.from(document.querySelectorAll('.tree-name')).map(e => e.textContent), grep: document.querySelectorAll('.grep-row').length,
      grepSummary: document.querySelector('.grep-summary').textContent, ai: document.querySelector('.ai-msg.ai .ai-text').textContent,
      aiTarget: document.querySelector('.ai-target').textContent, usage: document.querySelector('.ai-usage').textContent,
      split: !!app.active.editor.secondary, menus: Array.from(document.querySelectorAll('.mock-menu')).map(e => e.textContent),
      sent: window.__mock.calls.filter(c => c[0] === 'aiSend').map(c => c[1].prompt)[0],
    };
  },

  // サーバ: 登録 → 中を見る → 開く → 編集 → サーバに反映
  async server(app, wait) {
    app.prefs.serverEnabled = true;
    app.prefs.encryptionEnabled = false;
    app.prefs.servers = [{ id: 's1', name: '', kind: 'sftp', host: 'example.com', port: 22, user: 'taro', auth: 'password', keyFile: '', root: '/mock' }];
    app.applyPrefs();
    app.run('server.open');
    await wait(200);
    document.querySelector('.server-row').click();
    await wait(300);
    const listing = Array.from(document.querySelectorAll('.server-file')).map(e => e.dataset.name + (e.dataset.dir === '1' ? '/' : ''));
    const src = Array.from(document.querySelectorAll('.server-file')).find(e => e.dataset.name === 'src');
    src.dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
    await wait(300);
    const inSrc = Array.from(document.querySelectorAll('.server-file')).map(e => e.dataset.name);
    const where = document.querySelector('.servers-right input').value;
    return { listing, inSrc, where, menus: Array.from(document.querySelectorAll('.mock-menu')).map(e => e.textContent), toolbar: document.querySelectorAll('.tb-button').length };
  },
  async serverEdit(app, wait) {
    app.prefs.serverEnabled = true;
    app.prefs.encryptionEnabled = false;
    app.prefs.servers = [{ id: 's1', name: 'テスト', kind: 'sftp', host: 'example.com', port: 22, user: 'taro', auth: 'password', keyFile: '', root: '/mock' }];
    app.applyPrefs();
    const tab = await app.openRemote('s1', '/mock/メモ.txt');
    await wait(100);
    const opened = { name: tab.name, url: tab.remote.url, title: document.title, dirty: tab.isDirty() };
    tab.editor.insertAtCursorEnd('サーバで追記\n');
    const dirtyAfterEdit = tab.isDirty();
    await wait(2600); // 入力が止まって 2 秒で自動反映
    const auto = { dirty: tab.isDirty(), written: window.__mock.calls.filter(c => c[0] === 'remoteWrite').map(c => c[1] + ':' + c[2].slice(0, 8)), note: document.getElementById('status-notes').textContent };
    app.prefs.remoteAutoUpload = false;
    tab.editor.insertAtCursorEnd('手動\n');
    await wait(2300);
    const manualBefore = tab.isDirty();
    await app.save(tab);
    return { opened, dirtyAfterEdit, auto, manualBefore, manualAfter: tab.isDirty(), writes: window.__mock.calls.filter(c => c[0] === 'remoteWrite').length };
  },

  async settingsKeys(app, wait) {
    app.run('settings.open:keys');
    await wait(300);
    const input = Array.from(document.querySelectorAll('.key-input')).find(i => i.getAttribute('aria-label') === '上書き保存');
    input.focus();
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'q', code: 'KeyQ', ctrlKey: true, altKey: true, bubbles: true, cancelable: true }));
    await wait(200);
    const after = Array.from(document.querySelectorAll('.key-input')).find(i => i.getAttribute('aria-label') === '上書き保存').value;
    document.querySelector('.modal-buttons button').click();
    await wait(200);
    return { rows: document.querySelectorAll('.key-row').length, after, saved: app.prefs.keys, accel: app.accel.get('Ctrl+Alt+Q'), oldGone: !app.accel.has('Ctrl+S') };
  },
  // AI の設定: かんたん選択と料金、接続テスト → 利用可能の印
  async aiSettings(app, wait) {
    app.prefs.aiEnabled = true;
    app.prefs.aiVisible = true;
    app.applyPrefs();
    const before = { badge: document.querySelector('.ai-badge').textContent, status: (document.querySelector('.status-cell[data-id="ai"]') || {}).textContent };
    app.run('ai.settings');
    await wait(300);
    const options = Array.from(document.querySelectorAll('input[name="ai-preset"]')).map(i => i.closest('label').innerText.replace(/\n/g, ' | '));
    const banner0 = document.querySelector('.ai-banner').textContent;
    document.querySelector('.modal-body input[type="password"]').value = 'sk-test';
    Array.from(document.querySelectorAll('.modal-body button')).find(b => b.textContent === '接続テスト').click();
    await wait(700);
    const banner1 = document.querySelector('.ai-banner').textContent;
    return { before, options, banner0, banner1, model: app.prefs.aiModels, badge: document.querySelector('.ai-badge').textContent, status: document.querySelector('.status-cell[data-id="ai"]').textContent };
  },
  // AI のチャット: ボタンの依頼 → 確認して置き換え、自分で書いた依頼、範囲なしの置き換え、自動で書き換える
  async aiChat(app, wait) {
    Object.assign(app.prefs, { aiEnabled: true, aiVisible: true, aiModels: { openai: 'gpt-6-luna' }, aiVerified: { openai: 'ok|' }, encryptionEnabled: false, aiApply: 'confirm' });
    app.applyPrefs();
    const tab = app.active, e = tab.editor;
    e.setText('一行目です。\nなおしたい文。\n三行目。\n', false);
    e.view.dispatch({ selection: { anchor: 7, head: 14 } });
    const selected = e.selectionText();
    app.ai.runAction('proofread');
    await wait(500);
    const confirmText = document.querySelector('.ai-confirm:not([hidden])').innerText.replace(/\n/g, ' | ');
    e.view.dispatch({ selection: { anchor: 0 } }); // 待つあいだに選択を外しても、もとの場所を置き換える
    document.querySelector('.ai-confirm:not([hidden]) button.primary').click();
    await wait(100);
    const afterConfirm = e.getText();
    // 範囲を選ばずに「読みやすく」→ 置き換えボタンで文書全体を置き換える
    e.setText('全体を書き直す文章。', false);
    app.ai.runAction('rewrite');
    await wait(500);
    Array.from(document.querySelectorAll('.ai-msg.ai')).pop().querySelectorAll('.ai-apply')[1].click();
    await wait(100);
    const wholeReplaced = e.getText();
    app.run('edit.undo');
    const undone = e.getText();
    // 自分で書いた依頼 (Enter で送信)。自動では書き換えない
    const input = document.querySelector('.ai-input');
    input.value = 'この文を敬語にして';
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }));
    await wait(500);
    const afterCustom = e.getText();
    // 自動で書き換える
    app.setPref('aiApply', 'auto');
    app.ai.runAction('continueWriting');
    await wait(500);
    const afterAuto = e.getText();
    app.setPref('aiApply', 'never');
    await wait(50);
    return { selected, confirmText, afterConfirm: JSON.stringify(afterConfirm), wholeReplaced, undone, afterCustom, afterAuto: JSON.stringify(afterAuto),
      messages: Array.from(document.querySelectorAll('.ai-msg')).map(m => (m.classList.contains('user') ? 'U:' : 'A:') + m.querySelector('.ai-text').textContent.slice(0, 14)),
      neverDisabled: Array.from(document.querySelectorAll('.ai-apply')).every(b => b.disabled), inputCleared: input.value === '' };
  },
  // 共同編集 (ホスト): 申し込み → 承認 → 相手の変更・カーソル・チャット → 自分の変更が送られる
  async collabHost(app, wait) {
    Object.assign(app.prefs, { collabEnabled: true, encryptionEnabled: false });
    app.applyPrefs();
    const tab = app.active;
    tab.editor.setText('みんなで書く文章\n2 行目\n', false);
    app.run('collab.host');
    await wait(200);
    document.querySelector('.modal-buttons button.primary').click(); // 共有を始める
    await wait(300);
    const shareInfo = document.querySelector('.collab-share').innerText.replace(/\n/g, ' | ');
    document.querySelector('.modal-buttons button.primary').click(); // OK
    const s = app.collab;
    s.opened(5, '192.168.1.30');
    s.message(5, { t: 'hello', v: 1, name: 'Mac の太郎' });
    await wait(200);
    const approval = document.querySelector('.modal-title').textContent;
    document.querySelector('.modal-buttons button.primary').click(); // 承認する
    await wait(100);
    const welcome = window.__mock.sent.find(m => m[1].t === 'welcome')[1];
    s.message(5, { t: 'op', rev: 0, loc: 0, len: 0, text: '【追加】' });
    s.message(5, { t: 'cursor', loc: 4, len: 4 });
    s.message(5, { t: 'chat', text: 'こんにちは' });
    await wait(100);
    const afterRemote = tab.editor.getText();
    const caret = document.querySelector('.cm-remote-name') && document.querySelector('.cm-remote-name').textContent;
    window.__mock.sent = [];
    tab.editor.insertAtCursorEnd('X');
    await wait(50);
    const myOp = window.__mock.sent.filter(m => m[1].t === 'op').map(m => m[1]);
    app.run('edit.undo');
    const afterUndo = tab.editor.getText();
    return { shareInfo, approval, welcome: { id: welcome.id, rev: welcome.rev, text: welcome.text, users: welcome.users }, afterRemote, caret, myOp, afterUndo,
      chat: Array.from(document.querySelectorAll('.collab-log .ai-text, .collab-system')).map(e => e.textContent),
      users: Array.from(document.querySelectorAll('.collab-user')).map(e => e.textContent), status: document.getElementById('status-notes').textContent,
      menus: Array.from(document.querySelectorAll('.mock-menu')).map(e => e.textContent) };
  },
  // 共同編集 (ゲスト): 参加 → 承認されて新しいタブ → 自分の変更・返事・相手の変更
  async collabGuest(app, wait) {
    Object.assign(app.prefs, { collabEnabled: true, encryptionEnabled: false });
    app.applyPrefs();
    app.run('collab.join');
    await wait(200);
    const inputs = document.querySelectorAll('.modal-body input');
    inputs[0].value = '192.168.1.5:7650'; inputs[1].value = 'abcd-efgh-jkmn-pqrs';
    document.querySelector('.modal-buttons button.primary').click();
    await wait(200);
    const waitingTitle = document.querySelector('.modal-title').textContent;
    const s = app.collab;
    s.opened(0, '192.168.1.5');
    const hello = window.__mock.sent.find(m => m[1].t === 'hello')[1];
    s.message(0, { t: 'welcome', v: 1, id: 2, rev: 7, text: 'ホストの文章', title: 'memo.md', users: [{ id: 0, name: 'ホスト Mac' }, { id: 2, name: hello.name }], cursors: [{ author: 0, loc: 2, len: 0 }] });
    await wait(200);
    const tab = app.active;
    const opened = { name: tab.name, text: tab.editor.getText(), lang: tab.profile && tab.profile.name, modal: !!document.querySelector('.modal-title') };
    window.__mock.sent = [];
    tab.editor.insertAtCursorEnd('A'); // 1 つ目は送る
    tab.editor.insertAtCursorEnd('B'); // 返事が来るまでためる
    await wait(50);
    const sent1 = window.__mock.sent.filter(m => m[1].t === 'op').map(m => m[1]);
    s.message(0, { t: 'op', rev: 8, author: 0, loc: 0, len: 0, text: '先頭に' }); // ホストの変更 (すり合わせて反映)
    s.message(0, { t: 'op', rev: 9, author: 2, loc: 6, len: 0, text: 'A' }); // 自分の 1 つ目の返事 → 2 つ目を送る
    await wait(50);
    const sent2 = window.__mock.sent.filter(m => m[1].t === 'op').map(m => m[1]);
    return { hello: { name: hello.name, v: hello.v }, joinCall: window.__mock.calls.find(c => c[0] === 'collabJoin'), waitingTitle, opened, sent1, sent2, text: tab.editor.getText() };
  },
  // 行の数え方「ワープロ的」: 折り返した行も数える
  async lineCounting(app, wait) {
    const tab = app.active, e = tab.editor;
    e.setText('短い行\n' + 'とても長い行です。'.repeat(40) + '\n最後の行', false);
    await wait(100);
    e.setCaret(e.getText().length);
    await wait(100);
    const logical = { status: document.getElementById('status-cells').innerText.replace(/\n/g, ' | '), gutter: Array.from(document.querySelectorAll('.cm-lineNumbers .cm-gutterElement')).map(x => x.textContent).filter(Boolean) };
    app.run('view.lineCounting:visual');
    await wait(300);
    e.setCaret(e.getText().length);
    await wait(200);
    const visual = { status: document.getElementById('status-cells').innerText.replace(/\n/g, ' | '), gutter: Array.from(document.querySelectorAll('.cm-lineNumbers .cm-gutterElement')).map(x => x.textContent).filter(Boolean) };
    e.goToLine(3, 1, true);
    await wait(200);
    const at3 = e.info();
    app.run('view.lineCounting:logical');
    return { logical, visual, at3: { visualLine: at3.visual && at3.visual.line, line: at3.line, head: at3.head } };
  },
  // 暗号化の種類の表示と変更: ステータスバー → 方法の一覧・鍵の変更 (別枠)・設定の画面
  async cryptKind(app, wait) {
    const tab = app.active;
    tab.editor.setText('ひみつ', true);
    const before = document.querySelector('.status-cell[data-id="crypt"]').textContent;
    app.run('crypto.encrypt');
    await wait(200);
    document.querySelector('input[name="enc-kind"][value="password"]').click();
    await wait(100);
    const pw = document.querySelectorAll('.crypto-fields input[type="password"]');
    pw[0].value = pw[1].value = 'long-password';
    document.querySelector('.modal-buttons button.primary').click();
    await wait(400);
    const after = document.querySelector('.status-cell[data-id="crypt"]').textContent;
    document.querySelector('.status-cell[data-id="crypt"]').click();
    await wait(100);
    const popup = Array.from(document.querySelectorAll('.popup-item')).map(e => e.textContent);
    // 別枠: 鍵の変更 → 方法は選ばせず、パスワードだけ
    Array.from(document.querySelectorAll('.popup-item')).find(e => e.textContent.includes('鍵の変更')).click();
    await wait(200);
    const rekey = { title: document.querySelector('.modal-title').textContent, radios: document.querySelectorAll('input[name="enc-kind"]').length, fields: document.querySelectorAll('.crypto-fields input[type="password"]').length };
    const p2 = document.querySelectorAll('.crypto-fields input[type="password"]');
    p2[0].value = p2[1].value = 'another-password';
    document.querySelector('.modal-buttons button.primary').click();
    await wait(400);
    const keys = window.__mock.calls.filter(c => c[0] === 'makeKey').map(c => c[1].kind + ':' + c[1].password);
    // 設定の画面 (別枠)
    app.run('crypto.settings');
    await wait(200);
    const settings = { title: document.querySelector('.modal-title').textContent, body: document.querySelector('.modal-body').innerText.replace(/\n/g, ' | '), buttons: Array.from(document.querySelectorAll('.modal-buttons button')).map(b => b.textContent) };
    document.querySelector('.modal-body select').value = 'passcode';
    document.querySelector('.modal-buttons button.primary').click(); // 方法を変える
    await wait(200);
    const methodDialog = { title: document.querySelector('.modal-title').textContent, checked: document.querySelector('input[name="enc-kind"]:checked').value };
    document.querySelector('.modal-buttons button:not(.primary)').click();
    await wait(100);
    return { before, after, popup, rekey, keys, settings, methodDialog, menus: Array.from(document.querySelectorAll('.mock-menu')).map(e => e.textContent) };
  },
  async settingsToolbar(app, wait) { app.run('settings.open:toolbar'); await wait(300); return { rows: document.querySelectorAll('.key-row').length }; },
  async settingsAssoc(app, wait) { app.run('settings.open:assoc'); await wait(400); return { checks: document.querySelectorAll('.settings-content input[type=checkbox]').length }; },
  async aiUsage(app, wait) { app.prefs.aiEnabled = true; app.applyPrefs(); app.run('ai.usage'); await wait(400); return { cards: Array.from(document.querySelectorAll('.usage-cost')).map(e => e.textContent), rows: document.querySelectorAll('.usage-table tbody tr').length }; },

  // 閉じるときの確認、文字コードの変更、言語の切り替え
  async misc(app, wait) {
    const tab = app.active;
    tab.editor.setText('abc', true);
    const closing = app.closeTab(tab);
    await wait(150);
    const closeTitle = document.querySelector('.modal-title').textContent;
    const buttons = Array.from(document.querySelectorAll('.modal-buttons button')).map(b => b.textContent);
    document.querySelectorAll('.modal-buttons button')[2].click();
    const cancelled = !(await closing);
    app.run('doc.encoding:shiftJIS');
    app.run('doc.lineEnding:lf');
    app.run('doc.language:Python');
    await wait(100);
    const status = document.getElementById('status-cells').innerText.replace(/\n/g, ' | ');
    document.querySelector('.status-cell[data-id="enc"]').click();
    await wait(100);
    const popup = Array.from(document.querySelectorAll('.popup-item')).map(e => e.textContent);
    return { closeTitle, buttons, cancelled, status, popup };
  },
};
