'use strict';
// 文字コードの判定と変換 (Mac 版 TextCodec.swift と同じ決まり)
const iconv = require('iconv-lite');
const { t } = require('../shared/i18n');

const ENCODINGS = [
  { id: 'utf8', name: 'UTF-8', bom: [] },
  { id: 'utf8BOM', name: 'UTF-8 (BOM付)', bom: [0xEF, 0xBB, 0xBF] },
  { id: 'shiftJIS', name: 'Shift_JIS', bom: [] },
  { id: 'eucJP', name: 'EUC-JP', bom: [] },
  { id: 'iso2022JP', name: 'JIS', bom: [] },
  { id: 'utf16LE', name: 'UTF-16 LE', bom: [0xFF, 0xFE] },
  { id: 'utf16BE', name: 'UTF-16 BE', bom: [0xFE, 0xFF] },
];
const LINE_ENDINGS = [
  { id: 'lf', name: 'LF', string: '\n' },
  { id: 'crlf', name: 'CRLF', string: '\r\n' },
  { id: 'cr', name: 'CR', string: '\r' },
];

function encodingInfo(id) { return ENCODINGS.find(e => e.id === id) || ENCODINGS[0]; }
function encodingName(id) { return encodingInfo(id).name; }
function lineEndingInfo(id) { return LINE_ENDINGS.find(e => e.id === id) || LINE_ENDINGS[0]; }

function startsWith(buf, bytes) {
  if (bytes.length === 0 || buf.length < bytes.length) return false;
  for (let i = 0; i < bytes.length; i++) if (buf[i] !== bytes[i]) return false;
  return true;
}

function containsJISEscape(b) {
  for (let i = 0; i + 2 < b.length; i++) {
    if (b[i] !== 0x1B) continue;
    if ((b[i + 1] === 0x24 && (b[i + 2] === 0x42 || b[i + 2] === 0x40)) || (b[i + 1] === 0x28 && b[i + 2] === 0x4A)) return true;
  }
  return false;
}

function isValidShiftJIS(b) {
  let i = 0;
  while (i < b.length) {
    const c = b[i];
    if (c < 0x80 || (c >= 0xA1 && c <= 0xDF)) {
      i += 1;
    } else if ((c >= 0x81 && c <= 0x9F) || (c >= 0xE0 && c <= 0xFC)) {
      if (i + 1 >= b.length) return false;
      const t = b[i + 1];
      if (!((t >= 0x40 && t <= 0x7E) || (t >= 0x80 && t <= 0xFC))) return false;
      i += 2;
    } else {
      return false;
    }
  }
  return true;
}

function isValidEUCJP(b) {
  let i = 0;
  const hi = x => x >= 0xA1 && x <= 0xFE;
  while (i < b.length) {
    const c = b[i];
    if (c < 0x80) {
      i += 1;
    } else if (c === 0x8E) {
      if (!(i + 1 < b.length && b[i + 1] >= 0xA1 && b[i + 1] <= 0xDF)) return false;
      i += 2;
    } else if (c === 0x8F) {
      if (!(i + 2 < b.length && hi(b[i + 1]) && hi(b[i + 2]))) return false;
      i += 3;
    } else if (hi(c)) {
      if (!(i + 1 < b.length && hi(b[i + 1]))) return false;
      i += 2;
    } else {
      return false;
    }
  }
  return true;
}

function isValidUTF8(buf) {
  try {
    new TextDecoder('utf-8', { fatal: true }).decode(buf);
    return true;
  } catch (e) {
    return false;
  }
}

function detectEncoding(buf) {
  if (startsWith(buf, [0xEF, 0xBB, 0xBF])) return 'utf8BOM';
  if (startsWith(buf, [0xFF, 0xFE])) return 'utf16LE';
  if (startsWith(buf, [0xFE, 0xFF])) return 'utf16BE';
  let ascii = true;
  for (let i = 0; i < buf.length; i++) if (buf[i] >= 0x80) { ascii = false; break; }
  if (ascii) return containsJISEscape(buf) ? 'iso2022JP' : 'utf8';
  if (isValidUTF8(buf)) return 'utf8';
  const sjis = isValidShiftJIS(buf), euc = isValidEUCJP(buf);
  if (sjis && !euc) return 'shiftJIS';
  if (!sjis && euc) return 'eucJP';
  // 普通の Shift_JIS は 0x81-0x9F の先行バイトを含むので EUC としては不正になる。両方通るなら EUC-JP の可能性が高い
  if (sjis && euc) return 'eucJP';
  return 'shiftJIS';
}

function detectLineEnding(s) {
  if (s.indexOf('\r\n') >= 0) return 'crlf';
  if (s.indexOf('\r') >= 0) return 'cr';
  return 'lf';
}

function normalizeLineEndings(s) {
  if (s.indexOf('\r') < 0) return s;
  return s.replace(/\r\n?/g, '\n');
}

