// 流出防止 (暗号化) のダイアログ: 暗号化のしかたを選ぶ、開くときに鍵を聞く
import QRCode from 'qrcode';
import { h, modal } from './dialogs';
import i18n from '../../shared/i18n';

const { t } = i18n;

// 暗号化の方法 (Mac 版と同じ 6 通り)
export const KINDS = [
  { id: 'password', label: 'パスワード (8 文字以上)', note: 'どの PC・Mac でも開けます。長いほど安全。' },
  { id: 'passcode', label: 'パスコード (数字 6 桁以上)', note: '覚えやすいけど、パスワードより弱め。' },
  { id: 'device', label: 'この PC のロック (Windows のログイン)', note: '覚えなくて OK。この PC の、このユーザーでしか開けません。' },
  { id: 'totp', label: 'ワンタイム認証 (スマホの認証アプリ)', note: '開くたびにスマホの 6 桁を入れます。この PC でしか開けません。' },
  { id: 'twoStep', label: '二段階 (パスワード + ワンタイム認証)', note: 'パスワードとスマホの 6 桁の両方が要ります。この PC でしか開けません。' },
  { id: 'keyfile', label: '鍵ファイル (USB メモリなど)', note: '鍵ファイルのある USB を挿しているときだけ開けます。別の PC・Mac でも開けます。' },
];

