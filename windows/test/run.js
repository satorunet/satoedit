'use strict';
// 部品のテスト: node test/run.js  (Mac 版が作った見本 test/fixtures/mac-* を読めることも確かめる)
// 引数にフォルダを渡すと、Mac 版に読ませるための見本 (win-*) をそこへ書き出す
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const codec = require('../core/codec');
const fc = require('../core/filecrypto');
const totp = require('../core/totp');
const grep = require('../core/grep');
const profiles = require('../shared/profiles');
const { makeScanner, KINDS, displayWidth } = require('../shared/scanner');
const theme = require('../shared/theme');
const genko = require('../shared/genko');
const zip = require('../core/zip');

const fx = n => fs.readFileSync(path.join(__dirname, 'fixtures', n));
const tests = [];
const test = (name, fn) => tests.push([name, fn]);
const PLAIN = Buffer.from('こんにちは、Windows 版。\n2 行目 ABC 123\n', 'utf8');
const SAMPLE = '日本語テキスト、漢字\nabc 123\n';
const SECRET = Buffer.from(Array.from({ length: 20 }, (_, i) => i * 7 + 1));

test('文字コード: Mac 版が書いた 7 種類を自動判定して読める', () => {
  for (const e of codec.ENCODINGS) {
    const d = codec.decode(fx(`mac-${e.id}.txt`));
    assert.strictEqual(d.text, SAMPLE, e.id);
    assert.strictEqual(d.encoding, e.id, e.id);
    assert.strictEqual(d.lineEnding, 'crlf', e.id);
  }
});
test('文字コード: 書いたものが Mac 版の出力とバイト単位で同じ', () => {
  for (const e of codec.ENCODINGS) {
    assert.ok(codec.encode(SAMPLE, e.id, 'crlf').equals(fx(`mac-${e.id}.txt`)), e.id);
  }
});
test('文字コード: 機種依存文字は Shift_JIS で往復でき、書けない文字はエラー', () => {
  const s = '①㈱髙﨑 ｶﾅ\n';
  assert.strictEqual(codec.decode(codec.encode(s, 'shiftJIS', 'lf'), 'shiftJIS').text, s);
  assert.throws(() => codec.encode('絵文字😀', 'shiftJIS', 'lf'), /保存できない文字/);
  assert.throws(() => codec.encode('한국어', 'eucJP', 'lf'), /保存できない文字/);
  const kana = 'ｶﾅ と 漢字\n';
  assert.strictEqual(codec.decode(codec.encode(kana, 'iso2022JP', 'lf')).text, kana);
});
test('文字コード: 改行の判定と正規化', () => {
  assert.strictEqual(codec.detectLineEnding('a\rb'), 'cr');
  assert.strictEqual(codec.normalizeLineEndings('a\r\nb\rc\n'), 'a\nb\nc\n');
  assert.strictEqual(codec.decode(Buffer.from('a\rb', 'utf8')).lineEnding, 'cr');
  assert.strictEqual(codec.encode('a\nb', 'utf8', 'cr').toString(), 'a\rb');
  assert.strictEqual(codec.decode(Buffer.alloc(0)).encoding, 'utf8');
});
test('文字コード: 壊れたバイトは指定の文字コードでは読めず、自動なら置換して開く', () => {
  const bad = Buffer.from([0x82, 0xA0, 0xFF, 0xFF, 0x80]);
  assert.throws(() => codec.decode(bad, 'utf8'));
  assert.ok(typeof codec.decode(bad).text === 'string');
});

test('暗号化: Mac 版で暗号化した文書を開ける (パスワード・パスコード・鍵ファイル・二段階)', async () => {
  assert.ok((await fc.openWithPassword(fx('mac-password.enc'), 'ひみつのpassword')).plain.equals(PLAIN));
  assert.ok((await fc.openWithPassword(fx('mac-passcode.enc'), '123456')).plain.equals(PLAIN));
  const secret = fc.keyFileSecret(fx('mac.satorukey'));
  assert.ok(secret);
  assert.ok(fc.openWithKeyFile(fx('mac-keyfile.enc'), secret).plain.equals(PLAIN));
  assert.ok((await fc.openTwoStep(fx('mac-twostep.enc'), 'pw-two-step', SECRET)).plain.equals(PLAIN));
  assert.strictEqual(fc.header(fx('mac-passcode.enc')).kind, 'passcode');
});
test('暗号化: 違うパスワード・改ざん・違う鍵ファイルは開けない', async () => {
  await assert.rejects(fc.openWithPassword(fx('mac-password.enc'), 'ちがう'), e => e.code === 'wrong');
  const key = await fc.deriveKey('pw', { iterations: 10000 });
  const sealed = fc.seal(PLAIN, key);
  assert.ok(fc.open(sealed, key).equals(PLAIN));
  for (const i of [5, 12, 13, 20, sealed.length - 1, sealed.length - 20]) {
    const t = Buffer.from(sealed);
    t[i] ^= 1;
    assert.throws(() => fc.open(t, key), undefined, `位置 ${i}`);
  }
  const other = fc.keyFileSecret(fc.newKeyFileContents());
  assert.throws(() => fc.openWithKeyFile(fx('mac-keyfile.enc'), other), e => e.code === 'wrongKeyFile');
  assert.ok(!fc.isEncrypted(Buffer.from('普通の文章')));
  assert.throws(() => fc.header(Buffer.from('普通の文章')), e => e.code === 'notEncrypted');
  assert.strictEqual(fc.keyFileSecret(Buffer.from('SATORU-KEYFILE-1\r\n# x\r\nAAAA\r\n')), null);
});
test('暗号化: 保存のたびに中身が変わり、空の文書も扱える。この PC の鍵も往復できる', () => {
  const dk = fc.newDeviceKey();
  assert.ok(!fc.seal(PLAIN, dk).equals(fc.seal(PLAIN, dk)));
  assert.strictEqual(fc.open(fc.seal(Buffer.alloc(0), dk), fc.deviceKey(dk.key, dk.salt)).length, 0);
  assert.throws(() => fc.open(fc.seal(PLAIN, dk), fc.newDeviceKey()));
  const v1 = fc.seal(PLAIN, { key: dk.key, salt: dk.salt, iterations: 600000, kind: 'password' }, 1);
  assert.strictEqual(fc.header(v1).version, 1);
  assert.ok(fc.open(v1, { key: dk.key, salt: dk.salt, kind: 'password' }).equals(PLAIN));
});

test('ワンタイム認証: 公式の検証値 (RFC 6238) と Mac 版の値に一致', () => {
  const rfc = Buffer.from('12345678901234567890');
  assert.strictEqual(totp.codeAt(rfc, Math.floor(59 / 30), 8), '94287082');
  assert.strictEqual(totp.codeAt(rfc, Math.floor(1111111109 / 30), 8), '07081804');
  assert.strictEqual(totp.codeAt(rfc, Math.floor(20000000000 / 30), 8), '65353130');
  assert.strictEqual(totp.code(SECRET, 1700000000), '107393');
  assert.strictEqual(totp.base32(SECRET), 'AEEA6FQ5EQVTEOKAI5HFKXDDNJYXQ74G');
  assert.strictEqual(totp.uri(SECRET, '文書 A.txt', 'さとるエディタ'),
    'otpauth://totp/%E3%81%95%E3%81%A8%E3%82%8B%E3%82%A8%E3%83%87%E3%82%A3%E3%82%BF:%E6%96%87%E6%9B%B8%20A.txt?secret=AEEA6FQ5EQVTEOKAI5HFKXDDNJYXQ74G&issuer=%E3%81%95%E3%81%A8%E3%82%8B%E3%82%A8%E3%83%87%E3%82%A3%E3%82%BF&algorithm=SHA1&digits=6&period=30');
  assert.ok(totp.verify('107 393', SECRET, 1700000000));
  assert.ok(totp.verify('107393', SECRET, 1700000000 + 30));
  assert.ok(!totp.verify('107393', SECRET, 1700000000 + 90));
  assert.ok(!totp.verify('10739', SECRET, 1700000000));
});

