'use strict';
// 共同編集の通信の暗号化 (Mac 版 CollabCipher.swift と同じ決まり。Mac と Windows で一緒に編集できる)。
// ホストが共有のたびに作る「共有コード」から鍵を作り、1 通ずつ ChaCha20-Poly1305 で暗号化する。
// - ホスト→ゲストとゲスト→ホストで別の鍵を使う (はね返し対策)
// - 通し番号を暗号の中に入れて、順番の入れ替え・再送を受け付けない
// - コードを知らない相手は 1 通目から復号できず、承認の確認すら出ない
const crypto = require('crypto');

const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // 紛らわしい 0 O 1 I は使わない

/// 新しい共有コード (16 文字、4 文字ずつ区切る)
function newCode() {
  const bytes = crypto.randomBytes(16);
  const chars = Array.from(bytes, b => ALPHABET[b % ALPHABET.length]);
  return [0, 4, 8, 12].map(i => chars.slice(i, i + 4).join('')).join('-');
}

/// 入力されたコードの表記ゆれ (小文字・空白・ハイフン) をそろえる
function normalize(code) {
  return Array.from(String(code).toUpperCase()).filter(c => ALPHABET.includes(c)).join('');
}

class CollabCipher {
  constructor(code, isHost) {
    const ikm = Buffer.from(normalize(code), 'utf8');
    const salt = Buffer.from('satoru-editor collab v1', 'utf8');
    const key = label => Buffer.from(crypto.hkdfSync('sha256', ikm, salt, Buffer.from(label, 'utf8'), 32));
    const h2g = key('host->guest'), g2h = key('guest->host');
    this.sendKey = isHost ? h2g : g2h;
    this.receiveKey = isHost ? g2h : h2g;
    this.sendCounter = 0n;
    this.receiveCounter = 0n;
  }

  /// 平文 1 通 → 送る 1 行 (base64、改行なし)
  seal(plain) {
    const payload = Buffer.alloc(8 + plain.length);
    payload.writeBigUInt64BE(this.sendCounter, 0);
    Buffer.from(plain).copy(payload, 8);
    this.sendCounter += 1n;
    const nonce = crypto.randomBytes(12);
    const c = crypto.createCipheriv('chacha20-poly1305', this.sendKey, nonce, { authTagLength: 16 });
    const body = Buffer.concat([c.update(payload), c.final()]);
    return Buffer.concat([nonce, body, c.getAuthTag()]).toString('base64');
  }

  /// 受け取った 1 行 → 平文。鍵違い・改ざん・順番違いなら null
  open(line) {
    try {
      const raw = Buffer.from(String(line).trim(), 'base64');
      if (raw.length < 12 + 16 + 8) return null;
      const d = crypto.createDecipheriv('chacha20-poly1305', this.receiveKey, raw.subarray(0, 12), { authTagLength: 16 });
      d.setAuthTag(raw.subarray(raw.length - 16));
      const payload = Buffer.concat([d.update(raw.subarray(12, raw.length - 16)), d.final()]);
      if (payload.readBigUInt64BE(0) !== this.receiveCounter) return null;
      this.receiveCounter += 1n;
      return payload.subarray(8);
    } catch (e) {
      return null;
    }
  }
}

module.exports = { ALPHABET, newCode, normalize, CollabCipher };
