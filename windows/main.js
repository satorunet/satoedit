'use strict';
// エディタβ (Windows 版) の本体側: ウインドウ、メニューバー、ファイルの読み書き、暗号化、grep、AI への通信、PDF・印刷
const { app, BrowserWindow, Menu, dialog, ipcMain, shell, safeStorage, nativeTheme, clipboard, nativeImage, protocol } = require('electron');
// 拡張機能 (Web Worker) から本体を呼ぶための通り道。同期の呼び出し (本文を読む など) にも使える
protocol.registerSchemesAsPrivileged([{ scheme: 'satoplug', privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true } }]);
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const codec = require('./core/codec');
const fc = require('./core/filecrypto');
const totp = require('./core/totp');
const grep = require('./core/grep');
const zip = require('./core/zip');
const ai = require('./core/ai');
const furigana = require('./core/furigana');
const aiusage = require('./core/aiusage');
const winassoc = require('./core/winassoc');
const remote = require('./core/remote');
const localllm = require('./core/localllm');
const plugins = require('./core/plugins');
const collabnet = require('./core/collabnet');
const { newCode: newCollabCode } = require('./core/collabcipher');
const menuDef = require('./shared/menu');
const themeDef = require('./shared/theme');
const profilesDef = require('./shared/profiles');
const binaryDef = require('./shared/binary');
const i18n = require('./shared/i18n');
const { t } = i18n;

const APP_ID = 'satoruEditor';   // フォルダ名などに使う名前
const OLD_APP_IDS = ['sakubunEditor', 'satoedit'];   // 前の名前 (この名前の設定を、初めて起動したときに引き継ぐ)
/// 画面に出す名前 (言語に合わせる)
const appName = () => t('エディタβ');
const CONFIG_DIR = path.join(os.homedir(), '.satoruEditor');
const OLD_CONFIG_DIRS = [path.join(os.homedir(), '.sakubunEditor'), path.join(os.homedir(), '.satomaru')];

/// 前の名前の設定フォルダ (~/.sakubunEditor か、さらに前の ~/.satomaru) があり、新しいほうがまだ無ければ、名前を変えて移す
function migrateConfigDir() {
  if (fs.existsSync(CONFIG_DIR)) return;
  for (const old of OLD_CONFIG_DIRS) {
    try {
      if (!fs.lstatSync(old).isDirectory()) continue;
      fs.renameSync(old, CONFIG_DIR);
      return;
    } catch (e) { /* 無い・移せないときは新しく作る */ }
  }
}

/// Electron の作業フォルダ (%APPDATA%\\<名前>) も前の名前から写す。秘密 (safeStorage) の鍵がここにあるので、写さないと保存したパスワードが読めなくなる
function migrateUserData() {
  try {
    const now = app.getPath('userData');
    if (fs.existsSync(now)) return;
    for (const id of OLD_APP_IDS) {
      const old = path.join(path.dirname(now), id);
      if (fs.existsSync(old)) { fs.cpSync(old, now, { recursive: true }); return; }
    }
  } catch (e) { /* 写せなくても起動はする */ }
}
const FILES = {
  prefs: path.join(CONFIG_DIR, 'prefs.json'),
  theme: path.join(CONFIG_DIR, 'theme.json'),
  profiles: path.join(CONFIG_DIR, 'profiles.json'),
  secrets: path.join(CONFIG_DIR, 'secrets.json'),
  usage: path.join(CONFIG_DIR, 'ai-usage.json'),
  knownHosts: path.join(CONFIG_DIR, 'known-hosts.json'),
  aiPrices: path.join(CONFIG_DIR, 'ai-prices.json'),
};

// 動作環境の設定値 (Mac 版と同じ名前。新規ファイルの改行だけ Windows に合わせて CRLF)
const PREF_DEFAULTS = {
  wrap: true, invisibles: true, lineNumbers: true, columnRuler: true, toolbar: true,
  showEOF: true, highlightCurrentLine: true, autoIndent: true, codeCompletion: true, rememberCaret: true,
  defaultEncoding: 'utf8', defaultLineEnding: 'crlf',
  backupOnSave: false, trimTrailingOnSave: false,
  encryptAlways: false, aiEnabled: false, encryptionEnabled: false, paperEnabled: false, folderTreeEnabled: false,
  lineCounting: 'logical', lineSpacing: 2, genkoFullWidth: false, genkoFurigana: false, genkoAutoFormat: true, a4AutoFormat: true, linkURLs: true, paperSavePDF: true,
  encDefaultKind: 'device', aiProvider: 'openai', aiModels: {}, aiCustomBaseURL: 'http://localhost:11434/v1', aiVerified: {},
  folderTreeVisible: false, folderTreeRoot: '', folderTreeWidth: 240, aiVisible: false, diffVisible: false, remotePlaces: {}, remoteTreeVisible: false, remoteTreeWidth: 260, pluginsDisabled: [], pluginSources: {}, pluginStorage: {}, diffWidth: 360, aiWidth: 340, iconColor: 'ai',
  recent: [], carets: {}, lastKeyFileDir: '', windowBounds: null, language: 'auto',
  collabEnabled: false, collabChatVisible: true, collabPort: 7650, collabName: '', aiApply: 'confirm', keys: {}, hiddenMenu: [], toolbarItems: null, servers: [], serverEnabled: false, remoteAutoUpload: true, aiPrices: {}, aiYenPerDollar: 150,
};

let win = null;
let prefs = Object.assign({}, PREF_DEFAULTS);
let menuState = {};
let pendingFiles = [];
let pendingGrep = '';
let rendererReady = false;
let allowClose = false;

// ---------- 設定ファイル ----------

function readJSON(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (e) {
    return fallback;
  }
}

function writeFileAtomic(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = file + '.tmp-' + process.pid;
  fs.writeFileSync(tmp, data);
  fs.renameSync(tmp, file);
}

function loadPrefs() {
  const saved = readJSON(FILES.prefs, {});
  prefs = Object.assign({}, PREF_DEFAULTS, saved && typeof saved === 'object' ? saved : {});
  applyLanguage();
}

function applyLanguage() {
  let locale = 'ja';
  try { locale = app.getLocale(); } catch (e) { /* 起動直後で取れないときは日本語 */ }
  i18n.setLanguage(i18n.resolve(prefs.language, locale));
}

let prefsTimer = null;
function savePrefsSoon() {
  clearTimeout(prefsTimer);
  prefsTimer = setTimeout(savePrefsNow, 300);
}
function savePrefsNow() {
  clearTimeout(prefsTimer);
  prefsTimer = null;
  try {
    writeFileAtomic(FILES.prefs, JSON.stringify(prefs, null, 2));
  } catch (e) { /* 書けなくても編集は続けられる */ }
}

function loadTheme() {
  const raw = readJSON(FILES.theme, null);
  if (raw === null) return { theme: themeDef.defaults(), problems: [] };
  return themeDef.fromJSON(raw);
}

function loadUserProfiles() {
  const raw = readJSON(FILES.profiles, []);
  return Array.isArray(raw) ? raw : [];
}

// ---------- 秘密の置き場 (Windows のログインに結び付けて暗号化) ----------

