'use strict';
// 流出防止のためのファイル暗号化 (AES-256-GCM)。Mac 版 FileCrypto.swift と同じファイルの形なので、
// パスワード・パスコード・鍵ファイルで暗号化した文書は Mac と Windows のどちらでも開ける。
//
// ファイルの形 (版 2):
//   "SATORU-ENC\n" | 版=2 | 種類 (1) | 繰り返し回数 (4) | ソルト または 鍵の番号 (16) | AES-GCM (nonce 12 + 暗号文 + タグ 16)
// 版 1 (種類なし = パスワード) のファイルも読める。先頭部分も改ざん検出の対象。
const crypto = require('crypto');
const { t } = require('../shared/i18n');

const MAGIC = Buffer.from('SATORU-ENC\n', 'utf8');
const VERSION = 2;
const DEFAULT_ITERATIONS = 600000;
const PASSCODE_ITERATIONS = 2000000;
const KIND = { password: 0, passcode: 1, device: 2, totp: 3, keyfile: 4, twoStep: 5 };
const KIND_NAMES = Object.keys(KIND);
const KEYFILE_HEADER = 'SATORU-KEYFILE-1';
const KEYFILE_EXTENSION = 'satorukey';

class CryptoError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}
const errors = {
  notEncrypted: () => new CryptoError('notEncrypted', t('暗号化されたファイルではありません')),
  unsupportedVersion: () => new CryptoError('unsupportedVersion', t('このアプリでは読めない新しい形式の暗号化ファイルです')),
  wrong: () => new CryptoError('wrong', t('パスワード (パスコード) が違うか、ファイルが壊れています')),
  wrongKeyFile: () => new CryptoError('wrongKeyFile', t('この文書を暗号化したときの鍵ファイルではありません')),
  keyNotHere: () => new CryptoError('keyNotHere', t('このファイルの鍵はこの PC にありません。暗号化した PC でしか開けません。')),
};

function isEncrypted(buf) {
  return buf.length > MAGIC.length && buf.subarray(0, MAGIC.length).equals(MAGIC);
}

function pbkdf2(password, salt, iterations) {
  return new Promise((resolve, reject) => {
    crypto.pbkdf2(Buffer.from(password, 'utf8'), salt, iterations, 32, 'sha256', (err, key) => err ? reject(err) : resolve(key));
  });
}

function hkdf(ikm, salt, info) {
  return Buffer.from(crypto.hkdfSync('sha256', ikm, salt, Buffer.from(info, 'utf8'), 32));
}

/// パスワード (またはパスコード) から鍵を作る (少し時間がかかる)。salt を省くと新しく作る
async function deriveKey(password, { salt, iterations, kind } = {}) {
  kind = kind || 'password';
  iterations = iterations || (kind === 'passcode' ? PASSCODE_ITERATIONS : DEFAULT_ITERATIONS);
  salt = salt || crypto.randomBytes(16);
  return { key: await pbkdf2(password, salt, iterations), salt, iterations, kind };
}

/// この PC 用の乱数の鍵 (保存はアプリ側で、Windows のログインに結び付けて行う)
function newDeviceKey(kind = 'device') {
  const raw = crypto.randomBytes(32);
  return { key: raw, salt: crypto.randomBytes(16), iterations: 0, kind };
}

function deviceKey(raw, id, kind = 'device') {
  return { key: raw, salt: id, iterations: 0, kind };
}

/// 二段階: パスワードから作った鍵に、認証アプリと共有している秘密を混ぜる
async function twoStepKey(password, totpSecret, { salt, iterations } = {}) {
  const base = await deriveKey(password, { salt, iterations: iterations || DEFAULT_ITERATIONS });
  return { key: hkdf(base.key, totpSecret, 'satoru-two-step'), salt: base.salt, iterations: base.iterations, kind: 'twoStep' };
}

// 鍵ファイル
function newKeyFileContents() {
  return Buffer.from(`${KEYFILE_HEADER}\n# Satoru Editor key file. If you lose it, documents encrypted with it can never be opened.\n`
    + crypto.randomBytes(32).toString('base64') + '\n', 'utf8');
}

/// 鍵ファイルの中身から元の乱数を取り出す。鍵ファイルでなければ null
function keyFileSecret(contents) {
  if (contents.length >= 4096) return null;
  const lines = contents.toString('utf8').split(/\r\n|\r|\n/).map(s => s.trim()).filter(s => s.length > 0);
  if (lines[0] !== KEYFILE_HEADER) return null;
  const line = lines.slice(1).find(s => !s.startsWith('#'));
  if (!line || !/^[A-Za-z0-9+/]+=*$/.test(line)) return null;
  const secret = Buffer.from(line, 'base64');
  return secret.length === 32 ? secret : null;
}