/// 暗号化のしかたを選んで鍵を用意する。やめたら null、決まったら { token, kind, label }
/// initialKind: 最初に選んでおく方法。onlyKind: 方法は選ばせず、その方法の鍵だけを作り直す (鍵の変更)
export async function chooseKey(app, fileName, { initialKind, onlyKind } = {}) {
  const api = app.api;
  let kind = onlyKind || initialKind || (KINDS.some(k => k.id === app.prefs.encDefaultKind) ? app.prefs.encDefaultKind : 'device');
  if (!app.init.secretsAvailable && ['device', 'totp', 'twoStep'].includes(kind) && !onlyKind) kind = 'password';
  let enroll = null, keyFile = '', result = null;
  const fields = h('div', { class: 'crypto-fields' });
  const error = h('div', { class: 'find-status warn', role: 'alert' });
  const pw1 = h('input', { type: 'password', class: 'wide', autocomplete: 'new-password' });
  const pw2 = h('input', { type: 'password', class: 'wide', autocomplete: 'new-password' });
  const code = h('input', { type: 'text', class: 'code-input', inputmode: 'numeric', maxlength: '7', placeholder: '000000', autocomplete: 'off' });
  const qr = h('div', { class: 'qr-box' });
  const keyFileLabel = h('div', { class: 'dim keyfile-path' });

  const passwordRows = (word) => [
    h('div', { class: 'form-row' }, h('label', {}, word), pw1),
    h('div', { class: 'form-row' }, h('label', {}, t('もう一度')), pw2),
    h('div', { class: 'dim' }, t('どこにも保存されません。忘れると、だれにも開けなくなります。')),
  ];
  const enrollRows = () => [
    h('div', { class: 'enroll' }, qr, h('div', {},
      h('div', {}, t('1. スマホの認証アプリ (Google Authenticator など) で、この QR コードを読み取ります。')),
      h('div', { class: 'dim setup-key' }, t('読み取れないときの設定キー: ') + (enroll ? enroll.base32.replace(/(.{4})/g, '$1 ').trim() : '')),
      h('div', { class: 'top-gap' }, t('2. アプリに出た 6 桁を入れます。')), code,
      h('div', { class: 'dim top-gap' }, t('スマホをなくしたときのために、設定キーを控えておいてください。')))),
  ];
  const render = async () => {
    error.textContent = '';
    fields.textContent = '';
    if ((kind === 'totp' || kind === 'twoStep') && !enroll) {
      enroll = await api.totpBegin(fileName);
      try { qr.innerHTML = await QRCode.toString(enroll.uri, { type: 'svg', margin: 1, width: 150 }); } catch (e) { qr.textContent = enroll.uri; }
    }
    if (kind === 'password') fields.append(...passwordRows(t('パスワード')));
    else if (kind === 'passcode') fields.append(...passwordRows(t('パスコード')));
    else if (kind === 'device') fields.append(h('div', {}, t('鍵は Windows のログインに結び付けて、この PC に保存します。開くときは何も聞きません。')),
      h('div', { class: 'dim' }, t('別の PC や、Windows を入れ直したあとでは開けません。大事な文書は、別の方法の控えも残してください。')));
    else if (kind === 'totp') fields.append(...enrollRows());
    else if (kind === 'twoStep') fields.append(...passwordRows(t('パスワード')), ...enrollRows());
    else if (kind === 'keyfile') {
      keyFileLabel.textContent = keyFile || t('まだ選んでいません');
      fields.append(
        h('div', {}, t('鍵ファイルを USB メモリなどに置くと、それを挿しているときだけ開けます。')),
        h('div', { class: 'dim' }, t('なくすと開けなくなるので、控え (コピー) を別の場所にも置いてください。')),
        h('div', { class: 'form-row top-gap' },
          h('button', { onclick: async () => { const f = await api.newKeyFile(); if (f) { keyFile = f; keyFileLabel.textContent = f; } } }, t('新しい鍵ファイルを作る…')),
          h('button', { onclick: async () => {
            const f = await api.openDialog({ single: true, title: t('鍵ファイルを選ぶ'), filters: [{ name: t('鍵ファイル'), extensions: ['satorukey'] }, { name: t('すべてのファイル'), extensions: ['*'] }] });
            if (f[0]) { keyFile = f[0]; keyFileLabel.textContent = f[0]; }
          } }, t('すでにある鍵ファイルを選ぶ…'))),
        keyFileLabel);
    }
    const first = fields.querySelector('input');
    if (first) first.focus();
  };

  const radios = h('div', { class: 'kind-list', role: 'radiogroup' }, KINDS.map(k => {
    const disabled = !app.init.secretsAvailable && ['device', 'totp', 'twoStep'].includes(k.id);
    return h('label', { class: 'kind-row' + (disabled ? ' disabled' : '') },
      h('input', { type: 'radio', name: 'enc-kind', value: k.id, checked: k.id === kind, disabled, onchange: () => { kind = k.id; pw1.value = ''; pw2.value = ''; render(); } }),
      h('span', {}, h('span', { class: 'kind-label' }, t(k.label)), h('span', { class: 'dim kind-note' }, t(k.note))));
  }));

  const validate = async () => {
    error.textContent = '';
    const needsPassword = kind === 'password' || kind === 'passcode' || kind === 'twoStep';
    if (needsPassword) {
      if (kind === 'passcode' ? !/^[0-9]{6,}$/.test(pw1.value) : pw1.value.length < 8) {
        error.textContent = kind === 'passcode' ? t('パスコードは数字 6 桁以上にしてください。') : t('パスワードは 8 文字以上にしてください。');
        return false;
      }
      if (pw1.value !== pw2.value) { error.textContent = t('2 つの欄が同じではありません。'); return false; }
    }
    if (kind === 'keyfile' && !keyFile) { error.textContent = t('鍵ファイルを作るか、選んでください。'); return false; }
    error.textContent = t('鍵を作っています…');
    error.classList.remove('warn');
    const r = await api.makeKey({ kind, password: pw1.value, code: code.value, enrollId: enroll ? enroll.enrollId : null, keyFile });
    error.classList.add('warn');
    if (r.status !== 'ok') { error.textContent = r.message; return false; }
    result = r.enc;
    app.prefs.encDefaultKind = kind;
    return true;
  };

  const SHORT = { password: 'パスワード', passcode: 'パスコード', device: 'この PC のロック', totp: 'ワンタイム認証', twoStep: '二段階', keyfile: '鍵ファイル' };
  const kindLabel = SHORT[kind] || SHORT.password;
  const ok = await modal({
    title: onlyKind ? t('鍵の変更 ({kind})', { kind: t(kindLabel) }) : t('暗号化のしかた'), width: 560, className: 'crypto-modal',
    body: h('div', {}, h('div', { class: 'dim' }, onlyKind ? t('方法はそのままで、新しい鍵で「{name}」を暗号化し直します。', { name: fileName }) : t('「{name}」を暗号化して保存します (AES-256)。開けるのは鍵を持つ人だけです。', { name: fileName })), onlyKind ? null : radios, fields, error),
    buttons: [{ label: t('暗号化して保存'), value: true, primary: true, validate }, { label: t('キャンセル'), value: false, cancel: true }],
    onOpen: () => { render(); },
  });
  return ok ? result : null;
}

