'use strict';
// フォルダ内検索 (Mac 版 Grep.swift と同じ決まり)
const fs = require('fs');
const path = require('path');
const codec = require('./codec');

const SKIPPED_DIRECTORIES = new Set(['node_modules', '.build', 'DerivedData', 'Pods', '.git']);
const MAX_FILE_SIZE = 20 * 1024 * 1024;

function escapeRegex(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

function makeRegex({ pattern, useRegex, caseSensitive }) {
  return new RegExp(useRegex ? pattern : escapeRegex(pattern), caseSensitive ? 'mu' : 'imu');
}

/// "*.txt;*.md" のようなファイル名マスク → 判定する関数。空なら全ファイル
function makeMaskMatcher(fileMask) {
  const list = String(fileMask || '').split(/[;, ]+/).filter(Boolean);
  if (list.length === 0) return () => true;
  const regs = list.map(m => new RegExp('^' + m.split('').map(c => c === '*' ? '.*' : c === '?' ? '.' : escapeRegex(c)).join('') + '$', 'i'));
  return name => regs.some(r => r.test(name));
}

function* files(root, recursive) {
  let entries;
  try {
    entries = fs.readdirSync(root, { withFileTypes: true });
  } catch (e) {
    return;
  }
  entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  for (const e of entries) {
    if (e.name.startsWith('.')) continue; // 隠しファイルは見ない
    const full = path.join(root, e.name);
    if (e.isDirectory()) {
      if (recursive && !SKIPPED_DIRECTORIES.has(e.name)) yield* files(full, recursive);
    } else if (e.isFile()) {
      yield full;
    }
  }
}

/// バイナリっぽいファイルは null
function readText(file) {
  let buf;
  try {
    if (fs.statSync(file).size > MAX_FILE_SIZE) return null;
    buf = fs.readFileSync(file);
  } catch (e) {
    return null;
  }
  const head = buf.subarray(0, 8192);
  const utf16 = (head[0] === 0xFF && head[1] === 0xFE) || (head[0] === 0xFE && head[1] === 0xFF);
  if (!utf16 && head.includes(0)) return null;
  try {
    return codec.decode(buf).text;
  } catch (e) {
    return null;
  }
}

/// onMatch({file, line (1 始まり), text}) を見つけるたびに呼ぶ。途中で止めるには isCancelled が true を返す
async function search(root, options, onMatch, isCancelled = () => false) {
  const regex = makeRegex(options);
  const matches = makeMaskMatcher(options.fileMask);
  const max = options.maxResults || 10000;
  let count = 0, scanned = 0;
  for (const file of files(root, options.recursive !== false)) {
    if (isCancelled() || count >= max) break;
    if (!matches(path.basename(file))) continue;
    const text = readText(file);
    scanned += 1;
    if (scanned % 20 === 0) await new Promise(r => setImmediate(r)); // 画面が固まらないよう、ときどき手を止める
    if (text === null) continue;
    const lines = text.split('\n');
    for (let k = 0; k < lines.length; k++) {
      if (regex.test(lines[k])) {
        onMatch({ file, line: k + 1, text: lines[k].length > 500 ? lines[k].slice(0, 500) : lines[k] });
        count += 1;
        if (count >= max) break;
      }
    }
  }
  return { count, scanned, truncated: count >= max };
}

module.exports = { search, makeRegex, makeMaskMatcher, readText, files };
