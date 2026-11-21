// JS 拡張機能 (画面側)。拡張機能ごとに Web Worker を 1 つ作り、その中で main.js を動かす。
// Worker からは画面やファイル・ネットに直接は触れない (CSP で止めてある)。
// 本文を読むなどの命令は、satoplug:// への同期の呼び出し → 本体 → この画面、の順に届き、すぐ答えが返る (Mac 版と同じ書き方で動く)
import { h, modal, alertBox, confirmBox, promptBox, toast } from './dialogs';
import i18n from '../../shared/i18n';
import pm from '../../shared/pluginmanifest';

const { t } = i18n;

/// Worker の中で、拡張機能のプログラムより先に動かす部分 (satoru.* を組み立てる)
const BOOTSTRAP = `
'use strict';
(function () {
  const TOKEN = __TOKEN__, VERSION = __VERSION__;
  const post = m => self.postMessage(m);
  // sync call: waits for the answer
  function call(op, args) {
    const x = new XMLHttpRequest();
    x.open('POST', 'satoplug://call/', false);
    x.setRequestHeader('Content-Type', 'application/json');
    x.send(JSON.stringify({ token: TOKEN, op, args: args || [] }));
    const r = JSON.parse(x.responseText || '{}');
    if (r.error) throw new Error(r.error);
    return r.value;
  }
  const fmt = v => { if (typeof v === 'string') return v; if (v instanceof Error) return v.message; try { return JSON.stringify(v); } catch (e) { return String(v); } };
  const commands = new Map(), handlers = {}, providers = [];
  const satoru = Object.freeze({
    version: VERSION,
    commands: Object.freeze({
      register(spec, fn) {
        if (typeof spec === 'string') spec = { id: spec, title: spec };
        if (typeof fn !== 'function') throw new Error('commands.register: function required');
        const id = String(spec.id || spec.title);
        commands.set(id, fn);
        post({ type: 'register', id, title: String(spec.title || spec.id), key: String(spec.key || '') });
      },
    }),
    on(event, fn) { (handlers[event] = handlers[event] || []).push(fn); post({ type: 'on', event: String(event) }); },
    editor: Object.freeze({
      getText() { return call('getText'); },
      setText(s) { call('setText', [String(s)]); },
      getSelection() { return call('getSelection'); },
      replaceSelection(s) { call('replaceSelection', [String(s)]); },
      insert(s) { call('replaceSelection', [String(s)]); },
      select(start, end) { call('select', [start | 0, (end === undefined ? start : end) | 0]); },
      language() { return call('language'); },
      fileName() { return call('fileName'); },
      filePath() { return call('filePath'); },
    }),
    completion: Object.freeze({ register(fn) { providers.push(fn); post({ type: 'completion' }); } }),
    ui: Object.freeze({
      toast(title, detail) { call('toast', [String(title), detail == null ? '' : String(detail)]); },
      alert(msg) { call('alert', [String(msg)]); },
      confirm(msg) { return !!call('confirm', [String(msg)]); },
      prompt(msg, value) { return call('prompt', [String(msg), value == null ? '' : String(value)]); },
    }),
    storage: Object.freeze({
      get(key, fallback) { const v = call('storageGet', [String(key)]); if (v === null || v === undefined) return fallback; try { return JSON.parse(v); } catch (e) { return fallback; } },
      set(key, value) { call('storageSet', [String(key), JSON.stringify(value)]); },
    }),
    clipboard: Object.freeze({
      readText() { return call('clipboardRead'); },
      writeText(s) { call('clipboardWrite', [String(s)]); },
    }),
    fetch(url, options) {
      return fetch('satoplug://fetch/', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token: TOKEN, url: String(url), opts: options || {} }) })
        .then(r => r.json()).then(r => {
          if (r.error) throw new Error(r.error);
          const v = r.value;
          return { status: v.status, ok: v.status >= 200 && v.status < 300, headers: v.headers, text: () => Promise.resolve(v.body), json: () => new Promise((ok, ng) => { try { ok(JSON.parse(v.body)); } catch (e) { ng(e); } }) };
        });
    },
  });
  self.satoru = satoru;
  self.console = {
    log: (...a) => post({ type: 'log', error: false, text: a.map(fmt).join(' ') }),
    info: (...a) => post({ type: 'log', error: false, text: a.map(fmt).join(' ') }),
    warn: (...a) => post({ type: 'log', error: false, text: a.map(fmt).join(' ') }),
    error: (...a) => post({ type: 'log', error: true, text: a.map(fmt).join(' ') }),
  };
  const report = e => post({ type: 'log', error: true, text: (e && e.message) || String(e) });
  self.addEventListener('error', e => { report(e.error || e.message); e.preventDefault(); });
  self.addEventListener('unhandledrejection', e => { report(e.reason); e.preventDefault(); });
  // requests from the app: run a command, tell an event, ask for completions
  self.onmessage = e => {
    const m = e.data || {};
    try {
      if (m.type === 'command') { const fn = commands.get(m.id); if (fn) fn(); post({ type: 'done', callId: m.callId }); }
      else if (m.type === 'event') { for (const fn of handlers[m.name] || []) { try { fn(m.info); } catch (err) { report(err); } } post({ type: 'done', callId: m.callId }); }
      else if (m.type === 'complete') {
        const out = [];
        for (const fn of providers) {
          const list = fn(m.info);
          if (!Array.isArray(list)) continue;
          for (const v of list.slice(0, 500)) {
            if (typeof v === 'string') out.push({ label: v });
            else if (v && typeof v.label === 'string' && v.label) out.push({ label: v.label, detail: typeof v.detail === 'string' ? v.detail : '', kind: typeof v.kind === 'string' ? v.kind : '' });
          }
        }
        post({ type: 'done', callId: m.callId, value: out });
      }
    } catch (err) { report(err); post({ type: 'done', callId: m.callId }); }
  };
})();
`;

