'use strict';
// AI の答えを「ユーザーへのひとこと」と「文章に入れる中身」に分ける (Mac 版の AIAnswerParts と同じ)。
// 中身は <result> … </result> で囲んで返してもらう。囲みがなくても ``` のコードの塊があれば、それを中身にする
const OPEN = '<result>', CLOSE = '</result>';

const trim = s => s.trim();
/// 中身は前後の改行 1 つずつだけ落とす (行頭の空白などは中身なので残す)
function trimNewlines(s) {
  let t = s;
  if (t.startsWith('\r\n')) t = t.slice(2); else if (t.startsWith('\n')) t = t.slice(1);
  if (t.endsWith('\r\n')) t = t.slice(0, -2); else if (t.endsWith('\n')) t = t.slice(0, -1);
  return t;
}
/// 末尾にある「書きかけの目印」(例: "<res") を落とす
function dropPartial(s, mark) {
  for (let k = mark.length - 1; k >= 1; k--) if (s.endsWith(mark.slice(0, k))) return s.slice(0, -k);
  return s;
}

function splitFenced(text) {
  const start = text.indexOf('```');
  if (start < 0) return null;
  const before = text.slice(0, start);
  const after = text.slice(start + 3);
  const nl = after.indexOf('\n');
  if (nl < 0) return { message: trim(before), content: '', closed: false };
  const body = after.slice(nl + 1);
  const end = body.indexOf('```');
  if (end >= 0) {
    let code = body.slice(0, end);
    if (code.endsWith('\n')) code = code.slice(0, -1);
    const message = [trim(before), trim(body.slice(end + 3))].filter(Boolean).join('\n');
    return { message, content: code, closed: true };
  }
  let code = body;
  for (const k of [2, 1]) if (code.endsWith('`'.repeat(k))) { code = code.slice(0, -k); break; }
  return { message: trim(before), content: code, closed: false };
}

/// 届いている途中の文でも分けられる。{ message, content (なければ null), closed }
function split(text) {
  const o = text.indexOf(OPEN);
  if (o < 0) {
    const fenced = splitFenced(text);
    if (fenced) return fenced;
    return { message: trim(dropPartial(text, OPEN)), content: null, closed: false };
  }
  const before = text.slice(0, o);
  const rest = text.slice(o + OPEN.length);
  const c = rest.indexOf(CLOSE);
  if (c >= 0) {
    const message = [trim(before), trim(rest.slice(c + CLOSE.length))].filter(Boolean).join('\n');
    return { message, content: trimNewlines(rest.slice(0, c)), closed: true };
  }
  return { message: trim(before), content: trimNewlines(dropPartial(rest, CLOSE)), closed: false };
}

module.exports = { split, OPEN, CLOSE };
