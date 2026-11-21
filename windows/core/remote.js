'use strict';
// サーバのファイルのやりとり (SFTP / FTP / FTPS)。
// SFTP で初めてつなぐサーバの鍵は自動で登録し、あとで変わったときは接続を止める (なりすまし対策)
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { Writable, Readable } = require('stream');
const { t } = require('../shared/i18n');

const KINDS = [
  { id: 'sftp', label: 'SFTP (SSH)', port: 22 },
  { id: 'ftp', label: 'FTP', port: 21 },
  { id: 'ftps', label: 'FTPS (FTP + TLS)', port: 21 },
];
const MAX_FILE_SIZE = 50 * 1024 * 1024;
const TIMEOUT = 20000;

function kindInfo(id) { return KINDS.find(k => k.id === id) || KINDS[0]; }

/// サーバの上の場所をつなぐ (いつも / 区切り)
function joinPath(dir, name) {
  if (name === '..') {
    const parts = String(dir).split('/').filter(Boolean);
    parts.pop();
    return '/' + parts.join('/');
  }
  return (String(dir).replace(/\/+$/, '') || '') + '/' + name;
}

function sortEntries(list) {
  return list.filter(e => e.name !== '.' && e.name !== '..')
    .sort((a, b) => (a.dir !== b.dir ? (a.dir ? -1 : 1) : a.name.localeCompare(b.name, 'ja')));
}

// ---------- SFTP ----------

function fingerprint(key) {
  return 'SHA256:' + crypto.createHash('sha256').update(key).digest('base64').replace(/=+$/, '');
}

/// 覚えているサーバの鍵 (known-hosts.json) と比べる。初めてなら登録する
function checkHostKey(file, server, key) {
  let known = {};
  try { known = JSON.parse(fs.readFileSync(file, 'utf8')) || {}; } catch (e) { known = {}; }
  const id = `${server.host}:${server.port}`;
  const fp = fingerprint(key);
  if (!known[id]) {
    known[id] = fp;
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify(known, null, 2));
    return true;
  }
  return known[id] === fp;
}

function sftpConnect(server, secret, knownHostsFile) {
  const { Client } = require('ssh2');
  return new Promise((resolve, reject) => {
    const conn = new Client();
    let keyChanged = false, settled = false;
    const fail = e => { if (!settled) { settled = true; conn.end(); reject(e); } };
    const options = {
      host: server.host, port: server.port || 22, username: server.user, readyTimeout: TIMEOUT, keepaliveInterval: 15000,
      hostVerifier: key => {
        const ok = checkHostKey(knownHostsFile, server, key);
        if (!ok) keyChanged = true;
        return ok;
      },
    };
    if (server.auth === 'key') {
      try {
        options.privateKey = fs.readFileSync(server.keyFile);
      } catch (e) {
        return reject(new Error(t('鍵ファイルを読めません: {file}', { file: server.keyFile || '' })));
      }
      if (secret) options.passphrase = secret;
    } else {
      options.password = secret || '';
      // パスワードを「キーボード入力」として聞いてくるサーバにも答える
      options.tryKeyboard = true;
      conn.on('keyboard-interactive', (name, instructions, lang, prompts, finish) => finish(prompts.map(() => secret || '')));
    }
    conn.on('ready', () => {
      conn.sftp((err, sftp) => {
        if (err) return fail(err);
        settled = true;
        resolve({ conn, sftp });
      });
    });
    conn.on('error', e => {
      if (keyChanged) return fail(new Error(t('サーバの鍵が前と違います。なりすましのおそれがあるので接続をやめました。サーバを作り直したのなら、サーバの設定で「覚えている鍵を忘れる」を押してください。')));
      if (e.level === 'client-authentication') return fail(new Error(t('ログインできませんでした。ユーザー名とパスワード (または鍵) を確かめてください。')));
      fail(new Error(t('接続できませんでした: ') + e.message));
    });
    try { conn.connect(options); } catch (e) { fail(new Error(t('接続できませんでした: ') + e.message)); }
  });
}

