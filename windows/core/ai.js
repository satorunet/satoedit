'use strict';
const { t } = require('../shared/i18n');
// AI アシスタントの通信 (Mac 版 AIClient.swift と同じ送り方)。返事は少しずつ届く
const PROVIDERS = [
  { id: 'openai', label: 'ChatGPT (OpenAI)', baseURL: 'https://api.openai.com/v1', defaultModel: '',
    keyPage: 'https://platform.openai.com/api-keys',
    guide: '1. 「キーを取りに行く」でキーを作る\n2. 下に貼り、「一覧を取得」でモデルを選ぶ\n3. 「接続テスト」' },
  { id: 'claude', label: 'Claude (Anthropic)', baseURL: 'https://api.anthropic.com', defaultModel: 'claude-opus-5-5',
    keyPage: 'https://platform.claude.com/',
    guide: '1. 「キーを取りに行く」でキーを作る\n2. 下に貼って「接続テスト」' },
  { id: 'gemini', label: 'Gemini (Google)', baseURL: 'https://generativelanguage.googleapis.com/v1beta', defaultModel: '',
    keyPage: 'https://aistudio.google.com/apikey',
    guide: '1. 「キーを取りに行く」でキーを作る\n2. 下に貼り、「一覧を取得」でモデルを選ぶ\n3. 「接続テスト」' },
  { id: 'custom', label: 'カスタム (OpenAI 互換 API: Ollama・LM Studio など)', baseURL: 'http://localhost:11434/v1', defaultModel: '',
    keyPage: '',
    guide: 'Ollama などに接続します (例: http://localhost:11434/v1)。\nキーは空でも OK。「一覧を取得」→「接続テスト」' },
];
const ANTHROPIC_VERSION = '2026-10-21';
// Claude でサーバ側の自動切り替え (安全上の理由で断られたときに別のモデルで答える) を使えるモデル
const FALLBACK_MODELS = new Set(['claude-opus-5-5', 'claude-sonnet-5-5', 'claude-opus-5', 'claude-fable-5-2', 'claude-fable-5-1']);

function provider(id) { return PROVIDERS.find(p => p.id === id) || PROVIDERS[0]; }
const trimBase = s => String(s || '').replace(/[/ ]+$/, '').trim();

function explain(status, bodyText) {
  let detail = bodyText;
  try {
    const o = JSON.parse(bodyText);
    if (o && o.error && typeof o.error.message === 'string') detail = o.error.message;
    else if (o && typeof o.message === 'string') detail = o.message;
  } catch (e) { /* JSON でなければそのまま */ }
  let head;
  if (status === 401 || status === 403) head = t('API キーが違います。');
  else if (status === 404) head = t('モデルが見つかりません。');
  else if (status === 429) head = t('上限に達したか、混んでいます。少し待ってください。');
  else if (status === 400) head = t('受け付けられませんでした。');
  else if (status >= 500) head = t('AI 側のエラーです。少し待ってください。');
  else head = t('エラー ({status})', { status });
  return head + '\n\n' + String(detail).slice(0, 600);
}

function buildRequest({ provider: p, model, apiKey, baseURL, system, prompt }) {
  const base = trimBase(baseURL);
  const headers = { 'Content-Type': 'application/json' };
  let url, body;
  if (p === 'claude') {
    url = base + '/v1/messages';
    headers['x-api-key'] = apiKey;
    headers['anthropic-version'] = ANTHROPIC_VERSION;
    body = { model, max_tokens: 16000, stream: true, system, messages: [{ role: 'user', content: prompt }] };
    if (FALLBACK_MODELS.has(model)) {
      headers['anthropic-beta'] = 'server-side-fallback-2026-07-01';
      body.fallbacks = 'default';
    }
  } else if (p === 'gemini') {
    const m = model.startsWith('models/') ? model.slice(7) : model;
    url = `${base}/models/${encodeURIComponent(m)}:streamGenerateContent?alt=sse`;
    headers['x-goog-api-key'] = apiKey;
    body = { systemInstruction: { parts: [{ text: system }] }, contents: [{ role: 'user', parts: [{ text: prompt }] }] };
  } else {
    url = base + '/chat/completions';
    if (apiKey) headers.Authorization = 'Bearer ' + apiKey;
    body = { model, stream: true, messages: [{ role: 'system', content: system }, { role: 'user', content: prompt }] };
    // OpenAI は最後に使用量を返してもらう (互換サービスは受け付けないことがあるので付けない)
    if (p === 'openai') body.stream_options = { include_usage: true };
  }
  return { url, headers, body };
}

