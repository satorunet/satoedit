'use strict';
// 入力補完の中身 (画面は持たない)。Mac 版の Completion と同じ考え方
const lib = require('./completionlib');

/// "name(a, b)" → { label: 'name', kind: 'function', detail: '(a, b)', params: ['a', 'b'] }
function fn(signature) {
  const open = signature.indexOf('(');
  if (open < 0 || !signature.endsWith(')')) return { label: signature, kind: 'function', detail: '', params: [] };
  const inner = signature.slice(open + 1, -1);
  return { label: signature.slice(0, open).trim(), kind: 'function', detail: '(' + inner + ')', params: splitParams(inner) };
}

/// "a, b = (1, 2), c" → ["a", "b = (1, 2)", "c"]
function splitParams(inner) {
  const out = [];
  let cur = '', depth = 0;
  for (const ch of inner) {
    if ('([{<'.includes(ch)) { depth++; cur += ch; }
    else if (')]}>'.includes(ch)) { depth = Math.max(0, depth - 1); cur += ch; }
    else if (ch === ',' && depth === 0) { out.push(cur.trim()); cur = ''; }
    else cur += ch;
  }
  const last = cur.trim();
  if (last || out.length) out.push(last);
  return out.filter(Boolean);
}

const cache = new Map();
/// 言語の名前から、組み込みの候補
function libraryItems(language) {
  if (!language) return [];
  if (cache.has(language)) return cache.get(language);
  let list = [];
  if (lib.BY_LANGUAGE[language]) list = lib.BY_LANGUAGE[language].map(fn);
  else if (language === 'CSS') list = lib.CSS_PROPERTIES.map(label => ({ label, kind: 'property', detail: '', params: [] }));
  else if (language === 'HTML / XML') {
    list = lib.HTML_TAGS.map(label => ({ label, kind: 'tag', detail: '', params: [] }))
      .concat(lib.HTML_ATTRIBUTES.map(label => ({ label, kind: 'property', detail: '', params: [] })));
  }
  cache.set(language, list);
  return list;
}

const isWord = c => /[0-9A-Za-z_$]/.test(c);

/// 文書の中の単語 (3 文字以上、数字で始まらない)
function words(text, max = 5000) {
  const out = [], seen = new Set();
  const re = /[A-Za-z_$][0-9A-Za-z_$]{2,59}/g;
  const src = text.length > 2000000 ? text.slice(0, 2000000) : text;
  let m;
  while ((m = re.exec(src)) && out.length < max) {
    // 数字の続き (123abc) は飛ばす
    if (m.index > 0 && /[0-9]/.test(src[m.index - 1])) continue;
    if (!seen.has(m[0])) { seen.add(m[0]); out.push(m[0]); }
  }
  return out;
}

/// 文書の中で定義されている関数 (function foo(a, b) / def foo(a): / func foo(...) など)
function definedFunctions(text) {
  const src = text.length > 2000000 ? text.slice(0, 2000000) : text;
  const patterns = [
    /\bfunction\s*&?\s*([A-Za-z_$][\w$]*)\s*\(([^)]*)\)/g,
    /\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?function\s*\(([^)]*)\)/g,
    /\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?\(([^)]*)\)\s*=>/g,
    /\bdef\s+([A-Za-z_]\w*[?!]?)\s*\(([^)]*)\)/g,
    /\bfunc\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)\s*(?:<[^>]*>)?\s*\(([^)]*)\)/g,
    /\bfn\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\s*\(([^)]*)\)/g,
    /\bsub\s+([A-Za-z_]\w*)\s*\(([^)]*)\)/g,
  ];
  const seen = new Set(), out = [];
  for (const re of patterns) {
    let m;
    while ((m = re.exec(src))) {
      if (seen.has(m[1])) continue;
      seen.add(m[1]);
      out.push(fn(m[1] + '(' + m[2].replace(/\s+/g, ' ').trim() + ')'));
    }
  }
  return out;
}

/// 候補を選んだときに入れる文字と、カーソルの位置 (入れた文字の先頭から)
function insertion(item, next, language) {
  if (item.kind === 'function') {
    if (next === '(') return { text: item.label, caret: item.label.length };
    return { text: item.label + '()', caret: item.label.length + (item.params.length ? 1 : 2) };
  }
  if (item.kind === 'property' && language === 'CSS') {
    if (next === ':') return { text: item.label, caret: item.label.length };
    return { text: item.label + ': ;', caret: item.label.length + 2 };
  }
  if (item.kind === 'tag') {
    if (lib.VOID_TAGS.has(item.label)) return { text: item.label + '>', caret: item.label.length + 1 };
    return { text: item.label + '></' + item.label + '>', caret: item.label.length + 1 };
  }
  return { text: item.label, caret: item.label.length };
}

/// カーソルがどの関数呼び出しのかっこの中にいて、何番目の引数か ({ name, argIndex, openParen } または null)
function callContext(text, caret) {
  let depth = 0, commas = 0, quote = null;
  const stop = Math.max(0, caret - 3000);
  for (let i = Math.min(caret, text.length) - 1; i >= stop; i--) {
    const c = text[i];
    if (quote) {
      if (c === quote && (i === 0 || text[i - 1] !== '\\')) quote = null;
      continue;
    }
    if (c === '"' || c === "'" || c === '`') quote = c;
    else if (c === ')' || c === ']' || c === '}') depth++;
    else if (c === '[' || c === '{') { if (depth === 0) return null; depth--; }
    else if (c === '(') {
      if (depth > 0) { depth--; continue; }
      let e = i;
      while (e > 0 && text[e - 1] === ' ') e--;
      let s = e;
      while (s > 0 && isWord(text[s - 1])) s--;
      if (s >= e) return null;
      const name = text.slice(s, e);
      if (['if', 'for', 'while', 'switch', 'catch', 'return', 'elseif', 'foreach', 'function', 'def', 'func'].includes(name)) return null;
      return { name, argIndex: commas, openParen: i, nameStart: s };
    } else if (c === ',' && depth === 0) commas++;
    else if (c === ';' && depth === 0) return null;
  }
  return null;
}

module.exports = { fn, splitParams, libraryItems, words, definedFunctions, insertion, callContext, isWord };
