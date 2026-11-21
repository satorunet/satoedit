'use strict';
// AI の利用の記録と料金の目安 (Mac 版と同じ形の ~/.satoruEditor/ai-usage.json)
const fs = require('fs');
const path = require('path');

const master = require('../shared/aimodels');

// 料金のマスタは shared/aimodels.js。設定フォルダの ai-prices.json ({ "モデル名": [入力, 出力] }) があれば、そちらを優先する
let overrides = {};
function loadOverrides(file) {
  try {
    const o = JSON.parse(fs.readFileSync(file, 'utf8'));
    overrides = o && typeof o === 'object' && !Array.isArray(o) ? o : {};
  } catch (e) {
    overrides = {};
  }
  return overrides;
}
const PRICING_PAGES = Object.assign({ custom: '' }, master.SOURCES);

/// 使う単価 { input, output }: マスタ (公開されている料金) → 自分で入れた単価 → 手元の AI なら 0。分からなければ null
function price(provider, model, customPrices) {
  // マスタにあるモデルはその料金。無いモデルは、自分で入れた単価 (接続先ごと) を使う
  const known = master.priceOf(model, overrides);
  if (known) return { input: known.input, output: known.output, custom: false };
  const c = (customPrices || {})[provider];
  if (c && (c.input > 0 || c.output > 0)) return { input: Number(c.input) || 0, output: Number(c.output) || 0, custom: true };
  if (provider === 'custom') return { input: 0, output: 0, custom: false };
  return null;
}

function cost(usage, provider, model, customPrices) {
  const p = price(provider, model, customPrices);
  if (!p) return null;
  return (usage.inputTokens * p.input + usage.outputTokens * p.output) / 1000000;
}

function read(file) {
  try {
    const list = JSON.parse(fs.readFileSync(file, 'utf8'));
    return Array.isArray(list) ? list : [];
  } catch (e) {
    return [];
  }
}

function add(file, usage, provider, model, customPrices) {
  if (!usage || !(usage.inputTokens > 0 || usage.outputTokens > 0)) return;
  const list = read(file);
  const c = cost(usage, provider, model, customPrices);
  const record = { date: new Date().toISOString().replace(/\.\d+Z$/, 'Z'), provider, model, input: usage.inputTokens, output: usage.outputTokens, estimated: !!usage.estimated };
  if (c !== null) record.cost = c;
  list.push(record);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(list, null, 2));
}

function clear(file) {
  try { fs.unlinkSync(file); } catch (e) { /* もともと無い */ }
}

/// 記録 → 今日・今月・全部の合計と、月ごとの表
function summarize(records, now = new Date()) {
  const empty = () => ({ count: 0, input: 0, output: 0, cost: 0, unknownCost: false });
  const addTo = (s, r) => {
    s.count += 1; s.input += r.input || 0; s.output += r.output || 0;
    if (typeof r.cost === 'number') s.cost += r.cost; else s.unknownCost = true;
  };
  const monthKey = d => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
  const today = empty(), month = empty(), total = empty(), months = new Map();
  for (const r of records) {
    const d = new Date(r.date);
    if (isNaN(d)) continue;
    addTo(total, r);
    if (monthKey(d) === monthKey(now)) addTo(month, r);
    if (d.toDateString() === now.toDateString()) addTo(today, r);
    const key = monthKey(d);
    if (!months.has(key)) months.set(key, empty());
    addTo(months.get(key), r);
  }
  return { today, month, total, months: Array.from(months.entries()).sort((a, b) => (a[0] < b[0] ? 1 : -1)).map(([key, s]) => Object.assign({ month: key }, s)) };
}

module.exports = { loadOverrides, PRICING_PAGES, price, cost, read, add, clear, summarize };
