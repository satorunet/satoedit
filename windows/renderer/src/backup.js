// 設定 > バックアップ (Mac 版 LibraryBackupUI.swift と同じ): テキスト一覧を、パスワードで鍵をかけた 1 つのファイル (.satorubackup) に書き出す・戻す。
// 中身は Mac 版と同じ形なので、Windows で作ったものを Mac で、Mac で作ったものを Windows で戻せる。版の記録 (履歴) の設定もここ
import { h, modal, alertBox, confirmBox, toast } from './dialogs';
import { pathUtil } from './util';
import i18n from '../../shared/i18n';

const { t } = i18n;
const MAX_CHOICES = [10, 20, 50, 100, 200, 500, 1000];

function box(title, ...children) {
  return h('fieldset', { class: 'settings-box' }, h('legend', {}, title), ...children);
}

/// 新しいパスワード (2 回) と、入れるもの。やめたら null
async function askNewPassword() {
  const p1 = h('input', { type: 'password', class: 'wide', placeholder: t('パスワード (8 文字以上)'), autofocus: true });
  const p2 = h('input', { type: 'password', class: 'wide', placeholder: t('もう一度') });
  const links = h('input', { type: 'checkbox', checked: true });
  const history = h('input', { type: 'checkbox', checked: true });
  const ok = await modal({
    title: t('テキストをバックアップ'), width: 480,
    body: h('div', {}, h('div', { class: 'modal-line' }, t('テキスト一覧のファイルを、パスワードで鍵をかけた 1 つのファイルに書き出します。読み込むと、別の PC や Mac にも戻せます。')),
      h('div', { class: 'form-row top-gap' }, p1), h('div', { class: 'form-row' }, p2),
      h('label', { class: 'check-row' }, links, t('公開したリンクの記録も入れる (更新・公開をやめるための合言葉も)')),
      h('label', { class: 'check-row' }, history, t('版の履歴も入れる'))),
    buttons: [{ label: t('書き出す…'), value: true, primary: true, validate: async () => {
      if (Array.from(p1.value).length < 8) { await alertBox(t('パスワードは 8 文字以上にしてください'), ''); return false; }
      if (p1.value !== p2.value) { await alertBox(t('2 つのパスワードが違います'), ''); return false; }
      return true;
    } }, { label: t('キャンセル'), value: false, cancel: true }],
  });
  return ok ? { password: p1.value, withLinks: links.checked, withHistory: history.checked } : null;
}

export async function exportBackup(app, preset) {
  const api = app.api;
  const ask = preset || await askNewPassword();
  if (!ask) return null;
  const d = new Date(), p = n => String(n).padStart(2, '0');
  const name = t('さとるエディタのバックアップ') + `-${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}.satorubackup`;
  const out = ask.path || await api.saveDialog({ title: t('テキストをバックアップ'), defaultPath: name, filters: [{ name: t('さとるエディタのバックアップ'), extensions: ['satorubackup'] }] });
  if (!out) return null;
  // 書きかけは先に保存しておく (ファイルの中身を入れるため)。待っている版の記録も済ませる
  for (const tab of app.tabs) if (tab.path && tab.isDirty() && !tab.remote) await app.save(tab, { auto: !preset });
  await api.versionFlush('');
  if (!preset) toast(t('バックアップを作っています…'));
  const lib = app.library;
  const other = lib ? lib.items.filter(it => it.group === null || it.group === undefined).map(it => it.path) : [];
  const r = await api.backupExport({
    path: out, password: ask.password, withHistory: ask.withHistory, pinned: app.prefs.libraryPinned || [],
    folderIcons: app.prefs.libraryFolderIcons || {}, folderOrder: app.prefs.libraryFolderOrder || [],
    sharedLinks: ask.withLinks ? JSON.stringify(app.prefs.sharedLinks || []) : null, other,
  });
  if (preset) return r;
  if (r.status !== 'ok') { await alertBox(t('バックアップを書き出せませんでした'), r.message); return r; }
  const size = r.size < 1048576 ? (r.size / 1024).toFixed(1) + ' KB' : (r.size / 1048576).toFixed(1) + ' MB';
  const show = await modal({
    title: t('バックアップを書き出しました'),
    body: t('{n} 件のテキストを、パスワードで鍵をかけて保存しました ({size})。', { n: r.count, size }) + '\n' + out + '\n\n' + t('パスワードを忘れると、このバックアップは開けません。'),
    buttons: [{ label: t('閉じる'), value: false, primary: true, cancel: true }, { label: t('エクスプローラーで表示'), value: true }],
  });
  if (show) api.reveal(out);
  return r;
}

