'use strict';
// Windows 用の配布物を作る: node scripts/package-win.js
//   build/satoruEditor-win32-x64/satoruEditor.exe  と  build/satoruEditor-<版>-win-x64.zip
// Electron (Windows x64) を公式の配布元から取ってきて、ハッシュを確かめてからアプリを組み込む。Mac の上でも作れる。
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('child_process');

const ELECTRON_VERSION = process.env.ELECTRON_VERSION || '33.4.11';
const root = path.join(__dirname, '..');
const pkg = require('../package.json');
const tools = path.join(root, '.tools');
const build = path.join(root, 'build');
const out = path.join(build, 'satoruEditor-win32-x64');
const run = (cmd, args, opts) => execFileSync(cmd, args, Object.assign({ stdio: 'inherit' }, opts || {}));

function download() {
  fs.mkdirSync(tools, { recursive: true });
  const name = `electron-v${ELECTRON_VERSION}-win32-x64.zip`;
  const zip = path.join(tools, name);
  const sums = path.join(tools, `SHASUMS256-${ELECTRON_VERSION}.txt`);
  const base = `https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/`;
  if (!fs.existsSync(sums)) run('curl', ['-fsSL', '-o', sums, base + 'SHASUMS256.txt']);
  if (!fs.existsSync(zip)) run('curl', ['-fsSL', '-o', zip, base + name]);
  const line = fs.readFileSync(sums, 'utf8').split('\n').find(l => l.trim().endsWith('*' + name));
  const actual = crypto.createHash('sha256').update(fs.readFileSync(zip)).digest('hex');
  if (!line || line.split(/\s+/)[0] !== actual) {
    fs.unlinkSync(zip);
    throw new Error('Electron の配布物のハッシュが合いません。もう一度実行してください。');
  }
  return zip;
}

/// PNG (大きいもの 1 枚) → .ico (16〜256 の 6 種類。中身は PNG のまま入れる)
function makeIco(png, workDir) {
  const sizes = [16, 24, 32, 48, 64, 256];
  const images = sizes.map(s => {
    const f = path.join(workDir, `icon-${s}.png`);
    run('sips', ['-z', String(s), String(s), png, '--out', f], { stdio: 'ignore' });
    return fs.readFileSync(f);
  });
  const header = Buffer.alloc(6);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(sizes.length, 4);
  const entries = [];
  let offset = 6 + 16 * sizes.length;
  sizes.forEach((s, i) => {
    const e = Buffer.alloc(16);
    e[0] = s === 256 ? 0 : s;
    e[1] = s === 256 ? 0 : s;
    e.writeUInt16LE(1, 4);
    e.writeUInt16LE(32, 6);
    e.writeUInt32LE(images[i].length, 8);
    e.writeUInt32LE(offset, 12);
    offset += images[i].length;
    entries.push(e);
  });
  return Buffer.concat([header, ...entries, ...images]);
}

function brandExe(exePath, ico) {
  const ResEdit = require('resedit');
  const exe = ResEdit.NtExecutable.from(fs.readFileSync(exePath), { ignoreCert: true });
  const res = ResEdit.NtExecutableResource.from(exe);
  const iconFile = ResEdit.Data.IconFile.from(ico);
  const group = ResEdit.Resource.IconGroupEntry.fromEntries(res.entries)[0];
  ResEdit.Resource.IconGroupEntry.replaceIconsForResource(res.entries, group ? group.id : 1, group ? group.lang : 1033, iconFile.icons.map(i => i.data));
  const vi = ResEdit.Resource.VersionInfo.fromEntries(res.entries)[0];
  if (vi) {
    const [major, minor, patch] = pkg.version.split('.').map(Number);
    vi.setFileVersion(major, minor, patch, 0, 1033);
    vi.setProductVersion(major, minor, patch, 0, 1033);
    for (const lang of vi.getAllLanguagesForStringValues()) {
      vi.setStringValues(lang, {
        ProductName: 'さとるエディタ', FileDescription: 'さとるエディタ', CompanyName: 'satorunet', InternalName: 'satoruEditor',
        OriginalFilename: 'satoruEditor.exe', LegalCopyright: 'MIT License', FileVersion: pkg.version, ProductVersion: pkg.version,
      });
    }
    vi.outputToResourceEntries(res.entries);
  }
  res.outputResource(exe);
  fs.writeFileSync(exePath, Buffer.from(exe.generate()));
}

