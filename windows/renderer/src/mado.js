// 窓割り (Mac 版の Mado.swift・MadoSplit.swift と同じ考え方): ちがうタブの文書を、1 つのウインドウの中に左右・上下に並べる。
// (同じ文書を上下・左右に分けて見る「上下に分割 / 左右に分割」とは別のもの。どちらも一緒に使える)
//
// - 並べ方は木 (入れ子): 節は { dir: 'row' (左右) | 'col' (上下), kids: [...], sizes: [...] }、葉は { tab }
// - 画面 (葉) には見出し (名前と ×) を付ける。× はその画面の文書を閉じる (保存していなければ聞く)
// - 並べている文書のタブを選ぶと並びを出し、その画面にフォーカスを移す。並べていないタブを選ぶと、そのタブだけを出す (並びは覚えておく)
// - フォーカスのある画面の文書が「今の文書」(app.active)。ツールバー・メニュー・ステータスバーはその文書で動く
// - タブや見出しを編集画面の端へドラッグすると、そこに並べる (離す前に、入る所を薄い色で見せる)
import { h, popupMenu } from './dialogs';
import i18n from '../../shared/i18n';

const { t } = i18n;
/// 端に並べる判定の幅 (ウインドウの外側の縁)
const EDGE = 18;
/// ドラッグを始めるまでの動き
const DRAG_START = 6;

export class Mado {
  constructor(app) {
    this.app = app;
    this.root = null;
    this.focused = null;
    this.el = h('div', { id: 'mado-root' });
    app.el.editors.append(this.el);
    this.preview = h('div', { class: 'mado-drop' }, h('span', { class: 'mado-drop-label' }));
    app.el.editors.append(this.preview);
    this.preview.hidden = true;
    // 画面のどこを押しても (見出し・本文)、その画面にフォーカスを移す
    this.el.addEventListener('mousedown', e => this.paneTouched(e.target), true);
    this.el.addEventListener('focusin', e => this.paneTouched(e.target));
  }

  get enabled() { return this.app.prefs.madoEnabled !== false; }
  /// 並べているか
  get active() { return !!this.root; }
  /// 並べている文書 (左から / 上から)
  get tabs() { const out = []; walk(this.root, leaf => out.push(leaf.tab)); return out; }
  has(tab) { return !!tab && this.tabs.includes(tab); }
  /// 並びを出しているか (今の文書が並びの中にあるとき)
  get shown() { return this.active && this.has(this.app.active); }

  // ---------- メニューから ----------

  /// タブを左右 (row) / 上下 (col) に並べる。並べていなければ全部のタブ、並べていれば、まだ並べていないタブを外側に足して向きを変える
  splitTabs(dir) {
    const app = this.app;
    if (!this.enabled || app.tabs.length < 2) return false;
    if (!this.root) {
      this.root = { dir, kids: app.tabs.map(tab => ({ tab })), sizes: app.tabs.map(() => 1) };
      this.focused = app.active;
    } else {
      const extra = app.tabs.filter(x => !this.has(x));
      if (this.root.tab) this.root = { dir, kids: [this.root], sizes: [1] };
      for (const tab of extra) { this.root.kids.push({ tab }); this.root.sizes.push(1); }
      this.root.dir = dir;
      this.equalize(this.root);
      if (!this.has(this.focused)) this.focused = this.tabs[0];
    }
    this.render();
    app.activate(this.has(app.active) ? app.active : this.focused);
    return true;
  }

  /// 「この画面を左右 / 上下に分割」の相手: 今のタブの次の、まだ並べていないタブ (端なら先頭へ回る)
  partner() {
    const app = this.app, list = app.tabs, i = list.indexOf(app.active);
    for (let k = 1; k < list.length; k++) {
      const x = list[(i + k) % list.length];
      if (x !== app.active && !this.has(x)) return x;
    }
    return null;
  }

