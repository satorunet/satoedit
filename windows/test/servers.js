'use strict';
// テスト用の小さな SFTP サーバと FTP サーバ (この PC の中だけで動く)。フォルダ root の中身を見せる
const fs = require('fs');
const path = require('path');

function startSFTP(root, { user, password }) {
  const { Server, utils } = require('ssh2');
  const { STATUS_CODE, flagsToString } = utils.sftp;
  const hostKey = utils.generateKeyPairSync('ed25519');
  const local = p => path.join(root, path.posix.normalize('/' + p));
  const attrsOf = st => ({ mode: st.mode, uid: 0, gid: 0, size: st.size, atime: Math.floor(st.atimeMs / 1000), mtime: Math.floor(st.mtimeMs / 1000) });
  const server = new Server({ hostKeys: [hostKey.private] }, client => {
    client.on('authentication', ctx => {
      if (ctx.method === 'password' && ctx.username === user && ctx.password === password) ctx.accept();
      else ctx.reject(['password']);
    });
    client.on('error', () => {});
    client.on('ready', () => client.on('session', accept => {
      accept().on('sftp', acceptSftp => {
        const sftp = acceptSftp();
        const handles = new Map();
        let next = 0;
        const newHandle = value => { const h = Buffer.alloc(4); h.writeUInt32BE(next, 0); handles.set(next, value); next += 1; return h; };
        const get = h => handles.get(h.readUInt32BE(0));
        const guard = (reqid, fn) => { try { fn(); } catch (e) { sftp.status(reqid, e.code === 'ENOENT' ? STATUS_CODE.NO_SUCH_FILE : STATUS_CODE.FAILURE); } };
        sftp.on('REALPATH', (reqid, p) => sftp.name(reqid, [{ filename: path.posix.normalize('/' + (p === '.' ? '' : p)), longname: '', attrs: {} }]));
        const stat = (reqid, p) => guard(reqid, () => sftp.attrs(reqid, attrsOf(fs.statSync(local(p)))));
        sftp.on('STAT', stat);
        sftp.on('LSTAT', stat);
        sftp.on('FSTAT', (reqid, h) => guard(reqid, () => sftp.attrs(reqid, attrsOf(fs.fstatSync(get(h).fd)))));
        sftp.on('OPEN', (reqid, p, flags, attrs) => guard(reqid, () => {
          const fd = fs.openSync(local(p), flagsToString(flags), attrs && attrs.mode ? attrs.mode : 0o644);
          sftp.handle(reqid, newHandle({ fd }));
        }));
        sftp.on('READ', (reqid, h, offset, length) => guard(reqid, () => {
          const buf = Buffer.alloc(length);
          const n = fs.readSync(get(h).fd, buf, 0, length, offset);
          if (n === 0) sftp.status(reqid, STATUS_CODE.EOF); else sftp.data(reqid, buf.subarray(0, n));
        }));
        sftp.on('WRITE', (reqid, h, offset, data) => guard(reqid, () => { fs.writeSync(get(h).fd, data, 0, data.length, offset); sftp.status(reqid, STATUS_CODE.OK); }));
        sftp.on('CLOSE', (reqid, h) => guard(reqid, () => { const v = get(h); if (v && v.fd !== undefined) fs.closeSync(v.fd); handles.delete(h.readUInt32BE(0)); sftp.status(reqid, STATUS_CODE.OK); }));
        sftp.on('OPENDIR', (reqid, p) => guard(reqid, () => {
          const names = fs.readdirSync(local(p));
          sftp.handle(reqid, newHandle({ dir: local(p), names, sent: false }));
        }));
        sftp.on('READDIR', (reqid, h) => guard(reqid, () => {
          const v = get(h);
          if (v.sent) return sftp.status(reqid, STATUS_CODE.EOF);
          v.sent = true;
          sftp.name(reqid, v.names.map(n => ({ filename: n, longname: n, attrs: attrsOf(fs.statSync(path.join(v.dir, n))) })));
        }));
        sftp.on('MKDIR', (reqid, p) => guard(reqid, () => { fs.mkdirSync(local(p)); sftp.status(reqid, STATUS_CODE.OK); }));
        sftp.on('RMDIR', (reqid, p) => guard(reqid, () => { fs.rmdirSync(local(p)); sftp.status(reqid, STATUS_CODE.OK); }));
        sftp.on('REMOVE', (reqid, p) => guard(reqid, () => { fs.unlinkSync(local(p)); sftp.status(reqid, STATUS_CODE.OK); }));
        sftp.on('RENAME', (reqid, from, to) => guard(reqid, () => { fs.renameSync(local(from), local(to)); sftp.status(reqid, STATUS_CODE.OK); }));
        const ok = reqid => sftp.status(reqid, STATUS_CODE.OK);
        sftp.on('SETSTAT', ok);
        sftp.on('FSETSTAT', ok);
      });
    }));
  });
  return new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve({ port: server.address().port, close: () => server.close() })));
}

async function startFTP(root, { user, password }) {
  const FtpSrv = require('ftp-srv');
  const net = require('net');
  // 空いているポートを 1 つもらう
  const port = await new Promise(resolve => { const s = net.createServer(); s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => resolve(p)); }); });
  const quiet = { info() {}, debug() {}, warn() {}, error() {}, trace() {}, fatal() {}, child() { return quiet; } };
  const server = new FtpSrv({ url: `ftp://127.0.0.1:${port}`, pasv_url: '127.0.0.1', anonymous: false, log: quiet });
  server.on('login', ({ username, password: pw }, resolve, reject) => {
    if (username === user && pw === password) resolve({ root }); else reject(new Error('bad login'));
  });
  await server.listen();
  return { port, close: () => server.close() };
}

module.exports = { startSFTP, startFTP };
