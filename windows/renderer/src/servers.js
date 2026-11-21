// サーバ (SFTP / FTP / FTPS): 登録したサーバの中を見て回り、ファイルを開く窓
import { h, modal, floatWindow, alertBox, confirmBox, promptBox, popupMenu, toast } from './dialogs';
import { icon } from './icons';
import i18n from '../../shared/i18n';
import { RemoteState, RemoteLog, RemotePlaces, fmtDate, connectionText } from './remotestate';

const { t } = i18n;
const KINDS = [['sftp', 'SFTP (SSH)', 22], ['ftp', 'FTP', 21], ['ftps', 'FTPS (FTP + TLS)', 21]];

function joinPath(dir, name) {
  if (name === '..') {
    const parts = String(dir).split('/').filter(Boolean);
    parts.pop();
    return '/' + parts.join('/');
  }
  return (String(dir).replace(/\/+$/, '') || '') + '/' + name;
}

const displayName = s => s.name || `${s.user ? s.user + '@' : ''}${s.host}`;

/// サーバの追加・設定のダイアログ。保存したら true
async function editServer(app, server) {
  const isNew = !server;
  const s = Object.assign({ id: '', name: '', kind: 'sftp', host: '', port: 22, user: '', auth: 'password', keyFile: '', root: '' }, server || {});
  const hasPassword = isNew ? false : await app.api.serverHasPassword(s.id);
  const kind = h('select', {}, KINDS.map(([id, label]) => h('option', { value: id, selected: id === s.kind }, label)));
  const name = h('input', { type: 'text', class: 'wide', value: s.name, placeholder: t('一覧に出す名前 (空ならアドレス)') });
  const host = h('input', { type: 'text', class: 'wide', value: s.host, placeholder: t('example.com または 192.168.1.10'), autofocus: true });
  const port = h('input', { type: 'number', min: '1', max: '65535', value: s.port, style: { width: '80px' } });
  const user = h('input', { type: 'text', class: 'wide', value: s.user, autocomplete: 'off' });
  const auth = h('select', {}, h('option', { value: 'password', selected: s.auth !== 'key' }, t('パスワード')), h('option', { value: 'key', selected: s.auth === 'key' }, t('鍵ファイル (秘密鍵)')));
  const password = h('input', { type: 'password', class: 'wide', autocomplete: 'new-password', placeholder: hasPassword ? t('保存済み (変えるときだけ入れる)') : t('パスワード / 鍵のパスフレーズ (なければ空)') });
  const keyFile = h('input', { type: 'text', class: 'wide', value: s.keyFile, placeholder: 'C:\\Users\\…\\.ssh\\id_ed25519' });
  const root = h('input', { type: 'text', class: 'wide', value: s.root, placeholder: t('空ならログインした場所 (例: /var/www/html)') });
  const error = h('div', { class: 'find-status warn', role: 'alert' });
  const authRow = h('div', { class: 'form-row' }, h('label', {}, t('ログインの方法')), auth);
  const keyRow = h('div', { class: 'form-row' }, h('label', {}, t('鍵ファイル')), keyFile,
    h('button', { onclick: async () => { const f = await app.api.openDialog({ single: true, title: t('鍵ファイル (秘密鍵)') }); if (f[0]) keyFile.value = f[0]; } }, t('選択…')));
  const sync = () => {
    authRow.hidden = kind.value !== 'sftp';
    keyRow.hidden = kind.value !== 'sftp' || auth.value !== 'key';
  };
  kind.addEventListener('change', () => { port.value = KINDS.find(k => k[0] === kind.value)[2]; sync(); });
  auth.addEventListener('change', sync);
  sync();
  const row = (label, el) => h('div', { class: 'form-row' }, h('label', {}, label), el);
  const ok = await modal({
    title: isNew ? t('サーバを追加') : t('サーバの設定'), width: 520,
    body: h('div', {},
      row(t('種類'), kind), row(t('名前'), name),
      h('div', { class: 'form-row' }, h('label', {}, t('アドレス')), host, h('label', { style: { minWidth: '0' } }, t('ポート')), port),
      row(t('ユーザー名'), user), authRow, keyRow, row(t('パスワード'), password), row(t('最初に開く場所'), root),
      h('div', { class: 'dim' }, t('パスワードは、Windows のログインに結び付けて暗号化し、この PC の中だけに保存します。')),
      h('div', { class: 'dim' }, t('FTP は暗号化されません。できれば SFTP か FTPS を使ってください。')),
      !isNew && s.kind === 'sftp' ? h('div', { class: 'form-row' }, h('button', { onclick: async () => { await app.api.serverForgetKey(s.id); toast(t('覚えている鍵を忘れました。次につなぐとき、新しい鍵を登録します。')); } }, t('覚えている鍵を忘れる'))) : null,
      error),
    buttons: [{ label: t('保存'), value: true, primary: true, validate: async () => {
      const r = await app.api.serverSave({ id: s.id, name: name.value, kind: kind.value, host: host.value, port: port.value, user: user.value, auth: auth.value, keyFile: keyFile.value, root: root.value },
        password.value === '' && hasPassword ? undefined : password.value);
      if (r.status !== 'ok') { error.textContent = r.message; return false; }
      app.prefs.servers = (app.prefs.servers || []).filter(x => x.id !== r.server.id).concat([r.server]);
      return true;
    } }, { label: t('キャンセル'), value: false, cancel: true }],
  });
  return ok;
}

