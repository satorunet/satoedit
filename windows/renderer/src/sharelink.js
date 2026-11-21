// リンクで公開 (Mac 版 ShareLink.swift と同じ): テキストを docs.satoru.net に送って、https://docs.satoru.net/r/<id> で読めるようにする。
// 公開のしかたは「公開 (一覧に載る)」「リンクを知っている人だけ」「パスワード」。期限も決められる。
// 公開したものの記録 (prefs.sharedLinks) は Mac 版と同じ形 (日時は 2001-01-01 からの秒) なので、バックアップを Mac と行き来できる
import { h, modal, alertBox, toast } from './dialogs';
import { genkoShareLayout } from './paper';
import { wholeDocument } from './screenshot';
import { pathUtil } from './util';
import i18n from '../../shared/i18n';
import themeDef from '../../shared/theme';
import privacy from '../../shared/privacyscan';
import { stamp } from './library';

const { t } = i18n;
export const BASE = 'https://docs.satoru.net';
const APPLE_EPOCH = 978307200; // 1970 → 2001-01-01 の秒
const fromApple = s => (typeof s === 'number' ? (s + APPLE_EPOCH) * 1000 : null);
const toApple = ms => ms / 1000 - APPLE_EPOCH;
const norm = p => String(p || '').replace(/\//g, '\\').replace(/\\+$/, '').toLowerCase();

/// SHA-256 (中身の印。Mac 版と同じ値になる)
function sha256(str) {
  const bytes = new TextEncoder().encode(str);
  const K = [0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2];
  const H = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  const len = bytes.length, total = Math.ceil((len + 9) / 64) * 64;
  const m = new Uint8Array(total);
  m.set(bytes);
  m[len] = 0x80;
  const bits = len * 8;
  const dv = new DataView(m.buffer);
  dv.setUint32(total - 8, Math.floor(bits / 0x100000000));
  dv.setUint32(total - 4, bits >>> 0);
  const w = new Uint32Array(64);
  const rotr = (x, n) => (x >>> n) | (x << (32 - n));
  for (let o = 0; o < total; o += 64) {
    for (let i = 0; i < 16; i++) w[i] = dv.getUint32(o + i * 4);
    for (let i = 16; i < 64; i++) {
      const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3), s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }
    let [a, b, c, d, e, f, g, hh] = H;
    for (let i = 0; i < 64; i++) {
      const t1 = (hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i]) >>> 0;
      const t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) >>> 0;
      hh = g; g = f; f = e; e = (d + t1) >>> 0; d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }
    H[0] = (H[0] + a) >>> 0; H[1] = (H[1] + b) >>> 0; H[2] = (H[2] + c) >>> 0; H[3] = (H[3] + d) >>> 0;
    H[4] = (H[4] + e) >>> 0; H[5] = (H[5] + f) >>> 0; H[6] = (H[6] + g) >>> 0; H[7] = (H[7] + hh) >>> 0;
  }
  return H.map(x => x.toString(16).padStart(8, '0')).join('');
}
export const contentHash = (text, mode) => sha256(mode + '\u0000' + text);

