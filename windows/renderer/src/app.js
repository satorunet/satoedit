// さとるエディタの画面側の中心: タブ、ファイルの開閉・保存、メニューの動作、ステータスバー、用紙モードの切り替え
import { Editor, drawRuler } from './editor';
import { h, modal, alertBox, confirmBox, promptBox, popupMenu, toast, isModalOpen } from './dialogs';
import { icon } from './icons';
import { GenkoEditor, A4Editor, genkoPrintHTML, a4PrintHTML, plainPrintHTML, docxParagraphs } from './paper';
import { FindController } from './find';
import { openSettings } from './settings';
import { FolderTree } from './tree';
import { DiffPanel } from './diffpanel';
import { openLocalLLM } from './localllm';
import { PluginManager } from './plugins';
import { showViewer } from './viewers';
import { RemoteTree } from './remotetree';
import { RemoteState, RemoteLog, RemotePlaces, richToast, sizeText, connectionText } from './remotestate';
import { AIPanel, openAISettings, openAIUsage, isVerified } from './aipanel';
import { chooseKey, askUnlock, KINDS as CRYPTO_KINDS } from './cryptoui';
import { screenshotDialog } from './screenshot';
import { openServers } from './servers';
import { CollabPanel, startHosting, joinShare } from './collab';
import { TextLibrary } from './library';
import { ShareLink } from './sharelink';
import { VersionHistory } from './versions';
import { checkForUpdates, scheduleAutoCheck } from './updater';
import { installMockAPI } from './mock-api';
import { installHostAPI } from './host';
import { pathUtil } from './util';
import i18n from '../../shared/i18n';
import menuDef from '../../shared/menu';
import themeDef from '../../shared/theme';
import profilesDef from '../../shared/profiles';
import genko from '../../shared/genko';
import langGuess from '../../shared/langguess';

const { t } = i18n;
const appName = () => t('さとるエディタ');
if (!window.api && window.chrome && window.chrome.webview) installHostAPI(); // 軽量版 (WebView2) の本体とつなぐ
if (!window.api) installMockAPI();
const api = window.api;

const app = {
  api, t, prefs: {}, theme: themeDef.defaults(), userProfiles: [], profiles: profilesDef.BUILT_IN,
  tabs: [], active: null, untitled: 0, info: {}, accel: new Map(),
  el: {},
};
window.__app = app; // 動作確認用

// ---------- 設定 ----------

app.setPref = function (key, value) {
  app.prefs[key] = value;
  api.setPref(key, value);
  app.applyPrefs();
};

/// 横の欄 (フォルダ・差分・AI・チャット) を出して本文が 520 より狭くなったら、ウインドウを広げる
app.fitForPanes = function () {
  requestAnimationFrame(() => {
    const center = document.getElementById('center');
    const w = center ? center.getBoundingClientRect().width : 9999;
    if (w < 520) api.growWindow(Math.ceil(520 - w));
  });
};

app.applyPrefs = function () {
  const p = app.prefs;
  document.body.classList.toggle('no-toolbar', !p.toolbar);
  document.body.classList.toggle('no-ruler', !p.columnRuler);
  for (const tab of app.tabs) {
    tab.editor.configure(p, tab.profile);
    if (tab.paper) tab.paper.setPrefs(p);
    if (!p.paperEnabled && tab.paperMode !== 0) app.setPaperMode(tab, 0, { remember: false });
  }
  app.applyTheme();
  app.renderToolbar();
  app.tree.setVisible(!!(p.folderTreeEnabled && p.folderTreeVisible));
  app.ai.setVisible(!!(p.aiEnabled && p.aiVisible));
  app.diff.setVisible(!!p.diffVisible);
  app.remoteTree.update();
  app.applyLibrary();
  app.fitForPanes();
  app.collabPanel.setVisible(!!(p.collabEnabled && p.collabChatVisible));
  if (!p.collabEnabled && app.collab && app.collab.active) app.collab.stop();
  app.updateStatus();
  app.pushMenuState();
};

/// すべて初期状態に戻す (Mac 版の SettingsBackup.resetAll と同じ): 設定・追加機能のオン・オフとそれぞれの中の設定・欄の開け閉めと幅と並び方・
/// 色・フォント・ファイルタイプ別の設定を最初の状態にする。AI の鍵・サーバの一覧・テキストの一覧・公開中のリンクなど自分のデータは残す
app.resetAllSettings = async function () {
  const choice = await modal({
    title: t('すべての設定を最初の状態に戻しますか？'), body: t('すべての設定が最初の状態に戻ります。'),
    buttons: [{ label: t('初期状態に戻す'), value: 'reset', primary: true }, { label: t('いまの設定を保存してから戻す'), value: 'save' }, { label: t('やめる'), value: null, cancel: true }],
  });
  if (!choice) return false;
  if (choice === 'save' && !(await api.exportSettings())) return false;
  // 取り出した AI の欄は横に戻し、AI・差分の欄は閉じる
  if (app.ai.detached) app.ai.toggleDetached();
  const fresh = await api.resetSettings();
  app.prefs = fresh;
  app.theme = themeDef.defaults();
  app.saveTheme();
  app.userProfiles = [];
  app.reloadProfiles();
  app.remoteTree.dismissed = false;
  app.el.aiPane.style.width = (app.prefs.aiWidth || 340) + 'px';
  app.el.diffPane.style.width = (app.prefs.diffWidth || 360) + 'px';
  app.el.remotePane.style.width = (app.prefs.remoteTreeWidth || 260) + 'px';
  if (app.library) { app.library.arrange(); app.library.reload(); }
  app.applyPrefs();
  toast(t('すべての設定を最初の状態に戻しました'));
  return true;
};

/// 左のテキスト一覧を出し入れする (サーバツリーを出しているあいだは隠す。Mac 版と同じ)
app.applyLibrary = function () {
  const p = app.prefs;
  if (app.library) app.library.setVisible(p.libraryEnabled !== false && p.libraryVisible !== false && !(app.remoteTree && app.remoteTree.visible));
};

app.applyTheme = function () {
  const th = app.theme, colors = themeDef.colors(th), root = document.documentElement.style;
  for (const [key, value] of Object.entries(colors)) root.setProperty('--c-' + key, themeDef.normalizeHex(value) || '#FF00FF');
  const size = th.fontSize || themeDef.DEFAULT_FONT_SIZE;
  root.setProperty('--ed-font', `"${String(th.fontName).replace(/"/g, '')}", ${themeDef.FONT_FALLBACK}`);
  root.setProperty('--ed-size', size + 'px');
  root.setProperty('--ed-line', Math.round(size * 1.3 + (Number(app.prefs.lineSpacing) || 0)) + 'px');
  let dark = false;
  if (th.windowStyle === 'theme') dark = themeDef.isDark(colors.background);
  else if (th.windowStyle === 'system') dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  document.body.dataset.chrome = dark ? 'dark' : 'light';
  // カーソル行の文字の色 (透明にしてあれば変えない)
  const lineText = themeDef.normalizeHex(colors.currentLineText) || '';
  document.body.classList.toggle('cl-text', lineText.length === 7 || (lineText.length === 9 && !lineText.endsWith('00')));
  // ステータスバーは、枠が「灰色」「OS に合わせる」のときは、個別に色を変えていない限り枠と同じ色
  const follows = th.windowStyle !== 'theme';
  root.setProperty('--footer-bg', follows && !th.overrides.statusBackground ? 'var(--chrome-bg)' : 'var(--c-statusBackground)');
  root.setProperty('--footer-fg', follows && !th.overrides.statusText ? 'var(--chrome-fg)' : 'var(--c-statusText)');
  for (const tab of app.tabs) tab.editor.remeasure();
  requestAnimationFrame(app.updateRuler);
};

app.saveTheme = function () {
  app.applyTheme();
  clearTimeout(app.themeTimer);
  app.themeTimer = setTimeout(() => api.saveTheme(app.theme), 400);
  app.pushMenuState();
};

app.reloadProfiles = function () {
  app.profiles = profilesDef.merge(app.userProfiles);
  for (const tab of app.tabs) app.resolveProfile(tab);
  app.applyPrefs();
};

app.resolveProfile = function (tab) {
  tab.profile = tab.languageOverride
    ? (app.profiles.find(p => p.name === tab.languageOverride) || null)
    : (profilesDef.profileForFileName(app.profiles, tab.name)
      // 名前のない文書は、中身から見当をつけた言語 (AI がコードを入れたときなど)
      || (!tab.path && !tab.remote && tab.guessedLanguage ? app.profiles.find(p => p.name === tab.guessedLanguage) || null : null));
};

/// 名前のない文書で言語が「テキスト」のままなら、中身から見当をつけて色分けする
app.guessLanguageIfUnnamed = function (tab) {
  if (!tab || tab.path || tab.remote || tab.languageOverride || tab.profile) return;
  const name = langGuess.guess(tab.getText());
  if (!name) return;
  tab.guessedLanguage = name;
  app.resolveProfile(tab);
  tab.editor.configure(app.prefs, tab.profile);
  app.updateStatus();
};

// ---------- メニュー ----------

app.menuState = function () {
  const tab = app.active;
  const pub = tab && tab.path && app.share ? app.share.recordFor(tab.path) : null;
  return {
    prefs: app.prefs, recent: (app.prefs.recent || []).slice(0, 12),
    pluginMenu: app.plugins ? app.plugins.menuEntries() : [],
    paperMode: tab ? tab.paperMode : 0, genkoHorizontal: !!(tab && tab.genkoHorizontal), hasPath: !!(tab && tab.path),
    published: pub ? { id: pub.id } : null, shareNeedsUpdate: !!(pub && app.share.needsUpdate(pub, tab.getText(), app.share.modeOf(app.modeString(tab)))), split: !!(tab && tab.editor.secondary), splitSide: !!(tab && tab.el.classList.contains('split-side')), encrypted: !!(tab && tab.enc),
    collabActive: !!(app.collab && app.collab.active),
    current: tab ? { encoding: tab.encoding, lineEnding: tab.lineEnding, languageOverride: tab.languageOverride || '' } : {},
    languages: app.profiles.map(p => p.name), themePreset: app.theme.preset,
  };
};

app.pushMenuState = function () {
  clearTimeout(app.menuTimer);
  app.menuTimer = setTimeout(() => {
    const state = app.menuState();
    const menus = menuDef.build(state);
    app.accel = new Map();
    for (const item of menuDef.flatten(menus)) {
      if (item.accel && !item.role && item.enabled !== false) app.accel.set(item.accel, item.id);
    }
    api.setMenuState({
      collabActive: state.collabActive, paperMode: state.paperMode, genkoHorizontal: state.genkoHorizontal, hasPath: state.hasPath,
      published: state.published, shareNeedsUpdate: state.shareNeedsUpdate, split: state.split, splitSide: state.splitSide, encrypted: state.encrypted, current: state.current,
      languages: state.languages, themePreset: state.themePreset,
    });
    if (api.mockMenu) api.mockMenu(menus);
  }, 30);
};

// ---------- タブ ----------

