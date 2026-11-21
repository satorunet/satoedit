'use strict';
// ローカル LLM (Ollama) を、入れる・起動する・モデルを入れる・消す (本体側)。
// Windows では、公式の配布ファイル (OllamaSetup.exe) を取ってきて、正規の署名かを確かめてから起動する
const fs = require('fs');
const os = require('os');
const path = require('path');
const https = require('https');
const http = require('http');
const { spawn, execFile } = require('child_process');
const llm = require('../shared/localllm');

/// Ollama が入っている場所 (見つからなければ null)
function findOllama() {
  const local = process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local');
  const candidates = [
    path.join(local, 'Programs', 'Ollama', 'ollama app.exe'),
    path.join(local, 'Programs', 'Ollama', 'ollama.exe'),
    path.join(process.env.ProgramFiles || 'C:\\Program Files', 'Ollama', 'ollama app.exe'),
    path.join(process.env.ProgramFiles || 'C:\\Program Files', 'Ollama', 'ollama.exe'),
  ];
  return candidates.find(p => { try { return fs.statSync(p).isFile(); } catch (_) { return false; } }) || null;
}

function request(method, urlPath, body, { timeout = 3000 } = {}) {
  return new Promise((resolve, reject) => {
    const data = body ? Buffer.from(JSON.stringify(body)) : null;
    const req = http.request(llm.SERVER + urlPath, { method, timeout, headers: data ? { 'Content-Type': 'application/json', 'Content-Length': data.length } : {} }, res => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, text: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    if (data) req.write(data);
    req.end();
  });
}

/// いまの様子: 動いているか・入っているか・入っているモデル・この PC の Windows で動くか
async function status() {
  let running = false, models = [];
  try {
    const r = await request('GET', '/api/tags');
    running = r.status === 200;
    if (running) models = llm.parseTags(r.text);
  } catch (_) { running = false; }
  const build = process.platform === 'win32' ? llm.buildOf(os.release()) : 0;
  return { running, installed: running || !!findOllama(), models, platform: process.platform, release: os.release(), build };
}

/// 公式の説明書から、必要な Windows のビルド番号を読む (読めなければ控えの値)
function requiredBuild() {
  return new Promise(resolve => {
    const req = https.get(llm.REQUIREMENTS_URL, { timeout: 8000 }, res => {
      if (res.statusCode !== 200) { res.resume(); resolve({ build: llm.FALLBACK_MIN_BUILD, checked: false }); return; }
      let text = '';
      res.setEncoding('utf8');
      res.on('data', c => { text += c; });
      res.on('end', () => {
        const b = llm.parseRequiredBuild(text);
        resolve({ build: b || llm.FALLBACK_MIN_BUILD, checked: !!b });
      });
    });
    req.on('timeout', () => req.destroy());
    req.on('error', () => resolve({ build: llm.FALLBACK_MIN_BUILD, checked: false }));
  });
}

/// https で取ってくる (転送先へもついていく)。onProgress(受け取った, 全部)
function download(url, dest, onProgress, signal, redirects = 5) {
  return new Promise((resolve, reject) => {
    const req = https.get(url, res => {
      if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location && redirects > 0) {
        res.resume();
        download(new URL(res.headers.location, url).toString(), dest, onProgress, signal, redirects - 1).then(resolve, reject);
        return;
      }
      if (res.statusCode !== 200) { res.resume(); reject(new Error('HTTP ' + res.statusCode)); return; }
      const total = Number(res.headers['content-length']) || 0;
      let got = 0, last = 0;
      const out = fs.createWriteStream(dest);
      res.on('data', c => {
        got += c.length;
        const now = Date.now();
        if (now - last > 200) { last = now; onProgress(got, total); }
      });
      res.pipe(out);
      out.on('finish', () => { onProgress(got, total); resolve(); });
      out.on('error', reject);
      res.on('error', reject);
    });
    req.on('error', reject);
    if (signal) signal.cancel = () => req.destroy(new Error('cancelled'));
  });
}

/// 署名を確かめる: 正しく署名されていて、署名した会社が Ollama か
function verifySignature(file) {
  return new Promise(resolve => {
    if (process.platform !== 'win32') { resolve({ ok: false, reason: 'not windows' }); return; }
    const ps = `$s = Get-AuthenticodeSignature -LiteralPath '${file.replace(/'/g, "''")}'; Write-Output ($s.Status.ToString() + '|' + $s.SignerCertificate.Subject)`;
    execFile('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', ps], { timeout: 60000, windowsHide: true }, (err, stdout) => {
      if (err) { resolve({ ok: false, reason: String(err.message || err) }); return; }
      const [state, subject] = String(stdout).trim().split('|');
      resolve({ ok: state === 'Valid' && /Ollama/i.test(subject || ''), reason: `${state} ${subject || ''}`.trim() });
    });
  });
}

/// 取ってきて、確かめて、配布ファイル (インストーラ) を起動する
async function install(onProgress, signal) {
  const dest = path.join(os.tmpdir(), `OllamaSetup-${Date.now()}.exe`);
  try {
    await download(llm.INSTALLER_URL, dest, onProgress, signal);
    const sig = await verifySignature(dest);
    if (!sig.ok) throw new Error('signature: ' + sig.reason);
    // インストーラの画面が出る (管理者の権限は要らない。ホームフォルダに入る)
    spawn(dest, [], { detached: true, stdio: 'ignore' }).unref();
    return { ok: true };
  } catch (e) {
    try { fs.unlinkSync(dest); } catch (_) { /* なし */ }
    throw e;
  }
}

/// 入っている Ollama を起動する
function start() {
  const exe = findOllama();
  if (!exe) return false;
  const args = /ollama\.exe$/i.test(exe) ? ['serve'] : [];
  spawn(exe, args, { detached: true, stdio: 'ignore', windowsHide: true }).unref();
  return true;
}

/// モデルを取ってくる。onProgress(llm.parseProgress の結果)
function pull(name, onProgress, signal) {
  return new Promise((resolve, reject) => {
    if (!llm.isValidModelName(name)) { reject(new Error('bad name')); return; }
    const data = Buffer.from(JSON.stringify({ model: name, stream: true }));
    const req = http.request(llm.SERVER + '/api/pull', { method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': data.length } }, res => {
      let buf = '', lastError = null, done = false;
      res.setEncoding('utf8');
      res.on('data', c => {
        buf += c;
        let nl;
        while ((nl = buf.indexOf('\n')) >= 0) {
          const p = llm.parseProgress(buf.slice(0, nl));
          buf = buf.slice(nl + 1);
          if (!p) continue;
          if (p.error) lastError = p.error;
          if (p.done) done = true;
          onProgress(p);
        }
      });
      res.on('end', () => (lastError ? reject(new Error(lastError)) : resolve({ done })));
      res.on('error', reject);
    });
    req.on('error', reject);
    if (signal) signal.cancel = () => req.destroy(new Error('cancelled'));
    req.write(data);
    req.end();
  });
}

async function remove(name) {
  if (!llm.isValidModelName(name)) return false;
  const r = await request('DELETE', '/api/delete', { model: name }, { timeout: 30000 });
  return r.status === 200;
}

module.exports = { status, requiredBuild, install, start, pull, remove, findOllama };
