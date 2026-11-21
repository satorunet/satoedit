'use strict';
// JS 拡張機能のファイルまわり (本体側): 一覧・入れる (URL / フォルダ / zip)・外す・ひな形。
// 中身を動かすのは画面側 (Web Worker の中。ファイルやネットには直接触れない)
const fs = require('fs');
const os = require('os');
const path = require('path');
const https = require('https');
const http = require('http');
const zip = require('./zip');
const pm = require('../shared/pluginmanifest');
const docs = require('../shared/plugindocs');

function pluginsDir(configDir) { return path.join(configDir, 'plugins'); }

/// 入っている拡張機能。[{ manifest, folder, source, icon (data: の URL か絵文字), error }]
function list(configDir) {
  const dir = pluginsDir(configDir);
  let names = [];
  try { names = fs.readdirSync(dir, { withFileTypes: true }).filter(d => d.isDirectory() && !d.name.startsWith('.')).map(d => d.name).sort(); } catch (_) { return []; }
  const seen = new Set(), out = [];
  for (const name of names) {
    const folder = path.join(dir, name);
    let manifest;
    try { manifest = pm.parse(fs.readFileSync(path.join(folder, 'manifest.json'), 'utf8')); } catch (_) { continue; }
    if (seen.has(manifest.id)) continue;
    seen.add(manifest.id);
    const entry = { manifest, folder, source: '', icon: manifest.icon && !manifest.icon.includes('.') ? manifest.icon : '🧩', error: null };
    try {
      // フォルダの外 (シンボリックリンクの先など) は読まない
      const main = fs.realpathSync(path.join(folder, manifest.main));
      if (!main.startsWith(fs.realpathSync(folder) + path.sep)) throw new Error(manifest.main + ' outside');
      entry.source = fs.readFileSync(main, 'utf8');
    } catch (e) { entry.error = String(e.message || e); }
    if (manifest.icon && manifest.icon.includes('.') && !manifest.icon.includes('..')) {
      try {
        const img = fs.readFileSync(path.join(folder, manifest.icon));
        const ext = path.extname(manifest.icon).slice(1).toLowerCase();
        entry.icon = `data:image/${ext === 'svg' ? 'svg+xml' : ext};base64,` + img.toString('base64');
      } catch (_) { /* 絵文字のまま */ }
    }
    out.push(entry);
  }
  return out;
}

function get(url, redirects = 5, maxBytes = 20 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const lib = url.startsWith('https:') ? https : http;
    const req = lib.get(url, { headers: { 'User-Agent': 'satoruEditor' }, timeout: 30000 }, res => {
      if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location && redirects > 0) {
        res.resume();
        get(new URL(res.headers.location, url).toString(), redirects - 1, maxBytes).then(resolve, reject);
        return;
      }
      if (res.statusCode !== 200) { res.resume(); reject(new Error('HTTP ' + res.statusCode)); return; }
      const chunks = [];
      let size = 0;
      res.on('data', c => { size += c.length; if (size > maxBytes) req.destroy(new Error('too large')); else chunks.push(c); });
      res.on('end', () => resolve(Buffer.concat(chunks)));
      res.on('error', reject);
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
  });
}

/// manifest.json のある所 (そのもの、または 1 段下。GitHub の zip は repo-main/ の下に入っている)
function findRoot(files) {
  const names = files.map(f => f.name);
  if (names.includes('manifest.json')) return '';
  const tops = new Set(names.filter(n => !n.startsWith('__MACOSX/')).map(n => n.split('/')[0] + '/'));
  for (const t of tops) if (names.includes(t + 'manifest.json')) return t;
  return null;
}