test('色分け: コメント中の文字列・文字列中のコメント記号', () => {
  const p = profiles.BUILT_IN.find(x => x.name === 'JavaScript / TypeScript');
  const src = 'const s = "a // b"; // "c"\n/* x\n y */ let Foo = 12.5;\n`multi\nline`';
  const t = makeScanner(p)(src);
  const got = [];
  for (let i = 0; i < t.length; i += 3) got.push([KINDS[t[i + 2]], src.slice(t[i], t[i + 1])]);
  assert.deepStrictEqual(got, [
    ['keyword', 'const'], ['string', '"a // b"'], ['comment', '// "c"'], ['comment', '/* x\n y */'],
    ['keyword', 'let'], ['type', 'Foo'], ['number', '12.5'], ['string', '`multi\nline`'],
  ]);
});
test('色分け: 大文字小文字を区別しない言語・タグ・閉じていない文字列', () => {
  const sql = makeScanner(profiles.BUILT_IN.find(x => x.name === 'SQL'));
  const a = 'SELECT x FROM t -- c';
  const ta = sql(a);
  assert.strictEqual(KINDS[ta[2]], 'keyword');
  assert.strictEqual(a.slice(ta[ta.length - 3], ta[ta.length - 2]), '-- c');
  const html = makeScanner(profiles.BUILT_IN.find(x => x.name === 'HTML / XML'));
  const h = '<div class="a"></div><!-- <p> -->';
  const th = html(h);
  const kinds = [];
  for (let i = 0; i < th.length; i += 3) kinds.push(KINDS[th[i + 2]] + ':' + h.slice(th[i], th[i + 1]));
  assert.deepStrictEqual(kinds, ['tag:<div', 'string:"a"', 'tag:</div', 'comment:<!-- <p> -->']);
  const py = makeScanner(profiles.BUILT_IN.find(x => x.name === 'Python'));
  const u = 'x = "abc\ny = 1';
  const tu = py(u);
  assert.strictEqual(u.slice(tu[0], tu[1]), '"abc');
  assert.strictEqual(displayWidth('aあｱ'), 4);
});
test('言語の判定と、ユーザー設定での上書き・追加', () => {
  const list = profiles.merge([{ name: 'Python', extensions: ['PY'], tabWidth: 8 }, { name: '自作', extensions: ['zzz'] }, { bad: 1 }]);
  assert.strictEqual(profiles.profileForFileName(list, 'a.py').tabWidth, 8);
  assert.strictEqual(profiles.profileForFileName(list, 'b.ZZZ').name, '自作');
  assert.strictEqual(profiles.profileForFileName(list, 'Makefile').name, 'Makefile');
  assert.strictEqual(profiles.profileForFileName(list, 'x.cs').name, 'C#');
  assert.strictEqual(profiles.profileForFileName(list, 'メモ'), null);
  assert.strictEqual(profiles.profileForFileName(list, '.gitignore'), null);
});

test('テーマ: theme.json の読み書き (Mac 版と同じ形)', () => {
  assert.strictEqual(theme.PRESETS.length, 8);
  for (const p of theme.PRESETS) for (const e of theme.ENTRIES) assert.ok(theme.normalizeHex(p.colors[e.key]), p.name + e.key);
  const { theme: t, problems } = theme.fromJSON({ preset: 'ライト', windowStyle: 'theme', font: { name: 'X', size: 16 },
    colors: { text: '#ff0000', background: '#FFFFFF', nope: '#000000', caret: 'zzz' } });
  assert.deepStrictEqual(t.overrides, { text: '#FF0000' });
  assert.strictEqual(problems.length, 2);
  const again = theme.fromJSON(JSON.parse(theme.toFileContents(t)));
  assert.deepStrictEqual(again.theme, t);
  assert.strictEqual(again.problems.length, 0);
  assert.strictEqual(theme.colors(t).text, '#FF0000');
  assert.ok(theme.isDark('#2B2B2B') && !theme.isDark('#F7F1E3'));
});

test('grep: マスク・正規表現・バイナリ除外・Shift_JIS のファイル', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satoru-grep-'));
  fs.mkdirSync(path.join(dir, 'sub'));
  fs.mkdirSync(path.join(dir, 'node_modules'));
  fs.writeFileSync(path.join(dir, 'a.txt'), 'りんご\nみかん Apple\n');
  fs.writeFileSync(path.join(dir, 'sub', 'b.md'), codec.encode('apple パイ\n', 'shiftJIS', 'crlf'));
  fs.writeFileSync(path.join(dir, 'c.bin'), Buffer.from([0x61, 0, 0x70, 0x70, 0x6C, 0x65]));
  fs.writeFileSync(path.join(dir, 'node_modules', 'd.txt'), 'apple');
  const run = async o => { const r = []; await grep.search(dir, o, m => r.push(path.basename(m.file) + ':' + m.line + ':' + m.text)); return r; };
  assert.deepStrictEqual(await run({ pattern: 'apple' }), ['a.txt:2:みかん Apple', 'b.md:1:apple パイ']);
  assert.deepStrictEqual(await run({ pattern: 'apple', caseSensitive: true }), ['b.md:1:apple パイ']);
  assert.deepStrictEqual(await run({ pattern: 'apple', fileMask: '*.txt' }), ['a.txt:2:みかん Apple']);
  assert.deepStrictEqual(await run({ pattern: 'apple', recursive: false }), ['a.txt:2:みかん Apple']);
  assert.deepStrictEqual(await run({ pattern: '^り.+ご$', useRegex: true }), ['a.txt:1:りんご']);
  assert.deepStrictEqual(await run({ pattern: 'a.c', useRegex: false }), []);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('作文用紙: 題名 3 マス下げ・名前 下寄せ・段落 1 マス下げ・1 枚 20 列', () => {
  const text = '題名です\n山田太郎\n\n' + 'あ'.repeat(25) + '\n「かぎ」で始まる\n　字下げ済み';
  const cols = genko.layout(text, { autoFormat: true });
  const str = c => c.cells.map(x => x || '・').join('');
  assert.strictEqual(str(cols[0]), '・・・題名です' + '・'.repeat(13));
  assert.strictEqual(str(cols[1]), '・'.repeat(15) + '山田太郎・');
  assert.strictEqual(str(cols[2]), '・'.repeat(20));
  assert.strictEqual(str(cols[3]), '・' + 'あ'.repeat(19));
  assert.strictEqual(str(cols[4]), 'あ'.repeat(6) + '・'.repeat(14));
  assert.strictEqual(str(cols[5]).slice(0, 4), '「かぎ」');
  assert.strictEqual(str(cols[6]).slice(0, 4), '　字下げ');
  const plain = genko.layout(text, { autoFormat: false });
  assert.strictEqual(str(plain[0]).slice(0, 4), '題名です');
  assert.strictEqual(genko.sheets(genko.layout('あ'.repeat(401), {})).length, 2);
  assert.strictEqual(genko.sheets(genko.layout('', {})).length, 1);
  assert.strictEqual(genko.toFullWidth('abc 12!'), 'ａｂｃ　１２！');
  assert.deepStrictEqual(genko.a4Aligns('題\n名前\n\n本文\n　下げ済み', { autoFormat: true }).map(x => x.align + (x.indent ? '+' : '')),
    ['center', 'right', 'left', 'left+', 'left']);
});

test('zip: 作ったファイルを unzip で取り出せる (Word 書き出しの入れ物)', () => {
  const data = zip.make([{ name: 'a.txt', data: Buffer.from('hello') }, { name: 'dir/b.xml', data: Buffer.from('<x>あ</x>'.repeat(500)) }]);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'satoru-zip-'));
  fs.writeFileSync(path.join(dir, 't.zip'), data);
  const { execFileSync } = require('child_process');
  execFileSync('unzip', ['-q', path.join(dir, 't.zip'), '-d', path.join(dir, 'out')]);
  assert.strictEqual(fs.readFileSync(path.join(dir, 'out', 'a.txt'), 'utf8'), 'hello');
  assert.strictEqual(fs.readFileSync(path.join(dir, 'out', 'dir', 'b.xml'), 'utf8'), '<x>あ</x>'.repeat(500));
  fs.rmSync(dir, { recursive: true, force: true });
});