/// 1 つの拡張機能
class Plugin {
  constructor(manager, entry) {
    this.manager = manager;
    this.manifest = entry.manifest;
    this.folder = entry.folder;
    this.source = entry.source;
    this.icon = entry.icon;
    this.loadError = entry.error;
    this.commands = [];
    this.events = new Set();
    this.hasCompletion = false;
    this.log = [];
    this.worker = null;
    this.calls = new Map();
    this.seq = 0;
  }

  get running() { return !!this.worker; }

  addLog(text, error) {
    this.log.push({ date: new Date(), error: !!error, text: String(text) });
    if (this.log.length > 300) this.log.splice(0, this.log.length - 300);
  }

  start() {
    this.stop();
    if (this.loadError) { this.addLog(this.loadError, true); return; }
    const app = this.manager.app;
    this.token = Array.from(crypto.getRandomValues(new Uint8Array(16))).map(b => b.toString(16).padStart(2, '0')).join('');
    app.api.pluginToken(this.token, this.manifest.id);
    const code = BOOTSTRAP.replace('__TOKEN__', JSON.stringify(this.token)).replace('__VERSION__', JSON.stringify(app.version || 'dev'))
      + '\n//# sourceURL=' + this.manifest.id + '/bootstrap.js\n;\n' + this.source + '\n//# sourceURL=' + this.manifest.id + '/' + this.manifest.main;
    const url = URL.createObjectURL(new Blob([code], { type: 'text/javascript' }));
    try {
      this.worker = new Worker(url, { name: this.manifest.id });
    } catch (e) { this.addLog(String(e.message || e), true); return; } finally { setTimeout(() => URL.revokeObjectURL(url), 5000); }
    this.worker.onmessage = e => this.received(e.data || {});
    this.worker.onerror = e => { this.addLog(e.message || 'error', true); e.preventDefault(); };
    this.addLog(t('読み込みました'));
  }

  stop() {
    if (this.worker) { this.worker.terminate(); this.worker = null; }
    if (this.token) this.manager.app.api.pluginToken(this.token, '');
    for (const c of this.calls.values()) c(null);
    this.calls.clear();
    this.commands = [];
    this.events.clear();
    this.hasCompletion = false;
  }

