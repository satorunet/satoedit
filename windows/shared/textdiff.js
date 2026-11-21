'use strict';
// 2 つの文章の違い (差分表示用)。Mac 版の TextDiff と同じ考え方:
// 行ごとに比べ、変わった塊の中は 1 文字ずつ比べる。似ていないときは「全部消して、全部足した」にする

/// a と b の違い。消した a の位置と、足した b の位置を返す (Myers の方法)。
/// 違いが多すぎるときは、共通の頭と終わりを除いた真ん中を、まるごと入れ替えたものとする
function diffArrays(a, b, maxD = 4000) {
  const removed = new Set(), inserted = new Set();
  let start = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) start++;
  let endA = a.length, endB = b.length;
  while (endA > start && endB > start && a[endA - 1] === b[endB - 1]) { endA--; endB--; }
  const n = endA - start, m = endB - start;
  if (n === 0 && m === 0) return { removed, inserted };
  const all = () => {
    for (let i = start; i < endA; i++) removed.add(i);
    for (let j = start; j < endB; j++) inserted.add(j);
    return { removed, inserted };
  };
  if (n === 0 || m === 0) return all();
  const max = n + m, off = max + 1;
  let v = new Int32Array(2 * max + 3);
  const trace = [];
  let found = -1;
  for (let d = 0; d <= Math.min(max, maxD); d++) {
    trace.push(v.slice());
    for (let k = -d; k <= d; k += 2) {
      let x = (k === -d || (k !== d && v[off + k - 1] < v[off + k + 1])) ? v[off + k + 1] : v[off + k - 1] + 1;
      let y = x - k;
      while (x < n && y < m && a[start + x] === b[start + y]) { x++; y++; }
      v[off + k] = x;
      if (x >= n && y >= m) { found = d; break; }
    }
    if (found >= 0) break;
  }
  if (found < 0) return all();
  // たどり直して、消した・足した所を集める
  let x = n, y = m;
  for (let d = found; d > 0; d--) {
    const pv = trace[d];
    const k = x - y;
    const prevK = (k === -d || (k !== d && pv[off + k - 1] < pv[off + k + 1])) ? k + 1 : k - 1;
    const prevX = pv[off + prevK], prevY = prevX - prevK;
    while (x > prevX && y > prevY) { x--; y--; }
    if (x === prevX) inserted.add(start + prevY); else removed.add(start + prevX);
    x = prevX; y = prevY;
  }
  return { removed, inserted };
}

function lines(s) { return s.split('\n').map(l => (l.endsWith('\r') ? l.slice(0, -1) : l)); }

/// Word の変更履歴のように見せるための並び: [{ kind: 'same'|'removed'|'added'|'gap', text, newLine, skipped }]
/// newLine はその部分が始まる、いまの文書での行番号 (1 始まり)
function inline(oldText, newText, { context = 2, maxLines = 200000 } = {}) {
  if (oldText === newText) return { segments: [], added: 0, removed: 0, tooLarge: false };
  const a = lines(oldText), b = lines(newText);
  if (a.length + b.length > maxLines) return { segments: [], added: 0, removed: 0, tooLarge: true };
  const { removed, inserted } = diffArrays(a, b);
  const pieces = [];
  let i = 0, j = 0;
  while (i < a.length || j < b.length) {
    if ((i < a.length && removed.has(i)) || (j < b.length && inserted.has(j))) {
      const olds = [], news = [], startLine = j + 1;
      while ((i < a.length && removed.has(i)) || (j < b.length && inserted.has(j))) {
        while (i < a.length && removed.has(i)) olds.push(a[i++]);
        while (j < b.length && inserted.has(j)) news.push(b[j++]);
      }
      pieces.push({ change: true, olds, news, line: startLine });
    } else if (i < a.length && j < b.length) {
      pieces.push({ change: false, text: b[j], line: j + 1 }); i++; j++;
    } else break;
  }
  const keep = new Array(pieces.length).fill(false);
  pieces.forEach((p, k) => { if (p.change) for (let x = Math.max(0, k - context); x <= Math.min(pieces.length - 1, k + context); x++) keep[x] = true; });
  const out = [];
  const emit = (kind, text, line) => {
    if (!text) return;
    const last = out[out.length - 1];
    if (last && last.kind === kind && kind !== 'gap') last.text += text;
    else out.push({ kind, text, newLine: line, skipped: 0 });
  };
  for (let k = 0; k < pieces.length;) {
    if (!keep[k]) {
      let e = k;
      while (e < pieces.length && !keep[e]) e++;
      out.push({ kind: 'gap', text: '', newLine: pieces[k].line, skipped: e - k });
      k = e;
      continue;
    }
    const p = pieces[k];
    if (!p.change) emit('same', p.text + '\n', p.line);
    else inlineChange(p.olds.join('\n'), p.news.join('\n'), p.olds.length > 0, p.news.length > 0, p.line, emit);
    k++;
  }
  const last = out[out.length - 1];
  if (last && last.kind === 'same' && last.text.endsWith('\n')) {
    last.text = last.text.slice(0, -1);
    if (!last.text) out.pop();
  }
  return { segments: out, added: inserted.size, removed: removed.size, tooLarge: false };
}