const DAY_CHOICES = [[1, '1 日'], [7, '7 日'], [30, '30 日'], [365, '1 年'], [0, '期限なし'], [-1, '日時を指定…']];
const KINDS = ['public', 'unlisted', 'password'];
const pad = n => String(n).padStart(2, '0');
const localInput = ms => { const d = new Date(ms); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`; };

export class ShareLink {
  constructor(app) { this.app = app; this.api = app.api; this.asked = new Set(); }

  get records() { return Array.isArray(this.app.prefs.sharedLinks) ? this.app.prefs.sharedLinks : []; }
  set records(list) { this.app.prefs.sharedLinks = list; this.api.setPref('sharedLinks', list); this.app.pushMenuState(); if (this.app.library) this.app.library.changed(); }

  /// 記録に、ミリ秒の日時を添えたもの
  view(r) { return Object.assign({}, r, { createdMs: fromApple(r.created), expiresMs: fromApple(r.expires) }); }
  alive(r) { const e = fromApple(r.expires); return !e || e > Date.now(); }

  /// そのファイルの公開中のリンク (いちばん新しいもの)
  recordFor(path) {
    if (!path) return null;
    const p = norm(path);
    const r = this.records.find(x => x.path && norm(x.path) === p && this.alive(x));
    return r ? this.view(r) : null;
  }

  replace(r) {
    const clean = Object.assign({}, r);
    delete clean.createdMs; delete clean.expiresMs;
    this.records = this.records.map(x => (x.id === clean.id ? clean : x));
  }

  /// ファイルの名前や場所が変わったとき、公開の記録もそちらに付け替える
  repath(oldPath, newPath, swap) {
    let changed = false;
    const list = this.records.map(r => {
      if (!r.path) return r;
      const q = swap(r.path);
      if (q === r.path) return r;
      changed = true;
      return Object.assign({}, r, { path: q });
    });
    if (changed) this.records = list;
  }

  visibilityName(v) { return v === 'public' ? t('公開') : v === 'password' ? t('パスワード') : t('リンクを知っている人だけ'); }

  /// 公開するときの表示: 標準エディタ = "editor"、A4 = "text"、原稿用紙 = "genko" / "genkoH"
  modeOf(fileMode) { return fileMode === 'genko' || fileMode === 'genkoH' ? fileMode : fileMode === 'a4' ? 'text' : 'editor'; }

  /// 公開してから書き換えたか (前の版で中身の印がなければ、書き換えたことにする)
  needsUpdate(r, text, mode) {
    if (!r.contentHash) { this.learnHash(r, text, mode); return true; }
    return r.contentHash !== contentHash(text, mode);
  }
  /// 中身の印を覚えていないもの: 公開中の本文を取ってきて、いまと同じなら印を覚える (1 件 1 回)
  async learnHash(r, text, mode) {
    if (r.visibility === 'password' || this.asked.has(r.id)) return;
    this.asked.add(r.id);
    try {
      const res = await this.api.http({ url: r.url + '.txt', timeout: 15000 });
      if (res.status !== 200 || res.body !== text) return;
      const cur = this.records.find(x => x.id === r.id);
      if (cur && !cur.contentHash) this.replace(Object.assign({}, cur, { contentHash: contentHash(text, mode) }));
    } catch (e) { /* 分からなければそのまま */ }
  }

  /// 公開する中身: 開いていれば画面の文章、なければファイル。{ text, title, mode }
  async contentOf(path) {
    const tab = this.app.tabs.find(x => x.path && norm(x.path) === norm(path));
    let text, fileMode;
    if (tab) {
      if (tab.paper) this.app.syncFromPaper(tab);
      text = tab.getText();
      fileMode = this.app.modeString(tab);
    } else {
      const r = await this.api.libraryReadText(path);
      if (r.status !== 'ok' || r.encrypted || typeof r.text !== 'string') return null;
      text = r.text;
      fileMode = r.mode || (this.app.library ? this.app.library.modeFallback(path) : null);
    }
    const first = text.split('\n').map(s => s.trim()).find(s => s) || '';
    return { text, title: (first || pathUtil.base(path).replace(/\.[^.]*$/, '')).slice(0, 60), mode: this.modeOf(fileMode), tab };
  }

  // ---------- 公開する ----------

  /// メニュー「リンクで公開…」: いま開いている文書 (選んでいればその部分) を公開する
  async publishCurrent() {
    const app = this.app, tab = app.active;
    if (!tab) return;
    if (tab.enc) { await alertBox(t('暗号化した文書は公開できません'), t('データ暗号化のためです。')); return; }
    if (tab.paper) app.syncFromPaper(tab);
    let text = tab.getText(), offset = 0, file = tab.path || null;
    if (tab.paperMode === 0) {
      const sel = tab.editor.selectionRange();
      if (sel.to > sel.from) { text = text.slice(sel.from, sel.to); offset = sel.from; file = null; } // 一部分だけを公開するときは、ファイルの印は付けない
    }
    const first = text.split('\n').map(s => s.trim()).find(s => s) || '';
    const title = (first || tab.name).slice(0, 60);
    await this.share({ text, title, mode: this.modeOf(app.modeString(tab)), file, tab, offset });
  }

  /// テキスト一覧の右クリック「リンクで公開…」(開いていなくても、ファイルの中身を読んで公開する)
  async publishFile(path) {
    const c = await this.contentOf(path);
    if (!c) { toast(t('公開できるテキストではありません')); return; }
    await this.share({ text: c.text, title: c.title, mode: c.mode, file: path, tab: c.tab, offset: 0 });
  }

  async share({ text, title, mode, file, tab, offset }) {
    if (!text.trim()) { toast(t('公開する文章がありません')); return; }
    if (!(await this.confirmPrivacy(text, { tab, file, offset }))) return;
    // もう公開中のファイル: 同じリンクのページを新しくするか、別のリンクで公開するか
    const rec = file ? this.recordFor(file) : null;
    if (rec) {
      const can = this.needsUpdate(rec, text, mode);
      const choice = await modal({
        title: t('このテキストは公開中です'),
        body: rec.url + '\n\n' + (can ? t('公開中のページを今の内容に更新できます (リンクはそのまま。前の内容は変更履歴に残ります)。') : t('公開してから変更していないので、更新するものはありません。')),
        width: 500,
        buttons: [{ label: t('公開中のページを更新（変更を反映）'), value: 'update', primary: true, validate: () => can }, { label: t('新しいリンクで公開…'), value: 'new' }, { label: t('キャンセル'), value: null, cancel: true }],
      });
      if (choice === 'update') await this.update(rec, text, mode, tab);
      if (choice !== 'new') return;
    }
    const form = await this.form({ title });
    if (!form) return;
    await this.upload(Object.assign({ text, mode, file, tab }, form));
  }

  // ---------- 個人情報の確認 ----------

  /// 電話番号・名前・住所・パスワードなどが入っていないかを手元で点検し (どこにも送らない)、疑わしければ「このまま公開してよいか」を聞く。
  /// 続けてよければ true。「やめて見直す」なら、見つけたところをエディタで選ぶ
  async confirmPrivacy(text, { tab, file, offset = 0 } = {}) {
    const app = this.app;
    if (app.prefs.sharePrivacyCheckOff) return true;
    const user = String((app.init && app.init.userName) || '').trim();
    const names = [user, user.replace(/ /g, ''), user.replace(/ /g, '　')].filter(n => Array.from(n).length >= 2 && /[　-鿿]/.test(n));
    const found = privacy.scan(text, names);
    if (!found.length) return true;
    const off = h('input', { type: 'checkbox' });
    const body = h('div', {},
      ...found.slice(0, 8).map(f => h('div', { class: 'modal-line' }, '・' + t(f.kind) + '  ' + f.sample)),
      h('div', { class: 'modal-line top-gap' }, t('公開すると、リンクを知った人が読めるようになります。このまま公開してよいですか？')),
      h('label', { class: 'check-row top-gap' }, off, t('次からこの確認を出さない')));
    const r = await modal({
      title: '⚠ ' + t('個人情報が入っているかもしれません'), body, width: 500,
      buttons: [{ label: t('やめて見直す'), value: 'review', primary: true, cancel: true }, { label: t('このまま公開する'), value: 'go' }],
    });
    if (r === 'go') {
      if (off.checked) app.setPref('sharePrivacyCheckOff', true);
      return true;
    }
    await this.review(found, { tab, file, offset });
    return false;
  }

  /// 見つけた個人情報らしきところを、エディタで選んだ状態にして見せる (開いていなければ開く)
  async review(found, { tab, file, offset = 0 }) {
    const app = this.app;
    if (!tab && file) tab = await app.openPath(file);
    if (!tab) return;
    app.activate(tab);
    const ranges = found.map(f => ({ from: f.from + offset, to: f.to + offset }));
    setTimeout(() => {
      if (tab.paper && tab.paper.select) { tab.paper.focus(); tab.paper.select(ranges[0].from, ranges[0].to); tab.paper.reveal(); return; }
      if (tab.paper) return;
      tab.editor.selectRanges(ranges);
    }, 50);
  }

  // ---------- 公開の画面 ----------

  /// 題名・公開のしかた・パスワード・期限・変更履歴。editing なら公開中のものの設定を変える画面。OK なら値、やめたら null
  async form({ title, editing }) {
    const prefs = this.app.prefs;
    const titleField = h('input', { type: 'text', class: 'wide', value: title || '', placeholder: t('題名') });
    let visibility = editing ? editing.visibility : (prefs.shareVisibility || 'unlisted');
    const labels = [t('公開 (だれでも読める・検索にも出る)'), t('リンクを知っている人だけ'), t('パスワードを知っている人だけ')];
    const password = h('input', { type: 'password', placeholder: editing && editing.visibility === 'password' ? t('変えないときは空のまま') : t('パスワード (4 文字以上)'), style: { width: '220px' } });
    const radios = KINDS.map((k, i) => {
      const r = h('input', { type: 'radio', name: 'share-vis', value: k, checked: k === visibility });
      r.addEventListener('change', () => { visibility = k; if (!editing) this.app.setPref('shareVisibility', k); refresh(); });
      return h('label', { class: 'check-row' }, r, labels[i]);
    });
    const days = h('select', {});
    if (editing) days.append(h('option', { value: 'keep' }, editing.expiresMs ? t('変えない ({when} まで)', { when: stamp(editing.expiresMs) }) : t('変えない (期限なし)')));
    for (const [n, label] of DAY_CHOICES) days.append(h('option', { value: String(n) }, t(label)));
    days.value = editing ? 'keep' : String(DAY_CHOICES.some(c => c[0] === prefs.shareDays) ? prefs.shareDays : 30);
    const when = h('input', { type: 'datetime-local', value: localInput(editing && editing.expiresMs > Date.now() ? editing.expiresMs : Date.now() + 7 * 86400000), min: localInput(Date.now() + 5 * 60000) });
    const history = h('input', { type: 'checkbox', checked: editing ? editing.keepHistory !== false : prefs.shareKeepHistory !== false });
    const clear = h('input', { type: 'checkbox' });
    const clearRow = h('label', { class: 'check-row', hidden: !editing }, clear, t('今ある変更履歴を消す'));
    days.addEventListener('change', () => { if (!editing && Number(days.value) >= 0) this.app.setPref('shareDays', Number(days.value)); refresh(); });
    history.addEventListener('change', () => { if (!editing) this.app.setPref('shareKeepHistory', history.checked); if (history.checked) clear.checked = false; refresh(); });
    const refresh = () => {
      password.disabled = visibility !== 'password';
      when.disabled = days.value !== '-1';
      // 残さない設定にすると、今ある履歴も消える
      if (!history.checked) clear.checked = true;
      clear.disabled = !history.checked;
    };
    refresh();
    const body = h('div', { class: 'share-form' },
      editing ? h('div', { class: 'modal-line dim selectable' }, editing.url) : h('div', { class: 'modal-line dim' }, t('文章をインターネット上に公開して URL を発行します。')),
      h('div', { class: 'form-row' }, h('label', {}, t('題名')), titleField),
      ...radios,
      h('div', { class: 'form-row indent' }, password),
      h('div', { class: 'form-row' }, h('label', {}, t('公開の期限')), days, when),
      h('label', { class: 'check-row' }, history, t('変更履歴を残す (更新したとき、前の内容もページから見られる)')),
      clearRow,
      h('div', { class: 'dim small top-gap' }, t('公開をやめる・設定を変えるには、メニューの「公開」から。')));
    const ok = await modal({
      title: editing ? t('公開の設定') : t('リンクで公開共有'), body, width: 520,
      buttons: [{ label: editing ? t('変更する') : t('公開する'), value: true, primary: true, validate: async () => {
        const needPw = visibility === 'password' && (!editing || editing.visibility !== 'password' || password.value);
        if (needPw && Array.from(password.value).length < 4) { await alertBox(t('パスワードは 4 文字以上にしてください'), ''); return false; }
        if (days.value === '-1' && !(new Date(when.value).getTime() > Date.now())) { await alertBox(t('期限の日時を選んでください'), ''); return false; }
        return true;
      } }, { label: t('キャンセル'), value: false, cancel: true }],
    });
    if (!ok) return null;
    const keep = days.value === 'keep';
    const n = keep ? null : Number(days.value);
    return {
      title: titleField.value, visibility, password: password.value,
      days: n === null ? null : Math.max(0, n), expiresAt: n === -1 ? new Date(when.value).getTime() / 1000 : null, keepExpiry: keep,
      keepHistory: history.checked, clearHistory: !!editing && clear.checked,
    };
  }

  // ---------- 送る ----------

  /// 標準エディタで公開するときの見た目: いまのエディタの色と、改行の印を出すか
  editorTheme() {
    const c = themeDef.colors(this.app.theme);
    const hex = v => (themeDef.normalizeHex(v) || '#000000').slice(0, 7);
    const out = {};
    for (const [k, from] of [['background', 'background'], ['text', 'text'], ['gutterBackground', 'gutterBackground'], ['gutterText', 'gutterText'],
      ['gutterSeparator', 'gutterSeparator'], ['newlineMark', 'newlineMark'], ['eof', 'eof'], ['chrome', 'statusBackground'], ['chromeText', 'statusText'],
      ['currentLine', 'currentLine'], ['currentLineText', 'currentLineText'], ['gutterCurrentText', 'gutterCurrentText'], ['selection', 'selection'], ['caret', 'caret']]) out[k] = hex(c[from]);
    out.marks = !!this.app.prefs.invisibles;
    out.ruler = !!this.app.prefs.columnRuler;
    out.currentLineOn = !!this.app.prefs.highlightCurrentLine;
    return out;
  }

  /// 原稿用紙: アプリで並べたとおり (自動整形・ふりがな) をサーバに渡す
  async genkoLayout(text, horizontal, tab) {
    let ruby = [];
    if (this.app.prefs.genkoFurigana) {
      if (tab && tab.paper && tab.paper.ruby && tab.paper.rubyText === text) ruby = tab.paper.ruby;
      else { try { ruby = await this.api.furigana(text); } catch (e) { ruby = []; } }
    }
    return genkoShareLayout(text, this.app.prefs, ruby, horizontal);
  }

  /// 公開するファイルの画面の画像 (base64 の PNG)。開いているときだけ作る
  async image(tab, text) {
    if (!tab) return null;
    try {
      if (tab.paper) this.app.syncFromPaper(tab);
      if (tab.getText() !== text) return null; // 一部分だけを公開するとき
      const job = wholeDocument(this.app, tab);
      const r = await this.api.screenshot({ mode: 'whole', html: job.html, width: job.width, action: 'base64' });
      return r && r.status === 'ok' ? r.base64 : null;
    } catch (e) { return null; }
  }

  async body(base, text, mode, tab, withImage) {
    const body = Object.assign({}, base);
    if (mode === 'genko' || mode === 'genkoH') body.layout = await this.genkoLayout(text, mode === 'genkoH', tab);
    if (mode === 'editor') body.theme = this.editorTheme();
    if (withImage) { const img = await this.image(tab, text); if (img) body.image = img; }
    return body;
  }

  async request(method, path, body, token, timeout = 30000) {
    const headers = { 'Content-Type': 'application/json' };
    if (token) headers['X-Delete-Token'] = token;
    try {
      const r = await this.api.http({ url: BASE + path, method, headers, body: body ? JSON.stringify(body) : undefined, timeout });
      let json = null;
      try { json = JSON.parse(r.body); } catch (e) { json = null; }
      return { code: r.status, json };
    } catch (e) { return { code: 0, error: String((e && e.message) || e) }; }
  }

  failText(res) {
    return res.code === 404 ? t('このページはもう公開されていません。もう一度公開してください。')
      : res.code === 429 ? t('短い時間にたくさん公開したので、少し待ってからもう一度試してください。')
        : res.code === 0 ? t('インターネットにつながっているか確かめてください。') : t('サーバから答えがありませんでした ({code})', { code: res.code });
  }

  async upload({ text, title, mode, visibility, password, days, expiresAt, keepHistory, file, tab, quiet }) {
    toast(t('公開しています…'));
    const base = { text, title, mode, visibility, days: days || 0, keepHistory };
    if (expiresAt) base.expiresAt = expiresAt;
    if (visibility === 'password') base.password = password;
    // 「画像としてコピー」用に、いまの画面の画像も送る (パスワード制のものは送らない)
    const body = await this.body(base, text, mode, tab, visibility !== 'password' && !quiet);
    const res = await this.request('POST', '/api/share', body);
    const o = res.json || {};
    if (res.code !== 200 || !o.id || !o.url || !o.token) {
      if (!quiet) await alertBox(t('公開できませんでした'), this.failText(res));
      return null;
    }
    const rec = { id: o.id, url: o.url, token: o.token, title, visibility, created: toApple(Date.now()), contentHash: contentHash(text, mode), keepHistory };
    if (typeof o.expires === 'number') rec.expires = o.expires - APPLE_EPOCH;
    if (file) rec.path = file;
    this.records = [rec].concat(this.records);
    if (quiet) return rec;
    this.api.copyText(o.url);
    // 公開したら、すぐブラウザで開いて見せる
    this.api.openExternal(o.url);
    await alertBox(t('公開しました'), o.url + '\n\n' + t('リンクをコピーしました。') + '  ' + this.visibilityName(visibility)
      + (visibility === 'password' ? '\n' + t('読む人にはパスワードも伝えてください。') : ''));
    return rec;
  }

  /// 公開中のページを今の内容にする (URL・公開のしかた・期限はそのまま。前の内容はサイトの変更履歴に残る)
  async update(r, text, mode, tab, { quiet } = {}) {
    const body = await this.body({ text, title: r.title, mode }, text, mode, tab || (r.path ? this.app.tabs.find(x => x.path && norm(x.path) === norm(r.path)) : null), r.visibility !== 'password' && !quiet);
    const res = await this.request('PUT', '/api/share/' + r.id, body, r.token);
    if (res.code !== 200) {
      if (res.code === 404) this.records = this.records.filter(x => x.id !== r.id); // サーバにもう無い (期限切れなど)
      if (!quiet) await alertBox(t('更新できませんでした'), this.failText(res));
      return false;
    }
    this.replace(Object.assign({}, r, { contentHash: contentHash(text, mode) }));
    if (quiet) return true;
    this.api.openExternal(r.url);
    await alertBox(t('公開中のページを更新しました'), r.url + '\n\n' + t('前の内容は、ページの「変更履歴」から見られます。'));
    return true;
  }

  /// ファイルの公開中のページを更新する (個人情報の確認つき)
  async updateFile(path) {
    const r = this.recordFor(path);
    const c = r && await this.contentOf(path);
    if (!c) return;
    if (!(await this.confirmPrivacy(c.text, { tab: c.tab, file: path }))) return;
    await this.update(r, c.text, c.mode, c.tab);
  }

  /// 公開中のものの設定 (題名・公開のしかた・パスワード・期限・変更履歴) を変える。中身はそのまま
  async editSettings(r, { values, quiet } = {}) {
    const f = values || await this.form({ title: r.title, editing: r });
    if (!f) return false;
    const body = { title: f.title, visibility: f.visibility, keepHistory: f.keepHistory };
    if (f.visibility === 'password' && f.password) body.password = f.password;
    if (f.expiresAt) body.expiresAt = f.expiresAt; else if (!f.keepExpiry) body.days = f.days;
    if (f.clearHistory) body.clearHistory = true;
    const res = await this.request('PUT', '/api/share/' + r.id, body, r.token, 20000);
    const o = res.json;
    if (res.code !== 200 || !o) {
      if (!quiet) await alertBox(t('設定を変えられませんでした'), this.failText(res));
      return false;
    }
    const nr = Object.assign({}, r);
    if (String(body.title || '').trim()) nr.title = body.title;
    nr.visibility = o.visibility || nr.visibility;
    if (typeof o.expires === 'number') nr.expires = o.expires - APPLE_EPOCH; else delete nr.expires;
    if (typeof o.keepHistory === 'boolean') nr.keepHistory = o.keepHistory;
    this.replace(nr);
    if (!quiet) {
      await alertBox(t('公開の設定を変えました'), r.url + '\n' + this.visibilityName(nr.visibility) + '\n'
        + (nr.keepHistory !== false ? t('変更履歴: 残す') : t('変更履歴: 残さない'))
        + (o.historyCount === 0 && body.clearHistory ? '  ' + t('(今までの変更履歴は消しました)') : ''));
    }
    return true;
  }

  // ---------- 公開をやめる ----------

  async unpublish(r) {
    const res = await this.request('DELETE', '/api/share/' + r.id, null, r.token, 20000);
    if (res.code === 200) this.records = this.records.filter(x => x.id !== r.id);
    return res.code === 200;
  }

  async confirmUnpublish(r) {
    const ok = await modal({
      title: t('「{name}」の公開をやめますか？', { name: r.title || r.url }), body: t('リンクを開いても読めなくなります。'),
      buttons: [{ label: t('公開をやめる'), value: true, primary: true }, { label: t('キャンセル'), value: false, cancel: true }],
    });
    if (!ok) return false;
    const done = await this.unpublish(r);
    if (!done) await alertBox(t('公開をやめられませんでした'), t('インターネットにつながっているか確かめてください。'));
    else toast(t('公開をやめました'));
    return done;
  }

  // ---------- 公開したリンクの一覧 ----------

  async showList() {
    // 期限の切れたものは一覧から外す
    const alive = this.records.filter(r => this.alive(r));
    if (alive.length !== this.records.length) this.records = alive;
    let picked = 0;
    const table = h('div', { class: 'share-list', role: 'listbox' });
    const render = () => {
      const rows = this.records.map(r => this.view(r));
      table.textContent = '';
      table.append(h('div', { class: 'share-row head' }, h('span', {}, t('題名')), h('span', {}, t('公開のしかた')), h('span', {}, t('公開した日')), h('span', {}, t('期限'))));
      if (!rows.length) table.append(h('div', { class: 'dim modal-line' }, t('公開したリンクはまだありません')));
      rows.forEach((r, i) => table.append(h('div', {
        class: 'share-row' + (i === picked ? ' current' : ''), title: r.url,
        onclick: () => { picked = i; render(); }, ondblclick: () => this.api.openExternal(r.url),
      }, h('span', {}, r.title || r.url), h('span', {}, this.visibilityName(r.visibility)), h('span', {}, r.createdMs ? stamp(r.createdMs) : ''), h('span', {}, r.expiresMs ? stamp(r.expiresMs) : t('期限なし')))));
    };
    render();
    const cur = () => { const r = this.records[picked]; return r ? this.view(r) : null; };
    const buttons = h('div', { class: 'form-row top-gap' },
      h('button', { onclick: () => { const r = cur(); if (r) { this.api.copyText(r.url); toast(t('リンクをコピーしました')); } } }, t('リンクをコピー')),
      h('button', { onclick: () => { const r = cur(); if (r) this.api.openExternal(r.url); } }, t('ブラウザで開く')),
      h('span', { class: 'lib-space' }),
      h('button', { onclick: async () => { const r = cur(); if (r && await this.confirmUnpublish(r)) { picked = 0; render(); } } }, t('公開をやめる')));
    await modal({ title: t('公開したリンク'), body: h('div', {}, table, buttons), width: 680, buttons: [{ label: t('閉じる'), value: true, primary: true, cancel: true }] });
  }
}