function newTabObject({ path, text, encoding, lineEnding, enc, mtime }) {
  const el = h('div', { class: 'tab-view' });
  const primary = h('div', { class: 'pane primary' });
  const secondary = h('div', { class: 'pane secondary' });
  const paperHost = h('div', { class: 'paper-host' });
  el.append(primary, secondary, paperHost);
  app.el.editors.append(el);
  const tab = {
    id: 'tab' + Math.random().toString(36).slice(2), path: path || null, el, primary, secondary, paperHost,
    encoding: encoding || app.prefs.defaultEncoding || 'utf8', lineEnding: lineEnding || app.prefs.defaultLineEnding || 'crlf',
    languageOverride: '', profile: null, enc: enc || null, plainChoice: false, paperMode: 0, paper: null,
    mtime: mtime || 0, metaDirty: false, name: '',
    genkoHorizontal: !!app.prefs.genkoHorizontal, touched: false, locked: false,
    librarySelection: app.prefs.librarySelectedGroup || 'all',
  };
  if (path) tab.name = pathUtil.base(path);
  else { app.untitled += 1; tab.name = t('(無題)') + (app.untitled > 1 ? ' ' + app.untitled : ''); }
  app.resolveProfile(tab);
  tab.editor = new Editor({
    parent: primary, text: text || '',
    onChange: u => {
      if (tab.isDirty()) tab.touched = true;
      app.scheduleAutosave(tab);
      app.updateTabs();
      app.scheduleStatus();
      if (tab.collab) tab.collab.localUpdate(u);
      if (app.active === tab && app.diff) app.diff.refresh();
      if (tab.remote && !tab.uploading) {
        const cur = RemoteState.get(tab.remote.id, tab.remote.path);
        const want = tab.isDirty() ? 'editing' : 'opened';
        if (!cur || cur.state !== want) RemoteState.set(tab.remote.id, tab.remote.path, want);
      }
      // サーバのファイルは、入力が止まって 2 秒たったら自動で反映する
      if (tab.remote && app.prefs.remoteAutoUpload) {
        clearTimeout(tab.uploadTimer);
        tab.uploadTimer = setTimeout(() => { if (app.tabs.includes(tab) && tab.isDirty() && !isModalOpen()) app.saveRemote(tab, true); }, 2000);
      }
    },
    onSelection: () => { app.scheduleStatus(); if (tab.collab) tab.collab.localSelectionChanged(); if (app.active === tab && app.diff) app.diff.syncCurrentLine(); },
    onFocus: () => app.scheduleStatus(),
    onLink: url => api.openExternal(url),
  });
  tab.editor.extraCompletions = info => (app.plugins && app.plugins.plugins.some(p => p.running && p.hasCompletion) ? app.plugins.completions(info) : null);
  tab.editor.onGeometry = () => { if (app.active === tab) { app.scheduleRuler(); if (app.diff) app.diff.syncScroll(); } };
  tab.editor.configure(app.prefs, tab.profile);
  tab.savedDoc = tab.editor.view.state.doc; tab.editor.clearEditMarks(); if (app.diff) app.diff.refresh(0); // 保存した・開き直した: 目印を消し、差分の「編集前」も新しく
  tab.getText = () => (tab.paper ? tab.paper.getText() : tab.editor.getText());
  tab.isDirty = () => tab.metaDirty || !tab.editor.view.state.doc.eq(tab.savedDoc);
  /// いま字を打っているところ (通常のエディタか、用紙)
  tab.target = () => tab.paper || tab.editor;
  return tab;
}

app.newTab = function (o = {}) {
  const tab = newTabObject(o);
  app.tabs.push(tab);
  app.activate(tab);
  return tab;
};

app.activate = function (tab) {
  const changed = app.active !== tab;
  app.active = tab;
  // テキスト一覧のフォルダは、このタブで選んでいたものに戻す
  if (app.library && changed && tab.librarySelection && tab.librarySelection !== app.prefs.librarySelectedGroup) app.library.select(tab.librarySelection);
  else if (app.library) app.library.renderList();
  for (const x of app.tabs) x.el.classList.toggle('active', x === tab);
  app.updateTabs();
  app.find.onTabChange();
  app.tree.highlight(tab.path);
  if (app.diff) app.diff.refresh(0);
  // タブを替えたら、サーバツリーでそのファイルを選ぶ (サーバのファイルを編集中なら、自動で横に出す)
  if (app.remoteTree) app.remoteTree.update();
  app.updateStatus();
  app.pushMenuState();
  requestAnimationFrame(() => { tab.editor.remeasure(); app.updateRuler(); app.focusEditor(); });
};

app.focusEditor = function () {
  if (isModalOpen() || !app.active) return;
  app.active.target().focus();
};

app.updateTabs = function () {
  const bar = app.el.tabs;
  const want = app.tabs.map(tab => tab.id + '|' + tab.name + '|' + (tab.isDirty() ? 1 : 0) + '|' + (tab.enc ? 1 : 0) + '|' + (tab === app.active ? 1 : 0)).join('\n');
  if (bar.dataset.state === want) return;
  bar.dataset.state = want;
  bar.textContent = '';
  for (const tab of app.tabs) {
    bar.append(h('div', {
      class: 'tab' + (tab === app.active ? ' active' : ''), title: (tab.remote && tab.remote.url) || tab.path || tab.name, role: 'tab',
      onmousedown: e => { if (e.button === 0) app.activate(tab); else if (e.button === 1) { e.preventDefault(); app.closeTab(tab); } },
      oncontextmenu: e => {
        e.preventDefault();
        popupMenu([
          { label: t('閉じる'), action: () => app.closeTab(tab) },
          { label: t('ほかのタブを閉じる'), action: async () => { for (const x of app.tabs.slice()) if (x !== tab && !(await app.closeTab(x))) break; } },
          'sep',
          { label: t('パスをコピー'), disabled: !tab.path, action: () => api.copyText(tab.path) },
          { label: t('エクスプローラーで表示'), disabled: !tab.path, action: () => api.reveal(tab.path) },
        ], e.clientX, e.clientY);
      },
    },
    fileTypeIcon(tab),
    h('span', { class: 'tab-name' }, (tab.enc ? '🔒 ' : '') + tab.name + (tab.isDirty() ? ' ' + t('＊') : '')),
    h('span', { class: 'tab-close', title: t('閉じる'), onmousedown: e => e.stopPropagation(), onclick: () => app.closeTab(tab) }, '✕')));
  }
  const a = app.active;
  if (a) {
    api.setTitle(`${a.enc ? '🔒 ' : ''}${(a.remote && a.remote.url) || a.path || a.name}${a.isDirty() ? ' ' + t('＊') : ''} - ${appName()}`);
    const el = bar.querySelector('.tab.active');
    if (el && el.scrollIntoView) el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  }
};

/// タブに出す、ファイルの種類のアイコン (Windows が持っているアイコン。拡張子ごとに 1 回だけ取りに行く)
const iconCache = new Map();
function fileTypeIcon(tab) {
  const name = (tab.remote && tab.remote.path) || tab.path || tab.name || '';
  const m = /\.([A-Za-z0-9]{1,10})$/.exec(name);
  const ext = m ? m[1].toLowerCase() : 'txt';
  const img = h('img', { class: 'tab-icon', alt: '', draggable: 'false' });
  const known = iconCache.get(ext);
  if (typeof known === 'string') img.src = known;
  else {
    img.hidden = true;
    if (!known) iconCache.set(ext, api.fileIcon(ext).then(url => { iconCache.set(ext, url || ''); app.el.tabs.dataset.state = ''; app.updateTabs(); }).catch(() => iconCache.set(ext, '')));
  }
  if (img.src === '' || known === '') img.hidden = true;
  return img;
}

/// 閉じたら true。保存していない変更があれば聞く
app.closeTab = async function (tab, { noAsk } = {}) {
  if (tab.isDirty() && !noAsk) {
    app.activate(tab);
    const answer = await modal({
      title: t('「{name}」の変更を保存しますか？', { name: tab.name }), body: t('保存しないと、変更は失われます。'),
      buttons: [{ label: t('保存する'), value: 'save', primary: true }, { label: t('保存しない'), value: 'discard' }, { label: t('キャンセル'), value: 'cancel', cancel: true }],
    });
    if (answer === 'cancel' || answer === undefined) return false;
    if (answer === 'save' && !(await app.save(tab))) return false;
  }
  app.rememberCaret(tab);
  clearTimeout(tab.autosaveTimer);
  if (tab.path) {
    // 閉じるときは、待っている版の記録をすぐ済ませる。何も書かないまま閉じた「新規テキスト」は消す
    api.versionFlush(tab.path);
    if (app.library && app.library.isPlaceholder(tab.path) && !tab.getText().trim()) api.libraryRemoveEmpty(tab.path).then(() => app.library.changed());
  }
  if (tab.collab && tab.collab.active) tab.collab.stop();
  if (tab.paper) tab.paper.destroy();
  tab.editor.destroy();
  // サーバのファイルを閉じたら、「タブで開き中・編集中」の色を消す (ほかのタブで開いていなければ)
  if (tab.remote && !app.tabs.some(x => x !== tab && x.remote && x.remote.id === tab.remote.id && x.remote.path === tab.remote.path)) {
    const st = RemoteState.get(tab.remote.id, tab.remote.path);
    if (st && (st.state === 'opened' || st.state === 'editing')) RemoteState.clear(tab.remote.id, tab.remote.path);
  }
  tab.el.remove();
  const i = app.tabs.indexOf(tab);
  app.tabs.splice(i, 1);
  if (app.tabs.length === 0) app.newTab();
  else if (app.active === tab) app.activate(app.tabs[Math.min(i, app.tabs.length - 1)]);
  else app.updateTabs();
  return true;
};

/// 開いている文書のファイルを削除したとき: タブは閉じず、何も書いていない新しいテキストにする (サーバの文書などは閉じる)
app.makeBlank = async function (tab) {
  if (tab.remote || (tab.collab && tab.collab.active)) { await app.closeTab(tab, { noAsk: true }); return; }
  app.rememberCaret(tab);
  clearTimeout(tab.autosaveTimer);
  if (tab.path) api.versionFlush(tab.path);
  if (tab.paperMode !== 0) app.setPaperMode(tab, 0, { remember: false });
  tab.path = null;
  app.untitled += 1;
  tab.name = t('(無題)') + (app.untitled > 1 ? ' ' + app.untitled : '');
  tab.enc = null;
  tab.mtime = 0;
  tab.metaDirty = false;
  tab.touched = false;
  tab.plainChoice = false;
  app.setLocked(tab, false);
  app.resolveProfile(tab);
  tab.editor.setText('', false);
  tab.editor.configure(app.prefs, tab.profile);
  tab.savedDoc = tab.editor.view.state.doc; tab.editor.clearEditMarks(); if (app.diff) app.diff.refresh(0);
  app.updateTabs();
  if (tab === app.active) { app.tree.highlight(null); app.updateStatus(); app.pushMenuState(); }
};

