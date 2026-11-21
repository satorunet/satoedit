// フォルダツリー (左の欄): フォルダの中身を木で見せる。クリックで開く、名前で絞り込み、右クリックで新規・名前変更など
import { h, popupMenu, promptBox, confirmBox, alertBox } from './dialogs';
import { icon } from './icons';
import i18n from '../../shared/i18n';
import { pathUtil } from './util';

const { t } = i18n;

export class FolderTree {
  constructor(app) {
    this.app = app;
    this.root = '';
    this.open = new Set();
    this.children = new Map();
    this.current = null;
    this.filter = '';
    const pane = app.el.treePane;
    this.title = h('div', { class: 'tree-title' });
    this.search = h('input', { type: 'search', class: 'tree-search', placeholder: t('ファイル名で絞り込み'), 'aria-label': t('ファイル名で絞り込み') });
    this.list = h('div', { class: 'tree-list', role: 'tree', tabindex: '0' });
    this.note = h('div', { class: 'tree-note' });
    pane.append(
      h('div', { class: 'tree-head' }, this.title,
        h('button', { class: 'icon-button', title: t('フォルダを選ぶ'), onclick: () => this.chooseRoot() }, icon('dir', 15)),
        h('button', { class: 'icon-button', title: t('再読み込み'), onclick: () => this.reload() }, icon('refresh', 15))),
      this.search, this.list, this.note);
    let timer = null;
    this.search.addEventListener('input', () => {
      clearTimeout(timer);
      timer = setTimeout(() => { this.filter = this.search.value.trim(); this.render(); }, 200);
    });
    this.list.addEventListener('click', e => this.clicked(e, false));
    this.list.addEventListener('dblclick', e => this.clicked(e, true));
    this.list.addEventListener('contextmenu', e => {
      e.preventDefault();
      const row = e.target.closest('.tree-row');
      this.menu(row ? { path: row.dataset.path, dir: row.dataset.dir === '1' } : { path: this.root, dir: true, isRoot: true }, e.clientX, e.clientY);
    });
    // 右端をドラッグして幅を変える
    const resizer = app.el.treeResizer;
    let dragging = false;
    resizer.addEventListener('mousedown', e => { dragging = true; e.preventDefault(); });
    window.addEventListener('mousemove', e => {
      if (!dragging) return;
      const w = Math.max(140, Math.min(600, e.clientX));
      pane.style.width = w + 'px';
      app.scheduleRuler();
    });
    window.addEventListener('mouseup', () => {
      if (!dragging) return;
      dragging = false;
      app.prefs.folderTreeWidth = parseInt(pane.style.width, 10) || 240;
      app.api.setPref('folderTreeWidth', app.prefs.folderTreeWidth);
    });
  }

  setVisible(on) {
    const pane = this.app.el.treePane;
    if (pane.hidden === !on) return;
    pane.hidden = !on;
    this.app.el.treeResizer.hidden = !on;
    pane.style.width = (this.app.prefs.folderTreeWidth || 240) + 'px';
    if (on && !this.root && this.app.prefs.folderTreeRoot) this.setRoot(this.app.prefs.folderTreeRoot);
    else if (on) this.render();
    this.app.scheduleRuler();
  }

  async chooseRoot() {
    const dirs = await this.app.api.openDialog({ directory: true, title: t('フォルダを開く'), defaultPath: this.root || undefined });
    if (!dirs[0]) return;
    await this.setRoot(dirs[0]);
    if (!this.app.prefs.folderTreeVisible) this.app.setPref('folderTreeVisible', true);
  }

  async setRoot(dir) {
    this.root = dir;
    this.open = new Set([dir]);
    this.children = new Map();
    this.app.prefs.folderTreeRoot = dir;
    this.app.api.setPref('folderTreeRoot', dir);
    await this.load(dir);
    this.render();
  }

  async load(dir) {
    this.children.set(dir, await this.app.api.listDir(dir));
  }

  async reload() {
    if (!this.root) return;
    for (const dir of Array.from(this.open)) await this.load(dir);
    this.render();
  }

  highlight(path) {
    this.current = path || null;
    for (const row of this.list.querySelectorAll('.tree-row')) {
      row.classList.toggle('current', !!path && pathUtil.same(row.dataset.path, path));
    }
  }

