'use strict';
// 用紙モードの決まり。
// 原稿用紙: A4 横、1 列 20 マス × 20 列 (400 字)。中央に余白 (魚尾)、各列の右にふりがなの枠がある標準的な形。
//   自動整形では 題名は 3 マス下げ、名前は下寄せ (下を 1 マス空ける)、本文の段落は 1 マス下げ。
// A4: 題名は中央、名前は右寄せ、本文の段落は 1 字下げ。
const ROWS = 20;
const COLUMNS_PER_SHEET = 20;

// 用紙の寸法 (mm)。A4 横 297 × 210
const SHEET = {
  width: 297, height: 210,
  cell: 9,        // 1 マス
  ruby: 3,        // ふりがなの枠の幅
  pitch: 12,      // 1 列ぶん (マス + ふりがな)
  center: 12,     // 中央の余白
  left: 22.5, top: 15,
  line: '#CC7359',
};
SHEET.gridWidth = SHEET.pitch * COLUMNS_PER_SHEET + SHEET.center;
SHEET.gridHeight = SHEET.cell * ROWS;

/// 用紙の中の列 k (0 = いちばん右) の、マスの左端の x (mm)
function columnX(k) {
  const right = SHEET.left + SHEET.gridWidth - k * SHEET.pitch - (k >= COLUMNS_PER_SHEET / 2 ? SHEET.center : 0);
  return right - SHEET.pitch;
}

// 横書きの原稿用紙 (Mac 版と同じ): 縦書きの用紙を回して作る (A4 縦)。縦書きの「右の列から左へ」が「上の行から下へ」、
// 「列の上から下へ」が「行の左から右へ」になり、列の右のふりがなの枠は行の上に来る。真ん中の余白 (魚尾) はなく、線は緑
const LINE_H = '#388C5C';

/// 列 k (横書きでは行 k) のマスの左端 (縦書きの用紙の上の mm)。横書きは 20 行を詰めて、そのぶん全体を真ん中に寄せる
function columnXOf(k, horizontal) {
  if (!horizontal) return columnX(k);
  return columnX(k) + (k >= COLUMNS_PER_SHEET / 2 ? SHEET.center : 0) - SHEET.center / 2;
}

/// マス目全体の枠 (縦書きの用紙の上の mm): { x, width }
function gridSpan(horizontal) {
  return horizontal ? { x: SHEET.left + SHEET.center / 2, width: SHEET.gridWidth - SHEET.center } : { x: SHEET.left, width: SHEET.gridWidth };
}

/// 縦書きの用紙の上の位置 (mm) → 描く位置 (mm)。横書きは回す
function point(x, y, horizontal) { return horizontal ? [y, SHEET.width - x] : [x, y]; }

/// 縦書きの用紙の上の四角 → 描く四角 { left, top, width, height } (mm)
function rect(x, y, w, h, horizontal) {
  const a = point(x, y, horizontal), b = point(x + w, y + h, horizontal);
  return { left: Math.min(a[0], b[0]), top: Math.min(a[1], b[1]), width: Math.abs(a[0] - b[0]), height: Math.abs(a[1] - b[1]) };
}

/// 枠線の SVG (viewBox は mm)
function sheetSVG(horizontal) {
  const s = SHEET;
  const y0 = s.top, y1 = s.top + s.gridHeight;
  const L = (xa, ya, xb, yb) => { const a = point(xa, ya, horizontal), b = point(xb, yb, horizontal); return `M${+a[0].toFixed(3)} ${+a[1].toFixed(3)}L${+b[0].toFixed(3)} ${+b[1].toFixed(3)}`; };
  let thin = '';
  for (let k = 0; k < COLUMNS_PER_SHEET; k++) {
    const x = columnXOf(k, horizontal);
    // マスの左端・マスとふりがな枠の境・ふりがな枠の右端
    thin += L(x, y0, x, y1) + L(x + s.cell, y0, x + s.cell, y1) + L(x + s.pitch, y0, x + s.pitch, y1);
    for (let r = 1; r < ROWS; r++) thin += L(x, y0 + r * s.cell, x + s.cell, y0 + r * s.cell);
  }
  // 中央の余白の魚尾 (上下の小さな印)。横書きには真ん中の余白がないので描かない
  let marks = '';
  if (!horizontal) {
    const cx = columnX(COLUMNS_PER_SHEET / 2 - 1) - s.center / 2;
    const fish = y => `M${cx - 3.2} ${y}H${cx + 3.2}M${cx - 3.2} ${y + 5}L${cx} ${y + 2.6}L${cx + 3.2} ${y + 5}`;
    marks = fish(y0 + s.gridHeight * 0.25) + fish(y0 + s.gridHeight * 0.7);
  }
  const color = horizontal ? LINE_H : s.line;
  const span = gridSpan(horizontal);
  const frame = rect(span.x, y0, span.width, s.gridHeight, horizontal);
  const w = horizontal ? s.height : s.width, h = horizontal ? s.width : s.height;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">`
    + `<path d="${thin}" fill="none" stroke="${color}" stroke-width="0.18"/>`
    + (marks ? `<path d="${marks}" fill="none" stroke="${color}" stroke-width="0.3"/>` : '')
    + `<rect x="${frame.left}" y="${frame.top}" width="${frame.width}" height="${frame.height}" fill="none" stroke="${color}" stroke-width="0.6"/>`
    + '</svg>';
}

