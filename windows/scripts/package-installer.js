'use strict';
// Windows のインストーラーを作る: node scripts/package-installer.js
//   先に node scripts/package-host.js で build/satoruEditor-<版>-win-x64-lite.zip を作っておく (なければここで作る)
//   → build/satoruEditor-<版>-win-x64-setup.exe (中に zip を抱えた 1 つの exe)
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const root = path.join(__dirname, '..');
const pkg = require('../package.json');
const build = path.join(root, 'build');
const dotnet = process.env.DOTNET || path.join(os.homedir(), '.dotnet', 'dotnet');
const run = (cmd, args, opts) => execFileSync(cmd, args, Object.assign({ stdio: 'inherit' }, opts || {}));

const zip = path.join(build, `satoruEditor-${pkg.version}-win-x64-lite.zip`);
if (!fs.existsSync(zip) || process.argv.includes('--rebuild')) run('node', [path.join(__dirname, 'package-host.js')]);

const inst = path.join(root, 'installer');
fs.copyFileSync(zip, path.join(inst, 'payload.zip'));
const ico = path.join(build, 'host-obj', 'satoruEditor.ico');   // package-host.js が作ったアイコン
const bin = path.join(build, 'installer-bin');
fs.rmSync(bin, { recursive: true, force: true });
try {
  run(dotnet, ['build', path.join(inst, 'satoruEditorSetup.csproj'), '-c', 'Release', '-o', bin, '-nologo', '-v', 'q',
    `-p:ApplicationIcon=${ico}`, `-p:Version=${pkg.version}`]);
} finally {
  fs.rmSync(path.join(inst, 'payload.zip'), { force: true });   // 大きなファイルは置きっぱなしにしない
  fs.rmSync(path.join(inst, 'obj'), { recursive: true, force: true });
}
const out = path.join(build, `satoruEditor-${pkg.version}-win-x64-setup.exe`);
fs.copyFileSync(path.join(bin, 'satoruEditorSetup.exe'), out);
console.log('インストーラー:', out, (fs.statSync(out).size / 1048576).toFixed(2) + ' MB');