test('ふりがな: 送りがなには付けず、漢字のかたまりごとに読みを付ける', async () => {
  const f = require('../core/furigana');
  assert.deepStrictEqual(f.splitWord('美味しい', 'オイシイ'), [{ from: 0, to: 2, reading: 'おい' }]);
  assert.deepStrictEqual(f.splitWord('お寿司', 'オスシ'), [{ from: 1, to: 3, reading: 'すし' }]);
  assert.deepStrictEqual(f.splitWord('食べ物', 'タベモノ'), [{ from: 0, to: 1, reading: 'た' }, { from: 2, to: 3, reading: 'もの' }]);
  assert.deepStrictEqual(f.splitWord('かな', 'カナ'), []);
  const text = 'ひらがな\n学校の遠足';
  const r = await f.ruby(text);
  assert.deepStrictEqual(r.map(x => text.slice(x.from, x.to) + '=' + x.reading), ['学校=がっこう', '遠足=えんそく']);
});

test('作文用紙: カーソルの位置とマスの対応', () => {
  const text = '題\n\n' + 'あ'.repeat(25);
  const cols = genko.layout(text, { autoFormat: true });
  assert.deepStrictEqual(genko.caretCell(cols, 0), { column: 0, row: 3 });
  assert.deepStrictEqual(genko.caretCell(cols, 1), { column: 0, row: 4 });
  assert.deepStrictEqual(genko.caretCell(cols, 2), { column: 1, row: 0 }); // 何も書いていない 2 列目
  assert.deepStrictEqual(genko.caretCell(cols, 3), { column: 2, row: 1 });
  assert.deepStrictEqual(genko.caretCell(cols, 3 + 19), { column: 3, row: 0 }); // 折り返した先の頭
  assert.deepStrictEqual(genko.caretCell(cols, text.length), { column: 3, row: 6 });
  assert.strictEqual(genko.offsetAt(cols, 2, 5), 3 + 4);
  assert.strictEqual(genko.offsetAt(cols, 3, 15), text.length);
  assert.strictEqual(genko.offsetAt(cols, 0, 0), 0);
  for (let off = 0; off <= text.length; off++) {
    const c = genko.caretCell(cols, off);
    assert.strictEqual(genko.offsetAt(cols, c.column, c.row), off, '位置 ' + off);
  }
  assert.ok(genko.sheetSVG().startsWith('<svg'));
  assert.ok(Math.abs(genko.columnX(19) - genko.SHEET.left) < 1e-9, '左端の列が枠の左端に合う');
});

test('表示の言語: 英語の対応表に抜けがなく、{…} の差し込みも合っている', () => {
  const i18n = require('../shared/i18n');
  const en = require('../shared/en');
  const missing = require('../scripts/i18n-check').missing();
  assert.deepStrictEqual(missing.map(m => m[0]), []);
  const holes = s => (s.match(/\{\w+\}/g) || []).sort().join(',');
  for (const [ja, english] of Object.entries(en)) assert.strictEqual(holes(english), holes(ja), ja);
  assert.strictEqual(i18n.resolve('auto', 'ja-JP'), 'ja');
  assert.strictEqual(i18n.resolve('auto', 'en-US'), 'en');
  assert.strictEqual(i18n.resolve('ja', 'en-US'), 'ja');
  i18n.setLanguage('en');
  const menus = require('../shared/menu').build({ prefs: { aiEnabled: true, paperEnabled: true, encryptionEnabled: true, folderTreeEnabled: true }, languages: ['Python'], recent: ['C:\\a.txt'] });
  const flat = require('../shared/menu').flatten(menus).map(m => m.label);
  i18n.setLanguage('ja');
  assert.deepStrictEqual(menus.map(m => m.label), ['&File', '&Edit', '&Search', '&View', 'AI(&A)', '&Paper', 'En&cryption', 'E&xtras', '&Options']);
  const japanese = flat.filter(l => /[\u3040-\u30FF\u4E00-\u9FFF]/.test(l) && l !== '日本語 (Japanese)' && !l.includes('表示の言語'));
  assert.deepStrictEqual(japanese, []);
  assert.strictEqual(i18n.t('{n} 件', { n: 3 }), '3 件');
});

test('AI: 送る内容の形 (OpenAI・Claude・Gemini) と、届いた返事の取り出し', () => {
  const ai = require('../core/ai');
  const o = ai.buildRequest({ provider: 'openai', model: 'm', apiKey: 'k', baseURL: 'https://api.openai.com/v1/', system: 's', prompt: 'p' });
  assert.strictEqual(o.url, 'https://api.openai.com/v1/chat/completions');
  assert.strictEqual(o.headers.Authorization, 'Bearer k');
  assert.deepStrictEqual(o.body.stream_options, { include_usage: true });
  const c = ai.buildRequest({ provider: 'claude', model: 'claude-opus-5-5', apiKey: 'k', baseURL: 'https://api.anthropic.com', system: 's', prompt: 'p' });
  assert.strictEqual(c.url, 'https://api.anthropic.com/v1/messages');
  assert.strictEqual(c.headers['x-api-key'], 'k');
  assert.strictEqual(c.body.system, 's');
  const g = ai.buildRequest({ provider: 'gemini', model: 'models/g 1', apiKey: 'k', baseURL: 'https://x/v1beta', system: 's', prompt: 'p' });
  assert.strictEqual(g.url, 'https://x/v1beta/models/g%201:streamGenerateContent?alt=sse');
  const cu = ai.buildRequest({ provider: 'custom', model: 'm', apiKey: '', baseURL: 'http://localhost:11434/v1', system: 's', prompt: 'p' });
  assert.ok(!('Authorization' in cu.headers) && !('stream_options' in cu.body));
  const st = { inputTokens: 0, outputTokens: 0, error: null };
  assert.strictEqual(ai.extractText('openai', { choices: [{ delta: { content: 'あ' } }] }, st), 'あ');
  assert.strictEqual(ai.extractText('claude', { type: 'content_block_delta', delta: { type: 'text_delta', text: 'い' } }, st), 'い');
  assert.strictEqual(ai.extractText('gemini', { candidates: [{ content: { parts: [{ text: 'う' }, { text: 'え' }] } }] }, st), 'うえ');
  ai.extractText('claude', { type: 'message_delta', usage: { output_tokens: 7 }, delta: { stop_reason: 'refusal' } }, st);
  assert.strictEqual(st.outputTokens, 7);
  assert.ok(st.error);
  assert.ok(ai.explain(401, '{"error":{"message":"bad key"}}').includes('bad key'));
});

