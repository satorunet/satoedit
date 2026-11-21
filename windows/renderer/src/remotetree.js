// エディタの横のサーバツリー (Mac 版と同じ): サーバの中をツリーで見て、ファイルを開く。
// 開いているファイルの状態を色で、送受信中はくるくる回る印で見せる。下にお気に入り・履歴、色の見本、ログ
import { h, popupMenu, confirmBox, alertBox } from './dialogs';
import { icon } from './icons';
import i18n from '../../shared/i18n';
import { RemoteState, RemoteLog, RemotePlaces, logView, connectionText } from './remotestate';

const { t } = i18n;
const parentOf = p => { const i = String(p).lastIndexOf('/'); return i <= 0 ? '/' : p.slice(0, i); };
const joinPath = (dir, name) => (String(dir).replace(/\/+$/, '') || '') + '/' + name;

export class RemoteTree {
  constructor(app) {
    this.app = app;
    this.pane = app.el.remotePane;
    this.server = null;
    this.root = null;
    this.expanded = new Set();
    this.loading = new Set();
    this.cache = new Map(); // "id|dir" → 一覧
    this.selected = null;
    this.dismissed = false;

    this.serverSelect = h('select', { class: 'rtree-server', onchange: () => this.setServer((app.prefs.servers || []).find(s => s.id === this.serverSelect.value), null) });
    this.spinner = h('span', { class: 'rs-spin', hidden: true });
    this.list = h('div', { class: 'rtree-list', tabindex: '0', role: 'tree' });
    this.places = h('div', { class: 'rtree-places' });
    this.legend = h('div', { class: 'rtree-legend' }, RemoteState.LEGEND.map(row => h('div', {}, row.map(x => h('span', { class: x.cls }, '■ ' + t(x.label))))));
    const btn = (label, title, fn) => h('button', { class: 'icon-button', title, 'aria-label': title, onclick: fn }, label);
    this.resizer = h('div', { class: 'rtree-resizer' });
    this.pane.append(this.resizer,
      h('div', { class: 'rtree-head' }, this.serverSelect, this.spinner, h('span', { class: 'tb-space' }),
        btn('★', t('お気に入りと履歴'), e => this.placesMenu(e.currentTarget)),
        btn('⟳', t('再読み込み'), () => this.reload()),
        btn('⧉', t('サーバの窓を開く'), () => app.run('server.open')),
        btn('✕', t('閉じる'), () => this.dismiss())),
      this.list, this.places, this.legend, logView(app));
    this.pane.style.width = (app.prefs.remoteTreeWidth || 260) + 'px';

    this.list.addEventListener('click', e => this.clicked(e, false));
    this.list.addEventListener('dblclick', e => this.clicked(e, true));
    this.list.addEventListener('keydown', e => {
      if (e.key === 'Enter' && this.selected) { e.preventDefault(); this.openFile(this.selected); }
    });
    this.list.addEventListener('contextmenu', e => {
      e.preventDefault();
      const row = e.target.closest('.rtree-row');
      if (!row || row.dataset.dir !== '1' || !this.server) return;
      const p = row.dataset.path;
      popupMenu([{ label: RemotePlaces.isFavorite(app, this.server.id, p) ? t('お気に入りから外す') : t('お気に入りに入れる'),
        action: () => { RemotePlaces.toggleFavorite(app, this.server.id, p); this.renderPlaces(); this.render(); } }], e.clientX, e.clientY);
    });
    RemoteState.onChange(() => { if (this.visible) this.render(); });
    // 左の端をドラッグして幅を変える
    let dragging = false;
    this.resizer.addEventListener('mousedown', e => { dragging = true; e.preventDefault(); });
    window.addEventListener('mousemove', e => {
      if (!dragging) return;
      const left = this.pane.getBoundingClientRect().left;
      this.pane.style.width = Math.max(180, Math.min(600, e.clientX - left)) + 'px';
      app.scheduleRuler();
    });
    window.addEventListener('mouseup', () => {
      if (!dragging) return;
      dragging = false;
      app.prefs.remoteTreeWidth = parseInt(this.pane.style.width, 10) || 260;
      app.api.setPref('remoteTreeWidth', app.prefs.remoteTreeWidth);
    });
  }

