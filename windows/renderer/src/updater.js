// アップデート: GitHub Releases に新しい版が出ていれば知らせ、インストーラーを取ってきて入れ替える。
// 確かめる・取ってくる・起動するのは本体 (host/src/Updater.cs)。ここは知らせる画面と、閉じる前の確かめ
import { h, modal, alertBox, toast } from './dialogs';
import i18n from '../../shared/i18n';

const { t } = i18n;
const AUTO_DELAY = 5000;

/// 起動して少したってから、裏で確かめる (1 日に 1 回まで。うまくいかなくても何も出さない)
export function scheduleAutoCheck(app) {
  setTimeout(() => { checkForUpdates(app, { manual: false }).catch(() => {}); }, AUTO_DELAY);
}

/// manual: メニューから選んだとき (最新なら「最新の版です」、うまくいかなければ理由を出す。「この版はとばす」にした版も知らせる)
export async function checkForUpdates(app, { manual = false } = {}) {
  const api = window.api;
  if (!api.updateCheck) return null;
  if (manual) toast(t('アップデートを確認しています…'));
  let r;
  try { r = await api.updateCheck({ auto: !manual }); } catch (e) { r = { status: 'error', message: String((e && e.message) || e) }; }
  if (!r) return null;
  if (r.status === 'update') { r.answer = await offer(app, r); return r; }
  if (!manual) return r;
  if (r.status === 'latest') {
    await alertBox(t('アップデートを確認'), t('最新の版です') + '\n' + t('エディタβ') + ' ' + (r.current || app.version || ''));
  } else if (r.status === 'noasset') {
    await alertBox(t('アップデートを確認'), t('エディタβ {version} の Windows 用のファイルが、まだ用意されていません。しばらくしてから、もう一度お試しください。', { version: r.version }));
  } else if (r.status === 'error') {
    await alertBox(t('アップデートを確認できませんでした'), t('インターネットにつながっているかを確かめて、もう一度お試しください。') + '\n\n' + (r.message || ''));
  }
  return r;
}

/// 「新しい版があります」→ 'now' | 'later' | 'skip'
async function offer(app, r) {
  const api = window.api;
  const body = h('div', {},
    h('div', { class: 'modal-line' }, t('エディタβ {version} が出ています (いまは {current})。ダウンロードして入れ替えますか？', { version: r.version, current: r.current })),
    r.notes ? h('div', { class: 'modal-line', style: { marginTop: '8px' } },
      h('a', { href: '#', class: 'update-notes', onclick: e => { e.preventDefault(); api.openExternal(r.notes); } }, t('この版で変わったこと (リリースノート) を見る'))) : null);
  const answer = await modal({
    title: t('新しい版があります'), body, width: 480, className: 'update-dialog',
    buttons: [
      { label: t('今すぐアップデート'), value: 'now', primary: true },
      { label: t('あとで'), value: 'later', cancel: true },
      { label: t('この版はとばす'), value: 'skip' },
    ],
  });
  if (answer === 'skip') {
    app.setPref('updateSkipVersion', r.version);
    toast(t('{version} は知らせません。次の版が出たら知らせます。', { version: r.version }));
    return 'skip';
  }
  if (answer !== 'now') return 'later';
  await update(app, r);
  return 'now';
}

const mb = n => (n / 1048576).toFixed(1);

/// 取ってきて、保存していない文書を確かめてから、インストーラーを起動して閉じる
async function update(app, r) {
  const api = window.api;
  const bar = h('progress', { max: '1', value: '0', style: { width: '100%' } });
  const label = h('div', { class: 'modal-line' }, t('ダウンロードしています…'));
  let dialog = null;
  const off = api.on('update:progress', (got, total) => {
    if (total > 0) { bar.max = total; bar.value = got; label.textContent = t('ダウンロードしています… {done} / {total} MB', { done: mb(got), total: mb(total) }); }
  });
  const waiting = modal({
    title: t('アップデート'), body: h('div', {}, label, bar), width: 420, className: 'update-progress',
    buttons: [{ label: t('キャンセル'), value: 'cancel', cancel: true }], onOpen: d => { dialog = d; },
  });
  const done = api.updateDownload(r.asset).then(x => ({ result: x }), e => ({ result: { status: 'error', message: String((e && e.message) || e) } }));
  const first = await Promise.race([done, waiting.then(v => ({ closed: v }))]);
  off();
  if (first.closed !== undefined) { api.updateCancel(); return false; }
  if (dialog) dialog.close('done');
  const d = first.result;
  if (d.status === 'cancel') return false;
  if (d.status !== 'ok') { await alertBox(t('ダウンロードできませんでした'), d.message || ''); return false; }
  // ふつうに閉じるときと同じく、保存していない文書を確かめる (キャンセルならアップデートもやめる)
  if (!(await app.confirmClose())) { toast(t('アップデートをやめました。もう一度「アップデートを確認…」から始められます。')); return false; }
  const res = await api.updateInstall(d.path);
  if (!res || res.status !== 'ok') { await alertBox(t('アップデートを始められませんでした'), (res && res.message) || ''); return false; }
  return true;
}