/// 入れる準備: 取ってきて (または読んで)、中身を確かめる。まだ入れない
/// from: { url } か { path } (フォルダか .zip)。→ { files: [{ rel, data }], manifest, source }
async function prepare(from) {
  let files;
  let sourceText;
  if (from.url) {
    const url = pm.downloadURL(from.url);
    if (!url) throw new Error('badURL');
    files = zip.extract(await get(url)).map(e => ({ name: e.name, data: e.data }));
    sourceText = String(from.url).trim();
  } else {
    const p = String(from.path || '');
    const st = fs.statSync(p);
    if (st.isDirectory()) {
      files = [];
      const walk = (dir, rel) => {
        for (const d of fs.readdirSync(dir, { withFileTypes: true })) {
          if (d.name.startsWith('.')) continue;
          const full = path.join(dir, d.name), r = rel ? rel + '/' + d.name : d.name;
          if (d.isDirectory()) walk(full, r);
          else if (d.isFile()) files.push({ name: r, data: fs.readFileSync(full) });
          if (files.length > 2000) throw new Error('too many files');
        }
      };
      walk(p, '');
    } else {
      files = zip.extract(fs.readFileSync(p));
    }
    sourceText = p;
  }
  const root = findRoot(files);
  if (root === null) throw new Error('noManifest');
  const inside = files.filter(f => f.name.startsWith(root) && !f.name.startsWith('__MACOSX/')).map(f => ({ rel: f.name.slice(root.length), data: f.data }));
  const mf = inside.find(f => f.rel === 'manifest.json');
  let manifest;
  try { manifest = pm.parse(mf.data.toString('utf8')); } catch (e) { throw new Error('badManifest: ' + e.message); }
  if (!inside.some(f => f.rel === manifest.main)) throw new Error('noMain: ' + manifest.main);
  return { files: inside, manifest, source: sourceText };
}

/// 準備したものを ~/.satoruEditor/plugins/<id> に入れる (前のは trash でごみ箱へ)
async function commit(configDir, prepared, trash) {
  const dir = pluginsDir(configDir);
  fs.mkdirSync(dir, { recursive: true });
  const dest = path.join(dir, prepared.manifest.id);
  for (const old of list(configDir).filter(p => p.manifest.id === prepared.manifest.id).map(p => p.folder).concat([dest])) {
    if (fs.existsSync(old)) await trash(old);
  }
  for (const f of prepared.files) {
    const target = path.join(dest, ...f.rel.split('/'));
    if (!target.startsWith(dest + path.sep)) throw new Error('unsafe path');
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, f.data);
  }
  return dest;
}

/// ひな形を作る。main.js の場所を返す
function createTemplate(configDir, id) {
  const m = { id, name: id, version: '1.0.0', author: '', description: '', icon: '🧩', main: 'main.js', permissions: [] };
  pm.validate(Object.assign({ permissions: [] }, m));
  const dir = path.join(pluginsDir(configDir), id);
  if (fs.existsSync(dir)) throw new Error('exists');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'manifest.json'), JSON.stringify(m, null, 2) + '\n');
  fs.writeFileSync(path.join(dir, 'main.js'), docs.TEMPLATE);
  writeDocs(configDir);
  return path.join(dir, 'main.js');
}

function writeDocs(configDir) {
  const dir = pluginsDir(configDir);
  fs.mkdirSync(dir, { recursive: true });
  const p = path.join(dir, 'README.md');
  fs.writeFileSync(p, docs.README);
  return p;
}

/// 拡張機能の satoru.fetch (network の権限があるときだけ)。→ { status, headers, body }
function fetchFor(configDir, id, url, opts) {
  const p = list(configDir).find(x => x.manifest.id === id);
  if (!p || !pm.has(p.manifest, 'network')) return Promise.reject(new Error('no network permission'));
  let u;
  try { u = new URL(String(url)); } catch (_) { return Promise.reject(new Error('bad URL')); }
  if (!/^https?:$/.test(u.protocol)) return Promise.reject(new Error('bad URL'));
  const o = opts || {};
  return new Promise((resolve, reject) => {
    const lib = u.protocol === 'https:' ? https : http;
    const body = typeof o.body === 'string' ? Buffer.from(o.body) : null;
    const headers = Object.assign({}, o.headers || {});
    if (body) headers['Content-Length'] = body.length;
    const req = lib.request(u, { method: String(o.method || 'GET').toUpperCase(), headers, timeout: 30000 }, res => {
      const chunks = [];
      let size = 0;
      res.on('data', c => { size += c.length; if (size > 10 * 1024 * 1024) req.destroy(new Error('too large')); else chunks.push(c); });
      res.on('end', () => {
        const h = {};
        for (const [k, v] of Object.entries(res.headers)) h[k.toLowerCase()] = Array.isArray(v) ? v.join(', ') : String(v);
        resolve({ status: res.statusCode, headers: h, body: Buffer.concat(chunks).toString('utf8') });
      });
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

module.exports = { pluginsDir, list, prepare, commit, createTemplate, writeDocs, fetchFor };
