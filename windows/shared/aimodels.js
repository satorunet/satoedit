'use strict';
// AI のモデルと料金のマスタ (アプリの中に持っておく一覧表)。
// 料金は各社の一覧 API では取れないので、公式の料金ページの値をここに写してある (US ドル / 100 万トークン、標準の料金)。
// 確認した日: UPDATED。値段は変わるので目安として使い、正しい金額は各社の請求で確かめる。
// 自分で直したいときは、設定フォルダに ai-prices.json を置く ({ "モデル名": [入力, 出力] } の形。ここの値より優先される)
const UPDATED = '2026-11-18';

const SOURCES = {
  openai: 'https://developers.openai.com/api/docs/pricing',
  claude: 'https://www.anthropic.com/pricing',
  gemini: 'https://aistudio.google.com/docs/pricing',
};

// [入力, 出力] または { input, output, changes: [{ from: 'YYYY-MM-DD', input, output }] } (値上げ・値下げの予定)
const PRICES = {
  // OpenAI
  'gpt-6.2-astra': [8, 40], 'gpt-6.2-sol': [2, 10], 'gpt-6-astra': [10, 50], 'gpt-6.1-sol': [2, 10], 'gpt-6.1-terra': [1, 5],
  'gpt-6-luna': [0.10, 0.50], 'gpt-6-sol': [2, 10], 'gpt-5.6-sol': [4, 20], 'gpt-5.6-terra': [2, 12], 'gpt-5.6-luna': [0.20, 1.20],
  'gpt-5.5': [5, 30], 'gpt-5.5-pro': [30, 180], 'gpt-5.4': [2.5, 15], 'gpt-5.4-pro': [30, 180], 'gpt-5.4-mini': [0.75, 4.5], 'gpt-5.4-nano': [0.20, 1.25],
  'gpt-5.2': [1.75, 14], 'gpt-5.2-pro': [21, 168], 'gpt-5.1': [1.25, 10], 'gpt-5': [1.25, 10], 'gpt-5-mini': [0.25, 2], 'gpt-5-nano': [0.05, 0.40], 'gpt-5-pro': [15, 120],
  'gpt-4.1': [2, 8], 'gpt-4.1-mini': [0.40, 1.60], 'gpt-4o': [2.5, 10], 'gpt-4o-mini': [0.15, 0.60], 'o3-pro': [20, 80], 'o3': [2, 8],
  // Claude
  'claude-fable-5-2': [8, 40], 'claude-fable-5-1': [10, 50], 'claude-fable-5': [10, 50],
  'claude-opus-5-5': [4, 20], 'claude-opus-5': [5, 25], 'claude-opus-4-8': [5, 25], 'claude-opus-4-7': [5, 25], 'claude-opus-4-6': [5, 25],
  'claude-sonnet-5-5': [2, 10], 'claude-sonnet-5': [2, 10], 'claude-sonnet-4-6': [3, 15],
  'claude-haiku-5-5': [0.10, 0.50], 'claude-haiku-4-5': [1, 5],
  // Gemini
  'gemini-4-carbon': { input: 2, output: 10, changes: [{ from: '2026-12-01', input: 4, output: 20 }] },
  'gemini-4-argon': { input: 2, output: 10, changes: [{ from: '2026-12-01', input: 4, output: 20 }] },
  'gemini-4-hydrogen': [1.5, 7.5],
  'gemini-3.8-flash': { input: 0.75, output: 3.75, changes: [{ from: '2027-01-01', input: 1.5, output: 7.5 }] },
  'gemini-3.6-flash': { input: 0.75, output: 3.75, changes: [{ from: '2027-01-01', input: 1.5, output: 7.5 }] },
  'gemini-3.5-flash-lite': [0.30, 2.50], 'gemini-3.1-flash-lite': [0.25, 1.50], 'gemini-3.1-pro-preview': [2, 12],
  'gemini-3-flash-preview': [0.50, 3], 'gemini-2.5-flash-lite': [0.10, 0.40],
};

// かんたん選択: 接続先ごとの「最安 & 最速」と「内容重視」
const PRESETS = {
  openai: { fast: 'gpt-6-luna', quality: 'gpt-6.2-sol' },
  claude: { fast: 'claude-haiku-5-5', quality: 'claude-opus-5-5' },
  gemini: { fast: 'gemini-3.1-flash-lite', quality: 'gemini-4-carbon' },
};

/// モデルの料金 { input, output } (その日の値)。マスタに無ければ null。overrides は ai-prices.json の中身
function priceOf(model, overrides, now = new Date()) {
  const o = overrides && overrides[model];
  if (Array.isArray(o) && o.length === 2 && o.every(n => typeof n === 'number' && n >= 0)) return { input: o[0], output: o[1] };
  const p = PRICES[String(model || '').replace(/^models\//, '')];
  if (!p) return null;
  if (Array.isArray(p)) return { input: p[0], output: p[1] };
  let out = { input: p.input, output: p.output };
  const today = now.toISOString().slice(0, 10);
  for (const c of p.changes || []) if (today >= c.from) out = { input: c.input, output: c.output };
  return out;
}

/// これから料金が変わる予定 (なければ null)
function upcomingChange(model, now = new Date()) {
  const p = PRICES[model];
  if (!p || Array.isArray(p)) return null;
  const today = now.toISOString().slice(0, 10);
  return (p.changes || []).find(c => c.from > today) || null;
}

/// 日本語 1,000 字の校正 1 回ぶんの目安 (入力 1,500・出力 1,500 トークンとして)。ドル
function sampleCost(price) {
  return (1500 * price.input + 1500 * price.output) / 1000000;
}

module.exports = { UPDATED, SOURCES, PRICES, PRESETS, priceOf, upcomingChange, sampleCost };
