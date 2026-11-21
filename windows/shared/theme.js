'use strict';
// 色とフォント。プリセットを選び、そのうえで項目ごとに上書きできる。Mac 版と同じ色・同じ theme.json の形
const ENTRIES = [
  ['background', '本文の背景'],
  ['text', '普通の文字'],
  ['caret', 'カーソル (キャレット)'],
  ['selection', '選択範囲の背景'],
  ['currentLine', 'カーソル行の背景'],
  ['currentLineText', 'カーソル行の文字 (透明にすると色を変えない)'],
  ['gutterBackground', '行番号の背景'],
  ['gutterText', '行番号'],
  ['gutterCurrentText', 'カーソル行の行番号'],
  ['gutterSeparator', '行番号と本文の区切り線'],
  ['statusBackground', 'ステータスバーの背景 (*)'],
  ['statusText', 'ステータスバーの文字 (*)'],
  ['newlineMark', '改行マーク ↓'],
  ['invisible', 'タブ・空白の記号'],
  ['eof', '[EOF]'],
  ['keyword', 'キーワード'],
  ['type', '型名'],
  ['string', '文字列'],
  ['comment', 'コメント'],
  ['number', '数値'],
  ['tag', 'HTML タグ・grep のファイル名'],
  ['link', 'URL・メールアドレス (リンク)'],
].map(([key, label]) => ({ key, label }));

function preset(name, hexes) {
  const colors = {};
  ENTRIES.forEach((e, i) => { colors[e.key] = hexes[i]; });
  return { name, colors };
}

const PRESETS = [
  preset('ダーク', [
    '#2B2B2B', '#E5E5E5', '#E5E5E5', '#2F5A8A', '#FFFFFF0B', '#D0AF4C', '#2B2B2B', '#E5E5E5', '#D0AF4C',
    '#484848', '#484848', '#E5E5E5', '#31E3E5', '#828282', '#31E3E5',
    '#C792EA', '#E5C07B', '#E8483F', '#7F8C8D', '#F78C6C', '#61AFEF', '#6CB6FF']),
  preset('ライト', [
    '#FFFFFF', '#1E1E1E', '#000000', '#B4D5FE', '#0000000A', '#A8862A', '#F3F3F3', '#8A8A8A', '#A8862A',
    '#DDDDDD', '#E8E8E8', '#333333', '#2A9FB0', '#BBBBBB', '#2A9FB0',
    '#0033B3', '#7A3E9D', '#C41A16', '#6A8A6A', '#1750EB', '#0B7A75', '#0B57D0']),
  preset('暖色ダーク', [
    '#2A211C', '#EBDBC2', '#F5C26B', '#5C4632', '#FFE0B014', '#D0AF4C', '#241C18', '#8C7A66', '#D0AF4C',
    '#4A3B30', '#3A2E26', '#EBDBC2', '#D9A05B', '#6E5E50', '#D9A05B',
    '#F28C5B', '#E8C267', '#A9C46C', '#8C7A66', '#E39B7B', '#E0A96D', '#7FB8E6']),
  preset('和紙 (暖色ライト)', [
    '#F7F1E3', '#3B3127', '#8B4513', '#E8D5B0', '#8B451310', '#A8862A', '#EFE6D2', '#A8957A', '#A8862A',
    '#DCCEB0', '#E6DAC0', '#3B3127', '#B0803C', '#C8B89A', '#B0803C',
    '#A0522D', '#6B5B95', '#B03A2E', '#8A9A6B', '#C0662D', '#2E6E8E', '#1A5FB4']),
  preset('さくら (ピンク)', [
    '#FFF0F5', '#4A2C3A', '#E0457B', '#FFC2D9', '#E0457B12', '#A8862A', '#FCE4EE', '#C08AA2', '#A8862A',
    '#F3C6D8', '#F8D3E2', '#4A2C3A', '#E07BA5', '#D9AFC2', '#E07BA5',
    '#C2185B', '#8E44AD', '#D35400', '#A88799', '#E91E63', '#AD1457', '#2F6FD0']),
  preset('ピンクダーク', [
    '#2B1F28', '#F2DDE8', '#FF7EB6', '#6B3555', '#FF7EB612', '#D0AF4C', '#261B23', '#9C7A8E', '#D0AF4C',
    '#4A3343', '#3D2A37', '#F2DDE8', '#FF7EB6', '#7A5C6E', '#FF7EB6',
    '#FF79C6', '#FFB3D9', '#FFD27F', '#9C7A8E', '#FF9E9E', '#D7A6FF', '#8FC1FF']),
  preset('ミッドナイト (青)', [
    '#14192B', '#D6DEEB', '#7FDBFF', '#26407A', '#FFFFFF0A', '#D0AF4C', '#111526', '#5A6788', '#D0AF4C',
    '#2A3250', '#1E2540', '#C0CAE0', '#4FA3D9', '#3E4A6B', '#4FA3D9',
    '#82AAFF', '#7FDBCA', '#ECC48D', '#637777', '#F78C6C', '#7FDBFF', '#9CC4FF']),
  preset('黒板 (緑)', [
    '#1F2B24', '#E6EDE3', '#FFFFFF', '#3D5A47', '#FFFFFF0A', '#D0AF4C', '#1A251F', '#7D9184', '#D0AF4C',
    '#34453A', '#2A3A30', '#E6EDE3', '#F2E394', '#5E7266', '#F2E394',
    '#F2E394', '#9FD3F0', '#F5A9A9', '#8FA897', '#FFC48C', '#9FD3F0', '#A8D8FF']),
];