app.rememberCaret = function (tab) {
  if (!tab.path || !app.prefs.rememberCaret) return;
  const carets = Object.assign({}, app.prefs.carets || {});
  delete carets[tab.path];
  carets[tab.path] = tab.editor.view.state.selection.main.head;
  const keys = Object.keys(carets);
  for (const k of keys.slice(0, Math.max(0, keys.length - 200))) delete carets[k];
  app.prefs.carets = carets;
  api.setPref('carets', carets);
};

// ---------- 開く・保存 ----------

/// 暗号化ファイルなら鍵を聞きながら読む。やめたら null
async function readWithUnlock(path, encoding, read, forceText) {
  read = read || (opts => api.readFile(path, opts));
  let creds = {}, wrong = 0, message = '';
  for (;;) {
    const r = await read({ encoding, creds, forceText: !!forceText });
    if (r.status === 'ok' || r.status === 'viewer') return r;
    if (r.status === 'locked') {
      creds = await askUnlock(app, r.need, pathUtil.base(path), message);
      if (!creds) return null;
      message = '';
      continue;
    }
    // 入れ間違いはやり直せる。5 回まちがえたら開くのをやめる
    if ((r.code === 'wrong' || r.code === 'wrongCode' || r.code === 'wrongKeyFile') && Object.keys(creds).length) {
      wrong += 1;
      if (wrong >= 5) { await alertBox(t('開くのをやめました'), t('5 回まちがえました。')); return null; }
      message = r.message;
      const again = await read({ encoding, creds: {} });
      if (again.status !== 'locked') { await alertBox(t('開けませんでした'), again.message || r.message); return null; }
      creds = await askUnlock(app, again.need, pathUtil.base(path), message);
      if (!creds) return null;
      continue;
    }
    await alertBox(t('開けませんでした'), `${path}\n\n${r.message}`);
    return null;
  }
}

app.openPath = async function (path, { line, encoding, forceText, browse } = {}) {
  const existing = app.tabs.find(x => x.path && pathUtil.same(x.path, path));
  if (existing && !encoding) {
    app.activate(existing);
    if (line) app.goToLine(line);
    return existing;
  }
  const r = await readWithUnlock(path, encoding, null, forceText);
  if (!r) return null;
  // 画像やバイナリは、見るだけの画面で
  if (r.status === 'viewer') {
    showViewer(app, r, { name: pathUtil.base(path), openAsText: () => app.openPath(path, { forceText: true }), openExternal: () => api.openPath(path) });
    return null;
  }
  app.prefs.recent = [path].concat((app.prefs.recent || []).filter(f => f !== path)).slice(0, 12);
  let tab = existing;
  // 何も書いていない無題のタブは使い回す。テキスト一覧から開くときは、見ただけのタブ (開いてから書き換えていない) も使い回す
  const a = app.active;
  if (!tab && a && app.canReplace(a, browse)) tab = a;
  if (tab) {
    tab.path = path;
    tab.name = pathUtil.base(path);
    tab.encoding = r.encoding;
    tab.lineEnding = r.lineEnding;
    tab.enc = r.enc;
    tab.mtime = r.mtime;
    tab.metaDirty = false;
    tab.touched = false;
    tab.plainChoice = false;
    if (tab.paperMode !== 0) app.setPaperMode(tab, 0, { remember: false });
    app.resolveProfile(tab);
    tab.editor.setText(r.text, false);
    tab.editor.configure(app.prefs, tab.profile);
    tab.savedDoc = tab.editor.view.state.doc; tab.editor.clearEditMarks(); if (app.diff) app.diff.refresh(0); // 保存した・開き直した: 目印を消し、差分の「編集前」も新しく
    app.activate(tab);
  } else {
    tab = app.newTab({ path, text: r.text, encoding: r.encoding, lineEnding: r.lineEnding, enc: r.enc, mtime: r.mtime });
  }
  const caret = (app.prefs.carets || {})[path];
  if (line) app.goToLine(line);
  else if (app.prefs.rememberCaret && typeof caret === 'number') tab.editor.setCaret(caret);
  app.setLocked(tab, !!r.locked);
  // ファイルに書いてある表示 (原稿用紙の縦・横、A4) で開く。用紙切替を切っているときは、いつも標準エディタ
  const mode = r.mode || (app.library ? app.library.modeFallback(path) : null);
  if (app.prefs.paperEnabled && mode && !r.enc) app.setPaperMode(tab, mode === 'a4' ? 2 : mode === 'genkoH' ? 3 : 1, { remember: false });
  if (app.library) { app.library.remember(path); app.library.renderList(); }
  if (!r.enc) api.versionNoteOpened(path);
  if (app.plugins) app.plugins.emit('open', tab);
  app.pushMenuState();
  return tab;
};

/// このタブを、次に開くファイルで使い回してよいか: 書き換えていない・サーバや共同編集の文書でない。名前のない文書は何も書いていないときだけ
app.canReplace = function (tab, browse) {
  if (tab.isDirty() || tab.remote || (tab.collab && tab.collab.active)) return false;
  if (!tab.path) return tab.getText().length === 0;
  return !!browse && !tab.touched;
};

/// 表示の名前 (ファイルの見えない所に書くもの): "genko" / "genkoH" / "a4" / null (標準エディタ)
app.modeString = function (tab) {
  if (!tab) return null;
  return tab.paperMode === 1 ? (tab.genkoHorizontal ? 'genkoH' : 'genko') : tab.paperMode === 2 ? 'a4' : null;
};

/// ロック (読み取り専用) したファイル: 書き換えられないようにする
app.setLocked = function (tab, on) {
  tab.locked = !!on;
  tab.editor.setReadOnly(tab.locked);
  if (tab.paper && tab.paper.setReadOnly) tab.paper.setReadOnly(tab.locked);
  if (tab === app.active) app.updateStatus();
};

/// 自動保存 (メモ帳のように): テキスト一覧のフォルダの文書は、書き換えたら少し待って保存する。
/// 暗号化した文書・サーバの文書・データ暗号化をオンにしているとき・ロックした文書は、今までどおり自分で保存する。名前のない文書 (Ctrl+N) は保存しない
app.scheduleAutosave = function (tab) {
  if (!tab.path || tab.remote || tab.enc || tab.locked || app.prefs.encryptionEnabled || app.prefs.encryptAlways) return;
  if (!app.library || app.prefs.libraryEnabled === false || !app.library.isInFolder(tab.path)) return;
  if (!tab.isDirty()) return;
  clearTimeout(tab.autosaveTimer);
  tab.autosaveTimer = setTimeout(async () => {
    if (!app.tabs.includes(tab) || !tab.isDirty()) return;
    if (!tab.getText().trim()) return;
    await app.save(tab, { auto: true });
  }, 1500);
};

/// サーバのファイルを開く
app.openRemote = async function (id, file, { forceText } = {}) {
  const existing = app.tabs.find(x => x.remote && x.remote.id === id && x.remote.path === file);
  if (existing) {
    app.activate(existing);
    if (existing.isDirty()) richToast({ kind: 'info', title: t('編集中のタブを出しました'), detail: t('保存していない変更があるので、サーバから読み直していません。') });
    return existing;
  }
  // 受信中 → 開いた (知らせ・ログ・色)
  const server = (app.prefs.servers || []).find(x => x.id === id);
  const conn = connectionText(server), tkey = 'remote:' + id + file;
  const name = pathUtil.base(file), started = Date.now();
  RemoteState.set(id, file, 'downloading');
  RemoteLog.add(t('受信: {path} ({conn})', { path: file, conn }));
  richToast({ key: tkey, kind: 'progress', title: t('受信中: {name}', { name }), detail: conn + '\n' + file });
  const r = await readWithUnlock(file, undefined, opts => api.remoteRead(id, file, opts), forceText);
  if (!r || (r.status !== 'ok' && r.status !== 'viewer')) {
    RemoteState.set(id, file, 'failed');
    RemoteLog.add(t('受信できませんでした: {path}', { path: file }), 'error');
    richToast({ key: tkey, kind: 'failure', title: t('受信できませんでした: {name}', { name }), detail: conn + '\n' + file });
    return null;
  }
  const secs = ((Date.now() - started) / 1000).toFixed(1);
  RemoteLog.add(t('受信しました: {path} ({size}, {s} 秒)', { path: file, size: sizeText(r.size || 0), s: secs }), 'ok');
  richToast({ key: tkey, kind: 'success', title: t('開きました: {name}', { name }), detail: `${conn}\n${file}\n${sizeText(r.size || 0)} ・ ${secs} ${t('秒')}` });
  RemotePlaces.visitFile(app, id, file);
  if (r.status === 'viewer') RemoteState.clear(id, file); else RemoteState.set(id, file, 'opened');
  if (r.status === 'viewer') {
    showViewer(app, r, { name: pathUtil.base(file), openAsText: () => app.openRemote(id, file, { forceText: true }) });
    return null;
  }
  const tab = app.newTab({ text: r.text, encoding: r.encoding, lineEnding: r.lineEnding, enc: r.enc });
  tab.remote = r.remote;
  tab.name = pathUtil.base(file);
  tab.plainChoice = true; // サーバのファイルは、もとのまま (暗号化されていれば暗号化のまま) 保存する
  app.untitled -= 1;
  app.resolveProfile(tab);
  tab.editor.configure(app.prefs, tab.profile);
  app.updateTabs();
  app.updateStatus();
  // サーバのファイルを編集中は、エディタの横にサーバツリーを出して、このファイルを選ぶ
  if (app.remoteTree) { app.remoteTree.dismissed = false; app.remoteTree.update(); }
  return tab;
};

/// サーバのファイルを保存する (サーバに反映する)。quiet なら、うまくいったときは何も出さない
app.saveRemote = async function (tab, quiet) {
  if (tab.uploading) { tab.uploadAgain = true; return false; }
  tab.uploading = true;
  clearTimeout(tab.uploadTimer);
  if (tab.paper) app.syncFromPaper(tab);
  const doc = tab.editor.view.state.doc;
  // 送信中 → 更新済み (知らせ・ログ・色)
  const { id, path: file } = tab.remote;
  const server = (app.prefs.servers || []).find(x => x.id === id);
  const conn = connectionText(server), tkey = 'remote:' + id + file, started = Date.now();
  RemoteState.set(id, file, 'uploading');
  RemoteLog.add(t('送信: {path} ({conn})', { path: file, conn }));
  richToast({ key: tkey, kind: 'progress', title: t('送信中: {name}', { name: tab.name }), detail: conn + '\n' + file });
  const r = await api.remoteWrite(tab.remote.id, tab.remote.path, { text: tab.getText(), encoding: tab.encoding, lineEnding: tab.lineEnding, encToken: tab.enc ? tab.enc.token : null });
  tab.uploading = false;
  if (r.status !== 'ok') {
    RemoteState.set(id, file, 'failed');
    RemoteLog.add(t('送信できませんでした: {path} — {msg}', { path: file, msg: r.message }), 'error');
    richToast({ key: tkey, kind: 'failure', title: t('サーバに保存できませんでした'), detail: `${conn}\n${file}\n${r.message}` });
    await alertBox(t('サーバに保存できませんでした'), `${tab.remote.url}\n\n${r.message}`);
    return false;
  }
  const secs = ((Date.now() - started) / 1000).toFixed(1);
  RemoteLog.add(t('送信しました: {path} ({size}, {s} 秒)', { path: file, size: sizeText(r.size || 0), s: secs }), 'ok');
  richToast({ key: tkey, kind: 'success', title: t('サーバに反映しました: {name}', { name: tab.name }), detail: `${conn}\n${file}\n${sizeText(r.size || 0)} ・ ${secs} ${t('秒')}` });
  tab.savedDoc = doc; tab.editor.clearEditMarks(); if (app.diff) app.diff.refresh(0); // 保存した・開き直した: 目印を消し、差分の「編集前」も新しく
  tab.metaDirty = false;
  app.updateTabs();
  app.el.statusNotes.textContent = t('サーバに反映しました: {name}', { name: tab.name });
  // 送っているあいだにまた書き換えていたら「編集中」、そうでなければ「更新済み」
  RemoteState.set(id, file, tab.isDirty() ? 'editing' : 'uploaded');
  if (tab.uploadAgain) { tab.uploadAgain = false; if (tab.isDirty()) return app.saveRemote(tab, quiet); }
  return true;
};