  async render() {
    const seq = (this.seq = (this.seq || 0) + 1);
    this.title.textContent = this.root ? pathUtil.base(this.root) : t('フォルダ');
    this.title.title = this.root;
    this.note.textContent = '';
    if (!this.root) {
      this.list.textContent = '';
      this.list.append(h('div', { class: 'tree-empty' }, t('フォルダを選ぶと、中身がここに並びます。'),
        h('button', { onclick: () => this.chooseRoot() }, t('フォルダを開く…'))));
      return;
    }
    const frag = document.createDocumentFragment();
    if (this.filter) {
      // 絞り込み: フォルダの奥まで探して一覧にする
      const r = await this.app.api.findFiles(this.root, this.filter);
      if (seq !== this.seq) return;
      for (const f of r.files) frag.append(this.row(f, pathUtil.base(f), false, 0, f.slice(this.root.length).replace(/^[\\/]/, '')));
      this.note.textContent = r.files.length === 0 ? t('見つかりません') : (r.truncated ? t('500 件まで表示しています。もう少し絞ってください。') : t('{n} 件', { n: r.files.length }));
    } else {
      const walk = (dir, depth) => {
        for (const e of this.children.get(dir) || []) {
          const full = pathUtil.join(dir, e.name);
          frag.append(this.row(full, e.name, e.dir, depth));
          if (e.dir && this.open.has(full)) walk(full, depth + 1);
        }
      };
      walk(this.root, 0);
      if (!(this.children.get(this.root) || []).length) this.note.textContent = t('(空のフォルダ)');
    }
    this.list.textContent = '';
    this.list.append(frag);
    this.highlight(this.current);
  }

  row(path, name, dir, depth, tip) {
    return h('div', {
      class: 'tree-row' + (dir ? ' dir' : '') + (dir && this.open.has(path) ? ' open' : ''), role: 'treeitem',
      'data-path': path, 'data-dir': dir ? '1' : '0', title: tip || path, style: { paddingLeft: (6 + depth * 14) + 'px' },
    }, h('span', { class: 'tree-twist' }, dir ? icon('chevron', 12) : ''), icon(dir ? 'dir' : 'file', 14), h('span', { class: 'tree-name' }, name));
  }

  async clicked(e, double) {
    const row = e.target.closest('.tree-row');
    if (!row) return;
    const path = row.dataset.path;
    if (row.dataset.dir === '1') {
      if (double) return;
      if (this.open.has(path)) this.open.delete(path);
      else { this.open.add(path); await this.load(path); }
      this.render();
      return;
    }
    // 画像や PDF など、エディタで開かないものはダブルクリックで既定のアプリに渡す
    if (/\.(png|jpe?g|gif|bmp|ico|webp|pdf|zip|7z|lzh|exe|dll|msi|docx?|xlsx?|pptx?|mp[34]|wav|mov|avi)$/i.test(path)) {
      if (double) this.app.api.openPath(path);
      return;
    }
    if (!double) this.app.openPath(path);
  }

  menu(target, x, y) {
    if (!this.root) return;
    const app = this.app;
    const dir = target.dir ? target.path : pathUtil.dir(target.path);
    const create = async isDir => {
      const name = await promptBox(isDir ? t('新規フォルダ') : t('新規ファイル'), t('名前'), isDir ? t('新しいフォルダ') : t('新規.txt'));
      if (!name) return;
      const r = await app.api.createEntry(dir, name.trim(), isDir);
      if (r.status !== 'ok') { await alertBox(t('作れませんでした'), r.message); return; }
      this.open.add(dir);
      await this.reload();
      if (!isDir) app.openPath(r.path);
    };
    popupMenu([
      { label: t('新規ファイル…'), action: () => create(false) },
      { label: t('新規フォルダ…'), action: () => create(true) },
      'sep',
      { label: t('名前を変更…'), disabled: !!target.isRoot, action: async () => {
        const old = pathUtil.base(target.path);
        const name = await promptBox(t('名前を変更'), t('新しい名前'), old);
        if (!name || name === old) return;
        const r = await app.api.renameEntry(target.path, name.trim());
        if (r.status !== 'ok') { await alertBox(t('変更できませんでした'), r.message); return; }
        const tab = app.tabs.find(x => x.path && pathUtil.same(x.path, target.path));
        if (tab) { tab.path = r.path; tab.name = pathUtil.base(r.path); app.updateTabs(); }
        await this.reload();
      } },
      { label: t('ごみ箱に入れる'), disabled: !!target.isRoot, action: async () => {
        if (!(await confirmBox(t('「{name}」をごみ箱に入れますか？', { name: pathUtil.base(target.path) }), '', t('ごみ箱に入れる')))) return;
        const r = await app.api.trashEntry(target.path);
        if (r.status !== 'ok') { await alertBox(t('ごみ箱に入れられませんでした'), r.message); return; }
        await this.reload();
      } },
      'sep',
      { label: t('エクスプローラーで表示'), action: () => app.api.reveal(target.path) },
      { label: t('パスをコピー'), action: () => app.api.copyText(target.path) },
      { label: t('再読み込み'), action: () => this.reload() },
    ], x, y);
  }
}
