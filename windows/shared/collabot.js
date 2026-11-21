'use strict';
// 共同編集のすり合わせ (Operational Transformation)。Mac 版 CollabOT.swift と同じ決まり。
// 位置はどれも UTF-16 の単位 (JavaScript の文字列の位置と同じ)。

/// 1 回分の変更: loc から len 文字を text に置き換える
function op(loc, len, text) { return { loc, len, text: text || '' }; }
const noop = () => op(0, 0, '');
const isNoop = o => o.len === 0 && o.text.length === 0;
const end = o => o.loc + o.len;
const delta = o => o.text.length - o.len;
const shifted = (o, d) => op(o.loc + d, o.len, o.text);

function apply(o, s) {
  const l = Math.max(0, Math.min(o.loc, s.length));
  return s.slice(0, l) + o.text + s.slice(l + Math.max(0, Math.min(o.len, s.length - l)));
}

/// この変更のあと、位置 p はどこへ動くか (カーソル位置の追従用)
function transformPosition(o, p) {
  if (p <= o.loc) return p;
  if (p >= end(o)) return p + delta(o);
  return o.loc + o.text.length;
}

/// 同じ状態に対して同時に行われた 2 つの変更をすり合わせる。
/// 結果 [a', b'] は「b のあとに a'」「a のあとに b'」がどちらも同じ文章になる。aWins: 同じ位置への挿入などで a を先 (左) にするか
function transform(a, b, aWins) {
  if (isNoop(a) || isNoop(b)) return [a, b];
  // 1. 同じ位置への挿入どうし
  if (a.len === 0 && b.len === 0 && a.loc === b.loc) {
    return aWins ? [a, shifted(b, a.text.length)] : [shifted(a, b.text.length), b];
  }
  // 2. a が b より前 (接しているのも含む)
  if (end(a) <= b.loc) return [a, shifted(b, delta(a))];
  // 3. b が a より前
  if (end(b) <= a.loc) return [shifted(a, delta(b)), b];
  // ここから先は範囲が重なっている
  const identical = a.loc === b.loc && end(a) === end(b);
  // 4. a が b を含む (同じ範囲なら勝つほう)
  if (a.loc <= b.loc && end(b) <= end(a) && (!identical || aWins)) return [op(a.loc, a.len + delta(b), a.text), noop()];
  // 5. b が a を含む
  if (b.loc <= a.loc && end(a) <= end(b)) return [noop(), op(b.loc, b.len + delta(a), b.text)];
  // 6. 一部が重なる (a が先に始まる)
  if (a.loc < b.loc) return [op(a.loc, b.loc - a.loc, a.text), op(a.loc + a.text.length, end(b) - end(a), b.text)];
  // 7. 一部が重なる (b が先に始まる)
  return [op(b.loc + b.text.length, end(a) - end(b), a.text), op(b.loc, a.loc - b.loc, b.text)];
}

/// 共有する側 (ホスト) の変更の記録。全員の変更はここで順番が決まる
class OTServer {
  constructor() { this.revision = 0; this.history = []; }
  /// ホスト自身の変更 (すでに文章に反映済み)
  localEdit(o) { this.history.push(o); this.revision += 1; return this.revision; }
  /// 参加者から届いた変更。baseRevision 以降の変更とすり合わせた結果を返す (これを文章に反映して全員に配る)
  receive(o, baseRevision) {
    let x = o;
    const start = Math.max(0, Math.min(baseRevision, this.history.length));
    for (const h of this.history.slice(start)) x = transform(x, h, false)[0];
    this.history.push(x);
    this.revision += 1;
    return { op: x, revision: this.revision };
  }
}

/// 参加する側 (ゲスト) の状態。返事待ちの変更は 1 つだけ送り、残りはためておく
class OTClient {
  constructor(revision) { this.revision = revision; this.outstanding = null; this.buffer = []; }
  get hasPending() { return this.outstanding !== null || this.buffer.length > 0; }
  /// 自分の変更 (すでに文章に反映済み)。今すぐ送るべきものがあれば { op, baseRevision }
  localEdit(o) {
    if (this.outstanding === null) { this.outstanding = o; return { op: o, baseRevision: this.revision }; }
    this.buffer.push(o);
    return null;
  }
  /// 自分の変更がホストに受け付けられた。次に送るものがあれば返す
  acknowledged(r) {
    this.revision = r;
    this.outstanding = null;
    if (!this.buffer.length) return null;
    this.outstanding = this.buffer.shift();
    return { op: this.outstanding, baseRevision: this.revision };
  }
  /// ほかの人の変更が届いた。自分の文章に反映すべき形にして返す
  remote(o, r) {
    this.revision = r;
    let x = o;
    if (this.outstanding !== null) {
      const [x2, out2] = transform(x, this.outstanding, true);
      x = x2;
      this.outstanding = out2;
    }
    for (let i = 0; i < this.buffer.length; i++) {
      const [x2, b2] = transform(x, this.buffer[i], true);
      x = x2;
      this.buffer[i] = b2;
    }
    return x;
  }
}

module.exports = { op, noop, isNoop, apply, transformPosition, transform, OTServer, OTClient };
