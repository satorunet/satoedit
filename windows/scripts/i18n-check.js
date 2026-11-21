'use strict';
// 表示する言葉の洗い出し: node scripts/i18n-check.js
// プログラムの中の日本語の文字列を集めて、英語の対応表 (shared/en.js) にまだ無いものを並べる。全部そろっていれば何も出ない
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const JAPANESE = /[぀-ヿ㐀-鿿＀-￯]/;
// 画面に出す言葉ではないもの (フォントの名前、見本の文章、文字の集まりなど)
const IGNORE = new Set([
  'ＭＳ 明朝', '// メモ', '"文字"', '「『（(', '↓', 'シェル', 'バッチファイル', '秀丸ダーク',
]);
// theme.json の中に書く説明や、フォント名の並び
const SURNAMES = new Set(require('../shared/privacyscan').SURNAMES);
const IGNORE_PATTERN = /^(\s*"_|"[A-Za-z])/;

function sourceFiles() {
  const out = [path.join(root, 'main.js')];
  for (const dir of ['core', 'shared', path.join('renderer', 'src')]) {
    for (const f of fs.readdirSync(path.join(root, dir))) {
      if (!f.endsWith('.js') || f === 'en.js' || f === 'mock-api.js' || f === 'selftest.js' || f === 'plugindocs.js') continue; // plugindocs は拡張機能を作る人向けの説明 (日本語のまま)
      out.push(path.join(root, dir, f));
    }
  }
  return out;
}

/// ソースから文字列を取り出す ('…' "…" `…`。コメントは飛ばす)
function literals(code) {
  const out = [];
  let i = 0;
  const n = code.length;
  while (i < n) {
    const c = code[i];
    if (c === '/' && code[i + 1] === '/') { i = code.indexOf('\n', i); if (i < 0) break; continue; }
    if (c === '/' && code[i + 1] === '*') { i = code.indexOf('*/', i) + 2; continue; }
    if (c === '\'' || c === '"' || c === '`') {
      let j = i + 1, s = '';
      while (j < n && code[j] !== c) {
        if (code[j] === '\\') {
          const e = code[j + 1];
          s += e === 'n' ? '\n' : e === 't' ? '\t' : e === 'u' ? String.fromCharCode(parseInt(code.substr(j + 2, 4), 16)) : e;
          j += e === 'u' ? 6 : 2;
        } else {
          s += code[j];
          j += 1;
        }
      }
      // ${…} を含むものは、言葉を組み立てている途中なので対象外
      if (!(c === '`' && s.includes('${'))) out.push(s);
      i = j + 1;
      continue;
    }
    // 正規表現の中の / や引用符で迷子にならないように、/…/ は飛ばす
    if (c === '/' && /[(,=:[!&|?{};\n]\s*$/.test(code.slice(Math.max(0, i - 20), i))) {
      let j = i + 1, inClass = false;
      while (j < n && (code[j] !== '/' || inClass) && code[j] !== '\n') {
        if (code[j] === '\\') j += 1;
        else if (code[j] === '[') inClass = true;
        else if (code[j] === ']') inClass = false;
        j += 1;
      }
      i = j + 1;
      continue;
    }
    i += 1;
  }
  return out;
}

function collect() {
  const found = new Map();
  for (const file of sourceFiles()) {
    for (const s of literals(fs.readFileSync(file, 'utf8'))) {
      if (!JAPANESE.test(s) || IGNORE.has(s) || IGNORE_PATTERN.test(s)) continue;
      // 正規表現の文字列 (個人情報の点検など) と、名字の一覧は訳さない
      if (/\(\?[:<=!]|\[0-9|\\s/.test(s) || SURNAMES.has(s)) continue;
      // 記号・かっこだけのもの (訳す言葉ではない)
      if (/^[\s\u3000-\u303F\uFF01-\uFF0F\uFF1A-\uFF20\uFF3B-\uFF40\uFF5B-\uFF65○●✕✓]+$/.test(s)) continue;
      if (!found.has(s)) found.set(s, path.relative(root, file));
    }
  }
  return found;
}

function missing() {
  const en = require('../shared/en');
  const out = [];
  for (const [s, file] of collect()) if (!Object.prototype.hasOwnProperty.call(en, s)) out.push([s, file]);
  return out;
}

module.exports = { collect, missing };

if (require.main === module) {
  const list = missing();
  for (const [s, file] of list) console.log(JSON.stringify(s) + ',   // ' + file);
  console.error(`${collect().size} 個の言葉のうち、英語がまだ無いもの: ${list.length} 個`);
}
