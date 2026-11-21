'use strict';
// JS 拡張機能の manifest.json (Mac 版の PluginManifest と同じ決まり)
const PERMISSIONS = ['network', 'clipboard'];

/// 読んで、中身が正しいか確かめる。だめなら Error (message に理由)
function parse(text) {
  let o;
  try { o = typeof text === 'string' ? JSON.parse(text) : text; } catch (e) { throw new Error('badJSON: ' + e.message); }
  if (!o || typeof o !== 'object' || typeof o.id !== 'string') throw new Error('missing: id');
  const m = {
    id: o.id, name: typeof o.name === 'string' ? o.name : o.id, version: typeof o.version === 'string' ? o.version : '0.0.0',
    author: typeof o.author === 'string' ? o.author : '', description: typeof o.description === 'string' ? o.description : '',
    main: typeof o.main === 'string' ? o.main : 'main.js', permissions: Array.isArray(o.permissions) ? o.permissions.map(String) : [],
    homepage: typeof o.homepage === 'string' ? o.homepage : null, icon: typeof o.icon === 'string' ? o.icon : null,
  };
  validate(m);
  return m;
}

function validate(m) {
  // フォルダ名にも使うので、英小文字・数字・- . _ だけ
  if (!/^[a-z0-9][a-z0-9._-]{0,63}$/.test(m.id)) throw new Error('badID: ' + m.id);
  for (const p of m.permissions) if (!PERMISSIONS.includes(p)) throw new Error('unknownPermission: ' + p);
  // フォルダの外のファイルは読ませない
  if (!m.main || m.main.startsWith('/') || /^[A-Za-z]:/.test(m.main) || m.main.split(/[\\/]/).includes('..') || !m.main.endsWith('.js')) {
    throw new Error('badMain: ' + m.main);
  }
}

const has = (m, p) => m.permissions.includes(p);

/// "1.2.10" と "1.2.9" を数字ごとに比べる。a が新しければ 1
function compareVersions(a, b) {
  const parts = s => String(s).split(/[.-]/).map(x => parseInt(x, 10) || 0);
  const x = parts(a), y = parts(b);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const p = x[i] || 0, q = y[i] || 0;
    if (p !== q) return p > q ? 1 : -1;
  }
  return 0;
}

/// 貼られた URL を、zip を取りに行く URL にする (GitHub のリポジトリは既定のブランチの zip)
function downloadURL(text) {
  let s = String(text || '').trim();
  if (s.startsWith('github.com/')) s = 'https://' + s;
  let url;
  try { url = new URL(s); } catch (_) { return null; }
  if (!/^https?:$/.test(url.protocol)) return null;
  const host = url.hostname.toLowerCase();
  if (host === 'github.com' || host === 'www.github.com') {
    const comps = url.pathname.split('/').filter(Boolean);
    if (comps.length >= 2) {
      const user = comps[0];
      const repo = comps[1].replace(/\.git$/, '');
      if (comps.length >= 4 && comps[2] === 'tree') return `https://github.com/${user}/${repo}/archive/refs/heads/${comps.slice(3).join('/')}.zip`;
      if (comps.length === 2 || (comps[2] !== 'archive' && comps[2] !== 'releases')) return `https://github.com/${user}/${repo}/archive/HEAD.zip`;
    }
  }
  return url.toString();
}

/// メニューのショートカット "cmd+shift+d" を分ける (Windows では cmd も Ctrl として扱う)。だめなら null
function parseShortcut(text) {
  const parts = String(text || '').toLowerCase().split('+').map(s => s.trim());
  const key = parts[parts.length - 1];
  if (!key || key.length !== 1) return null;
  const s = { key, ctrl: false, shift: false, alt: false };
  for (const m of parts.slice(0, -1)) {
    if (['cmd', 'command', 'meta', 'ctrlorcmd', 'cmdorctrl', 'ctrl', 'control'].includes(m)) s.ctrl = true;
    else if (m === 'shift') s.shift = true;
    else if (['alt', 'option', 'opt'].includes(m)) s.alt = true;
    else return null;
  }
  if (!s.ctrl && !s.alt) return null; // 修飾キーなしの 1 文字は、普通の入力とぶつかる
  return s;
}

/// "Ctrl+Shift+D" の形 (メニューに出す・キーの見分けに使う)
function accelOf(s) {
  if (!s) return '';
  return [s.ctrl ? 'Ctrl' : '', s.alt ? 'Alt' : '', s.shift ? 'Shift' : '', s.key.toUpperCase()].filter(Boolean).join('+');
}

module.exports = { PERMISSIONS, parse, validate, has, compareVersions, downloadURL, parseShortcut, accelOf };