test('メニュー: キー割り当ての変更と、項目を隠す設定', () => {
  const m = require('../shared/menu');
  const menus = m.build({ prefs: { encryptionEnabled: true, keys: { 'file.save': 'Ctrl+Alt+Q', 'find.show': '' }, hiddenMenu: ['file.print', 'file.exportPDF', 'file.exportWord', 'file.importPDF', 'file.screenshot', 'settings.open:general', 'file.openRecent'] } });
  const flat = m.flatten(menus);
  assert.strictEqual(flat.find(x => x.id === 'file.save').accel, 'Ctrl+Alt+Q');
  assert.strictEqual(flat.find(x => x.id === 'find.show').accel, '');
  assert.ok(!flat.some(x => x.id === 'file.print'));
  assert.ok(flat.some(x => x.id === 'settings.open:general'), '設定を開く項目は隠せない');
  const file = menus[0].submenu;
  assert.ok(!file.some(x => x.header), '中身のなくなった見出しは消える');
  assert.ok(!file.some((x, i) => x.type === 'separator' && (i === 0 || i === file.length - 1 || file[i - 1].type === 'separator')), '区切り線が続かない');
  const all = m.flatten(m.build({ prefs: { hiddenMenu: ['file.print'] }, forSettings: true }));
  assert.ok(all.some(x => x.id === 'file.print'), '設定の画面では隠した項目も見える');
  assert.strictEqual(all.find(x => x.id === 'file.save').defaultAccel, 'Ctrl+S');
});

test('AI の利用の記録: 料金の計算と、今日・今月・月ごとの合計', () => {
  const u = require('../core/aiusage');
  assert.strictEqual(u.cost({ inputTokens: 1000000, outputTokens: 500000 }, 'claude', 'claude-opus-5-5', {}), 4 + 10);
  assert.strictEqual(u.cost({ inputTokens: 1000, outputTokens: 1000 }, 'openai', 'x', {}), null);
  assert.strictEqual(u.cost({ inputTokens: 1000000, outputTokens: 0 }, 'openai', 'x', { openai: { input: 2, output: 8 } }), 2);
  assert.strictEqual(u.cost({ inputTokens: 5, outputTokens: 5 }, 'custom', 'local', {}), 0);
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'satoru-usage-')), 'ai-usage.json');
  u.add(file, { inputTokens: 100, outputTokens: 50 }, 'claude', 'claude-opus-5-5', {});
  u.add(file, { inputTokens: 10, outputTokens: 5, estimated: true }, 'openai', 'x', {});
  u.add(file, { inputTokens: 0, outputTokens: 0 }, 'openai', 'x', {});
  const list = u.read(file);
  assert.strictEqual(list.length, 2);
  assert.ok(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(list[0].date), 'Mac 版と同じ日付の形');
  list.push({ date: '2020-01-15T00:00:00Z', provider: 'claude', model: 'm', input: 7, output: 3, cost: 1 });
  const s = u.summarize(list);
  assert.strictEqual(s.today.count, 2);
  assert.ok(s.today.unknownCost);
  assert.strictEqual(s.total.count, 3);
  assert.strictEqual(s.months[s.months.length - 1].month, '2020-01');
  u.clear(file);
  assert.deepStrictEqual(u.read(file), []);
  assert.deepStrictEqual(require('../core/winassoc').cleanExtensions(['.TXT', '*.md', 'a b', 'txt', '../x']), ['txt', 'md']);
});

test('PDF の読み込み: 行の組み立て (横書き・縦書き) と、字のそろえ', () => {
  const { pageText, tidy } = require('../core/pdfimport');
  const it = (str, x, y, size = 12, w = str.length * 12) => ({ str, transform: [size, 0, 0, size, x, y], width: w });
  assert.strictEqual(pageText([it('2 行目', 50, 680), it('題名', 200, 700), it('左', 50, 700, 12, 12), it('ふり', 50, 712, 5)]), '左 題名\n2 行目');
  const vertical = [];
  ['右の列', '左の列'].forEach((col, c) => Array.from(col).forEach((ch, r) => vertical.push(it(ch, 500 - c * 30, 700 - r * 20, 12, 12))));
  assert.strictEqual(pageText(vertical), '右の列\n左の列');
  assert.strictEqual(tidy('遠\u2F9C\u0000山'), '遠足山');
  assert.strictEqual(tidy('行き\uFE11朝\uFE12\uFE35あ\uFE36\uFE41か\uFE42'), '行き、朝。（あ）「か」');
  assert.strictEqual(pageText([]), '');
});

for (const kind of ['sftp', 'ftp']) {
  test(`サーバ (${kind.toUpperCase()}): 一覧・読み書き・フォルダ・名前変更・削除、まちがったパスワード`, async () => {
    const remote = require('../core/remote');
    const servers = require('./servers');
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'satoru-remote-'));
    fs.mkdirSync(path.join(root, 'www'));
    fs.writeFileSync(path.join(root, 'www', 'index.html'), codec.encode('<p>こんにちは</p>\n', 'shiftJIS', 'crlf'));
    fs.writeFileSync(path.join(root, 'memo.txt'), 'メモ');
    const known = path.join(root, '..', path.basename(root) + '-known.json');
    const srv = await (kind === 'sftp' ? servers.startSFTP : servers.startFTP)(root, { user: 'taro', password: 'ひみつ pw' });
    const server = { kind, host: '127.0.0.1', port: srv.port, user: 'taro', auth: 'password' };
    const c = remote.connect(server, 'ひみつ pw', known);
    try {
      const home = await c.home();
      assert.strictEqual(home, '/');
      assert.deepStrictEqual((await c.list('/')).map(e => e.name + (e.dir ? '/' : '')), ['www/', 'memo.txt']);
      const file = remote.joinPath('/www', 'index.html');
      const d = codec.decode(await c.read(file));
      assert.strictEqual(d.text, '<p>こんにちは</p>\n');
      assert.strictEqual(d.encoding, 'shiftJIS');
      await c.write(file, codec.encode(d.text + '<p>追記</p>\n', d.encoding, d.lineEnding));
      assert.strictEqual(codec.decode(fs.readFileSync(path.join(root, 'www', 'index.html'))).text, '<p>こんにちは</p>\n<p>追記</p>\n');
      await c.write('/www/新規.txt', Buffer.from('new'));
      await c.mkdir('/www/sub');
      await c.rename('/www/新規.txt', '/www/sub/moved.txt');
      assert.strictEqual(fs.readFileSync(path.join(root, 'www', 'sub', 'moved.txt'), 'utf8'), 'new');
      await c.remove('/www/sub/moved.txt', false);
      await c.remove('/www/sub', true);
      assert.deepStrictEqual((await c.list('/www')).map(e => e.name), ['index.html']);
      await assert.rejects(c.read('/nothing.txt'));
    } finally {
      c.close();
    }
    const wrong = remote.connect(server, 'ちがう', known);
    await assert.rejects(wrong.list('/'), /ログインできませんでした/);
    wrong.close();
    if (kind === 'sftp') {
      // サーバの鍵が変わったら (別のサーバが同じ場所にいたら) つながない
      const saved = JSON.parse(fs.readFileSync(known, 'utf8'));
      assert.ok(saved[`127.0.0.1:${srv.port}`].startsWith('SHA256:'));
      saved[`127.0.0.1:${srv.port}`] = 'SHA256:xxxx';
      fs.writeFileSync(known, JSON.stringify(saved));
      const other = remote.connect(server, 'ひみつ pw', known);
      await assert.rejects(other.list('/'), /鍵が前と違います/);
      other.close();
      remote.forgetHostKey(known, server);
      const again = remote.connect(server, 'ひみつ pw', known);
      assert.strictEqual((await again.list('/')).length, 2);
      again.close();
    }
    await srv.close();
    fs.rmSync(root, { recursive: true, force: true });
    assert.strictEqual(remote.joinPath('/a/b', '..'), '/a');
    assert.strictEqual(remote.joinPath('/', 'x'), '/x');
    assert.strictEqual(remote.url({ kind: 'sftp', host: 'h', port: 2222, user: 'u' }, '/a.txt'), 'sftp://u@h:2222/a.txt');
  });
}