function sftpClient(server, secret, knownHostsFile) {
  let link = null;
  const open = async () => { if (!link) link = await sftpConnect(server, secret, knownHostsFile); return link.sftp; };
  const call = (fn, ...args) => new Promise((resolve, reject) => fn(...args, (err, value) => (err ? reject(err) : resolve(value))));
  return {
    async home() {
      const sftp = await open();
      return call(sftp.realpath.bind(sftp), '.');
    },
    async list(dir) {
      const sftp = await open();
      const items = await call(sftp.readdir.bind(sftp), dir);
      const out = [];
      for (const it of items) {
        let isDir = it.attrs.isDirectory();
        // リンクは、指している先がフォルダかどうかを見る
        if (it.attrs.isSymbolicLink()) {
          try { isDir = (await call(sftp.stat.bind(sftp), joinPath(dir, it.filename))).isDirectory(); } catch (e) { isDir = false; }
        }
        out.push({ name: it.filename, dir: isDir, size: it.attrs.size, mtime: it.attrs.mtime * 1000 });
      }
      return sortEntries(out);
    },
    async read(file) {
      const sftp = await open();
      const st = await call(sftp.stat.bind(sftp), file);
      if (st.size > MAX_FILE_SIZE) throw new Error(t('大きすぎるファイルです (50 MB まで)。'));
      return call(sftp.readFile.bind(sftp), file);
    },
    async write(file, data) {
      const sftp = await open();
      // 権限 (実行できる・できない など) は、もとのファイルのまま残す
      let mode;
      try { mode = (await call(sftp.stat.bind(sftp), file)).mode; } catch (e) { mode = undefined; }
      await call(sftp.writeFile.bind(sftp), file, data, mode === undefined ? {} : { mode: mode & 0o7777 });
    },
    async mkdir(dir) { const sftp = await open(); await call(sftp.mkdir.bind(sftp), dir); },
    async remove(file, isDir) { const sftp = await open(); await call((isDir ? sftp.rmdir : sftp.unlink).bind(sftp), file); },
    async rename(from, to) { const sftp = await open(); await call(sftp.rename.bind(sftp), from, to); },
    close() { if (link) { link.conn.end(); link = null; } },
  };
}

// ---------- FTP / FTPS ----------

function ftpClient(server, secret) {
  const ftp = require('basic-ftp');
  let client = null;
  const open = async () => {
    if (client && !client.closed) return client;
    client = new ftp.Client(TIMEOUT);
    try {
      await client.access({ host: server.host, port: server.port || 21, user: server.user || 'anonymous', password: secret || '', secure: server.kind === 'ftps' });
    } catch (e) {
      client.close();
      client = null;
      if (e.code === 530 || e.code === 430) throw new Error(t('ログインできませんでした。ユーザー名とパスワード (または鍵) を確かめてください。'));
      throw new Error(t('接続できませんでした: ') + e.message);
    }
    return client;
  };
  // FTP は 1 つの接続で同時に 1 つのことしかできないので、順番に行う
  let queue = Promise.resolve();
  const serial = fn => { const p = queue.then(fn, fn); queue = p.catch(() => {}); return p; };
  return {
    home() { return serial(async () => (await open()).pwd()); },
    list(dir) {
      return serial(async () => {
        const c = await open();
        const items = await c.list(dir);
        return sortEntries(items.map(it => ({ name: it.name, dir: it.isDirectory || (it.isSymbolicLink && !it.size), size: it.size, mtime: it.modifiedAt ? it.modifiedAt.getTime() : 0 })));
      });
    },
    read(file) {
      return serial(async () => {
        const c = await open();
        const chunks = [];
        let total = 0;
        const sink = new Writable({
          write(chunk, enc, done) {
            total += chunk.length;
            if (total > MAX_FILE_SIZE) return done(new Error(t('大きすぎるファイルです (50 MB まで)。')));
            chunks.push(chunk);
            done();
          },
        });
        await c.downloadTo(sink, file);
        return Buffer.concat(chunks);
      });
    },
    write(file, data) { return serial(async () => { const c = await open(); await c.uploadFrom(Readable.from([data]), file); }); },
    mkdir(dir) { return serial(async () => { const c = await open(); await c.send('MKD ' + dir); }); },
    remove(file, isDir) { return serial(async () => { const c = await open(); if (isDir) await c.send('RMD ' + file); else await c.remove(file); }); },
    rename(from, to) { return serial(async () => { const c = await open(); await c.rename(from, to); }); },
    close() { if (client) { client.close(); client = null; } },
  };
}

/// server: { kind, host, port, user, auth ('password' | 'key'), keyFile }。secret はパスワード (鍵のときはパスフレーズ)
function connect(server, secret, knownHostsFile) {
  return server.kind === 'sftp' ? sftpClient(server, secret, knownHostsFile) : ftpClient(server, secret);
}

/// 覚えているサーバの鍵を忘れる (サーバを作り直したとき)
function forgetHostKey(file, server) {
  let known = {};
  try { known = JSON.parse(fs.readFileSync(file, 'utf8')) || {}; } catch (e) { return; }
  delete known[`${server.host}:${server.port}`];
  fs.writeFileSync(file, JSON.stringify(known, null, 2));
}

function displayName(server) {
  return server.name || `${server.user ? server.user + '@' : ''}${server.host}`;
}

function url(server, file) {
  const port = server.port && server.port !== kindInfo(server.kind).port ? ':' + server.port : '';
  return `${server.kind}://${server.user ? server.user + '@' : ''}${server.host}${port}${file}`;
}

module.exports = { KINDS, kindInfo, joinPath, connect, forgetHostKey, fingerprint, checkHostKey, displayName, url };