  /// フォーカスのある画面を左右 (row) / 上下 (col) に分けて、相手のタブを並べる。並べていなければ、今のタブと相手で並べる
  splitFocused(dir, target) {
    const app = this.app;
    if (!this.enabled) return false;
    const side = dir === 'row' ? 'right' : 'below';
    // 並べていないタブを見ているとき: そのタブを、並びのフォーカスのある画面の隣に入れる
    if (this.root && !this.shown && !target) {
      this.insert(app.active, this.focused, side);
      this.render();
      app.activate(app.active);
      return true;
    }
    const other = this.partner();
    if (!other) return false;
    if (!this.root) {
      this.root = { dir, kids: [{ tab: app.active }, { tab: other }], sizes: [1, 1] };
    } else {
      // 並びを出していないとき (並べていないタブを見ているとき) は、今のタブを並びの端に足してから分ける
      const at = target || app.active;
      if (!this.has(at)) this.insert(at, null, side);
      this.insert(other, at, side);
    }
    this.render();
    app.activate(other);
    return true;
  }

  /// 並べるのをやめて、タブに戻す
  unsplit(activate = true) {
    if (!this.root) return;
    const focus = this.has(this.app.active) ? this.app.active : this.focused;
    for (const tab of this.tabs) this.app.el.editors.append(tab.el);
    this.root = null;
    this.focused = null;
    this.render();
    if (activate && focus && this.app.tabs.includes(focus)) this.app.activate(focus);
  }

  /// 次 (d = 1) / 前 (d = -1) の画面へ
  move(d) {
    const list = this.tabs;
    if (!this.shown || list.length < 2) return;
    const i = list.indexOf(this.app.active);
    this.app.activate(list[(i + d + list.length) % list.length]);
  }

  /// 画面の大きさをそろえる (node を省くと全部)
  equalize(node) {
    const all = !node;
    const go = n => { if (!n || n.tab) return; n.sizes = n.kids.map(() => 1); if (all) n.kids.forEach(go); };
    go(node || this.root);
    if (all) this.render();
  }

  /// この画面だけをタブに戻す (文書は閉じない)
  returnToTab(tab) {
    const next = this.remove(tab);
    this.app.el.editors.append(tab.el);
    this.app.activate(tab);
    return next;
  }

  // ---------- 木の操作 ----------

  /// tab を並びから外す (閉じたとき・タブに戻すとき)。残りが 1 つになったら並べるのをやめる。次にフォーカスする文書を返す
  remove(tab) {
    if (!this.has(tab)) return null;
    const list = this.tabs, i = list.indexOf(tab);
    const nextFocus = list[i + 1] || list[i - 1] || null;
    this.root = prune(this.root, tab);
    if (this.root && this.root.tab) {
      // 1 つだけ残った: 並べるのをやめる
      const last = this.root.tab;
      this.app.el.editors.append(last.el);
      this.root = null;
      this.focused = null;
      this.render();
      return last;
    }
    if (this.focused === tab) this.focused = nextFocus;
    this.render();
    return nextFocus;
  }

