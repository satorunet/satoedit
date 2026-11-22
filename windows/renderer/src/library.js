// テキスト一覧 (Mac 版 TextLibrary.swift と同じ): 左にフォルダの欄、その右にテキストの一覧。
// ・新しく書いた文書の置き場所は「ドキュメント\さとるエディタ」。中にフォルダを作って分けられる (入れ子・並べ替え・アイコンと色)
// ・開いた・保存したファイルも一覧に入る (「ほかの場所」)
// ・ピン固定・ロック・複製・移動・削除・版の履歴・リンクで公開を右クリックから。Shift・Ctrl を押しながら選ぶと、まとめて扱える
import { h, modal, alertBox, confirmBox, promptBox, popupMenu, toast } from './dialogs';
import { icon } from './icons';
import { pathUtil, slidePane } from './util';
import i18n from '../../shared/i18n';
import genko from '../../shared/genko';
import menuDef from '../../shared/menu';

const { t } = i18n;
const MAX_KNOWN = 500;
/// 中身 (本文のはじめ・表示) を読むのは、新しい順にこの数まで (それより古いものはファイルの名前だけで出す)
const CONTENT_LIMIT = 120;
/// 新しく作ったファイル・フォルダに点を付けておく長さ (ミリ秒)
const NEW_MS = 20000;
/// 作ってからの残り時間 (新しくなければ 0)
export function newRemaining(created, now = Date.now()) {
  if (!created) return 0;
  const age = now - created;
  return age >= -5000 && age < NEW_MS ? NEW_MS - Math.max(0, age) : 0;
}
/// 「親 › 自分」を幅に入れる: 入りきらないときは親を後ろから縮めて「..」を付け、自分の名前は残す。fits(親の字) が入るかを答える
export function shortenParent(parent, fits) {
  if (!parent || fits(parent)) return parent;
  for (let p = parent.slice(0, -1); p.length; p = p.slice(0, -1)) if (fits(p + '..')) return p + '..';
  return fits('..') ? '..' : null;
}

/// 選べるフォルダの絵 (Mac 版の名前, 画面に出す名前, 絵文字)。名前は Mac 版と同じものを覚えるので、バックアップを Mac と行き来できる
export const FOLDER_SYMBOLS = [
  ['folder', 'フォルダ', '📁'], ['star', '星', '⭐'], ['heart', 'ハート', '❤️'], ['book', '本', '📖'], ['pencil', 'えんぴつ', '✏️'],
  ['graduationcap', '学校', '🎓'], ['briefcase', '仕事', '💼'], ['house', '家', '🏠'], ['airplane', '旅行', '✈️'], ['camera', '写真', '📷'],
  ['music.note', '音楽', '🎵'], ['leaf', '葉っぱ', '🍃'], ['lightbulb', 'アイデア', '💡'], ['flag', '旗', '🚩'], ['bookmark', 'しおり', '🔖'],
  ['tray', 'トレイ', '📥'], ['person', '人', '👤'], ['calendar', '予定', '📅'], ['cart', '買い物', '🛒'], ['gamecontroller', 'あそび', '🎮'],
];
export const FOLDER_COLORS = [
  ['accent', '標準', '#0a84ff'], ['red', '赤', '#ff3b30'], ['orange', 'オレンジ', '#ff9500'], ['yellow', '黄', '#ffcc00'], ['green', '緑', '#34c759'],
  ['teal', '青緑', '#30b0c7'], ['blue', '青', '#007aff'], ['purple', '紫', '#af52de'], ['pink', 'ピンク', '#ff2d55'], ['brown', '茶', '#a2845e'], ['gray', 'グレー', '#8e8e93'],
];
const colorOf = name => (FOLDER_COLORS.find(c => c[0] === name) || FOLDER_COLORS[0])[2];

