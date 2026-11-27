'use strict';
// Windows の関連付けと、エクスプローラーの右クリックメニュー。
// どれも「いまのユーザー」の設定 (HKEY_CURRENT_USER) だけを書き換えるので、管理者の権限は要らず、外せば元に戻る。
// 「既定のアプリ」そのものは Windows が守っていてアプリからは変えられないので、「プログラムから開く」の一覧に載せるところまでを行う
const { execFile } = require('child_process');

const CLASSES = 'HKCU\\Software\\Classes';
// レジストリの中の名前は画面に出ない。前の版で登録したものを消せるよう、そのままにしておく
const PROG_ID = 'satoEdit.Document';
const DEFAULT_EXTENSIONS = ['txt', 'log', 'md', 'ini', 'csv', 'json', 'xml', 'html', 'htm', 'css', 'js', 'ts', 'py', 'c', 'cpp', 'h', 'cs', 'java', 'php', 'rb', 'go', 'rs', 'sql', 'bat', 'ps1', 'yml', 'yaml', 'sh'];

function reg(args) {
  return new Promise(resolve => {
    execFile('reg.exe', args, { windowsHide: true }, (error, stdout) => resolve({ ok: !error, out: String(stdout || '') }));
  });
}

const add = (key, name, value) => reg(['add', key].concat(name === null ? ['/ve'] : ['/v', name], ['/t', 'REG_SZ', '/d', value, '/f']));
const remove = key => reg(['delete', key, '/f']);
const exists = async key => (await reg(['query', key])).ok;

function cleanExtensions(list) {
  return Array.from(new Set((list || []).map(e => String(e).trim().toLowerCase().replace(/^\*?\./, '')).filter(e => /^[a-z0-9_+-]{1,16}$/.test(e))));
}

async function status() {
  if (process.platform !== 'win32') return { supported: false, fileMenu: false, folderMenu: false, extensions: [], defaults: DEFAULT_EXTENSIONS };
  const extensions = [];
  const q = await reg(['query', `${CLASSES}\\${PROG_ID}`, '/v', 'Extensions']);
  const m = /Extensions\s+REG_SZ\s+(.*)/.exec(q.out);
  if (q.ok && m) extensions.push(...cleanExtensions(m[1].split(/\s+/)));
  return {
    supported: true, defaults: DEFAULT_EXTENSIONS, extensions,
    fileMenu: await exists(`${CLASSES}\\*\\shell\\satoEdit`),
    folderMenu: await exists(`${CLASSES}\\Directory\\shell\\satoEditGrep`),
  };
}

/// o: { exe (satoEdit.exe の場所), extensions: [拡張子], fileMenu: bool, folderMenu: bool, labels: { open, grep } }
async function apply(o) {
  if (process.platform !== 'win32') return { ok: false, message: 'Windows only' };
  const exe = o.exe;
  const failures = [];
  const must = async (p, what) => { if (!(await p).ok) failures.push(what); };

  // 「プログラムから開く」の一覧
  const before = (await status()).extensions;
  const extensions = cleanExtensions(o.extensions);
  for (const e of before.filter(x => !extensions.includes(x))) {
    await reg(['delete', `${CLASSES}\\.${e}\\OpenWithProgids`, '/v', PROG_ID, '/f']);
  }
  if (extensions.length) {
    await must(add(`${CLASSES}\\${PROG_ID}`, null, 'エディタβ'), 'ProgID');
    await must(add(`${CLASSES}\\${PROG_ID}`, 'Extensions', extensions.join(' ')), 'ProgID');
    await must(add(`${CLASSES}\\${PROG_ID}\\DefaultIcon`, null, `"${exe}",0`), 'icon');
    await must(add(`${CLASSES}\\${PROG_ID}\\shell\\open\\command`, null, `"${exe}" "%1"`), 'command');
    for (const e of extensions) {
      await must(reg(['add', `${CLASSES}\\.${e}\\OpenWithProgids`, '/v', PROG_ID, '/t', 'REG_NONE', '/f']), '.' + e);
    }
  } else {
    await remove(`${CLASSES}\\${PROG_ID}`);
  }

  // ファイルの右クリック「エディタβで開く」
  if (o.fileMenu) {
    await must(add(`${CLASSES}\\*\\shell\\satoEdit`, null, o.labels.open), 'file menu');
    await must(add(`${CLASSES}\\*\\shell\\satoEdit`, 'Icon', `"${exe}",0`), 'file menu');
    await must(add(`${CLASSES}\\*\\shell\\satoEdit\\command`, null, `"${exe}" "%1"`), 'file menu');
  } else {
    await remove(`${CLASSES}\\*\\shell\\satoEdit`);
  }

  // フォルダの右クリック「エディタβで grep」
  if (o.folderMenu) {
    await must(add(`${CLASSES}\\Directory\\shell\\satoEditGrep`, null, o.labels.grep), 'folder menu');
    await must(add(`${CLASSES}\\Directory\\shell\\satoEditGrep`, 'Icon', `"${exe}",0`), 'folder menu');
    await must(add(`${CLASSES}\\Directory\\shell\\satoEditGrep\\command`, null, `"${exe}" "--grep=%1"`), 'folder menu');
  } else {
    await remove(`${CLASSES}\\Directory\\shell\\satoEditGrep`);
  }
  return { ok: failures.length === 0, message: failures.join(', ') };
}

module.exports = { DEFAULT_EXTENSIONS, cleanExtensions, status, apply };