function inlineChange(oldS, newS, hasOld, hasNew, line, emit) {
  const x = Array.from(oldS), y = Array.from(newS);
  if (hasOld && hasNew && x.length + y.length <= 6000) {
    const { removed: rem, inserted: ins } = diffArrays(x, y, 1500);
    const common = x.length - rem.size;
    if (common >= 0.5 * Math.max(x.length, y.length)) {
      let i = 0, j = 0;
      while (i < x.length || j < y.length) {
        if (i < x.length && rem.has(i)) emit('removed', x[i++], line);
        else if (j < y.length && ins.has(j)) emit('added', y[j++], line);
        else if (i < x.length && j < y.length) { emit('same', y[j], line); i++; j++; }
        else break;
      }
      emit('same', '\n', line);
      return;
    }
  }
  if (hasOld) emit('removed', oldS + '\n', line);
  if (hasNew) emit('added', newS + '\n', line);
}

/// 表示用に 1 行ずつへ分ける: [{ gap, parts: [[kind, text]], removedOnly, number }]
function toRows(result) {
  const rows = [{ parts: [], newline: null }];
  for (const seg of result.segments) {
    if (seg.kind === 'gap') {
      if (rows[rows.length - 1].parts.length) rows.push({ parts: [], newline: null });
      rows[rows.length - 1].gap = seg;
      rows.push({ parts: [], newline: null });
      continue;
    }
    let rest = seg.text;
    let nl;
    while ((nl = rest.indexOf('\n')) >= 0) {
      if (nl > 0) rows[rows.length - 1].parts.push([seg.kind, rest.slice(0, nl)]);
      rows[rows.length - 1].newline = seg.kind;
      rows.push({ parts: [], newline: null });
      rest = rest.slice(nl + 1);
    }
    if (rest) rows[rows.length - 1].parts.push([seg.kind, rest]);
  }
  const lastRow = rows[rows.length - 1];
  if (lastRow && !lastRow.parts.length && !lastRow.gap) rows.pop();
  let lineNo = result.segments.length ? result.segments[0].newLine : 1;
  for (const r of rows) {
    if (r.gap) { r.number = r.gap.newLine; lineNo = r.gap.newLine + r.gap.skipped; continue; }
    r.removedOnly = (r.parts.length > 0 && r.parts.every(p => p[0] === 'removed') && (r.newline === null || r.newline === 'removed'))
      || (r.parts.length === 0 && r.newline === 'removed');
    r.number = lineNo;
    if (!r.removedOnly) lineNo++;
  }
  return rows;
}

module.exports = { diffArrays, inline, toRows, lines };
