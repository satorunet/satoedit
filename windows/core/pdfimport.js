'use strict';
// PDF からテキストを読み込む (pdf.js)。文字の位置から行を組み立てる。縦書きの PDF は、右の列から順に読む
const fs = require('fs');
const path = require('path');

let lib = null;
function pdfjs() {
  if (!lib) {
    // 古い Node には無いので、読み込む前に用意しておく
    if (typeof globalThis.DOMException === 'undefined') globalThis.DOMException = class DOMException extends Error {};
    const at = function (n) { n = Math.trunc(n) || 0; if (n < 0) n += this.length; return n < 0 || n >= this.length ? undefined : this[n]; };
    for (const C of [Array, String, Uint8Array]) {
      if (!C.prototype.at) Object.defineProperty(C.prototype, 'at', { value: at, writable: true, configurable: true });
    }
    if (typeof globalThis.structuredClone === 'undefined') globalThis.structuredClone = v => require('v8').deserialize(require('v8').serialize(v));
    lib = require('pdfjs-dist/legacy/build/pdf.js');
  }
  return lib;
}

/// PDF の中の字を普通の字にそろえる: 部首用の別の字 (「⾜」など) や縦書き用の字を普通の字に、読めなかった字 (NUL) は捨てる
function tidy(text) {
  // 縦書き用の句読点・かっこ (︑︒︵ など) も、ふつうの字にそろえる
  // (NFKC にまかせると、かっこが半角の ( ) になってしまうので、かっこだけは全角にする)
  const brackets = { '\uFE35': '（', '\uFE36': '）', '\uFE37': '｛', '\uFE38': '｝', '\uFE39': '〔', '\uFE3A': '〕', '\uFE3B': '【', '\uFE3C': '】',
    '\uFE3D': '《', '\uFE3E': '》', '\uFE3F': '〈', '\uFE40': '〉', '\uFE41': '「', '\uFE42': '」', '\uFE43': '『', '\uFE44': '』', '\uFE47': '［', '\uFE48': '］' };
  return text.replace(/[\u2E80-\u2FDF\uFE10-\uFE19\uFE30-\uFE4F]/g, c => brackets[c] || c.normalize('NFKC')).replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, '');
}

/// 1 ページぶんの文字の並び → 文章
function pageText(items) {
  const runs = items.filter(i => i.str && i.str.trim() !== '').map(i => ({
    str: i.str, x: i.transform[4], y: i.transform[5], w: i.width || 0, h: Math.abs(i.transform[3]) || Math.abs(i.transform[0]) || 10,
    // 文字が横倒し (回転) か、1 文字ずつ縦に並んでいれば縦書き
    rotated: Math.abs(i.transform[1]) > Math.abs(i.transform[0]),
  }));
  if (runs.length === 0) return '';
  const size = runs.map(r => r.h).sort((a, b) => a - b)[Math.floor(runs.length / 2)] || 10;
  // ふりがな (本文よりずっと小さい字) は、本文に混ざると読みにくいので入れない
  for (let i = runs.length - 1; i >= 0; i--) if (runs[i].h < size * 0.6) runs.splice(i, 1);
  // 縦書きの判定: 同じ x に、1 文字の断片が縦にたくさん並んでいる
  const single = runs.filter(r => Array.from(r.str).length === 1);
  const columns = new Map();
  for (const r of single) {
    const key = Math.round(r.x / (size * 0.5));
    columns.set(key, (columns.get(key) || 0) + 1);
  }
  const stacked = Array.from(columns.values()).filter(n => n >= 3).reduce((a, b) => a + b, 0);
  const vertical = runs.some(r => r.rotated) || (single.length > runs.length * 0.7 && stacked > single.length * 0.6);

  const groups = [];
  if (vertical) {
    // 右の列から、上から下へ
    const sorted = runs.slice().sort((a, b) => (Math.abs(a.x - b.x) > size * 0.5 ? b.x - a.x : b.y - a.y));
    for (const r of sorted) {
      const last = groups[groups.length - 1];
      if (last && Math.abs(last.x - r.x) <= size * 0.5) last.items.push(r); else groups.push({ x: r.x, items: [r] });
    }
    return groups.map(g => g.items.map(r => r.str).join('')).join('\n');
  }
  // 横書き: 上の行から、左から右へ
  const sorted = runs.slice().sort((a, b) => (Math.abs(a.y - b.y) > size * 0.5 ? b.y - a.y : a.x - b.x));
  for (const r of sorted) {
    const last = groups[groups.length - 1];
    if (last && Math.abs(last.y - r.y) <= size * 0.5) last.items.push(r); else groups.push({ y: r.y, items: [r] });
  }
  return groups.map(g => {
    let line = '', end = null;
    for (const r of g.items) {
      // 離れている断片のあいだには空白を入れる
      if (end !== null && r.x - end > size * 0.6) line += ' ';
      line += r.str;
      end = r.x + r.w;
    }
    return line;
  }).join('\n');
}

/// PDF のファイル → { text, pages }
async function importPDF(file) {
  const base = path.dirname(require.resolve('pdfjs-dist/package.json'));
  const doc = await pdfjs().getDocument({
    data: new Uint8Array(fs.readFileSync(file)),
    cMapUrl: path.join(base, 'cmaps') + path.sep, cMapPacked: true,
    standardFontDataUrl: path.join(base, 'standard_fonts') + path.sep,
    isEvalSupported: false, useSystemFonts: false, verbosity: 0,
  }).promise;
  const parts = [];
  for (let n = 1; n <= doc.numPages; n++) {
    const page = await doc.getPage(n);
    const content = await page.getTextContent();
    parts.push(pageText(content.items));
  }
  const pages = doc.numPages;
  await doc.destroy();
  return { text: tidy(parts.join('\n\n')).replace(/[ \t]+$/gm, '') + '\n', pages };
}

module.exports = { importPDF, pageText, tidy };