  received(m) {
    if (m.type === 'register') {
      this.commands = this.commands.filter(c => c.id !== m.id).concat([{ id: m.id, title: m.title, accel: pm.accelOf(pm.parseShortcut(m.key)) }]);
      this.manager.commandsChanged();
    } else if (m.type === 'on') this.events.add(m.event);
    else if (m.type === 'completion') this.hasCompletion = true;
    else if (m.type === 'log') this.addLog(m.text, m.error);
    else if (m.type === 'done') { const c = this.calls.get(m.callId); if (c) { this.calls.delete(m.callId); c(m.value); } }
  }

  /// Worker に頼んで、終わるのを待つ (timeout ミリ秒で諦める)
  ask(message, timeout = 0) {
    if (!this.worker) return Promise.resolve(null);
    const callId = ++this.seq;
    return new Promise(resolve => {
      this.calls.set(callId, resolve);
      this.worker.postMessage(Object.assign({ callId }, message));
      if (timeout) setTimeout(() => { if (this.calls.has(callId)) { this.calls.delete(callId); resolve(null); } }, timeout);
    });
  }
}

export class PluginManager {
  constructor(app) {
    this.app = app;
    this.plugins = [];
    this.eventTab = null; // イベントの最中は、その文書を相手にする
    app.api.on('plugin:call', (reqId, id, op, args) => this.handleCall(reqId, id, op, args));
  }

  isEnabled(p) { return !(this.app.prefs.pluginsDisabled || []).includes(p.manifest.id); }

  async loadAll() {
    for (const p of this.plugins) p.stop();
    let list = [];
    try { list = await this.app.api.pluginList(); } catch (_) { list = []; }
    this.plugins = list.map(e => new Plugin(this, e));
    for (const p of this.plugins) if (this.isEnabled(p)) p.start();
    this.changed();
  }

  setEnabled(p, on) {
    const d = new Set(this.app.prefs.pluginsDisabled || []);
    if (on) d.delete(p.manifest.id); else d.add(p.manifest.id);
    this.app.setPref('pluginsDisabled', Array.from(d));
    if (on) p.start(); else p.stop();
    this.changed();
  }

  commandsChanged() { this.app.pushMenuState(); }
  changed() {
    this.app.pushMenuState();
    if (this.onChange) this.onChange();
  }

  /// メニュー「追加機能」に並べるもの
  menuEntries() {
    return this.plugins.filter(p => p.running && p.commands.length).map(p => ({
      id: p.manifest.id, name: p.manifest.name, icon: p.icon && !p.icon.startsWith('data:') ? p.icon : '🧩',
      commands: p.commands.map(c => ({ id: c.id, title: c.title, accel: c.accel })),
    }));
  }

  run(ref) {
    const [pid, cid] = String(ref).split('/');
    const p = this.plugins.find(x => x.manifest.id === pid);
    if (p && p.running) p.ask({ type: 'command', id: cid });
  }

  info(tab) {
    return { fileName: tab ? tab.name : '', path: tab ? ((tab.remote && tab.remote.path) || tab.path || '') : '', language: tab && tab.profile ? tab.profile.name : '', remote: !!(tab && tab.remote) };
  }

  /// イベント (open / beforeSave / save) を知らせる。beforeSave は終わるまで待つ (そこで本文を書き換えられる)
  async emit(name, tab) {
    const targets = this.plugins.filter(p => p.running && p.events.has(name));
    if (!targets.length) return;
    const saved = this.eventTab;
    this.eventTab = tab;
    try { await Promise.all(targets.map(p => p.ask({ type: 'event', name, info: this.info(tab) }, name === 'beforeSave' ? 3000 : 0))); }
    finally { this.eventTab = saved; }
  }

  /// 入力補完に、拡張機能からの候補を足す
  async completions(info) {
    const targets = this.plugins.filter(p => p.running && p.hasCompletion);
    if (!targets.length) return [];
    const lists = await Promise.all(targets.map(p => p.ask({ type: 'complete', info }, 400)));
    const out = [];
    lists.forEach((list, i) => {
      for (const v of list || []) {
        const kind = ['function', 'keyword', 'type', 'property', 'word'].includes(v.kind) ? v.kind : 'snippet';
        out.push({ label: v.label, kind, detail: v.detail || targets[i].manifest.name, params: [] });
      }
    });
    return out;
  }

