'use strict';
// 自動ふりがな: 文章の漢字に読みを付ける (辞書は kuromoji)。読みは辞書まかせなので、人名などは外れることがある
const path = require('path');

const KANJI = /[㐀-䶿一-鿿豈-﫿々〆ヵヶ]/;
let building = null;

function tokenizer() {
  if (!building) {
    building = new Promise((resolve, reject) => {
      const kuromoji = require('kuromoji');
      const dicPath = path.join(path.dirname(require.resolve('kuromoji/package.json')), 'dict');
      kuromoji.builder({ dicPath }).build((err, tk) => (err ? reject(err) : resolve(tk)));
    });
    building.catch(() => { building = null; });
  }
  return building;
}

function toHiragana(s) {
  return s.replace(/[ァ-ヶ]/g, c => String.fromCharCode(c.charCodeAt(0) - 0x60));
}

function escapeRegex(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

/// 1 つの単語 (表記と読み) → [{ from, to, reading }] (from / to は単語の中の位置)。送りがなには付けない
function splitWord(surface, reading) {
  const yomi = toHiragana(reading);
  // 表記を「漢字のかたまり」と「かなのかたまり」に分ける
  const parts = [];
  for (let i = 0; i < surface.length; i++) {
    const kanji = KANJI.test(surface[i]);
    const last = parts[parts.length - 1];
    if (last && last.kanji === kanji) { last.text += surface[i]; last.to = i + 1; }
    else parts.push({ kanji, text: surface[i], from: i, to: i + 1 });
  }
  if (!parts.some(p => p.kanji)) return [];
  const pattern = '^' + parts.map(p => (p.kanji ? '(.+?)' : escapeRegex(toHiragana(p.text)))).join('') + '$';
  const m = new RegExp(pattern).exec(yomi);
  if (!m) return [{ from: 0, to: surface.length, reading: yomi }];
  let g = 1;
  return parts.filter(p => p.kanji).map(p => ({ from: p.from, to: p.to, reading: m[g++] }));
}

/// 文章 → ふりがなの一覧 [{ from, to, reading }] (位置は文章の先頭から、UTF-16 単位)
async function ruby(text) {
  const tk = await tokenizer();
  const out = [];
  let base = 0;
  for (const line of String(text).split('\n')) {
    if (line.length <= 20000 && KANJI.test(line)) {
      let pos = 0;
      for (const token of tk.tokenize(line)) {
        const surface = token.surface_form;
        const at = line.indexOf(surface, pos);
        if (at < 0) continue;
        pos = at + surface.length;
        if (!token.reading || token.reading === '*' || !KANJI.test(surface)) continue;
        for (const r of splitWord(surface, token.reading)) {
          out.push({ from: base + at + r.from, to: base + at + r.to, reading: r.reading });
        }
      }
    }
    base += line.length + 1;
  }
  return out;
}

module.exports = { ruby, splitWord, toHiragana };