  get visible() { return !this.pane.hidden; }

  /// 出すかどうか: 「横に出す」にしている、またはサーバのファイルを編集中 (閉じるを押していなければ)
  update() {
    const app = this.app, p = app.prefs, tab = app.active;
    const wants = !!p.serverEnabled && (!!p.remoteTreeVisible || (!!(tab && tab.remote) && !this.dismissed));
    if (this.visible !== wants) { this.pane.hidden = !wants; app.el.remoteResizer.hidden = !wants; app.scheduleRuler(); if (app.applyLibrary) app.applyLibrary(); }
    if (!wants) return;
    this.renderServers();
    if (tab && tab.remote) this.reveal(tab.remote.id, tab.remote.path);
    else if (!this.server && (p.servers || []).length) this.setServer(p.servers[0], null);
  }

  dismiss() {
    this.dismissed = true;
    if (this.app.prefs.remoteTreeVisible) this.app.setPref('remoteTreeVisible', false);
    else this.update();
  }

  renderServers() {
    const list = this.app.prefs.servers || [];
    const want = list.map(s => s.id).join(',') + '|' + (this.server ? this.server.id : '');
    if (this.serverSelect.dataset.key === want) return;
    this.serverSelect.dataset.key = want;
    this.serverSelect.textContent = '';
    for (const s of list) this.serverSelect.append(h('option', { value: s.id, selected: this.server && this.server.id === s.id }, s.name || `${s.user ? s.user + '@' : ''}${s.host}`));
  }

  /// サーバを替える。root が null ならログインした場所 (または設定の「最初に開く場所」)
  async setServer(server, root) {
    if (!server) return;
    this.server = server;
    this.renderServers();
    this.renderPlaces();
    let where = root || server.root || null;
    if (!where) {
      const home = await this.app.api.remoteCall(server.id, 'home');
      where = home.status === 'ok' ? home.value || '/' : '/';
    }
    this.root = where;
    this.expanded = new Set([where]);
    await this.ensure(where);
    this.render();
  }

  cacheList(sid, dir, list) { this.cache.set(sid + '|' + dir, list); }

  /// サーバの窓でファイルを開いたとき: そのときのフォルダを根に、そのファイルを選んでおく
  showFolder(server, dir, file, list) {
    this.server = server;
    this.root = dir;
    this.expanded = new Set([dir]);
    this.cacheList(server.id, dir, list);
    this.selected = file;
    this.dismissed = false;
    this.renderServers();
    this.renderPlaces();
    this.render();
  }

  async ensure(dir) {
    const k = this.server.id + '|' + dir;
    if (this.cache.has(k)) return this.cache.get(k);
    this.loading.add(dir);
    this.spinner.hidden = false;
    this.render();
    RemoteLog.add(t('一覧: {path} ({conn})', { path: dir, conn: connectionText(this.server) }));
    const r = await this.app.api.remoteCall(this.server.id, 'list', dir);
    this.loading.delete(dir);
    this.spinner.hidden = this.loading.size === 0;
    if (r.status !== 'ok') { RemoteLog.add(t('一覧を取れませんでした: {msg}', { msg: r.message }), 'error'); return []; }
    this.cache.set(k, r.value);
    RemotePlaces.visitFolder(this.app, this.server.id, dir);
    return r.value;
  }

  async reload() {
    if (!this.server) return;
    for (const k of Array.from(this.cache.keys())) if (k.startsWith(this.server.id + '|')) this.cache.delete(k);
    for (const d of this.expanded) await this.ensure(d);
    this.render();
  }

  /// タブを替えた・開いた: そのファイルを選び、見える所まで開く (根の外なら、そのフォルダを根にする)
  async reveal(id, path) {
    const server = (this.app.prefs.servers || []).find(s => s.id === id);
    if (!server) return;
    if (!this.server || this.server.id !== id || !this.root) { this.server = server; this.root = null; }
    const dir = parentOf(path);
    if (!this.root || !(path + '/').startsWith(this.root.replace(/\/$/, '') + '/')) { this.root = dir; this.expanded = new Set([dir]); }
    // 根からそのファイルのフォルダまで開く
    const parts = dir.slice(this.root.length).split('/').filter(Boolean);
    let cur = this.root;
    this.expanded.add(cur);
    await this.ensure(cur);
    for (const p of parts) { cur = joinPath(cur, p); this.expanded.add(cur); await this.ensure(cur); }
    this.selected = path;
    this.renderServers();
    this.renderPlaces();
    this.render();
    const el = this.list.querySelector('.rtree-row.selected');
    if (el && el.scrollIntoViewIfNeeded) el.scrollIntoViewIfNeeded(false);
  }

