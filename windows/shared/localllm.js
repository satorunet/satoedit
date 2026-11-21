'use strict';
// 自分の PC の中で動かす軽い LLM (Ollama 経由) のための、画面を持たない部分 (Mac 版の LocalLLM と同じ)
const SERVER = 'http://127.0.0.1:11434';
const OPENAI_BASE = 'http://127.0.0.1:11434/v1';
const INSTALLER_URL = 'https://ollama.com/download/OllamaSetup.exe';
const REQUIREMENTS_URL = 'https://docs.ollama.com/windows.md';
const DOWNLOAD_PAGE = 'https://ollama.com/download/windows';
/// 説明書を読めなかったときに使う、必要な Windows (10 の 22H2 = ビルド 19045)
const FALLBACK_MIN_BUILD = 19045;

const RECOMMENDED = [
  { name: 'gemma3:1b', sizeGB: 0.8, note: 'いちばん軽い。短い文章の手直し向き' },
  { name: 'qwen2.5:1.5b', sizeGB: 1.0, note: '軽い。日本語もそこそこ' },
  { name: 'qwen2.5-coder:1.5b', sizeGB: 1.0, note: '軽い。プログラム向き' },
  { name: 'llama3.2:1b', sizeGB: 1.3, note: '軽い。英語が得意' },
  { name: 'qwen2.5:3b', sizeGB: 1.9, note: '速さと賢さのバランス型' },
  { name: 'gemma3:4b', sizeGB: 3.3, note: '日本語がしっかり。メモリ 8 GB 以上で' },
];

/// GET /api/tags の返事
function parseTags(json) {
  const root = typeof json === 'string' ? safeJSON(json) : json;
  if (!root || !Array.isArray(root.models)) return [];
  return root.models.map(m => ({ name: m.name || m.model, size: Number(m.size) || 0 })).filter(m => m.name);
}

function safeJSON(s) { try { return JSON.parse(s); } catch (_) { return null; } }

/// "gemma3" と "gemma3:latest" は同じ
function sameModel(a, b) {
  const n = s => (String(s).includes(':') ? String(s).toLowerCase() : String(s).toLowerCase() + ':latest');
  return n(a) === n(b);
}

/// POST /api/pull が 1 行ずつ返す JSON
function parseProgress(line) {
  const o = safeJSON(line);
  if (!o || typeof o !== 'object') return null;
  if (o.error) return { status: '', completed: 0, total: 0, error: String(o.error), done: true, fraction: null };
  const total = Number(o.total) || 0, completed = Number(o.completed) || 0;
  const status = String(o.status || '');
  return { status, completed, total, error: null, done: status === 'success', fraction: total > 0 ? Math.min(1, completed / total) : null };
}

function sizeText(bytes) {
  const gb = bytes / 1e9;
  return gb >= 0.1 ? gb.toFixed(1) + ' GB' : Math.round(bytes / 1e6) + ' MB';
}

/// モデル名に使える文字だけか (URL やコマンドに混ぜても安全なように)
function isValidModelName(s) {
  return /^[A-Za-z0-9][A-Za-z0-9._/-]{0,80}(:[A-Za-z0-9._-]{1,40})?$/.test(String(s || ''));
}

/// 説明書の "Windows 10 22H2 or newer" から、必要なビルド番号を読む
function parseRequiredBuild(text) {
  const m = /Windows\s+(10|11)\s+(\d{2}H\d)\s+or\s+(newer|later)/i.exec(String(text || ''));
  if (!m) return null;
  const table = { '10': { '20H2': 19042, '21H1': 19043, '21H2': 19044, '22H2': 19045 }, '11': { '21H2': 22000, '22H2': 22621, '23H2': 22631, '24H2': 26100 } };
  return (table[m[1]] || {})[m[2].toUpperCase()] || null;
}

/// os.release() ("10.0.19045") のビルド番号
function buildOf(release) {
  const parts = String(release || '').split('.');
  return parts.length >= 3 ? Number(parts[2]) || 0 : 0;
}

module.exports = { SERVER, OPENAI_BASE, INSTALLER_URL, REQUIREMENTS_URL, DOWNLOAD_PAGE, FALLBACK_MIN_BUILD, RECOMMENDED,
  parseTags, sameModel, parseProgress, sizeText, isValidModelName, parseRequiredBuild, buildOf };
