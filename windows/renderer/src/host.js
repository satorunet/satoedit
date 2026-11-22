// 軽量版 (C# + WebView2) の本体とつなぐ入口。Electron 版の preload.js と同じ window.api を作る。
// 本体 (windows/host/) とは chrome.webview.postMessage でやりとりする。
// JavaScript だけでできること (メニューの組み立て・テーマの読み書き・AI の送り方・料金の計算・ふりがなの分け方・PDF の読み込み) はここで行い、
// 本体はファイル・暗号・ネット・OS の機能だけを受け持つ
import i18n from '../../shared/i18n';
import menuDef from '../../shared/menu';
import themeDef from '../../shared/theme';
import aiModels from '../../shared/aimodels';
import llm from '../../shared/localllm';
import pm from '../../shared/pluginmanifest';
import pluginDocs from '../../shared/plugindocs';
import ai from '../../core/ai';

const { t } = i18n;
const OFFICIAL_URL = 'https://editor.satoru.net';
const KIND_LABELS = { password: 'パスワード', passcode: 'パスコード', device: 'この PC のロック', totp: 'ワンタイム認証', twoStep: '二段階', keyfile: '鍵ファイル' };
// AI のキーは画面側に渡さない。送るときにこの印を本体がキーに置き換える
const KEY_MARK = '\u0000SATOEDIT-API-KEY\u0000';