/// 暗号化ファイルを開くときに、足りないものを聞く。やめたら null、入れたら { password?, code?, keyFile? }
export async function askUnlock(app, need, fileName, message) {
  const error = h('div', { class: 'find-status warn', role: 'alert' }, message || '');
  const pw = h('input', { type: 'password', class: 'wide', autocomplete: 'off', autofocus: true });
  const code = h('input', { type: 'text', class: 'code-input', inputmode: 'numeric', maxlength: '7', placeholder: '000000', autocomplete: 'off' });
  const buttons = (validate) => [{ label: t('開く'), value: true, primary: true, validate }, { label: t('キャンセル'), value: false, cancel: true }];
  const head = h('div', { class: 'dim' }, fileName);
  if (need === 'password' || need === 'passcode') {
    const word = need === 'passcode' ? t('パスコード') : t('パスワード');
    const ok = await modal({
      title: '🔒 ' + t('{word}を入れてください', { word }), body: h('div', {}, head, h('div', { class: 'form-row top-gap' }, h('label', {}, word), pw), error),
      buttons: buttons(() => pw.value.length > 0),
    });
    return ok ? { password: pw.value } : null;
  }
  if (need === 'totp') {
    const ok = await modal({
      title: '🔒 ' + t('ワンタイム認証: スマホの認証アプリの 6 桁を入れてください'), body: h('div', {}, head, h('div', { class: 'form-row top-gap' }, h('label', {}, t('6 桁のコード')), code), error),
      buttons: buttons(() => code.value.trim().length > 0),
    });
    return ok ? { code: code.value } : null;
  }
  if (need === 'twoStep') {
    const ok = await modal({
      title: '🔒 ' + t('パスワードと、スマホの認証アプリの 6 桁を入れてください'),
      body: h('div', {}, head, h('div', { class: 'form-row top-gap' }, h('label', {}, t('パスワード')), pw), h('div', { class: 'form-row' }, h('label', {}, t('6 桁のコード')), code), error),
      buttons: buttons(() => pw.value.length > 0 && code.value.trim().length > 0),
    });
    return ok ? { password: pw.value, code: code.value } : null;
  }
  if (need === 'keyfile') {
    const ok = await modal({
      title: '🔒 ' + t('鍵ファイルが必要です'),
      body: h('div', {}, head, h('div', { class: 'top-gap' }, t('鍵ファイルの入った USB メモリなどを挿してから「探し直す」を押すか、鍵ファイルを選んでください。')), error),
      buttons: [{ label: t('鍵ファイルを選ぶ…'), value: 'choose', primary: true }, { label: t('探し直す'), value: 'retry' }, { label: t('キャンセル'), value: false, cancel: true }],
    });
    if (ok === 'retry') return {};
    if (ok !== 'choose') return null;
    const f = await app.api.openDialog({ single: true, title: t('鍵ファイルを選ぶ'), filters: [{ name: t('鍵ファイル'), extensions: ['satorukey'] }, { name: t('すべてのファイル'), extensions: ['*'] }] });
    return f[0] ? { keyFile: f[0] } : null;
  }
  return null;
}