const norm = p => String(p || '').replace(/\//g, '\\').replace(/\\+$/, '').toLowerCase();
const samePath = (a, b) => norm(a) === norm(b);

/// 日時の表示: 「たった今」「5 分前」「3 時間前」「昨日」「4 日前」、それより前は月日 (去年より前は年月日)
export function dateText(ms) {
  const d = new Date(ms), now = new Date();
  const sec = (now - d) / 1000;
  if (sec < 60) return t('たった今');
  if (sec < 3600) return t('{n} 分前', { n: Math.floor(sec / 60) });
  if (sec < 86400) return t('{n} 時間前', { n: Math.floor(sec / 3600) });
  const y = new Date(now); y.setDate(now.getDate() - 1);
  if (d.toDateString() === y.toDateString()) return t('昨日');
  if (sec < 7 * 86400) return t('{n} 日前', { n: Math.max(2, Math.floor(sec / 86400)) });
  const lang = i18n.language() === 'en' ? 'en-US' : 'ja-JP';
  return d.toLocaleDateString(lang, d.getFullYear() === now.getFullYear() ? { month: 'short', day: 'numeric' } : { year: 'numeric', month: 'short', day: 'numeric' });
}
/// 2026/11/21 13:05
export function stamp(ms) {
  const d = new Date(ms), p = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}/${p(d.getMonth() + 1)}/${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

// ---------- しるし (表示ごとの小さな絵) ----------

/// 原稿用紙のしるし: 枠と 3×3 のマス (縦書きは朱で列のすき間、横書きは緑で行のすき間)
function genkoMarkSVG(horizontal) {
  const c = horizontal ? genko.LINE_H : genko.SHEET.line;
  let d = '';
  for (let i = 1; i < 3; i++) {
    const v = 0.75 + 12.5 * i / 3;
    if (horizontal) d += `M0.75 ${v - 0.8}H13.25M0.75 ${v + 0.8}H13.25M${v} 0.75V13.25`;
    else d += `M${v - 0.8} 0.75V13.25M${v + 0.8} 0.75V13.25M0.75 ${v}H13.25`;
  }
  return `<rect x="0.75" y="0.75" width="12.5" height="12.5" fill="#fffdf7" stroke="${c}" stroke-width="1.1"/><path d="${d}" stroke="${c}" stroke-width="0.7" fill="none"/>`;
}
/// 紙のしるし: 右上を折った白い紙。lines = 横書きの行 3 本 (標準エディタ)、なし = A4用紙
function pageMarkSVG(lines) {
  const c = '#546a9e';
  const w = 14 * 0.74, x = 7 - w / 2, f = w * 0.32;
  let s = `<path d="M${x} 0.6H${x + w - f}L${x + w} ${0.6 + f}V13.4H${x}Z" fill="#fff" stroke="${c}" stroke-width="1.1" stroke-linejoin="round"/>`;
  if (lines) {
    let d = '';
    for (let k = 0; k < 3; k++) { const y = 0.6 + 12.8 * (0.42 + k * 0.18); d += `M${x + 2} ${y}H${x + w - (k === 2 ? w * 0.4 : 2)}`; }
    s += `<path d="${d}" stroke="${c}" stroke-width="0.9"/>`;
  }
  return s;
}
/// 表示のしるし (公開中なら右下にリンクのバッジ)
export function modeMark(mode, shared) {
  const inner = mode === 'genko' || mode === 'genkoH' ? genkoMarkSVG(mode === 'genkoH') : pageMarkSVG(mode !== 'a4');
  const badge = shared ? '<circle cx="14.5" cy="13" r="4.3" fill="#0a84ff" stroke="#fff" stroke-width="0.8"/><path d="M12.9 13.6l1.2-1.2M13.6 11.9l.5-.5a1.1 1.1 0 0 1 1.6 1.6l-.5.5M14.6 14.4l-.5.5a1.1 1.1 0 0 1-1.6-1.6l.5-.5" stroke="#fff" stroke-width="0.9" fill="none" stroke-linecap="round"/>' : '';
  const span = h('span', { class: 'lib-mark' });
  span.innerHTML = `<svg viewBox="0 0 ${shared ? 19 : 14} ${shared ? 17.5 : 14}" width="${shared ? 17 : 13}" height="${shared ? 15.5 : 13}" aria-hidden="true">${inner}${badge}</svg>`;
  return span;
}

// ---------- 本体 ----------

export class TextLibrary {
  constructor(app) {
    this.app = app;
    this.api = app.api;
    this.root = '';
    this.items = [];
    this.tree = [];
    this.rows = [];
    this.picked = new Set();     // いくつも選んだテキスト (パス)
    this.pickedFolders = [];     // いくつも選んだフォルダ (キー)
    this.anchor = null;
    this.query = '';
    this.extTree = [];
    this.content = new Map();   // 読んだ中身 (パス → { modified, data })。data が null ならテキストではない
    this.slid = new Set();      // 上からすべり込ませたもの (同じものは 2 回動かさない)
    this.customName = null;     // 任意フォルダを基準にしているときの、そのフォルダの名前
    this.el = document.getElementById('library-pane');
    this.build();
    // 「5 分前」などを、1 分ごとに描き直す
    setInterval(() => { if (!this.el.hidden) this.renderList(); }, 60000);
  }

  get prefs() { return this.app.prefs; }
  get selected() { return this.prefs.librarySelectedGroup || 'all'; }

  async init() {
    try {
      // 任意フォルダを選んでいれば、そこを基準にする (見つからなければローカル)
      const info = await this.api.librarySetRoot(this.prefs.libraryCustomFolder || null);
      this.applyInfo(info);
      this.historyRoot = info.history || '';
    } catch (e) { this.root = ''; }
    // はじめて使うとき: いままでの「最近使ったファイル」を一覧に入れておく
    if (!this.prefs.librarySeeded) {
      const known = (this.prefs.libraryFiles || []).slice();
      for (const f of this.prefs.recent || []) if (!known.some(k => samePath(k, f))) known.push(f);
      this.setPref('libraryFiles', known.slice(0, MAX_KNOWN));
      this.setPref('librarySeeded', true);
    }
    this.app.applyLibrary();
    await this.reload();
  }

  setPref(key, value) { this.prefs[key] = value; this.api.setPref(key, value); }

  applyInfo(info) {
    this.root = (info && info.root) || '';
    this.customName = info && info.custom ? info.name || pathUtil.base(info.root) : null;
    this.refreshStorage();
  }
  /// いちばん上の階層の名前 (ふだんは「メモ」、任意フォルダのときはそのフォルダの名前)
  get rootName() { return this.customName || t('メモ'); }

  // ---------- 置き場所 (ローカル / 任意フォルダ) ----------

  /// 任意フォルダを基準にして見る (開いたことのあるものは、新しい順に 8 つまで覚える)
  async useCustom(path) {
    const info = await this.api.librarySetRoot(path);
    if (!info.custom) {
      this.setPref('libraryCustomRecent', (this.prefs.libraryCustomRecent || []).filter(p => !samePath(p, path)));
      await alertBox(t('フォルダが見つかりません'), path);
      return;
    }
    this.applyInfo(info);
    this.setPref('libraryCustomFolder', info.root);
    this.setPref('libraryCustomRecent', [info.root].concat((this.prefs.libraryCustomRecent || []).filter(p => !samePath(p, info.root))).slice(0, 8));
    this.select('all');
    await this.reload();
  }
  async useLocal() {
    const info = await this.api.librarySetRoot(null);
    this.applyInfo(info);
    this.setPref('libraryCustomFolder', null);
    this.select('all');
    await this.reload();
  }
  async pickCustom() {
    const dirs = await this.api.openDialog({ directory: true, title: t('フォルダの欄の基準にする、この PC の中のフォルダを選んでください') });
    if (dirs && dirs[0]) await this.useCustom(dirs[0]);
  }
  /// ▾ ボタン: ローカル / 任意フォルダ… / 開いたことのある任意フォルダ (✕ で履歴から消す)
  storageMenu() {
    const cur = this.customName ? this.root : null;
    const recent = (this.prefs.libraryCustomRecent || []).slice();
    if (cur && !recent.some(p => samePath(p, cur))) recent.unshift(cur);
    const items = [
      { label: t('ローカル'), icon: '💻', checked: !cur, tip: t('ドキュメント\\さとるエディタ'), action: () => { if (cur) this.useLocal(); } },
      'sep',
      { label: t('任意フォルダ…'), icon: '📁', action: () => this.pickCustom() },
    ];
    for (const p of recent) {
      items.push({ label: pathUtil.base(p), icon: '📁', checked: !!cur && samePath(cur, p), tip: p, action: () => { if (!cur || !samePath(cur, p)) this.useCustom(p); },
        remove: { tip: t('この履歴を消す (フォルダそのものは消しません)'), action: () => this.removeRecent(p) } });
    }
    const r = this.storageButton.getBoundingClientRect();
    popupMenu(items, r.left, r.bottom + 2, { className: 'lib-storage-menu' });
  }
  async removeRecent(path) {
    this.setPref('libraryCustomRecent', (this.prefs.libraryCustomRecent || []).filter(p => !samePath(p, path)));
    // 今見ているフォルダを消したときは、ローカルに戻す
    if (this.customName && samePath(this.root, path)) await this.useLocal();
    this.refreshStorage();
    this.storageMenu();
  }
  refreshStorage() {
    if (!this.storageButton) return;
    this.storageButton.textContent = '';
    this.storageButton.append(h('span', { class: 'lib-storage-name' }, this.customName || t('ローカル')), h('span', { class: 'lib-storage-arrow' }, '▾'));
    this.storageButton.title = t('見るテキストの置き場所: この PC・好きなフォルダ') + (this.root ? '\n' + this.root : '');
  }

  // ---------- 開いたほかの場所のフォルダ ----------

  get externalFolders() { return (this.prefs.libraryExternalFolders || []).filter(Boolean); }
  /// そのファイルが入っている、開いたフォルダ (なければ null)
  externalRoot(path) {
    const n = norm(path);
    let best = null;
    for (const e of this.externalFolders) if (n.startsWith(norm(e) + '\\') && (!best || e.length > best.length)) best = e;
    return best;
  }
  async openExternalFolder() {
    const dirs = await this.api.openDialog({ directory: true, title: t('一覧に出す、この PC の中のフォルダを選んでください (中のテキストが出ます)') });
    const p = dirs && dirs[0];
    if (!p) return;
    // さとるエディタのフォルダ (とその中) は、もう出ているので足さない
    if (samePath(p, this.root) || norm(p).startsWith(norm(this.root) + '\\')) { this.select(this.group(p + '\\x') ? 'sub:' + this.group(p + '\\x') : 'root'); return; }
    if (!this.externalFolders.some(e => samePath(e, p))) {
      this.setPref('libraryExternalFolders', this.externalFolders.concat([p]));
      // 「ほかの場所」の記録から、開いたフォルダの中のものを外す (そちらで出るので、二重に出さない)
      this.setPref('libraryFiles', (this.prefs.libraryFiles || []).filter(f => !norm(f).startsWith(norm(p) + '\\')));
    }
    this.select('ext:' + p);
    await this.reload();
  }
  async removeExternalFolder(path) {
    this.setPref('libraryExternalFolders', this.externalFolders.filter(e => !samePath(e, path)));
    if (this.selectionKeys(this.selected).some(k => k.startsWith('ext:') && (samePath(k.slice(4), path) || norm(k.slice(4)).startsWith(norm(path) + '\\')))) this.select('all');
    await this.reload();
  }

  // ---------- 場所 ----------

  /// "" = さとるエディタ直下、"旅行/京都" = 中のフォルダ、null = ほかの場所
  group(path) {
    if (!path || !this.root) return null;
    const root = norm(this.root), parent = norm(pathUtil.dir(path));
    if (parent === root) return '';
    if (!parent.startsWith(root + '\\')) return null;
    return pathUtil.dir(path).replace(/\//g, '\\').replace(/\\+$/, '').slice(this.root.replace(/\\+$/, '').length + 1).replace(/\\/g, '/');
  }
  isInFolder(path) { return this.group(path) !== null; }
  folderPath(rel) { return rel ? this.root.replace(/\\+$/, '') + '\\' + rel.replace(/\//g, '\\') : this.root; }
  isPlaceholder(path) {
    if (!path || !this.isInFolder(path)) return false;
    const n = pathUtil.base(path).replace(/\.[^.]*$/, '');
    return n === '新規テキスト' || n.startsWith('新規テキスト ');
  }
  /// 新しい文書を置くフォルダ (左の欄で選んでいるフォルダ。ほかはさとるエディタ直下)
  targetRel() {
    let sel = this.selected;
    if (sel.startsWith('multi:')) sel = sel.slice(6).split('\n').find(k => k.startsWith('sub:')) || 'root';
    return sel.startsWith('sub:') ? sel.slice(4) : '';
  }

  // ---------- 覚えておくこと ----------

  isPinned(path) { return (this.prefs.libraryPinned || []).some(p => samePath(p, path)); }
  setPinned(on, path) {
    const list = (this.prefs.libraryPinned || []).filter(p => !samePath(p, path));
    if (on) list.unshift(path);
    this.setPref('libraryPinned', list);
    this.changed();
  }
  /// 開いた・保存したファイルを覚える (さとるエディタのフォルダの外のものだけ、一覧の「ほかの場所」に出る)
  remember(path) {
    if (!path || /\.(pdf|docx?|xlsx?|pptx?|zip|exe|png|jpe?g|gif|satorubackup)$/i.test(path)) return;
    const old = this.prefs.libraryFiles || [];
    const known = old.some(p => samePath(p, path));
    if (known && samePath(old[0], path)) return;
    this.setPref('libraryFiles', [path].concat(old.filter(p => !samePath(p, path))).slice(0, MAX_KNOWN));
    // 開くファイルを替えただけでは読み直さない (一覧に新しく入るときだけ)
    if (!known && !this.itemFor(path)) this.changed();
  }
  forget(path) {
    this.setPref('libraryFiles', (this.prefs.libraryFiles || []).filter(p => !samePath(p, path)));
    this.changed();
  }
  /// ファイルの表示を覚える (ファイルの見えない所に書く。書けないファイルはアプリの中に)
  async setMode(path, mode) {
    if (!path) return;
    const ok = await this.api.librarySetMode(path, mode || null);
    const modes = Object.assign({}, this.prefs.libraryModes || {});
    const key = norm(path);
    if (ok) { if (key in modes) { delete modes[key]; this.setPref('libraryModes', modes); } } else if (modes[key] !== mode) {
      if (mode) modes[key] = mode; else delete modes[key];
      const keys = Object.keys(modes);
      if (keys.length > 1000) delete modes[keys[0]];
      this.setPref('libraryModes', modes);
    }
    const it = this.itemFor(path);
    if (it && it.mode !== mode) { it.mode = mode || null; this.renderList(); }
  }
  modeFallback(path) { return (this.prefs.libraryModes || {})[norm(path)] || null; }

  /// ファイル・フォルダの場所が変わった: 覚えていること (ピン・表示・公開・一覧) と、開いているタブの場所を付け替える
  relocate(oldPath, newPath) {
    const o = norm(oldPath);
    const swap = p => {
      const n = norm(p);
      if (n === o) return newPath;
      if (n.startsWith(o + '\\')) return newPath + p.slice(oldPath.replace(/\\+$/, '').length);
      return p;
    };
    this.setPref('libraryPinned', (this.prefs.libraryPinned || []).map(swap));
    this.setPref('libraryFiles', (this.prefs.libraryFiles || []).map(swap));
    const modes = {};
    for (const [k, v] of Object.entries(this.prefs.libraryModes || {})) modes[norm(swap(k))] = v;
    this.setPref('libraryModes', modes);
    if (this.app.share) this.app.share.repath(oldPath, newPath, swap);
    for (const tab of this.app.tabs) {
      if (!tab.path) continue;
      const q = swap(tab.path);
      if (q !== tab.path) { tab.path = q; tab.name = pathUtil.base(q); }
    }
    this.app.updateTabs();
    this.changed();
  }
  /// フォルダの道すじが変わった: 並び・アイコン・選んでいるフォルダも付け替える
  relocateFolder(oldRel, newRel, from, to) {
    const swapRel = r => (r === oldRel || r.startsWith(oldRel + '/') ? newRel + r.slice(oldRel.length) : r);
    this.setPref('libraryFolderOrder', (this.prefs.libraryFolderOrder || []).map(swapRel));
    const icons = {};
    for (const [k, v] of Object.entries(this.prefs.libraryFolderIcons || {})) icons[swapRel(k)] = v;
    this.setPref('libraryFolderIcons', icons);
    this.setPref('libraryFolderExpanded', (this.prefs.libraryFolderExpanded || []).map(k => (k.startsWith('sub:') ? 'sub:' + swapRel(k.slice(4)) : k)));
    const swapKey = k => (k.startsWith('sub:') ? 'sub:' + swapRel(k.slice(4)) : k);
    const sel = this.selected;
    this.select(sel.startsWith('multi:') ? 'multi:' + sel.slice(6).split('\n').map(swapKey).join('\n') : swapKey(sel));
    for (const tab of this.app.tabs) if (tab.librarySelection) tab.librarySelection = swapKey(tab.librarySelection);
    this.relocate(from, to);
  }

  folderIcon(rel) {
    const v = String((this.prefs.libraryFolderIcons || {})[rel] || '');
    const [sym, col] = v.split('|');
    return { symbol: sym || 'folder', color: col || null };
  }
  setFolderIcon(rel, { symbol, color, reset } = {}) {
    const all = Object.assign({}, this.prefs.libraryFolderIcons || {});
    if (reset) delete all[rel];
    else {
      const cur = this.folderIcon(rel);
      const col = color !== undefined ? color : (cur.color || '');
      all[rel] = (symbol || cur.symbol) + '|' + (col === 'accent' ? '' : col);
    }
    this.setPref('libraryFolderIcons', all);
    this.renderFolders();
  }
  folderBadge(rel, fallbackSym) {
    const ic = rel === null ? { symbol: fallbackSym, color: null } : this.folderIcon(rel);
    const sym = FOLDER_SYMBOLS.find(s => s[0] === ic.symbol);
    const span = h('span', { class: 'lib-ficon', style: { '--fc': colorOf(ic.color) } });
    if (!sym || ic.symbol === 'folder') span.append(folderSVG());
    else span.append(h('span', { class: 'lib-femoji' }, sym[2]));
    if (ic.color && sym && ic.symbol !== 'folder') span.classList.add('tinted');
    return span;
  }

  // ---------- 一覧を読む ----------

  changed() {
    clearTimeout(this.changeTimer);
    this.changeTimer = setTimeout(() => this.reload(), 300);
  }

  async reload() {
    const gen = (this.gen = (this.gen || 0) + 1);
    // 時間がかかるときは、前の中身を消してから「読み込み中…」を出す
    clearTimeout(this.loadingTimer);
    this.loadingTimer = setTimeout(() => { if (gen === this.gen) this.setLoading(true); }, 250);
    let scan = null;
    try {
      // ファイルの場所と日時だけを集める (中身は読まない)。中身は、選んでいるフォルダの分だけあとで読む
      scan = await this.api.libraryScan(this.prefs.libraryFiles || [], this.prefs.libraryFolderOrder || [], this.externalFolders);
    } catch (e) { console.warn(e); }
    if (gen !== this.gen) return;
    clearTimeout(this.loadingTimer);
    this.setLoading(false);
    scan = scan || {};
    if (scan.root) this.root = scan.root;
    const share = this.app.share;
    const items = [];
    for (const it of scan.files || []) {
      const c = this.content.get(norm(it.path));
      if (c && c.modified === it.modified) {
        if (!c.data) continue; // テキストではなかった
        this.fill(it, c.data);
      }
      it.pinned = this.isPinned(it.path);
      const r = share && this.prefs.shareEnabled !== false ? share.recordFor(it.path) : null;
      it.sharedURL = r ? r.url : null;
      items.push(it);
    }
    this.items = items.sort((a, b) => (a.pinned !== b.pinned ? (a.pinned ? -1 : 1) : b.modified - a.modified));
    this.tree = scan.tree || [];
    this.extTree = scan.externals || [];
    this.applyModes();
    // 消えたフォルダを選んでいたら「すべて」に戻す
    const keys = this.selectionKeys(this.selected);
    if (keys.some(k => (k.startsWith('sub:') && !this.findRel(k.slice(4))) || (k.startsWith('ext:') && !this.findExt(k.slice(4))))) this.select('all');
    this.renderFolders();
    this.renderList();
    await this.loadContents();
  }

  fill(it, d) {
    it.snippet = d.snippet || '';
    it.encrypted = !!d.encrypted;
    it.fileMode = d.mode || null;
    it.loaded = true;
  }
  /// 表示 (しるし): 開いているタブは今の表示、ほかはファイルに書いたもの (書けなかったものはアプリが覚えたもの)
  applyModes() {
    for (const it of this.items) it.mode = it.encrypted ? null : it.fileMode || this.modeFallback(it.path);
    for (const tab of this.app.tabs) {
      const it = tab.path && this.itemFor(tab.path);
      if (it) it.mode = this.app.modeString(tab);
    }
  }

  /// 選んでいるフォルダのテキストの中身を読む (新しい順に CONTENT_LIMIT 件まで。読んだものは覚えておく)
  async loadContents() {
    const sel = this.selected;
    const want = this.items.filter(it => this.matches(it, sel)).sort((a, b) => b.modified - a.modified).slice(0, CONTENT_LIMIT).filter(it => !it.loaded);
    if (!want.length) return;
    let res = [];
    try { res = await this.api.libraryRead(want.map(x => x.path)); } catch (e) { res = []; }
    let dropped = false;
    want.forEach((it, i) => {
      const d = res && res[i];
      if (d === undefined) return;
      this.content.set(norm(it.path), { modified: it.modified, data: d ? { snippet: d.snippet, encrypted: d.encrypted, mode: d.mode } : null });
      if (d) this.fill(it, d); else { it.notText = true; dropped = true; }
    });
    if (dropped) this.items = this.items.filter(it => !it.notText);
    this.applyModes();
    if (dropped) this.renderFolders();
    this.renderList();
  }

  /// 読み込み中のしるし (ぐるぐると「読み込み中…」)。出すときは前の中身を消す
  setLoading(on) {
    if (!this.folderLoading) return;
    this.loading = on;
    this.folderLoading.hidden = !on;
    this.listLoading.hidden = !on;
    if (on) { this.folderList.textContent = ''; this.list.textContent = ''; }
  }

  itemFor(path) { return this.items.find(x => samePath(x.path, path)) || null; }
  findRel(rel, nodes = this.tree) {
    for (const n of nodes) { if (n.rel === rel) return n; const c = this.findRel(rel, n.children || []); if (c) return c; }
    return null;
  }
  allRels(nodes = this.tree, out = []) { for (const n of nodes) { out.push(n.rel); this.allRels(n.children || [], out); } return out; }
  findExt(path, nodes = this.extTree) {
    for (const n of nodes) { if (samePath(n.path, path)) return n; const c = this.findExt(path, n.children || []); if (c) return c; }
    return null;
  }
  selectionKeys(sel) { return sel.startsWith('multi:') ? sel.slice(6).split('\n').filter(Boolean) : [sel]; }
  matches(item, sel) {
    if (sel.startsWith('multi:')) return this.selectionKeys(sel).some(k => this.matches(item, k));
    if (sel === 'all') return true;
    if (sel === 'root') return item.group === '';
    if (sel === 'other') return (item.group === null || item.group === undefined) && !this.externalRoot(item.path);
    if (sel === 'shared') return !!item.sharedURL;   // リンクで公開共有しているもの
    if (sel.startsWith('ext:')) return norm(item.path).startsWith(norm(sel.slice(4)) + '\\');
    return sel.startsWith('sub:') && item.group === sel.slice(4);
  }

  /// 左の欄で選ぶフォルダを変える (いま前にあるタブのものとして覚える)
  select(key) {
    if (this.selected !== key) this.setPref('librarySelectedGroup', key);
    if (this.app.active) this.app.active.librarySelection = key;
    this.pickedFolders = this.selectionKeys(key);
    this.picked.clear();
    this.renderFolders();
    this.renderList();
    this.refreshDivider();
    // 選んだフォルダの分の中身を読む
    this.loadContents();
  }

  // ---------- 画面 ----------

  build() {
    this.folderList = h('div', { class: 'lib-folders', role: 'tree', tabindex: '0', 'aria-label': t('フォルダ') });
    // Delete で、選んでいるフォルダを削除する (聞いてから)。「すべて」「メモ」などは消せない
    this.folderList.addEventListener('keydown', e => {
      if ((e.key === 'Delete' || e.key === 'Backspace') && !e.isComposing && !e.altKey && !e.ctrlKey) {
        e.preventDefault();
        const rels = this.selectionKeys(this.selected).filter(k => k.startsWith('sub:')).map(k => k.slice(4));
        if (!rels.length) { this.beep(); return; }
        this.trashFolders(rels);
      }
    });
    // 左上: 新規フォルダ (選んでいるフォルダの中に作る)。好きな場所のフォルダを開くのは右クリックと「…」から
    this.newFolderButton = h('button', { class: 'icon-button lib-newfolder', title: t('新規フォルダ (選んでいるフォルダの中に作る)'), 'aria-label': t('新規フォルダ'),
      onclick: () => this.newFolder(this.folderParent()) }, icon('newFolder', 15));
    // 右上: 置き場所 (ローカル / 任意フォルダ) の ▾ ボタン
    this.storageButton = h('button', { class: 'lib-storage', onclick: () => this.storageMenu() });
    this.refreshStorage();
    this.folderLoading = loadingMark();
    this.folderPane = h('div', { class: 'lib-folder-pane' },
      h('div', { class: 'lib-head' }, this.newFolderButton, h('span', { class: 'lib-space' }), this.storageButton),
      this.folderLoading, this.folderList);
    this.search = h('input', { type: 'search', class: 'lib-search', placeholder: t('題名・本文で絞り込み'), hidden: true });
    this.search.addEventListener('input', () => { this.query = this.search.value.trim().toLowerCase(); this.renderList(); });
    this.search.addEventListener('keydown', e => { if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); this.toggleSearch(); } });
    this.list = h('div', { class: 'lib-list', tabindex: '0', role: 'listbox', 'aria-label': t('テキスト一覧'), 'aria-multiselectable': 'true' });
    this.list.addEventListener('keydown', e => {
      if ((e.key === 'Delete' || e.key === 'Backspace') && !e.isComposing) {
        const paths = this.pickedPaths();
        if (paths.length) { e.preventDefault(); this.trash(paths); }
      }
    });
    // ふつうになぞると、そのファイルをつかむ (フォルダの上に置くと移る)。Shift を押しながらなぞったときだけ、続けて選ぶ
    this.list.addEventListener('mousedown', e => this.shiftSweep(e));
    // 上下 (フォルダの欄が上、テキストの一覧が下) ⇔ 左右 (フォルダの欄が左) の切り替え
    this.layoutButton = h('button', { class: 'icon-button lib-layout', title: t('上下 / 左右に並べ替える'), 'aria-label': t('上下 / 左右に並べ替える'),
      onclick: () => { this.setPref('libraryOneColumn', !this.oneColumn); this.arrange(); } });
    this.newTextButton = h('button', { class: 'icon-button', title: t('新しいテキスト'), 'aria-label': t('新しいテキスト'), onclick: () => this.createBlank() }, icon('new', 15));
    this.moreButton = h('button', { class: 'icon-button', title: t('履歴の操作'), 'aria-label': t('履歴の操作'), onclick: () => this.moreMenu() }, icon('more', 15));
    // ゴミ箱: 押すと選んだテキストを削除。ファイルやフォルダをつかんで置いても削除できる
    this.trashButton = h('button', { class: 'icon-button lib-trash', title: t('ゴミ箱 (選んだテキストを削除。ファイルやフォルダをここに置いても削除できます)'), 'aria-label': t('削除'),
      onclick: () => { const paths = this.pickedPaths(); if (!paths.length) { this.beep(); return; } this.trash(paths); } }, icon('trash', 15));
    this.bindTrashDrop(this.trashButton);
    this.listLoading = loadingMark();
    this.listPane = h('div', { class: 'lib-list-pane' },
      h('div', { class: 'lib-head' },
        this.newTextButton,
        h('span', { class: 'lib-space' }),
        h('button', { class: 'icon-button', title: t('検索'), onclick: () => this.toggleSearch() }, icon('find', 15)),
        this.layoutButton,
        this.moreButton,
        this.trashButton,
        h('button', { class: 'icon-button', title: t('テキスト一覧を閉じる'), onclick: () => this.app.setPref('libraryVisible', false) }, '✕')),
      this.search, this.listLoading, this.list);
    const resizer = (pane, key, min, max) => {
      const r = h('div', { class: 'lib-resizer', title: t('ドラッグで幅を変える') });
      r.addEventListener('mousedown', e => {
        e.preventDefault();
        const target = typeof pane === 'function' ? pane() : pane;
        const start = e.clientX, w0 = target.getBoundingClientRect().width;
        const move = ev => { target.style.width = Math.max(min, Math.min(max, w0 + ev.clientX - start)) + 'px'; this.app.scheduleRuler(); this.refreshDivider(); };
        const up = () => { window.removeEventListener('mousemove', move); window.removeEventListener('mouseup', up); this.setPref(key, Math.round(target.getBoundingClientRect().width)); };
        window.addEventListener('mousemove', move);
        window.addEventListener('mouseup', up);
      });
      return r;
    };
    this.column = h('div', { class: 'lib-column' });
    // 上下のときの、フォルダの欄と一覧の間のバー: 選んでいるフォルダの名前。つかんで上下に動かすと、フォルダの欄の高さが変わる (ダブルクリックで元に戻す)
    this.dividerLabel = h('span', { class: 'lib-divider-label' });
    this.stackDivider = h('div', { class: 'lib-stack-divider', title: '' }, this.dividerLabel);
    this.bindDivider(this.stackDivider);
    window.addEventListener('resize', () => { this.fitFolders(); this.refreshDivider(); });
    this.folderResizer = resizer(this.folderPane, 'libraryFolderWidth', 60, 420);
    this.listResizer = resizer(() => (this.oneColumn ? this.column : this.listPane), 'libraryListWidth', 110, 640);
    this.arrange();
  }

  beep() { try { this.api.beep(); } catch (e) { /* 鳴らせなくてもよい */ } }

  /// 新規フォルダを作る場所 (左上のボタン・「…」から): 選んでいるフォルダ (「すべて」などなら、いちばん上)
  folderParent() {
    const sel = this.selected;
    return sel.startsWith('sub:') ? sel.slice(4) : '';
  }

  /// 区切りのバーをつかんで上下に動かす: フォルダの欄の高さ (欄の半分まで。覚えておく)。ダブルクリックでフォルダの数に合わせた高さに戻す
  bindDivider(bar) {
    bar.addEventListener('mousedown', e => {
      if (e.button !== 0 || e.detail > 1) return;
      e.preventDefault();
      const y0 = e.clientY, h0 = this.folderPane.getBoundingClientRect().height;
      const move = ev => {
        const max = this.column.clientHeight * 0.5;
        const hgt = Math.round(Math.min(max, Math.max(50, h0 + ev.clientY - y0)));
        this.prefs.libraryFolderPaneHeight = hgt;
        this.folderPane.style.height = hgt + 'px';
      };
      const up = () => {
        window.removeEventListener('mousemove', move);
        window.removeEventListener('mouseup', up);
        if (this.prefs.libraryFolderPaneHeight) this.setPref('libraryFolderPaneHeight', this.prefs.libraryFolderPaneHeight);
      };
      window.addEventListener('mousemove', move);
      window.addEventListener('mouseup', up);
    });
    bar.addEventListener('dblclick', () => {
      this.setPref('libraryFolderPaneHeight', null);
      this.folderPane.classList.add('lib-animate-height');
      this.fitFolders();
      setTimeout(() => this.folderPane.classList.remove('lib-animate-height'), 250);
    });
  }

  /// 区切りのバーの字: 選んでいるフォルダ (深いときは、ひとつ上の親と自分の名前だけ)。入りきらないときは親を「..」で縮める
  refreshDivider() {
    if (!this.dividerLabel) return;
    const key = this.selected;
    let badge, text, parent = '';
    if (key === 'all') { badge = h('span', { class: 'lib-ficon' }, icon('library', 12)); text = t('すべて'); }
    else if (key === 'root') { badge = this.folderBadge(null, 'folder'); text = this.rootName; }
    else if (key === 'other') { badge = this.folderBadge(null, 'folder'); text = t('ほかの場所'); }
    else if (key === 'shared') { badge = this.folderBadge(null, 'folder'); text = t('公開共有中'); }
    else if (key.startsWith('sub:')) {
      const rel = key.slice(4), parts = rel.split('/');
      badge = this.folderBadge(rel);
      text = parts[parts.length - 1];
      if (parts.length > 1) parent = parts[parts.length - 2];
    } else if (key.startsWith('ext:')) { badge = this.folderBadge(null, 'folder'); text = pathUtil.base(key.slice(4)); }
    else if (key.startsWith('multi:')) { badge = this.folderBadge(null, 'folder'); text = t('{n} 個のフォルダ', { n: this.selectionKeys(key).length }); }
    else { badge = this.folderBadge(null, 'folder'); text = ''; }
    const label = this.dividerLabel;
    this.stackDivider.title = t('下のテキストは「{name}」の中のものです', { name: parent ? parent + ' › ' + text : text });
    const set = p => {
      label.textContent = '';
      label.append(badge, h('span', { class: 'lib-divider-text' }, (p ? p + ' › ' : '') + text));
    };
    set(parent);
    if (!parent || !label.isConnected || !label.clientWidth) return;
    const room = this.stackDivider.clientWidth - 16;
    const fits = p => { set(p); return label.scrollWidth <= room; };
    const best = shortenParent(parent, fits);
    set(best || '');
  }

  /// Shift を押しながらなぞる: 押したところから続けて選ぶ (つかまない)
  shiftSweep(e) {
    if (e.button !== 0 || !e.shiftKey) return;
    const start = e.target.closest && e.target.closest('.lib-row');
    if (!start) return;
    e.preventDefault();
    this.list.focus({ preventScroll: true });
    const indexOf = el => Number(el.dataset.index);
    const from = this.anchor || (this.app.active && this.app.active.path);
    let a = this.rows.findIndex(r => samePath(r.path, from));
    if (a < 0) a = indexOf(start);
    let last = -1;
    const pick = b => {
      if (b === last || b < 0 || b >= this.rows.length) return;
      last = b;
      this.picked.clear();
      for (let i = Math.min(a, b); i <= Math.max(a, b); i++) this.picked.add(norm(this.rows[i].path));
      this.renderList();
    };
    pick(indexOf(start));
    const move = ev => {
      const el = document.elementFromPoint(ev.clientX, ev.clientY);
      const row = el && el.closest && el.closest('.lib-row');
      if (row && this.list.contains(row)) pick(indexOf(row));
    };
    const up = () => { window.removeEventListener('mousemove', move); window.removeEventListener('mouseup', up); this.swept = true; setTimeout(() => { this.swept = false; }, 0); };
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
  }

  /// ゴミ箱のボタンに、一覧のファイル・フォルダの欄のフォルダを置くと削除する (聞いてから)
  bindTrashDrop(btn) {
    const ok = e => { const ty = Array.from(e.dataTransfer.types); return ty.includes('application/x-satoru-texts') || ty.includes('application/x-satoru-folder'); };
    btn.addEventListener('dragover', e => { if (!ok(e)) return; e.preventDefault(); e.dataTransfer.dropEffect = 'move'; btn.classList.add('drop-hot'); });
    btn.addEventListener('dragleave', () => btn.classList.remove('drop-hot'));
    btn.addEventListener('drop', e => {
      btn.classList.remove('drop-hot');
      if (!ok(e)) return;
      e.preventDefault();
      const texts = e.dataTransfer.getData('application/x-satoru-texts');
      const folder = e.dataTransfer.getData('application/x-satoru-folder');
      // ドラッグが終わってから聞く
      setTimeout(() => {
        if (texts) this.trash(JSON.parse(texts));
        if (folder) this.trashFolders([folder]);
      }, 0);
    });
  }

  /// 「…」のメニュー
  moreMenu() {
    const r = this.moreButton.getBoundingClientRect();
    popupMenu([
      { label: t('新しいテキスト'), icon: '📝', action: () => this.createBlank() },
      { label: t('新規フォルダ…'), icon: '📁', action: () => this.newFolder(this.folderParent()) },
      { label: t('ほかの場所のフォルダを開く…'), icon: '📂', action: () => this.openExternalFolder() },
      'sep',
      { label: t('サムネで一覧'), icon: '▦', action: () => this.showGrid() },
      { label: t('保存フォルダをエクスプローラーで開く'), icon: '📂', action: async () => { const p = await this.api.libraryFolderPath(''); this.api.openPath(p); } },
      'sep',
      { label: t('「ほかの場所」の履歴をクリア…'), action: () => this.clearOtherPlaces() },
      'sep',
      { label: t('版の履歴・バックアップの設定…'), icon: '⚙', action: () => this.app.run('settings.open:backup') },
    ], r.left, r.bottom + 2);
  }

  /// 「ほかの場所」(さとるエディタのフォルダの外) のテキストを、一覧から外す (ファイルは消さない)
  async clearOtherPlaces() {
    const others = this.items.filter(it => (it.group === null || it.group === undefined) && !this.externalRoot(it.path));
    if (!others.length) { this.beep(); return; }
    const ok = await confirmBox(t('「ほかの場所」の履歴をクリアしますか？'),
      t('一覧から {n} 件を外します。ファイルそのものは消しません。さとるエディタのフォルダの中のテキストはそのままです。', { n: others.length }), t('クリア'));
    if (!ok) return;
    this.setPref('libraryFiles', (this.prefs.libraryFiles || []).filter(p => !others.some(o => samePath(o.path, p))));
    await this.reload();
  }

  /// 上下に並べるか (はじめは上下。Mac 版と同じ「libraryOneColumn」)
  get oneColumn() { return this.prefs.libraryOneColumn !== false; }

  /// 上下 / 左右に並べ直す
  arrange() {
    const one = this.oneColumn;
    this.el.classList.toggle('stacked', one);
    this.el.textContent = '';
    this.column.textContent = '';
    this.layoutButton.textContent = '';
    this.layoutButton.append(layoutSVG(!one));
    if (one) {
      // 上にフォルダの欄 (高さは中身に合わせる)、下にテキストの一覧 (残りぜんぶ)。Mac 版と同じ
      this.folderPane.style.width = '';
      this.listPane.style.width = '';
      this.column.style.width = (Number(this.prefs.libraryListWidth) || 220) + 'px';
      this.column.append(this.folderPane, this.stackDivider, this.listPane);
      this.el.append(this.column, this.listResizer);
      this.fitFolders();
      requestAnimationFrame(() => this.refreshDivider());
    } else {
      this.column.style.width = '';
      this.folderPane.style.height = '';
      this.folderPane.style.width = (Number(this.prefs.libraryFolderWidth) || 140) + 'px';
      this.listPane.style.width = (Number(this.prefs.libraryListWidth) || 220) + 'px';
      this.el.append(this.folderPane, this.folderResizer, this.listPane, this.listResizer);
    }
    this.app.scheduleRuler();
  }

  /// 出す / しまう (左はしから滑らせる)
  setVisible(on) {
    const now = this.el.dataset.sliding ? this.el.dataset.sliding === 'in' : !this.el.hidden;
    if (on === now) return;
    if (on && this.el.hidden) this.arrange();
    if (on) requestAnimationFrame(() => this.fitFolders());
    slidePane(this.el, on, true, () => this.app.scheduleRuler());
  }

  toggleSearch() {
    this.search.hidden = !this.search.hidden;
    if (this.search.hidden) { this.search.value = ''; this.query = ''; this.renderList(); this.app.focusEditor(); } else this.search.focus();
  }

  // ---------- フォルダの欄 ----------

  renderFolders() {
    if (this.loading) return;
    const counts = {};
    let other = 0, shared = 0;
    for (const it of this.items) {
      if (it.group === null || it.group === undefined) { if (!this.externalRoot(it.path)) other++; } else counts[it.group] = (counts[it.group] || 0) + 1;
      if (it.sharedURL) shared++;
    }
    const expanded = new Set(this.prefs.libraryFolderExpanded || []);
    const keys = new Set(this.selectionKeys(this.selected));
    const list = this.folderList;
    const scroll = list.scrollTop;
    const animate = this.folderRendered && list.isConnected;
    list.textContent = '';
    let soonest = 0;
    const row = (key, name, badge, count, depth, node) => {
      const hasKids = node && node.children && node.children.length;
      const open = hasKids && expanded.has(key);
      // 新しく作ったフォルダ: 名前のすぐ右に小さな点 (少しのあいだだけ)。はじめて出るときは上からすべり込む
      const left = key.startsWith('sub:') && node ? newRemaining(node.created) : 0;
      if (left && (!soonest || left < soonest)) soonest = left;
      const fresh = left && !this.slid.has(key);
      if (fresh) this.slid.add(key);
      const el = h('div', {
        class: 'lib-frow' + (keys.has(key) ? ' current' : '') + (fresh && animate ? ' lib-slide-in' : ''), role: 'treeitem', 'data-key': key, draggable: key.startsWith('sub:') ? 'true' : null,
        style: { paddingLeft: (4 + depth * 10) + 'px' },
        onclick: e => { list.focus({ preventScroll: true }); this.folderClicked(key, e); },
        oncontextmenu: e => { e.preventDefault(); this.folderMenu(key, e.clientX, e.clientY); },
      },
      h('span', { class: 'lib-twist' + (open ? ' open' : ''), onclick: e => { if (!hasKids) return; e.stopPropagation(); this.toggleExpand(key); } }, hasKids ? icon('chevron', 10) : ''),
      badge, h('span', { class: 'lib-fname', title: node && node.path ? node.path : null }, name), left ? newDot() : null, h('span', { class: 'lib-space' }),
      h('span', { class: 'lib-count' }, count > 0 ? String(count) : ''));   // 0 件は出さない
      this.bindFolderDrag(el, key);
      list.append(el);
      if (open) {
        for (const c of node.children) {
          if (key.startsWith('ext:')) row('ext:' + c.path, c.name, this.folderBadge(null, 'folder'), this.countUnder(c.path), depth + 1, c);
          else row('sub:' + c.rel, c.name, this.folderBadge(c.rel), counts[c.rel] || 0, depth + 1, c);
        }
      }
    };
    row('all', t('すべて'), h('span', { class: 'lib-ficon' }, icon('library', 14)), this.items.length, 0, null);
    row('root', this.rootName, this.folderBadge(null, 'folder'), counts[''] || 0, 0, null);
    for (const n of this.tree) row('sub:' + n.rel, n.name, this.folderBadge(n.rel), counts[n.rel] || 0, 0, n);
    for (const n of this.extTree) row('ext:' + n.path, n.name, this.folderBadge(null, 'folder'), this.countUnder(n.path), 0, n);
    row('other', t('ほかの場所'), h('span', { class: 'lib-ficon' }, '📄'), other, 0, null);
    // リンクで公開共有しているテキスト (あるときだけ出す)
    if (shared > 0) row('shared', t('公開共有中'), h('span', { class: 'lib-ficon' }, '🔗'), shared, 0, null);
    // 自分で作ったフォルダがまだ無いときは、並びのすぐ下に作り方の案内を出す
    if (!this.tree.length) {
      list.append(h('div', { class: 'lib-folder-hint' }, hintText(t('「左上のボタン」で新規フォルダ'), () => this.newFolder(this.folderParent()), on => hop(this.newFolderButton, on))));
    }
    list.scrollTop = scroll;
    this.folderRendered = true;
    this.scheduleNewExpiry(soonest);
    this.fitFolders();
    this.refreshDivider();
  }

  countUnder(path) { const p = norm(path) + '\\'; return this.items.filter(it => norm(it.path).startsWith(p)).length; }

  /// 新しいしるしの点を、時間が来たら消す (描き直す)
  scheduleNewExpiry(ms) {
    if (!ms) return;
    const at = Date.now() + ms + 50;
    if (this.newExpiryAt && this.newExpiryAt <= at && this.newExpiryAt > Date.now()) return;
    clearTimeout(this.newExpiryTimer);
    this.newExpiryAt = at;
    this.newExpiryTimer = setTimeout(() => { this.newExpiryAt = 0; this.renderFolders(); this.renderList(); }, ms + 50);
  }

  /// 上下のとき、フォルダの欄の高さを中身 (見出し + 見えているフォルダの行) に合わせる。80px 以上、欄の高さの半分まで。
  /// 区切りのバーで高さを決めたときは、その高さ (欄の半分まで)
  fitFolders() {
    if (!this.oneColumn || !this.folderPane || !this.folderPane.isConnected) return;
    const pane = this.folderPane;
    const total = this.column.clientHeight;
    if (!total) return; // まだ画面に出ていない
    const manual = Number(this.prefs.libraryFolderPaneHeight) || 0;
    if (manual) { pane.style.height = Math.round(Math.max(50, Math.min(manual, total * 0.5))) + 'px'; return; }
    const head = pane.querySelector('.lib-head');
    const natural = (head ? head.offsetHeight : 0) + this.folderList.scrollHeight + 6;
    if (!natural) return;
    const height = Math.round(Math.max(80, Math.min(natural, total * 0.5)));
    pane.style.height = height + 'px';
  }

  toggleExpand(key) {
    const set = new Set(this.prefs.libraryFolderExpanded || []);
    if (set.has(key)) set.delete(key); else set.add(key);
    this.setPref('libraryFolderExpanded', Array.from(set));
    this.renderFolders();
  }
  expand(rel) {
    if (!rel) return;
    const set = new Set(this.prefs.libraryFolderExpanded || []);
    set.add('sub:' + rel);
    this.setPref('libraryFolderExpanded', Array.from(set));
  }

  /// 表に出ている順のフォルダのキー
  visibleFolderKeys() { return Array.from(this.folderList.querySelectorAll('.lib-frow')).map(e => e.dataset.key); }

  folderClicked(key, e) {
    let keys;
    if (e.ctrlKey || e.metaKey) {
      const cur = this.selectionKeys(this.selected).filter(k => k !== 'all');
      keys = cur.includes(key) ? cur.filter(k => k !== key) : cur.concat([key]);
      if (!keys.length) keys = [key];
    } else if (e.shiftKey && this.folderAnchor) {
      const order = this.visibleFolderKeys();
      const a = order.indexOf(this.folderAnchor), b = order.indexOf(key);
      keys = a < 0 || b < 0 ? [key] : order.slice(Math.min(a, b), Math.max(a, b) + 1);
    } else {
      keys = [key];
      this.folderAnchor = key;
      // 中にフォルダがあるもの: 選んでいて開いているものを押すと閉じ、閉じているものは選んで開く (Mac 版と同じ)
      const node = key.startsWith('sub:') ? this.findRel(key.slice(4)) : null;
      if (node && node.children && node.children.length) {
        const expanded = new Set(this.prefs.libraryFolderExpanded || []);
        const already = this.selected === key;
        if (expanded.has(key)) { if (already) this.toggleExpand(key); } else this.toggleExpand(key);
      }
    }
    // いくつも選んだら、そのどれかに入っているテキストを出す (「すべて」が入っていれば、すべて)
    this.select(keys.length > 1 && !keys.includes('all') ? 'multi:' + keys.join('\n') : (keys.includes('all') ? 'all' : keys[0]));
  }

  // ドラッグ: フォルダは線の位置で並べ替え、フォルダの上でその中へ。テキストをフォルダに落とすと移動
  bindFolderDrag(el, key) {
    el.addEventListener('dragstart', e => {
      if (!key.startsWith('sub:')) { e.preventDefault(); return; }
      e.dataTransfer.setData('application/x-satoru-folder', key.slice(4));
      e.dataTransfer.effectAllowed = 'move';
    });
    const where = e => {
      const r = el.getBoundingClientRect(), y = (e.clientY - r.top) / r.height;
      if (!key.startsWith('sub:')) return key === 'root' ? 'into' : null;
      return y < 0.28 ? 'before' : y > 0.72 ? 'after' : 'into';
    };
    el.addEventListener('dragover', e => {
      const types = Array.from(e.dataTransfer.types);
      const folder = types.includes('application/x-satoru-folder'), texts = types.includes('application/x-satoru-texts');
      if (!folder && !texts) return;
      // ファイルは、自分で作ったフォルダ (とメモ) にだけ置ける。もう全部そのフォルダにあるときは置けない
      const into = key === 'root' || key.startsWith('sub:');
      const rel = key === 'root' ? '' : key.slice(4);
      const w = texts ? (into && (this.dragPaths || []).some(p => this.group(p) !== rel) ? 'into' : null) : where(e);
      if (!w) return;
      e.preventDefault();
      el.classList.remove('drop-before', 'drop-after', 'drop-into');
      el.classList.add('drop-' + w);
    });
    el.addEventListener('dragleave', () => el.classList.remove('drop-before', 'drop-after', 'drop-into'));
    el.addEventListener('drop', e => {
      el.classList.remove('drop-before', 'drop-after', 'drop-into');
      const texts = e.dataTransfer.getData('application/x-satoru-texts');
      const targetRel = key === 'root' ? '' : key.startsWith('sub:') ? key.slice(4) : null;
      if (texts) {
        e.preventDefault();
        // ロックしたものは動かさない
        const paths = JSON.parse(texts).filter(p => this.group(p) !== targetRel);
        const locked = paths.filter(p => (this.itemFor(p) || {}).locked);
        if (locked.length) this.beep();
        const free = paths.filter(p => !locked.includes(p));
        if (targetRel !== null && free.length) this.moveTexts(free, targetRel);
        return;
      }
      const dragged = e.dataTransfer.getData('application/x-satoru-folder');
      if (!dragged) return;
      e.preventDefault();
      const w = where(e);
      if (!w) return;
      const rel = key.slice(4);
      const parentOf = r => (r.includes('/') ? r.slice(0, r.lastIndexOf('/')) : '');
      let parent, index = null;
      if (key === 'root') { parent = ''; index = 0; } else if (w === 'into') parent = rel;
      else {
        parent = parentOf(rel);
        const sibs = this.siblings(parent);
        index = sibs.indexOf(rel) + (w === 'after' ? 1 : 0);
      }
      this.dropFolder(dragged, parent, index);
    });
  }

  siblings(parent) {
    const node = parent ? this.findRel(parent) : null;
    return (parent ? (node ? node.children : []) : this.tree).map(n => n.rel);
  }

  async dropFolder(dragged, parent, index) {
    if (parent === dragged || parent.startsWith(dragged + '/')) return; // 自分の中へは入れない
    const parentOf = r => (r.includes('/') ? r.slice(0, r.lastIndexOf('/')) : '');
    const oldParent = parentOf(dragged);
    let rel = dragged;
    const before = this.siblings(parent);
    if (oldParent !== parent) {
      const r = await this.api.libraryMoveFolder(dragged, parent);
      if (r.status !== 'ok') { await alertBox(t('移せませんでした'), r.message); return; }
      rel = r.rel;
      this.relocateFolder(dragged, rel, r.from, r.to);
      this.expand(parent);
    }
    // 同じ親の中での並び
    const sibs = before.filter(x => x !== rel && x !== dragged);
    let at = index === null ? sibs.length : index;
    if (oldParent === parent) { const from = before.indexOf(dragged); if (from >= 0 && from < at) at -= 1; }
    sibs.splice(Math.max(0, Math.min(sibs.length, at)), 0, rel);
    this.setPref('libraryFolderOrder', sibs.concat((this.prefs.libraryFolderOrder || []).filter(x => !sibs.includes(x))));
    await this.reload();
  }

  /// 新規フォルダ。fromMenu = 右クリックの「この中に新規フォルダ…」(場所は決まっている)。
  /// 左上のボタン・「…」からで、自分で作ったフォルダを選んでいるときは、その中に作るか、いちばん上に作るかを選べる
  async newFolder(parent, fromMenu = false) {
    let name;
    if (!fromMenu && parent) {
      const r = await this.askPlace(parent);
      if (!r) return;
      name = r.name;
      if (!r.inside) parent = '';
    } else {
      name = await promptBox(t('新しいフォルダ'), parent ? t('「{name}」の中に作るフォルダの名前', { name: parent.split('/').pop() }) : t('フォルダの名前'), '');
    }
    if (name === null || !name.trim()) return;
    const r = await this.api.libraryCreateFolder(name, parent);
    if (r.status !== 'ok') { await alertBox(t('フォルダを作れませんでした'), r.message); return; }
    this.expand(parent);
    await this.reload();
    this.select('sub:' + r.rel);
  }

  /// 新規フォルダの名前と、作る場所 (選んでいるフォルダの中 / いちばん上に別のフォルダとして)
  async askPlace(parent) {
    const input = h('input', { type: 'text', class: 'wide', autofocus: true });
    const inside = h('input', { type: 'radio', name: 'lib-place', checked: true });
    const top = h('input', { type: 'radio', name: 'lib-place' });
    const ok = await modal({
      title: t('新しいフォルダ'),
      body: h('div', { class: 'lib-place' }, h('div', { class: 'modal-line' }, t('フォルダの名前')), input,
        h('label', { class: 'check-row top-gap' }, inside, t('「{name}」の中に作る', { name: parent.split('/').pop() })),
        h('label', { class: 'check-row' }, top, t('別のフォルダとして、いちばん上に作る'))),
      buttons: [{ label: 'OK', value: true, primary: true }, { label: t('キャンセル'), value: false, cancel: true }],
    });
    return ok ? { name: input.value, inside: inside.checked } : null;
  }

  folderMenu(key, x, y) {
    const picked = this.selectionKeys(this.selected);
    if (picked.length > 1 && picked.includes(key)) {
      const rels = picked.filter(k => k.startsWith('sub:')).map(k => k.slice(4));
      const nested = rels.filter(r => r.includes('/'));
      const items = [{ label: t('{n} 個のフォルダを選んでいます', { n: picked.length }), header: true }];
      if (rels.length) {
        items.push('sep');
        if (nested.length) items.push({ label: t('いちばん上の階層へ出す ({n} 個)', { n: nested.length }), action: () => this.moveFoldersToTop(nested) });
        items.push({ label: t('{n} 個のフォルダをごみ箱に入れる…', { n: rels.length }), action: () => this.trashFolders(rels) });
      }
      popupMenu(items, x, y);
      return;
    }
    const rel = key === 'root' ? '' : key.startsWith('sub:') ? key.slice(4) : null;
    const items = [];
    if (key.startsWith('ext:')) {
      const path = key.slice(4);
      items.push({ label: t('エクスプローラーで表示'), action: () => this.api.openPath(path) });
      // 開いたフォルダそのもの (いちばん上) だけ、一覧から外せる
      if (this.externalFolders.some(e => samePath(e, path))) items.push({ label: t('一覧から外す (フォルダは消さない)'), action: () => this.removeExternalFolder(path) });
      items.push('sep', { label: t('ほかの場所のフォルダを開く…'), action: () => this.openExternalFolder() });
      popupMenu(items, x, y);
      return;
    }
    if (rel !== null) {
      items.push({ label: rel ? t('この中に新規フォルダ…') : t('新規フォルダ…'), action: () => this.newFolder(rel, true) });
      items.push({ label: t('エクスプローラーで表示'), action: async () => { const p = await this.api.libraryFolderPath(rel); this.api.openPath(p); } });
    } else {
      items.push({ label: t('新規フォルダ…'), action: () => this.newFolder('', true) });
    }
    items.push({ label: t('ほかの場所のフォルダを開く…'), action: () => this.openExternalFolder() });
    if (key.startsWith('sub:')) {
      const cur = this.folderIcon(rel);
      items.push('sep');
      items.push({ label: t('名前を変更…'), action: () => this.renameFolder(rel) });
      items.push({ label: t('アイコン'), submenu: [
        ...FOLDER_SYMBOLS.map(([sym, label, emoji]) => ({ label: t(label), icon: emoji, checked: cur.symbol === sym, action: () => this.setFolderIcon(rel, { symbol: sym }) })),
        'sep',
        ...FOLDER_COLORS.map(([col, label, hex]) => ({ label: t(label), icon: h('span', { class: 'lib-swatch', style: { background: hex } }), checked: (cur.color || 'accent') === col, action: () => this.setFolderIcon(rel, { color: col }) })),
        'sep',
        { label: t('元に戻す'), action: () => this.setFolderIcon(rel, { reset: true }) },
      ] });
      if (rel.includes('/')) items.push({ label: t('いちばん上の階層へ出す'), action: () => this.moveFoldersToTop([rel]) });
      items.push({ label: t('ごみ箱に入れる'), action: () => this.trashFolders([rel]) });
    }
    popupMenu(items, x, y);
  }

  async renameFolder(rel) {
    const old = rel.split('/').pop();
    const name = await promptBox(t('フォルダの名前を変更'), t('新しい名前'), old);
    if (name === null || !name.trim() || name === old) return;
    const r = await this.api.libraryRenameFolder(rel, name);
    if (r.status !== 'ok') { await alertBox(t('名前を変えられませんでした'), r.message); return; }
    this.relocateFolder(rel, r.rel, r.from, r.to);
    await this.reload();
  }

  async moveFoldersToTop(rels) {
    // 深いものから出す (親を先に動かすと、子の道すじが変わるため)
    for (const rel of rels.slice().sort((a, b) => b.length - a.length)) {
      const r = await this.api.libraryMoveFolder(rel, '');
      if (r.status === 'ok') this.relocateFolder(rel, r.rel, r.from, r.to);
      else toast(r.message);
    }
    await this.reload();
  }

  /// フォルダをごみ箱に入れる (いくつでも。聞くのは 1 回。中のテキストも一緒に)
  async trashFolders(rels) {
    const tops = rels.filter(r => !rels.some(o => r !== o && r.startsWith(o + '/')));
    if (!tops.length) return;
    const body = withNames(t('中のテキストとフォルダも一緒にごみ箱に入ります。'), tops);
    const ok = await confirmBox(tops.length === 1 ? t('フォルダ「{name}」をごみ箱に入れますか？', { name: tops[0].split('/').pop() }) : t('{n} 個のフォルダをごみ箱に入れますか？', { n: tops.length }), body, t('ごみ箱に入れる'));
    if (!ok) return;
    // 中の文書を開いていれば、タブは閉じずに空の新しいテキストにする
    for (const tab of this.app.tabs.slice()) {
      const g = tab.path ? this.group(tab.path) : null;
      if (g !== null && tops.some(r => g === r || g.startsWith(r + '/'))) await this.app.makeBlank(tab);
    }
    const paths = await Promise.all(tops.map(r => this.api.libraryFolderPath(r)));
    const r = await this.api.libraryTrash(paths);
    if (r.failed && r.failed.length) await alertBox(t('ごみ箱に入れられませんでした'), r.failed.join('\n'));
    const keys = this.selectionKeys(this.selected);
    if (keys.some(k => tops.some(r2 => k === 'sub:' + r2 || k.startsWith('sub:' + r2 + '/')))) this.select('all');
    await this.reload();
  }

  // ---------- テキストの一覧 ----------

  renderList() {
    if (!this.list || this.loading) return;
    const sel = this.selected;
    const inGroup = this.items.filter(it => this.matches(it, sel));
    const q = this.query;
    this.rows = q ? inGroup.filter(it => String(it.title).toLowerCase().includes(q) || String(it.snippet || '').toLowerCase().includes(q)) : inGroup;
    const showFolder = sel === 'all' || sel === 'other' || sel === 'shared' || sel.startsWith('multi:');
    const cur = this.app.active && this.app.active.path;
    const scroll = this.list.scrollTop;
    const animate = this.listRendered && this.list.isConnected;
    this.list.textContent = '';
    if (!this.rows.length) {
      // 空のときは、文ではなくアイコンで (検索で見つからないときは虫めがね)
      this.list.append(q ? emptyState('find', 'NO MATCH')
        : emptyState('tray', 'NO DATA', hintText(t('「左上のボタン」で新規ファイル'), () => this.createBlank(), on => hop(this.newTextButton, on))));
    }
    let soonest = 0;
    this.rows.forEach((it, index) => {
      const isCur = cur && samePath(cur, it.path);
      const picked = this.picked.size > 1 ? this.picked.has(norm(it.path)) : isCur;
      // 1 行目: しるしとファイルの名前 (拡張子なし)、右はしに拡張子を小さく
      const title = h('div', { class: 'lib-rtitle' });
      if (it.pinned) title.append(h('span', { class: 'lib-pin', title: t('ピン固定') }, '📌'));
      if (it.locked) title.append(h('span', { class: 'lib-lock', title: t('ロック') }, '🔒'));
      const base = pathUtil.base(it.path);
      const dot = base.lastIndexOf('.');
      const ext = dot > 0 ? base.slice(dot + 1).toLowerCase() : '';
      title.append(modeMark(it.encrypted ? null : it.mode, !!it.sharedURL), h('span', { class: 'lib-rname' }, (it.encrypted ? '🔒 ' : '') + (dot > 0 ? base.slice(0, dot) : base)));
      if (ext) title.append(h('span', { class: 'lib-ext' }, ext));
      // 2 行目: 左にフォルダ名 (「すべて」などを見ているとき)、右に時間。本文のはじめは出さない
      const detail = h('div', { class: 'lib-rdetail' });
      if (showFolder) {
        const outside = it.group === null || it.group === undefined;
        const name = outside ? pathUtil.base(pathUtil.dir(it.path)) || t('ほかの場所') : it.group === '' ? this.rootName : it.group;
        detail.append(h('span', { class: 'lib-ftag', title: outside ? pathUtil.dir(it.path) : name }, name.split('/').pop()));
      }
      detail.append(h('span', { class: 'lib-space' }), h('span', { class: 'lib-time' }, dateText(it.modified)));
      // 新しく作ったファイル: アイコンの左に小さな点。はじめて出るときは上からすべり込む
      const left = newRemaining(it.created);
      if (left && (!soonest || left < soonest)) soonest = left;
      const fresh = left && !this.slid.has(norm(it.path));
      if (fresh) this.slid.add(norm(it.path));
      const row = h('div', {
        class: 'lib-row' + (picked ? ' current' : '') + (fresh && animate ? ' lib-slide-in' : ''), role: 'option', 'aria-selected': picked ? 'true' : 'false', draggable: 'true',
        'data-index': String(index),
        title: it.path + (it.sharedURL ? '\n' + t('公開中: {url}', { url: it.sharedURL }) : ''),
        onclick: e => this.rowClicked(it, e),
        oncontextmenu: e => { e.preventDefault(); this.rowMenu(it, e.clientX, e.clientY); },
      }, left ? newDot() : null, title, detail);
      row.addEventListener('dragstart', e => {
        if (e.shiftKey) { e.preventDefault(); return; }
        const paths = this.picked.size > 1 && this.picked.has(norm(it.path)) ? this.pickedPaths() : [it.path];
        this.dragPaths = paths;
        e.dataTransfer.setData('application/x-satoru-texts', JSON.stringify(paths));
        e.dataTransfer.effectAllowed = 'move';
      });
      row.addEventListener('dragend', () => { this.dragPaths = null; });
      this.list.append(row);
    });
    this.list.scrollTop = scroll;
    this.listRendered = true;
    this.scheduleNewExpiry(soonest);
  }

  pickedPaths() {
    if (this.picked.size > 0) return this.rows.filter(r => this.picked.has(norm(r.path))).map(r => r.path);
    const cur = this.app.active && this.app.active.path;
    return cur && this.rows.some(r => samePath(r.path, cur)) ? [cur] : [];
  }

  rowClicked(it, e) {
    this.list.focus({ preventScroll: true });
    if (this.swept && e.shiftKey) return; // Shift でなぞって選んだところ
    if (e.ctrlKey || e.metaKey) {
      if (this.picked.size === 0) { const cur = this.app.active && this.app.active.path; if (cur && this.rows.some(r => samePath(r.path, cur))) this.picked.add(norm(cur)); }
      const k = norm(it.path);
      if (this.picked.has(k)) this.picked.delete(k); else this.picked.add(k);
      this.anchor = it.path;
      this.renderList();
      return;
    }
    if (e.shiftKey) {
      const from = this.anchor || (this.app.active && this.app.active.path);
      const a = this.rows.findIndex(r => samePath(r.path, from)), b = this.rows.indexOf(it);
      this.picked.clear();
      for (let i = Math.min(a < 0 ? b : a, b); i <= Math.max(a, b); i++) this.picked.add(norm(this.rows[i].path));
      this.renderList();
      return;
    }
    this.picked.clear();
    this.anchor = it.path;
    this.open(it.path);
  }

  /// 一覧から開く (見ただけのタブなら、タブを増やさずにそのタブで開く)
  async open(path) {
    await this.app.openPath(path, { browse: true });
    this.renderList();
  }

  /// 空の「新規テキスト」を (選んでいるフォルダに) 作って一覧に入れ、開く (メモ帳の「新規メモ」と同じ)
  async createBlank() {
    // 新しい文書は、そのとき使っていた表示 (原稿用紙など) で始める
    const mode = this.prefs.lastPaperMode === 'genko' ? (this.prefs.genkoHorizontal ? 'genkoH' : 'genko') : '';
    const r = await this.api.libraryCreateBlank(this.targetRel(), mode);
    if (r.status !== 'ok') { await alertBox(t('作れませんでした'), r.message); return; }
    await this.reload();
    await this.app.openPath(r.path, { browse: true });
    this.app.focusEditor();
  }

  kindText(it) {
    const m = /\.([^.\\]+)$/.exec(it.path);
    const ext = m ? m[1].toLowerCase() : '';
    const type = !ext || ext === 'txt' ? t('テキスト') + (ext ? ' (.txt)' : '') : t('{ext} ファイル', { ext: ext.toUpperCase() }) + ' (.' + ext + ')';
    const parts = [it.encrypted ? t('暗号化された文書') : type];
    const names = { genko: '原稿用紙 (縦書き)', genkoH: '原稿用紙 (横書き)', a4: 'A4用紙' };
    if (names[it.mode]) parts.push(t(names[it.mode]));
    return parts.join(t('・'));
  }

  moveTargets(exclude) {
    const rels = this.allRels();
    return [['', t('メモ')]].concat(rels.map(r => [r, '　'.repeat(r.split('/').length - 1) + r.split('/').pop()])).filter(([r]) => r !== exclude);
  }

  async rowMenu(it, x, y) {
    // いくつも選んでいる中で右クリックしたら、まとめて扱うメニュー
    if (this.picked.size > 1 && this.picked.has(norm(it.path))) { this.multiMenu(this.pickedPaths(), x, y); return; }
    const app = this.app, share = app.share;
    let versions = [];
    const vOn = this.prefs.versionHistory !== false && this.prefs.libraryEnabled !== false;
    if (!it.encrypted && vOn) { try { versions = await this.api.versionList(it.path); } catch (e) { versions = []; } }
    const items = [
      { label: t('更新：{when}', { when: dateText(it.modified) + '  (' + stamp(it.modified) + ')' }), icon: '🕒', header: true },
      { label: t('種類：{kind}', { kind: this.kindText(it) }), icon: '📄', header: true },
    ];
    if (vOn) items.push({ label: versions.length ? t('版：{n} 個 (最新 {when})', { n: versions.length, when: dateText(versions[0].date) }) : t('版：まだありません'), icon: '🕘', header: true });
    const short = ms => new Date(ms).toLocaleString(i18n.language() === 'en' ? 'en-US' : 'ja-JP', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
    versions.slice(0, 5).forEach((v, n) => items.push({
      label: '    ' + (n === 0 ? t('いちばん新しい版') + ' ・ ' : '') + dateText(v.date) + '  (' + short(v.date) + ')',
      action: () => app.versions.show(it.path, v.key),
    }));
    if (versions.length > 5) items.push({ label: '    ' + t('ほか {n} 個…', { n: versions.length - 5 }), action: () => app.versions.show(it.path) });
    const shareOn = this.prefs.shareEnabled !== false;
    const rec = shareOn && share && share.recordFor(it.path);
    if (rec) {
      items.push({ label: t('公開中ページ表示（id:{id}）', { id: rec.id }), icon: '🌐', action: () => this.api.openExternal(rec.url) });
      items.push({ label: t('リンクをコピー'), icon: '📋', action: () => { this.api.copyText(rec.url); toast(t('リンクをコピーしました')); } });
      const content = await share.contentOf(it.path);
      items.push({ label: t('公開中のページを更新（変更を反映）'), icon: '🔄', disabled: !content || !share.needsUpdate(rec, content.text, content.mode), action: () => share.updateFile(it.path) });
      items.push({ label: t('公開の設定…'), icon: '⚙', action: () => share.editSettings(rec) });
      items.push({ label: t('公開をやめる'), icon: '⛔', action: () => share.confirmUnpublish(rec) });
    }
    items.push('sep',
      { label: t('開く'), action: () => this.open(it.path) },
      { label: t('エクスプローラーで表示'), action: () => this.api.reveal(it.path) },
      { label: t('ファイルの情報…'), action: () => this.showInfo(it) });
    if (!it.encrypted && share && shareOn) items.push({ label: t('リンクで公開共有…'), icon: '🔗', action: () => share.publishFile(it.path) });
    items.push('sep',
      { label: it.pinned ? t('ピン固定を外す') : t('ピン固定 (いちばん上に)'), icon: '📌', action: () => this.setPinned(!it.pinned, it.path) },
      { label: it.locked ? t('ロックを外す') : t('ロック (書き換え・削除を防ぐ)'), icon: '🔒', action: () => this.setLocked([it.path], !it.locked) },
      { label: t('名前を変更…'), disabled: it.locked, action: () => this.askRename(it.path) },
      { label: t('複製'), action: () => this.duplicate(it.path) },
      vOn ? { label: t('版の履歴…'), disabled: it.encrypted, action: () => app.versions.show(it.path) } : null,
      { label: t('移動'), disabled: it.locked, submenu: [
        ...this.moveTargets(it.group).map(([rel, name]) => ({ label: name, icon: '📁', action: () => this.moveTexts([it.path], rel) })),
        'sep',
        { label: t('ほかの場所を選ぶ…'), action: () => this.moveElsewhere([it.path]) },
      ] },
      'sep');
    for (let i = items.length - 1; i >= 0; i--) if (items[i] === null) items.splice(i, 1);
    if (!it.inFolder) items.push({ label: t('一覧から外す (ファイルは残す)'), action: () => this.forget(it.path) });
    items.push({ label: t('削除 (ごみ箱に入れる)'), icon: '🗑', disabled: it.locked, action: () => this.trash([it.path]) });
    popupMenu(items, x, y);
  }

  /// いくつも選んだときの右クリック (まとめて ピン・ロック・移動・削除)
  multiMenu(paths, x, y) {
    const pinned = paths.every(p => this.isPinned(p));
    const locked = paths.every(p => (this.itemFor(p) || {}).locked);
    popupMenu([
      { label: t('{n} 件を選んでいます', { n: paths.length }), icon: '☑', header: true },
      'sep',
      { label: pinned ? t('ピン固定を外す') : t('ピン固定 (いちばん上に)'), icon: '📌', action: () => { for (const p of paths) this.setPinned(!pinned, p); } },
      { label: locked ? t('ロックを外す') : t('ロック (書き換え・削除を防ぐ)'), icon: '🔒', action: () => this.setLocked(paths, !locked) },
      { label: t('移動'), submenu: [
        ...this.moveTargets(null).map(([rel, name]) => ({ label: name, icon: '📁', action: () => this.moveTexts(paths, rel) })),
        'sep',
        { label: t('ほかの場所を選ぶ…'), action: () => this.moveElsewhere(paths) },
      ] },
      'sep',
      { label: t('{n} 件を削除…', { n: paths.length }), icon: '🗑', action: () => this.trash(paths) },
    ], x, y);
  }

  async setLocked(paths, on) {
    for (const p of paths) {
      const tab = this.app.tabs.find(x => x.path && samePath(x.path, p));
      // 書きかけがあれば、ロックする前に保存しておく
      if (on && tab && tab.isDirty()) await this.app.save(tab);
      const r = await this.api.librarySetLocked(p, on);
      if (r.status !== 'ok') { toast(r.message); continue; }
      if (tab) this.app.setLocked(tab, on);
    }
    await this.reload();
  }

  async duplicate(path) {
    const r = await this.api.libraryDuplicate(path, t('{name} のコピー'), t('{name} のコピー {n}'));
    if (r.status !== 'ok') { await alertBox(t('複製できませんでした'), r.message); return; }
    if (!this.isInFolder(r.path)) this.remember(r.path);
    const mode = (this.itemFor(path) || {}).mode;
    if (mode) await this.setMode(r.path, mode);
    await this.reload();
  }

  /// 名前を聞いて、元のファイルの名前を変える (ファイル > 名前を変更…・一覧の右クリック)。中身はそのまま
  async askRename(path) {
    const name = pathUtil.base(path);
    const input = h('input', { type: 'text', class: 'wide', value: name, autofocus: true });
    const dot = name.lastIndexOf('.');
    const ok = await modal({
      title: t('ファイルの名前を変更'),
      body: h('div', {}, h('div', { class: 'modal-line' }, t('元のファイルの名前を変えます (中身はそのまま)。')), input),
      // 拡張子の前までを選んでおく (すぐ打ち直せるように)
      onOpen: () => setTimeout(() => { try { input.setSelectionRange(0, dot > 0 ? dot : name.length); } catch (e) { /* そのまま */ } }, 0),
      buttons: [{ label: t('変更'), value: true, primary: true }, { label: t('キャンセル'), value: false, cancel: true }],
    });
    if (!ok) return null;
    return this.renameTo(path, input.value);
  }

  /// 名前を変える。拡張子を書かなければ前のものを付ける。開いているタブは、そのまま新しい名前で編集を続けられる。
  /// ピン・表示・公開の記録・版の履歴もついていく。変えたら新しいパス
  async renameTo(path, newName) {
    let name = Array.from(String(newName || '').trim()).filter(c => c >= ' ' && c !== '/' && c !== ':' && c !== '\\').join('');
    if (!name || name.startsWith('.')) { this.beep(); return null; }
    const base = pathUtil.base(path);
    const oldDot = base.lastIndexOf('.');
    if (name.lastIndexOf('.') <= 0 && oldDot > 0) name += base.slice(oldDot);
    if (name === base) return path;
    const to = pathUtil.join(pathUtil.dir(path), name);
    if (!samePath(to, path)) {
      const info = await this.api.fileInfo(to);
      if (info && info.exists) { await alertBox(t('「{name}」はもうあります', { name }), t('ほかの名前にしてください。')); return null; }
    }
    const tab = this.app.tabs.find(x => x.path && samePath(x.path, path));
    if ((this.itemFor(path) || {}).locked || (tab && tab.locked)) { await alertBox(t('ロックしているので名前を変えられません'), ''); return null; }
    if (tab && tab.isDirty()) await this.app.save(tab);
    if (tab) clearTimeout(tab.autosaveTimer);
    const r = await this.api.renameEntry(path, name);
    if (r.status !== 'ok') { await alertBox(t('名前を変えられませんでした'), r.message); return null; }
    await this.api.versionRepath(path, r.path);
    const known = (this.prefs.libraryFiles || []).some(p => samePath(p, path));
    this.relocate(path, r.path);
    if (!known && !this.isInFolder(r.path)) this.remember(r.path);
    if (tab && tab === this.app.active) this.app.updateTabs();
    await this.reload();
    return r.path;
  }

  async moveTexts(paths, rel) {
    const dir = await this.api.libraryFolderPath(rel);
    await this.moveTo(paths, dir);
  }
  async moveElsewhere(paths) {
    const dirs = await this.api.openDialog({ directory: true, title: t('移す場所を選んでください'), defaultPath: pathUtil.dir(paths[0]) });
    if (dirs && dirs[0]) await this.moveTo(paths, dirs[0]);
  }
  /// 好きな場所へ移す。開いている文書は、そのまま新しい場所で編集を続けられる
  async moveTo(paths, dir) {
    for (const p of paths) {
      const it = this.itemFor(p);
      if (it && it.locked) { toast(t('ロックしているので移せません: {name}', { name: pathUtil.base(p) })); continue; }
      const tab = this.app.tabs.find(x => x.path && samePath(x.path, p));
      if (tab && tab.isDirty()) await this.app.save(tab);
      const r = await this.api.libraryMove(p, dir);
      if (r.status !== 'ok') { await alertBox(t('移せませんでした'), r.message); continue; }
      if (samePath(r.path, p)) continue;
      const pinned = this.isPinned(p);
      this.forget(p);
      this.relocate(p, r.path);
      if (!this.isInFolder(r.path)) this.remember(r.path);
      if (pinned) this.setPinned(true, r.path);
    }
    await this.reload();
  }

  /// ごみ箱に入れる (いくつでも。聞くのは 1 回。ロックしたものは入れない)
  async trash(paths) {
    const locked = paths.filter(p => (this.itemFor(p) || {}).locked);
    const targets = paths.filter(p => !(this.itemFor(p) || {}).locked);
    if (!targets.length) {
      await alertBox(t('ロックしているので削除できません'), t('右クリックの「ロックを外す」で外してから削除してください。'));
      return;
    }
    const body = withNames(t('ごみ箱に入れます。ごみ箱から戻すこともできます。')
      + (locked.length ? '\n\n' + t('ロックしている {n} 件は削除しません。', { n: locked.length }) : ''), targets.map(p => pathUtil.base(p)));
    const ok = await modal({
      title: targets.length === 1 ? t('「{name}」を削除しますか？', { name: pathUtil.base(targets[0]) }) : t('{n} 件のテキストを削除しますか？', { n: targets.length }),
      body, buttons: [{ label: t('削除'), value: true, primary: true }, { label: t('キャンセル'), value: false, cancel: true }],
    });
    if (!ok) return;
    // 開いている文書は、タブを閉じずに空の新しいテキストにする (保存は聞かない。ごみ箱から戻せる)
    for (const tab of this.app.tabs.slice()) if (tab.path && targets.some(p => samePath(p, tab.path))) await this.app.makeBlank(tab);
    const r = await this.api.libraryTrash(targets);
    for (const p of r.done || []) {
      this.forget(p);
      if (this.isPinned(p)) this.setPinned(false, p);
    }
    if (r.failed && r.failed.length) await alertBox(t('ごみ箱に入れられませんでした'), r.failed.join('\n'));
    this.picked.clear();
    await this.reload();
  }

  /// サムネで一覧: 本文の見本つきのカードを並べて見渡す (押すと開く)
  showGrid() {
    const old = document.getElementById('lib-grid');
    if (old) { old.remove(); return; }
    const rows = this.items.filter(it => this.matches(it, this.selected));
    const close = () => { grid.remove(); document.removeEventListener('keydown', onKey, true); this.app.focusEditor(); };
    const onKey = e => { if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); close(); } };
    const cards = rows.map(it => {
      const genkoMode = it.mode === 'genko' || it.mode === 'genkoH';
      const paper = h('div', { class: 'lib-card-paper' + (genkoMode ? ' genko' + (it.mode === 'genkoH' ? ' h' : '') : '') + (it.mode === 'a4' ? ' a4' : '') },
        h('div', { class: 'lib-card-text' }, it.encrypted ? '🔒 ' + t('暗号化された文書') : String(it.snippet || '').slice(0, genkoMode ? 400 : 300)));
      return h('div', { class: 'lib-card', title: it.path, onclick: () => { close(); this.open(it.path); }, oncontextmenu: e => { e.preventDefault(); this.rowMenu(it, e.clientX, e.clientY); } },
        paper, h('div', { class: 'lib-card-cap' }, modeMark(it.encrypted ? null : it.mode, !!it.sharedURL), h('span', { class: 'lib-rname' }, it.title)),
        h('div', { class: 'lib-card-time dim' }, dateText(it.modified)));
    });
    const grid = h('div', { id: 'lib-grid' },
      h('div', { class: 'lib-grid-head' }, h('span', { class: 'lib-title' }, t('サムネで一覧 ({n} 件)', { n: rows.length })), h('span', { class: 'lib-space' }), h('button', { onclick: close }, t('閉じる'))),
      h('div', { class: 'lib-grid-body' }, cards.length ? cards : h('div', { class: 'lib-empty' }, t('まだテキストがありません'))));
    document.getElementById('center').append(grid);
    document.addEventListener('keydown', onKey, true);
  }

  /// ファイルの情報: 場所・大きさ・字数・行数・文字コード・改行・表示・日時・公開・印
  async showInfo(it) {
    const r = await this.api.libraryReadText(it.path);
    if (r.status !== 'ok') { await alertBox(t('読めませんでした'), r.message); return; }
    const size = r.size < 1024 ? r.size + ' B' : r.size < 1048576 ? (r.size / 1024).toFixed(1) + ' KB' : (r.size / 1048576).toFixed(1) + ' MB';
    const lines = [[t('場所'), pathUtil.dir(it.path)], [t('大きさ'), size]];
    const mode = r.mode || this.modeFallback(it.path);
    if (r.encrypted) lines.push([t('中身'), '🔒 ' + t('暗号化された文書')]);
    else if (typeof r.text === 'string') {
      const text = r.text;
      lines.push([t('字数'), t('{n} 字', { n: Array.from(text.replace(/\n/g, '')).length })]);
      lines.push([t('行数'), t('{n} 行', { n: text === '' ? 0 : text.split('\n').length })]);
      const enc = menuDef.ENCODINGS.find(e => e[0] === r.encoding);
      lines.push([t('文字コード'), enc ? enc[1] : r.encoding]);
      lines.push([t('改行コード'), String(r.lineEnding || '').toUpperCase()]);
      if (mode === 'genko' || mode === 'genkoH') {
        const cols = genko.layout(text, { autoFormat: mode === 'genko' && !!this.prefs.genkoAutoFormat });
        lines.push([t('表示'), t(mode === 'genkoH' ? '原稿用紙 (横書き)' : '原稿用紙 (縦書き)') + '  ' + t('{n} 枚', { n: Math.max(1, Math.ceil(cols.length / genko.COLUMNS_PER_SHEET)) })]);
      } else lines.push([t('表示'), mode === 'a4' ? t('A4用紙') : t('標準エディタ')]);
    }
    lines.push([t('作成日時'), stamp(r.created)], [t('更新日時'), stamp(r.modified)]);
    const rec = this.app.share && this.app.share.recordFor(it.path);
    if (rec) lines.push([t('共有リンク'), rec.url + '\n' + this.app.share.visibilityName(rec.visibility) + (rec.expiresMs ? '  ' + t('期限 {when}', { when: stamp(rec.expiresMs) }) : '')]);
    const marks = [];
    if (this.isPinned(it.path)) marks.push('📌 ' + t('ピン固定'));
    if (r.locked) marks.push('🔒 ' + t('ロック'));
    if (marks.length) lines.push([t('印'), marks.join('  ')]);
    const table = h('div', { class: 'info-grid' }, lines.map(([k, v]) => [h('div', { class: 'dim' }, k), h('div', { class: 'selectable' }, v)]));
    const res = await modal({ title: pathUtil.base(it.path), body: table, width: 480,
      buttons: [{ label: t('閉じる'), value: false, primary: true, cancel: true }, { label: t('エクスプローラーで表示'), value: true }] });
    if (res) this.api.reveal(it.path);
  }
}

/// 並べ方のボタンの絵: 縦の線 (左右に並べる) / 横の線 (上下に並べる)。押すとその並びになる
function layoutSVG(stack) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('width', '15');
  svg.setAttribute('height', '15');
  svg.innerHTML = `<rect x="3" y="4.5" width="18" height="15" rx="2" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="${stack ? 'M3 12H21' : 'M12 4.5V19.5'}" stroke="currentColor" stroke-width="1.6"/>`;
  return svg;
}

function folderSVG() {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 16 16');
  svg.setAttribute('width', '14');
  svg.setAttribute('height', '14');
  svg.innerHTML = '<path d="M1.5 4V12.5a1 1 0 0 0 1 1h11a1 1 0 0 0 1-1V5.5a1 1 0 0 0-1-1H7.5L6 3H2.5a1 1 0 0 0-1 1z" fill="var(--fc)" fill-opacity="0.22" stroke="var(--fc)" stroke-width="1.2"/>';
  return svg;
}

/// 新しく作ったものの小さな点 (強調色)
function newDot() { return h('span', { class: 'lib-new-dot', title: t('新しく作りました') }); }

/// 読み込み中のしるし: ぐるぐると「読み込み中…」(時間がかかるときだけ出す)
function loadingMark() {
  return h('div', { class: 'lib-loading', hidden: true }, h('span', { class: 'lib-spinner', 'aria-hidden': 'true' }), h('span', {}, t('読み込み中…')));
}

/// ボタンをぴょんぴょん跳ねさせて場所を知らせる (on = false で止める)
function hop(btn, on) { if (btn) btn.classList.toggle('lib-hop', !!on); }

/// 案内の文: 「」で囲んだところは強調色の下線付きで見せる (「」は出さない)。押すと onClick、マウスを乗せると onHover(true/false)
export function hintText(text, onClick, onHover) {
  const el = h('div', { class: 'lib-hint' });
  String(text).split('「').forEach((part, i) => {
    const end = part.indexOf('」');
    if (i > 0 && end >= 0) {
      el.append(h('span', { class: 'lib-hint-link', role: 'button', tabindex: '0', onclick: onClick,
        onkeydown: e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onClick(); } },
        onmouseenter: () => onHover && onHover(true), onmouseleave: () => onHover && onHover(false) }, part.slice(0, end)));
      el.append(part.slice(end + 1));
    } else el.append(part);
  });
  return el;
}

/// 空のときのしるし: 大きめのアイコンと、小さな英字 (NO DATA など)。その下に案内
function emptyState(iconName, caption, hint) {
  return h('div', { class: 'lib-empty-state', 'aria-label': caption }, h('span', { class: 'lib-empty-icon' }, icon(iconName, 28)),
    h('div', { class: 'lib-empty-caption' }, caption), hint || null);
}

/// 確認の窓の本文: 説明と、いくつもあるときは左寄せの名前の並び (8 件まで + …)
function withNames(text, names) {
  const body = h('div', {}, ...String(text).split('\n').map(line => h('div', { class: 'modal-line' }, line || ' ')));
  if (names.length > 1) {
    body.append(h('div', { class: 'lib-names' }, ...names.slice(0, 8).map(n => h('div', {}, '・' + n)), names.length > 8 ? h('div', {}, '…') : null));
  }
  return body;
}