// JIS (ISO-2022-JP) ⇔ EUC-JP のバイト列。文字の表は EUC-JP と同じなので、切り替えの印だけ付け外しする
function jisToEUC(buf) {
  const out = [];
  let mode = 0; // 0 = ASCII, 1 = 漢字, 2 = 半角カナ
  let i = 0;
  while (i < buf.length) {
    const c = buf[i];
    if (c === 0x1B && i + 2 < buf.length) {
      const a = buf[i + 1], b = buf[i + 2];
      if (a === 0x24 && (b === 0x42 || b === 0x40)) { mode = 1; i += 3; continue; }
      if (a === 0x28 && (b === 0x42 || b === 0x4A)) { mode = 0; i += 3; continue; }
      if (a === 0x28 && b === 0x49) { mode = 2; i += 3; continue; }
      return null;
    }
    if (c === 0x0A || c === 0x0D) { out.push(c); i += 1; continue; }
    if (c >= 0x80) return null;
    if (mode === 1) {
      if (i + 1 >= buf.length) return null;
      out.push(c | 0x80, buf[i + 1] | 0x80);
      i += 2;
    } else if (mode === 2) {
      out.push(0x8E, c | 0x80);
      i += 1;
    } else {
      out.push(c);
      i += 1;
    }
  }
  return Buffer.from(out);
}

function eucToJIS(buf) {
  const out = [];
  let mode = 0;
  const set = m => {
    if (m === mode) return;
    mode = m;
    if (m === 0) out.push(0x1B, 0x28, 0x42);
    else if (m === 1) out.push(0x1B, 0x24, 0x42);
    else out.push(0x1B, 0x28, 0x49);
  };
  let i = 0;
  while (i < buf.length) {
    const c = buf[i];
    if (c < 0x80) {
      set(0); out.push(c); i += 1;
    } else if (c === 0x8E) {
      set(2); out.push(buf[i + 1] & 0x7F); i += 2;
    } else if (c === 0x8F) {
      return null; // 補助漢字は JIS では書けない
    } else {
      set(1); out.push(c & 0x7F, buf[i + 1] & 0x7F); i += 2;
    }
  }
  set(0);
  return Buffer.from(out);
}

/// 読めなければ null (壊れたバイトを黙って置き換えない)
function decodeRaw(buf, encoding) {
  const info = encodingInfo(encoding);
  let body = buf;
  if (info.bom.length && startsWith(buf, info.bom)) body = buf.subarray(info.bom.length);
  let text;
  switch (encoding) {
    case 'utf8': case 'utf8BOM':
      try { return new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(body); } catch (e) { return null; }
    case 'shiftJIS':
      if (!isValidShiftJIS(body)) return null;
      text = iconv.decode(body, 'cp932');
      break;
    case 'eucJP':
      if (!isValidEUCJP(body)) return null;
      text = iconv.decode(body, 'eucjp');
      break;
    case 'iso2022JP': {
      const euc = jisToEUC(body);
      if (!euc) return null;
      text = iconv.decode(euc, 'eucjp');
      break;
    }
    case 'utf16LE':
      if (body.length % 2) return null;
      return iconv.decode(body, 'utf16le', { stripBOM: false });
    case 'utf16BE':
      if (body.length % 2) return null;
      return iconv.decode(body, 'utf16-be', { stripBOM: false });
    default:
      return null;
  }
  return text.indexOf('�') >= 0 ? null : text;
}

/// encoding を省くと自動判別。返す text の改行は LF にそろえてある
function decode(buf, encoding) {
  const make = (raw, e) => ({ text: normalizeLineEndings(raw), encoding: e, lineEnding: detectLineEnding(raw) });
  if (encoding) {
    const raw = decodeRaw(buf, encoding);
    if (raw === null) throw new Error(t('{name} として読み込めませんでした。別の文字コードを指定して開き直してください。', { name: encodingName(encoding) }));
    return make(raw, encoding);
  }
  const guess = detectEncoding(buf);
  for (const e of [guess, 'utf8', 'shiftJIS', 'eucJP'].filter((x, i, a) => a.indexOf(x) === i)) {
    const raw = decodeRaw(buf, e);
    if (raw !== null) return make(raw, e);
  }
  // 最後の手段: 壊れたバイトを置換文字にして UTF-8 として開く
  return make(new TextDecoder('utf-8').decode(buf), 'utf8');
}

/// text は LF 改行の前提。その文字コードで書けない文字があればエラー
function encode(text, encoding, lineEnding) {
  const eol = lineEndingInfo(lineEnding).string;
  const converted = eol === '\n' ? text : text.replace(/\n/g, eol);
  const info = encodingInfo(encoding);
  const fail = () => new Error(t('{name} では保存できない文字が含まれています。文字コードを UTF-8 などに変更してから保存してください。', { name: info.name }));
  let body;
  switch (encoding) {
    case 'utf8': case 'utf8BOM': body = Buffer.from(converted, 'utf8'); break;
    case 'utf16LE': body = iconv.encode(converted, 'utf16le', { addBOM: false }); break;
    case 'utf16BE': body = iconv.encode(converted, 'utf16-be', { addBOM: false }); break;
    case 'shiftJIS':
      body = iconv.encode(converted, 'cp932');
      if (iconv.decode(body, 'cp932') !== converted) throw fail();
      break;
    case 'eucJP': case 'iso2022JP': {
      const euc = iconv.encode(converted, 'eucjp');
      if (iconv.decode(euc, 'eucjp') !== converted) throw fail();
      body = encoding === 'eucJP' ? euc : eucToJIS(euc);
      if (!body) throw fail();
      break;
    }
    default: throw fail();
  }
  return Buffer.concat([Buffer.from(info.bom), body]);
}

module.exports = {
  ENCODINGS, LINE_ENDINGS, encodingName, lineEndingInfo,
  detectEncoding, detectLineEnding, normalizeLineEndings, decode, encode,
};
