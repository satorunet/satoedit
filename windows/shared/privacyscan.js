'use strict';
// うっかり個人情報を公開しないための、手元だけでの点検 (どこにも送らない)。Mac 版 PrivacyScan.swift と同じ探し方。
// 電話番号・メールアドレス・郵便番号と住所・パスワードらしき書き方・カード番号・マイナンバーらしき数字・人の名前らしきもの を探す

// よくある名字 (上位。林・森・原のような 1 字のものは、ふつうの言葉と見分けにくいので入れない)
const SURNAMES = ['佐藤', '鈴木', '高橋', '田中', '伊藤', '渡辺', '山本', '中村', '小林', '加藤', '吉田', '山田', '佐々木', '山口',
  '松本', '井上', '木村', '斎藤', '清水', '山崎', '池田', '橋本', '阿部', '石川', '山下', '中島', '石井',
  '小川', '前田', '岡田', '長谷川', '藤田', '後藤', '近藤', '村上', '遠藤', '青木', '坂本', '斉藤', '福田', '太田',
  '西村', '藤井', '金子', '岡本', '藤原', '中野', '三浦', '原田', '中川', '松田', '竹内', '小野', '田村', '中山',
  '和田', '石田', '森田', '上田', '内田', '柴田', '酒井', '宮崎', '横山', '高木', '安藤', '宮本', '大野',
  '小島', '工藤', '谷口', '今井', '高田', '丸山', '増田', '杉山', '村田', '大塚', '小山', '平野', '藤本', '久保',
  '松井', '千葉', '岩崎', '桜井', '木下', '野口', '松尾', '菊地', '野村', '新井', '渡部', '矢野'];

/// 真ん中を伏せる (確認の画面にそのまま出さないように)
function masked(s) {
  const c = Array.from(s);
  if (c.length <= 4) return s;
  const keep = Math.max(2, Math.floor(c.length / 4));
  return c.slice(0, keep).join('') + '＊'.repeat(Math.min(8, c.length - keep * 2)) + c.slice(c.length - keep).join('');
}

/// 見つけたもの [{ kind, sample, from, to }] (種類ごとに 3 つまで、本文の中の位置の順)。names: 必ず探す名前 (Windows の利用者名など)
function scan(text, names = []) {
  const out = [];
  const add = (kind, pattern, flags = '', mask = true, group = 0) => {
    const re = new RegExp(pattern, 'g' + flags);
    let n = 0, m;
    while ((m = re.exec(text)) !== null) {
      if (m[0] === '') { re.lastIndex += 1; continue; }
      const raw = m[group];
      if (raw === undefined) continue;
      const at = m.index + (group ? m[0].indexOf(raw) : 0);
      const s = raw.trim();
      const sample = mask ? masked(s) : s;
      if (!s || out.some(f => f.kind === kind && f.sample === sample)) continue;
      // 前後の空白は選ぶ範囲に入れない
      const lead = raw.indexOf(s);
      const from = at + (lead < 0 ? 0 : lead);
      out.push({ kind, sample, from, to: from + s.length });
      n += 1;
      if (n >= 3) break;
    }
  };
  // 電話番号: 0 から始まる 10〜11 桁 (ハイフン・括弧・空白あり)、+81 から始まるもの
  add('電話番号', '(?<![0-9０-９])(?:\\+81[-\\s]?|0)[0-9０-９]{1,4}[-ー－(（\\s)）]{0,2}[0-9０-９]{1,4}[-ー－\\s]?[0-9０-９]{3,4}(?![0-9０-９])');
  add('メールアドレス', '[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}');
  add('郵便番号', '(?:〒\\s?|(?<![0-9０-９\\-ー－]))[0-9０-９]{3}[-ー－][0-9０-９]{4}(?![0-9０-９\\-ー－])'); // 電話番号の途中は拾わない
  // 住所: 都道府県 + 市区町村 + 番地らしき数字
  add('住所', '(?:北海道|東京都|京都府|大阪府|[^\\s　、。]{2,3}県)[^\\s　、。]{1,12}?[市区町村郡][^\\s　、。]{0,16}?[0-9０-９一二三四五六七八九十]+(?:丁目|番地?|号|[-ー－])');
  // パスワード・暗証番号・API キーなどの書き方
  add('パスワード', '(?:パスワード|パスコード|暗証番号|password|passwd|pwd|pass|api[_\\s-]?key|secret|token)\\s*[:：=＝は]\\s*\\S{3,}', 'i');
  add('カード番号', '(?<![0-9])(?:[0-9]{4}[-\\s]?){3}[0-9]{4}(?![0-9])');
  add('マイナンバーらしき番号', '(?<![0-9０-９])[0-9０-９]{4}[\\s-]?[0-9０-９]{4}[\\s-]?[0-9０-９]{4}(?![0-9０-９])');
  // 名前: 「氏名」「名前」の欄、よくある名字 + 名前
  add('名前', '(?:氏名|名前|お名前|本名)\\s*[:：は]\\s*([^\\s　、。\\n]{2,10})', '', true, 1);
  add('名前', '(?:' + SURNAMES.join('|') + ')[\\s　]?[一-龥ぁ-ゖ]{1,3}(?=\\s|　|$|さん|くん|ちゃん|様|さま|先生|氏|君|\\n|、|。|の|が|は|と)', 'm', false);
  for (const name of names) {
    if (Array.from(name).length < 2) continue;
    const at = text.indexOf(name);
    if (at >= 0 && !out.some(f => f.sample === name)) out.push({ kind: '名前', sample: name, from: at, to: at + name.length });
  }
  // マイナンバーとカード番号・電話番号が同じ数字を拾ったら、ひとつにする
  const seen = new Set();
  return out.filter(f => { const k = f.kind + '\u0000' + f.sample; if (seen.has(k)) return false; seen.add(k); return true; }).sort((a, b) => a.from - b.from);
}

module.exports = { scan, masked, SURNAMES };
