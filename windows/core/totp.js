'use strict';
// スマホの認証アプリ (Google Authenticator など) と同じ 6 桁コード (RFC 6238, HMAC-SHA1, 30 秒ごと)
const crypto = require('crypto');

const PERIOD = 30;
const DIGITS = 6;

function newSecret() { return crypto.randomBytes(20); }

function codeAt(secret, counter, digits = DIGITS) {
  const msg = Buffer.alloc(8);
  msg.writeBigUInt64BE(BigInt(counter));
  const mac = crypto.createHmac('sha1', secret).update(msg).digest();
  const offset = mac[mac.length - 1] & 0x0F;
  const value = ((mac[offset] & 0x7F) << 24) | (mac[offset + 1] << 16) | (mac[offset + 2] << 8) | mac[offset + 3];
  return String(value % Math.pow(10, digits)).padStart(digits, '0');
}

function code(secret, timeSeconds = Date.now() / 1000) {
  return codeAt(secret, Math.floor(Math.max(0, timeSeconds) / PERIOD));
}

/// 入力されたコードが合っているか。時計のずれに備えて前後 1 つ (±30 秒) まで認める
function verify(input, secret, timeSeconds = Date.now() / 1000, window = 1) {
  const entered = String(input).replace(/\s/g, '');
  if (!/^[0-9]{6}$/.test(entered)) return false;
  const counter = Math.floor(Math.max(0, timeSeconds) / PERIOD);
  let ok = false;
  for (let d = -window; d <= window; d++) {
    if (counter + d < 0) continue;
    if (codeAt(secret, counter + d) === entered) ok = true; // 途中で抜けず、毎回すべて比べる
  }
  return ok;
}

/// 認証アプリに手で打ち込むための表記 (Base32、= の詰め物なし)
function base32(buf) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  let out = '', buffer = 0, bits = 0;
  for (const byte of buf) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += alphabet[(buffer >>> (bits - 5)) & 0x1F];
      bits -= 5;
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) out += alphabet[(buffer << (5 - bits)) & 0x1F];
  return out;
}

/// QR コードにする登録用の URL
function uri(secret, account, issuer) {
  const enc = s => encodeURIComponent(s).replace(/[!'()*]/g, c => '%' + c.charCodeAt(0).toString(16).toUpperCase());
  return `otpauth://totp/${enc(issuer)}:${enc(account)}?secret=${base32(secret)}&issuer=${enc(issuer)}&algorithm=SHA1&digits=${DIGITS}&period=${PERIOD}`;
}

module.exports = { PERIOD, DIGITS, newSecret, codeAt, code, verify, base32, uri };
