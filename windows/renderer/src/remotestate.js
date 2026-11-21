// サーバのファイルの状態 (受信中・編集中・送信中・更新済み…)、ログ、お気に入りと履歴、右上の知らせ。
// サーバの窓とエディタ横のサーバツリーの両方から使う (Mac 版と同じ考え方)
import { h } from './dialogs';
import i18n from '../../shared/i18n';

const { t } = i18n;

// ---------- 状態 ----------

const STATES = {
  opened: { label: 'タブで開き中', color: 'purple' },
  downloading: { label: '受信中', color: 'blue', busy: true },
  editing: { label: '編集中', color: 'orange' },
  uploading: { label: '送信中', color: 'blue', busy: true },
  uploaded: { label: '更新 {time}', color: 'green' },
  failed: { label: '失敗', color: 'red' },
};
const states = new Map();
const listeners = new Set();
const key = (id, path) => id + '|' + path;

export const RemoteState = {
  set(id, path, state) {
    states.set(key(id, path), { state, at: Date.now() });
    listeners.forEach(fn => fn());
  },
  clear(id, path) {
    if (states.delete(key(id, path))) listeners.forEach(fn => fn());
  },
  get(id, path) { return states.get(key(id, path)) || null; },
  onChange(fn) { listeners.add(fn); },
  /// { label, cls, busy } (状態がなければ null)
  describe(id, path) {
    const s = states.get(key(id, path));
    if (!s) return null;
    const d = STATES[s.state];
    const time = new Date(s.at).toTimeString().slice(0, 5);
    return { label: t(d.label, { time }), cls: 'rs-' + d.color, busy: !!d.busy, state: s.state };
  },
  LEGEND: [['opened', 'editing'], ['downloading', 'uploaded']].map(row => row.map(s => ({ label: STATES[s].label === '更新 {time}' ? '更新済み' : STATES[s].label, cls: 'rs-' + STATES[s].color }))),
};

// ---------- ログ ----------

const logLines = [];
const logListeners = new Set();
export const RemoteLog = {
  add(text, level = 'info') {
    logLines.push({ at: new Date(), text: String(text), level });
    if (logLines.length > 500) logLines.splice(0, logLines.length - 500);
    logListeners.forEach(fn => fn());
  },
  lines() { return logLines; },
  clear() { logLines.length = 0; logListeners.forEach(fn => fn()); },
  onChange(fn) { logListeners.add(fn); },
};

/// いつも暗いログの欄 (下までスクロールしているときだけ、新しい行を追いかける)。コピー・消すつき
export function logView(app) {
  const list = h('div', { class: 'rlog-lines' });
  const mark = { info: '•', ok: '✓', error: '✗' };
  const render = () => {
    const atBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 20;
    list.textContent = '';
    for (const l of logLines.slice(-300)) list.append(h('div', { class: 'rlog-' + l.level }, `${l.at.toTimeString().slice(0, 8)} ${mark[l.level] || '•'} ${l.text}`));
    if (atBottom) list.scrollTop = list.scrollHeight;
  };
  RemoteLog.onChange(render);
  render();
  return h('div', { class: 'rlog' },
    h('div', { class: 'rlog-head' }, h('span', {}, t('ログ')), h('span', { class: 'tb-space' }),
      h('button', { class: 'rlog-btn', title: t('コピー'), onclick: () => app.api.copyText(logLines.map(l => `${l.at.toTimeString().slice(0, 8)} ${l.text}`).join('\n')) }, '⧉'),
      h('button', { class: 'rlog-btn', title: t('消す'), onclick: () => RemoteLog.clear() }, '🗑')),
    list);
}

// ---------- お気に入りと履歴 (サーバごと) ----------