  /// 拡張機能のフォルダの中のファイルを保存したら、その拡張機能を読み直す (作りながら試せるように)
  async fileSaved(path) {
    if (!path) return;
    const folder = await this.app.api.pluginsFolder();
    const norm = s => String(s).replace(/\\\\/g, '/').toLowerCase();
    if (!norm(path).startsWith(norm(folder) + '/')) return;
    await this.loadAll();
    const p = this.plugins.find(x => norm(path).startsWith(norm(x.folder) + '/'));
    if (p) toast(t('「{name}」を読み直しました', { name: p.manifest.name }));
  }

  // ---------- Worker からの同期の命令 ----------

  async handleCall(reqId, id, op, args) {
    const api = this.app.api;
    try {
      const value = await this.perform(id, op, args || []);
      api.pluginReply(reqId, true, value === undefined ? null : value);
    } catch (e) {
      api.pluginReply(reqId, false, String((e && e.message) || e));
    }
  }

  async perform(id, op, args) {
    const app = this.app;
    const p = this.plugins.find(x => x.manifest.id === id);
    if (!p) throw new Error('unknown plugin');
    const tab = this.eventTab && app.tabs.includes(this.eventTab) ? this.eventTab : app.active;
    const needTab = () => { if (!tab) throw new Error('no document'); if (tab.paper) app.syncFromPaper(tab); return tab; };
    const view = () => needTab().editor.view;
    const denied = perm => { const msg = t('権限「{p}」がないので使えません。manifest.json の permissions に書いてください', { p: perm }); p.addLog(msg, true); throw new Error(msg); };
    switch (op) {
      case 'getText': return needTab().getText();
      case 'setText': { const v = view(); const sel = v.state.selection.main.head; v.dispatch({ changes: { from: 0, to: v.state.doc.length, insert: args[0] }, selection: { anchor: Math.min(sel, args[0].length) }, userEvent: 'input' }); return null; }
      case 'getSelection': { const r = view().state.selection.main; return { start: r.from, end: r.to, text: view().state.sliceDoc(r.from, r.to) }; }
      case 'replaceSelection': { const v = view(); const r = v.state.selection.main; v.dispatch({ changes: { from: r.from, to: r.to, insert: args[0] }, selection: { anchor: r.from + args[0].length }, userEvent: 'input', scrollIntoView: true }); return null; }
      case 'select': { const v = view(); const n = v.state.doc.length; const a = Math.max(0, Math.min(args[0], n)), b = Math.max(a, Math.min(args[1], n)); v.dispatch({ selection: { anchor: a, head: b }, scrollIntoView: true }); return null; }
      case 'language': return tab && tab.profile ? tab.profile.name : '';
      case 'fileName': return tab ? tab.name : '';
      case 'filePath': return tab ? ((tab.remote && tab.remote.path) || tab.path || '') : '';
      case 'toast': toast(args[1] ? `${args[0]} — ${args[1]}` : args[0]); return null;
      case 'alert': await alertBox(p.manifest.name, args[0]); return null;
      case 'confirm': return await confirmBox(p.manifest.name, args[0], 'OK');
      case 'prompt': { const v = await promptBox(p.manifest.name, args[0], args[1]); return v === undefined ? null : v; }
      case 'storageGet': { const all = app.prefs.pluginStorage || {}; const mine = all[id] || {}; return Object.prototype.hasOwnProperty.call(mine, args[0]) ? mine[args[0]] : null; }
      case 'storageSet': { const all = Object.assign({}, app.prefs.pluginStorage); all[id] = Object.assign({}, all[id], { [args[0]]: args[1] }); app.setPref('pluginStorage', all); return null; }
      case 'clipboardRead': if (!pm.has(p.manifest, 'clipboard')) denied('clipboard'); return await app.api.readClipboard();
      case 'clipboardWrite': if (!pm.has(p.manifest, 'clipboard')) denied('clipboard'); await app.api.copyText(args[0]); return null;
      default: throw new Error('unknown: ' + op);
    }
  }

  // ---------- 入れる・外す ----------

  permissionText(perm) { return perm === 'network' ? t('ネットにつなぐ') : perm === 'clipboard' ? t('クリップボードを読み書きする') : perm; }