  /// tab を、画面 at の side ('left' 'right' 'above' 'below') に入れる。at が無ければ、いちばん外側の端に
  insert(tab, at, side) {
    if (tab === at) return;
    if (this.has(tab)) this.root = prune(this.root, tab);
    const dir = side === 'left' || side === 'right' ? 'row' : 'col';
    const before = side === 'left' || side === 'above';
    const leaf = { tab };
    if (!this.root) { this.root = { dir, kids: before ? [leaf, { tab: at }] : [{ tab: at }, leaf], sizes: [1, 1] }; return; }
    if (this.root.tab) this.root = { dir, kids: [this.root], sizes: [1] };
    if (!at || !this.has(at)) {
      // 端に並べる: 外側が同じ向きならその端に足す。違えば全体を包む
      if (this.root.dir !== dir) this.root = { dir, kids: [this.root], sizes: [this.root.kids.length] };
      const share = this.root.sizes.reduce((a, b) => a + b, 0) / Math.max(1, this.root.kids.length);
      if (before) { this.root.kids.unshift(leaf); this.root.sizes.unshift(share); } else { this.root.kids.push(leaf); this.root.sizes.push(share); }
      return;
    }
    const found = findParent(this.root, at);
    const { parent, index } = found;
    if (parent && parent.dir === dir) {
      // 同じ向きの並び: at の隣に入れて、at の大きさを 2 つで分ける
      const half = parent.sizes[index] / 2;
      parent.sizes[index] = half;
      parent.kids.splice(before ? index : index + 1, 0, leaf);
      parent.sizes.splice(before ? index : index + 1, 0, half);
    } else {
      // 向きが違う: at を新しい節に置き換えて、その中を分ける
      const node = { dir, kids: before ? [leaf, { tab: at }] : [{ tab: at }, leaf], sizes: [1, 1] };
      if (parent) parent.kids[index] = node; else this.root = node;
    }
  }

  // ---------- 画面 ----------

  /// 今の文書が変わった (app.activate から)。並びの中の文書なら並びを出して、その画面に印を付ける
  activated(tab) {
    const show = this.has(tab);
    if (show) this.focused = tab;
    this.app.el.editors.classList.toggle('mado-on', show);
    for (const p of this.el.querySelectorAll('.mado-pane')) p.classList.toggle('focused', show && p.tab === tab);
  }

  /// 名前・保存の印が変わった: 見出しを合わせる
  titlesChanged() {
    if (!this.root) return;
    for (const p of this.el.querySelectorAll('.mado-pane')) {
      const tab = p.tab, title = (tab.enc ? '🔒 ' : '') + tab.name + (tab.isDirty() ? ' ' + t('＊') : '');
      const label = p.querySelector('.mado-title');
      if (label.textContent !== title) label.textContent = title;
      label.title = (tab.remote && tab.remote.url) || tab.path || tab.name;
    }
  }

  /// 木から画面を作り直す (文書の画面 tab.el は作り直さず、入れ物を移すだけ)
  render() {
    const app = this.app;
    this.el.textContent = '';
    if (this.root) this.el.append(this.build(this.root));
    this.activated(app.active);
    this.titlesChanged();
    for (const tab of this.tabs) { tab.editor.remeasure(); if (tab.paper && tab.paper.relayout) tab.paper.relayout(); }
    requestAnimationFrame(() => { for (const tab of app.tabs) tab.editor.remeasure(); app.updateRuler(); });
    app.pushMenuState();
  }

  build(node) {
    if (node.tab) return this.pane(node.tab);
    const box = h('div', { class: 'mado-node ' + node.dir });
    node.kids.forEach((kid, i) => {
      if (i > 0) box.append(this.divider(node, i));
      const el = this.build(kid);
      el.style.flex = `${node.sizes[i] || 1} 1 0`;
      box.append(el);
    });
    return box;
  }

  pane(tab) {
    const app = this.app;
    const close = h('button', { class: 'mado-close', title: t('この画面の文書を閉じる'), onmousedown: e => e.stopPropagation(), onclick: () => app.closeTab(tab) }, '✕');
    const head = h('div', { class: 'mado-head' },
      h('span', { class: 'mado-title' }),
      close);
    head.addEventListener('mousedown', e => {
      if (e.button !== 0 || e.target === close) return;
      e.preventDefault();
      this.trackDrag(tab, e, () => app.activate(tab));
    });
    head.addEventListener('dblclick', () => this.equalize());
    head.addEventListener('contextmenu', async e => {
      e.preventDefault();
      app.activate(tab);
      const x = e.clientX, y = e.clientY;
      // いちばん上に、テキスト一覧で右クリックしたときと同じ、このファイルのメニュー (Mac 版と同じ)
      const it = tab.path && app.library && app.library.itemFor(tab.path);
      const top = it ? await app.library.rowMenuItems(it) : [];
      popupMenu(top.length ? [...top, 'sep', ...this.paneMenu(tab)] : this.paneMenu(tab), x, y);
    });
    const body = h('div', { class: 'mado-body' });
    body.append(tab.el);
    const p = h('div', { class: 'mado-pane' }, head, body);
    p.tab = tab;
    return p;
  }

