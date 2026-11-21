// 版の履歴の窓 (Mac 版 VersionHistoryWindow.swift と同じ): 左に版の一覧、右に中身。
// 「この版」= その版の中身、「今との違い」= 行ごとの違い、「Word 風」= 文章の中に消した所 (赤の取り消し線) と足した所 (青の下線)
import { h, modal, alertBox, toast } from './dialogs';
import { dateText, stamp } from './library';
import { pathUtil } from './util';
import i18n from '../../shared/i18n';
import textdiff from '../../shared/textdiff';

const { t } = i18n;
const norm = p => String(p || '').replace(/\//g, '\\').toLowerCase();

/// 行ごとの違い: [{ kind: 'same'|'removed'|'added'|'gap', text, skipped }] (変わった所の前後 context 行だけ残す)
export function lineRows(oldText, newText, context = 3) {
  const a = textdiff.lines(oldText), b = textdiff.lines(newText);
  const { removed, inserted } = textdiff.diffArrays(a, b);
  const all = [];
  let i = 0, j = 0;
  while (i < a.length || j < b.length) {
    if (i < a.length && removed.has(i)) all.push({ kind: 'removed', text: a[i++] });
    else if (j < b.length && inserted.has(j)) all.push({ kind: 'added', text: b[j++] });
    else if (i < a.length && j < b.length) { all.push({ kind: 'same', text: b[j] }); i++; j++; } else break;
  }
  const keep = all.map(() => false);
  all.forEach((r, k) => { if (r.kind !== 'same') for (let x = Math.max(0, k - context); x <= Math.min(all.length - 1, k + context); x++) keep[x] = true; });
  const out = [];
  for (let k = 0; k < all.length;) {
    if (keep[k]) { out.push(all[k++]); continue; }
    let e = k;
    while (e < all.length && !keep[e]) e++;
    out.push({ kind: 'gap', text: '', skipped: e - k });
    k = e;
  }
  return out;
}

export class VersionHistory {
  constructor(app) { this.app = app; this.api = app.api; }

  /// メニュー「ファイル > 版の履歴…」: 今の内容も版に入れてから見せる
  async showCurrent() {
    const tab = this.app.active;
    if (!tab || !tab.path) { toast(t('まだ保存していない文書です')); return; }
    if (tab.enc) { toast(t('暗号化した文書は版を記録しません')); return; }
    if (tab.isDirty()) await this.app.save(tab, { versionNow: true });
    else await this.api.versionNoteSaved(tab.path, true);
    await new Promise(r => setTimeout(r, 300));
    await this.show(tab.path);
  }

  currentText(path) {
    const tab = this.app.tabs.find(x => x.path && norm(x.path) === norm(path));
    if (tab) { if (tab.paper) this.app.syncFromPaper(tab); return Promise.resolve(tab.getText()); }
    return this.api.libraryReadText(path).then(r => (r && typeof r.text === 'string' ? r.text : ''));
  }

  async show(path, selectKey) {
    const versions = await this.api.versionList(path);
    let index = Math.max(0, versions.findIndex(v => v.key === selectKey));
    let view = 0;
    const cache = new Map();
    const list = h('div', { class: 'ver-list', tabindex: '0', role: 'listbox' });
    const content = h('div', { class: 'ver-content selectable' });
    const info = h('div', { class: 'ver-info dim' });
    const seg = h('div', { class: 'ver-seg', role: 'tablist' });
    const segs = [t('この版'), t('今との違い'), t('Word 風')].map((label, i) => {
      const b = h('button', { class: i === view ? 'active' : '', onclick: () => { view = i; segs.forEach((x, k) => x.classList.toggle('active', k === i)); refresh(); } }, label);
      seg.append(b);
      return b;
    });
    const text = async v => {
      if (!cache.has(v.key)) { const r = await this.api.versionContent(path, v.key); cache.set(v.key, r ? r.text : null); }
      return cache.get(v.key);
    };
    const renderList = () => {
      list.textContent = '';
      if (!versions.length) {
        list.append(h('div', { class: 'ver-row' }, h('div', {}, t('まだ版がありません')), h('div', { class: 'dim' }, t('保存すると、ここに残ります'))));
        return;
      }
      versions.forEach((v, i) => list.append(h('div', {
        class: 'ver-row' + (i === index ? ' current' : ''), role: 'option',
        onclick: () => { index = i; renderList(); refresh(); },
      }, h('div', {}, (i === 0 ? t('いちばん新しい版') + ' ・ ' : '') + dateText(v.date)), h('div', { class: 'dim' }, stamp(v.date)))));
      const cur = list.children[index];
      if (cur && cur.scrollIntoView) cur.scrollIntoView({ block: 'nearest' });
    };
    list.addEventListener('keydown', e => {
      if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
      e.preventDefault();
      index = Math.max(0, Math.min(versions.length - 1, index + (e.key === 'ArrowDown' ? 1 : -1)));
      renderList(); refresh();
    });
    const refresh = async () => {
      const v = versions[index];
      content.textContent = '';
      info.textContent = '';
      if (!v) return;
      const old = await text(v);
      if (old === null) { content.textContent = t('この版を読めませんでした'); return; }
      if (view === 0) {
        content.textContent = old;
        info.textContent = t('{n} 字', { n: Array.from(old).length });
        return;
      }
      const now = await this.currentText(path);
      if (view === 2) {
        // Word の変更履歴のように: 文章の中に、消した字と足した字をそのまま並べる
        const d = textdiff.inline(old, now, { context: 1000000 });
        if (d.tooLarge) content.textContent = t('大きすぎて比べられません');
        else if (!d.segments.length) content.textContent = t('今の内容と同じです');
        for (const s of d.segments) {
          content.append(h('span', { class: 'ver-' + s.kind }, s.kind === 'gap' ? t('… {n} 行 同じ …', { n: s.skipped }) + '\n' : s.text));
        }
        info.textContent = t('赤の取り消し線 = この版から消した所 ・ 青の下線 = 足した所');
        return;
      }
      // 今との違い: この版 → 今 で、消えた行は赤、増えた行は緑
      const rows = lineRows(old, now, 3);
      let added = 0, removed = 0;
      for (const r of rows) {
        if (r.kind === 'added') added++;
        if (r.kind === 'removed') removed++;
        const mark = r.kind === 'removed' ? '− ' : r.kind === 'added' ? '+ ' : '  ';
        content.append(h('div', { class: 'ver-line ver-l-' + r.kind }, mark + (r.kind === 'gap' ? t('… {n} 行 同じ …', { n: r.skipped }) : r.text)));
      }
      if (old === now) content.append(h('div', {}, t('今の内容と同じです')));
      info.textContent = t('今のほうが +{a} 行 / −{b} 行', { a: added, b: removed });
    };
    renderList();
    refresh();
    const r = await modal({
      title: t('版の履歴: {name}', { name: pathUtil.base(path) }), width: 860, className: 'ver-modal', noEnter: true,
      body: h('div', { class: 'ver-body' }, h('div', { class: 'ver-left' }, h('div', { class: 'dim small' }, t('保存した日時')), list),
        h('div', { class: 'ver-right' }, seg, content, info)),
      buttons: [
        { label: t('この版をコピー'), value: 'copy', validate: async () => { const v = versions[index]; const s = v && await text(v); if (s !== null && s !== undefined) { this.api.copyText(s); toast(t('コピーしました')); } return false; } },
        { label: t('この版に戻す'), value: 'restore', primary: true, validate: () => versions.length > 0 },
        { label: t('閉じる'), value: null, cancel: true },
      ],
    });
    if (r === 'restore') await this.restore(path, await text(versions[index]));
  }

  /// エディタの本文をこの版にする (開いていなければ開く)。元に戻すで取り消せる
  async restore(path, s) {
    if (typeof s !== 'string') return;
    let tab = this.app.tabs.find(x => x.path && norm(x.path) === norm(path));
    if (!tab) tab = await this.app.openPath(path);
    if (!tab) return;
    if (tab.locked) { await alertBox(t('ロックしているので戻せません'), t('右クリックの「ロックを外す」で外してから戻してください。')); return; }
    this.app.activate(tab);
    if (tab.paper) { tab.paper.replaceRange(0, tab.paper.getText().length, s); this.app.syncFromPaper(tab); } else tab.editor.replaceRange(0, tab.editor.view.state.doc.length, s);
    tab.touched = true;
    this.app.updateTabs();
    toast(t('この版に戻しました (元に戻すで取り消せます)'));
  }
}
