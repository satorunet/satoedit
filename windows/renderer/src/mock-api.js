// ブラウザだけで画面を動かして確かめるための代役 (本物のアプリでは使わない)。
// ファイルはメモリの中に置き、メニューバーは画面の上に簡単なものを出す
import { h, popupMenu } from './dialogs';
import i18n from '../../shared/i18n';
import themeDef from '../../shared/theme';

export function installMockAPI() {
  const listeners = {};
  const emit = (channel, ...args) => (listeners[channel] || []).forEach(fn => setTimeout(() => fn(...args), 0));
  const files = new Map([
    ['/mock/picture.png', ''], ['/mock/data.bin', ''],
    ['/mock/メモ.txt', '半角 スペース と　全角スペース\tタブ\nhttps://example.com/ を見てください。\n3 行目です。\n'],
    ['/mock/src/sample.js', '// コメント\nconst greeting = "こんにちは"; // "文字列"\nfunction add(a, b) {\n\treturn a + b + 42;\n}\nclass Foo extends Bar {}\n'],
    ['/mock/src/page.html', '<!-- コメント -->\n<div class="box">本文</div>\n'],
    ['/mock/作文.txt', '春の遠足\n山田太郎\n\n先週の金曜日、学校の遠足で動物園に行きました。天気はとても良くて、朝から楽しみでした。\n「早く行こう。」\nと、友だちが言いました。\n'],
  ]);
  const prefs = {
    wrap: true, invisibles: true, lineNumbers: true, columnRuler: true, toolbar: true, showEOF: true, highlightCurrentLine: true,
    autoIndent: true, codeCompletion: true, rememberCaret: true, defaultEncoding: 'utf8', defaultLineEnding: 'crlf', backupOnSave: false, trimTrailingOnSave: false,
    encryptAlways: false, aiEnabled: false, encryptionEnabled: false, paperEnabled: false, folderTreeEnabled: false,
    lineCounting: 'logical', lineSpacing: 2, genkoFullWidth: false, genkoFurigana: false, genkoAutoFormat: true, a4AutoFormat: true, linkURLs: true, paperSavePDF: true,
    encDefaultKind: 'device', aiProvider: 'openai', aiModels: {}, aiCustomBaseURL: 'http://localhost:11434/v1', aiVerified: {},
    folderTreeVisible: false, folderTreeRoot: '', folderTreeWidth: 240, aiVisible: false, diffVisible: false, remotePlaces: {}, remoteTreeVisible: false, remoteTreeWidth: 260, pluginsDisabled: [], pluginSources: {}, pluginStorage: {}, diffWidth: 360, aiWidth: 340, iconColor: 'ai',
    recent: [], carets: {}, lastKeyFileDir: '', windowBounds: null, language: 'auto', collabEnabled: false, collabChatVisible: true, collabPort: 7650, collabName: '', aiApply: 'confirm', keys: {}, hiddenMenu: [], toolbarItems: null, aiPrices: {}, aiYenPerDollar: 150, servers: [], serverEnabled: false, remoteAutoUpload: true,
    autoUpdateCheck: true, updateSkipVersion: '', updateLastCheck: 0,
  };
  try { Object.assign(prefs, JSON.parse(sessionStorage.getItem('mock-prefs') || '{}')); } catch (e) { /* なし */ }
  const query = new URLSearchParams(location.search);
  if (query.get('lang')) prefs.language = query.get('lang');
  const mock = { files, prefs, calls: [], next: {}, lastPrint: null, encrypted: new Map() };
  window.__mock = mock;
  const log = (name, ...args) => mock.calls.push([name, ...args]);
  const dirOf = p => p.slice(0, p.lastIndexOf('/')) || '/';

  const api = {
    on(channel, fn) { (listeners[channel] = listeners[channel] || []).push(fn); },
    emit,
    async init() {
      return { prefs, theme: themeDef.defaults(), themeProblems: [], userProfiles: [], platform: 'mock', version: '1.0.1', files: [],
        secretsAvailable: true, aiPriceOverrides: {}, configDir: '/mock/.satoruEditor', userName: 'user', hostName: 'pc', homeDir: '/mock',
        language: i18n.resolve(prefs.language, navigator.language) };
    },
    async setPref(key, value) { prefs[key] = value; try { sessionStorage.setItem('mock-prefs', JSON.stringify(prefs)); } catch (e) { /* なし */ } return true; },
    async saveTheme(theme) { log('saveTheme', theme); return true; },
    async saveUserProfiles(list) { log('saveUserProfiles', list); return true; },
    async setMenuState() { return true; },
    async exportSettings() { return true; },
    async importSettings() { return { status: 'cancel' }; },
    async openDialog(o = {}) { log('openDialog', o); if (mock.next.open) { const v = mock.next.open; mock.next.open = null; return v; } return o.directory ? ['/mock'] : ['/mock/メモ.txt']; },
    async saveDialog(o = {}) { log('saveDialog', o); if (mock.next.save) { const v = mock.next.save; mock.next.save = null; return v; } return '/mock/' + String(o.defaultPath || '保存.txt').split(/[\\/]/).pop(); },
    async readFile(path, opts = {}) {
      if (!files.has(path)) return { status: 'error', message: 'ファイルがありません' };
      const enc = mock.encrypted.get(path);
      if (enc) {
        const creds = opts.creds || {};
        if (enc.kind === 'password' && typeof creds.password !== 'string') return { status: 'locked', need: 'password', kind: 'password' };
        if (enc.kind === 'password' && creds.password !== enc.password) return { status: 'error', code: 'wrong', message: 'パスワード (パスコード) が違うか、ファイルが壊れています' };
      }
      const text = files.get(path);
      // 画面の確認用: .png は画像、.bin はバイナリとして見せる
      if (!opts.forceText && /\.png$/i.test(path)) return { status: 'viewer', kind: 'image', mime: 'image/png', size: 70, base64: 'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAN0lEQVR42mNkYPhfz0AEYBzVSF+NjFRrZMQqI7EqiTKAaJtGNQ5mjYzUaiRaIzGaRzWObI0AlWYPET0Ki4gAAAAASUVORK5CYII=' };
      if (!opts.forceText && /\.bin$/i.test(path)) return { status: 'viewer', kind: 'hex', size: 40, base64: btoa('Hello, world!\n\u0000\u0001ABC binary data here...') };
      return { status: 'ok', path, text: text.replace(/\r\n?/g, '\n'), encoding: opts.encoding || 'utf8', lineEnding: text.includes('\r\n') ? 'crlf' : 'lf',
        enc: enc ? { token: enc.token, kind: enc.kind, label: enc.label } : null, mtime: Date.now() };
    },
    async writeFile(o) {
      log('writeFile', o);
      files.set(o.path, o.text);
      if (o.encToken) mock.encrypted.set(o.path, mock.keys[o.encToken]); else mock.encrypted.delete(o.path);
      return { status: 'ok', mtime: Date.now() };
    },
    async fileInfo(path) { return { exists: files.has(path) }; },
    async clearRecent() { prefs.recent = []; return true; },
    async totpBegin() { return { enrollId: 'e1', base32: 'AEEA6FQ5EQVTEOKAI5HFKXDDNJYXQ74G', uri: 'otpauth://totp/satoruEditor:doc?secret=AEEA6FQ5EQVTEOKAI5HFKXDDNJYXQ74G&issuer=satoruEditor' }; },
    async makeKey(o) {
      log('makeKey', o);
      if ((o.kind === 'totp' || o.kind === 'twoStep') && o.code !== '123456') return { status: 'error', message: '6 桁のコードが違います。スマホの認証アプリに出ている数字を入れてください。' };
      const token = 'k' + Math.random().toString(36).slice(2);
      const labels = { password: 'パスワード', passcode: 'パスコード', device: 'この PC のロック', totp: 'ワンタイム認証', twoStep: '二段階', keyfile: '鍵ファイル' };
      mock.keys = mock.keys || {};
      mock.keys[token] = { token, kind: o.kind, label: i18n.t(labels[o.kind]), password: o.password };
      return { status: 'ok', enc: { token, kind: o.kind, label: i18n.t(labels[o.kind]) } };
    },
    async newKeyFile() { return '/mock/usb/satoruEditor-key.satorukey'; },
    async listDir(dir) {
      const out = new Map();
      const prefix = dir.replace(/\/+$/, '') + '/';
      for (const p of files.keys()) {
        if (!p.startsWith(prefix)) continue;
        const rest = p.slice(prefix.length);
        const i = rest.indexOf('/');
        if (i < 0) out.set(rest, { name: rest, dir: false }); else out.set(rest.slice(0, i), { name: rest.slice(0, i), dir: true });
      }
      return Array.from(out.values()).sort((a, b) => (a.dir !== b.dir ? (a.dir ? -1 : 1) : a.name.localeCompare(b.name, 'ja')));
    },
    async findFiles(root, q) { return { files: Array.from(files.keys()).filter(p => p.startsWith(root) && p.split('/').pop().toLowerCase().includes(q.toLowerCase())), truncated: false }; },
    async createEntry(dir, name, isDir) { const p = dir.replace(/\/+$/, '') + '/' + name; if (isDir) files.set(p + '/.keep', ''); else files.set(p, ''); return { status: 'ok', path: p }; },
    async renameEntry(file, name) { const to = dirOf(file) + '/' + name; files.set(to, files.get(file) || ''); files.delete(file); return { status: 'ok', path: to }; },
    async trashEntry(file) { files.delete(file); return { status: 'ok' }; },
    async reveal(p) { log('reveal', p); return true; },
    async openPath(p) { log('openPath', p); return ''; },
    async openExternal(url) { log('openExternal', url); return true; },
    async copyText(text) { log('copyText', text); try { await navigator.clipboard.writeText(text); } catch (e) { /* なし */ } return true; },
    async pathInfo(file) { return { dir: dirOf(file), base: file.split('/').pop(), sep: '/', home: '/mock' }; },
    async editCommand(name) { document.execCommand(name); return true; },
    pathForFile() { return ''; },
    async grepStart(id, root, o) {
      const re = new RegExp(o.useRegex ? o.pattern : o.pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), o.caseSensitive ? 'u' : 'iu');
      const list = [];
      for (const [p, text] of files) {
        if (!p.startsWith(root)) continue;
        text.split('\n').forEach((line, i) => { if (re.test(line)) list.push({ file: p, line: i + 1, text: line }); });
      }
      emit('grep:matches', id, list);
      emit('grep:done', id, { count: list.length, scanned: files.size });
      return true;
    },
    async grepCancel() { return true; },
    async furigana(text) {
      // 見た目を確かめるための、いくつかの言葉だけの読み
      const dict = { 遠足: 'えんそく', 山田: 'やまだ', 太郎: 'たろう', 先週: 'せんしゅう', 金曜日: 'きんようび', 学校: 'がっこう', 動物園: 'どうぶつえん', 天気: 'てんき', 春: 'はる', 行: 'い', 朝: 'あさ', 楽: 'たの', 早: 'はや', 友: 'とも', 言: 'い', 良: 'よ' };
      const out = [];
      for (const [word, reading] of Object.entries(dict)) {
        let i = -1;
        while ((i = text.indexOf(word, i + 1)) >= 0) out.push({ from: i, to: i + word.length, reading });
      }
      return out.sort((a, b) => a.from - b.from);
    },
    async aiStatus() { return { openai: { hasKey: !!mock.aiKey }, claude: { hasKey: false }, gemini: { hasKey: false }, custom: { hasKey: false } }; },
    async aiSetKey(p, key) { mock.aiKey = key; return { status: 'ok' }; },
    async aiListModels() { return { status: 'ok', models: ['mock-model-large', 'mock-model-small'] }; },
    async aiSend(id, o) {
      log('aiSend', o);
      // 画面の確認で、答えを決めておける (mock.next.aiAnswer)
      const fixed = mock.next.aiAnswer;
      if (fixed) delete mock.next.aiAnswer;
      const words = fixed ? fixed.match(/[\s\S]{1,12}/g) : ['これは', '見本の', '答え', 'です。'];
      words.forEach((wd, i) => setTimeout(() => emit('ai:delta', id, wd), 30 * (i + 1)));
      setTimeout(() => emit('ai:done', id, { usage: { inputTokens: 12, outputTokens: 8, estimated: false } }), 30 * (words.length + 1) + 20);
      return true;
    },
    async aiCancel(id) { emit('ai:done', id, { cancelled: true }); return true; },
    async serverSave(server, password) { const s = Object.assign({}, server, { id: server.id || 's' + Math.random().toString(36).slice(2), port: Number(server.port) || 22 }); prefs.servers = (prefs.servers || []).filter(x => x.id !== s.id).concat([s]); return { status: 'ok', server: s }; },
    async serverDelete(id) { prefs.servers = (prefs.servers || []).filter(x => x.id !== id); return true; },
    async serverForgetKey() { return true; },
    async serverHasPassword() { return true; },
    async remoteCall(id, action, a, b) {
      log('remoteCall', action, a, b);
      if (action === 'home') return { status: 'ok', value: '/mock' };
      if (action === 'list') return { status: 'ok', value: (await api.listDir(a)).map(e => Object.assign({ size: e.dir ? 0 : (files.get(a.replace(/\/+$/, '') + '/' + e.name) || '').length }, e)) };
      if (action === 'create') files.set(a, '');
      if (action === 'remove') files.delete(a);
      if (action === 'rename') { files.set(b, files.get(a) || ''); files.delete(a); }
      return { status: 'ok' };
    },
    async remoteRead(id, file) { const r = await api.readFile(file, {}); return r.status === 'ok' ? Object.assign(r, { remote: { id, path: file, url: 'sftp://taro@example.com' + file } }) : r; },
    async remoteWrite(id, file, o) { log('remoteWrite', file, o.text); files.set(file, o.text); return { status: 'ok' }; },
    async collabHost(port) { log('collabHost', port); return { status: 'ok', code: 'ABCD-EFGH-JKLM-NPQR', port: port || 7650, addresses: ['192.168.1.20'], hostName: 'pc' }; },
    async collabJoin(address, port, code) { log('collabJoin', address, port, code); return { status: 'ok' }; },
    async collabSend(id, msg) { mock.sent = mock.sent || []; mock.sent.push([id, msg]); return true; },
    async collabClose(id) { log('collabClose', id); return true; },
    async collabStop() { log('collabStop'); return true; },
    async attention() { return true; },
    async aiUsage() {
      const s = (count, input, output, cost) => ({ count, input, output, cost, unknownCost: false });
      return { summary: { today: s(2, 1200, 800, 0.012), month: s(14, 30000, 21000, 0.31), total: s(40, 90000, 61000, 0.95), months: [Object.assign({ month: '2026-11' }, s(14, 30000, 21000, 0.31)), Object.assign({ month: '2026-10' }, s(26, 60000, 40000, 0.64))] },
        prices: prefs.aiPrices || {}, yen: prefs.aiYenPerDollar || 150, pages: { openai: 'https://openai.com/api/pricing/' }, current: null };
    },
    async aiUsageClear() { return true; },
    async importPDF() { return { status: 'ok', text: 'PDF の 1 行目\nPDF の 2 行目\n', pages: 1 }; },
    async assocStatus() { return mock.assoc || { supported: true, fileMenu: false, folderMenu: false, extensions: [], defaults: ['txt', 'log', 'md'] }; },
    async assocApply(o) { log('assocApply', o); mock.assoc = { supported: true, fileMenu: o.fileMenu, folderMenu: o.folderMenu, extensions: o.extensions, defaults: ['txt', 'log', 'md'] }; return { status: 'ok' }; },
    async exportPDF(o) { log('exportPDF', o.path); mock.lastPrint = o; return { status: 'ok' }; },
    async print(o) { mock.lastPrint = o; return { status: 'ok' }; },
    async screenshot(o) { log('screenshot', o); mock.lastShot = o; return { status: 'ok', width: 800, height: 600, clipped: false }; },
    async exportDocx(o) { log('exportDocx', o); return { status: 'ok' }; },
    async setTitle(title) { document.title = title; return true; },
    async closeWindow() { log('closeWindow'); return true; },
    async quit() { emit('app:request-close'); return true; },
    async about() { return true; },
    async updateCheck(o) { return (o && o.auto) ? { status: 'off', current: '1.0.1' } : { status: 'latest', current: '1.0.1', version: '1.0.1' }; },
    async updateDownload() { return { status: 'cancel' }; },
    async updateCancel() { return true; },
    async updateInstall() { return { status: 'error', message: 'mock' }; },
    async fileIcon() { return ''; },
    async growWindow(dx) { log('growWindow', dx); return true; },
    async pluginList() { return mock.plugins || []; },
    async pluginsFolder() { return '/mock/.satoruEditor/plugins'; },
    async pluginPrepare(from) { log('pluginPrepare', from); return { ok: false, error: 'mock' }; },
    async pluginCommit() { return { ok: false, error: 'mock' }; },
    async pluginDiscard() { return true; },
    async pluginUninstall(id) { log('pluginUninstall', id); return true; },
    async pluginTemplate(id) { log('pluginTemplate', id); return { ok: false, error: 'mock' }; },
    async pluginDocs() { return '/mock/.satoruEditor/plugins/README.md'; },
    async pluginFetch() { throw new Error('mock'); },
    async readClipboard() { return ''; },
    async pluginToken() { return true; },
    async pluginReply() { return true; },
    async llmStatus() { return mock.llm || { running: false, installed: false, models: [], platform: 'mock', release: '', build: 0 }; },
    async llmRequiredBuild() { return { build: 19045, checked: true }; },
    async llmInstall() { log('llmInstall'); return { ok: true }; },
    async llmCancelInstall() { return true; },
    async llmStart() { log('llmStart'); return true; },
    async llmPull(name) { log('llmPull', name); return { ok: true }; },
    async llmCancelPull() { return true; },
    async llmDelete(name) { log('llmDelete', name); return true; },
    /// 本物では Windows のメニューバーになるもの
    mockMenu(menus) {
      let bar = document.getElementById('mock-menubar');
      if (!bar) { bar = h('div', { id: 'mock-menubar' }); document.getElementById('app').prepend(bar); }
      bar.textContent = '';
      const open = (items, x, y) => popupMenu(items.map(m => {
        if (m.type === 'separator') return 'sep';
        if (m.header) return { label: '― ' + m.label + ' ―', disabled: true };
        if (m.submenu) return { label: m.label + '  ▸', action: () => open(m.submenu, x + 40, y + 20) };
        return { label: m.label + (m.accel ? '    ' + m.accel : ''), checked: m.checked, disabled: m.enabled === false, action: () => emit('command', m.id) };
      }), x, y);
      for (const m of menus) {
        bar.append(h('button', { class: 'mock-menu', onclick: e => { const r = e.currentTarget.getBoundingClientRect(); open(m.submenu, r.left, r.bottom); } }, m.label.replace(/\(&.\)/, '')));
      }
    },
    // テキスト一覧・版の履歴・バックアップ (ブラウザで見るときは空のまま)
    async libraryInfo() { return { root: 'C:\\Users\\you\\Documents\\さとるエディタ', history: '' }; },
    async libraryItems() { return []; },
    async libraryTree() { return []; },
    async versionList() { return []; },
    async http() { return { status: 0, body: '' }; },
  };
  for (const n of ['libraryCreateFolder', 'libraryRenameFolder', 'libraryMoveFolder', 'libraryTrash', 'libraryCreateBlank', 'libraryGetMode', 'librarySetMode',
    'librarySetLocked', 'libraryDuplicate', 'libraryMove', 'libraryFolderPath', 'libraryReadText', 'libraryRemoveEmpty', 'libraryRemovePlaceholder', 'librarySame',
    'versionNoteSaved', 'versionNoteOpened', 'versionFlush', 'versionContent', 'versionRepath', 'versionForget', 'versionPruneAll', 'versionReveal',
    'backupExport', 'backupOpen', 'backupRestore']) if (!api[n]) api[n] = async () => ({ status: 'error', message: 'mock' });
  window.api = api;
  // ?scenario=名前 を付けると、test/ui/scenarios.js の手順を自動で実行する (画面の確認用)
  const scenario = query.get('scenario');
  if (scenario) {
    const script = document.createElement('script');
    script.src = '../test/ui/scenarios.js';
    script.onload = async () => {
      const wait = ms => new Promise(r => setTimeout(r, ms));
      for (let i = 0; i < 100 && !document.body.classList.contains('ready'); i++) await wait(50);
      const out = document.createElement('pre');
      out.id = 'scenario-result';
      out.hidden = true;
      try {
        const r = await window.__scenarios[scenario](window.__app, wait);
        out.textContent = JSON.stringify({ ok: true, result: r === undefined ? null : r });
      } catch (e) {
        out.textContent = JSON.stringify({ ok: false, error: String((e && e.stack) || e) });
      }
      document.body.append(out);
    };
    document.head.append(script);
  }
}
