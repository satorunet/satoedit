// 画像やバイナリのファイルを開いたとき: エディタの代わりに、見るだけの画面を出す (Mac 版と同じ)
import { h, floatWindow, toast } from './dialogs';
import i18n from '../../shared/i18n';
import binary from '../../shared/binary';

const { t } = i18n;

function bytesOf(base64) {
  const s = atob(base64);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

const sizeText = n => (n >= 1e6 ? (n / 1e6).toFixed(1) + ' MB' : n >= 1e3 ? (n / 1e3).toFixed(1) + ' KB' : n + ' B');

/// r: 本体からの { kind: 'image' | 'hex', base64, mime, size }。name: ファイル名。openAsText: 文字として開き直す
export function showViewer(app, r, { name, openAsText, openExternal }) {
  const id = 'viewer:' + name;
  if (r.kind === 'image') {
    const img = h('img', { class: 'viewer-image fit', src: `data:${r.mime};base64,${r.base64}`, alt: name, draggable: 'false' });
    const info = h('span', { class: 'dim' });
    img.addEventListener('load', () => { info.textContent = `${img.naturalWidth} × ${img.naturalHeight} ・ ${sizeText(r.size)}`; });
    let scale = 1;
    const setFit = fit => { img.classList.toggle('fit', fit); img.style.width = fit ? '' : Math.round(img.naturalWidth * scale) + 'px'; };
    const zoom = f => { scale = Math.max(0.05, Math.min(20, scale * f)); setFit(false); };
    const stage = h('div', { class: 'viewer-stage', tabindex: '0' }, img);
    stage.addEventListener('dblclick', () => { scale = 1; setFit(!img.classList.contains('fit')); });
    stage.addEventListener('keydown', e => {
      if (e.key === '+' || e.key === ';') zoom(1.25);
      else if (e.key === '-') zoom(0.8);
      else if (e.key === '0') { scale = 1; setFit(true); }
      else if (e.key === '1') { scale = 1; setFit(false); }
      else if (e.key === ' ') win.close();
      else return;
      e.preventDefault();
    });
    const body = h('div', { class: 'viewer' },
      h('div', { class: 'form-row' },
        h('button', { onclick: () => { scale = 1; setFit(true); } }, t('ウインドウに合わせる')),
        h('button', { onclick: () => { scale = 1; setFit(false); } }, t('実際の大きさ')),
        h('button', { onclick: () => zoom(1.25) }, '+'), h('button', { onclick: () => zoom(0.8) }, '−'),
        h('span', { class: 'tb-space' }), info,
        openExternal ? h('button', { onclick: openExternal }, t('ほかのアプリで開く')) : null),
      stage);
    const win = floatWindow({ id, title: name, body, width: 720 });
    setTimeout(() => stage.focus(), 0);
    return win;
  }

  // 16 進数で見る (見えている行だけ作る)
  const data = bytesOf(r.base64);
  const rows = binary.lineCount(data.length);
  const digits = Math.max(8, data.length.toString(16).length);
  const rowH = 18;
  const inner = h('div', { class: 'hex-inner', style: { height: rows * rowH + 'px' } });
  const scroller = h('div', { class: 'hex-scroll', tabindex: '0' }, inner);
  const draw = () => {
    const first = Math.max(0, Math.floor(scroller.scrollTop / rowH) - 5);
    const last = Math.min(rows, first + Math.ceil(scroller.clientHeight / rowH) + 12);
    inner.textContent = '';
    for (let i = first; i < last; i++) {
      const l = binary.line(data, i * 16, digits);
      inner.append(h('div', { class: 'hex-row', style: { top: i * rowH + 'px' } },
        h('span', { class: 'hex-off' }, l.offset), h('span', { class: 'hex-bytes' }, l.hex), h('span', { class: 'hex-ascii' }, l.ascii)));
    }
  };
  scroller.addEventListener('scroll', draw);
  const goField = h('input', { type: 'text', placeholder: '0x1F00', style: { width: '110px' } });
  const go = () => {
    const v = parseInt(goField.value.replace(/^0x/i, ''), 16);
    if (Number.isFinite(v)) scroller.scrollTop = Math.floor(Math.max(0, Math.min(v, data.length - 1)) / 16) * rowH;
  };
  goField.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); go(); } });
  const copy = () => {
    const lines = [];
    for (let i = 0; i < Math.min(rows, 4096); i++) { const l = binary.line(data, i * 16, digits); lines.push(`${l.offset}  ${l.hex}  |${l.ascii}|`); }
    app.api.copyText(lines.join('\n'));
    toast(t('コピーしました'));
  };
  const body = h('div', { class: 'viewer' },
    h('div', { class: 'form-row' },
      h('span', { class: 'dim' }, t('バイナリのファイルです ({size})', { size: sizeText(r.size) }) + (r.truncated ? ' ' + t('(はじめの 16 MB だけ表示)') : '')),
      h('span', { class: 'tb-space' }),
      h('span', {}, t('位置へ移動')), goField, h('button', { onclick: go }, t('移動'))),
    h('div', { class: 'hex-head' }, h('span', { class: 'hex-off' }, t('位置')), h('span', { class: 'hex-bytes' }, t('16 進数')), h('span', { class: 'hex-ascii' }, t('文字'))),
    scroller,
    h('div', { class: 'form-row' },
      h('button', { onclick: copy }, t('コピー')),
      h('span', { class: 'tb-space' }),
      openAsText ? h('button', { onclick: () => { win.close(); openAsText(); } }, t('テキストとして開く')) : null,
      openExternal ? h('button', { onclick: openExternal }, t('ほかのアプリで開く')) : null));
  const win = floatWindow({ id, title: name, body, width: 760 });
  setTimeout(draw, 0);
  return win;
}
