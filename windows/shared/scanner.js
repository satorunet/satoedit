'use strict';
// 文書全体を先頭から 1 回なめて色付け用のトークンを切り出す簡易スキャナ (Mac 版 SyntaxScanner.swift の移植)。
// 正規表現の積み重ねと違い、コメント中の文字列・文字列中のコメント記号を正しく扱える。
const KINDS = ['keyword', 'type', 'string', 'comment', 'number', 'tag'];
const K = { keyword: 0, type: 1, string: 2, comment: 3, number: 4, tag: 5 };

function makeScanner(profile) {
  const fold = profile.caseInsensitive ? s => s.toLowerCase() : s => s;
  const keywords = new Set((profile.keywords || []).map(fold));
  const types = new Set((profile.types || []).map(fold));
  const lineComments = (profile.lineComments || []).filter(s => s);
  const blockComments = (profile.blockComments || []).filter(p => p && p.length === 2 && p[0] && p[1]);
  const strings = (profile.stringDelimiters || []).filter(s => s);
  // 長い区切りから試す (""" を " より先に)
  const multiline = (profile.multilineStrings || []).filter(s => s).sort((a, b) => b.length - a.length);

  const isDigit = c => c >= 48 && c <= 57;
  const isIdentStart = c => (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c === 95 || c === 36 || c >= 0x80;
  const isIdentChar = c => isIdentStart(c) || isDigit(c);

  /// 返り値は [開始, 終了, 種類, 開始, 終了, 種類, …] (位置は UTF-16 単位)
  return function tokens(s) {
    const n = s.length;
    const out = [];
    let i = 0;
    const emit = (a, b, k) => { out.push(a, Math.min(b, n), k); };

    scan: while (i < n) {
      const c = s.charCodeAt(i);

      for (const lc of lineComments) {
        if (s.startsWith(lc, i)) {
          let j = s.indexOf('\n', i + lc.length);
          if (j < 0) j = n;
          emit(i, j, K.comment);
          i = j;
          continue scan;
        }
      }
      for (const [open, close] of blockComments) {
        if (s.startsWith(open, i)) {
          let j = s.indexOf(close, i + open.length);
          j = j < 0 ? n : j + close.length;
          emit(i, j, K.comment);
          i = j;
          continue scan;
        }
      }
      for (const d of multiline) {
        if (s.startsWith(d, i)) {
          let j = i + d.length;
          while (j < n) {
            if (s.charCodeAt(j) === 0x5C) { j += 2; continue; }
            if (s.startsWith(d, j)) { j += d.length; break; }
            j += 1;
          }
          j = Math.min(n, j);
          emit(i, j, K.string);
          i = j;
          continue scan;
        }
      }
      for (const d of strings) {
        if (s.startsWith(d, i)) {
          let j = i + d.length;
          while (j < n && s.charCodeAt(j) !== 0x0A) {
            if (s.charCodeAt(j) === 0x5C) { j += 2; continue; }
            if (s.startsWith(d, j)) { j += d.length; break; }
            j += 1;
          }
          j = Math.min(n, j);
          emit(i, j, K.string);
          i = j;
          continue scan;
        }
      }
      if (profile.markupTags && c === 0x3C) { // <
        let j = i + 1;
        if (j < n) {
          const x = s.charCodeAt(j);
          if (x === 0x2F || x === 0x3F || x === 0x21) j += 1; // / ? !
        }
        const nameStart = j;
        while (j < n) {
          const x = s.charCodeAt(j);
          if (isIdentChar(x) || x === 0x2D || x === 0x3A) j += 1; else break; // - :
        }
        if (j > nameStart) {
          emit(i, j, K.tag);
          i = j;
          continue scan;
        }
      }
      if (isDigit(c) && (i === 0 || !isIdentChar(s.charCodeAt(i - 1)))) {
        let j = i + 1;
        while (j < n) {
          const x = s.charCodeAt(j);
          if (isIdentChar(x) || x === 0x2E) j += 1; else break;
        }
        emit(i, j, K.number);
        i = j;
        continue scan;
      }
      if (isIdentStart(c)) {
        let j = i + 1;
        while (j < n && isIdentChar(s.charCodeAt(j))) j += 1;
        if (c < 0x80) {
          const key = fold(s.slice(i, j));
          if (keywords.has(key)) emit(i, j, K.keyword);
          else if (types.has(key) || (profile.capitalizedIsType && c >= 65 && c <= 90)) emit(i, j, K.type);
        }
        i = j;
        continue scan;
      }
      i += 1;
    }
    return out;
  };
}

/// 半角を 1、全角を 2 として数えた表示幅
function displayWidth(s) {
  let wd = 0;
  for (const ch of s) {
    const v = ch.codePointAt(0);
    wd += (v < 0x1100 || (v >= 0xFF61 && v <= 0xFF9F)) ? 1 : 2;
  }
  return wd;
}

module.exports = { KINDS, K, makeScanner, displayWidth };