  /// 見出しの右クリックのメニュー
  paneMenu(tab) {
    const can = !!this.partner();
    return [
      { label: t('この画面を左右に分割'), disabled: !can, action: () => this.splitFocused('row', tab) },
      { label: t('この画面を上下に分割'), disabled: !can, action: () => this.splitFocused('col', tab) },
      { label: t('画面の大きさをそろえる'), action: () => this.equalize() },
      'sep',
      { label: t('タブに戻す'), action: () => this.returnToTab(tab) },
      { label: t('並べるのをやめる (タブに戻す)'), action: () => this.unsplit() },
      'sep',
      { label: t('閉じる'), action: () => this.app.closeTab(tab) },
    ];
  }

  /// 画面と画面のあいだの区切り。ドラッグで大きさを変える
  divider(node, i) {
    const d = h('div', { class: 'mado-divider' });
    d.addEventListener('mousedown', e => {
      if (e.button !== 0) return;
      e.preventDefault();
      const a = d.previousSibling, b = d.nextSibling;
      const horizontal = node.dir === 'row';
      const ra = a.getBoundingClientRect(), rb = b.getBoundingClientRect();
      const total = horizontal ? ra.width + rb.width : ra.height + rb.height;
      const start = horizontal ? e.clientX : e.clientY;
      const sum = node.sizes[i - 1] + node.sizes[i];
      const first = horizontal ? ra.width : ra.height;
      const moveTo = ev => {
        const pos = Math.max(60, Math.min(total - 60, first + ((horizontal ? ev.clientX : ev.clientY) - start)));
        node.sizes[i - 1] = sum * pos / total;
        node.sizes[i] = sum - node.sizes[i - 1];
        a.style.flex = `${node.sizes[i - 1]} 1 0`;
        b.style.flex = `${node.sizes[i]} 1 0`;
      };
      const up = () => {
        window.removeEventListener('mousemove', moveTo, true);
        window.removeEventListener('mouseup', up, true);
        for (const tab of this.tabs) tab.editor.remeasure();
        this.app.updateRuler();
      };
      window.addEventListener('mousemove', moveTo, true);
      window.addEventListener('mouseup', up, true);
    });
    return d;
  }

  /// 画面の中を押した・フォーカスが入った: その画面の文書を今の文書にする
  paneTouched(target) {
    const p = target && target.closest ? target.closest('.mado-pane') : null;
    if (p && p.tab && p.tab !== this.app.active && this.app.tabs.includes(p.tab)) this.app.activate(p.tab, { keepFocus: true });
  }

  // ---------- ドラッグ (タブのバー・見出しから) ----------