test('AI のモデルと料金のマスタ: かんたん選択のモデルに料金があり、値段の変わる日も扱える', () => {
  const m = require('../shared/aimodels');
  for (const [provider, set] of Object.entries(m.PRESETS)) {
    for (const kind of ['fast', 'quality']) {
      const p = m.priceOf(set[kind]);
      assert.ok(p && p.input > 0 && p.output > 0, provider + ' ' + kind);
    }
    assert.ok(m.priceOf(set.fast).input <= m.priceOf(set.quality).input, provider + ': 最安のほうが安い');
    assert.ok(m.SOURCES[provider]);
  }
  assert.deepStrictEqual(m.priceOf('gemini-4-carbon', {}, new Date('2026-11-18T00:00:00Z')), { input: 2, output: 10 });
  assert.deepStrictEqual(m.priceOf('gemini-4-carbon', {}, new Date('2026-12-01T00:00:00Z')), { input: 4, output: 20 });
  assert.strictEqual(m.upcomingChange('gemini-4-carbon', new Date('2026-11-18T00:00:00Z')).from, '2026-12-01');
  assert.strictEqual(m.upcomingChange('gemini-4-carbon', new Date('2026-12-02T00:00:00Z')), null);
  assert.deepStrictEqual(m.priceOf('gpt-6-luna', { 'gpt-6-luna': [1, 2] }), { input: 1, output: 2 }, 'ai-prices.json の値が優先');
  assert.strictEqual(m.priceOf('models/gemini-3.1-flash-lite').input, 0.25);
  assert.strictEqual(m.priceOf('知らないモデル'), null);
  assert.ok(Math.abs(m.sampleCost({ input: 0.1, output: 0.5 }) - 0.0009) < 1e-12);
  const u = require('../core/aiusage');
  assert.strictEqual(u.cost({ inputTokens: 1000000, outputTokens: 1000000 }, 'openai', 'gpt-6-luna', { openai: { input: 9, output: 9 } }), 0.6, 'マスタにあるモデルはマスタの料金');
});

test('差分: Word の変更履歴のように、変わった字だけを消した・足したにする (Mac 版と同じ)', () => {
  const textdiff = require('../shared/textdiff');
  let r = textdiff.inline('今日は晴れです。\n明日も', '今日は雨です。\n明日も');
  assert.strictEqual(r.added, 1);
  assert.strictEqual(r.removed, 1);
  assert.strictEqual(r.segments.find(s => s.kind === 'removed').text, '晴れ');
  assert.strictEqual(r.segments.find(s => s.kind === 'added').text, '雨');
  const now = r.segments.filter(s => s.kind !== 'removed' && s.kind !== 'gap').map(s => s.text).join('');
  assert.strictEqual(now, '今日は雨です。\n明日も');
  r = textdiff.inline('a\nb', 'a\nNEW\nb');
  assert.strictEqual(r.segments.find(s => s.kind === 'added').text, 'NEW\n');
  assert.strictEqual(r.segments.find(s => s.kind === 'added').newLine, 2);
  assert.deepStrictEqual(textdiff.inline('abcdef', 'xyz').segments.map(s => s.kind), ['removed', 'added']);
  const old = Array.from({ length: 30 }, (_, i) => 'l' + (i + 1));
  const nw = old.slice(); nw[15] = 'CHANGED';
  r = textdiff.inline(old.join('\n'), nw.join('\n'), { context: 2 });
  assert.strictEqual(r.segments[0].kind, 'gap');
  assert.strictEqual(r.segments[r.segments.length - 1].kind, 'gap');
  // 行ごとに分けると、行番号は「いまの文書」の番号。消した行だけの行は番号なし
  const o = 'a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn'.split('\n');
  const m = o.slice(); m[1] = 'B2'; m.splice(4, 1); m.splice(10, 0, 'NEW');
  const rows = textdiff.toRows(textdiff.inline(o.join('\n'), m.join('\n'), { context: 1e9 }));
  assert.deepStrictEqual(rows.map(x => (x.removedOnly ? '-' : String(x.number))), ['1', '-', '2', '3', '4', '-', '5', '6', '7', '8', '9', '10', '11', '12', '13', '14']);
  // 同じなら空
  assert.strictEqual(textdiff.inline('x', 'x').segments.length, 0);
  // 大きな違いでも止まらない
  const big = Array.from({ length: 3000 }, (_, i) => 'x' + i).join('\n');
  const big2 = Array.from({ length: 3000 }, (_, i) => 'y' + i).join('\n');
  assert.ok(textdiff.inline(big, big2).removed === 3000);
});

test('AI の答え: ひとこと と 中身 (<result> / ``` ) に分ける (Mac 版と同じ)', () => {
  const ans = require('../shared/aianswer');
  let p = ans.split('誤字を 2 か所直しました。\n<result>\n  本文です。\n次の行\n</result>');
  assert.strictEqual(p.message, '誤字を 2 か所直しました。');
  assert.strictEqual(p.content, '  本文です。\n次の行');
  assert.ok(p.closed);
  assert.strictEqual(ans.split('ただの答えです').content, null);
  assert.strictEqual(ans.split('直しました。<res').message, '直しました。');
  p = ans.split('直しました。<result>本文</re');
  assert.strictEqual(p.content, '本文');
  assert.ok(!p.closed);
  p = ans.split('前<result>x</result>後のひとこと');
  assert.strictEqual(p.message, '前\n後のひとこと');
  p = ans.split('関数を書きました。\n```swift\nfunc a() {}\nlet b = 1\n```\n使ってみてください。');
  assert.strictEqual(p.message, '関数を書きました。\n使ってみてください。');
  assert.strictEqual(p.content, 'func a() {}\nlet b = 1');
  assert.strictEqual(ans.split('x<result>```a```</result>').content, '```a```');
});

test('言語の見当: 名前のない文書の中身から (Mac 版と同じ)', () => {
  const { guess } = require('../shared/langguess');
  assert.strictEqual(guess("<?php\necho 'hi';"), 'PHP');
  assert.strictEqual(guess('<!DOCTYPE html>\n<html></html>'), 'HTML / XML');
  assert.strictEqual(guess('function add(a, b) {\n  return a + b;\n}\nconsole.log(add(1, 2));'), 'JavaScript / TypeScript');
  assert.strictEqual(guess('def add(a, b):\n    return a + b\n\nprint(add(1, 2))'), 'Python');
  assert.strictEqual(guess('import SwiftUI\nstruct A: View {}'), 'Swift');
  assert.strictEqual(guess('package main\n\nfunc main() {\n\tx := 1\n}'), 'Go');
  assert.strictEqual(guess('#include <stdio.h>\nint main() { return 0; }'), 'C / C++ / Objective-C');
  assert.strictEqual(guess('#!/bin/bash\necho hi'), 'シェル');
  assert.strictEqual(guess('{"a": 1, "b": [1, 2]}'), 'JSON');
  assert.strictEqual(guess('SELECT name FROM users WHERE id = 1;'), 'SQL');
  assert.strictEqual(guess('body {\n  color: red;\n}'), 'CSS');
  assert.strictEqual(guess('fn main() {\n    let mut x = 1;\n    println!("{}", x);\n}'), 'Rust');
  assert.strictEqual(guess('今日はいい天気でした。\n明日も晴れるといいな。'), null);
  assert.strictEqual(guess(''), null);
});