export const RemotePlaces = {
  get(app, sid) {
    const all = app.prefs.remotePlaces || {};
    const p = all[sid] || {};
    return { favorites: p.favorites || [], folders: p.folders || [], files: p.files || [] };
  },
  save(app, sid, p) {
    const all = Object.assign({}, app.prefs.remotePlaces);
    all[sid] = p;
    app.setPref('remotePlaces', all);
  },
  isFavorite(app, sid, path) { return this.get(app, sid).favorites.includes(path); },
  toggleFavorite(app, sid, path) {
    const p = this.get(app, sid);
    p.favorites = p.favorites.includes(path) ? p.favorites.filter(x => x !== path) : p.favorites.concat([path]);
    this.save(app, sid, p);
  },
  visitFolder(app, sid, path) {
    const p = this.get(app, sid);
    p.folders = [path].concat(p.folders.filter(x => x !== path)).slice(0, 15);
    this.save(app, sid, p);
  },
  visitFile(app, sid, path) {
    const p = this.get(app, sid);
    p.files = [path].concat(p.files.filter(x => x !== path)).slice(0, 15);
    this.save(app, sid, p);
  },
  clearRecent(app, sid) {
    const p = this.get(app, sid);
    this.save(app, sid, { favorites: p.favorites, folders: [], files: [] });
  },
  forget(app, sid) {
    const all = Object.assign({}, app.prefs.remotePlaces);
    delete all[sid];
    app.setPref('remotePlaces', all);
  },
  /// 「お気に入り・履歴」の一覧 (押すと pick(path, isFile))
  listView(app, sid, pick) {
    const box = h('div', { class: 'rplaces' });
    if (!sid) { box.append(h('div', { class: 'dim rplaces-empty' }, t('サーバを選ぶと、お気に入りと履歴が出ます'))); return box; }
    const p = this.get(app, sid);
    const section = (title, items, isFile, glyph) => {
      box.append(h('div', { class: 'rplaces-head' }, title));
      if (!items.length) { box.append(h('div', { class: 'dim rplaces-empty' }, t('(なし)'))); return; }
      for (const path of items) {
        box.append(h('div', { class: 'rplaces-row', title: path, onclick: () => pick(path, isFile) }, h('span', { class: 'rplaces-glyph' }, glyph), h('span', { class: 'rplaces-name' }, '\u200E' + path + '\u200E')));
      }
    };
    section(t('★ お気に入り'), p.favorites, false, '★');
    section(t('最近開いたフォルダ'), p.folders, false, '📁');
    section(t('最近開いたファイル'), p.files, true, '📄');
    return box;
  },
};

/// 日時: 2028/2/2 22:22:22
export function fmtDate(ms) {
  if (!ms) return '';
  const d = new Date(ms);
  const p = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}/${d.getMonth() + 1}/${d.getDate()} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

export const sizeText = n => (n >= 1e6 ? (n / 1e6).toFixed(1) + ' MB' : n >= 1e3 ? (n / 1e3).toFixed(1) + ' KB' : n + ' B');

/// つなぎ先の短い説明: SFTP user@host:22
export function connectionText(s) {
  if (!s) return '';
  return `${String(s.kind || '').toUpperCase()} ${s.user ? s.user + '@' : ''}${s.host}:${s.port}`;
}

// ---------- 右上の知らせ (進み中・うまくいった・失敗) ----------

const toasts = new Map();
/// key が同じなら、その知らせを書き換える。kind: 'progress' | 'success' | 'failure' | 'info'
export function richToast({ key, kind, title, detail }) {
  let host = document.getElementById('rich-toasts');
  if (!host) { host = h('div', { id: 'rich-toasts' }); document.getElementById('overlays').append(host); }
  let entry = key && toasts.get(key);
  if (!entry) {
    const el = h('div', { class: 'rtoast', onclick: () => remove() });
    const remove = () => { el.remove(); if (key) toasts.delete(key); clearTimeout(entry.timer); };
    entry = { el, remove, timer: null };
    if (key) toasts.set(key, entry);
    host.append(el);
  }
  const icon = kind === 'progress' ? h('span', { class: 'rtoast-spin' }) : h('span', { class: 'rtoast-icon ' + kind }, kind === 'success' ? '✓' : kind === 'failure' ? '✗' : 'ℹ');
  entry.el.className = 'rtoast ' + kind;
  entry.el.textContent = '';
  entry.el.append(icon, h('div', { class: 'rtoast-text' }, h('div', { class: 'rtoast-title' }, title), detail ? h('div', { class: 'rtoast-detail' }, detail) : null));
  clearTimeout(entry.timer);
  if (kind !== 'progress') entry.timer = setTimeout(entry.remove, kind === 'failure' ? 10000 : 5000);
}