function secretsAvailable() {
  try { return safeStorage.isEncryptionAvailable(); } catch (e) { return false; }
}
function loadSecrets() { return readJSON(FILES.secrets, {}) || {}; }
function getSecret(name) {
  const v = loadSecrets()[name];
  if (!v || !secretsAvailable()) return null;
  try { return safeStorage.decryptString(Buffer.from(v, 'base64')); } catch (e) { return null; }
}
function setSecret(name, value) {
  const all = loadSecrets();
  if (value === null || value === '') {
    delete all[name];
  } else {
    if (!secretsAvailable()) throw new Error(t('この PC では秘密を安全に保存できません。'));
    all[name] = safeStorage.encryptString(value).toString('base64');
  }
  writeFileAtomic(FILES.secrets, JSON.stringify(all, null, 2));
}

// ---------- 暗号化の鍵 (中身は画面側に渡さず、番号だけ渡す) ----------

const keys = new Map();       // 番号 → 鍵
const enrollments = new Map(); // ワンタイム認証の登録途中の秘密
function keep(key) {
  const token = crypto.randomBytes(12).toString('hex');
  keys.set(token, key);
  return token;
}

const KIND_LABELS = {
  password: 'パスワード', passcode: 'パスコード', device: 'この PC のロック',
  totp: 'ワンタイム認証', twoStep: '二段階', keyfile: '鍵ファイル',
};
const kindLabel = kind => t(KIND_LABELS[kind] || kind);

function deviceRecord(id) {
  const raw = getSecret('key.' + id.toString('hex'));
  if (!raw) return null;
  try {
    const o = JSON.parse(raw);
    return { raw: o.raw ? Buffer.from(o.raw, 'base64') : null, totp: o.totp ? Buffer.from(o.totp, 'base64') : null };
  } catch (e) {
    return null;
  }
}
function storeDeviceRecord(id, rec) {
  setSecret('key.' + id.toString('hex'), JSON.stringify({
    raw: rec.raw ? rec.raw.toString('base64') : undefined, totp: rec.totp ? rec.totp.toString('base64') : undefined,
  }));
}

/// 鍵ファイルを探す: 前に使った場所と、つないであるドライブのいちばん上の階層
function findKeyFiles() {
  const dirs = [];
  if (prefs.lastKeyFileDir) dirs.push(prefs.lastKeyFileDir);
  if (process.platform === 'win32') {
    for (const letter of 'DEFGHIJKLMNOPQRSTUVWXYZ') dirs.push(letter + ':\\');
  } else {
    try { for (const v of fs.readdirSync('/Volumes')) dirs.push(path.join('/Volumes', v)); } catch (e) { /* なし */ }
  }
  const found = [];
  for (const d of dirs) {
    let names;
    try { names = fs.readdirSync(d); } catch (e) { continue; }
    for (const n of names) {
      if (n.toLowerCase().endsWith('.' + fc.KEYFILE_EXTENSION)) found.push(path.join(d, n));
    }
  }
  return found;
}

function readKeyFile(file) {
  try {
    if (fs.statSync(file).size >= 4096) return null;
    return fc.keyFileSecret(fs.readFileSync(file));
  } catch (e) {
    return null;
  }
}

/// 新しい鍵を用意する (暗号化して保存するとき)
async function makeKey(o) {
  switch (o.kind) {
    case 'password':
      if (typeof o.password !== 'string' || o.password.length < 8) throw new Error(t('パスワードは 8 文字以上にしてください。'));
      return fc.deriveKey(o.password, { kind: 'password' });
    case 'passcode':
      if (!/^[0-9]{6,}$/.test(o.password || '')) throw new Error(t('パスコードは数字 6 桁以上にしてください。'));
      return fc.deriveKey(o.password, { kind: 'passcode' });
    case 'device': {
      if (!secretsAvailable()) throw new Error('この PC では鍵を安全に保存できません。別の方法を選んでください。');
      const k = fc.newDeviceKey('device');
      storeDeviceRecord(k.salt, { raw: k.key });
      return k;
    }
    case 'totp':
    case 'twoStep': {
      if (!secretsAvailable()) throw new Error('この PC では鍵を安全に保存できません。別の方法を選んでください。');
      const secret = enrollments.get(o.enrollId);
      if (!secret) throw new Error(t('スマホの登録をやり直してください。'));
      if (!totp.verify(o.code || '', secret)) throw new Error(t('6 桁のコードが違います。スマホの認証アプリに出ている数字を入れてください。'));
      let k;
      if (o.kind === 'totp') {
        k = fc.newDeviceKey('totp');
        storeDeviceRecord(k.salt, { raw: k.key, totp: secret });
      } else {
        if (typeof o.password !== 'string' || o.password.length < 8) throw new Error(t('パスワードは 8 文字以上にしてください。'));
        k = await fc.twoStepKey(o.password, secret);
        storeDeviceRecord(k.salt, { totp: secret });
      }
      enrollments.delete(o.enrollId);
      return k;
    }
    case 'keyfile': {
      const secret = readKeyFile(o.keyFile);
      if (!secret) throw new Error(t('これは鍵ファイルではありません。'));
      prefs.lastKeyFileDir = path.dirname(o.keyFile);
      savePrefsSoon();
      return fc.keyFileKey(secret);
    }
    default:
      throw new Error(t('暗号化の方法を選んでください。'));
  }
}

/// 暗号化ファイルを開く。足りないものがあれば { need } を返して画面側で聞いてもらう
async function unlock(buf, creds) {
  const h = fc.header(buf);
  switch (h.kind) {
    case 'password':
    case 'passcode':
      if (typeof creds.password !== 'string') return { need: h.kind };
      return fc.openWithPassword(buf, creds.password);
    case 'device': {
      const rec = deviceRecord(h.salt);
      if (!rec || !rec.raw) throw fc.errors.keyNotHere();
      const key = fc.deviceKey(rec.raw, h.salt, 'device');
      return { plain: fc.open(buf, key), key };
    }
    case 'totp': {
      const rec = deviceRecord(h.salt);
      if (!rec || !rec.raw || !rec.totp) throw fc.errors.keyNotHere();
      if (typeof creds.code !== 'string') return { need: 'totp' };
      if (!totp.verify(creds.code, rec.totp)) throw new fc.CryptoError('wrongCode', t('6 桁のコードが違います。'));
      const key = fc.deviceKey(rec.raw, h.salt, 'totp');
      return { plain: fc.open(buf, key), key };
    }
    case 'twoStep': {
      const rec = deviceRecord(h.salt);
      if (!rec || !rec.totp) throw fc.errors.keyNotHere();
      if (typeof creds.password !== 'string' || typeof creds.code !== 'string') return { need: 'twoStep' };
      if (!totp.verify(creds.code, rec.totp)) throw new fc.CryptoError('wrongCode', t('6 桁のコードが違います。'));
      return fc.openTwoStep(buf, creds.password, rec.totp);
    }
    case 'keyfile': {
      const candidates = creds.keyFile ? [creds.keyFile] : findKeyFiles();
      for (const f of candidates) {
        const secret = readKeyFile(f);
        if (!secret || fc.keyFileFingerprint(secret) !== h.iterations) continue;
        prefs.lastKeyFileDir = path.dirname(f);
        savePrefsSoon();
        return fc.openWithKeyFile(buf, secret);
      }
      if (creds.keyFile) throw fc.errors.wrongKeyFile();
      return { need: 'keyfile' };
    }
    default:
      throw fc.errors.unsupportedVersion();
  }
}

