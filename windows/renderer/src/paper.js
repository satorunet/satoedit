// 用紙モード: 原稿用紙 (A4 横・20×20・中央の余白とふりがな枠つき) と A4 用紙。印刷・PDF 用の HTML もここで作る
import { h } from './dialogs';
import genko from '../../shared/genko';

const { SHEET, ROWS, COLUMNS_PER_SHEET } = genko;
const MINCHO = '"Yu Mincho", "YuMincho", "MS Mincho", "ＭＳ 明朝", "Hiragino Mincho ProN", "Noto Serif CJK JP", serif';

function esc(s) {
  return s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

/// 1 枚ぶんの中身 (枠線 + 文字)。sel = [from, to) は選択、comp = [from, to) は日本語入力の変換中
/// ふりがなの一覧 → 列ごとの置き場所 { 列番号: [{ row, rows, text }] }。列をまたぐ言葉は、字数に応じて読みを分ける
function placeRuby(columns, ruby) {
  const byColumn = {};
  if (!ruby || !ruby.length) return byColumn;
  const where = new Map();
  columns.forEach((col, ci) => col.offs.forEach((off, r) => { if (off >= 0) where.set(off, [ci, r]); }));
  for (const item of ruby) {
    const cells = [];
    for (let off = item.from; off < item.to; off++) { const w = where.get(off); if (w) cells.push(w); }
    if (!cells.length) continue;
    const segments = [];
    for (const [ci, r] of cells) {
      const last = segments[segments.length - 1];
      if (last && last.column === ci) last.rows += 1; else segments.push({ column: ci, row: r, rows: 1 });
    }
    const chars = Array.from(item.reading);
    let used = 0;
    segments.forEach((seg, i) => {
      const take = i === segments.length - 1 ? chars.length - used : Math.round(chars.length * seg.rows / cells.length);
      const text = chars.slice(used, used + take).join('');
      used += take;
      if (text) (byColumn[seg.column] = byColumn[seg.column] || []).push({ row: seg.row, rows: seg.rows, text });
    });
  }
  return byColumn;
}

const U = v => `calc(${+v.toFixed(3)} * var(--u))`;
/// 縦書きの用紙の上の四角 (mm) → 置く場所の style (横書きは回す)
function box(x, y, w, hgt, horizontal, size) {
  const r = genko.rect(x, y, w, hgt, horizontal);
  return `left:${U(r.left)};top:${U(r.top)};width:${U(r.width)};height:${U(r.height)}` + (size ? `;font-size:${U(size)}` : '');
}

function sheetHTML(sheet, index, total, sel, comp, rubyByColumn, horizontal) {
  let out = genko.sheetSVG(horizontal);
  for (let k = 0; k < sheet.length; k++) {
    const col = sheet[k];
    const x = genko.columnXOf(k, horizontal);
    for (const rb of (rubyByColumn && rubyByColumn[index * COLUMNS_PER_SHEET + k]) || []) {
      const height = rb.rows * SHEET.cell;
      const size = Math.min(SHEET.ruby * 0.8, (height - 0.4) / Array.from(rb.text).length);
      out += `<span class="gk-ruby" style="${box(x + SHEET.cell, SHEET.top + rb.row * SHEET.cell, SHEET.ruby, height, horizontal, size)}">${esc(rb.text)}</span>`;
    }
    for (let r = 0; r < ROWS; r++) {
      const ch = col.cells[r];
      if (ch === null) continue;
      const off = col.offs[r];
      let cls = 'gk';
      if (sel && off >= sel[0] && off < sel[1]) cls += ' sel';
      if (comp && off >= comp[0] && off < comp[1]) cls += ' comp';
      if (ch.length === 1 && ch.charCodeAt(0) < 0x2000) cls += ' half';
      out += `<span class="${cls}" style="${box(x, SHEET.top + r * SHEET.cell, SHEET.cell, SHEET.cell, horizontal)}">${ch === ' ' || ch === '\t' ? '' : esc(ch)}</span>`;
    }
    // 何も書いていない列を選んだとき (改行だけの段落) も選択が見えるように
    if (sel && col.last && col.to >= sel[0] && col.to < sel[1] && col.from >= 0) {
      const n = col.cells.reduce((m, c, r) => (c !== null ? r + 1 : m), col.first);
      if (n < ROWS) out += `<span class="gk sel" style="${box(x, SHEET.top + n * SHEET.cell, SHEET.cell, SHEET.cell, horizontal)}"></span>`;
    }
  }
  // 用紙の下の小さな表示 (枠の左下と右下)
  const span = genko.gridSpan(horizontal);
  const frame = genko.rect(span.x, SHEET.top, span.width, SHEET.gridHeight, horizontal);
  const sheetW = horizontal ? SHEET.height : SHEET.width;
  const labelTop = frame.top + frame.height + 2;
  out += `<span class="gk-label" style="left:${U(frame.left)};top:${U(labelTop)}">20 × 20</span>`;
  out += `<span class="gk-label right" style="right:${U(sheetW - frame.left - frame.width)};top:${U(labelTop)}">No. ${index + 1} / ${total}</span>`;
  return out;
}

const SHEET_CSS = `
.genko-sheet { position: relative; width: calc(${SHEET.width} * var(--u)); height: calc(${SHEET.height} * var(--u)); background: #fffdf7; overflow: hidden; }
.genko-sheet.h { width: calc(${SHEET.height} * var(--u)); height: calc(${SHEET.width} * var(--u)); }
.genko-sheet svg { position: absolute; left: 0; top: 0; width: 100%; height: 100%; pointer-events: none; }
.gk { position: absolute; display: flex; align-items: center; justify-content: center;
  font-family: ${MINCHO}; font-size: calc(${SHEET.cell * 0.72} * var(--u)); line-height: 1; color: #111; writing-mode: vertical-rl; text-orientation: upright; white-space: pre; pointer-events: none; }
.gk.half, .genko-sheet.h .gk { writing-mode: horizontal-tb; }
.gk-ruby { position: absolute; display: flex; align-items: center; justify-content: center; font-family: ${MINCHO}; line-height: 1; color: #333; writing-mode: vertical-rl; text-orientation: upright; white-space: nowrap; pointer-events: none; }
.genko-sheet.h .gk-ruby { writing-mode: horizontal-tb; }
.gk-label { position: absolute; font: calc(2.6 * var(--u)) "Segoe UI", "Yu Gothic UI", sans-serif; color: ${SHEET.line}; pointer-events: none; }
.genko-sheet.h .gk-label { color: ${genko.LINE_H}; }
`;

/// 原稿用紙の編集画面。文章そのものは見えない入力欄 (textarea) が持ち、マス目には 1 文字ずつ置いて見せる。
/// こうすると、画面と印刷で必ず同じマスに同じ字が入る
export class GenkoEditor {
  constructor({ parent, text, prefs, onInput, onSelection, furigana, horizontal }) {
    this.prefs = prefs;
    this.horizontal = !!horizontal; // 横書きの原稿用紙 (A4 縦・緑の線・自動整形なし)
    this.onInput = onInput || (() => {});
    this.onSelection = onSelection || (() => {});
    this.furigana = furigana || null; // 文章 → ふりがなの一覧を返す関数
    this.ruby = [];
    this.rubyText = '';
    this.columns = [];
    this.cache = [];
    this.comp = null;
    this.input = h('textarea', { class: 'genko-input', spellcheck: 'false', autocomplete: 'off', wrap: 'off', 'aria-label': '原稿用紙の本文' });
    this.caret = h('div', { class: 'genko-caret' });
    this.sheetsEl = h('div', { class: 'genko-sheets' });
    this.dom = h('div', { class: 'genko-scroll' + (this.horizontal ? ' horizontal' : '') }, h('style', {}, SHEET_CSS), this.sheetsEl, this.input);
    if (this.horizontal) this.caret.classList.add('h');
    parent.append(this.dom);
    this.input.value = text || '';
    this.input.setSelectionRange(0, 0);
    this.bind();
    this.resizer = new ResizeObserver(() => this.fit());
    this.resizer.observe(this.dom);
    this.fit();
    this.render();
    this.refreshRuby();
  }

  /// 自動整形は縦書きだけ (Mac 版と同じ)
  autoFormat() { return !this.horizontal && !!this.prefs.genkoAutoFormat; }

  /// ふりがなを取り直す (入力が止まってから少し待つ)
  refreshRuby() {
    clearTimeout(this.rubyTimer);
    if (!this.prefs.genkoFurigana || !this.furigana) {
      if (this.ruby.length) { this.ruby = []; this.render(); }
      return;
    }
    this.rubyTimer = setTimeout(async () => {
      const text = this.input.value;
      let list = [];
      try { list = await this.furigana(text); } catch (e) { list = []; }
      if (this.input.value !== text || !this.prefs.genkoFurigana) return; // 待っている間に書き換わった
      this.ruby = list || [];
      this.rubyText = text;
      this.render();
    }, 350);
  }

  /// 書き換えた場所より後ろのふりがなは位置がずれるので、取り直すまで消しておく
  trimRuby() {
    const now = this.input.value, old = this.rubyText;
    if (!this.ruby.length || now === old) return;
    let same = 0;
    const n = Math.min(now.length, old.length);
    while (same < n && now.charCodeAt(same) === old.charCodeAt(same)) same += 1;
    this.ruby = this.ruby.filter(r => r.to < same);
    this.rubyText = now;
  }

  bind() {
    const input = this.input;
    input.addEventListener('input', () => { this.trimRuby(); this.render(); this.onInput(input.value); this.reveal(); this.refreshRuby(); });
    input.addEventListener('compositionstart', () => { this.comp = [input.selectionStart, input.selectionStart]; });
    input.addEventListener('compositionupdate', () => { requestAnimationFrame(() => this.render()); });
    input.addEventListener('compositionend', e => {
      const start = this.comp ? this.comp[0] : null;
      this.comp = null;
      if (this.prefs.genkoFullWidth && start !== null && e.data) {
        const full = genko.toFullWidth(e.data);
        if (full !== e.data && input.value.substr(start, e.data.length) === e.data) {
          input.setSelectionRange(start, start + e.data.length);
          document.execCommand('insertText', false, full);
        }
      }
      this.render();
    });
    input.addEventListener('beforeinput', e => {
      if (e.isComposing || e.inputType !== 'insertText' || !e.data) return;
      if (this.prefs.genkoFullWidth) {
        const full = genko.toFullWidth(e.data);
        if (full !== e.data) { e.preventDefault(); document.execCommand('insertText', false, full); }
      }
    });
    input.addEventListener('keydown', e => this.keydown(e));
    input.addEventListener('focus', () => { this.dom.classList.add('focused'); this.render(); });
    input.addEventListener('blur', () => { this.dom.classList.remove('focused'); });
    this.onSelectionChange = () => { if (document.activeElement === input) { this.render(); this.onSelection(); } };
    document.addEventListener('selectionchange', this.onSelectionChange);

    let dragging = false;
    this.sheetsEl.addEventListener('mousedown', e => {
      if (e.button !== 0) return;
      e.preventDefault();
      const off = this.offsetFromPoint(e.clientX, e.clientY);
      if (off === null) { input.focus({ preventScroll: true }); return; }
      const anchor = e.shiftKey ? this.anchor() : off;
      this.select(anchor, off);
      input.focus({ preventScroll: true });
      dragging = true;
      this.dragAnchor = anchor;
    });
    this.onMouseMove = e => {
      if (!dragging) return;
      const off = this.offsetFromPoint(e.clientX, e.clientY);
      if (off !== null) this.select(this.dragAnchor, off);
    };
    this.onMouseUp = () => { dragging = false; };
    window.addEventListener('mousemove', this.onMouseMove);
    window.addEventListener('mouseup', this.onMouseUp);
  }

  destroy() {
    clearTimeout(this.rubyTimer);
    document.removeEventListener('selectionchange', this.onSelectionChange);
    window.removeEventListener('mousemove', this.onMouseMove);
    window.removeEventListener('mouseup', this.onMouseUp);
    this.resizer.disconnect();
    this.dom.remove();
  }

  // カーソルは head (動くほう) と anchor (動かないほう) で持つ
  head() { return this.input.selectionDirection === 'backward' ? this.input.selectionStart : this.input.selectionEnd; }
  anchor() { return this.input.selectionDirection === 'backward' ? this.input.selectionEnd : this.input.selectionStart; }
  select(anchor, head) {
    const n = this.input.value.length;
    anchor = Math.max(0, Math.min(n, anchor));
    head = Math.max(0, Math.min(n, head));
    this.input.setSelectionRange(Math.min(anchor, head), Math.max(anchor, head), head < anchor ? 'backward' : 'forward');
    this.render();
    this.onSelection();
  }

  keydown(e) {
    if (e.isComposing) return;
    const input = this.input, text = input.value;
    const move = to => {
      e.preventDefault();
      const target = Math.max(0, Math.min(text.length, to));
      this.select(e.shiftKey ? this.anchor() : target, target);
      this.reveal();
    };
    const head = this.head();
    const step = dir => {
      // 絵文字などの 2 つ組の文字は 1 文字として動く
      let p = head + dir;
      if (p > 0 && p < text.length) {
        const c = text.charCodeAt(p);
        if (c >= 0xDC00 && c <= 0xDFFF) p += dir;
      }
      return p;
    };
    const cell = genko.caretCell(this.columns, head);
    const nextColumn = () => (cell.column + 1 >= this.columns.length ? move(text.length) : move(genko.offsetAt(this.columns, cell.column + 1, cell.row)));
    const prevColumn = () => (cell.column === 0 ? move(0) : move(genko.offsetAt(this.columns, cell.column - 1, cell.row)));
    // 縦書きは 上下 = 字、左 = 次の列。横書きは 左右 = 字、下 = 次の行
    const key = this.horizontal ? ({ ArrowLeft: 'prev', ArrowRight: 'next', ArrowUp: 'up', ArrowDown: 'down' })[e.key]
      : ({ ArrowUp: 'prev', ArrowDown: 'next', ArrowRight: 'up', ArrowLeft: 'down' })[e.key];
    switch (key || e.key) {
      case 'prev': return move(step(-1));
      case 'next': return move(step(1));
      case 'down': return nextColumn();
      case 'up': return prevColumn();
      case 'Home': return move(e.ctrlKey ? 0 : this.columns[cell.column].from);
      case 'End': return move(e.ctrlKey ? text.length : this.columns[cell.column].to);
      case 'PageDown': return move(genko.offsetAt(this.columns, Math.min(this.columns.length - 1, cell.column + COLUMNS_PER_SHEET), cell.row));
      case 'PageUp': return move(genko.offsetAt(this.columns, Math.max(0, cell.column - COLUMNS_PER_SHEET), cell.row));
      case 'Enter': {
        // 自動整形: 名前 (2 列目) を書き終えて改行したら、1 列空けて 4 列目から本文を始める
        const atEnd = input.selectionStart === input.selectionEnd && head === text.length;
        const paragraph = text.slice(0, head).split('\n').length - 1;
        if (this.autoFormat() && atEnd && paragraph === 1 && head > 0 && text[head - 1] !== '\n') {
          e.preventDefault();
          document.execCommand('insertText', false, '\n\n');
          return undefined;
        }
        // 自動整形を使わないとき: 改行のたび、次の段落の頭に全角スペースを入れる (Mac 版と同じ)
        if (!this.autoFormat() && this.prefs.genkoAutoIndent && input.selectionStart === input.selectionEnd) {
          e.preventDefault();
          document.execCommand('insertText', false, '\n\u3000');
        }
        return undefined;
      }
      default: return undefined;
    }
  }

  fit() {
    const w = this.dom.clientWidth;
    if (!w) return;
    const u = Math.max(2.2, Math.min(4.6, (w - 56) / (this.horizontal ? SHEET.height : SHEET.width)));
    this.u = u;
    this.dom.style.setProperty('--u', u.toFixed(3) + 'px');
    this.placeCaret();
  }

  offsetFromPoint(x, y) {
    const sheets = Array.from(this.sheetsEl.children);
    let best = -1;
    for (let i = 0; i < sheets.length; i++) {
      const r = sheets[i].getBoundingClientRect();
      if (y >= r.top - 12 && y <= r.bottom + 12) { best = i; break; }
    }
    if (best < 0) return null;
    const r = sheets[best].getBoundingClientRect();
    const px = (x - r.left) / this.u, py = (y - r.top) / this.u;
    const xmm = this.horizontal ? SHEET.width - py : px, ymm = this.horizontal ? px : py;
    let k = 0, distance = Infinity;
    for (let i = 0; i < COLUMNS_PER_SHEET; i++) {
      const cx = genko.columnXOf(i, this.horizontal) + SHEET.pitch / 2;
      if (Math.abs(cx - xmm) < distance) { distance = Math.abs(cx - xmm); k = i; }
    }
    const column = best * COLUMNS_PER_SHEET + k;
    if (column >= this.columns.length) return this.input.value.length;
    const row = Math.max(0, Math.min(ROWS, Math.floor((ymm - SHEET.top) / SHEET.cell + 0.35)));
    return genko.offsetAt(this.columns, column, row);
  }

  render() {
    const input = this.input;
    this.columns = genko.layout(input.value, { autoFormat: this.autoFormat() });
    const sheets = genko.sheets(this.columns);
    const sel = input.selectionStart !== input.selectionEnd ? [input.selectionStart, input.selectionEnd] : null;
    const comp = this.comp ? [this.comp[0], input.selectionEnd] : null;
    const rubyByColumn = this.prefs.genkoFurigana ? placeRuby(this.columns, this.ruby) : null;
    while (this.sheetsEl.children.length > sheets.length) { this.sheetsEl.lastChild.remove(); this.cache.pop(); }
    sheets.forEach((sheet, i) => {
      const html = sheetHTML(sheet, i, sheets.length, sel, comp, rubyByColumn, this.horizontal);
      let el = this.sheetsEl.children[i];
      if (!el) { el = h('div', { class: 'genko-sheet' + (this.horizontal ? ' h' : '') }); this.sheetsEl.append(el); this.cache[i] = null; }
      if (this.cache[i] !== html) { el.innerHTML = html; this.cache[i] = html; }
    });
    this.placeCaret();
  }

  placeCaret() {
    if (!this.columns.length || !this.sheetsEl.children.length) return;
    const cell = genko.caretCell(this.columns, this.head());
    const sheetIndex = Math.floor(cell.column / COLUMNS_PER_SHEET);
    const sheet = this.sheetsEl.children[Math.min(sheetIndex, this.sheetsEl.children.length - 1)];
    if (!sheet) return;
    const x = genko.columnXOf(cell.column % COLUMNS_PER_SHEET, this.horizontal), y = SHEET.top + Math.min(cell.row, ROWS) * SHEET.cell;
    let left, top;
    if (this.horizontal) {
      // 横書き: マスの左に縦の線
      const r = genko.rect(x, y, SHEET.cell, SHEET.cell, true);
      left = r.left; top = r.top;
      this.caret.style.left = `calc(${left} * var(--u) - 1px)`;
      this.caret.style.top = `calc(${top + 0.4} * var(--u))`;
      this.caret.style.height = `calc(${SHEET.cell - 0.8} * var(--u))`;
      this.caret.style.width = '';
    } else {
      left = x; top = y;
      this.caret.style.left = `calc(${x + 0.4} * var(--u))`;
      this.caret.style.top = `calc(${y} * var(--u) - 1px)`;
      this.caret.style.width = `calc(${SHEET.cell - 0.8} * var(--u))`;
      this.caret.style.height = '';
    }
    if (this.caret.parentNode !== sheet) sheet.append(this.caret);
    // 入力欄をカーソルのそばに置く (日本語入力の候補がそこに出る)
    this.input.style.left = (sheet.offsetLeft + left * this.u) + 'px';
    this.input.style.top = (sheet.offsetTop + top * this.u) + 'px';
    // 点滅を最初からやり直す
    this.caret.style.animation = 'none';
    void this.caret.offsetWidth;
    this.caret.style.animation = '';
  }

  reveal() { this.caret.scrollIntoView({ block: 'nearest', inline: 'nearest' }); }

  getText() { return this.input.value; }
  setText(text) {
    if (this.input.value === text) return;
    this.input.value = text;
    this.input.setSelectionRange(0, 0);
    this.ruby = [];
    this.render();
    this.refreshRuby();
  }
  setPrefs(prefs) { this.prefs = prefs; this.render(); this.refreshRuby(); }
  setReadOnly(on) { this.input.readOnly = !!on; }
  focus() { this.input.focus({ preventScroll: true }); }
  hasFocus() { return document.activeElement === this.input; }
  selectionText() { return this.input.value.slice(this.input.selectionStart, this.input.selectionEnd); }
  selectionRange() { return { from: this.input.selectionStart, to: this.input.selectionEnd }; }
  replaceRange(from, to, text) { this.focus(); this.input.setSelectionRange(from, to); document.execCommand('insertText', false, text); this.select(from, from + text.length); }
  replaceSelection(text) { this.focus(); document.execCommand('insertText', false, text); }
  insertAtCursorEnd(text) { this.focus(); this.input.setSelectionRange(this.input.selectionEnd, this.input.selectionEnd); document.execCommand('insertText', false, text); }
  selectAll() { this.focus(); this.input.select(); this.render(); }
  undo() { this.focus(); document.execCommand('undo'); }
  redo() { this.focus(); document.execCommand('redo'); }

  /// ステータスバーに出す情報 (文字数は改行を数えない)
  info() {
    const text = this.input.value;
    const cell = genko.caretCell(this.columns, this.head());
    return {
      chars: Array.from(text.replace(/\n/g, '')).length,
      sheets: Math.max(1, Math.ceil(this.columns.length / COLUMNS_PER_SHEET)),
      columns: this.columns.length,
      sheet: Math.floor(cell.column / COLUMNS_PER_SHEET) + 1,
      column: (cell.column % COLUMNS_PER_SHEET) + 1, row: Math.min(ROWS, cell.row + 1),
      selected: Array.from(this.selectionText().replace(/\n/g, '')).length,
    };
  }
}

/// A4 用紙の編集画面 (横書き 40 字 × 36 行の見た目)。段落ごとに寄せを付けられる
export class A4Editor {
  constructor({ parent, text, prefs, onInput, onSelection }) {
    this.prefs = prefs;
    this.onInput = onInput || (() => {});
    this.onSelection = onSelection || (() => {});
    this.text = h('div', { class: 'a4-text', contenteditable: 'true', spellcheck: 'false', 'aria-label': 'A4 用紙の本文' });
    this.dom = h('div', { class: 'a4-scroll' }, h('div', { class: 'a4-paper' }, this.text));
    parent.append(this.dom);
    this.fill(text || '', {});
    this.text.addEventListener('input', e => {
      if (e.isComposing) return;
      this.repair();
      this.format();
      this.onInput(this.getText());
    });
    this.text.addEventListener('compositionend', () => { this.repair(); this.format(); this.onInput(this.getText()); });
    this.text.addEventListener('paste', e => {
      e.preventDefault();
      const data = (e.clipboardData.getData('text/plain') || '').replace(/\r\n?/g, '\n');
      this.insertText(data);
    });
    this.text.addEventListener('drop', e => e.preventDefault());
    this.onSelectionChange = () => { if (this.hasFocus()) this.onSelection(); };
    document.addEventListener('selectionchange', this.onSelectionChange);
  }

  destroy() {
    document.removeEventListener('selectionchange', this.onSelectionChange);
    this.dom.remove();
  }

  fill(text, manual) {
    this.text.textContent = '';
    text.split('\n').forEach((line, i) => {
      const p = h('p', {}, line === '' ? h('br') : line);
      if (manual[i]) p.dataset.align = manual[i];
      this.text.append(p);
    });
    this.format();
  }

  /// 編集のはずみで段落 (<p>) の外に文字が出たり、全部消えたりしたら直す
  repair() {
    const root = this.text;
    if (!root.firstChild) {
      const p = h('p', {}, h('br'));
      root.append(p);
      const range = document.createRange();
      range.setStart(p, 0);
      range.collapse(true);
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
      return;
    }
    for (const node of Array.from(root.childNodes)) {
      if (node.nodeType === 1 && node.tagName === 'P') continue;
      if (node.nodeType === 1 && node.tagName === 'DIV') {
        const p = document.createElement('p');
        while (node.firstChild) p.append(node.firstChild);
        node.replaceWith(p);
      }
    }
  }

  paragraphs() { return Array.from(this.text.children).filter(el => el.tagName === 'P'); }
  manual() {
    const out = {};
    this.paragraphs().forEach((p, i) => { if (p.dataset.align) out[i] = p.dataset.align; });
    return out;
  }

  format() {
    const ps = this.paragraphs();
    const aligns = genko.a4Aligns(ps.map(p => p.textContent).join('\n'), { autoFormat: !!this.prefs.a4AutoFormat, manual: this.manual() });
    ps.forEach((p, i) => {
      const a = aligns[i] || { align: 'left', indent: false };
      p.style.textAlign = a.align;
      p.style.textIndent = a.indent ? '1em' : '0';
      p.style.paddingRight = a.align === 'right' ? '1em' : '0';
    });
  }

  insertText(data) {
    this.text.focus();
    data.split('\n').forEach((line, i) => {
      if (i > 0) document.execCommand('insertParagraph');
      if (line) document.execCommand('insertText', false, line);
    });
  }

  /// 選んでいる段落の寄せを変える ('auto' | 'left' | 'center' | 'right')
  setAlign(value) {
    const sel = window.getSelection();
    if (!sel.rangeCount) return;
    const range = sel.getRangeAt(0);
    for (const p of this.paragraphs()) {
      if (!range.intersectsNode(p)) continue;
      if (value === 'auto') delete p.dataset.align; else p.dataset.align = value;
    }
    this.format();
  }

  getText() { return this.paragraphs().map(p => p.textContent).join('\n'); }
  setText(text) { if (this.getText() !== text) this.fill(text, {}); }
  setPrefs(prefs) { this.prefs = prefs; this.format(); }
  setReadOnly(on) { this.text.contentEditable = on ? 'false' : 'true'; }
  focus() { this.text.focus({ preventScroll: true }); }
  hasFocus() { return document.activeElement === this.text; }
  selectionText() { const s = window.getSelection(); return this.hasFocus() || this.text.contains(s.anchorNode) ? s.toString() : ''; }
  /// 選んでいる範囲を、文章の先頭からの位置で返す (選んでいる文字が 1 か所だけ見つかるときだけ。あいまいなら範囲なし)
  selectionRange() {
    const sel = this.selectionText().replace(/\r/g, ''), all = this.getText();
    const at = sel ? all.indexOf(sel) : -1;
    return at >= 0 && all.indexOf(sel, at + 1) < 0 ? { from: at, to: at + sel.length } : { from: 0, to: 0 };
  }
  replaceRange(from, to, text) { const all = this.getText(); this.fill(all.slice(0, from) + text + all.slice(to), {}); this.onInput(this.getText()); }
  replaceSelection(text) { this.insertText(text); }
  insertAtCursorEnd(text) { this.text.focus(); window.getSelection().collapseToEnd(); this.insertText(text); }
  selectAll() { this.text.focus(); window.getSelection().selectAllChildren(this.text); }
  undo() { this.text.focus(); document.execCommand('undo'); }
  redo() { this.text.focus(); document.execCommand('redo'); }
  info() {
    const text = this.getText();
    return { chars: Array.from(text.replace(/\n/g, '')).length, lines: this.paragraphs().length, selected: Array.from(this.selectionText().replace(/\n/g, '')).length };
  }
}

// ---------- 印刷・PDF 用の HTML ----------

function page(title, css, body) {
  return `<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>${esc(title)}</title><style>${css}</style></head><body>${body}</body></html>`;
}

/// 原稿用紙: 1 枚を A4 横の 1 ページに。画面と同じ枠・同じマスに刷る
export function genkoPrintHTML(title, text, prefs, ruby, horizontal) {
  const columns = genko.layout(text, { autoFormat: !horizontal && !!prefs.genkoAutoFormat });
  const sheets = genko.sheets(columns);
  const rubyByColumn = prefs.genkoFurigana ? placeRuby(columns, ruby) : null;
  const css = `@page { size: A4 ${horizontal ? 'portrait' : 'landscape'}; margin: 0; } html, body { margin: 0; padding: 0; } :root { --u: 1mm; }
    ${SHEET_CSS} .genko-sheet { background: #fff; page-break-after: always; break-after: page; } .genko-sheet:last-child { page-break-after: auto; break-after: auto; }`;
  return page(title, css, sheets.map((s, i) => `<div class="genko-sheet${horizontal ? ' h' : ''}">${sheetHTML(s, i, sheets.length, null, null, rubyByColumn, horizontal)}</div>`).join(''));
}

/// 公開するときの原稿用紙の並び (Mac 版 ShareLink.genkoLayout と同じ形): { columns: [[字 か null] × 20], ruby: { 列: [[行, 行数, 読み]] } }
export function genkoShareLayout(text, prefs, ruby, horizontal) {
  const columns = genko.layout(text, { autoFormat: !horizontal && !!prefs.genkoAutoFormat });
  const out = {};
  if (prefs.genkoFurigana) {
    for (const [col, list] of Object.entries(placeRuby(columns, ruby))) out[col] = list.map(r => [r.row, r.rows, r.text]);
  }
  return { columns: columns.map(c => c.cells.map(x => (x === null ? null : x))), ruby: out };
}

/// A4: 40 字 × 36 行。寄せと字下げは画面と同じ
export function a4PrintHTML(title, text, prefs, manual) {
  const aligns = genko.a4Aligns(text, { autoFormat: !!prefs.a4AutoFormat, manual: manual || {} });
  const css = `@page { size: A4 portrait; } html, body { margin: 0; padding: 0; }
    body { font-family: ${MINCHO}; font-size: 12pt; line-height: 6.86mm; color: #000; width: 40em; margin: 0 auto; }
    p { margin: 0; white-space: pre-wrap; word-break: break-all; line-break: strict; min-height: 6.86mm; }`;
  const body = text.split('\n').map((line, i) => {
    const a = aligns[i] || { align: 'left', indent: false };
    const style = `text-align:${a.align};text-indent:${a.indent ? '1em' : '0'};padding-right:${a.align === 'right' ? '1em' : '0'}`;
    return `<p style="${style}">${esc(line) || '&nbsp;'}</p>`;
  }).join('');
  return page(title, css, body);
}

/// 通常の文書: 等幅のまま折り返して刷る
export function plainPrintHTML(title, text, fontFamily) {
  const css = `@page { size: A4 portrait; } html, body { margin: 0; padding: 0; }
    pre { margin: 0; font-family: ${fontFamily}; font-size: 10.5pt; line-height: 1.45; color: #000; white-space: pre-wrap; word-break: break-all; tab-size: 4; }`;
  return page(title, css, `<pre>${esc(text)}</pre>`);
}

/// Word に書き出す段落
export function docxParagraphs(text, mode, prefs, manual) {
  const lines = text.split('\n');
  if (mode !== 2) return lines.map(t => ({ text: t }));
  const aligns = genko.a4Aligns(text, { autoFormat: !!prefs.a4AutoFormat, manual: manual || {} });
  return lines.map((t, i) => ({ text: t, align: aligns[i].align, indent: aligns[i].indent }));
}