/// サーバの窓を出す
export function openServers(app) {
  let current = null, dir = '/', seq = 0;
  const serverList = h('div', { class: 'server-list', role: 'listbox' });
  const pathField = h('input', { type: 'text', class: 'wide', placeholder: '/path/to/folder', 'aria-label': t('場所') });
  const files = h('div', { class: 'server-files', role: 'list', tabindex: '0' });
  const status = h('div', { class: 'dim server-status', role: 'status' });

  const renderServers = () => {
    serverList.textContent = '';
    const list = (app.prefs.servers || []).slice().sort((a, b) => displayName(a).localeCompare(displayName(b), 'ja'));
    if (!list.length) serverList.append(h('div', { class: 'dim server-empty' }, t('「追加」でサーバを登録します。')));
    for (const s of list) {
      serverList.append(h('div', { class: 'server-row' + (current && current.id === s.id ? ' selected' : ''), role: 'option', title: `${s.kind}://${s.user ? s.user + '@' : ''}${s.host}:${s.port}`,
        onclick: () => select(s),
        oncontextmenu: e => { e.preventDefault(); select(s); popupMenu([
          { label: t('設定…'), action: async () => { if (await editServer(app, s)) { current = app.prefs.servers.find(x => x.id === s.id); renderServers(); load(current.root || null); } } },
          { label: t('一覧から削除…'), action: () => removeServer(s) },
        ], e.clientX, e.clientY); },
      }, h('span', { class: 'server-kind' }, s.kind.toUpperCase()), h('span', { class: 'tree-name' }, displayName(s))));
    }
  };
  const removeServer = async s => {
    if (!(await confirmBox(t('「{name}」を一覧から削除しますか？', { name: displayName(s) }), t('サーバ上のファイルは消えません。'), t('削除')))) return;
    await app.api.serverDelete(s.id);
    app.prefs.servers = (app.prefs.servers || []).filter(x => x.id !== s.id);
    RemotePlaces.forget(app, s.id);
    if (current && current.id === s.id) { current = null; files.textContent = ''; pathField.value = ''; status.textContent = ''; renderPlaces(); }
    renderServers();
  };
  const select = s => { current = s; renderServers(); renderPlaces(); load(s.root || null); };
  // 右側: お気に入り・履歴 (押すとそこへ。ファイルなら開く)
  const placesBox = h('div', { class: 'servers-places' });
  const renderPlaces = () => {
    placesBox.textContent = '';
    placesBox.append(h('div', { class: 'servers-places-title' }, t('お気に入り・履歴')),
      RemotePlaces.listView(app, current && current.id, (path, isFile) => {
        if (!isFile) { load(path); return; }
        const slash = path.lastIndexOf('/');
        load(path.slice(0, slash) || '/').then(() => openFile(path));
      }));
  };
  /// ★: お気に入りに足す・外す、お気に入りと履歴へ移る
  const placesMenu = el => {
    if (!current) return;
    const r = el.getBoundingClientRect();
    const p = RemotePlaces.get(app, current.id);
    const fav = RemotePlaces.isFavorite(app, current.id, dir);
    popupMenu([
      { label: fav ? t('このフォルダをお気に入りから外す') : t('このフォルダをお気に入りに入れる'), action: () => { RemotePlaces.toggleFavorite(app, current.id, dir); renderPlaces(); } },
      'sep',
      ...(p.favorites.length ? p.favorites.map(f => ({ label: '★ ' + f, action: () => load(f) })) : [{ label: t('(お気に入りはまだありません)'), disabled: true }]),
      'sep',
      ...p.folders.slice(0, 10).map(f => ({ label: '📁 ' + f, action: () => load(f) })),
      ...p.files.slice(0, 10).map(f => ({ label: '📄 ' + f, action: () => { const slash = f.lastIndexOf('/'); load(f.slice(0, slash) || '/').then(() => openFile(f)); } })),
      'sep',
      { label: t('履歴を消す'), action: () => { RemotePlaces.clearRecent(app, current.id); renderPlaces(); } },
    ], r.left, r.bottom + 2);
  };

  /// フォルダの中身を出す。target が null なら、ログインした場所
  const load = async target => {
    if (!current) return;
    const mine = (seq += 1);
    status.textContent = t('つないでいます…');
    files.classList.add('loading');
    let where = target;
    if (!where) {
      const home = await app.api.remoteCall(current.id, 'home');
      if (mine !== seq) return;
      if (home.status !== 'ok') { files.classList.remove('loading'); status.textContent = ''; await alertBox(t('サーバとのやりとりに失敗しました'), home.message); return; }
      where = home.value || '/';
    }
    RemoteLog.add(t('一覧: {path} ({conn})', { path: where, conn: connectionText(current) }));
    const r = await app.api.remoteCall(current.id, 'list', where);
    if (mine !== seq) return;
    files.classList.remove('loading');
    if (r.status !== 'ok') { status.textContent = ''; RemoteLog.add(t('一覧を取れませんでした: {msg}', { msg: r.message }), 'error'); await alertBox(t('サーバとのやりとりに失敗しました'), r.message); return; }
    dir = where;
    pathField.value = dir;
    lastList = r.value;
    renderFiles();
    status.textContent = t('{n} 個', { n: r.value.length });
    RemotePlaces.visitFolder(app, current.id, dir);
    renderPlaces();
    // エディタ横のサーバツリーにも、同じ一覧を使ってもらう
    if (app.remoteTree) app.remoteTree.cacheList(current.id, dir, r.value);
  };
  let lastList = [];
  const renderFiles = () => {
    const selected = (files.querySelector('.selected') || {}).dataset;
    const selName = selected && selected.name;
    files.textContent = '';
    if (dir !== '/') files.append(row({ name: '..', dir: true }));
    for (const e of lastList) files.append(row(e));
    if (selName) { const el = files.querySelector(`[data-name="${CSS.escape(selName)}"]`); if (el) el.classList.add('selected'); }
  };
  // 状態 (受信中・編集中・更新済み…) が変わったら色を付け直す
  RemoteState.onChange(() => { if (current && files.isConnected) renderFiles(); });
  const row = e => {
    const st = !e.dir && current ? RemoteState.describe(current.id, joinPath(dir, e.name)) : null;
    const fav = e.dir && e.name !== '..' && current && RemotePlaces.isFavorite(app, current.id, joinPath(dir, e.name));
    return h('div', { class: 'server-file' + (e.dir ? ' dir' : '') + (st ? ' ' + st.cls : ''), role: 'listitem', 'data-name': e.name, 'data-dir': e.dir ? '1' : '0' },
      st && st.busy ? h('span', { class: 'rs-spin' }) : icon(e.dir ? 'dir' : 'file', 14),
      h('span', { class: 'tree-name' }, (e.name === '..' ? t('.. (上のフォルダ)') : e.name) + (fav ? ' ★' : '')),
      h('span', { class: 'server-state' }, st ? st.label : ''),
      h('span', { class: 'dim server-size' }, e.dir || e.size === undefined ? '' : e.size.toLocaleString()),
      h('span', { class: 'dim server-date' }, e.name === '..' ? '' : fmtDate(e.mtime)));
  };

  /// ファイルを開く: エディタ横のサーバツリーを、いま見ているフォルダに合わせて、そのファイルを選んでおく
  const openFile = async full => {
    status.textContent = t('開いています…');
    if (app.remoteTree) app.remoteTree.showFolder(current, dir, full, lastList);
    const tab = await app.openRemote(current.id, full);
    status.textContent = '';
    if (tab) { win.close(); app.focusEditor(); }
  };
  const openEntry = async el => {
    const name = el.dataset.name, full = joinPath(dir, name);
    if (el.dataset.dir === '1') { load(full); return; }
    openFile(full);
  };
  files.addEventListener('dblclick', e => { const el = e.target.closest('.server-file'); if (el) openEntry(el); });
  files.addEventListener('click', e => {
    const el = e.target.closest('.server-file');
    for (const x of files.querySelectorAll('.selected')) x.classList.remove('selected');
    if (el) el.classList.add('selected');
  });
  files.addEventListener('keydown', e => { if (e.key === 'Enter') { const el = files.querySelector('.selected'); if (el) openEntry(el); } });
  files.addEventListener('contextmenu', e => {
    e.preventDefault();
    if (!current) return;
    const el = e.target.closest('.server-file');
    const name = el && el.dataset.name !== '..' ? el.dataset.name : null;
    const act = async (action, ...args) => {
      const r = await app.api.remoteCall(current.id, action, ...args);
      if (r.status !== 'ok') await alertBox(t('サーバとのやりとりに失敗しました'), r.message);
      load(dir);
    };
    const isDir = el && el.dataset.dir === '1' && name;
    popupMenu([
      ...(isDir ? [{ label: RemotePlaces.isFavorite(app, current.id, joinPath(dir, name)) ? t('お気に入りから外す') : t('お気に入りに入れる'), action: () => { RemotePlaces.toggleFavorite(app, current.id, joinPath(dir, name)); renderFiles(); renderPlaces(); } }, 'sep'] : []),
      { label: t('新しいファイル…'), action: async () => { const n = await promptBox(t('新しいファイル'), t('{dir} に作ります', { dir }), '', { placeholder: 'index.html' }); if (n && n.trim()) act('create', joinPath(dir, n.trim())); } },
      { label: t('新しいフォルダ…'), action: async () => { const n = await promptBox(t('新しいフォルダ'), t('{dir} に作ります', { dir }), ''); if (n && n.trim()) act('mkdir', joinPath(dir, n.trim())); } },
      'sep',
      { label: t('名前を変更…'), disabled: !name, action: async () => { const n = await promptBox(t('名前を変更'), t('新しい名前'), name); if (n && n.trim() && n !== name) act('rename', joinPath(dir, name), joinPath(dir, n.trim())); } },
      { label: t('サーバから削除…'), disabled: !name, action: async () => {
        if (!(await confirmBox(t('サーバから「{name}」を削除しますか？', { name }), t('ごみ箱には入らず、元に戻せません。'), t('削除')))) return;
        act('remove', joinPath(dir, name), el.dataset.dir === '1');
      } },
      'sep',
      { label: t('再読み込み'), action: () => load(dir) },
    ], e.clientX, e.clientY);
  });
  pathField.addEventListener('keydown', e => { if (e.key === 'Enter' && !e.isComposing) { e.preventDefault(); load(pathField.value.trim() || '/'); } });

  const body = h('div', { class: 'servers' },
    h('div', { class: 'servers-left' }, serverList,
      h('div', { class: 'form-row' },
        h('button', { onclick: async () => { if (await editServer(app, null)) renderServers(); } }, t('追加…')),
        h('button', { onclick: async () => { if (current && (await editServer(app, current))) { current = app.prefs.servers.find(x => x.id === current.id); renderServers(); load(current.root || null); } } }, t('設定…')))),
    h('div', { class: 'servers-right' },
      h('div', { class: 'form-row' }, pathField,
        h('button', { class: 'icon-button', title: t('お気に入りと履歴'), onclick: e => placesMenu(e.currentTarget) }, '★'),
        h('button', { class: 'icon-button', title: t('再読み込み'), onclick: () => load(pathField.value.trim() || dir) }, icon('refresh', 15))),
      h('div', { class: 'server-files-head dim' }, h('span', {}, t('名前')), h('span', {}, t('状態')), h('span', {}, t('大きさ')), h('span', {}, t('更新日時'))),
      files,
      h('div', { class: 'form-row' }, status, h('span', { class: 'tb-space' }), h('button', { class: 'primary', onclick: () => { const el = files.querySelector('.selected'); if (el) openEntry(el); } }, t('開く')))),
    placesBox);
  const win = floatWindow({ id: 'servers', title: t('サーバ (SFTP / FTP)'), body, width: 1000, onClose: () => app.focusEditor() });
  renderServers();
  renderPlaces();
  // サーバがまだ無ければ、続けて追加の画面を出す
  if (!(app.prefs.servers || []).length) editServer(app, null).then(ok => { if (ok) { renderServers(); select(app.prefs.servers[0]); } });
  return win;
}