// ---------- ウインドウ ----------

function iconPath(color) {
  const names = ['ai', 'shu', 'hinoki', 'sumi', 'yamabuki', 'murasaki', 'asagi', 'kinari'];
  return path.join(__dirname, 'assets', 'icons', (names.includes(color) ? color : 'ai') + '.png');
}

function applyNativeTheme(theme) {
  const style = theme.windowStyle;
  if (style === 'system') nativeTheme.themeSource = 'system';
  else if (style === 'theme') nativeTheme.themeSource = themeDef.isDark(themeDef.colors(theme).background) ? 'dark' : 'light';
  else nativeTheme.themeSource = 'light';
}

function createWindow() {
  const b = prefs.windowBounds || {};
  win = new BrowserWindow({
    width: b.width || 1100, height: b.height || 760, x: b.x, y: b.y,
    minWidth: 480, minHeight: 320,
    title: appName(),
    icon: iconPath(prefs.iconColor),
    backgroundColor: '#f0f0f0',
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true, nodeIntegration: false, sandbox: true, spellcheck: false,
    },
  });
  if (b.maximized) win.maximize();
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  win.once('ready-to-show', () => win.show());

  // 文中のリンクなどでアプリの画面が別のページに変わらないようにする
  win.webContents.on('will-navigate', e => e.preventDefault());
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^(https?|mailto):/i.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });

  win.on('close', e => {
    if (!win.isMinimized()) {
      const nb = win.getNormalBounds();
      prefs.windowBounds = { x: nb.x, y: nb.y, width: nb.width, height: nb.height, maximized: win.isMaximized() };
    }
    savePrefsNow();
    if (allowClose || !rendererReady) return;
    e.preventDefault();
    win.webContents.send('app:request-close'); // 保存していない文書がないか画面側で確かめる
  });
  win.on('closed', () => { win = null; });
}

function send(channel, ...args) {
  if (win && !win.isDestroyed()) win.webContents.send(channel, ...args);
}

// ---------- メニューバー ----------

function toElectronMenu(items) {
  return items.map(m => {
    if (m.type === 'separator') return { type: 'separator' };
    if (m.header) return { label: '― ' + m.label + ' ―', enabled: false };
    if (m.submenu) return { label: m.label, submenu: toElectronMenu(m.submenu) };
    const out = { label: m.label, enabled: m.enabled !== false };
    if (m.type === 'checkbox' || m.type === 'radio') { out.type = m.type; out.checked = !!m.checked; }
    if (m.accel) out.accelerator = m.accel.replace('Ctrl', 'CmdOrCtrl');
    if (m.role) {
      out.role = m.role; // 切り取り・コピー・貼り付けは OS の動きに任せる
    } else {
      out.registerAccelerator = false; // キーは画面側で受ける (ここでは表示だけ)
      const id = m.id;
      out.click = () => { if (id) send('command', id); };
    }
    return out;
  });
}

function rebuildMenu() {
  const state = Object.assign({}, menuState, { prefs, recent: (prefs.recent || []).slice(0, 12) });
  Menu.setApplicationMenu(Menu.buildFromTemplate(toElectronMenu(menuDef.build(state))));
}

// ---------- ファイル ----------

function addRecent(file) {
  prefs.recent = [file].concat((prefs.recent || []).filter(f => f !== file)).slice(0, 12);
  savePrefsSoon();
  try { app.addRecentDocument(file); } catch (e) { /* なくてもよい */ }
  rebuildMenu();
}

function fail(e) {
  return { status: 'error', code: e && e.code ? String(e.code) : '', message: (e && e.message) || String(e) };
}

/// ファイルの中身 (バイト列) → 文章。暗号化されていれば鍵を使って開く
async function decodeDocument(buf, opts = {}) {
  // 画像やバイナリは、エディタではなく見るだけの画面で開く (「テキストとして開く」を選んだときは文字として)
  if (!opts.forceText && !fc.isEncrypted(buf)) {
    const mime = binaryDef.imageType(opts.name);
    if (mime && buf.length <= 50 * 1024 * 1024) return { status: 'viewer', kind: 'image', mime, base64: buf.toString('base64'), size: buf.length };
    if (binaryDef.looksBinary(buf)) {
      const max = 16 * 1024 * 1024;
      return { status: 'viewer', kind: 'hex', base64: buf.subarray(0, max).toString('base64'), size: buf.length, truncated: buf.length > max };
    }
  }
  let body = buf, enc = null;
  if (fc.isEncrypted(buf)) {
    const r = await unlock(buf, opts.creds || {});
    if (r.need) return { status: 'locked', need: r.need, kind: fc.header(buf).kind };
    body = r.plain;
    enc = { token: keep(r.key), kind: r.key.kind, label: kindLabel(r.key.kind) };
  }
  const d = codec.decode(body, opts.encoding || undefined);
  return { status: 'ok', text: d.text, encoding: d.encoding, lineEnding: d.lineEnding, enc };
}

async function readDocument(file, opts = {}) {
  const r = await decodeDocument(fs.readFileSync(file), Object.assign({ name: file }, opts));
  if (r.status !== 'ok') return r;
  addRecent(file);
  return Object.assign(r, { path: file, mtime: fs.statSync(file).mtimeMs });
}

/// 文章 → ファイルに書く中身 (文字コードを変換し、鍵があれば暗号化する)
function encodeDocument(o) {
  let body = codec.encode(o.text, o.encoding, o.lineEnding);
  if (o.encToken) {
    const key = keys.get(o.encToken);
    if (!key) throw new Error(t('暗号化の鍵が見つかりません。もう一度「暗号化して保存…」を選んでください。'));
    body = fc.seal(body, key);
  }
  return body;
}

function writeDocument(o) {
  const body = encodeDocument(o);
  if (o.backup && fs.existsSync(o.path)) {
    try { fs.copyFileSync(o.path, o.path + '.bak'); } catch (e) { /* バックアップが作れなくても保存はする */ }
  }
  writeFileAtomic(o.path, body);
  addRecent(o.path);
  return { status: 'ok', mtime: fs.statSync(o.path).mtimeMs };
}

function existingFiles(args) {
  const out = [];
  for (const a of args) {
    if (!a || a.startsWith('-')) continue;
    try {
      const full = path.resolve(a);
      if (fs.statSync(full).isFile()) out.push(full);
    } catch (e) { /* ファイルでないものは無視 */ }
  }
  return out;
}

