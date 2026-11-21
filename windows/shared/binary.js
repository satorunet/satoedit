'use strict';
// テキストではないデータ (バイナリ) の見分けと、16 進数での表示 (Mac 版の BinaryData と同じ)

/// 先頭の一部を見て、バイナリらしいか。
/// NUL (0x00) が入っていればバイナリ。ただし UTF-16 のテキスト (BOM あり、または 1 バイトおきに 0) は除く。
/// NUL がなくても、改行・タブなど以外の制御文字が多ければバイナリ
function looksBinary(sample) {
  const b = sample.subarray ? sample.subarray(0, 8192) : sample.slice(0, 8192);
  if (!b.length) return false;
  if ((b[0] === 0xFF && b[1] === 0xFE) || (b[0] === 0xFE && b[1] === 0xFF) || (b[0] === 0xEF && b[1] === 0xBB && b[2] === 0xBF)) return false;
  let nul = 0, even = 0, odd = 0;
  for (let i = 0; i < b.length; i++) if (b[i] === 0) { nul++; if (i % 2 === 0) even++; else odd++; }
  if (nul > 0) {
    const half = Math.floor(b.length / 2);
    if (half > 0 && ((even > half * 0.4 && odd === 0) || (odd > half * 0.4 && even === 0))) return false;
    return true;
  }
  let controls = 0;
  for (let i = 0; i < b.length; i++) {
    const v = b[i];
    if ((v < 0x20 && ![0x09, 0x0A, 0x0D, 0x0C, 0x1B, 0x08].includes(v)) || v === 0x7F) controls++;
  }
  return controls / b.length > 0.1;
}

const BYTES_PER_LINE = 16;

/// 16 バイト 1 行: { offset, hex, ascii }
function line(data, offset, digits = 8) {
  const bytes = data.subarray ? data.subarray(offset, Math.min(offset + BYTES_PER_LINE, data.length)) : data.slice(offset, offset + BYTES_PER_LINE);
  let hex = '';
  for (let i = 0; i < BYTES_PER_LINE; i++) {
    if (i === 8) hex += ' ';
    hex += i < bytes.length ? bytes[i].toString(16).toUpperCase().padStart(2, '0') : '  ';
    if (i < BYTES_PER_LINE - 1) hex += ' ';
  }
  let ascii = '';
  for (const v of bytes) ascii += v >= 0x20 && v <= 0x7E ? String.fromCharCode(v) : '.';
  return { offset: offset.toString(16).toUpperCase().padStart(digits, '0'), hex, ascii };
}

const lineCount = size => Math.ceil(size / BYTES_PER_LINE);

const IMAGE_TYPES = { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', webp: 'image/webp', bmp: 'image/bmp', ico: 'image/x-icon' };
/// 画像として見るファイルか (SVG は文字なのでエディタで開く)
function imageType(name) {
  const m = /\.([A-Za-z0-9]+)$/.exec(String(name || ''));
  return m ? IMAGE_TYPES[m[1].toLowerCase()] || null : null;
}

module.exports = { looksBinary, line, lineCount, imageType, BYTES_PER_LINE };