  /// from: { url } か { path }。確認してから入れる。入れたら true
  async install(from) {
    const api = this.app.api;
    toast(from.url ? t('ダウンロードしています…') : t('読み込んでいます…'));
    const r = await api.pluginPrepare(from);
    if (!r.ok) { await alertBox(t('拡張機能を入れられませんでした'), this.problemText(r.error)); return false; }
    const m = r.manifest;
    const perms = m.permissions.map(x => this.permissionText(x));
    const lines = [m.description, t('作者: {a}   版: {v}', { a: m.author || '?', v: m.version }),
      perms.length ? t('使う権限: {p}', { p: perms.join('、') }) : t('特別な権限は使いません (文書の読み書きだけ)'), '',
      t('ほかの人が作ったプログラムです。信頼できる作者のものだけ入れてください。')].filter(x => x !== '');
    const title = r.existing ? t('「{name}」を {a} から {b} に入れ替えますか？', { name: m.name, a: r.existing.version, b: m.version }) : t('「{name}」を入れますか？', { name: m.name });
    const ok = await confirmBox(title, lines.join('\n'), r.existing ? t('入れ替える') : t('入れる'));
    if (!ok) { api.pluginDiscard(r.token); return false; }
    const c = await api.pluginCommit(r.token);
    if (!c.ok) { await alertBox(t('拡張機能を入れられませんでした'), c.error); return false; }
    this.app.setPref('pluginSources', Object.assign({}, this.app.prefs.pluginSources, { [c.id]: c.source }));
    this.app.setPref('pluginsDisabled', (this.app.prefs.pluginsDisabled || []).filter(x => x !== c.id));
    await this.loadAll();
    toast(t('「{name}」を入れました', { name: m.name }) + ' — ' + t('メニュー「追加機能」から使えます'));
    return true;
  }

  problemText(err) {
    const e = String(err || '');
    if (e.startsWith('noManifest')) return t('manifest.json が見つかりません');
    if (e.startsWith('badManifest')) return t('manifest.json に問題があります: {e}', { e: e.slice(13) });
    if (e.startsWith('noMain')) return t('{f} が見つかりません', { f: e.slice(8) });
    if (e.startsWith('unsafe')) return t('zip の中に、フォルダの外へ書き出すファイルがあります');
    if (e.startsWith('badURL')) return t('URL が正しくありません');
    if (e === 'too large') return t('大きすぎます (20 MB まで)');
    return e;
  }

  async uninstall(p) {
    if (!(await confirmBox(t('「{name}」を外しますか？', { name: p.manifest.name }), t('フォルダはごみ箱に移します。'), t('外す')))) return false;
    p.stop();
    await this.app.api.pluginUninstall(p.manifest.id);
    const sources = Object.assign({}, this.app.prefs.pluginSources);
    delete sources[p.manifest.id];
    this.app.setPref('pluginSources', sources);
    await this.loadAll();
    return true;
  }

  async update(p) {
    const src = (this.app.prefs.pluginSources || {})[p.manifest.id];
    if (!src || !/^(https?:|github\.com)/.test(src)) { await alertBox(t('更新できません'), t('URL から入れたものではないので、更新できません')); return; }
    await this.install({ url: src });
  }

  async createTemplate() {
    const id = await promptBox(t('新しい拡張機能を作る'), t('名前 (英小文字・数字・-) を入れてください。.satoruEditor/plugins の中にひな形を作ります。'), 'my-plugin');
    if (!id) return;
    const r = await this.app.api.pluginTemplate(id.trim().toLowerCase());
    if (!r.ok) { await alertBox(t('ひな形を作れませんでした'), r.error === 'exists' ? t('同じ名前のフォルダがもうあります') : /badID/.test(r.error) ? t('名前に使えない文字があります') : r.error); return; }
    await this.loadAll();
    await this.app.openPath(r.path);
    toast(t('ひな形を作りました') + ' — ' + t('main.js を書き換えて保存すると、すぐ読み直します'));
  }

  async openDocs() { this.app.openPath(await this.app.api.pluginDocs()); }
  async revealFolder(p) { if (p) this.app.api.reveal(p.folder + '/manifest.json'); else this.app.api.openPath(await this.app.api.pluginsFolder()); }
}
