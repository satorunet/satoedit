'use strict';
// 軽量版 (C# + WebView2) の配布物を作る: node scripts/package-host.js
//   build/satoruEditor-lite/satoruEditor/satoruEditor.exe  と  build/satoruEditor-<版>-win-x64-lite.zip
// 本体は windows/host/ (.NET Framework 4.8。Windows に最初から入っている)。この Mac の .NET SDK (~/.dotnet/dotnet) で作れる。
// 画面 (renderer) は Electron 版と同じものを、ここで別にまとめ直して入れる (renderer/dist は書き換えない)
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const root = path.join(__dirname, '..');
const pkg = require('../package.json');
const build = path.join(root, 'build');
const bin = path.join(build, 'host-bin');
const stage = path.join(build, 'satoruEditor-lite');
const out = path.join(stage, 'satoruEditor');
const app = path.join(out, 'app');
const dotnet = process.env.DOTNET || path.join(os.homedir(), '.dotnet', 'dotnet');
const run = (cmd, args, opts) => execFileSync(cmd, args, Object.assign({ stdio: 'inherit' }, opts || {}));

function copyDir(from, to, filter) {
  fs.mkdirSync(to, { recursive: true });
  for (const e of fs.readdirSync(from, { withFileTypes: true })) {
    const a = path.join(from, e.name), b = path.join(to, e.name);
    if (filter && !filter(a, e)) continue;
    if (e.isDirectory()) copyDir(a, b, filter); else fs.copyFileSync(a, b);
  }
}

/// PNG (大きいもの 1 枚) → .ico (16〜256 の 6 種類。中身は PNG のまま入れる)。package-win.js と同じ作り方
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

// PDF の読み込みに使う文字の表 (cmaps) のうち、日本語の PDF に要るものだけ入れる (中国語・韓国語の表は入れない)
const OTHER_CJK = /^(Adobe-(CNS1|GB1|Korea1)|B5|CNS|ETen|ETHK|GB|HK|KSC|UniCNS|UniGB|UniKS)/;

async function main() {
  // 1. 本体 (C#)
  const work = path.join(build, 'host-obj');
  fs.mkdirSync(work, { recursive: true });
  const ico = path.join(work, 'satoruEditor.ico');
  fs.writeFileSync(ico, makeIco(path.join(root, 'assets', 'icons', 'ai.png'), work));
  fs.rmSync(bin, { recursive: true, force: true });
  run(dotnet, ['build', path.join(root, 'host', 'satoruEditor.csproj'), '-c', 'Release', '-o', bin, '-nologo', '-v', 'q', `-p:ApplicationIcon=${ico}`, `-p:Version=${pkg.version}`]);

  // 2. 画面 (renderer) を 1 つにまとめる
  fs.rmSync(stage, { recursive: true, force: true });
  fs.mkdirSync(path.join(app, 'renderer', 'dist'), { recursive: true });
  await require('esbuild').build({
    entryPoints: [path.join(root, 'renderer', 'src', 'app.js')], bundle: true, outfile: path.join(app, 'renderer', 'dist', 'app.js'),
    format: 'iife', platform: 'browser', target: ['chrome120'], minify: true, logLevel: 'warning',
  });
  for (const f of ['index.html', 'style.css']) fs.copyFileSync(path.join(root, 'renderer', f), path.join(app, 'renderer', f));
  copyDir(path.join(root, 'assets', 'icons'), path.join(app, 'assets', 'icons'));
  const pdfjs = path.join(root, 'node_modules', 'pdfjs-dist');
  fs.mkdirSync(path.join(app, 'pdfjs'), { recursive: true });
  for (const f of ['pdf.min.js', 'pdf.worker.min.js']) fs.copyFileSync(path.join(pdfjs, 'build', f), path.join(app, 'pdfjs', f));
  copyDir(path.join(pdfjs, 'cmaps'), path.join(app, 'pdfjs', 'cmaps'), (p, e) => e.isFile() && e.name.endsWith('.bcmap') && !OTHER_CJK.test(e.name));
  fs.copyFileSync(path.join(pdfjs, 'LICENSE'), path.join(app, 'pdfjs', 'LICENSE'));

  // 3. 本体の部品
  const take = ['satoruEditor.exe', 'satoruEditor.exe.config', 'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.WinForms.dll'];
  for (const f of fs.readdirSync(bin)) if (/^(Renci\.SshNet|Microsoft\.Bcl\.AsyncInterfaces|System\.[A-Za-z.]+)\.dll$/.test(f)) take.push(f);
  for (const f of take) fs.copyFileSync(path.join(bin, f), path.join(out, f));
  fs.copyFileSync(path.join(bin, 'runtimes', 'win-x64', 'native', 'WebView2Loader.dll'), path.join(out, 'WebView2Loader.dll'));

  fs.writeFileSync(path.join(out, 'README.txt'), [
    'さとるエディタ ' + pkg.version + ' (軽量版)', '',
    'satoruEditor.exe をダブルクリックして起動します。フォルダごと好きな場所に置いてください。',
    'Double-click satoruEditor.exe to start. Keep the whole folder together.', '',
    '動かすには Windows 10 / 11 に最初から入っている .NET Framework 4.8 と Microsoft Edge WebView2 ランタイムを使います。',
    'It uses .NET Framework 4.8 and the Microsoft Edge WebView2 Runtime, which come with Windows 10 / 11.', '',
    '初回は Windows の「PC が保護されました」が出ることがあります。「詳細情報」→「実行」で起動できます。',
    'Windows may show "Windows protected your PC" the first time. Choose "More info" > "Run anyway".', '',
  ].join('\r\n'));

  const zipOut = path.join(build, `satoruEditor-${pkg.version}-win-x64-lite.zip`);
  fs.rmSync(zipOut, { force: true });
  run('zip', ['-q', '-r', '-X', '-9', zipOut, 'satoruEditor'], { cwd: stage });
  console.log('できました:', out);
  console.log('配布用:', zipOut, (fs.statSync(zipOut).size / 1048576).toFixed(2) + ' MB');
}

main().catch(e => { console.error(e); process.exit(1); });