  render() {
    const top = this.list.scrollTop;
    this.list.textContent = '';
    if (!this.server || !this.root) return;
    const add = (dir, depth) => {
      const items = this.cache.get(this.server.id + '|' + dir) || [];
      for (const e of items) {
        const full = joinPath(dir, e.name);
        const open = e.dir && this.expanded.has(full);
        const st = !e.dir ? RemoteState.describe(this.server.id, full) : null;
        const busy = (st && st.busy) || (e.dir && this.loading.has(full));
        const fav = e.dir && RemotePlaces.isFavorite(this.app, this.server.id, full);
        this.list.append(h('div', { class: 'rtree-row' + (full === this.selected ? ' selected' : '') + (st ? ' ' + st.cls : ''), role: 'treeitem',
          'data-path': full, 'data-dir': e.dir ? '1' : '0', style: { paddingLeft: (4 + depth * 14) + 'px' }, title: full },
          h('span', { class: 'rtree-twist' }, e.dir ? (open ? '▾' : '▸') : ''),
          busy ? h('span', { class: 'rs-spin' }) : icon(e.dir ? 'dir' : 'file', 13),
          h('span', { class: 'tree-name' }, e.name + (fav ? ' ★' : '')),
          h('span', { class: 'rtree-state' }, st ? st.label : '')));
        if (open) add(full, depth + 1);
      }
    };
    this.list.append(h('div', { class: 'rtree-root dim', title: this.root }, '\u200E' + this.root + '\u200E'));
    add(this.root, 0);
    this.list.scrollTop = top;
  }

  renderPlaces() {
    this.places.textContent = '';
    this.places.append(RemotePlaces.listView(this.app, this.server && this.server.id, (path, isFile) => {
      if (isFile) { this.openFile(path); return; }
      this.root = path;
      this.expanded = new Set([path]);
      this.ensure(path).then(() => this.render());
    }));
  }

  placesMenu(el) {
    if (!this.server) return;
    const r = el.getBoundingClientRect();
    const p = RemotePlaces.get(this.app, this.server.id);
    const goFolder = f => { this.root = f; this.expanded = new Set([f]); this.ensure(f).then(() => this.render()); };
    popupMenu([
      ...(p.favorites.length ? p.favorites.map(f => ({ label: '★ ' + f, action: () => goFolder(f) })) : [{ label: t('(お気に入りはまだありません)'), disabled: true }]),
      'sep', ...p.folders.slice(0, 10).map(f => ({ label: '📁 ' + f, action: () => goFolder(f) })),
      ...p.files.slice(0, 10).map(f => ({ label: '📄 ' + f, action: () => this.openFile(f) })),
    ], r.left - 160, r.bottom + 2);
  }

  async clicked(e, double) {
    const row = e.target.closest('.rtree-row');
    if (!row) return;
    const path = row.dataset.path;
    if (row.dataset.dir === '1') {
      if (this.expanded.has(path)) this.expanded.delete(path);
      else { this.expanded.add(path); await this.ensure(path); }
      this.render();
      return;
    }
    this.selected = path;
    this.render();
    // 開いているタブなら、そのタブを出すだけ
    const tab = this.app.tabs.find(x => x.remote && x.remote.id === this.server.id && x.remote.path === path);
    if (tab) { this.app.activate(tab); return; }
    if (double) { this.openFile(path); return; }
    // 1 回押しただけでは開かない: 開くか聞く
    if (await confirmBox(t('「{name}」を開きますか？', { name: path.slice(path.lastIndexOf('/') + 1) }), path, t('開く'))) this.openFile(path);
  }

  async openFile(path) {
    if (!this.server) return;
    this.selected = path;
    this.render();
    const tab = await this.app.openRemote(this.server.id, path);
    if (tab) this.app.focusEditor();
  }
}