test('ローカル LLM: 一覧・進み具合・名前・必要な Windows を読む (Mac 版と同じ)', () => {
  const llm = require('../shared/localllm');
  const list = llm.parseTags('{"models":[{"name":"gemma3:1b","size":815319791},{"model":"qwen2.5:3b","size":1929912432}]}');
  assert.deepStrictEqual(list.map(m => m.name), ['gemma3:1b', 'qwen2.5:3b']);
  assert.strictEqual(llm.parseTags('oops').length, 0);
  assert.strictEqual(llm.parseProgress('{"status":"pulling abc","total":1000,"completed":250}').fraction, 0.25);
  assert.strictEqual(llm.parseProgress('{"status":"success"}').done, true);
  assert.strictEqual(llm.parseProgress('{"error":"nope"}').error, 'nope');
  assert.strictEqual(llm.parseProgress('not json'), null);
  assert.ok(llm.sameModel('gemma3', 'gemma3:latest') && !llm.sameModel('gemma3:1b', 'gemma3:4b'));
  assert.ok(llm.isValidModelName('qwen2.5-coder:1.5b') && llm.isValidModelName('hf.co/user/model:Q4_K_M'));
  assert.ok(!llm.isValidModelName('x; rm -rf /') && !llm.isValidModelName(''));
  for (const r of llm.RECOMMENDED) assert.ok(llm.isValidModelName(r.name));
  assert.strictEqual(llm.sizeText(815319791), '0.8 GB');
  assert.strictEqual(llm.parseRequiredBuild('* Windows 10 22H2 or newer, Home or Pro'), 19045);
  assert.strictEqual(llm.parseRequiredBuild('nothing'), null);
  assert.strictEqual(llm.buildOf('10.0.19045'), 19045);
});

test('入力補完: 単語・関数・入れる形・引数の位置 (Mac 版と同じ)', () => {
  const c = require('../shared/completion');
  assert.deepStrictEqual(c.words('alpha beta be alpha 123abc gamma_1 $user'), ['alpha', 'beta', 'gamma_1', '$user']);
  const byName = Object.fromEntries(c.definedFunctions('function hello(name, age) {}\nconst add = (a, b) => a + b;\ndef greet(self, who="x"):\nfunc move(to point: CGPoint, animated: Bool) {}\nfunction &refFn($a) {}').map(f => [f.label, f.params]));
  assert.deepStrictEqual(byName.hello, ['name', 'age']);
  assert.deepStrictEqual(byName.add, ['a', 'b']);
  assert.deepStrictEqual(byName.greet, ['self', 'who="x"']);
  assert.deepStrictEqual(byName.move, ['to point: CGPoint', 'animated: Bool']);
  assert.deepStrictEqual(byName.refFn, ['$a']);
  const sub = c.fn('substr(string, offset, length)');
  assert.deepStrictEqual(c.insertion(sub, null, 'PHP'), { text: 'substr()', caret: 7 });
  assert.deepStrictEqual(c.insertion(sub, '(', 'PHP'), { text: 'substr', caret: 6 });
  assert.deepStrictEqual(c.insertion(c.fn('time()'), null, 'PHP'), { text: 'time()', caret: 6 });
  assert.deepStrictEqual(c.insertion({ label: 'div', kind: 'tag', params: [] }, null, 'HTML / XML'), { text: 'div></div>', caret: 4 });
  assert.deepStrictEqual(c.insertion({ label: 'br', kind: 'tag', params: [] }, null, 'HTML / XML'), { text: 'br>', caret: 3 });
  assert.deepStrictEqual(c.insertion({ label: 'color', kind: 'property', params: [] }, null, 'CSS'), { text: 'color: ;', caret: 7 });
  const ctx = s => c.callContext(s, s.length);
  assert.strictEqual(ctx('substr($s, ').name, 'substr');
  assert.strictEqual(ctx('substr($s, ').argIndex, 1);
  assert.strictEqual(ctx('foo(bar(1, 2), ').name, 'foo');
  assert.strictEqual(ctx('foo(bar(1, 2), ').argIndex, 1);
  assert.strictEqual(ctx('foo("a, b", ').argIndex, 1);
  assert.strictEqual(ctx('foo(bar(').name, 'bar');
  assert.strictEqual(ctx('foo(1); x'), null);
  assert.strictEqual(ctx('if (a, '), null);
  assert.ok(c.libraryItems('JavaScript / TypeScript').some(i => i.label === 'JSON.stringify' && i.params.length === 3));
  assert.ok(c.libraryItems('PHP').some(i => i.label === 'str_replace'));
  assert.ok(c.libraryItems('HTML / XML').some(i => i.label === 'div' && i.kind === 'tag'));
  assert.deepStrictEqual(c.splitParams('a, b = (1, 2), ...rest'), ['a', 'b = (1, 2)', '...rest']);
});

test('zip を読む: 作ったものを読み戻せ、フォルダの外へ出る名前は断る', () => {
  const zip = require('../core/zip');
  const made = zip.make([{ name: 'repo-main/manifest.json', data: Buffer.from('{"id":"x"}') }, { name: 'repo-main/main.js', data: Buffer.from('satoru;'.repeat(200)) }]);
  const back = zip.extract(made);
  assert.deepStrictEqual(back.map(e => e.name), ['repo-main/manifest.json', 'repo-main/main.js']);
  assert.strictEqual(back[1].data.toString(), 'satoru;'.repeat(200));
  const evil = zip.make([{ name: '../evil.js', data: Buffer.from('x') }]);
  assert.throws(() => zip.extract(evil), /unsafe/);
  assert.throws(() => zip.extract(Buffer.from('not a zip at all, definitely not')), /not a zip/);
});

test('拡張機能の manifest: 読む・断る・版・URL・ショートカット (Mac 版と同じ)', () => {
  const pm = require('../shared/pluginmanifest');
  const m = pm.parse('{"id":"date-stamp","name":"日付","version":"1.2.0","permissions":["network"],"icon":"📅"}');
  assert.strictEqual(m.name, '日付');
  assert.strictEqual(m.main, 'main.js');
  assert.ok(pm.has(m, 'network') && !pm.has(m, 'clipboard'));
  for (const bad of ['{"name":"x"}', '{"id":"../evil"}', '{"id":"Upper"}', '{"id":"ok","permissions":["files"]}', '{"id":"ok","main":"../../x.js"}', '{"id":"ok","main":"/etc/x.js"}', 'not json']) {
    assert.throws(() => pm.parse(bad), bad);
  }
  assert.strictEqual(pm.compareVersions('1.2.10', '1.2.9'), 1);
  assert.strictEqual(pm.compareVersions('1.0', '1.0.0'), 0);
  assert.strictEqual(pm.compareVersions('0.9.1', '1.0.0'), -1);
  assert.strictEqual(pm.downloadURL('https://github.com/u/r'), 'https://github.com/u/r/archive/HEAD.zip');
  assert.strictEqual(pm.downloadURL('github.com/u/r.git'), 'https://github.com/u/r/archive/HEAD.zip');
  assert.strictEqual(pm.downloadURL('https://github.com/u/r/tree/dev'), 'https://github.com/u/r/archive/refs/heads/dev.zip');
  assert.strictEqual(pm.downloadURL('https://example.com/p.zip'), 'https://example.com/p.zip');
  assert.strictEqual(pm.downloadURL('file:///etc/passwd'), null);
  assert.strictEqual(pm.downloadURL('hello'), null);
  assert.strictEqual(pm.accelOf(pm.parseShortcut('cmd+shift+D')), 'Ctrl+Shift+D');
  assert.strictEqual(pm.parseShortcut('d'), null);
  assert.strictEqual(pm.parseShortcut('cmd+hyper+d'), null);
});