/// バックアップから戻す。preset = { path, password } (自己点検用。聞かずに戻す)
export async function importBackup(app, preset) {
  const api = app.api;
  let file = preset && preset.path;
  if (!file) {
    const files = await api.openDialog({ single: true, title: t('読み込むバックアップ (.satorubackup) を選んでください'), filters: [{ name: t('さとるエディタのバックアップ'), extensions: ['satorubackup'] }] });
    file = files && files[0];
  }
  if (!file) return null;
  let opened = null;
  while (!opened) {
    let pw = preset && preset.password;
    if (!pw) {
      const f = h('input', { type: 'password', class: 'wide', autofocus: true });
      const ok = await modal({ title: t('バックアップのパスワード'), body: h('div', {}, h('div', { class: 'modal-line' }, pathUtil.base(file)), f),
        buttons: [{ label: t('開く'), value: true, primary: true }, { label: t('キャンセル'), value: false, cancel: true }] });
      if (!ok) return null;
      pw = f.value;
    }
    const r = await api.backupOpen({ path: file, password: pw });
    if (r.status === 'ok') { opened = r; break; }
    if (preset) return r;
    if (r.status === 'notBackup') { await alertBox(t('読み込めませんでした'), t('さとるエディタのバックアップではありません')); return null; }
    if (r.status === 'newer') { await alertBox(t('読み込めませんでした'), t('新しい版のさとるエディタで作ったバックアップです。アプリを新しくしてください')); return null; }
    if (r.status === 'error') { await alertBox(t('読み込めませんでした'), r.message); return null; }
    if (!(await confirmBox(t('パスワードが違います'), '', t('もう一度')))) return null;
  }
  if (!preset) {
    const when = new Date(opened.createdAt).toLocaleString(i18n.language() === 'en' ? 'en-US' : 'ja-JP');
    const ok = await confirmBox(t('バックアップから戻しますか？'),
      t('{when} に作ったバックアップ: テキスト {n} 件・フォルダ {f} 個', { when, n: opened.entries, f: opened.folders }) + '\n\n'
      + t('さとるエディタのフォルダに戻します。今あるファイルは消しません。同じ名前で中身が違うものは「(バックアップ)」を付けて別に置きます。'), t('戻す'));
    if (!ok) return null;
  }
  const r = await api.backupRestore(opened.token, t('ほかの場所から戻したもの'), t('(バックアップ)'), t('(バックアップ {n})'));
  if (r.status !== 'ok') { if (!preset) await alertBox(t('読み込めませんでした'), r.message); return r; }
  // ピン・フォルダのアイコン (決めていないものだけ)・並び (ないものを後ろに)・公開したリンクの記録 (同じものは足さない)
  const pins = (app.prefs.libraryPinned || []).slice();
  for (const p of r.pinned || []) if (!pins.some(x => pathUtil.same(x, p))) pins.push(p);
  app.setPref('libraryPinned', pins);
  const icons = Object.assign({}, r.folderIcons || {}, app.prefs.libraryFolderIcons || {});
  app.setPref('libraryFolderIcons', icons);
  const order = (app.prefs.libraryFolderOrder || []).slice();
  app.setPref('libraryFolderOrder', order.concat((r.folderOrder || []).filter(x => !order.includes(x))));
  if (r.sharedLinks) {
    let list = [];
    try { list = JSON.parse(r.sharedLinks); } catch (e) { list = []; }
    const have = new Set((app.prefs.sharedLinks || []).map(x => x.id));
    // Mac の場所 (/Users/…/書類/さとるエディタ/…) は、こちらのさとるエディタのフォルダに付け替える
    const root = app.library ? app.library.root : '';
    const fixed = (Array.isArray(list) ? list : []).filter(x => x && x.id && !have.has(x.id)).map(x => {
      const m = x.path ? /[\\/]さとるエディタ[\\/](.+)$/.exec(x.path) : null;
      return m && root ? Object.assign({}, x, { path: root.replace(/\\+$/, '') + '\\' + m[1].replace(/\//g, '\\') }) : x;
    });
    app.setPref('sharedLinks', (app.prefs.sharedLinks || []).concat(fixed));
  }
  if (app.library) await app.library.reload();
  app.pushMenuState();
  if (!preset) {
    await alertBox(t('バックアップから戻しました'), t('新しく戻したもの {a} 件 ・ 同じだったので飛ばしたもの {s} 件 ・ 名前を変えて戻したもの {r} 件', { a: r.added, s: r.skipped, r: r.renamed })
      + (r.failed > 0 ? '\n' + t('戻せなかったもの {n} 件', { n: r.failed }) : ''));
  }
  return r;
}

/// 設定 > バックアップ
export function backupPane(app) {
  const pane = h('div', {});
  const render = () => {
    const max = Number(app.prefs.versionHistoryMax) || 20;
    const maxSel = h('select', {
      onchange: async e => {
        const n = Number(e.target.value);
        if (n < max && !(await confirmBox(t('残す版を {n} 個までにしますか？', { n }), t('今ある履歴も、テキストごとに新しい {n} 個だけ残して、それより古い版は消します。元に戻せません。', { n }), t('減らす')))) { render(); return; }
        app.setPref('versionHistoryMax', n);
        await app.api.versionPruneAll(n);
        render();
      },
    }, MAX_CHOICES.map(n => h('option', { value: String(n), selected: n === max }, t('{n} 個まで', { n }))));
    pane.textContent = '';
    pane.append(
      box(t('テキストのバックアップ'),
        h('div', { class: 'modal-line' }, t('テキストを、パスワード付きの 1 つのファイルにまとめて保存します。別の PC や Mac にも戻せます。')),
        h('div', { class: 'form-row' },
          h('button', { onclick: () => exportBackup(app) }, t('テキストをバックアップ (書き出す)…')),
          h('button', { onclick: () => importBackup(app) }, t('バックアップから戻す (読み込む)…'))),
        h('div', { class: 'dim' }, t('テキスト・フォルダ・版の履歴などが、まるごと入ります。')),
        h('div', { class: 'dim' }, t('戻しても、今あるファイルは消えません。パスワードを忘れると開けないので注意。'))),
      box(t('版の履歴'),
        h('label', { class: 'check-row' }, h('input', { type: 'checkbox', checked: app.prefs.versionHistory !== false, onchange: e => app.setPref('versionHistory', e.target.checked) }),
          t('保存のたびに、テキストごとの版を残す')),
        h('div', { class: 'dim' }, t('保存するたびに版を残します。テキスト一覧の右クリックから、前の版を見たり戻したりできます。')),
        h('div', { class: 'form-row' }, h('label', {}, t('テキストごとに残す版の数')), maxSel, h('span', { class: 'dim' }, t('(それより古い版は消えます)'))),
        h('div', { class: 'form-row' }, h('button', { onclick: () => app.api.versionReveal() }, t('記録の場所をエクスプローラーで開く')))));
  };
  render();
  return pane;
}