const WINDOW_STYLES = [
  { key: 'gray', label: '灰色' },
  { key: 'theme', label: 'テーマに合わせる' },
  { key: 'system', label: 'Windows の設定に合わせる' },
];

// Windows の等幅の和文フォント。無ければ順に次を使う
const DEFAULT_FONT_NAME = 'BIZ UDGothic';
const FONT_FALLBACK = '"BIZ UDGothic", "MS Gothic", "ＭＳ ゴシック", "Osaka-Mono", "Noto Sans Mono CJK JP", monospace';
const DEFAULT_FONT_SIZE = 14;

/// #RRGGBB / #RRGGBBAA をそろえた形 (大文字) にする。読めなければ null
function normalizeHex(hex) {
  let s = String(hex || '').trim();
  if (s.startsWith('#')) s = s.slice(1);
  if (!/^([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(s)) return null;
  s = s.toUpperCase();
  if (s.length === 8 && s.endsWith('FF')) s = s.slice(0, 6);
  return '#' + s;
}

function defaults() {
  return { preset: PRESETS[0].name, windowStyle: 'gray', fontName: DEFAULT_FONT_NAME, fontSize: DEFAULT_FONT_SIZE, overrides: {} };
}

function presetNamed(name) { return PRESETS.find(p => p.name === name) || PRESETS[0]; }

/// theme.json の中身 (JSON を読んだもの) → 状態。問題があった項目は既定値にして problems に書く
function fromJSON(root) {
  const t = defaults();
  const problems = [];
  if (!root || typeof root !== 'object' || Array.isArray(root)) return { theme: t, problems: ['一番外側が { } ではありません'] };
  if (typeof root.preset === 'string') {
    const p = root.preset === '秀丸ダーク' ? 'ダーク' : root.preset;
    if (PRESETS.some(x => x.name === p)) t.preset = p;
    else problems.push(`知らないプリセット: ${p}`);
  }
  if (typeof root.windowStyle === 'string') {
    if (WINDOW_STYLES.some(x => x.key === root.windowStyle)) t.windowStyle = root.windowStyle;
    else problems.push('windowStyle は gray / theme / system のどれかにしてください');
  }
  if (root.font && typeof root.font === 'object') {
    if (typeof root.font.name === 'string' && root.font.name) t.fontName = root.font.name;
    if (typeof root.font.size === 'number' && root.font.size >= 6 && root.font.size <= 72) t.fontSize = root.font.size;
  }
  const base = presetNamed(t.preset).colors;
  for (const [key, value] of Object.entries(root.colors || {})) {
    if (!(key in base)) { problems.push(`知らない項目: ${key}`); continue; }
    const h = normalizeHex(value);
    if (!h) { problems.push(`${key} の色が読めません (#RRGGBB か #RRGGBBAA で書いてください)`); continue; }
    if (h !== normalizeHex(base[key])) t.overrides[key] = h; // プリセットと同じ色は上書き扱いにしない
  }
  return { theme: t, problems };
}

/// 状態 → theme.json の文字列 (説明つき)
function toFileContents(t) {
  const q = s => JSON.stringify(s);
  const width = Math.max(...ENTRIES.map(e => e.key.length));
  const lines = ['{'];
  lines.push('  "_説明": "preset で土台を選び、colors に書いた項目だけ上書きします。色は #RRGGBB (透明度つきは #RRGGBBAA)。",');
  lines.push('  "_使えるpreset": [' + PRESETS.map(p => q(p.name)).join(', ') + '],');
  lines.push(`  "preset": ${q(t.preset)},`);
  lines.push(`  "windowStyle": ${q(t.windowStyle)},`);
  lines.push('  "_windowStyleの意味": "ウインドウ枠・タブ・メニューの色。gray = 灰色、theme = テーマに合わせる、system = OS に合わせる。(*) の項目は gray / system のとき、colors に書かない限り枠と同じ色になります",');
  lines.push(`  "font": { "name": ${q(t.fontName)}, "size": ${t.fontSize} },`);
  const custom = ENTRIES.filter(e => t.overrides[e.key]);
  if (custom.length === 0) {
    lines.push('  "colors": {},');
  } else {
    lines.push('  "colors": {');
    custom.forEach((e, i) => {
      lines.push(`    "${e.key}": ${' '.repeat(width - e.key.length)}"${t.overrides[e.key]}"` + (i === custom.length - 1 ? '' : ','));
    });
    lines.push('  },');
  }
  lines.push('  "_項目の意味": {');
  ENTRIES.forEach((e, i) => lines.push(`    "${e.key}": ${q(e.label)}` + (i === ENTRIES.length - 1 ? '' : ',')));
  lines.push('  }', '}');
  return lines.join('\n') + '\n';
}

/// いま有効な色 (キー → #RRGGBB / #RRGGBBAA)
function colors(t) {
  return Object.assign({}, presetNamed(t.preset).colors, t.overrides);
}

function isDark(hex) {
  const h = normalizeHex(hex) || '#000000';
  const r = parseInt(h.slice(1, 3), 16) / 255, g = parseInt(h.slice(3, 5), 16) / 255, b = parseInt(h.slice(5, 7), 16) / 255;
  return 0.2126 * r + 0.7152 * g + 0.0722 * b < 0.5;
}

module.exports = {
  ENTRIES, PRESETS, WINDOW_STYLES, DEFAULT_FONT_NAME, DEFAULT_FONT_SIZE, FONT_FALLBACK,
  normalizeHex, defaults, presetNamed, fromJSON, toFileContents, colors, isDark,
};