/// エクスプローラーの右クリック「エディタβで grep」から渡されるフォルダ (--grep=フォルダ)
function grepArg(argv) {
  const a = argv.find(x => x.startsWith('--grep='));
  if (!a) return '';
  const dir = a.slice(7).replace(/"/g, '');
  try { return fs.statSync(dir).isDirectory() ? dir : ''; } catch (e) { return ''; }
}

function argvFiles(argv) {
  // 配布版は [exe, ファイル…]、開発中は [electron, アプリの場所, ファイル…]
  return existingFiles(argv.slice(app.isPackaged ? 1 : 2));
}

// ---------- 印刷・PDF ----------

async function withPrintWindow(html, fn) {
  const tmp = path.join(app.getPath('temp'), `satoru-print-${process.pid}-${Date.now()}.html`);
  fs.writeFileSync(tmp, html, 'utf8');
  const w = new BrowserWindow({ show: false, webPreferences: { sandbox: true, javascript: false } });
  try {
    await w.loadFile(tmp);
    return await fn(w);
  } finally {
    if (!w.isDestroyed()) w.destroy();
    try { fs.unlinkSync(tmp); } catch (e) { /* 残っても害はない */ }
  }
}

/// margins は インチ ({ top, bottom, left, right })。省くと余白なし (原稿用紙は用紙いっぱいに枠を描く)
function pdfData(html, landscape, margins) {
  return withPrintWindow(html, w => w.webContents.printToPDF({
    landscape: !!landscape, pageSize: 'A4', printBackground: true, preferCSSPageSize: true,
    margins: margins || { top: 0, bottom: 0, left: 0, right: 0 },
  }));
}

/// HTML を見えないウインドウで開いて、ページ全体 (見えていない下のほうも) を 1 枚の PNG にする
const MAX_IMAGE_HEIGHT = 16000;
async function captureWholePage(html, width) {
  const tmp = path.join(app.getPath('temp'), `satoruEditor-shot-${process.pid}-${Date.now()}.html`);
  fs.writeFileSync(tmp, html, 'utf8');
  // 画面に出さずに描く (offscreen)。普通の「見えないウインドウ」は描画されないので撮れない
  const w = new BrowserWindow({ show: false, width: Math.max(200, Math.min(4000, Math.round(width) || 1000)), height: 600, useContentSize: true,
    webPreferences: { sandbox: true, javascript: false, offscreen: true } });
  try {
    await w.loadFile(tmp);
    const dbg = w.webContents.debugger;
    dbg.attach('1.3');
    const metrics = await dbg.sendCommand('Page.getLayoutMetrics');
    const content = Object.assign({}, metrics.cssContentSize || metrics.contentSize);
    try {
      // 短い文書は、ウインドウの高さではなく本文の高さに合わせる
      const doc = await dbg.sendCommand('DOM.getDocument', { depth: 1 });
      const body = await dbg.sendCommand('DOM.querySelector', { nodeId: doc.root.nodeId, selector: 'body' });
      const box = await dbg.sendCommand('DOM.getBoxModel', { nodeId: body.nodeId });
      if (box && box.model && box.model.height > 0) content.height = box.model.height;
    } catch (e) { /* 取れなければページ全体の高さを使う */ }
    dbg.detach();
    const height = Math.max(1, Math.min(MAX_IMAGE_HEIGHT, Math.ceil(content.height)));
    w.setContentSize(Math.max(1, Math.ceil(content.width)), height);
    await new Promise(r => setTimeout(r, 300)); // 大きさを変えたあとの描き直しを待つ
    const image = await withTimeout(w.webContents.capturePage(), 20000);
    return { png: image.toPNG(), clipped: content.height > MAX_IMAGE_HEIGHT };
  } finally {
    if (!w.isDestroyed()) w.destroy();
    try { fs.unlinkSync(tmp); } catch (e) { /* 残っても害はない */ }
  }
}

/// 終わらない処理で固まらないようにする
function withTimeout(promise, ms) {
  return Promise.race([promise, new Promise((resolve, reject) => setTimeout(() => reject(new Error(t('画像にするのに時間がかかりすぎました。ウインドウを表示した状態で、もう一度試してください。'))), ms))]);
}

function xmlEscape(s) {
  return s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]))
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, '');
}

/// 段落の並び [{ text, align, indent }] → .docx の中身
function docxData(paragraphs, opts = {}) {
  const font = opts.font || 'ＭＳ 明朝';
  const body = paragraphs.map(p => {
    const jc = p.align === 'center' ? '<w:jc w:val="center"/>' : p.align === 'right' ? '<w:jc w:val="right"/>' : '';
    const ind = p.indent ? '<w:ind w:firstLineChars="100" w:firstLine="210"/>' : '';
    const runs = p.text.split('\t').map(t => `<w:r><w:t xml:space="preserve">${xmlEscape(t)}</w:t></w:r>`).join('<w:r><w:tab/></w:r>');
    return `<w:p><w:pPr>${jc}${ind}</w:pPr>${runs}</w:p>`;
  }).join('');
  const document = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' + body
    + '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1701" w:right="1701" w:bottom="1701" w:left="1701" w:header="851" w:footer="992" w:gutter="0"/></w:sectPr>'
    + '</w:body></w:document>';
  const styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    + '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr>'
    + `<w:rFonts w:ascii="${xmlEscape(font)}" w:hAnsi="${xmlEscape(font)}" w:eastAsia="${xmlEscape(font)}"/><w:sz w:val="21"/><w:szCs w:val="21"/><w:lang w:val="en-US" w:eastAsia="ja-JP"/>`
    + '</w:rPr></w:rPrDefault></w:docDefaults></w:styles>';
  return zip.make([
    { name: '[Content_Types].xml', data: '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>' },
    { name: '_rels/.rels', data: '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>' },
    { name: 'word/_rels/document.xml.rels', data: '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>' },
    { name: 'word/document.xml', data: document },
    { name: 'word/styles.xml', data: styles },
  ]);
}

// ---------- 画面側からの呼び出し ----------

/// 公式サイト
const OFFICIAL_URL = 'https://editor.satoru.net';
const iconCacheMain = new Map();
const llmJobs = {};
const pluginStaging = new Map();
// 拡張機能の呼び出し: 合言葉 (Worker ごと) → 拡張機能の id。画面側が Worker を作るときに登録する
const pluginTokens = new Map();
const pluginPending = new Map();
let pluginSeq = 0;

/// satoplug://call/ (同期の命令) と satoplug://fetch/ (ネット) を受ける
async function pluginProtocol(request) {
  const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'Content-Type', 'Content-Type': 'application/json' };
  if (request.method === 'OPTIONS') return new Response('', { status: 204, headers: cors });
  let msg;
  try { msg = JSON.parse(await request.text()); } catch (_) { return new Response('{"error":"bad request"}', { status: 400, headers: cors }); }
  const id = pluginTokens.get(String(msg.token || ''));
  if (!id) return new Response('{"error":"unknown plugin"}', { status: 403, headers: cors });
  const reply = value => new Response(JSON.stringify(value === undefined ? { value: null } : value), { status: 200, headers: cors });
  try {
    if (new URL(request.url).host === 'fetch') return reply({ value: await plugins.fetchFor(CONFIG_DIR, id, msg.url, msg.opts) });
    if (!win || win.isDestroyed()) return reply({ error: 'no window' });
    // 画面側で、いまの文書に対して行ってもらう (答えが来るまで Worker は待っている)
    const reqId = ++pluginSeq;
    const value = await new Promise((resolve, reject) => {
      pluginPending.set(reqId, { resolve, reject });
      send('plugin:call', reqId, id, String(msg.op || ''), msg.args || []);
    });
    return reply({ value });
  } catch (e) {
    return reply({ error: String(e.message || e) });
  }
}

