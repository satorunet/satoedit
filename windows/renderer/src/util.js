// パスの小道具 (Windows の \ と / のどちらでも動く)
export const pathUtil = {
  base(p) { return String(p).replace(/[\\/]+$/, '').split(/[\\/]/).pop(); },
  dir(p) { const s = String(p).replace(/[\\/]+$/, ''); const i = Math.max(s.lastIndexOf('/'), s.lastIndexOf('\\')); return i <= 0 ? s.slice(0, i + 1) : (/^[A-Za-z]:$/.test(s.slice(0, i)) ? s.slice(0, i + 1) : s.slice(0, i)); },
  join(d, n) { const sep = d.includes('\\') && !d.includes('/') ? '\\' : '/'; return d.replace(/[\\/]+$/, '') + sep + n; },
  withExtension(p, ext) { const b = pathUtil.base(p); const i = b.lastIndexOf('.'); return pathUtil.join(pathUtil.dir(p), (i > 0 ? b.slice(0, i) : b) + '.' + ext); },
  same(a, b) { return String(a).replace(/\\/g, '/').toLowerCase() === String(b).replace(/\\/g, '/').toLowerCase(); },
};

/// 横の欄を、はしから滑らせて出し入れする (Mac 版の slideSide と同じ)。欄の中身は出したときの幅のまま、
/// 外側の余白 (margin) を動かすので、本文の幅がだんだん変わる。「動きを減らす」にしているときは、すぐ切り替える
export function slidePane(el, open, fromLeft, done) {
  if (el._slideFinish) el._slideFinish();
  const side = fromLeft ? 'marginLeft' : 'marginRight';
  const reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (open === !el.hidden || reduce || !document.body.classList.contains('ready') || document.hidden) {
    el.hidden = !open;
    if (done) done();
    return;
  }
  el.hidden = false;
  const w = Math.ceil(el.getBoundingClientRect().width);
  if (!w) { el.hidden = !open; if (done) done(); return; }
  el.style.transition = 'none';
  el.style[side] = (open ? -w : 0) + 'px';
  el.getBoundingClientRect(); // ここから動かす
  el.style.transition = `margin ${open ? 260 : 200}ms ${open ? 'ease-out' : 'ease-in'}`;
  el.style[side] = (open ? 0 : -w) + 'px';
  el.dataset.sliding = open ? 'in' : 'out';
  let timer = 0;
  const finish = () => {
    clearTimeout(timer);
    el.removeEventListener('transitionend', onEnd);
    el._slideFinish = null;
    el.style.transition = '';
    el.style[side] = '';
    delete el.dataset.sliding;
    el.hidden = !open;
    if (done) done();
  };
  const onEnd = e => { if (e.target === el) finish(); };
  el.addEventListener('transitionend', onEnd);
  timer = setTimeout(finish, 450);
  el._slideFinish = finish;
}