test('バイナリの見分けと 16 進の表示 (Mac 版と同じ)', () => {
  const bin = require('../shared/binary');
  assert.ok(!bin.looksBinary(Buffer.from('こんにちは\nhello\tworld\r\n')));
  assert.ok(!bin.looksBinary(Buffer.alloc(0)));
  assert.ok(!bin.looksBinary(Buffer.from('\u001b[31mred\u001b[0m\n')));
  assert.ok(!bin.looksBinary(Buffer.from('plain ascii text in utf16', 'utf16le')));
  assert.ok(bin.looksBinary(Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52])));
  assert.ok(bin.looksBinary(Buffer.from(Array.from({ length: 200 }, (_, i) => 1 + (i % 8)))));
  const d = Buffer.from('Hello, world!\n\u0000\u0001ABC');
  const l0 = bin.line(d, 0);
  assert.strictEqual(l0.offset, '00000000');
  assert.strictEqual(l0.hex, '48 65 6C 6C 6F 2C 20 77  6F 72 6C 64 21 0A 00 01');
  assert.strictEqual(l0.ascii, 'Hello, world!...');
  const l1 = bin.line(d, 16);
  assert.strictEqual(l1.offset, '00000010');
  assert.ok(l1.hex.startsWith('41 42 43 '));
  assert.strictEqual(l0.hex.length, l1.hex.length);
  assert.strictEqual(bin.lineCount(d.length), 2);
  assert.strictEqual(bin.imageType('a/b.PNG'), 'image/png');
  assert.strictEqual(bin.imageType('x.svg'), null);
});

test('共同編集の暗号: Mac 版が書いた 5 通を開け、順番違い・コード違い・改ざんは受け付けない', () => {
  const { CollabCipher, newCode, normalize, ALPHABET } = require('../core/collabcipher');
  const lines = fx('mac-collab.txt').toString('utf8').split('\n');
  const guestSide = new CollabCipher('AB2C DEFG hjkm-npqr', false), hostSide = new CollabCipher('ab2cdefghjkmnpqr', true);
  const got = lines.map(l => { const p = (l[0] === 'H' ? guestSide : hostSide).open(l.slice(2)); return p && JSON.parse(p.toString('utf8')); });
  assert.deepStrictEqual(got, [{ t: 'welcome', text: 'こんにちは😀' }, { t: 'op', loc: 1 }, { t: 'bye' }, { t: 'hello', name: 'Mac' }, { t: 'chat', text: 'やあ' }]);
  // 順番を入れ替えた・同じものをもう一度・別のコード・1 文字変えたものは開けない
  const g2 = new CollabCipher('AB2CDEFGHJKMNPQR', false);
  assert.strictEqual(g2.open(lines[1].slice(2)), null);
  const g3 = new CollabCipher('AB2CDEFGHJKMNPQR', false);
  assert.ok(g3.open(lines[0].slice(2)));
  assert.strictEqual(g3.open(lines[0].slice(2)), null);
  assert.strictEqual(new CollabCipher('ZZZZDEFGHJKMNPQR', false).open(lines[0].slice(2)), null);
  const b = Buffer.from(lines[0].slice(2), 'base64'); b[20] ^= 1;
  assert.strictEqual(new CollabCipher('AB2CDEFGHJKMNPQR', false).open(b.toString('base64')), null);
  // ホストとゲストの往復 (はね返しは開けない)
  const host = new CollabCipher('k', true), guest = new CollabCipher('k', false);
  const line = host.seal(Buffer.from('{"t":"op"}'));
  assert.ok(!line.includes('\n'));
  assert.strictEqual(new CollabCipher('k', true).open(line), null, '自分の向きの鍵では開けない');
  assert.strictEqual(guest.open(line).toString(), '{"t":"op"}');
  const code = newCode();
  assert.ok(/^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$/.test(code));
  assert.ok(Array.from(normalize(code)).every(c => ALPHABET.includes(c)) && normalize(code).length === 16);
});

test('共同編集のすり合わせ: どちらの順に反映しても同じ文章になる (ゲスト 2 人 + ホストを乱数で)', () => {
  const ot = require('../shared/collabot');
  const [a2, b2] = ot.transform(ot.op(3, 4, 'XY'), ot.op(5, 0, 'あ'), true);
  assert.deepStrictEqual([a2, b2], [ot.op(3, 5, 'XY'), ot.op(0, 0, '')], 'Mac 版と同じ結果');
  // 乱数で同時に編集して、最後に全員の文章がそろうか
  let seed = 12345;
  const rand = n => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n; };
  for (let round = 0; round < 300; round++) {
    const server = new ot.OTServer();
    let hostText = 'あいうえおかきくけこ0123456789';
    const guests = [0, 1].map(() => ({ text: hostText, client: new ot.OTClient(0), inbox: [] }));
    const randomOp = s => { const loc = rand(s.length + 1); const len = rand(Math.min(4, s.length - loc) + 1); return ot.op(loc, len, ['', 'X', 'YZ', '😀', 'ん'][rand(5)]); };
    const sent = [];
    const broadcast = (o, rev, author) => guests.forEach((g, i) => g.inbox.push({ o, rev, author }));
    for (let step = 0; step < 12; step++) {
      const who = rand(3);
      if (who === 2) { const o = randomOp(hostText); hostText = ot.apply(o, hostText); broadcast(o, server.localEdit(o), 'host'); continue; }
      const g = guests[who];
      if (rand(2) === 0 && g.inbox.length) {
        const m = g.inbox.shift();
        if (m.author === who) { const next = g.client.acknowledged(m.rev); if (next) sent.push({ who, ...next }); }
        else g.text = ot.apply(g.client.remote(m.o, m.rev), g.text);
        continue;
      }
      const o = randomOp(g.text);
      g.text = ot.apply(o, g.text);
      const s = g.client.localEdit(o);
      if (s) sent.push({ who, ...s });
      if (sent.length && rand(2) === 0) {
        const m = sent.shift();
        const r = server.receive(m.op, m.baseRevision);
        hostText = ot.apply(r.op, hostText);
        broadcast(r.op, r.revision, m.who);
      }
    }
    // 残りをすべて届ける
    for (let guard = 0; guard < 1000 && (sent.length || guests.some(g => g.inbox.length)); guard++) {
      if (sent.length) { const m = sent.shift(); const r = server.receive(m.op, m.baseRevision); hostText = ot.apply(r.op, hostText); broadcast(r.op, r.revision, m.who); }
      guests.forEach((g, who) => {
        while (g.inbox.length) {
          const m = g.inbox.shift();
          if (m.author === who) { const next = g.client.acknowledged(m.rev); if (next) sent.push({ who, ...next }); }
          else g.text = ot.apply(g.client.remote(m.o, m.rev), g.text);
        }
      });
    }
    guests.forEach((g, i) => assert.strictEqual(g.text, hostText, `回 ${round} ゲスト ${i}`));
  }
  assert.strictEqual(ot.transformPosition(ot.op(2, 3, 'ab'), 10), 9);
  assert.strictEqual(ot.transformPosition(ot.op(2, 3, 'ab'), 3), 4);
});