const handlers = {
  async init() {
    rendererReady = true;
    const { theme, problems } = loadTheme();
    applyNativeTheme(theme);
    const files = pendingFiles;
    pendingFiles = [];
    const grepRoot = pendingGrep;
    pendingGrep = '';
    return {
      prefs, theme, themeProblems: problems, userProfiles: loadUserProfiles(),
      platform: process.platform, version: app.getVersion(), files, grepRoot,
      secretsAvailable: secretsAvailable(), configDir: CONFIG_DIR,
      aiPriceOverrides: aiusage.loadOverrides(FILES.aiPrices), homeDir: os.homedir(), userName: os.userInfo().username, hostName: os.hostname(), language: i18n.language(),
    };
  },

  // 設定
  setPref(key, value) {
    if (!(key in PREF_DEFAULTS)) return false;
    prefs[key] = value;
    savePrefsSoon();
    if (key === 'language') applyLanguage();
    if (key === 'iconColor' && win) win.setIcon(nativeImage.createFromPath(iconPath(value)));
    rebuildMenu();
    return true;
  },
  saveTheme(theme) {
    writeFileAtomic(FILES.theme, themeDef.toFileContents(theme));
    applyNativeTheme(theme);
    return true;
  },
  saveUserProfiles(list) {
    writeFileAtomic(FILES.profiles, JSON.stringify(list, null, 2));
    return true;
  },
  setMenuState(state) {
    menuState = state || {};
    rebuildMenu();
    return true;
  },
  async exportSettings() {
    const r = await dialog.showSaveDialog(win, { title: t('設定内容の保存'), defaultPath: 'satoru-editor-settings.json', filters: [{ name: t('設定ファイル'), extensions: ['json'] }] });
    if (r.canceled || !r.filePath) return false;
    const { theme } = loadTheme();
    const kept = Object.assign({}, prefs, { recent: [], carets: {}, windowBounds: null });
    writeFileAtomic(r.filePath, JSON.stringify({ app: 'satoru-editor', version: 1, prefs: kept, theme: JSON.parse(themeDef.toFileContents(theme)), profiles: loadUserProfiles() }, null, 2));
    return true;
  },
  async importSettings() {
    const r = await dialog.showOpenDialog(win, { title: t('設定内容の復元'), properties: ['openFile'], filters: [{ name: t('設定ファイル'), extensions: ['json'] }] });
    if (r.canceled || !r.filePaths[0]) return { status: 'cancel' };
    const o = readJSON(r.filePaths[0], null);
    if (!o || o.app !== 'satoru-editor') return { status: 'error', message: t('エディタβの設定ファイルではありません。') };
    for (const k of Object.keys(PREF_DEFAULTS)) {
      if (o.prefs && k in o.prefs && !['recent', 'carets', 'windowBounds'].includes(k)) prefs[k] = o.prefs[k];
    }
    applyLanguage();
    savePrefsNow();
    if (o.theme) writeFileAtomic(FILES.theme, themeDef.toFileContents(themeDef.fromJSON(o.theme).theme));
    if (Array.isArray(o.profiles)) writeFileAtomic(FILES.profiles, JSON.stringify(o.profiles, null, 2));
    rebuildMenu();
    return { status: 'ok' };
  },

  // ファイル
  async openDialog(o = {}) {
    const r = await dialog.showOpenDialog(win, {
      title: o.title || t('開く'), defaultPath: o.defaultPath || undefined,
      properties: o.directory ? ['openDirectory'] : (o.single ? ['openFile'] : ['openFile', 'multiSelections']),
      filters: o.filters || [{ name: t('すべてのファイル'), extensions: ['*'] }],
    });
    return r.canceled ? [] : r.filePaths;
  },
  async saveDialog(o = {}) {
    const r = await dialog.showSaveDialog(win, {
      title: o.title || t('名前を付けて保存'), defaultPath: o.defaultPath || undefined,
      filters: o.filters || [{ name: t('テキスト'), extensions: ['txt'] }, { name: t('すべてのファイル'), extensions: ['*'] }],
    });
    return r.canceled ? null : r.filePath;
  },
  async readFile(file, opts) {
    try { return await readDocument(file, opts || {}); } catch (e) { return fail(e); }
  },
  async writeFile(o) {
    try { return writeDocument(o); } catch (e) { return fail(e); }
  },
  fileInfo(file) {
    try {
      const s = fs.statSync(file);
      return { exists: true, mtime: s.mtimeMs, size: s.size };
    } catch (e) {
      return { exists: false };
    }
  },
  clearRecent() {
    prefs.recent = [];
    savePrefsSoon();
    try { app.clearRecentDocuments(); } catch (e) { /* なくてもよい */ }
    rebuildMenu();
    return true;
  },

  // 暗号化
  totpBegin(account) {
    const secret = totp.newSecret();
    const id = crypto.randomBytes(8).toString('hex');
    enrollments.set(id, secret);
    return { enrollId: id, base32: totp.base32(secret), uri: totp.uri(secret, account || 'document', appName()) };
  },
  async makeKey(o) {
    try {
      const key = await makeKey(o || {});
      prefs.encDefaultKind = key.kind;
      savePrefsSoon();
      return { status: 'ok', enc: { token: keep(key), kind: key.kind, label: kindLabel(key.kind) } };
    } catch (e) {
      return fail(e);
    }
  },
  async newKeyFile() {
    const r = await dialog.showSaveDialog(win, {
      title: t('鍵ファイルを作る (USB メモリなどに置く)'), defaultPath: 'satoru-editor-key.' + fc.KEYFILE_EXTENSION,
      filters: [{ name: t('鍵ファイル'), extensions: [fc.KEYFILE_EXTENSION] }],
    });
    if (r.canceled || !r.filePath) return null;
    fs.writeFileSync(r.filePath, fc.newKeyFileContents(), { flag: 'wx' }); // すでにある鍵ファイルは上書きしない
    return r.filePath;
  },

  // フォルダツリー
  listDir(dir) {
    try {
      return fs.readdirSync(dir, { withFileTypes: true })
        .filter(e => !e.name.startsWith('.') && (e.isDirectory() || e.isFile()))
        .map(e => ({ name: e.name, dir: e.isDirectory() }))
        .sort((a, b) => (a.dir !== b.dir ? (a.dir ? -1 : 1) : a.name.localeCompare(b.name, 'ja')));
    } catch (e) {
      return [];
    }
  },
  findFiles(root, query) {
    const q = String(query || '').toLowerCase();
    const out = [];
    let truncated = false;
    for (const f of grep.files(root, true)) {
      if (!path.basename(f).toLowerCase().includes(q)) continue;
      if (out.length >= 500) { truncated = true; break; }
      out.push(f);
    }
    return { files: out, truncated };
  },
  createEntry(dir, name, isDir) {
    try {
      if (!name || /[\\/:*?"<>|]/.test(name)) throw new Error(t('使えない文字が入っています。'));
      const full = path.join(dir, name);
      if (fs.existsSync(full)) throw new Error(t('同じ名前のものがあります。'));
      if (isDir) fs.mkdirSync(full); else fs.writeFileSync(full, '', { flag: 'wx' });
      return { status: 'ok', path: full };
    } catch (e) {
      return fail(e);
    }
  },
  renameEntry(file, name) {
    try {
      if (!name || /[\\/:*?"<>|]/.test(name)) throw new Error(t('使えない文字が入っています。'));
      const to = path.join(path.dirname(file), name);
      if (fs.existsSync(to)) throw new Error(t('同じ名前のものがあります。'));
      fs.renameSync(file, to);
      return { status: 'ok', path: to };
    } catch (e) {
      return fail(e);
    }
  },
  async trashEntry(file) {
    try {
      await shell.trashItem(file);
      return { status: 'ok' };
    } catch (e) {
      return fail(e);
    }
  },
  reveal(file) { shell.showItemInFolder(file); return true; },
  openPath(file) { return shell.openPath(file); },
  openExternal(url) {
    if (/^(https?|mailto):/i.test(url)) shell.openExternal(url);
    return true;
  },
  copyText(text) { clipboard.writeText(String(text)); return true; },
  pathInfo(file) {
    return { dir: path.dirname(file), base: path.basename(file), sep: path.sep, home: os.homedir() };
  },

  // 自動ふりがな
  async furigana(text) {
    try { return await furigana.ruby(String(text).slice(0, 200000)); } catch (e) { return []; }
  },

  // grep
  grepStart(id, root, options) {
    const job = { cancelled: false };
    grepJobs.set(id, job);
    let batch = [];
    const flush = () => { if (batch.length) { send('grep:matches', id, batch); batch = []; } };
    grep.search(root, options, m => { batch.push(m); if (batch.length >= 200) flush(); }, () => job.cancelled)
      .then(r => { flush(); send('grep:done', id, Object.assign({ cancelled: job.cancelled }, r)); })
      .catch(e => { flush(); send('grep:done', id, { error: e.message }); })
      .finally(() => grepJobs.delete(id));
    return true;
  },
  grepCancel(id) {
    const job = grepJobs.get(id);
    if (job) job.cancelled = true;
    return true;
  },

  // AI
  aiStatus() {
    const out = {};
    for (const p of ai.PROVIDERS) out[p.id] = { hasKey: !!getSecret('ai.' + p.id) };
    return out;
  },
  aiSetKey(provider, key) {
    try {
      setSecret('ai.' + provider, String(key || '').trim());
      return { status: 'ok' };
    } catch (e) {
      return fail(e);
    }
  },
  async aiListModels(provider) {
    try {
      return { status: 'ok', models: await ai.listModels(provider, getSecret('ai.' + provider) || '', aiBase(provider)) };
    } catch (e) {
      return fail(e);
    }
  },
  aiSend(id, o) {
    const controller = new AbortController();
    aiJobs.set(id, controller);
    const provider = o.provider || prefs.aiProvider;
    ai.send({
      provider, model: o.model || (prefs.aiModels || {})[provider] || ai.provider(provider).defaultModel,
      apiKey: getSecret('ai.' + provider) || '', baseURL: aiBase(provider),
      system: o.system, prompt: o.prompt, signal: controller.signal,
      onDelta: t => send('ai:delta', id, t),
    }).then(usage => {
      if (!o.noLog) { try { aiusage.add(FILES.usage, usage, provider, o.model || (prefs.aiModels || {})[provider] || '', prefs.aiPrices); } catch (e) { /* 記録できなくても答えは返す */ } }
      send('ai:done', id, { usage });
    })
      .catch(e => send('ai:done', id, { error: controller.signal.aborted ? '' : (e.message || String(e)), cancelled: controller.signal.aborted }))
      .finally(() => aiJobs.delete(id));
    return true;
  },
  aiCancel(id) {
    const c = aiJobs.get(id);
    if (c) c.abort();
    return true;
  },

  aiUsage() {
    return { summary: aiusage.summarize(aiusage.read(FILES.usage)), prices: prefs.aiPrices || {}, yen: prefs.aiYenPerDollar || 150, pages: aiusage.PRICING_PAGES,
      current: aiusage.price(prefs.aiProvider, (prefs.aiModels || {})[prefs.aiProvider] || ai.provider(prefs.aiProvider).defaultModel, prefs.aiPrices) };
  },
  aiUsageClear() { aiusage.clear(FILES.usage); return true; },

  // PDF からテキストを読み込む
  async importPDF(file) {
    try {
      const r = await require('./core/pdfimport').importPDF(file);
      return { status: 'ok', text: r.text, pages: r.pages };
    } catch (e) {
      return fail(e);
    }
  },

  // サーバ (SFTP / FTP / FTPS)
  serverSave(server, password) {
    try {
      const s = {
        id: server.id || crypto.randomBytes(8).toString('hex'), name: String(server.name || '').trim(),
        kind: remote.kindInfo(server.kind).id, host: String(server.host || '').trim(), port: parseInt(server.port, 10) || remote.kindInfo(server.kind).port,
        user: String(server.user || '').trim(), auth: server.auth === 'key' ? 'key' : 'password', keyFile: String(server.keyFile || ''), root: String(server.root || '').trim(),
      };
      if (!s.host) throw new Error(t('サーバのアドレスを入れてください。'));
      if (typeof password === 'string') setSecret('server.' + s.id, password); // undefined なら前のまま
      prefs.servers = (prefs.servers || []).filter(x => x.id !== s.id).concat([s]);
      savePrefsSoon();
      dropConnection(s.id);
      return { status: 'ok', server: s };
    } catch (e) {
      return fail(e);
    }
  },
  serverDelete(id) {
    prefs.servers = (prefs.servers || []).filter(x => x.id !== id);
    savePrefsSoon();
    try { setSecret('server.' + id, null); } catch (e) { /* 残っても使われない */ }
    dropConnection(id);
    return true;
  },
  serverForgetKey(id) {
    const s = (prefs.servers || []).find(x => x.id === id);
    if (s) remote.forgetHostKey(FILES.knownHosts, s);
    dropConnection(id);
    return true;
  },
  serverHasPassword(id) { return !!getSecret('server.' + id); },
  async remoteCall(id, action, ...args) {
    try {
      const c = connection(id);
      switch (action) {
        case 'home': return { status: 'ok', value: await c.home() };
        case 'list': return { status: 'ok', value: await c.list(args[0]) };
        case 'mkdir': await c.mkdir(args[0]); return { status: 'ok' };
        case 'remove': await c.remove(args[0], !!args[1]); return { status: 'ok' };
        case 'rename': await c.rename(args[0], args[1]); return { status: 'ok' };
        case 'create': await c.write(args[0], Buffer.alloc(0)); return { status: 'ok' };
        default: throw new Error('unknown action');
      }
    } catch (e) {
      dropConnection(id); // 切れた接続を使い回さない
      return fail(e);
    }
  },
  async remoteRead(id, file, opts) {
    try {
      const s = (prefs.servers || []).find(x => x.id === id);
      const buf = await connection(id).read(file);
      const r = await decodeDocument(buf, Object.assign({ name: file }, opts || {}));
      if (r.status === 'viewer') return Object.assign(r, { remote: { id, path: file, url: remote.url(s, file) } });
      if (r.status !== 'ok') return r;
      return Object.assign(r, { size: buf.length, remote: { id, path: file, url: remote.url(s, file) } });
    } catch (e) {
      dropConnection(id);
      return fail(e);
    }
  },
  async remoteWrite(id, file, o) {
    try {
      const body = encodeDocument(o);
      await connection(id).write(file, body);
      return { status: 'ok', size: body.length };
    } catch (e) {
      dropConnection(id);
      return fail(e);
    }
  },

  // 共同編集: 通信だけをここで行い、メッセージは画面側に渡す
  async collabHost(port) {
    collabStop();
    const code = newCollabCode();
    try {
      collabLink = await collabnet.host(parseInt(port, 10) || collabnet.DEFAULT_PORT, code, collabEvents());
    } catch (e) {
      return { status: 'error', message: e.code === 'EADDRINUSE' ? t('ポート {port} はほかで使われています。別の番号にしてください。', { port }) : e.message };
    }
    return { status: 'ok', code, port: collabLink.port, addresses: collabnet.localAddresses(), hostName: os.hostname() };
  },
  collabJoin(address, port, code) {
    collabStop();
    collabLink = collabnet.join(String(address).trim(), parseInt(port, 10) || collabnet.DEFAULT_PORT, code, collabEvents());
    return { status: 'ok' };
  },
  collabSend(id, msg) { if (collabLink) collabLink.send(id, msg); return true; },
  collabClose(id) { if (collabLink) collabLink.close(id); return true; },
  collabStop() { collabStop(); return true; },
  attention() { if (win && !win.isFocused()) win.flashFrame(true); return true; },

  // 関連付け・右クリックメニュー (Windows)
  assocStatus() { return winassoc.status(); },
  async assocApply(o) {
    const r = await winassoc.apply({ exe: process.execPath, extensions: o.extensions, fileMenu: !!o.fileMenu, folderMenu: !!o.folderMenu,
      labels: { open: t('エディタβで開く'), grep: t('エディタβで grep') } });
    return r.ok ? { status: 'ok' } : { status: 'error', message: r.message };
  },

  // 印刷・書き出し
  async exportPDF(o) {
    try {
      writeFileAtomic(o.path, await pdfData(o.html, o.landscape, o.margins));
      return { status: 'ok' };
    } catch (e) {
      return fail(e);
    }
  },
  async print(o) {
    try {
      await withPrintWindow(o.html, w => new Promise((resolve, reject) => {
        w.webContents.print({ landscape: !!o.landscape, printBackground: true, margins: { marginType: o.margins ? 'default' : 'none' }, pageSize: 'A4' },
          (ok, reason) => (ok || reason === 'cancelled' || !reason ? resolve() : reject(new Error(reason))));
      }));
      return { status: 'ok' };
    } catch (e) {
      return fail(e);
    }
  },
  /// スクリーンショット: 表示中の範囲 (rect) か、文書全体 (html) を PNG にして、コピーするか保存する
  async screenshot(o) {
    try {
      let png, clipped = false;
      if (o.mode === 'visible') {
        png = (await withTimeout(win.webContents.capturePage(o.rect), 8000)).toPNG();
      } else {
        const r = await captureWholePage(o.html, o.width);
        png = r.png;
        clipped = r.clipped;
      }
      const image = nativeImage.createFromBuffer(png);
      const size = image.getSize();
      if (o.action === 'copy') clipboard.writeImage(image);
      else writeFileAtomic(o.path, png);
      return { status: 'ok', width: size.width, height: size.height, clipped };
    } catch (e) {
      return fail(e);
    }
  },
  exportDocx(o) {
    try {
      writeFileAtomic(o.path, docxData(o.paragraphs, o));
      return { status: 'ok' };
    } catch (e) {
      return fail(e);
    }
  },

  // 切り取り・コピー・貼り付け (ツールバーから)
  editCommand(name) {
    if (!win) return false;
    if (name === 'cut') win.webContents.cut();
    else if (name === 'copy') win.webContents.copy();
    else if (name === 'paste') win.webContents.paste();
    return true;
  },

  // ウインドウ
  setTitle(title) { if (win) win.setTitle(title); return true; },
  closeWindow() { allowClose = true; if (win) win.close(); return true; },
  quit() { if (win) win.close(); return true; },
  async about() {
    const r = await dialog.showMessageBox(win, {
      type: 'info', title: t('エディタβについて'), message: `${appName()} ${app.getVersion()}`,
      detail: t('Windows 用の軽いテキストエディタです。\n\nMIT License')
        + '\n\n' + t('公式サイト') + ': ' + OFFICIAL_URL,
      buttons: ['OK', t('公式サイトを開く')], defaultId: 0, cancelId: 0,
    });
    if (r.response === 1) shell.openExternal(OFFICIAL_URL);
    return true;
  },

  // ---------- JS 拡張機能 ----------
  pluginList() { return plugins.list(CONFIG_DIR).map(p => ({ manifest: p.manifest, folder: p.folder, source: p.source, icon: p.icon, error: p.error })); },
  pluginsFolder() { const d = plugins.pluginsDir(CONFIG_DIR); fs.mkdirSync(d, { recursive: true }); return d; },
  /// 入れる準備 (取ってきて確かめる)。確認の画面のあとで pluginCommit
  async pluginPrepare(from) {
    try {
      const prepared = await plugins.prepare(from || {});
      const token = 'p' + Date.now() + Math.random().toString(36).slice(2, 8);
      pluginStaging.set(token, prepared);
      const existing = plugins.list(CONFIG_DIR).find(p => p.manifest.id === prepared.manifest.id);
      return { ok: true, token, manifest: prepared.manifest, source: prepared.source, existing: existing ? existing.manifest : null };
    } catch (e) { return { ok: false, error: String(e.message || e) }; }
  },
  async pluginCommit(token) {
    const prepared = pluginStaging.get(token);
    pluginStaging.delete(token);
    if (!prepared) return { ok: false, error: 'expired' };
    try {
      await plugins.commit(CONFIG_DIR, prepared, p => shell.trashItem(p));
      return { ok: true, id: prepared.manifest.id, source: prepared.source }; // 入れた元・使う/止めるは画面側で覚える
    } catch (e) { return { ok: false, error: String(e.message || e) }; }
  },
  pluginDiscard(token) { pluginStaging.delete(token); return true; },
  async pluginUninstall(id) {
    const p = plugins.list(CONFIG_DIR).find(x => x.manifest.id === id);
    if (!p) return false;
    await shell.trashItem(p.folder);
    return true;
  },
  pluginTemplate(id) {
    try { return { ok: true, path: plugins.createTemplate(CONFIG_DIR, String(id || '')) }; } catch (e) { return { ok: false, error: String(e.message || e) }; }
  },
  pluginDocs() { return plugins.writeDocs(CONFIG_DIR); },
  pluginFetch(id, url, opts) { return plugins.fetchFor(CONFIG_DIR, String(id), url, opts); },
  /// Worker を作ったとき: その合言葉を、どの拡張機能のものか覚える (止めたら消す)
  pluginToken(token, id) { if (id) pluginTokens.set(String(token), String(id)); else pluginTokens.delete(String(token)); return true; },
  /// 画面側からの答え (plugin:call への)
  pluginReply(reqId, ok, value) {
    const p = pluginPending.get(reqId);
    if (!p) return false;
    pluginPending.delete(reqId);
    if (ok) p.resolve(value); else p.reject(new Error(String(value)));
    return true;
  },
  readClipboard() { return clipboard.readText(); },

  // ---------- ローカル LLM (Ollama) ----------
  llmStatus() { return localllm.status(); },
  llmRequiredBuild() { return localllm.requiredBuild(); },
  async llmInstall() {
    llmJobs.install = {};
    try {
      await localllm.install((got, total) => send('llm:install', { got, total }), llmJobs.install);
      return { ok: true };
    } catch (e) { return { ok: false, error: String(e.message || e) }; } finally { delete llmJobs.install; }
  },
  llmCancelInstall() { if (llmJobs.install && llmJobs.install.cancel) llmJobs.install.cancel(); return true; },
  llmStart() { return localllm.start(); },
  async llmPull(name) {
    llmJobs.pull = {};
    try {
      await localllm.pull(String(name), p => send('llm:pull', name, p), llmJobs.pull);
      return { ok: true };
    } catch (e) { return { ok: false, error: String(e.message || e) }; } finally { delete llmJobs.pull; }
  },
  llmCancelPull() { if (llmJobs.pull && llmJobs.pull.cancel) llmJobs.pull.cancel(); return true; },
  async llmDelete(name) { try { return await localllm.remove(String(name)); } catch (_) { return false; } },

  /// 横の欄を出したとき、本文が狭くなりすぎないようにウインドウを広げる (画面からははみ出さない)
  growWindow(dx) {
    if (!win || win.isMaximized() || win.isFullScreen()) return false;
    const add = Math.max(0, Math.min(2000, Math.round(Number(dx) || 0)));
    if (!add) return false;
    const { screen } = require('electron');
    const b = win.getBounds();
    const area = screen.getDisplayMatching(b).workArea;
    const width = Math.min(b.width + add, area.width);
    let x = b.x;
    if (x + width > area.x + area.width) x = Math.max(area.x, area.x + area.width - width); // 右にはみ出すなら左へ
    win.setBounds({ x, y: b.y, width, height: b.height }, true);
    return true;
  },

  /// ファイルの種類 (拡張子) のアイコン。Windows が持っている絵を data: の URL で返す
  async fileIcon(ext) {
    const e = String(ext || 'txt').toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 10) || 'txt';
    if (iconCacheMain.has(e)) return iconCacheMain.get(e);
    let url = '';
    try {
      // 拡張子だけでは聞けないので、空のファイルを一時フォルダに作って聞く
      const dir = path.join(app.getPath('temp'), 'satoruEditor-icons');
      fs.mkdirSync(dir, { recursive: true });
      const probe = path.join(dir, 'probe.' + e);
      if (!fs.existsSync(probe)) fs.writeFileSync(probe, '');
      const img = await app.getFileIcon(probe, { size: 'small' });
      url = img.isEmpty() ? '' : img.toDataURL();
    } catch (_) { url = ''; }
    iconCacheMain.set(e, url);
    return url;
  },
};

// サーバとの接続は、しばらく使い回す (2 分使わなければ切る)
const connections = new Map();
function connection(id) {
  const s = (prefs.servers || []).find(x => x.id === id);
  if (!s) throw new Error(t('サーバの設定が見つかりません。'));
  let entry = connections.get(id);
  if (!entry) {
    entry = { client: remote.connect(s, getSecret('server.' + id) || '', FILES.knownHosts), timer: null };
    connections.set(id, entry);
  }
  clearTimeout(entry.timer);
  entry.timer = setTimeout(() => dropConnection(id), 120000);
  return entry.client;
}
function dropConnection(id) {
  const entry = connections.get(id);
  if (!entry) return;
  clearTimeout(entry.timer);
  try { entry.client.close(); } catch (e) { /* もう切れている */ }
  connections.delete(id);
}

let collabLink = null;
function collabEvents() {
  return {
    onOpen: (id, address) => send('collab:open', id, address),
    onMessage: (id, msg) => send('collab:message', id, msg),
    onClose: (id, info) => send('collab:close', id, info),
  };
}
function collabStop() {
  if (collabLink) { try { collabLink.stop(); } catch (e) { /* もう閉じている */ } }
  collabLink = null;
}

const grepJobs = new Map();
const aiJobs = new Map();
function aiBase(provider) {
  return provider === 'custom' ? (prefs.aiCustomBaseURL || ai.provider('custom').baseURL) : ai.provider(provider).baseURL;
}

// ---------- 起動 ----------

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.setName(APP_ID);
  migrateUserData();
  migrateConfigDir();
  if (process.platform === 'win32') app.setAppUserModelId('net.satoru.editor');
  loadPrefs();
  pendingFiles = argvFiles(process.argv);
  pendingGrep = grepArg(process.argv);

  // すでに起動しているときに別のファイルを開いたら、いまのウインドウのタブで開く
  app.on('second-instance', (event, argv, cwd) => {
    const files = existingFiles(argv.slice(1).map(a => (a.startsWith('-') ? a : path.resolve(cwd || '.', a))));
    if (win) {
      if (win.isMinimized()) win.restore();
      win.focus();
      if (files.length) send('open-files', files);
      const root = grepArg(argv);
      if (root) send('open-grep', root);
    }
  });

  app.whenReady().then(() => {
    protocol.handle('satoplug', pluginProtocol);
    for (const [name, fn] of Object.entries(handlers)) {
      ipcMain.handle('api:' + name, (event, ...args) => {
        if (!win || event.sender !== win.webContents) throw new Error('not allowed from this window');
        return fn(...args);
      });
    }
    applyLanguage(); // OS の言語は、起動が済んでからでないと正しく取れない
    rebuildMenu();
    createWindow();
    // 自己点検: satoruEditor.exe --selftest=結果を書くフォルダ
    const flag = process.argv.find(x => x.startsWith('--selftest='));
    if (flag) {
      require('./core/selftest')(flag.slice('--selftest='.length), {
        app, Menu, getWindow: () => win, isReady: () => rendererReady, makeKey, keep, writeDocument, readDocument, docxData, secretsAvailable,
        configDir: CONFIG_DIR, screenshot: handlers.screenshot, clipboard,
        setLanguage: lang => { prefs.language = lang; applyLanguage(); rebuildMenu(); },
        quit: () => { allowClose = true; app.quit(); },
      });
    }
  });
  app.on('window-all-closed', () => app.quit());
}