function startsIndented(text) {
  if (!text) return false;
  const c = text[0];
  return c === '　' || c === ' ' || c === '\t' || '「『（('.includes(c);
}

/// 段落 (0 始まり) の書き出しを何マス下げるか
function indentFor(index, text, autoFormat) {
  const count = Array.from(text).length;
  if (!autoFormat) return 0;
  if (count === 0) return index === 0 ? 3 : (index === 1 ? 0 : 1); // まだ何も書いていない列の書き始め
  if (index === 0) return count <= ROWS - 3 ? 3 : 0;
  if (index === 1) return count < ROWS ? ROWS - count - 1 : 0;
  return startsIndented(text) ? 0 : 1;
}

/// 文章 → 列の並び。
/// 各列: { cells: 20 個 (文字か null), offs: 20 個 (その文字の位置。なければ -1), paragraph: 段落番号,
///         from / to: この列が受け持つ文章の位置の範囲 (to はこの列の最後の文字の次), first: 最初の文字の行 }
function layout(text, { autoFormat = true } = {}) {
  const columns = [];
  let offset = 0;
  const newColumn = (index, first) => {
    const col = { cells: new Array(ROWS).fill(null), offs: new Array(ROWS).fill(-1), paragraph: index, from: offset, to: offset, first, last: false };
    columns.push(col);
    return col;
  };
  String(text).split('\n').forEach((para, index) => {
    let row = indentFor(index, para, autoFormat);
    let col = newColumn(index, row);
    for (const ch of para) {
      if (row >= ROWS) {
        col = newColumn(index, 0);
        row = 0;
      }
      col.cells[row] = ch;
      col.offs[row] = offset;
      offset += ch.length;
      col.to = offset;
      row += 1;
    }
    col.last = true; // 段落の最後の列 (ここの to が改行の位置)
    offset += 1;     // 改行
  });
  return columns;
}

/// 文章の位置 → カーソルを出すマス { column, row } (row = 20 は列のいちばん下の外)
function caretCell(columns, offset) {
  for (let i = 0; i < columns.length; i++) {
    const c = columns[i];
    if (offset < c.from || offset > c.to) continue;
    if (offset === c.to) {
      // 列の最後の文字の次。段落の途中で折り返した位置は、次の列の頭に出す
      if (!c.last && i + 1 < columns.length) continue;
      const n = c.cells.reduce((m, x, r) => (x !== null ? r + 1 : m), c.first);
      return { column: i, row: n };
    }
    for (let r = 0; r < ROWS; r++) if (c.offs[r] === offset) return { column: i, row: r };
  }
  const lastIndex = Math.max(0, columns.length - 1);
  return { column: lastIndex, row: columns.length ? columns[lastIndex].first : 0 };
}

/// マス → 文章の位置 (文字のないマスは、その列でいちばん近い位置)
function offsetAt(columns, column, row) {
  const c = columns[Math.max(0, Math.min(column, columns.length - 1))];
  if (!c) return 0;
  if (row < c.first) return c.from;
  for (let r = Math.min(row, ROWS - 1); r >= 0; r--) {
    if (c.offs[r] >= 0) return r === row ? c.offs[r] : c.to;
  }
  return c.from;
}

/// 列の並び → 1 枚 (20 列) ずつ。足りない列は空の列で埋める
function sheets(columns) {
  const out = [];
  const total = Math.max(1, Math.ceil(columns.length / COLUMNS_PER_SHEET));
  for (let s = 0; s < total; s++) {
    const sheet = columns.slice(s * COLUMNS_PER_SHEET, (s + 1) * COLUMNS_PER_SHEET);
    while (sheet.length < COLUMNS_PER_SHEET) {
      sheet.push({ cells: new Array(ROWS).fill(null), offs: new Array(ROWS).fill(-1), paragraph: -1, from: -1, to: -1, first: 0, last: false });
    }
    out.push(sheet);
  }
  return out;
}

/// 半角の英数字・記号・空白を全角にする
function toFullWidth(s) {
  let out = '';
  for (const ch of s) {
    const c = ch.charCodeAt(0);
    if (ch === ' ') out += '　';
    else if (ch.length === 1 && c >= 0x21 && c <= 0x7E) out += String.fromCharCode(c + 0xFEE0);
    else out += ch;
  }
  return out;
}

/// A4 の段落ごとの寄せ。manual は { 段落番号: 'left' | 'center' | 'right' } (手で決めた寄せ)
function a4Aligns(text, { autoFormat = true, manual = {} } = {}) {
  return String(text).split('\n').map((para, index) => {
    let align = 'left';
    if (manual[index]) align = manual[index];
    else if (autoFormat && para.length > 0) align = index === 0 ? 'center' : (index === 1 ? 'right' : 'left');
    const indent = align === 'left' && autoFormat && !manual[index] && index >= 2 && para.length > 0 && !startsIndented(para);
    return { align, indent };
  });
}

module.exports = {
  ROWS, COLUMNS_PER_SHEET, SHEET, LINE_H, columnX, columnXOf, gridSpan, point, rect, sheetSVG, startsIndented, indentFor, layout, caretCell, offsetAt, sheets, toFullWidth, a4Aligns,
};