export function installHostAPI() {
  const wv = window.chrome.webview;
  const pending = new Map();
  const listeners = {};
  const internal = {};
  let seq = 0;

  // ---------- やりとりの土台 ----------

  /// 本体からのエラー・メッセージを今の言語にする (本体は日本語と、訳すための key・params を返す)
  const translate = o => (o && o.key ? t(o.key, o.params || undefined) + (o.detail || '') : t(String((o && o.message) || o || '')));
  function tidy(v) {
    if (!v || typeof v !== 'object' || Array.isArray(v)) return v;
    if (typeof v.message === 'string' && (v.status === 'error' || v.key)) { v.message = translate(v); delete v.key; delete v.params; delete v.detail; }
    if (v.ok === false && typeof v.error === 'string') v.error = t(v.error);
    if (v.enc && typeof v.enc === 'object' && v.enc.kind) v.enc.label = t(KIND_LABELS[v.enc.kind] || v.enc.label || v.enc.kind);
    return v;
  }

  wv.addEventListener('message', e => {
    const m = e.data;
    if (!m || typeof m !== 'object') return;
    if (m.k === 'reply') {
      const p = pending.get(m.id);
      if (!p) return;
      pending.delete(m.id);
      if (m.ok) p.resolve(tidy(m.value === undefined ? null : m.value));
      else {
        const err = new Error(translate(m.error));
        if (m.error && m.error.code) err.code = m.error.code;
        p.reject(err);
      }
    } else if (m.k === 'event') {
      const args = m.args || [];
      if (internal[m.channel]) internal[m.channel](...args);
      for (const fn of listeners[m.channel] || []) {
        try { fn(...args); } catch (err) { console.error(err); }
      }
    }
  });

  const call = (name, ...args) => new Promise((resolve, reject) => {
    const id = ++seq;
    pending.set(id, { resolve, reject });
    wv.postMessage({ k: 'call', id, name, args });
  });
  const emit = (channel, ...args) => { for (const fn of listeners[channel] || []) { try { fn(...args); } catch (err) { console.error(err); } } };

  // ファイルをウインドウに落としたとき: 場所は本体でしか分からないので、ファイルごと本体に渡して開いてもらう
  window.addEventListener('drop', e => {
    const files = e.dataTransfer && e.dataTransfer.files;
    if (files && files.length && wv.postMessageWithAdditionalObjects) wv.postMessageWithAdditionalObjects({ k: 'drop' }, files);
  }, true);

  // ---------- 状態 (メニューの組み立てに使う) ----------

  let prefs = {};
  let locale = navigator.language || 'ja';
  let theme = themeDef.defaults();
  let menuState = {};
  let version = '1.0.3';
  let priceOverrides = {};
  let menuTimer = null;

  /// メニューバー: 本体の設定の言語で組み立てて (Electron 版の本体と同じ)、本体に渡す
  function rebuildMenu() {
    clearTimeout(menuTimer);
    menuTimer = setTimeout(() => {
      const cur = i18n.language();
      i18n.setLanguage(i18n.resolve(prefs.language, locale));
      try {
        const state = Object.assign({}, menuState, { prefs, recent: (prefs.recent || []).slice(0, 12) });
        call('setMenu', menuDef.build(state)).catch(() => {});
      } finally {
        i18n.setLanguage(cur);
      }
    }, 0);
  }
  internal.__recent = list => { prefs.recent = list || []; rebuildMenu(); };

  /// ウインドウ枠の明るさ (main.js の applyNativeTheme と同じ考え方)
  function applyNativeTheme(th) {
    const style = th.windowStyle;
    let scheme = 'light';
    if (style === 'system') scheme = 'auto';
    else if (style === 'theme') scheme = themeDef.isDark(themeDef.colors(th).background) ? 'dark' : 'light';
    call('setTheme', scheme).catch(() => {});
  }

  const parseJSON = (text, fallback) => { if (typeof text !== 'string') return fallback; try { return JSON.parse(text); } catch (e) { return fallback; } };
  const loadTheme = text => {
    const raw = parseJSON(text, null);
    if (raw === null) return { theme: themeDef.defaults(), problems: [] };
    return themeDef.fromJSON(raw);
  };

  // ---------- AI の利用の記録 (core/aiusage.js と同じ計算) ----------

  function price(provider, model, customPrices) {
    const known = aiModels.priceOf(model, priceOverrides);
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
  async function addUsage(usage, provider, model) {
    if (!usage || !(usage.inputTokens > 0 || usage.outputTokens > 0)) return;
    const c = cost(usage, provider, model, prefs.aiPrices);
    const record = { date: new Date().toISOString().replace(/\.\d+Z$/, 'Z'), provider, model, input: usage.inputTokens, output: usage.outputTokens, estimated: !!usage.estimated };
    if (c !== null) record.cost = c;
    await call('appendUsage', record);
  }

  // ---------- 本体を通したネット (AI・拡張機能・ローカル LLM) ----------

  const streams = new Map();
  internal.__stream = (id, text) => { const s = streams.get(id); if (s) s.onData(text); };
  internal.__streamEnd = (id, r) => { const s = streams.get(id); if (s) { streams.delete(id); s.onEnd(r || {}); } };
  let streamSeq = 0;
  /// 少しずつ届く返事。onLine(1 行) を呼び、終わったら { status, body, error, cancelled } で解決
  function httpStream(req, onLine, jobId) {
    const id = 's' + (++streamSeq);
    return new Promise(resolve => {
      let buffer = '';
      streams.set(id, {
        onData: text => {
          buffer += text;
          let nl;
          while ((nl = buffer.indexOf('\n')) >= 0) { const line = buffer.slice(0, nl); buffer = buffer.slice(nl + 1); onLine(line); }
        },
        onEnd: r => { if (buffer) onLine(buffer); buffer = ''; resolve(r); },
      });
      if (jobId !== undefined) jobs.set(jobId, id);
      call('httpStream', id, req).catch(e => { streams.delete(id); resolve({ error: e.message }); });
    });
  }
  const jobs = new Map();
  const aiBase = provider => (provider === 'custom' ? (prefs.aiCustomBaseURL || ai.provider('custom').baseURL) : ai.provider(provider).baseURL);
  const trimBase = s => String(s || '').replace(/[/ ]+$/, '').trim();
  const connectError = msg => t('接続できませんでした: ') + msg;

  async function hasKey(provider) {
    const s = await call('aiStatus', [provider]);
    return !!(s[provider] && s[provider].hasKey);
  }

  async function listModels(p) {
    const key = (await hasKey(p)) ? KEY_MARK : '';
    const base = trimBase(aiBase(p));
    const headers = {};
    let url;
    if (p === 'claude') {
      url = base + '/v1/models?limit=100';
      headers['x-api-key'] = key;
      headers['anthropic-version'] = (ai.buildRequest({ provider: 'claude', model: 'x', apiKey: '', baseURL: '', system: '', prompt: '' }).headers['anthropic-version']);
    } else if (p === 'gemini') {
      url = base + '/models?pageSize=200';
      headers['x-goog-api-key'] = key;
    } else {
      url = base + '/models';
      if (key) headers.Authorization = 'Bearer ' + key;
    }
    let res;
    try {
      res = await call('http', { url, headers, secret: 'ai.' + p, timeout: 30000 });
    } catch (e) {
      throw new Error(connectError(e.message));
    }
    if (res.status >= 400) throw new Error(ai.explain(res.status, res.body));
    const o = parseJSON(res.body, {}) || {};
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

  /// core/ai.js の send と同じ流れを、本体の通信で行う
  async function aiSend(id, o) {
    const provider = o.provider || prefs.aiProvider;
    const model = o.model || (prefs.aiModels || {})[provider] || ai.provider(provider).defaultModel;
    try {
      if (!model) throw new Error(t('モデルを選んでください (AI の設定)。'));
      const keyed = await hasKey(provider);
      if (provider !== 'custom' && !keyed) throw new Error(t('API キーを入れてください (AI の設定)。'));
      const req = ai.buildRequest({ provider, model, apiKey: keyed ? KEY_MARK : '', baseURL: aiBase(provider), system: o.system, prompt: o.prompt });
      const state = { inputTokens: 0, outputTokens: 0, error: null };
      let outputLength = 0;
      const r = await httpStream({ url: req.url, method: 'POST', headers: req.headers, body: JSON.stringify(req.body), secret: 'ai.' + provider }, line => {
        line = line.replace(/\r$/, '');
        if (!line.startsWith('data:')) return;
        const payload = line.slice(5).trim();
        if (!payload || payload === '[DONE]') return;
        let obj;
        try { obj = JSON.parse(payload); } catch (e) { return; }
        const text = ai.extractText(provider, obj, state);
        if (text) { outputLength += text.length; emit('ai:delta', id, text); }
      }, id);
      jobs.delete(id);
      if (r.cancelled) { emit('ai:done', id, { error: '', cancelled: true }); return; }
      if (r.error) throw new Error(connectError(r.error));
      if (r.status >= 400) throw new Error(ai.explain(r.status, r.body || ''));
      if (state.error) throw new Error(state.error);
      const estimated = state.inputTokens === 0 && state.outputTokens === 0 && outputLength > 0;
      const usage = estimated
        ? { inputTokens: String(o.system || '').length + String(o.prompt || '').length, outputTokens: outputLength, estimated: true }
        : { inputTokens: state.inputTokens, outputTokens: state.outputTokens, estimated: false };
      if (!o.noLog) { try { await addUsage(usage, provider, o.model || (prefs.aiModels || {})[provider] || ''); } catch (e) { /* 記録できなくても答えは返す */ } }
      emit('ai:done', id, { usage });
    } catch (e) {
      jobs.delete(id);
      emit('ai:done', id, { error: e.message || String(e), cancelled: false });
    }
  }

  // ---------- ふりがな (core/furigana.js の splitWord と同じ) ----------

  const KANJI = /[㐀-䶿一-鿿豈-﫿々〆ヵヶ]/;
  const toHiragana = s => s.replace(/[ァ-ヶ]/g, c => String.fromCharCode(c.charCodeAt(0) - 0x60));
  const escapeRegex = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  function splitWord(surface, reading) {
    const yomi = toHiragana(reading);
    const parts = [];
    for (let i = 0; i < surface.length; i++) {
      const kanji = KANJI.test(surface[i]);
      const last = parts[parts.length - 1];
      if (last && last.kanji === kanji) { last.text += surface[i]; last.to = i + 1; } else parts.push({ kanji, text: surface[i], from: i, to: i + 1 });
    }
    if (!parts.some(p => p.kanji)) return [];
    const pattern = '^' + parts.map(p => (p.kanji ? '(.+?)' : escapeRegex(toHiragana(p.text)))).join('') + '$';
    const m = new RegExp(pattern).exec(yomi);
    if (!m) return [{ from: 0, to: surface.length, reading: yomi }];
    let g = 1;
    return parts.filter(p => p.kanji).map(p => ({ from: p.from, to: p.to, reading: m[g++] }));
  }
  async function furigana(text) {
    text = String(text).slice(0, 200000);
    // 本体は Windows の日本語入力 (IME) に読みを聞き、単語 [{ at, surface, reading }] を返す
    const words = await call('furigana', text);
    const out = [];
    for (const w of words || []) {
      if (!w.reading || !KANJI.test(w.surface)) continue;
      for (const r of splitWord(w.surface, w.reading)) out.push({ from: w.at + r.from, to: w.at + r.to, reading: r.reading });
    }
    return out;
  }

  // ---------- PDF の読み込み (pdf.js を画面の中で動かす。core/pdfimport.js と同じ組み立て) ----------

  let pdfLoading = null;
  function loadScript(src) {
    return new Promise((resolve, reject) => {
      const s = document.createElement('script');
      s.src = src;
      s.onload = resolve;
      s.onerror = () => reject(new Error('cannot load ' + src));
      document.head.append(s);
    });
  }
  function pdfjs() {
    if (!pdfLoading) {
      // Worker は使わず、画面の中で動かす (pdf.worker を先に読み込んでおくと、そちらを使う)
      pdfLoading = loadScript('../pdfjs/pdf.worker.min.js').then(() => loadScript('../pdfjs/pdf.min.js')).then(() => window.pdfjsLib);
      pdfLoading.catch(() => { pdfLoading = null; });
    }
    return pdfLoading;
  }
  const b64ToBytes = b64 => { const s = atob(b64); const out = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i); return out; };
  // 文字の表 (cmaps) は本体から読む (この画面は fetch を使えない決まりなので)
  class HostCMapReader {
    constructor() { this.isCompressed = true; }
    async fetch({ name }) {
      if (!/^[A-Za-z0-9._-]+$/.test(name)) throw new Error('bad cmap');
      return { cMapData: b64ToBytes(await call('readAppFile', 'pdfjs/cmaps/' + name + '.bcmap')), compressionType: 1 };
    }
  }
  function pdfTidy(text) {
    const brackets = { '︵': '（', '︶': '）', '︷': '｛', '︸': '｝', '︹': '〔', '︺': '〕', '︻': '【', '︼': '】',
      '︽': '《', '︾': '》', '︿': '〈', '﹀': '〉', '﹁': '「', '﹂': '」', '﹃': '『', '﹄': '』', '﹇': '［', '﹈': '］' };
    return text.replace(/[⺀-⿟︐-︙︰-﹏]/g, c => brackets[c] || c.normalize('NFKC')).replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, '');
  }
  function pageText(items) {
    const runs = items.filter(i => i.str && i.str.trim() !== '').map(i => ({
      str: i.str, x: i.transform[4], y: i.transform[5], w: i.width || 0, h: Math.abs(i.transform[3]) || Math.abs(i.transform[0]) || 10,
      rotated: Math.abs(i.transform[1]) > Math.abs(i.transform[0]),
    }));
    if (runs.length === 0) return '';
    const size = runs.map(r => r.h).sort((a, b) => a - b)[Math.floor(runs.length / 2)] || 10;
    for (let i = runs.length - 1; i >= 0; i--) if (runs[i].h < size * 0.6) runs.splice(i, 1);
    const single = runs.filter(r => Array.from(r.str).length === 1);
    const columns = new Map();
    for (const r of single) {
      const key = Math.round(r.x / (size * 0.5));
      columns.set(key, (columns.get(key) || 0) + 1);
    }
    const stacked = Array.from(columns.values()).filter(n => n >= 3).reduce((a, b) => a + b, 0);
    const vertical = runs.some(r => r.rotated) || (single.length > runs.length * 0.7 && stacked > single.length * 0.6);
    const groups = [];
    if (vertical) {
      const sorted = runs.slice().sort((a, b) => (Math.abs(a.x - b.x) > size * 0.5 ? b.x - a.x : b.y - a.y));
      for (const r of sorted) {
        const last = groups[groups.length - 1];
        if (last && Math.abs(last.x - r.x) <= size * 0.5) last.items.push(r); else groups.push({ x: r.x, items: [r] });
      }
      return groups.map(g => g.items.map(r => r.str).join('')).join('\n');
    }
    const sorted = runs.slice().sort((a, b) => (Math.abs(a.y - b.y) > size * 0.5 ? b.y - a.y : a.x - b.x));
    for (const r of sorted) {
      const last = groups[groups.length - 1];
      if (last && Math.abs(last.y - r.y) <= size * 0.5) last.items.push(r); else groups.push({ y: r.y, items: [r] });
    }
    return groups.map(g => {
      let line = '', end = null;
      for (const r of g.items) {
        if (end !== null && r.x - end > size * 0.6) line += ' ';
        line += r.str;
        end = r.x + r.w;
      }
      return line;
    }).join('\n');
  }
  async function importPDF(file) {
    const lib = await pdfjs();
    const data = b64ToBytes(await call('readBytes', file));
    const doc = await lib.getDocument({
      data, cMapUrl: 'host:/', cMapPacked: true, CMapReaderFactory: HostCMapReader,
      isEvalSupported: false, useSystemFonts: false, verbosity: 0, disableFontFace: true,
    }).promise;
    const parts = [];
    for (let n = 1; n <= doc.numPages; n++) {
      const page = await doc.getPage(n);
      const content = await page.getTextContent();
      parts.push(pageText(content.items));
    }
    const pages = doc.numPages;
    await doc.destroy();
    return { text: pdfTidy(parts.join('\n\n')).replace(/[ \t]+$/gm, '') + '\n', pages };
  }

  // ---------- 拡張機能 (manifest を読むのはここ。ファイルは本体) ----------

  async function pluginList() {
    const raw = await call('pluginRaw');
    const seen = new Set(), out = [];
    for (const r of raw || []) {
      let manifest;
      try { manifest = pm.parse(r.manifestText); } catch (_) { continue; }
      if (seen.has(manifest.id)) continue;
      seen.add(manifest.id);
      let icon = manifest.icon && !manifest.icon.includes('.') ? manifest.icon : '🧩';
      if (manifest.icon && manifest.icon.includes('.') && !manifest.icon.includes('..') && r.iconData) {
        const ext = (manifest.icon.split('.').pop() || '').toLowerCase();
        icon = `data:image/${ext === 'svg' ? 'svg+xml' : ext};base64,` + r.iconData;
      }
      out.push({ manifest, folder: r.folder, source: r.source || '', icon, error: r.error || null });
    }
    return out;
  }
  const staged = new Map();

  // ---------- window.api ----------

  const passthrough = [
    'fileInfo', 'listDir', 'findFiles', 'createEntry', 'renameEntry', 'trashEntry', 'reveal', 'openPath', 'openExternal', 'copyText', 'pathInfo',
    'grepStart', 'grepCancel', 'serverSave', 'serverDelete', 'serverForgetKey', 'serverHasPassword', 'remoteCall', 'remoteRead', 'remoteWrite',
    'aiSetKey', 'assocStatus', 'exportPDF', 'print', 'exportDocx', 'screenshot',
    'collabHost', 'collabJoin', 'collabSend', 'collabClose', 'collabStop', 'attention', 'editCommand', 'setTitle', 'closeWindow', 'quit', 'fileIcon', 'growWindow',
    'pluginToken', 'pluginReply', 'readClipboard', 'makeKey', 'readFile', 'writeFile',
    // テキスト一覧・版の履歴・バックアップ・リンクで公開 (docs.satoru.net への送信)
    'libraryInfo', 'libraryItems', 'libraryTree', 'librarySetRoot', 'libraryScan', 'libraryRead', 'beep', 'libraryCreateFolder', 'libraryRenameFolder', 'libraryMoveFolder', 'libraryTrash', 'libraryCreateBlank',
    'libraryGetMode', 'librarySetMode', 'librarySetLocked', 'libraryDuplicate', 'libraryMove', 'libraryFolderPath', 'libraryReadText', 'libraryRemoveEmpty',
    'libraryRemovePlaceholder', 'librarySame', 'versionNoteSaved', 'versionNoteOpened', 'versionFlush', 'versionList', 'versionContent', 'versionRepath',
    'versionForget', 'versionPruneAll', 'versionReveal', 'backupExport', 'backupOpen', 'backupRestore', 'http',
    // アップデート (GitHub Releases)
    'updateCheck', 'updateDownload', 'updateCancel', 'updateInstall',
  ];
  const api = {};
  for (const name of passthrough) api[name] = (...args) => call(name, ...args);

  Object.assign(api, {
    on(channel, fn) {
      (listeners[channel] = listeners[channel] || []).push(fn);
      return () => { listeners[channel] = (listeners[channel] || []).filter(f => f !== fn); };
    },
    pathForFile() { return ''; }, // 落としたファイルは本体が開く (上の drop を参照)

    async init() {
      const r = await call('init');
      prefs = r.prefs || {};
      locale = r.locale || locale;
      version = r.version || version;
      const loaded = loadTheme(r.themeText);
      theme = loaded.theme;
      const profiles = parseJSON(r.profilesText, []);
      const prices = parseJSON(r.pricesText, {});
      priceOverrides = prices && typeof prices === 'object' && !Array.isArray(prices) ? prices : {};
      applyNativeTheme(theme);
      rebuildMenu();
      return {
        prefs, theme, themeProblems: loaded.problems, userProfiles: Array.isArray(profiles) ? profiles : [],
        platform: r.platform, version, files: r.files || [], grepRoot: r.grepRoot || '',
        secretsAvailable: r.secretsAvailable, configDir: r.configDir, aiPriceOverrides: priceOverrides,
        homeDir: r.homeDir, userName: r.userName, fullName: r.fullName || '', hostName: r.hostName, language: i18n.resolve(prefs.language, locale),
      };
    },

    // 設定
    async setPref(key, value) {
      const ok = await call('setPref', key, value);
      if (ok) prefs[key] = value;
      rebuildMenu();
      return ok;
    },
    async saveTheme(th) {
      theme = th;
      await call('writeConfig', 'theme.json', themeDef.toFileContents(th));
      applyNativeTheme(th);
      return true;
    },
    async saveUserProfiles(list) { await call('writeConfig', 'profiles.json', JSON.stringify(list, null, 2)); return true; },
    async setMenuState(state) { menuState = state || {}; rebuildMenu(); return true; },
    async resetSettings() {
      const r = await call('resetSettings');
      if (r && typeof r === 'object') prefs = r;
      rebuildMenu();
      return prefs;
    },
    exportSettings() {
      return call('exportSettings', { title: t('設定内容の保存'), filters: [{ name: t('設定ファイル'), extensions: ['json'] }], theme: JSON.parse(themeDef.toFileContents(theme)) });
    },
    async importSettings() {
      const r = await call('importSettings', { title: t('設定内容の復元'), filters: [{ name: t('設定ファイル'), extensions: ['json'] }] });
      if (r.status !== 'ok') return r;
      prefs = r.prefs || prefs;
      if (r.theme) await call('writeConfig', 'theme.json', themeDef.toFileContents(themeDef.fromJSON(r.theme).theme));
      rebuildMenu();
      return { status: 'ok' };
    },

    // ファイル
    openDialog(o = {}) {
      return call('openDialog', Object.assign({}, o, { title: o.title || t('開く'), filters: o.filters || [{ name: t('すべてのファイル'), extensions: ['*'] }] }));
    },
    saveDialog(o = {}) {
      // 文書の保存 (種類を決めていないとき): どんな拡張子でもそのまま。書かなかったときだけ .txt
      const any = !o.filters;
      return call('saveDialog', Object.assign({}, o, {
        anyExtension: any, replaceAsk: t('{name} は既にあります。置き換えますか？'),
        title: o.title || t('名前を付けて保存'),
        filters: o.filters || [{ name: t('テキスト'), extensions: ['txt'] }, { name: t('すべてのファイル'), extensions: ['*'] }],
      }));
    },
    async clearRecent() { prefs.recent = []; await call('clearRecent'); rebuildMenu(); return true; },

    // 暗号化
    totpBegin(account) { return call('totpBegin', account || 'document', t('さとるエディタ')); },
    newKeyFile() { return call('newKeyFile', { title: t('鍵ファイルを作る (USB メモリなどに置く)'), filters: [{ name: t('鍵ファイル'), extensions: ['satorukey'] }] }); },

    // ふりがな
    async furigana(text) { try { return await furigana(text); } catch (e) { return []; } },

    // AI
    aiStatus() { return call('aiStatus', ai.PROVIDERS.map(p => p.id)); },
    async aiListModels(provider) {
      try { return { status: 'ok', models: await listModels(provider) }; } catch (e) { return { status: 'error', code: '', message: e.message }; }
    },
    aiSend(id, o) { aiSend(id, o || {}); return Promise.resolve(true); },
    async aiCancel(id) {
      const s = jobs.get(id);
      if (s) await call('httpCancel', s);
      return true;
    },
    async aiUsage() {
      const records = parseJSON(await call('readConfig', 'ai-usage.json'), []);
      return {
        summary: summarize(Array.isArray(records) ? records : []), prices: prefs.aiPrices || {}, yen: prefs.aiYenPerDollar || 150,
        pages: Object.assign({ custom: '' }, aiModels.SOURCES),
        current: price(prefs.aiProvider, (prefs.aiModels || {})[prefs.aiProvider] || ai.provider(prefs.aiProvider).defaultModel, prefs.aiPrices),
      };
    },
    async aiUsageClear() { await call('deleteConfig', 'ai-usage.json'); return true; },

    // PDF から読み込む
    async importPDF(file) {
      try {
        const r = await importPDF(file);
        return { status: 'ok', text: r.text, pages: r.pages };
      } catch (e) { return { status: 'error', code: '', message: String((e && e.message) || e) }; }
    },

    // 関連付け
    assocApply(o) { return call('assocApply', Object.assign({}, o, { labels: { open: t('さとるエディタで開く'), grep: t('さとるエディタで grep') } })); },

    async about() {
      return call('about', {
        title: t('さとるエディタについて'), message: `${t('さとるエディタ')} ${version}`,
        detail: t('Windows 用の軽いテキストエディタです。\n\nMIT License') + '\n\n' + t('公式サイト') + ': ' + OFFICIAL_URL,
        buttons: ['OK', t('公式サイトを開く')], url: OFFICIAL_URL,
      });
    },

    // 拡張機能
    pluginList,
    pluginsFolder() { return call('pluginsFolder'); },
    async pluginPrepare(from) {
      try {
        from = from || {};
        let req;
        if (from.url) {
          const url = pm.downloadURL(from.url);
          if (!url) throw new Error('badURL');
          req = { url, source: String(from.url).trim() };
        } else {
          req = { path: String(from.path || ''), source: String(from.path || '') };
        }
        const r = await call('pluginStage', req);
        let manifest;
        try { manifest = pm.parse(r.manifestText); } catch (e) { call('pluginDiscard', r.token); throw new Error('badManifest: ' + e.message); }
        if (!(r.files || []).includes(manifest.main)) { call('pluginDiscard', r.token); throw new Error('noMain: ' + manifest.main); }
        staged.set(r.token, { manifest, source: req.source });
        const existing = (await pluginList()).find(p => p.manifest.id === manifest.id);
        return { ok: true, token: r.token, manifest, source: req.source, existing: existing ? existing.manifest : null };
      } catch (e) { return { ok: false, error: String(e.message || e) }; }
    },
    async pluginCommit(token) {
      const s = staged.get(token);
      staged.delete(token);
      if (!s) return { ok: false, error: 'expired' };
      try {
        const old = (await pluginList()).filter(p => p.manifest.id === s.manifest.id).map(p => p.folder);
        await call('pluginCommit', token, s.manifest.id, old);
        return { ok: true, id: s.manifest.id, source: s.source };
      } catch (e) { return { ok: false, error: String(e.message || e) }; }
    },
    async pluginDiscard(token) { staged.delete(token); await call('pluginDiscard', token); return true; },
    async pluginUninstall(id) {
      const p = (await pluginList()).find(x => x.manifest.id === id);
      if (!p) return false;
      await call('trashPath', p.folder);
      return true;
    },
    async pluginTemplate(id) {
      try {
        id = String(id || '');
        const m = { id, name: id, version: '1.0.0', author: '', description: '', icon: '🧩', main: 'main.js', permissions: [] };
        pm.validate(Object.assign({ permissions: [] }, m));
        const path = await call('pluginTemplate', id, JSON.stringify(m, null, 2) + '\n', pluginDocs.TEMPLATE, pluginDocs.README);
        return { ok: true, path };
      } catch (e) { return { ok: false, error: String(e.message || e) }; }
    },
    pluginDocs() { return call('pluginDocs', pluginDocs.README); },
    async pluginFetch(id, url, opts) { return call('pluginFetch', String(id), url, opts || {}); },

    // ローカル LLM (Ollama)
    async llmStatus() {
      let running = false, models = [];
      try {
        const r = await call('http', { url: llm.SERVER + '/api/tags', timeout: 3000 });
        running = r.status === 200;
        if (running) models = llm.parseTags(r.body);
      } catch (_) { running = false; }
      const info = await call('llmInfo');
      return { running, installed: running || !!info.installed, models, platform: 'win32', release: info.release, build: llm.buildOf(info.release) };
    },
    async llmRequiredBuild() {
      try {
        const r = await call('http', { url: llm.REQUIREMENTS_URL, timeout: 8000 });
        if (r.status !== 200) return { build: llm.FALLBACK_MIN_BUILD, checked: false };
        const b = llm.parseRequiredBuild(r.body);
        return { build: b || llm.FALLBACK_MIN_BUILD, checked: !!b };
      } catch (_) { return { build: llm.FALLBACK_MIN_BUILD, checked: false }; }
    },
    async llmInstall() {
      try { await call('llmInstall', llm.INSTALLER_URL); return { ok: true }; } catch (e) { return { ok: false, error: String(e.message || e) }; }
    },
    llmCancelInstall() { return call('llmCancelInstall'); },
    llmStart() { return call('llmStart'); },
    async llmPull(name) {
      name = String(name);
      try {
        if (!llm.isValidModelName(name)) throw new Error('bad name');
        let lastError = null, done = false;
        const r = await httpStream({ url: llm.SERVER + '/api/pull', method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ model: name, stream: true }) }, line => {
          const p = llm.parseProgress(line);
          if (!p) return;
          if (p.error) lastError = p.error;
          if (p.done) done = true;
          emit('llm:pull', name, p);
        }, '__pull');
        jobs.delete('__pull');
        if (r.cancelled) throw new Error('cancelled');
        if (r.error) throw new Error(r.error);
        if (lastError) throw new Error(lastError);
        return { ok: true, done };
      } catch (e) { return { ok: false, error: String(e.message || e) }; }
    },
    async llmCancelPull() { const s = jobs.get('__pull'); if (s) await call('httpCancel', s); return true; },
    async llmDelete(name) {
      if (!llm.isValidModelName(name)) return false;
      try {
        const r = await call('http', { url: llm.SERVER + '/api/delete', method: 'DELETE', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ model: String(name) }), timeout: 30000 });
        return r.status === 200;
      } catch (_) { return false; }
    },
  });

  window.api = api;
  window.__host = { call, emit }; // 動作確認用
}