app.openDialog = async function () {
  const a = app.active;
  const files = await api.openDialog({ defaultPath: a && a.path ? pathUtil.dir(a.path) : undefined });
  for (const f of files) await app.openPath(f);
};

/// 保存できたら true
app.save = async function (tab, { saveAs, auto, versionNow } = {}) {
  tab = tab || app.active;
  if (tab.remote && !saveAs) return app.saveRemote(tab, false);
  if (tab.saving) { tab.saveAgain = true; return false; }
  let path = tab.path;
  // テキスト一覧の「新規テキスト」を Ctrl+S: 名前を付けて保存にする (置き場所はそのフォルダ、名前の候補は 1 行目。名前は自分で決める)
  const placeholder = !auto && !saveAs && app.library && app.library.isPlaceholder(tab.path) ? tab.path : null;
  if (!path || saveAs || placeholder) {
    if (tab.paper) app.syncFromPaper(tab);
    const dir = placeholder ? pathUtil.dir(placeholder) : null;
    const suggested = placeholder ? await suggestName(tab.getText(), dir) : (tab.path || tab.name.replace(/[\\/:*?"<>|()（）]/g, '').trim() + '.txt');
    path = await api.saveDialog({ defaultPath: suggested });
    if (!path) return false;
  }
  if (tab.locked && !saveAs && !placeholder) {
    if (!auto) await alertBox(t('保存できませんでした'), t('ロックしているので保存できません。テキスト一覧の右クリックで「ロックを外す」を選んでください。'));
    return false;
  }
  if (tab.paper) app.syncFromPaper(tab);
  // 拡張機能の「保存の直前」(ここで本文を書き換えると、その内容で保存される)
  if (app.plugins) await app.plugins.emit('beforeSave', tab);
  let text = tab.getText();
  if (app.prefs.trimTrailingOnSave && tab.paperMode === 0) {
    const trimmed = text.replace(/[ \t]+$/gm, '');
    if (trimmed !== text) { tab.editor.setText(trimmed, true); text = trimmed; }
  }
  // 流出防止: 暗号化していない文書は、どちらで保存するか確かめる
  if (app.prefs.encryptionEnabled && !tab.enc && !tab.plainChoice) {
    let choice = 'encrypt';
    if (!app.prefs.encryptAlways) {
      choice = await modal({
        title: t('どちらで保存しますか？'), body: t('データ暗号化がオンです。暗号化すると、鍵を持つ人しか開けません。'),
        buttons: [{ label: t('暗号化して保存'), value: 'encrypt', primary: true }, { label: t('そのまま保存'), value: 'plain' }, { label: t('キャンセル'), value: 'cancel', cancel: true }],
      });
    }
    if (choice === 'cancel' || choice === undefined) return false;
    if (choice === 'plain') tab.plainChoice = true;
    else {
      const enc = await chooseKey(app, pathUtil.base(path));
      if (!enc) return false;
      tab.enc = enc;
    }
  }
  tab.saving = true;
  const writtenDoc = tab.editor.view.state.doc;
  const r = await api.writeFile({
    path, text, encoding: tab.encoding, lineEnding: tab.lineEnding,
    encToken: tab.enc ? tab.enc.token : null, backup: !!app.prefs.backupOnSave && !auto,
    mode: app.modeString(tab), versionNow: !auto || !!versionNow,
  });
  tab.saving = false;
  if (r.status !== 'ok') {
    if (!auto || !tab.autosaveFailed) await alertBox(t('保存できませんでした'), r.message);
    if (auto) tab.autosaveFailed = true;
    return false;
  }
  tab.autosaveFailed = false;
  const oldPath = tab.path;
  tab.path = path;
  tab.remote = null; // 名前を付けてこの PC に保存したら、サーバとのつながりは切る
  tab.name = pathUtil.base(path);
  tab.mtime = r.mtime;
  tab.metaDirty = false;
  tab.savedDoc = writtenDoc; if (!auto) tab.editor.clearEditMarks(); if (app.diff && !auto) app.diff.refresh(0); // 保存した・開き直した: 目印を消し、差分の「編集前」も新しく
  app.prefs.recent = [path].concat((app.prefs.recent || []).filter(f => f !== path)).slice(0, 12);
  if (app.library) {
    // 「新規テキスト」を名前を付けて保存したら、元の仮のファイルは消し、表示・公開リンク・版の履歴・ピンは引き継ぐ
    if (placeholder && !pathUtil.same(placeholder, path)) {
      await api.versionRepath(placeholder, path);
      const pinned = app.library.isPinned(placeholder);
      app.library.relocate(placeholder, path);
      await api.libraryRemovePlaceholder(placeholder);
      if (pinned) app.library.setPinned(true, path);
    } else if (saveAs && oldPath && !pathUtil.same(oldPath, path)) {
      // 名前を付けて保存: 新しいファイルに今の表示を書く (元のファイルはそのまま)
    }
    app.library.remember(path);
    app.library.changed();
  }
  if (tab.saveAgain) { tab.saveAgain = false; if (tab.isDirty()) app.scheduleAutosave(tab); }
  if (!tab.languageOverride) { app.resolveProfile(tab); tab.editor.configure(app.prefs, tab.profile); }
  app.rememberCaret(tab);
  // 用紙モードでは、見たままの PDF も一緒に作る (暗号化した文書は、中身が読める PDF を残さない)
  if (tab.paperMode !== 0 && app.prefs.paperSavePDF && !tab.enc && !auto) {
    const pdf = await app.exportPDF(tab, pathUtil.withExtension(path, 'pdf'));
    if (pdf) toast(t('保存しました (PDF も作りました)'));
  }
  app.updateTabs();
  app.updateStatus();
  app.tree.highlight(tab.path);
  app.pushMenuState();
  if (app.plugins) { app.plugins.emit('save', tab); app.plugins.fileSaved(tab.path); }
  return true;
};

/// 新しい文書の名前の候補: 1 行目 (なければ日時) から作る。同じ名前があれば番号を付ける
async function suggestName(text, dir) {
  const first = text.split('\n').map(s => s.trim()).find(s => s) || '';
  let base = Array.from(first.replace(/[\\/:*?"<>|\u0000-\u001f]/g, '')).slice(0, 30).join('').trim();
  if (!base || base.startsWith('.')) {
    const d = new Date(), p = n => String(n).padStart(2, '0');
    base = t('メモ {when}', { when: `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}${p(d.getMinutes())}` });
  }
  for (let n = 1; n < 200; n++) {
    const f = dir + '\\' + base + (n === 1 ? '' : ' ' + n) + '.txt';
    const info = await api.fileInfo(f);
    if (!info.exists) return f;
  }
  return dir + '\\' + base + '.txt';
}

app.revert = async function () {
  const tab = app.active;
  if (tab.remote) { toast(t('サーバのファイルでは使えません')); return; }
  if (!tab.path) return;
  if (tab.isDirty() && !(await confirmBox(t('保存時の状態に戻しますか？'), t('保存していない変更は失われます。'), t('戻す')))) return;
  const r = await readWithUnlock(tab.path);
  if (!r) return;
  if (tab.paperMode !== 0) app.setPaperMode(tab, 0);
  tab.encoding = r.encoding; tab.lineEnding = r.lineEnding; tab.enc = r.enc; tab.metaDirty = false;
  tab.editor.setText(r.text, false);
  tab.editor.configure(app.prefs, tab.profile);
  tab.savedDoc = tab.editor.view.state.doc; tab.editor.clearEditMarks(); if (app.diff) app.diff.refresh(0); // 保存した・開き直した: 目印を消し、差分の「編集前」も新しく
  app.updateTabs(); app.updateStatus(); app.pushMenuState();
};

app.reopenWithEncoding = async function (encoding) {
  const tab = app.active;
  if (!tab.path) { toast(t('まだ保存していない文書です')); return; }
  if (tab.isDirty() && !(await confirmBox(t('開き直しますか？'), t('保存していない変更は失われます。'), t('開き直す')))) return;
  const r = await readWithUnlock(tab.path, encoding);
  if (!r) return;
  tab.encoding = r.encoding; tab.lineEnding = r.lineEnding; tab.enc = r.enc; tab.metaDirty = false;
  if (tab.paperMode !== 0) app.setPaperMode(tab, 0);
  tab.editor.setText(r.text, false);
  tab.editor.configure(app.prefs, tab.profile);
  tab.savedDoc = tab.editor.view.state.doc; tab.editor.clearEditMarks(); if (app.diff) app.diff.refresh(0); // 保存した・開き直した: 目印を消し、差分の「編集前」も新しく
  app.updateTabs(); app.updateStatus(); app.pushMenuState();
};

// ---------- 用紙モード ----------

app.syncFromPaper = function (tab) {
  if (!tab.paper) return;
  const text = tab.paper.getText();
  if (text !== tab.editor.getText()) tab.editor.setText(text, true);
};

/// 文章の from〜to を置き換える (AI の答えを入れるとき)。用紙モードでも通常でも同じ位置の数え方
app.replaceRange = function (tab, from, to, text) {
  if (tab.paper) { tab.paper.replaceRange(from, to, text); app.syncFromPaper(tab); }
  else tab.editor.replaceRange(from, to, text);
  app.updateTabs();
};

/// 新しい鍵で暗号化して保存し直す (方法の変更・鍵の変更・はじめての暗号化)
app.reencrypt = async function (tab, options) {
  if (tab.collab && tab.collab.active) { toast(t('共同編集のあいだは変えられません。')); return; }
  const enc = await chooseKey(app, tab.name, options);
  if (!enc) return;
  tab.enc = enc;
  tab.plainChoice = false;
  tab.metaDirty = true;
  app.updateTabs(); app.updateStatus(); app.pushMenuState();
  await app.save(tab);
};

// 暗号化の方法の短い名前 (ステータスバーなどに出す)
const SHORT_KIND = { password: 'パスワード', passcode: 'パスコード', device: 'この PC のロック', totp: 'ワンタイム認証', twoStep: '二段階', keyfile: '鍵ファイル' };

/// この文書の暗号化の設定 (ステータスバーとは別の画面): いまの方法を見て、方法の変更・鍵の変更・解除を選ぶ
async function encryptionSettings(app) {
  const tab = app.active;
  const locked = !!(tab.collab && tab.collab.active);
  const select = h('select', {}, CRYPTO_KINDS.map(k => h('option', { value: k.id, selected: k.id === (tab.enc ? tab.enc.kind : app.prefs.encDefaultKind || 'device') }, t(SHORT_KIND[k.id]))));
  const now = tab.enc
    ? [t('いま: 🔒 {kind} で暗号化しています。', { kind: t(SHORT_KIND[tab.enc.kind]) }), t('「方法を変える」は下で選んだ方法で、「鍵の変更」は同じ方法のまま新しい鍵で暗号化し直します。')]
    : [t('いま: 🔓 暗号化していません。下で選んだ方法で暗号化して保存できます。')];
  if (locked) now.push(t('共同編集のあいだは変えられません。'));
  const buttons = tab.enc
    ? [{ label: t('方法を変える'), value: 'method', primary: true }, { label: t('鍵の変更…'), value: 'key' }, { label: t('暗号化を解除…'), value: 'off' }, { label: t('閉じる'), value: null, cancel: true }]
    : [{ label: t('暗号化する'), value: 'method', primary: true }, { label: t('閉じる'), value: null, cancel: true }];
  if (locked) buttons.forEach(b => { if (b.value) b.validate = () => false; });
  const r = await modal({
    title: t('この文書の暗号化の設定'), width: 500,
    body: h('div', {}, ...now.map(x => h('div', { class: 'modal-line' }, x)), h('div', { class: 'form-row top-gap' }, h('label', {}, t('暗号化の方法')), select)),
    buttons,
  });
  if (r === 'method') app.reencrypt(tab, { initialKind: select.value });
  else if (r === 'key') app.run('crypto.changeKey');
  else if (r === 'off') app.run('crypto.decrypt');
}

app.setPaperMode = function (tab, mode, { remember = true } = {}) {
  tab = tab || app.active;
  // 3 = 原稿用紙 (横書き)。縦 ⇔ 横 の切り替えはこのタブだけ (自分で選んだときは、新しいタブの向きとしても覚える)
  if (mode === 3 || mode === 1) {
    const horizontal = mode === 3;
    if (remember) { app.prefs.genkoHorizontal = horizontal; api.setPref('genkoHorizontal', horizontal); }
    if (tab.genkoHorizontal !== horizontal) {
      tab.genkoHorizontal = horizontal;
      if (tab.paperMode === 1) { app.syncFromPaper(tab); tab.paperMode = -1; } // 作り直す
    }
    mode = 1;
  }
  if (tab.paperMode === mode) return;
  if (tab.paperMode === -1) tab.paperMode = 1;
  if (mode !== 0 && tab.collab && tab.collab.active) { toast(t('共同編集のあいだは、用紙モードにできません')); return; }
  if (tab.paper) {
    app.syncFromPaper(tab);
    tab.paper.destroy();
    tab.paper = null;
  }
  tab.paperMode = mode;
  tab.el.classList.toggle('paper', mode !== 0);
  if (mode !== 0) {
    app.find.close();
    const options = {
      parent: tab.paperHost, text: tab.editor.getText(), prefs: app.prefs,
      onInput: text => {
        clearTimeout(tab.paperSync);
        tab.paperSync = setTimeout(() => { app.syncFromPaper(tab); app.updateTabs(); }, 150);
        app.scheduleStatus();
      },
      onSelection: () => app.scheduleStatus(),
      furigana: text => api.furigana(text),
    };
    tab.paper = mode === 1 ? new GenkoEditor(Object.assign(options, { horizontal: tab.genkoHorizontal })) : new A4Editor(options);
    if (tab.locked && tab.paper.setReadOnly) tab.paper.setReadOnly(true);
  }
  // 最後に使った表示を覚えておく (次に起動したとき「前回と同じ」で使う)。ファイルにも表示を書いておく
  if (remember) { const last = mode === 1 ? 'genko' : mode === 2 ? 'a4' : 'normal'; app.prefs.lastPaperMode = last; api.setPref('lastPaperMode', last); }
  if (remember && tab.path && !tab.remote && !tab.enc && app.library) app.library.setMode(tab.path, app.modeString(tab));
  if (tab === app.active) {
    app.updateStatus();
    app.pushMenuState();
    requestAnimationFrame(() => { tab.editor.remeasure(); app.updateRuler(); app.focusEditor(); });
  }
};

function printJob(tab) {
  const title = tab.name;
  if (tab.paper) app.syncFromPaper(tab);
  const text = tab.getText();
  if (tab.paperMode === 1) return { html: genkoPrintHTML(title, text, app.prefs, tab.paper ? tab.paper.ruby : [], tab.genkoHorizontal), landscape: !tab.genkoHorizontal, margins: null };
  // 余白はインチ (上下 25 mm・左右 20 mm くらい)
  const margins = { top: 0.98, bottom: 0.98, left: 0.79, right: 0.79 };
  if (tab.paperMode === 2) return { html: a4PrintHTML(title, text, app.prefs, tab.paper ? tab.paper.manual() : {}), landscape: false, margins };
  return { html: plainPrintHTML(title, text, getComputedStyle(document.documentElement).getPropertyValue('--ed-font') || 'monospace'), landscape: false, margins: { top: 0.6, bottom: 0.6, left: 0.6, right: 0.6 } };
}

app.exportPDF = async function (tab, path) {
  tab = tab || app.active;
  if (!path) {
    path = await api.saveDialog({
      title: t('PDF として書き出す'), defaultPath: tab.path ? pathUtil.withExtension(tab.path, 'pdf') : tab.name + '.pdf',
      filters: [{ name: 'PDF', extensions: ['pdf'] }],
    });
    if (!path) return false;
  }
  const r = await api.exportPDF(Object.assign({ path }, printJob(tab)));
  if (r.status !== 'ok') { await alertBox(t('PDF を作れませんでした'), r.message); return false; }
  return true;
};

app.exportWord = async function () {
  const tab = app.active;
  const path = await api.saveDialog({
    title: t('Word (.docx) として書き出す'), defaultPath: tab.path ? pathUtil.withExtension(tab.path, 'docx') : tab.name + '.docx',
    filters: [{ name: 'Word', extensions: ['docx'] }],
  });
  if (!path) return;
  if (tab.paper) app.syncFromPaper(tab);
  const paragraphs = docxParagraphs(tab.getText(), tab.paperMode, app.prefs, tab.paperMode === 2 && tab.paper ? tab.paper.manual() : {});
  const r = await api.exportDocx({ path, paragraphs });
  if (r.status !== 'ok') await alertBox(t('Word のファイルを作れませんでした'), r.message);
  else toast(t('書き出しました: {name}', { name: pathUtil.base(path) }));
};

app.print = async function () {
  const r = await api.print(printJob(app.active));
  if (r.status !== 'ok') await alertBox(t('印刷できませんでした'), r.message);
};

// ---------- 追加機能 ----------

app.toggleFeature = async function (id, on) {
  const f = menuDef.FEATURES.find(x => x.id === id);
  if (!f) return false;
  const want = on === undefined ? !app.prefs[f.pref] : on;
  if (want === !!app.prefs[f.pref]) return true;
  if (want) {
    let agreed = id !== 'ai' && !f.needsAgree;
    const check = h('input', { type: 'checkbox', onchange: e => { agreed = e.target.checked; } });
    const body = h('div', {},
      h('div', { class: 'modal-line dim' }, t(f.summary)),
      ...t(f.confirm).split('\n').map(line => h('div', { class: 'modal-line' }, line)),
      id === 'ai' || f.needsAgree ? h('label', { class: 'check-row top-gap' }, check, t('わかりました')) : null);
    const ok = await modal({
      title: f.confirmTitle ? t(f.confirmTitle) : t('{name} をオンにします', { name: t(f.title) }), body,
      buttons: [{ label: t('オンにする'), value: true, primary: true, validate: () => agreed }, { label: t('やめる'), value: false, cancel: true }],
    });
    if (!ok) return false;
  }
  app.prefs[f.pref] = want;
  api.setPref(f.pref, want);
  if (!want && id === 'encryption') { app.prefs.encryptAlways = false; api.setPref('encryptAlways', false); }
  // オンにしたら、その機能をすぐ画面に出す
  if (want && id === 'ai') { app.prefs.aiVisible = true; api.setPref('aiVisible', true); }
  if (want && id === 'folder') { app.prefs.folderTreeVisible = true; api.setPref('folderTreeVisible', true); }
  if (want && id === 'library') { app.prefs.libraryVisible = true; api.setPref('libraryVisible', true); if (app.library) app.library.reload(); }
  app.applyPrefs();
  if (want && id === 'paper') app.setPaperMode(app.active, 1);
  if (want && id === 'server') openServers(app);
  if (want && id === 'folder' && !app.prefs.folderTreeRoot) app.tree.chooseRoot();
  return true;
};

// ---------- ステータスバー・ルーラー・ツールバー ----------

app.scheduleStatus = function () {
  if (app.statusPending) return;
  app.statusPending = true;
  // 画面が描かれていないあいだ (最小化など) は requestAnimationFrame が止まるので、時間でも動かす
  const run = () => {
    if (!app.statusPending) return;
    app.statusPending = false;
    app.updateStatus();
    app.updateTabs();
  };
  requestAnimationFrame(run);
  setTimeout(run, 120);
};

app.updateStatus = function () {
  const tab = app.active;
  if (!tab) return;
  const notes = [], cells = [];
  if (tab.remote) notes.push(tab.remote.url);
  if (tab.collab && tab.collab.active) notes.push('👥 ' + (tab.collab.role === 'host' ? t('共有中 ({n} 人)', { n: tab.collab.users.size }) : t('参加中 ({n} 人)', { n: tab.collab.users.size })));
  // 暗号化の種類は右側の項目 (押すと変えられる) に出す。流出防止を使っていないときだけ、ここに出す
  if (tab.enc && !app.prefs.encryptionEnabled) notes.push('🔒 ' + t('暗号化') + ` (${tab.enc.label})`);
  if (tab.locked) notes.push('🔒 ' + t('ロック中 (書き換えできません)'));
  if (app.library && app.library.isPlaceholder(tab.path)) notes.push(t('新規テキスト: Ctrl+S で名前を付けて保存'));
  if (tab.paperMode === 1 && tab.paper) {
    const i = tab.paper.info();
    if (i.selected) notes.push(t('選択 {n} 字', { n: i.selected }));
    cells.push({ id: 'chars', title: t('{n} 字', { n: i.chars }), tip: t('文字数 (改行は数えません)') });
    cells.push({ id: 'sheets', title: t('{a} / {b} 枚', { a: i.sheet, b: i.sheets }), tip: t('いまの用紙 / 全部の枚数 (1 枚 400 字)') });
    cells.push({ id: 'cell', title: t('{c} 列 {r} マス', { c: i.column, r: i.row }), tip: t('カーソルの位置') });
  } else if (tab.paperMode === 2 && tab.paper) {
    const i = tab.paper.info();
    if (i.selected) notes.push(t('選択 {n} 字', { n: i.selected }));
    cells.push({ id: 'chars', title: t('{n} 字', { n: i.chars }), tip: t('文字数 (改行は数えません)') });
    cells.push({ id: 'lines', title: t('{n} 段落', { n: i.lines }), tip: '' });
  } else {
    const i = tab.editor.info();
    app.info = i;
    if (i.selected) notes.push(t('選択 {n} 文字', { n: i.selected }));
    const v = i.visual;
    cells.push({ id: 'pos', title: t('{line} 行  {col} 列', { line: v ? v.line : i.line, col: i.displayColumn }), tip: t('クリックで指定行へ移動') + (v ? ' ' + t('(ワープロ的な数え方)') : '') });
    cells.push({ id: 'total', title: t('全 {n} 行', { n: v ? v.lines : i.lines }), tip: v ? t('折り返しも 1 行と数えた行数') : t('文書全体の行数') });
  }
  if (app.prefs.aiEnabled) {
    const ready = isVerified(app, app.prefs.aiProvider || 'openai');
    cells.push({ id: 'ai', title: ready ? '●' : t('AI 未設定'), cls: ready ? 'ok' : '', tip: ready ? t('接続を確認済みです。AI を使えます。') : t('クリックで AI の設定を開く') });
  }
  if (app.prefs.encryptionEnabled) {
    cells.push(tab.enc
      ? { id: 'crypt', title: '🔒 ' + tab.enc.label, tip: t('暗号化しています。クリックで暗号化の方法を変更') }
      : { id: 'crypt', title: '🔓 ' + t('暗号化なし'), tip: t('暗号化していません。クリックで暗号化の方法を選ぶ') });
  }
  if (app.prefs.paperEnabled) {
    cells.push({ id: 'paper', title: t(paperName(tab)), tip: t('用紙 (クリックで 標準エディタ・原稿用紙・A4用紙 を切り替え)') });
  }
  cells.push({ id: 'lang', title: tab.profile ? tab.profile.name : t('テキスト'), tip: t('クリックで言語 (色分け・タブ幅) を変更') });
  cells.push({ id: 'enc', title: menuDef.ENCODINGS.find(e => e[0] === tab.encoding)[1], tip: t('クリックで文字コードを変更') });
  cells.push({ id: 'eol', title: tab.lineEnding.toUpperCase(), tip: t('クリックで改行コードを変更') });
  app.el.statusNotes.textContent = notes.join('      ');
  app.el.statusNotes.title = app.el.statusNotes.textContent;

  // 用紙モードのときだけ、自動整形のチェックを出す
  const fmt = app.el.statusFormat;
  fmt.hidden = tab.paperMode === 0 || (tab.paperMode === 1 && tab.genkoHorizontal);
  if (tab.paperMode !== 0) {
    const key = tab.paperMode === 1 ? 'genkoAutoFormat' : 'a4AutoFormat';
    fmt.lastChild.textContent = tab.paperMode === 1 ? t('原稿用紙の自動整形') : t('A4 の自動整形');
    fmt.title = tab.paperMode === 1 ? t('題名 3 マス下げ・名前 下寄せ・段落 1 マス下げ') : t('題名 中央・名前 右寄せ・段落 1 字下げ');
    fmt.firstChild.checked = !!app.prefs[key];
    fmt.firstChild.onchange = e => { app.setPref(key, e.target.checked); app.focusEditor(); };
  }
  const box = app.el.statusCells;
  const key = cells.map(c => c.id).join(',');
  if (box.dataset.key !== key) {
    box.dataset.key = key;
    box.textContent = '';
    for (const c of cells) box.append(h('button', { class: 'status-cell', 'data-id': c.id, onclick: e => app.statusClicked(c.id, e.currentTarget) }));
  }
  cells.forEach((c, i) => {
    const b = box.children[i];
    if (b.textContent !== c.title) b.textContent = c.title;
    b.title = c.tip;
    b.classList.toggle('ok', c.cls === 'ok');
  });
};

const PAPER_NAMES_JA = ['標準エディタ', '原稿用紙 (縦書き)', 'A4用紙', '原稿用紙 (横書き)'];
const paperName = tab => PAPER_NAMES_JA[tab.paperMode === 1 && tab.genkoHorizontal ? 3 : (tab.paperMode || 0)];

app.statusClicked = function (id, el) {
  const tab = app.active, r = el.getBoundingClientRect();
  const show = items => popupMenu(items, r.left, r.top, { alignBottom: true });
  if (id === 'pos') app.run('goto.line');
  if (id === 'paper') {
    const cur = tab.paperMode === 1 && tab.genkoHorizontal ? 3 : (tab.paperMode || 0);
    // 「切り替えの候補」でチェックしたもの (と、いまの用紙) だけ
    const on = menuDef.paperCandidates(app.prefs);
    show(menuDef.PAPER_CANDIDATES.filter(c => c[2] === cur || on.includes(c[0])).map(c => c[2])
      .map(i => ({ label: t(PAPER_NAMES_JA[i]), checked: cur === i, action: () => app.run('paper.mode:' + i) })));
    return;
  }
  else if (id === 'ai') { if (isVerified(app, app.prefs.aiProvider || 'openai')) app.setPref('aiVisible', !app.prefs.aiVisible); else openAISettings(app); }
  else if (id === 'lang') {
    show([{ label: t('自動 (拡張子で判定)'), checked: !tab.languageOverride, action: () => app.run('doc.language:') }, 'sep',
      ...app.profiles.map(p => ({ label: p.name, checked: tab.languageOverride === p.name, action: () => app.run('doc.language:' + p.name) }))]);
  } else if (id === 'enc') {
    show([...menuDef.ENCODINGS.map(([e, name]) => ({ label: name, checked: tab.encoding === e, action: () => app.run('doc.encoding:' + e) })), 'sep',
      { label: t('文字コードを指定して開き直す') + '…', disabled: !tab.path, action: () => {
        popupMenu(menuDef.ENCODINGS.map(([e, name]) => ({ label: name, action: () => app.run('doc.reopen:' + e) })), r.left, r.top, { alignBottom: true });
      } }]);
  } else if (id === 'crypt') {
    const locked = !!(tab.collab && tab.collab.active);
    const current = tab.enc ? tab.enc.kind : null;
    show([
      { label: tab.enc ? t('暗号化の方法を変える') : t('暗号化の方法を選ぶ'), disabled: true },
      ...CRYPTO_KINDS.map(k => ({ label: t(SHORT_KIND[k.id]), checked: k.id === current, disabled: locked, action: () => app.reencrypt(tab, { initialKind: k.id }) })),
      'sep',
      // 鍵の変更 (方法はそのままで、パスワードや鍵だけを新しくする) は別の枠
      { label: t('鍵の変更…'), disabled: !tab.enc || locked, action: () => app.run('crypto.changeKey') },
      { label: t('暗号化を解除…'), disabled: !tab.enc || locked, action: () => app.run('crypto.decrypt') },
      'sep',
      { label: t('この文書の暗号化の設定…'), action: () => app.run('crypto.settings') },
    ]);
  } else if (id === 'eol') {
    show(menuDef.LINE_ENDINGS.map(([e, name]) => ({ label: name, checked: tab.lineEnding === e, action: () => app.run('doc.lineEnding:' + e) })));
  }
};

app.scheduleRuler = function () {
  if (app.rulerPending) return;
  app.rulerPending = true;
  requestAnimationFrame(() => { app.rulerPending = false; app.updateRuler(); });
};

app.updateRuler = function () {
  const tab = app.active;
  const hidden = !app.prefs.columnRuler || !tab || tab.paperMode !== 0;
  app.el.ruler.hidden = hidden;
  if (hidden) return;
  const css = getComputedStyle(document.documentElement);
  drawRuler(app.el.ruler, tab.editor.view, {
    background: css.getPropertyValue('--c-gutterBackground').trim(), text: css.getPropertyValue('--c-gutterText').trim(),
    separator: css.getPropertyValue('--c-gutterSeparator').trim(),
  });
};

const TOOLBAR = [
  ['new', '新規作成', 'file.new', '新規作成 (Ctrl+N)'], ['library', 'テキスト一覧', 'library.toggle', 'テキスト一覧を出す / しまう', 'library'], ['libraryGrid', 'サムネ一覧', 'library.grid', 'テキストをサムネ (カード) で見渡す', 'library'], ['folder', 'フォルダ', 'folder.toggle', 'フォルダツリーを出す / しまう', 'folder'], '-',
  ['open', '開く', 'file.open', 'ファイルを開く'], ['server', 'サーバ', 'server.open', 'サーバ (SFTP / FTP) につないでファイルを開く', 'server'], ['save', '保存', 'file.save', '上書き保存'], '-',
  ['undo', '元に戻す', 'edit.undo', '元に戻す'], ['redo', 'やり直し', 'edit.redo', 'やり直し'], '-',
  ['cut', '切り取り', 'edit.cut', '切り取り'], ['copy', 'コピー', 'edit.copy', 'コピー'], ['paste', '貼り付け', 'edit.paste', '貼り付け'], ['duplicate', '行複製', 'line.duplicate', '行を複製'], '-',
  ['find', '検索', 'find.show', '検索'], ['replace', '置換', 'find.replace', '置換'], ['grep', 'grep', 'grep.show', 'ファイルから検索'], ['goto', '行移動', 'goto.line', '指定行へ移動'], ['diff', '差分', 'view.diff', '差分: 編集前とどこが変わったかを横に表示 (Ctrl+Shift+D)'], '-',
  ['split', '分割', 'view.split', '上下に分割 / 分割をやめる'], ['splitSide', '左右分割', 'view.splitSide', '左右に分割 / 分割をやめる'], ['share', '共有', 'collab.host', 'この文書を共有して共同編集する', 'collab'], ['paper', '用紙切替', 'paper.cycle', '用紙切替: 標準エディタ → 原稿用紙 → A4用紙', 'paper'], ['publish', '公開', 'share.publish', 'リンクで公開共有 (docs.satoru.net)', 'share'], ['ai', 'AI', 'ai.toggle', 'AI アシスタント', 'ai'],
  'space', ['camera', 'スクショ', 'file.screenshot', 'スクリーンショット (画像にする)'], ['theme', '色・フォント', 'settings.open:theme', '色・フォント'],
];
const FEATURE_PREF = { folder: 'folderTreeEnabled', paper: 'paperEnabled', ai: 'aiEnabled', server: 'serverEnabled', collab: 'collabEnabled', share: 'shareEnabled', library: 'libraryEnabled' };
app.TOOLBAR = TOOLBAR;

/// ツールバーに並べるもの (設定で選んだ並びがあればそれ)
function toolbarLayout() {
  const custom = app.prefs.toolbarItems;
  if (!Array.isArray(custom)) return TOOLBAR;
  const byName = new Map(TOOLBAR.filter(b => Array.isArray(b)).map(b => [b[0], b]));
  return custom.map(name => (name === '-' || name === 'space' ? name : byName.get(name))).filter(Boolean);
}

app.renderToolbar = function () {
  const bar = app.el.toolbar;
  const key = i18n.language() + JSON.stringify([app.prefs.folderTreeEnabled, app.prefs.paperEnabled, app.prefs.aiEnabled, app.prefs.serverEnabled, app.prefs.collabEnabled, app.prefs.shareEnabled, app.prefs.libraryEnabled, app.prefs.toolbarItems]);
  if (bar.dataset.key === key) return;
  bar.dataset.key = key;
  bar.textContent = '';
  const accelFor = id => { for (const [a, x] of app.accel) if (x === id) return ` (${a})`; return ''; };
  for (const b of toolbarLayout()) {
    if (b === '-') { bar.append(h('span', { class: 'tb-sep' })); continue; }
    if (b === 'space') { bar.append(h('span', { class: 'tb-space' })); continue; }
    const [name, label, command, tip, feature] = b;
    if (feature && !app.prefs[FEATURE_PREF[feature]]) continue;
    const btn = h('button', {
      class: 'tb-button', 'aria-label': t(label),
      onmousedown: e => e.preventDefault(), // 押しても文章の選択を外さない
      onmouseenter: e => { e.currentTarget.title = t(tip) + accelFor(command); },
      onclick: () => app.run(command),
    }, icon(name));
    bar.append(btn);
  }
};

// ---------- メニューの動作 ----------

app.goToLine = function (line) {
  const tab = app.active;
  if (tab.paperMode !== 0) return;
  tab.editor.goToLine(line);
};

function needNormal() {
  if (app.active.paperMode === 0) return true;
  toast(t('用紙モードでは使えません (用紙 > 標準エディタ に戻してください)'));
  return false;
}
const ed = fn => () => { if (needNormal()) fn(app.active.editor); };

/// 画面を分ける。side が true なら左右、false なら上下。分けているときに違う向きを選んだら、向きだけ変える
function toggleSplit(side) {
  if (!needNormal()) return;
  const tab = app.active;
  const isSide = tab.el.classList.contains('split-side');
  if (tab.editor.secondary && isSide !== side) {
    tab.el.classList.toggle('split-side', side);
  } else if (tab.editor.secondary) {
    tab.editor.unsplit(); tab.el.classList.remove('split', 'split-side');
  } else {
    tab.el.classList.add('split'); tab.el.classList.toggle('split-side', side); tab.editor.split(tab.secondary);
  }
  tab.editor.remeasure();
  app.pushMenuState();
  app.focusEditor();
}

const commands = {
  'file.new': () => app.newTab(),
  'file.open': () => app.openDialog(),
  'file.openRecent': f => app.openPath(f),
  'file.clearRecent': () => { app.prefs.recent = []; api.clearRecent(); app.pushMenuState(); },
  'file.close': () => app.closeTab(app.active),
  'file.save': () => app.save(app.active),
  'file.saveAs': () => app.save(app.active, { saveAs: true }),
  // 元のファイルの名前を変える (名前のない文書・サーバの文書は「名前を付けて保存」と同じ)
  'file.rename': () => {
    const tab = app.active;
    if (!tab) return;
    if (!tab.path || tab.remote || !app.library) return app.save(tab, { saveAs: true });
    return app.library.askRename(tab.path);
  },
  'file.revert': () => app.revert(),
  'file.versions': () => { if (app.prefs.versionHistory !== false && app.prefs.libraryEnabled !== false) app.versions.showCurrent(); },
  'library.toggle': () => app.setPref('libraryVisible', app.prefs.libraryVisible === false),
  'library.new': () => app.library.createBlank(),
  'library.grid': () => app.library.showGrid(),
  'share.publish': () => app.share.publishCurrent(),
  'share.update': async () => { const tab = app.active; if (tab && tab.path) await app.share.updateFile(tab.path); },
  'share.settings': () => { const r = app.active && app.share.recordFor(app.active.path); if (r) app.share.editSettings(r); },
  'share.open': () => { const r = app.active && app.share.recordFor(app.active.path); if (r) api.openExternal(r.url); },
  'share.copy': () => { const r = app.active && app.share.recordFor(app.active.path); if (r) { api.copyText(r.url); toast(t('リンクをコピーしました')); } },
  'share.unpublish': () => { const r = app.active && app.share.recordFor(app.active.path); if (r) app.share.confirmUnpublish(r); },
  'share.list': () => app.share.showList(),
  'share.togglePrivacy': () => app.setPref('sharePrivacyCheckOff', !app.prefs.sharePrivacyCheckOff),
  'file.print': () => app.print(),
  'file.exportPDF': async () => { if (await app.exportPDF()) toast(t('PDF を書き出しました')); },
  'file.exportWord': () => app.exportWord(),
  'file.screenshot': () => screenshotDialog(app),
  'file.importPDF': async () => {
    const files = await api.openDialog({ single: true, title: t('PDF からテキストを読み込む'), filters: [{ name: 'PDF', extensions: ['pdf'] }] });
    if (!files[0]) return;
    toast(t('PDF を読んでいます…'));
    const r = await api.importPDF(files[0]);
    if (r.status !== 'ok') { await alertBox(t('PDF を読み込めませんでした'), r.message); return; }
    if (!r.text.trim()) { await alertBox(t('文字が見つかりませんでした'), t('スキャンした画像だけの PDF からは、文字を取り出せません。')); return; }
    const tab = app.newTab({ text: r.text });
    tab.metaDirty = true;
    app.updateTabs();
    toast(t('{n} ページから読み込みました', { n: r.pages }));
  },
  'app.quit': () => api.quit(),
  'app.about': () => api.about(),
  'app.checkUpdate': () => checkForUpdates(app, { manual: true }),
  'app.language': async lang => {
    app.prefs.language = lang;
    await api.setPref('language', lang);
    const next = i18n.resolve(lang, navigator.language);
    if (next === i18n.language()) return;
    // 画面を作り直す。保存していない文書があるときは、次に起動したときから切り替える
    if (app.tabs.some(x => x.isDirty())) { toast(next === 'en' ? 'The language will change the next time you start Satoru Editor.' : '次に起動したときから日本語になります。'); return; }
    try { sessionStorage.setItem('reopen', JSON.stringify(app.tabs.filter(x => x.path).map(x => x.path))); } catch (e) { /* なくてもよい */ }
    location.reload();
  },

  'edit.undo': () => app.active.target().undo(),
  'edit.redo': () => app.active.target().redo(),
  'edit.cut': () => api.editCommand('cut'),
  'edit.copy': () => api.editCommand('copy'),
  'edit.paste': () => api.editCommand('paste'),
  'edit.selectAll': () => app.active.target().selectAll(),
  'line.duplicate': ed(e => e.duplicateLine()),
  'line.delete': ed(e => e.deleteLine()),
  'line.moveUp': ed(e => e.moveLineUp()),
  'line.moveDown': ed(e => e.moveLineDown()),
  'line.indent': ed(e => e.indent()),
  'line.outdent': ed(e => e.outdent()),
  'line.toggleComment': ed(e => e.toggleComment()),
  'line.sort': ed(e => e.transformLines(lines => lines.slice().sort((a, b) => a.localeCompare(b, 'ja')))),
  'line.unique': ed(e => e.transformLines(lines => { const seen = new Set(); return lines.filter(l => (seen.has(l) ? false : (seen.add(l), true))); })),
  'line.trim': ed(e => e.transformLines(lines => lines.map(l => l.replace(/[ \t　]+$/, '')))),
  'convert.upper': ed(e => e.transformSelection(s => s.toUpperCase())),
  'convert.lower': ed(e => e.transformSelection(s => s.toLowerCase())),
  'convert.capitalize': ed(e => e.transformSelection(s => s.replace(/\b([a-zA-Z])([a-zA-Z]*)/g, (m, a, b) => a.toUpperCase() + b.toLowerCase()))),
  'convert.fullWidth': ed(e => e.transformSelection(s => genko.toFullWidth(s))),

  'find.show': () => { if (needNormal()) app.find.show(false); },
  'find.replace': () => { if (needNormal()) app.find.show(true); },
  'find.next': () => { if (needNormal()) app.find.next(false); },
  'find.previous': () => { if (needNormal()) app.find.next(true); },
  'find.useSelection': () => { if (needNormal()) app.find.useSelection(); },
  'grep.show': () => app.find.grepDialog(),
  'goto.line': async () => {
    if (!needNormal()) return;
    const i = app.active.editor.info();
    const vis = i.visual;
    const v = await promptBox(t('指定行へ移動'), t('行番号 (1 〜 {n})', { n: vis ? vis.lines : i.lines }) + (vis ? '  ' + t('(ワープロ的な数え方)') : ''), String(vis ? vis.line : i.line));
    const n = parseInt(v, 10);
    if (v !== null && n > 0) app.active.editor.goToLine(n, 1, !!vis);
  },
  'goto.bracket': ed(e => e.jumpToBracket()),

  'view.wrap': () => app.setPref('wrap', !app.prefs.wrap),
  'view.invisibles': () => app.setPref('invisibles', !app.prefs.invisibles),
  'view.lineNumbers': () => app.setPref('lineNumbers', !app.prefs.lineNumbers),
  'view.columnRuler': () => app.setPref('columnRuler', !app.prefs.columnRuler),
  'view.toolbar': () => app.setPref('toolbar', !app.prefs.toolbar),
  'view.lineCounting': mode => app.setPref('lineCounting', mode === 'visual' ? 'visual' : 'logical'),
  'view.split': () => toggleSplit(false),
  'view.splitSide': () => toggleSplit(true),
  'view.switchPane': () => {
    const e = app.active.editor;
    if (!e.secondary) return;
    (e.active === e.view ? e.secondary : e.view).focus();
  },
  'view.zoomIn': () => { app.theme.fontSize = Math.min(72, app.theme.fontSize + 1); app.saveTheme(); },
  'view.zoomOut': () => { app.theme.fontSize = Math.max(6, app.theme.fontSize - 1); app.saveTheme(); },
  'tab.next': () => app.activate(app.tabs[(app.tabs.indexOf(app.active) + 1) % app.tabs.length]),
  'tab.previous': () => app.activate(app.tabs[(app.tabs.indexOf(app.active) + app.tabs.length - 1) % app.tabs.length]),

  'folder.open': () => app.tree.chooseRoot(),
  'folder.toggle': () => app.setPref('folderTreeVisible', !app.prefs.folderTreeVisible),

  'ai.toggle': () => app.setPref('aiVisible', !app.prefs.aiVisible),
  'ai.action': id => { if (!app.prefs.aiVisible) app.setPref('aiVisible', true); app.ai.runAction(id); },
  'ai.settings': () => openAISettings(app),
  'ai.usage': () => openAIUsage(app),

  'ai.localLLM': () => openLocalLLM(app),
  'plugin.run': ref => app.plugins.run(ref),
  'plugin.manage': () => app.run('settings.open:features'),
  'view.diff': () => app.setPref('diffVisible', !app.prefs.diffVisible),
  'paper.mode': m => app.setPaperMode(app.active, parseInt(m, 10) || 0),
  // ツールバーの用紙切替: 「切り替えの候補」でチェックしたものを順に (Mac 版と同じ)
  'paper.cycle': () => {
    const tab = app.active, all = menuDef.PAPER_CANDIDATES, on = menuDef.paperCandidates(app.prefs);
    const cur = menuDef.paperCandidateOf(tab.paperMode, tab.genkoHorizontal);
    const at = all.findIndex(c => c[0] === cur);
    for (let k = 1; k <= all.length; k++) {
      const c = all[(at + k) % all.length];
      if (on.includes(c[0])) { if (c[0] !== cur) app.setPaperMode(tab, c[2]); return; }
    }
  },
  'paper.toggle': key => app.setPref(key, !app.prefs[key]),
  'paper.align': value => {
    const tab = app.active;
    if (tab.paperMode !== 2 || !tab.paper) { toast(t('A4 用紙のときに使えます')); return; }
    tab.paper.setAlign(value);
  },

  'collab.host': () => startHosting(app),
  'collab.join': () => joinShare(app),
  'collab.toggleChat': () => app.setPref('collabChatVisible', !app.prefs.collabChatVisible),
  'collab.stop': () => { if (app.collab) app.collab.stop(); },
  'server.open': () => openServers(app),
  'server.settings': () => openServers(app),
  'server.tree': () => { app.remoteTree.dismissed = false; app.setPref('remoteTreeVisible', !app.prefs.remoteTreeVisible); },
  'server.toggleAuto': () => app.setPref('remoteAutoUpload', !app.prefs.remoteAutoUpload),

  'crypto.encrypt': () => app.reencrypt(app.active, {}),
  'crypto.changeMethod': () => app.reencrypt(app.active, { initialKind: app.active.enc && app.active.enc.kind }),
  'crypto.changeKey': () => { const tab = app.active; if (tab.enc) app.reencrypt(tab, { onlyKind: tab.enc.kind }); },
  'crypto.settings': () => encryptionSettings(app),
  'crypto.decrypt': async () => {
    const tab = app.active;
    if (!tab.enc) return;
    if (!(await confirmBox(t('暗号化を解除しますか？'), t('次に保存すると、だれでも読める普通のファイルになります。'), t('解除する')))) return;
    tab.enc = null;
    tab.plainChoice = true;
    tab.metaDirty = true;
    app.updateTabs(); app.updateStatus(); app.pushMenuState();
  },
  'crypto.toggleAlways': () => app.setPref('encryptAlways', !app.prefs.encryptAlways),

  'feature.toggle': id => app.toggleFeature(id),
  'settings.open': pane => openSettings(app, pane),
  // 各機能のメニューの「…の設定…」: 設定の「追加機能」を開いて、その機能の説明と設定を広げる
  'settings.feature': id => openSettings(app, 'features', { expand: id }),
  'settings.reset': () => app.resetAllSettings(),
  'settings.export': async () => { if (await api.exportSettings()) toast(t('設定を保存しました')); },
  'settings.import': async () => {
    const r = await api.importSettings();
    if (r.status === 'error') await alertBox(t('復元できませんでした'), r.message);
    else if (r.status === 'ok') { await alertBox(t('設定を復元しました'), t('画面を読み込み直します。')); location.reload(); }
  },

  'doc.encoding': e => { const tab = app.active; if (tab.encoding !== e) { tab.encoding = e; tab.metaDirty = true; } app.updateTabs(); app.updateStatus(); app.pushMenuState(); },
  'doc.reopen': e => app.reopenWithEncoding(e),
  'doc.lineEnding': e => { const tab = app.active; if (tab.lineEnding !== e) { tab.lineEnding = e; tab.metaDirty = true; } app.updateTabs(); app.updateStatus(); app.pushMenuState(); },
  'doc.language': name => {
    const tab = app.active;
    tab.languageOverride = name || '';
    app.resolveProfile(tab);
    tab.editor.configure(app.prefs, tab.profile);
    app.updateStatus(); app.pushMenuState();
  },
  'theme.preset': name => { app.theme.preset = name; app.theme.overrides = {}; app.saveTheme(); },
};

/// "paper.mode:1" のような命令を実行する
app.run = function (id) {
  if (!id) return;
  const i = id.indexOf(':');
  const name = i < 0 ? id : id.slice(0, i);
  const arg = i < 0 ? undefined : id.slice(i + 1);
  const fn = commands[name];
  if (!fn) return;
  try {
    const r = fn(arg);
    if (r && r.catch) r.catch(e => { console.error(e); alertBox(t('エラー'), String((e && e.message) || e)); });
  } catch (e) {
    console.error(e);
    alertBox(t('エラー'), String((e && e.message) || e));
  }
};

// 文字を打つ欄の中では、編集のキー (元に戻す・行の操作など) をその欄に任せる
const EDITOR_ONLY = /^(edit\.|line\.|convert\.|view\.switchPane|goto\.bracket|paper\.align)/;

function onKeyDown(e) {
  if (e.isComposing || e.keyCode === 229) return;
  const accel = menuDef.acceleratorOf(e);
  if (!accel) return;
  const id = app.accel.get(accel);
  if (!id) return;
  if (isModalOpen()) return;
  const el = e.target;
  const tab = app.active;
  const inEditor = tab && (tab.el.contains(el));
  const typing = el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement || el.isContentEditable;
  if (typing && !inEditor && EDITOR_ONLY.test(id)) return;
  e.preventDefault();
  e.stopPropagation();
  app.run(id);
}

// ---------- 起動 ----------

async function start() {
  const init = await api.init();
  i18n.setLanguage(init.language || i18n.resolve(init.prefs.language, navigator.language));
  document.documentElement.lang = i18n.language();
  app.prefs = init.prefs;
  app.theme = init.theme;
  app.userProfiles = init.userProfiles || [];
  app.profiles = profilesDef.merge(app.userProfiles);
  app.init = init;

  const $ = id => document.getElementById(id);
  app.el = {
    toolbar: $('toolbar'), tabs: $('tabs'), editors: $('editors'), ruler: $('ruler'),
    statusNotes: $('status-notes'), statusCells: $('status-cells'), statusFormat: $('status-format'),
    treePane: $('tree-pane'), treeResizer: $('tree-resizer'), aiPane: $('ai-pane'), diffPane: $('diff-pane'), remotePane: $('remote-pane'), remoteResizer: $('remote-resizer'), chatPane: $('chat-pane'), grepPane: $('grep-pane'),
  };
  $('tab-add').title = t('新規作成');
  $('tab-add').addEventListener('click', () => app.newTab());
  app.el.tabs.addEventListener('dblclick', e => { if (e.target === app.el.tabs) app.newTab(); });

  app.find = new FindController(app);
  app.tree = new FolderTree(app);
  app.ai = new AIPanel(app);
  app.collabPanel = new CollabPanel(app);
  app.diff = new DiffPanel(app);
  app.plugins = new PluginManager(app);
  app.remoteTree = new RemoteTree(app);
  app.share = new ShareLink(app);
  app.versions = new VersionHistory(app);
  app.library = new TextLibrary(app);

  window.addEventListener('keydown', onKeyDown, true);
  window.addEventListener('resize', app.scheduleRuler);
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => app.applyTheme());
  // ファイルをウインドウに落としたら開く
  window.addEventListener('dragover', e => { if (e.dataTransfer && Array.from(e.dataTransfer.types).includes('Files')) e.preventDefault(); });
  window.addEventListener('drop', e => {
    if (!e.dataTransfer || !e.dataTransfer.files.length) return;
    e.preventDefault();
    (async () => {
      for (const f of Array.from(e.dataTransfer.files)) {
        const p = api.pathForFile(f);
        if (p) await app.openPath(p);
      }
      app.focusEditor(); // 開いたファイルにすぐ書けるように
    })();
  });

  api.on('command', id => app.run(id));
  api.on('open-grep', root => app.find.grepDialog(root));
  api.on('collab:open', (id, address) => { if (app.collab) app.collab.opened(id, address); });
  api.on('collab:message', (id, msg) => { if (app.collab) app.collab.message(id, msg); });
  api.on('collab:close', (id, info) => { if (app.collab) app.collab.closed(id, info); });
  api.on('open-files', files => { (async () => { for (const f of files) await app.openPath(f); })(); });
  /// 閉じてよいか (保存していない文書を 1 つずつ確かめる)。キャンセルなら false。アップデートで閉じるときにも使う
  app.confirmClose = async () => {
    for (const tab of app.tabs.slice()) {
      if (!tab.isDirty()) { app.rememberCaret(tab); if (tab.path) await api.versionFlush(tab.path); continue; }
      app.activate(tab);
      const answer = await modal({
        title: t('「{name}」の変更を保存しますか？', { name: tab.name }), body: t('保存しないと、変更は失われます。'),
        buttons: [{ label: t('保存する'), value: 'save', primary: true }, { label: t('保存しない'), value: 'discard' }, { label: t('キャンセル'), value: 'cancel', cancel: true }],
      });
      if (answer === 'cancel' || answer === undefined) return false;
      if (answer === 'save' && !(await app.save(tab))) return false;
    }
    return true;
  };
  api.on('app:request-close', async () => {
    if (await app.confirmClose()) api.closeWindow();
  });
  app.checkForUpdates = opts => checkForUpdates(app, opts); // 自己点検用

  app.newTab();
  app.applyPrefs();
  app.version = init.version;
  // 起動したときの白紙の表示 (設定「起動したときの表示」。はじめは標準エディタ。「前回と同じ」は最後に使っていた表示)
  if (app.prefs.paperEnabled) {
    let mode = app.prefs.startPaperMode || 'normal';
    if (mode === 'last') mode = app.prefs.lastPaperMode || 'normal';
    if (mode === 'genko') app.setPaperMode(app.active, app.prefs.genkoHorizontal ? 3 : 1, { remember: false });
    else if (mode === 'a4') app.setPaperMode(app.active, 2, { remember: false });
  }
  await app.library.init();
  // JS の拡張機能を読み込む (~/.satoruEditor/plugins)
  app.plugins.loadAll();
  if (init.themeProblems && init.themeProblems.length) toast(t('theme.json に問題があります (その項目は既定値を使います)'));

  let reopen = [];
  try { reopen = JSON.parse(sessionStorage.getItem('reopen') || '[]'); sessionStorage.removeItem('reopen'); } catch (e) { reopen = []; }
  for (const f of reopen.concat(init.files || [])) await app.openPath(f);
  if (app.prefs.folderTreeEnabled && app.prefs.folderTreeRoot) app.tree.setRoot(app.prefs.folderTreeRoot);
  if (init.grepRoot) app.find.grepDialog(init.grepRoot);
  document.body.classList.add('ready');
  scheduleAutoCheck(app); // 新しい版が出ていないか (設定「アップデートを自動で確認」。1 日に 1 回まで)
}

start().catch(e => {
  console.error(e);
  document.body.append(h('pre', { style: { padding: '16px', color: '#c00' } }, String((e && e.stack) || e)));
});

export default app;