/// 鍵ファイルの指紋 (暗号化ファイルの先頭に入れて、違う鍵ファイルをすぐ見分ける)
function keyFileFingerprint(secret) {
  const d = crypto.createHash('sha256').update(Buffer.concat([Buffer.from('satoru-keyfile-id', 'utf8'), secret])).digest();
  return d.readUInt32BE(0);
}

function keyFileKey(secret, salt) {
  salt = salt || crypto.randomBytes(16);
  return { key: hkdf(secret, salt, 'satoru-file-key'), salt, iterations: keyFileFingerprint(secret), kind: 'keyfile' };
}

function headerData(key, version = VERSION) {
  const parts = [MAGIC, Buffer.from([version])];
  if (version >= 2) parts.push(Buffer.from([KIND[key.kind]]));
  const it = Buffer.alloc(4);
  it.writeUInt32BE(key.iterations >>> 0, 0);
  parts.push(it, key.salt);
  return Buffer.concat(parts);
}

/// 平文 → 暗号化ファイルの中身 (保存のたびに nonce は新しくなる)
function seal(plain, key, version = VERSION) {
  const h = headerData(key, version);
  const nonce = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', key.key, nonce);
  c.setAAD(h);
  const body = Buffer.concat([c.update(plain), c.final()]);
  return Buffer.concat([h, nonce, body, c.getAuthTag()]);
}

/// ファイルの先頭を読む
function header(buf) {
  if (!isEncrypted(buf)) throw errors.notEncrypted();
  const v = buf[MAGIC.length];
  let i = MAGIC.length + 1;
  let kind;
  if (v === 1) {
    kind = 'password';
  } else if (v === 2) {
    if (buf.length <= i || buf[i] >= KIND_NAMES.length) throw errors.unsupportedVersion();
    kind = KIND_NAMES[buf[i]];
    i += 1;
  } else {
    throw errors.unsupportedVersion();
  }
  if (buf.length < i + 20) throw errors.wrong();
  return { version: v, kind, iterations: buf.readUInt32BE(i), salt: Buffer.from(buf.subarray(i + 4, i + 20)), length: i + 20 };
}

/// 暗号化ファイル → 平文
function open(buf, key) {
  const h = header(buf);
  if (buf.length < h.length + 28 || !h.salt.equals(key.salt) || h.kind !== key.kind) throw errors.wrong();
  try {
    const d = crypto.createDecipheriv('aes-256-gcm', key.key, buf.subarray(h.length, h.length + 12));
    d.setAAD(buf.subarray(0, h.length));
    d.setAuthTag(buf.subarray(buf.length - 16));
    return Buffer.concat([d.update(buf.subarray(h.length + 12, buf.length - 16)), d.final()]);
  } catch (e) {
    throw errors.wrong();
  }
}

function checkIterations(h) {
  // 極端な回数を書き込まれたファイルで固まらないように
  if (h.iterations < 10000 || h.iterations > 50000000) throw errors.wrong();
}

/// パスワード・パスコードで開く (鍵も返すので、保存のときに使い回せる)
async function openWithPassword(buf, password) {
  const h = header(buf);
  if (h.kind !== 'password' && h.kind !== 'passcode') throw errors.wrong();
  checkIterations(h);
  const key = await deriveKey(password, { salt: h.salt, iterations: h.iterations, kind: h.kind });
  return { plain: open(buf, key), key };
}

async function openTwoStep(buf, password, totpSecret) {
  const h = header(buf);
  if (h.kind !== 'twoStep') throw errors.wrong();
  checkIterations(h);
  const key = await twoStepKey(password, totpSecret, { salt: h.salt, iterations: h.iterations });
  return { plain: open(buf, key), key };
}

function openWithKeyFile(buf, secret) {
  const h = header(buf);
  if (h.kind !== 'keyfile') throw errors.wrong();
  if (h.iterations !== keyFileFingerprint(secret)) throw errors.wrongKeyFile();
  const key = keyFileKey(secret, h.salt);
  return { plain: open(buf, key), key };
}

module.exports = {
  MAGIC, VERSION, DEFAULT_ITERATIONS, PASSCODE_ITERATIONS, KIND, KEYFILE_HEADER, KEYFILE_EXTENSION,
  CryptoError, errors, isEncrypted, deriveKey, newDeviceKey, deviceKey, twoStepKey,
  newKeyFileContents, keyFileSecret, keyFileFingerprint, keyFileKey, headerData, seal, header, open,
  openWithPassword, openTwoStep, openWithKeyFile,
};
