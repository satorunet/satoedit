'use strict';
// 画面側 (renderer/src) を 1 つのファイル renderer/dist/app.js にまとめる: node scripts/build.js
const path = require('path');
const esbuild = require('esbuild');

const root = path.join(__dirname, '..');
esbuild.build({
  entryPoints: [path.join(root, 'renderer', 'src', 'app.js')],
  bundle: true,
  outfile: path.join(root, 'renderer', 'dist', 'app.js'),
  format: 'iife',
  platform: 'browser',
  target: ['chrome120'],
  sourcemap: process.argv.includes('--sourcemap'),
  minify: process.argv.includes('--minify'),
  logLevel: 'info',
}).catch(() => process.exit(1));