/// 届いた 1 件 (JSON) から文章を取り出す。使用量やエラーは state に書き込む
function extractText(p, o, state) {
  if (p === 'claude') {
    if (o.type === 'message_start') {
      const u = (o.message && o.message.usage) || {};
      state.inputTokens = (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0);
    } else if (o.type === 'content_block_delta') {
      return o.delta && o.delta.type === 'text_delta' ? o.delta.text : null;
    } else if (o.type === 'message_delta') {
      if (o.usage && typeof o.usage.output_tokens === 'number') state.outputTokens = o.usage.output_tokens;
      if (o.delta && o.delta.stop_reason === 'refusal') state.error = t('AI が回答を断りました。');
    } else if (o.type === 'error') {
      state.error = (o.error && o.error.message) || t('AI 側でエラーが起きました');
    }
    return null;
  }
  if (p === 'gemini') {
    if (o.promptFeedback && o.promptFeedback.blockReason) state.error = t('安全上の理由で回答されませんでした ({reason})', { reason: o.promptFeedback.blockReason });
    if (o.usageMetadata) {
      state.inputTokens = o.usageMetadata.promptTokenCount || state.inputTokens;
      state.outputTokens = o.usageMetadata.candidatesTokenCount || state.outputTokens;
    }
    const parts = o.candidates && o.candidates[0] && o.candidates[0].content && o.candidates[0].content.parts;
    return parts ? parts.map(x => x.text || '').join('') : null;
  }
  if (o.error) state.error = o.error.message || 'エラー';
  if (o.usage) {
    state.inputTokens = o.usage.prompt_tokens || state.inputTokens;
    state.outputTokens = o.usage.completion_tokens || state.outputTokens;
  }
  const d = o.choices && o.choices[0] && o.choices[0].delta;
  return d && typeof d.content === 'string' ? d.content : null;
}

/// 送って、届いた分から onDelta に渡す。終わったら使ったトークン数を返す
async function send(o) {
  if (!o.model) throw new Error(t('モデルを選んでください (AI の設定)。'));
  if (o.provider !== 'custom' && !o.apiKey) throw new Error(t('API キーを入れてください (AI の設定)。'));
  const req = buildRequest(o);
  let res;
  try {
    res = await fetch(req.url, { method: 'POST', headers: req.headers, body: JSON.stringify(req.body), signal: o.signal });
  } catch (e) {
    if (o.signal && o.signal.aborted) throw e;
    throw new Error(t('接続できませんでした: ') + (e.cause && e.cause.message ? e.cause.message : e.message));
  }
  if (res.status >= 400) throw new Error(explain(res.status, await res.text()));
  const state = { inputTokens: 0, outputTokens: 0, error: null };
  const decoder = new TextDecoder('utf-8');
  let buffer = '', outputLength = 0;
  const handleLine = line => {
    line = line.replace(/\r$/, '');
    if (!line.startsWith('data:')) return;
    const payload = line.slice(5).trim();
    if (!payload || payload === '[DONE]') return;
    let obj;
    try { obj = JSON.parse(payload); } catch (e) { return; }
    const text = extractText(o.provider, obj, state);
    if (text) {
      outputLength += text.length;
      o.onDelta(text);
    }
  };
  for await (const chunk of res.body) {
    buffer += decoder.decode(chunk, { stream: true });
    let nl;
    while ((nl = buffer.indexOf('\n')) >= 0) {
      handleLine(buffer.slice(0, nl));
      buffer = buffer.slice(nl + 1);
    }
  }
  if (buffer) handleLine(buffer);
  if (state.error) throw new Error(state.error);
  // 使用量を返さないサービスは文字数から見積もる
  const estimated = state.inputTokens === 0 && state.outputTokens === 0 && outputLength > 0;
  return estimated
    ? { inputTokens: (o.system + o.prompt).length, outputTokens: outputLength, estimated: true }
    : { inputTokens: state.inputTokens, outputTokens: state.outputTokens, estimated: false };
}

async function listModels(p, apiKey, baseURL) {
  const base = trimBase(baseURL);
  const headers = {};
  let url;
  if (p === 'claude') {
    url = base + '/v1/models?limit=100';
    headers['x-api-key'] = apiKey;
    headers['anthropic-version'] = ANTHROPIC_VERSION;
  } else if (p === 'gemini') {
    url = base + '/models?pageSize=200';
    headers['x-goog-api-key'] = apiKey;
  } else {
    url = base + '/models';
    if (apiKey) headers.Authorization = 'Bearer ' + apiKey;
  }
  let res;
  try {
    res = await fetch(url, { headers, signal: AbortSignal.timeout(30000) });
  } catch (e) {
    throw new Error(t('接続できませんでした: ') + (e.cause && e.cause.message ? e.cause.message : e.message));
  }
  const text = await res.text();
  if (res.status >= 400) throw new Error(explain(res.status, text));
  let o = {};
  try { o = JSON.parse(text); } catch (e) { /* 空の一覧として扱う */ }
  let ids;
  if (p === 'gemini') {
    ids = (o.models || []).filter(m => (m.supportedGenerationMethods || []).includes('generateContent'))
      .map(m => (String(m.name || '').startsWith('models/') ? m.name.slice(7) : m.name)).filter(Boolean);
  } else {
    ids = (o.data || []).map(m => m.id).filter(Boolean);
  }
  if (p !== 'claude') ids.sort(); // Claude は新しい順のまま
  return ids;
}

module.exports = { PROVIDERS, provider, buildRequest, extractText, explain, send, listModels };