test('共同編集の通信: 正しいコードならやりとりでき、違うコードはすぐ切れる', async () => {
  const net = require('../core/collabnet');
  const { newCode } = require('../core/collabcipher');
  const code = newCode();
  const log = [];
  let hostLink;
  const hostDone = new Promise(resolve => {
    net.host(0, code, {
      onOpen: (id, addr) => log.push('open ' + id + ' ' + addr),
      onMessage: (id, msg) => { log.push('host got ' + JSON.stringify(msg)); hostLink.send(id, { t: 'welcome', id: 1, text: '共有の文章😀' }); },
      onClose: (id, info) => { log.push('host close ' + id + ' ' + info.decryptFailed); resolve(); },
    }).then(l => { hostLink = l; startGuests(l.port); });
  });
  let startGuests;
  const guestsReady = new Promise(r => { startGuests = r; });
  const port = await guestsReady;
  const got = await new Promise(resolve => {
    const g = net.join('127.0.0.1', port, code.toLowerCase(), {
      onOpen: () => g.send(0, { t: 'hello', v: 1, name: 'テスト' }),
      onMessage: (id, msg) => { resolve(msg); g.close(); },
      onClose: () => {},
    });
  });
  assert.deepStrictEqual(got, { t: 'welcome', id: 1, text: '共有の文章😀' });
  await hostDone;
  // 違うコード: ホストは 1 通目で切り、ゲストには「何も復号できないまま切れた」と伝わる
  const info = await new Promise(resolve => {
    const g = net.join('127.0.0.1', port, 'ZZZZ-ZZZZ-ZZZZ-ZZZZ', {
      onOpen: () => g.send(0, { t: 'hello', v: 1, name: 'x' }),
      onMessage: () => resolve('unexpected'),
      onClose: (id, i) => resolve(i),
    });
  });
  assert.strictEqual(info.decryptedAny, false);
  // つながらない相手
  const refused = await new Promise(resolve => net.join('127.0.0.1', 1, code, { onOpen() {}, onMessage() {}, onClose: (id, i) => resolve(i) }));
  assert.strictEqual(refused.decryptedAny, false);
  hostLink.stop();
  assert.ok(log.includes('host got {"t":"hello","v":1,"name":"テスト"}'));
  assert.ok(Array.isArray(net.localAddresses()));
});

test('個人情報の点検: 電話・メール・郵便番号・パスワード・名前を見つけ、真ん中を伏せる (Mac 版と同じ)', () => {
  const privacy = require('../shared/privacyscan');
  const text = '連絡先 090-1234-5678\nメール taro@example.com\n〒123-4567 東京都新宿区西新宿2-8-1\npassword: hunter22\n氏名: 山田花子\n';
  const kinds = privacy.scan(text).map(f => f.kind);
  for (const k of ['電話番号', 'メールアドレス', '郵便番号', 'パスワード', '名前']) assert.ok(kinds.includes(k), k);
  const tel = privacy.scan(text).find(f => f.kind === '電話番号');
  assert.strictEqual(text.slice(tel.from, tel.to), '090-1234-5678');
  assert.ok(tel.sample.includes('＊'));
  assert.deepStrictEqual(privacy.scan('今日はいい天気です。'), []);
});
test('版: package.json・本体 (AssemblyInfo)・exe の manifest がそろっている', () => {
  const ver = require('../package.json').version;
  const read = f => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');
  const info = read('host/src/AssemblyInfo.cs');
  assert.ok(/^\d+\.\d+\.\d+$/.test(ver), ver);
  assert.ok(info.includes(`AssemblyInformationalVersion("${ver}")`), 'AssemblyInformationalVersion');
  assert.ok(info.includes(`AssemblyVersion("${ver}.0")`), 'AssemblyVersion');
  assert.ok(info.includes(`AssemblyFileVersion("${ver}.0")`), 'AssemblyFileVersion');
  for (const f of ['host/app.manifest', 'installer/app.manifest']) assert.ok(read(f).includes(`assemblyIdentity version="${ver}.0"`), f);
});

test('アップデート: 設定の既定 (自動で確認はオン)・メニューの項目', () => {
  const store = fs.readFileSync(path.join(__dirname, '..', 'host', 'src', 'Store.cs'), 'utf8');
  assert.ok(store.includes('""autoUpdateCheck"": true'));
  assert.ok(store.includes('""updateSkipVersion"": """"'));
  const menu = require('../shared/menu');
  const ids = menu.flatten(menu.build({ prefs: {} })).map(m => m.id);
  assert.ok(ids.includes('app.checkUpdate'));
});

test('横書きの原稿用紙: 縦書きの用紙を回した形 (A4 縦・真ん中の余白なし・緑の線)', () => {
  assert.strictEqual(genko.point(10, 20, true).join(','), '20,287');
  const xs = Array.from({ length: 20 }, (_, k) => genko.columnXOf(k, true));
  for (let k = 1; k < 20; k++) assert.strictEqual(xs[k - 1] - xs[k], genko.SHEET.pitch); // 行は等しい間隔 (真ん中の余白なし)
  assert.ok(genko.sheetSVG(true).includes(genko.LINE_H) && genko.sheetSVG(true).includes('viewBox="0 0 210 297"'));
  assert.ok(genko.sheetSVG(false).includes('viewBox="0 0 297 210"'));
});

(async () => {
  const out = process.argv[2];
  if (out) {
    fs.writeFileSync(path.join(out, 'win-password.enc'), fc.seal(PLAIN, await fc.deriveKey('ひみつのpassword', { iterations: 20000 })));
    fs.writeFileSync(path.join(out, 'win-passcode.enc'), fc.seal(PLAIN, await fc.deriveKey('123456', { iterations: 20000, kind: 'passcode' })));
    const kf = fc.newKeyFileContents();
    fs.writeFileSync(path.join(out, 'win.satorukey'), kf);
    fs.writeFileSync(path.join(out, 'win-keyfile.enc'), fc.seal(PLAIN, fc.keyFileKey(fc.keyFileSecret(kf))));
    fs.writeFileSync(path.join(out, 'win-twostep.enc'), fc.seal(PLAIN, await fc.twoStepKey('pw-two-step', SECRET, { iterations: 20000 })));
    for (const e of codec.ENCODINGS) fs.writeFileSync(path.join(out, `win-${e.id}.txt`), codec.encode(SAMPLE, e.id, 'crlf'));
    const { CollabCipher } = require('../core/collabcipher');
    const host = new CollabCipher('ab2c-defg-hjkm-npqr', true), guest = new CollabCipher('AB2CDEFGHJKMNPQR', false);
    fs.writeFileSync(path.join(out, 'win-collab.txt'), [
      'H ' + host.seal(Buffer.from(JSON.stringify({ t: 'welcome', text: 'Windows から😀' }))),
      'H ' + host.seal(Buffer.from(JSON.stringify({ t: 'bye' }))),
      'G ' + guest.seal(Buffer.from(JSON.stringify({ t: 'hello', name: 'Windows PC' }))),
    ].join('\n'));
    console.log('見本を書き出しました:', out);
    return;
  }
  let failed = 0;
  for (const [name, fn] of tests) {
    try {
      await fn();
      console.log('  ok  ' + name);
    } catch (e) {
      failed += 1;
      console.log('  NG  ' + name + '\n      ' + String((e && e.stack) || e).split('\n').slice(0, 6).join('\n      '));
    }
  }
  console.log(`${tests.length} 件中 ${tests.length - failed} 件成功、${failed} 件失敗`);
  process.exit(failed ? 1 : 0);
})();
