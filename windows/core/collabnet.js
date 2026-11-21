'use strict';
// 共同編集の TCP の接続。メッセージは JSON を共有コードの鍵で暗号化し、base64 にして 1 行ずつ送る (Mac 版と同じ)。
// ここは通信だけを受け持ち、だれが参加しているか・文章のすり合わせは画面側 (renderer/src/collab.js) が行う
const net = require('net');
const os = require('os');
const { CollabCipher } = require('./collabcipher');

const DEFAULT_PORT = 7650;
const MAX_LINE = 64 * 1024 * 1024;

/// 1 本の接続。onMessage(obj) / onClose({ decryptedAny, decryptFailed })
class Peer {
  constructor(socket, cipher) {
    this.socket = socket;
    this.cipher = cipher;
    this.buffer = '';
    this.decryptedAny = false;
    this.decryptFailed = false;
    this.closed = false;
    this.onMessage = () => {};
    this.onClose = () => {};
    socket.setEncoding('utf8');
    socket.setNoDelay(true);
    socket.on('data', chunk => this.receive(chunk));
    socket.on('close', () => this.finish());
    socket.on('error', () => this.finish());
  }

  get remoteAddress() { return String(this.socket.remoteAddress || '').replace(/^::ffff:/, ''); }

  receive(chunk) {
    this.buffer += chunk;
    let nl;
    while ((nl = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, nl);
      this.buffer = this.buffer.slice(nl + 1);
      // 鍵が違う・改ざん・順番違いなら、その場で切る
      const plain = this.cipher.open(line);
      let obj = null;
      if (plain) { try { obj = JSON.parse(plain.toString('utf8')); } catch (e) { obj = null; } }
      if (!obj || typeof obj !== 'object') { this.decryptFailed = true; this.cancel(); return; }
      this.decryptedAny = true;
      this.onMessage(obj);
    }
    if (this.buffer.length > MAX_LINE) this.cancel();
  }

  send(message) {
    if (this.closed) return;
    this.socket.write(this.cipher.seal(Buffer.from(JSON.stringify(message), 'utf8')) + '\n');
  }

  cancel() {
    this.socket.destroy();
    this.finish();
  }

  finish() {
    if (this.closed) return;
    this.closed = true;
    this.onClose({ decryptedAny: this.decryptedAny, decryptFailed: this.decryptFailed });
  }
}

/// この PC のアドレス (IPv4、ループバックとリンクローカルを除く)
function localAddresses() {
  const out = [];
  for (const list of Object.values(os.networkInterfaces())) {
    for (const a of list || []) {
      if ((a.family === 'IPv4' || a.family === 4) && !a.internal && !a.address.startsWith('169.254.')) out.push(a.address);
    }
  }
  return out;
}

/// 共有を始める (ホスト)。events: { onOpen(id, address), onMessage(id, obj), onClose(id, info) }
function host(port, code, events) {
  return new Promise((resolve, reject) => {
    const peers = new Map();
    let next = 1;
    const server = net.createServer(socket => {
      const id = next++;
      const peer = new Peer(socket, new CollabCipher(code, true));
      peers.set(id, peer);
      peer.onMessage = obj => events.onMessage(id, obj);
      peer.onClose = info => { peers.delete(id); events.onClose(id, info); };
      events.onOpen(id, peer.remoteAddress);
    });
    server.once('error', e => reject(e.code === 'EADDRINUSE' ? Object.assign(new Error('port in use'), { code: 'EADDRINUSE' }) : e));
    server.listen(port, () => {
      server.removeAllListeners('error');
      server.on('error', () => {});
      resolve({
        port: server.address().port,
        send(id, msg) { const p = peers.get(id); if (p) p.send(msg); },
        close(id) { const p = peers.get(id); if (p) p.cancel(); },
        stop() { server.close(); for (const p of peers.values()) p.cancel(); peers.clear(); },
      });
    });
  });
}

/// 参加する (ゲスト)。つながったら events.onOpen(0, address)
function join(address, port, code, events) {
  const socket = net.connect({ host: address, port });
  const peer = new Peer(socket, new CollabCipher(code, false));
  peer.onMessage = obj => events.onMessage(0, obj);
  peer.onClose = info => events.onClose(0, info);
  socket.once('connect', () => events.onOpen(0, address));
  socket.setTimeout(15000, () => { if (!peer.decryptedAny) peer.cancel(); });
  socket.once('data', () => socket.setTimeout(0));
  return {
    send(id, msg) { peer.send(msg); },
    close() { peer.cancel(); },
    stop() { peer.cancel(); },
  };
}

module.exports = { DEFAULT_PORT, localAddresses, host, join, Peer };
