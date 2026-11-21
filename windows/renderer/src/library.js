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
    this.el = document.getElementById('library-pane');
    this.build();
    // 「5 分前」などを、1 分ごとに描き直す
    setInterval(() => { if (!this.el.hidden) this.renderList(); }, 60000);
  }

  get prefs() { return this.app.prefs; }
  get selected() { return this.prefs.librarySelectedGroup || 'all'; }

  async init() {
    try { const info = await this.api.libraryInfo(); this.root = info.root || ''; this.historyRoot = info.history || ''; } catch (e) { this.root = ''; }
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
    const list = [path].concat((this.prefs.libraryFiles || []).filter(p => !samePath(p, path))).slice(0, MAX_KNOWN);
    this.setPref('libraryFiles', list);
    this.changed();
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
    let items = [], tree = [];
    try {
      [items, tree] = await Promise.all([
        this.api.libraryItems(this.prefs.libraryFiles || [], this.prefs.libraryFolderOrder || []),
        this.api.libraryTree(this.prefs.libraryFolderOrder || []),
      ]);
    } catch (e) { console.warn(e); }
    if (gen !== this.gen) return;
    const share = this.app.share;
    for (const it of items || []) {
      it.pinned = this.isPinned(it.path);
      if (!it.mode && !it.encrypted) it.mode = this.modeFallback(it.path);
      const r = share && this.prefs.shareEnabled !== false ? share.recordFor(it.path) : null;
      it.sharedURL = r ? r.url : null;
    }
    // 開いているタブの中身 (保存前でも、表示は今のもの)
    for (const tab of this.app.tabs) {
      const it = tab.path && (items || []).find(x => samePath(x.path, tab.path));
      if (it) it.mode = this.app.modeString(tab);
    }
    this.items = (items || []).sort((a, b) => (a.pinned !== b.pinned ? (a.pinned ? -1 : 1) : b.modified - a.modified));
    this.tree = tree || [];
    // 消えたフォルダを選んでいたら「すべて」に戻す
    const keys = this.selectionKeys(this.selected);
    if (keys.some(k => k.startsWith('sub:') && !this.findRel(k.slice(4)))) this.select('all');
    this.renderFolders();
    this.renderList();
  }

  itemFor(path) { return this.items.find(x => samePath(x.path, path)) || null; }
  findRel(rel, nodes = this.tree) {
    for (const n of nodes) { if (n.rel === rel) return n; const c = this.findRel(rel, n.children || []); if (c) return c; }
    return null;
  }
  allRels(nodes = this.tree, out = []) { for (const n of nodes) { out.push(n.rel); this.allRels(n.children || [], out); } return out; }
  selectionKeys(sel) { return sel.startsWith('multi:') ? sel.slice(6).split('\n').filter(Boolean) : [sel]; }
  matches(item, sel) {
    if (sel.startsWith('multi:')) return this.selectionKeys(sel).some(k => this.matches(item, k));
    if (sel === 'all') return true;
    if (sel === 'root') return item.group === '';
    if (sel === 'other') return item.group === null || item.group === undefined;
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
  }

  // ---------- 画面 ----------

  build() {
    this.folderList = h('div', { class: 'lib-folders', role: 'tree', 'aria-label': t('フォルダ') });
    this.folderPane = h('div', { class: 'lib-folder-pane' },
      h('div', { class: 'lib-head' }, h('span', { class: 'lib-title' }, t('フォルダ'))),
      this.folderList,
      h('button', { class: 'lib-add', title: t('新規フォルダ (選んでいるフォルダの中に作る)'), onclick: () => this.newFolder(this.selected.startsWith('sub:') ? this.selected.slice(4) : '') }, '＋ ' + t('フォルダ')));
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
    // 上下 (フォルダの欄が上、テキストの一覧が下) ⇔ 左右 (フォルダの欄が左) の切り替え
    this.layoutButton = h('button', { class: 'icon-button lib-layout', title: t('上下 / 左右に並べ替える'), 'aria-label': t('上下 / 左右に並べ替える'),
      onclick: () => { this.setPref('libraryOneColumn', !this.oneColumn); this.arrange(); } });
    this.listPane = h('div', { class: 'lib-list-pane' },
      h('div', { class: 'lib-head' },
        h('button', { class: 'icon-button', title: t('新しいテキスト'), onclick: () => this.createBlank() }, icon('new', 15)),
        h('span', { class: 'lib-title' }, t('テキスト')),
        h('span', { class: 'lib-space' }),
        h('button', { class: 'icon-button', title: t('検索'), onclick: () => this.toggleSearch() }, icon('find', 15)),
        this.layoutButton,
        h('button', { class: 'icon-button', title: t('テキスト一覧を閉じる'), onclick: () => this.app.setPref('libraryVisible', false) }, '✕')),
      this.search, this.list);
    const resizer = (pane, key, min, max) => {
      const r = h('div', { class: 'lib-resizer', title: t('ドラッグで幅を変える') });
      r.addEventListener('mousedown', e => {
        e.preventDefault();
        const target = typeof pane === 'function' ? pane() : pane;
        const start = e.clientX, w0 = target.getBoundingClientRect().width;
        const move = ev => { target.style.width = Math.max(min, Math.min(max, w0 + ev.clientX - start)) + 'px'; this.app.scheduleRuler(); };
        const up = () => { window.removeEventListener('mousemove', move); window.removeEventListener('mouseup', up); this.setPref(key, Math.round(target.getBoundingClientRect().width)); };
        window.addEventListener('mousemove', move);
        window.addEventListener('mouseup', up);
      });
      return r;
    };
    this.column = h('div', { class: 'lib-column' });
    this.stackDivider = h('div', { class: 'lib-stack-divider', 'aria-hidden': 'true' }); // 上下のときの、フォルダの欄と一覧の間の細い仕切り
    window.addEventListener('resize', () => this.fitFolders());
    this.folderResizer = resizer(this.folderPane, 'libraryFolderWidth', 60, 420);
    this.listResizer = resizer(() => (this.oneColumn ? this.column : this.listPane), 'libraryListWidth', 110, 640);
    this.arrange();
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
    const counts = {};
    let other = 0;
    for (const it of this.items) { if (it.group === null || it.group === undefined) other++; else counts[it.group] = (counts[it.group] || 0) + 1; }
    const expanded = new Set(this.prefs.libraryFolderExpanded || []);
    const keys = new Set(this.selectionKeys(this.selected));
    const list = this.folderList;
    const scroll = list.scrollTop;
    list.textContent = '';
    const row = (key, name, badge, count, depth, node) => {
      const hasKids = node && node.children && node.children.length;
      const open = hasKids && expanded.has(key);
      const el = h('div', {
        class: 'lib-frow' + (keys.has(key) ? ' current' : ''), role: 'treeitem', 'data-key': key, draggable: key.startsWith('sub:') ? 'true' : null,
        style: { paddingLeft: (4 + depth * 10) + 'px' },
        onclick: e => this.folderClicked(key, e),
        oncontextmenu: e => { e.preventDefault(); this.folderMenu(key, e.clientX, e.clientY); },
      },
      h('span', { class: 'lib-twist' + (open ? ' open' : ''), onclick: e => { if (!hasKids) return; e.stopPropagation(); this.toggleExpand(key); } }, hasKids ? icon('chevron', 10) : ''),
      badge, h('span', { class: 'lib-fname' }, name), h('span', { class: 'lib-count' }, String(count)));
      this.bindFolderDrag(el, key);
      list.append(el);
      if (open) for (const c of node.children) row('sub:' + c.rel, c.name, this.folderBadge(c.rel), counts[c.rel] || 0, depth + 1, c);
    };
    row('all', t('すべて'), h('span', { class: 'lib-ficon' }, icon('library', 14)), this.items.length, 0, null);
    row('root', t('メモ'), this.folderBadge(null, 'folder'), counts[''] || 0, 0, null);
    for (const n of this.tree) row('sub:' + n.rel, n.name, this.folderBadge(n.rel), counts[n.rel] || 0, 0, n);
    row('other', t('ほかの場所'), h('span', { class: 'lib-ficon' }, '📄'), other, 0, null);
    list.scrollTop = scroll;
    this.fitFolders();
  }

  /// 上下のとき、フォルダの欄の高さを中身 (見出し + 見えているフォルダの行) に合わせる。80px 以上、欄の高さの半分まで
  fitFolders() {
    if (!this.oneColumn || !this.folderPane || !this.folderPane.isConnected) return;
    const pane = this.folderPane;
    const head = pane.querySelector('.lib-head');
    const add = pane.querySelector('.lib-add');
    const addStyle = add ? getComputedStyle(add) : null;
    const addH = add ? add.offsetHeight + parseFloat(addStyle.marginTop) + parseFloat(addStyle.marginBottom) : 0;
    const natural = (head ? head.offsetHeight : 0) + this.folderList.scrollHeight + addH;
    const total = this.column.clientHeight;
    if (!total || !natural) return; // まだ画面に出ていない
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
      const w = texts ? (key === 'root' || key.startsWith('sub:') ? 'into' : null) : where(e);
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
        if (targetRel !== null) this.moveTexts(JSON.parse(texts), targetRel);
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

  async newFolder(parent) {
    const name = await promptBox(t('新しいフォルダ'), parent ? t('「{name}」の中に作るフォルダの名前', { name: parent.split('/').pop() }) : t('フォルダの名前'), '');
    if (name === null || !name.trim()) return;
    const r = await this.api.libraryCreateFolder(name, parent);
    if (r.status !== 'ok') { await alertBox(t('フォルダを作れませんでした'), r.message); return; }
    this.expand(parent);
    await this.reload();
    this.select('sub:' + r.rel);
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
    if (rel !== null) {
      items.push({ label: rel ? t('この中に新規フォルダ…') : t('新規フォルダ…'), action: () => this.newFolder(rel) });
      items.push({ label: t('エクスプローラーで表示'), action: async () => { const p = await this.api.libraryFolderPath(rel); this.api.openPath(p); } });
    } else {
      items.push({ label: t('新規フォルダ…'), action: () => this.newFolder('') });
    }
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
    const body = t('中のテキストとフォルダも一緒にごみ箱に入ります。') + (tops.length > 1 ? '\n\n' + tops.slice(0, 8).map(r => '・' + r).join('\n') : '');
    const ok = await confirmBox(tops.length === 1 ? t('フォルダ「{name}」をごみ箱に入れますか？', { name: tops[0].split('/').pop() }) : t('{n} 個のフォルダをごみ箱に入れますか？', { n: tops.length }), body, t('ごみ箱に入れる'));
    if (!ok) return;
    // 中の文書を開いていれば閉じる
    for (const tab of this.app.tabs.slice()) {
      const g = tab.path ? this.group(tab.path) : null;
      if (g !== null && tops.some(r => g === r || g.startsWith(r + '/'))) await this.app.closeTab(tab, { noAsk: true });
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
    if (!this.list) return;
    const sel = this.selected;
    const inGroup = this.items.filter(it => this.matches(it, sel));
    const q = this.query;
    this.rows = q ? inGroup.filter(it => String(it.title).toLowerCase().includes(q) || String(it.snippet || '').toLowerCase().includes(q)) : inGroup;
    const showFolder = sel === 'all' || sel.startsWith('multi:');
    const cur = this.app.active && this.app.active.path;
    const scroll = this.list.scrollTop;
    this.list.textContent = '';
    if (!this.rows.length) {
      this.list.append(h('div', { class: 'lib-empty' }, q ? t('見つかりません') : t('まだテキストがありません')));
    }
    for (const it of this.rows) {
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
        const name = it.group === null || it.group === undefined ? pathUtil.base(pathUtil.dir(it.path)) || t('ほかの場所') : it.group === '' ? t('メモ') : it.group;
        detail.append(h('span', { class: 'lib-ftag', title: it.group === null || it.group === undefined ? pathUtil.dir(it.path) : name }, name.split('/').pop()));
      }
      detail.append(h('span', { class: 'lib-space' }), h('span', { class: 'lib-time' }, dateText(it.modified)));
      const row = h('div', {
        class: 'lib-row' + (picked ? ' current' : ''), role: 'option', 'aria-selected': picked ? 'true' : 'false', draggable: 'true',
        title: it.path + (it.sharedURL ? '\n' + t('公開中: {url}', { url: it.sharedURL }) : ''),
        onclick: e => this.rowClicked(it, e),
        oncontextmenu: e => { e.preventDefault(); this.rowMenu(it, e.clientX, e.clientY); },
      }, title, detail);
      row.addEventListener('dragstart', e => {
        const paths = this.picked.size > 1 && this.picked.has(norm(it.path)) ? this.pickedPaths() : [it.path];
        e.dataTransfer.setData('application/x-satoru-texts', JSON.stringify(paths));
        e.dataTransfer.effectAllowed = 'move';
      });
      this.list.append(row);
    }
    this.list.scrollTop = scroll;
  }

  pickedPaths() {
    if (this.picked.size > 0) return this.rows.filter(r => this.picked.has(norm(r.path))).map(r => r.path);
    const cur = this.app.active && this.app.active.path;
    return cur && this.rows.some(r => samePath(r.path, cur)) ? [cur] : [];
  }

  rowClicked(it, e) {
    this.list.focus({ preventScroll: true });
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
    const body = t('ごみ箱に入れます。ごみ箱から戻すこともできます。')
      + (targets.length > 1 ? '\n\n' + targets.slice(0, 8).map(p => '・' + pathUtil.base(p)).join('\n') + (targets.length > 8 ? '\n…' : '') : '')
      + (locked.length ? '\n\n' + t('ロックしている {n} 件は削除しません。', { n: locked.length }) : '');
    const ok = await modal({
      title: targets.length === 1 ? t('「{name}」を削除しますか？', { name: pathUtil.base(targets[0]) }) : t('{n} 件のテキストを削除しますか？', { n: targets.length }),
      body, buttons: [{ label: t('削除'), value: true, primary: true }, { label: t('キャンセル'), value: false, cancel: true }],
    });
    if (!ok) return;
    // 開いている文書なら先に閉じる (保存は聞かない。ごみ箱から戻せる)
    for (const tab of this.app.tabs.slice()) if (tab.path && targets.some(p => samePath(p, tab.path))) await this.app.closeTab(tab, { noAsk: true });
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
