'use strict';
// ポータブル版 (zip を広げて、その場ですぐ動く) を作る: node scripts/package-portable.js
//   先に node scripts/package-host.js で build/satoruEditor-lite/satoruEditor を作っておく (なければここで作る)
//   → build/SatoruEditor-<版>-win-x64-portable.zip
// 中身はインストール版と同じ。exe の横に portable.txt があると、設定・テキスト・記録をすべて exe の横の data フォルダに置く
// (host/src/Program.cs の Portable)。アップデートは setup.exe を /portable=<場所> で起動して、その場で入れ替える
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const root = path.join(__dirname, '..');
const pkg = require('../package.json');
const build = path.join(root, 'build');
const run = (cmd, args, opts) => execFileSync(cmd, args, Object.assign({ stdio: 'inherit' }, opts || {}));

const lite = path.join(build, 'satoruEditor-lite', 'satoruEditor');
if (!fs.existsSync(path.join(lite, 'satoruEditor.exe')) || process.argv.includes('--rebuild')) run('node', [path.join(__dirname, 'package-host.js')]);

const stage = path.join(build, 'portable');
const out = path.join(stage, 'SatoruEditor');
fs.rmSync(stage, { recursive: true, force: true });
fs.mkdirSync(stage, { recursive: true });
run('cp', ['-R', lite, out]);
fs.rmSync(path.join(out, 'README.txt'), { force: true });

fs.writeFileSync(path.join(out, 'portable.txt'), [
  'このファイルがあると、さとるエディタはポータブル版として動きます。',
  '設定・テキスト・版の履歴は、すべてこのフォルダの中の data フォルダに入ります (この PC には残しません)。',
  'このファイルは消さないでください。',
  '',
  'While this file exists, Satoru Editor runs as a portable app.',
  'Settings, texts and version history are all kept in the "data" folder here (nothing is left on this PC).',
  'Please do not delete this file.', '',
].join('\r\n'));
fs.mkdirSync(path.join(out, 'data'), { recursive: true });
fs.writeFileSync(path.join(out, 'README.txt'), [
  'さとるエディタ ' + pkg.version + ' (ポータブル版)', '',
  'satoruEditor.exe をダブルクリックすると、インストールしないで、すぐ使えます。',
  'フォルダごと好きな場所 (USB メモリなど) に置いてください。書いたテキストや設定は data フォルダに入ります。',
  'ほかのパソコンで続きを書くときは、このフォルダごと持っていってください。', '',
  'Double-click satoruEditor.exe to use it right away, without installing.',
  'Put the whole folder anywhere you like (a USB stick, for example). Your texts and settings go into the "data" folder.',
  'To continue on another PC, take the whole folder with you.', '',
  '動かすには Windows 10 / 11 に最初から入っている .NET Framework 4.8 と Microsoft Edge WebView2 ランタイムを使います。',
  'It uses .NET Framework 4.8 and the Microsoft Edge WebView2 Runtime, which come with Windows 10 / 11.', '',
  '初回は Windows の「PC が保護されました」が出ることがあります。「詳細情報」→「実行」で起動できます。',
  'Windows may show "Windows protected your PC" the first time. Choose "More info" > "Run anyway".', '',
  'パスワードなど秘密の設定は、この PC のログインに結び付けて守っているため、別の PC では入れ直しになります。',
  'Passwords and other secrets are tied to this PC\'s sign-in, so you will need to enter them again on another PC.', '',
].join('\r\n'));

const zipOut = path.join(build, `SatoruEditor-${pkg.version}-win-x64-portable.zip`);
fs.rmSync(zipOut, { force: true });
run('zip', ['-q', '-r', '-X', '-9', zipOut, 'SatoruEditor'], { cwd: stage });
console.log('ポータブル版:', zipOut, (fs.statSync(zipOut).size / 1048576).toFixed(2) + ' MB');