  /// 押したまま動かしたらドラッグ。動かさずに離したら click()
  trackDrag(tab, down, click) {
    let dragging = false, ghost = null;
    const app = this.app;
    const source = down.target && down.target.closest ? down.target.closest('.tab, .mado-head') : null;
    const fromBar = !!(source && source.classList.contains('tab'));
    const grab = source ? (() => { const r = source.getBoundingClientRect(); return { x: down.clientX - r.left, y: down.clientY - r.top }; })() : { x: 10, y: 10 };
    const move = e => {
      if (!dragging) {
        if (Math.abs(e.clientX - down.clientX) + Math.abs(e.clientY - down.clientY) < DRAG_START) return;
        if (!this.enabled || app.tabs.length < 2) return;
        dragging = true;
        document.body.classList.add('mado-dragging');
        // つまんだタブ (見出し) の写しを持ち上げて、マウスについてこさせる
        if (source) {
          const r = source.getBoundingClientRect();
          ghost = source.cloneNode(true);
          ghost.classList.add('mado-ghost');
          Object.assign(ghost.style, { width: r.width + 'px', height: r.height + 'px' });
          document.body.append(ghost);
          source.classList.add('mado-drag-source');
        }
      }
      if (ghost) { ghost.style.left = (e.clientX - grab.x) + 'px'; ghost.style.top = (e.clientY - grab.y) + 'px'; }
      // タブのバーの上なら、タブの並びを入れ替える
      if (fromBar && !this.has(tab) && this.overBar(e.clientX, e.clientY)) { this.reorder(tab, source, e.clientX); this.showDrop(null); return; }
      this.showDrop(this.dropAt(tab, e.clientX, e.clientY));
    };
    const up = e => {
      window.removeEventListener('mousemove', move, true);
      window.removeEventListener('mouseup', up, true);
      if (!dragging) { click(); return; }
      document.body.classList.remove('mado-dragging');
      if (ghost) ghost.remove();
      if (source) source.classList.remove('mado-drag-source');
      if (fromBar && !this.has(tab) && this.overBar(e.clientX, e.clientY)) { this.showDrop(null); app.activate(tab); app.updateTabs(); return; }
      const drop = this.dropAt(tab, e.clientX, e.clientY);
      this.showDrop(null);
      if (drop) this.dropped(tab, drop);
      else app.updateTabs();
    };
    window.addEventListener('mousemove', move, true);
    window.addEventListener('mouseup', up, true);
  }

  overBar(x, y) {
    const b = this.app.el.tabs.getBoundingClientRect();
    return x >= b.left && x <= b.right && y >= b.top - 4 && y <= b.bottom + 4;
  }

  /// タブのバーの x の所へ、tab を移す (並び app.tabs と、バーの中の要素の両方)
  reorder(tab, el, x) {
    const app = this.app, bar = app.el.tabs;
    const els = Array.from(bar.children).filter(c => c.classList.contains('tab'));
    const from = app.tabs.indexOf(tab);
    if (from < 0 || els.length !== app.tabs.length) return;
    // 自分以外のタブのうち、まん中が x より左にあるものの数 = 入る場所
    const others = els.filter(c => c !== el);
    const to = others.filter(c => { const r = c.getBoundingClientRect(); return r.left + r.width / 2 < x; }).length;
    if (to === from) return;
    app.tabs.splice(from, 1);
    app.tabs.splice(to, 0, tab);
    bar.insertBefore(el, others[to] || null);
  }

  /// その場所で離したら、どこに入るか: { at: 画面の文書 (null なら外側の端), side, rect, label }。入れられなければ null
  dropAt(tab, x, y) {
    const app = this.app, area = app.el.editors.getBoundingClientRect();
    // 並べている画面の見出しをタブのバーに持っていったら、タブに戻す
    const bar = app.el.tabs.getBoundingClientRect();
    if (this.has(tab) && y >= bar.top && y <= bar.bottom && x >= bar.left && x <= bar.right) {
      return { back: true, rect: bar, label: t('離すとタブに戻ります') };
    }
    if (x < area.left || x > area.right || y < area.top || y > area.bottom) return null;
    const shown = this.shown;
    // ウインドウの外側の縁: いちばん外側の端に並べる
    if (shown) {
      const edge = sideNear(area, x, y, EDGE);
      if (edge) return { at: null, side: edge, rect: half(area, edge, 0.3), label: t('端に並べる') };
    }
    let at = null, r = area;
    if (shown) {
      const p = Array.from(this.el.querySelectorAll('.mado-pane')).find(el => { const b = el.getBoundingClientRect(); return x >= b.left && x <= b.right && y >= b.top && y <= b.bottom; });
      if (!p) return null;
      at = p.tab;
      r = p.getBoundingClientRect();
    } else {
      at = app.active;
      // 今見ているタブそのものをドラッグしたら、となりのタブと並べる (Mac 版と同じ)
      if (at === tab) at = this.partner();
    }
    if (!at || at === tab) return null;
    // 画面の中で、いちばん近い辺の側に半分ずつ
    const side = nearestSide(r, x, y);
    return { at, side, rect: half(r, side, 0.5), label: null };
  }

