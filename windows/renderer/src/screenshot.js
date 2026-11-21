// スクリーンショット: 表示されている部分、または文書全体を画像にして、コピーするか画像として保存する
import { h, modal, alertBox, toast } from './dialogs';
import { genkoPrintHTML, a4PrintHTML } from './paper';
import { makeScanner, KINDS } from '../../shared/scanner';
import themeDef from '../../shared/theme';
import i18n from '../../shared/i18n';
import { pathUtil } from './util';

const { t } = i18n;
const MAX_LINES = 5000; // 文書全体を画像にするときの上限 (これより長いと画像が大きくなりすぎる)

function esc(s) {
  return s.replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
}

/// 通常の文書を、画面と同じ色・フォント・行番号つきの HTML にする
function plainHTML(app, tab, text) {
  const colors = themeDef.colors(app.theme);
  const css = getComputedStyle(document.documentElement);
  const font = css.getPropertyValue('--ed-font'), size = css.getPropertyValue('--ed-size'), line = css.getPropertyValue('--ed-line');
  const tokens = tab.profile && text.length < 2000000 ? makeScanner(tab.profile)(text) : [];
  // 色分けを入れながら、行ごとに切る
  const lines = [''];
  let pos = 0;
  const push = (from, to, cls) => {
    const parts = text.slice(from, to).split('\n');
    parts.forEach((part, i) => {
      if (i > 0) lines.push('');
      if (part) lines[lines.length - 1] += cls ? `<span class="${cls}">${esc(part)}</span>` : esc(part);
    });
  };
  for (let i = 0; i < tokens.length; i += 3) {
    if (tokens[i] > pos) push(pos, tokens[i], '');
    push(tokens[i], tokens[i + 1], 'k-' + KINDS[tokens[i + 2]]);
    pos = tokens[i + 1];
  }
  push(pos, text.length, '');
  const digits = String(lines.length).length;
  const rows = lines.map((html, i) => `<div class="l"><span class="n">${i + 1}</span><span class="c">${html || ' '}</span></div>`).join('');
  const style = `html, body { margin: 0; } body { background: ${colors.background}; color: ${colors.text}; font-family: ${font}; font-size: ${size}; line-height: ${line}; padding: 4px 0; }
    .l { display: flex; } .n { flex: 0 0 auto; width: ${digits + 2}ch; padding-right: 1ch; text-align: right; color: ${colors.gutterText}; background: ${colors.gutterBackground}; border-right: 1px solid ${colors.gutterSeparator}; }
    .c { flex: 1; min-width: 0; padding: 0 8px; white-space: pre-wrap; word-break: break-all; tab-size: ${tab.profile ? tab.profile.tabWidth : 4}; }
    ${KINDS.map(k => `.k-${k} { color: ${colors[k]}; }`).join(' ')}`;
  return `<!doctype html><html><head><meta charset="utf-8"><style>${style}</style></head><body>${rows}</body></html>`;
}

/// 文書全体の HTML と、画像にするときの幅 (px)
export function wholeDocument(app, tab) {
  if (tab.paper) app.syncFromPaper(tab);
  let text = tab.getText();
  if (tab.paperMode === 1) {
    // 原稿用紙: 1 mm = 4 px で、用紙を縦に並べる
    const horizontal = !!tab.genkoHorizontal;
    const html = genkoPrintHTML(tab.name, text, app.prefs, tab.paper ? tab.paper.ruby : [], horizontal)
      .replace('--u: 1mm', '--u: 4px').replace(/@page \{[^}]*\}/, '')
      .replace('</style>', ' body { background: #8a8f96; padding: 16px; } .genko-sheet { margin: 0 auto 16px; background: #fffdf7; }</style>');
    return { html, width: (horizontal ? 210 : 297) * 4 + 32, truncated: false };
  }
  if (tab.paperMode === 2) {
    const html = a4PrintHTML(tab.name, text, app.prefs, tab.paper ? tab.paper.manual() : {})
      .replace(/@page \{[^}]*\}/, '').replace('font-size: 12pt; line-height: 6.86mm;', 'font-size: 16px; line-height: 28px; padding: 80px; background: #fff;')
      .replace(/min-height: 6\.86mm/, 'min-height: 28px');
    return { html, width: 800, truncated: false };
  }
  const all = text.split('\n');
  const truncated = all.length > MAX_LINES;
  if (truncated) text = all.slice(0, MAX_LINES).join('\n');
  return { html: plainHTML(app, tab, text), width: Math.max(480, Math.round(tab.el.getBoundingClientRect().width)), truncated };
}

export async function screenshotDialog(app) {
  const tab = app.active;
  let mode = app.screenshotMode || 'visible';
  const radio = (value, label, note) => h('label', { class: 'kind-row' },
    h('input', { type: 'radio', name: 'shot-mode', checked: mode === value, onchange: () => { mode = value; } }),
    h('span', {}, h('span', { class: 'kind-label' }, label), h('span', { class: 'dim kind-note' }, note)));
  const action = await modal({
    title: t('スクリーンショット (画像にする)'), width: 460,
    body: h('div', {},
      h('div', { class: 'kind-list' },
        radio('visible', t('表示されている部分'), t('いま見えている範囲を、そのまま画像にします。')),
        radio('whole', t('文書全体'), t('見えていない部分も含めて、最初から最後までを 1 枚の画像にします。')))),
    buttons: [{ label: t('コピー'), value: 'copy', primary: true }, { label: t('画像として保存…'), value: 'save' }, { label: t('キャンセル'), value: null, cancel: true }],
  });
  if (!action) return;
  app.screenshotMode = mode;
  let path = null;
  if (action === 'save') {
    path = await app.api.saveDialog({
      title: t('画像として保存'), defaultPath: tab.path ? pathUtil.withExtension(tab.path, 'png') : tab.name.replace(/[\\/:*?"<>|()（）]/g, '').trim() + '.png',
      filters: [{ name: 'PNG', extensions: ['png'] }],
    });
    if (!path) return;
  }
  // ダイアログが消えた画面になってから撮る
  await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(r, 60))));
  let job;
  if (mode === 'visible') {
    const r = tab.el.getBoundingClientRect();
    const top = app.el.ruler.hidden ? r.top : app.el.ruler.getBoundingClientRect().top;
    job = { mode, rect: { x: Math.round(r.left), y: Math.round(top), width: Math.round(r.width), height: Math.round(r.bottom - top) } };
  } else {
    job = Object.assign({ mode }, wholeDocument(app, tab));
  }
  const result = await app.api.screenshot(Object.assign(job, { action, path }));
  if (result.status !== 'ok') { await alertBox(t('画像にできませんでした'), result.message); return; }
  let message = action === 'copy' ? t('画像をコピーしました ({w} × {h})', { w: result.width, h: result.height }) : t('画像を保存しました: {name}', { name: pathUtil.base(path) });
  if (job.truncated || result.clipped) message += ' ' + t('(長いので途中までです)');
  toast(message);
}