function copyDir(from, to, filter) {
  fs.mkdirSync(to, { recursive: true });
  for (const e of fs.readdirSync(from, { withFileTypes: true })) {
    const a = path.join(from, e.name), b = path.join(to, e.name);
    if (filter && !filter(a, e)) continue;
    if (e.isDirectory()) copyDir(a, b, filter); else fs.copyFileSync(a, b);
  }
}

function main() {
  const zip = download();
  run('node', [path.join(root, 'scripts', 'build.js'), '--minify']);
  fs.rmSync(out, { recursive: true, force: true });
  fs.mkdirSync(out, { recursive: true });
  run('unzip', ['-q', zip, '-d', out]);
  fs.renameSync(path.join(out, 'electron.exe'), path.join(out, 'satoruEditor.exe'));
  const defaultApp = path.join(out, 'resources', 'default_app.asar');
  if (fs.existsSync(defaultApp)) fs.unlinkSync(defaultApp);

  // アプリ本体
  const appDir = path.join(out, 'resources', 'app');
  fs.mkdirSync(appDir, { recursive: true });
  for (const f of ['main.js', 'preload.js']) fs.copyFileSync(path.join(root, f), path.join(appDir, f));
  for (const d of ['core', 'shared', 'assets']) copyDir(path.join(root, d), path.join(appDir, d));
  copyDir(path.join(root, 'renderer'), path.join(appDir, 'renderer'), (p, e) => !(e.isDirectory() && e.name === 'src'));
  // 実行に要る部品だけを入れる (画面側の部品は dist/app.js にまとめてある)
  const runtimeDeps = { 'iconv-lite': pkg.dependencies['iconv-lite'], kuromoji: pkg.dependencies.kuromoji, 'pdfjs-dist': pkg.dependencies['pdfjs-dist'], ssh2: pkg.dependencies.ssh2, 'basic-ftp': pkg.dependencies['basic-ftp'] };
  fs.writeFileSync(path.join(appDir, 'package.json'), JSON.stringify({
    name: pkg.name, productName: pkg.productName, version: pkg.version, description: pkg.description, main: pkg.main, license: pkg.license, dependencies: runtimeDeps,
  }, null, 2));
  run('npm', ['install', '--production', '--no-audit', '--no-fund', '--no-package-lock', '--ignore-scripts'], { cwd: appDir, stdio: 'ignore' });

  // PDF の読み込みに使わない部分は入れない (ブラウザ用の画面部品など)
  const pdfjs = path.join(appDir, 'node_modules', 'pdfjs-dist');
  for (const d of ['web', 'types', 'image_decoders', 'build', path.join('legacy', 'web'), path.join('legacy', 'image_decoders')]) fs.rmSync(path.join(pdfjs, d), { recursive: true, force: true });
  for (const f of fs.readdirSync(path.join(pdfjs, 'legacy', 'build'))) {
    if (f !== 'pdf.js' && f !== 'pdf.worker.js') fs.rmSync(path.join(pdfjs, 'legacy', 'build', f), { force: true });
  }
  fs.rmSync(path.join(appDir, 'node_modules', 'canvas'), { recursive: true, force: true });

  // アイコンと名前
  const work = fs.mkdtempSync(path.join(build, 'ico-'));
  const ico = makeIco(path.join(root, 'assets', 'icons', 'ai.png'), work);
  fs.writeFileSync(path.join(appDir, 'assets', 'satoruEditor.ico'), ico);
  brandExe(path.join(out, 'satoruEditor.exe'), ico);
  fs.rmSync(work, { recursive: true, force: true });

  fs.writeFileSync(path.join(out, 'README.txt'), [
    'さとるエディタ ' + pkg.version, '',
    'satoruEditor.exe をダブルクリックして起動します。フォルダごと好きな場所に置いてください。',
    'Double-click satoruEditor.exe to start. Keep the whole folder together.', '',
    '初回は Windows の「PC が保護されました」が出ることがあります。「詳細情報」→「実行」で起動できます。',
    'Windows may show "Windows protected your PC" the first time. Choose "More info" > "Run anyway".', '',
  ].join('\r\n'));

  const zipOut = path.join(build, `satoruEditor-${pkg.version}-win-x64.zip`);
  fs.rmSync(zipOut, { force: true });
  run('zip', ['-q', '-r', '-X', zipOut, path.basename(out)], { cwd: build });
  console.log('できました:', out);
  console.log('配布用:', zipOut, (fs.statSync(zipOut).size / 1048576).toFixed(1) + ' MB');
}

main();