  showDrop(drop) {
    const pv = this.preview;
    if (!drop) { pv.hidden = true; return; }
    const area = this.app.el.editors.getBoundingClientRect(), r = drop.rect;
    // タブのバーは編集画面の外なので、上にはみ出して出す
    Object.assign(pv.style, { left: (r.left - area.left) + 'px', top: (r.top - area.top) + 'px', width: r.width + 'px', height: r.height + 'px' });
    pv.firstChild.textContent = drop.label || '';
    pv.hidden = false;
  }

  dropped(tab, drop) {
    if (drop.back) { this.returnToTab(tab); return; }
    if (!this.root) {
      this.root = null;
      this.insert(tab, drop.at, drop.side);
    } else {
      this.insert(tab, drop.at, drop.side);
      if (this.root && this.root.tab) { this.unsplit(); return; }
    }
    this.render();
    this.app.activate(tab);
  }
}

// ---------- 木をたどる ----------

function walk(node, fn) {
  if (!node) return;
  if (node.tab) { fn(node); return; }
  for (const k of node.kids) walk(k, fn);
}

/// tab の葉の親と、その中の番号
function findParent(node, tab, parent = null, index = -1) {
  if (node.tab) return node.tab === tab ? { parent, index } : null;
  for (let i = 0; i < node.kids.length; i++) {
    const r = findParent(node.kids[i], tab, node, i);
    if (r) return r;
  }
  return null;
}

/// tab の葉を除いた木 (子が 1 つになった節は、その子に置き換える。同じ向きの節が続いたら 1 つにまとめる)
function prune(node, tab) {
  if (!node) return null;
  if (node.tab) return node.tab === tab ? null : node;
  const kids = [], sizes = [];
  node.kids.forEach((k, i) => {
    const r = prune(k, tab);
    if (!r) return;
    if (!r.tab && r.dir === node.dir) {
      const total = r.sizes.reduce((a, b) => a + b, 0) || 1;
      r.kids.forEach((kk, j) => { kids.push(kk); sizes.push(node.sizes[i] * r.sizes[j] / total); });
    } else { kids.push(r); sizes.push(node.sizes[i]); }
  });
  if (!kids.length) return null;
  if (kids.length === 1) return kids[0];
  return { dir: node.dir, kids, sizes };
}

/// 外側の縁 (幅 w) にあれば、その辺
function sideNear(r, x, y, w) {
  if (x - r.left < w) return 'left';
  if (r.right - x < w) return 'right';
  if (y - r.top < w) return 'above';
  if (r.bottom - y < w) return 'below';
  return null;
}

/// いちばん近い辺 (縦横の比をそろえて比べる)
function nearestSide(r, x, y) {
  const fx = (x - r.left) / Math.max(1, r.width), fy = (y - r.top) / Math.max(1, r.height);
  const d = [['left', fx], ['right', 1 - fx], ['above', fy], ['below', 1 - fy]];
  d.sort((a, b) => a[1] - b[1]);
  return d[0][0];
}

/// r の side 側の f の部分
function half(r, side, f) {
  const out = { left: r.left, top: r.top, width: r.width, height: r.height };
  if (side === 'left') out.width = r.width * f;
  if (side === 'right') { out.width = r.width * f; out.left = r.right - out.width; }
  if (side === 'above') out.height = r.height * f;
  if (side === 'below') { out.height = r.height * f; out.top = r.bottom - out.height; }
  return out;
}
