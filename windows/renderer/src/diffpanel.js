// 差分の欄: 開いたとき (保存したとき) の内容と、いまの内容の違いを、エディタの右に Word の変更履歴のように見せる。
// 行の高さ・字はエディタと同じにして、エディタと一緒にスクロールする。行を押すとエディタのその行へ移る
import { h } from './dialogs';
import i18n from '../../shared/i18n';
import textdiff from '../../shared/textdiff';

const { t } = i18n;

export class DiffPanel {
  constructor(app) {
    this.app = app;
    this.pane = app.el.diffPane;
    this.rowsByLine = new Map(); // いまの文書の行番号 → 行の要素
    this.timer = null;
    this.bar = h('div', { class: 'diff-resizer', title: t('ドラッグで幅を変える') });
    this.close = h('button', { class: 'diff-close', title: t('閉じる'), 'aria-label': t('閉じる'), onclick: () => app.setPref('diffVisible', false) }, '✕');
    this.body = h('div', { class: 'diff-body' });
    this.scroller = h('div', { class: 'diff-scroll' }, this.body);
    this.empty = h('div', { class: 'diff-empty' });
    this.pane.append(this.bar, this.scroller, this.empty, this.close);
    this.pane.style.width = (app.prefs.diffWidth || 360) + 'px';
    // 行を押したら、エディタのその行へ
    this.body.addEventListener('click', e => {
      if (window.getSelection && String(window.getSelection()).length) return; // 字を選んでいるときは移らない
      const row = e.target.closest('.diff-row');
      if (!row || !app.active) return;
      app.active.editor.goToLine(Number(row.dataset.line) || 1, 1);
      app.focusEditor();
    });
    // 左の端をドラッグして幅を変える
    let dragging = false;
    this.bar.addEventListener('mousedown', e => { dragging = true; e.preventDefault(); });
    window.addEventListener('mousemove', e => {
      if (!dragging) return;
      const right = this.pane.getBoundingClientRect().right;
      const w = Math.max(200, Math.min(window.innerWidth - 300, right - e.clientX));
      this.pane.style.width = w + 'px';
      app.scheduleRuler();
    });
    window.addEventListener('mouseup', () => {
      if (!dragging) return;
      dragging = false;
      app.prefs.diffWidth = parseInt(this.pane.style.width, 10) || 360;
      app.api.setPref('diffWidth', app.prefs.diffWidth);
    });
  }

  get visible() { return !this.pane.hidden; }

  setVisible(on) {
    if (this.visible === on) return;
    this.pane.hidden = !on;
    if (on) this.refresh(0);
    this.app.scheduleRuler();
  }

  /// 文字が変わった・タブを替えた・保存した: 少し待ってから比べ直す
  refresh(delay = 400) {
    if (!this.visible) return;
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.render(), delay);
  }

  render() {
    const tab = this.app.active;
    this.rowsByLine.clear();
    this.body.textContent = '';
    if (!tab || tab.paperMode !== 0) { this.showEmpty(tab ? t('用紙モードのあいだは差分を出しません') : ''); return; }
    const oldText = tab.savedDoc.toString(), newText = tab.editor.view.state.doc.toString();
    // 変わっていない行も省かずに全部 (エディタと 1 行ずつ対応させる)
    const result = textdiff.inline(oldText, newText, { context: 1e9 });
    if (result.tooLarge) { this.showEmpty(t('大きすぎるので比べていません')); return; }
    if (!result.segments.length) { this.showEmpty(t('変更はありません')); return; }
    this.empty.hidden = true;
    const rows = textdiff.toRows(result);
    const digits = Math.max(3, String(rows.reduce((m, r) => Math.max(m, r.number || 0), 1)).length);
    const frag = document.createDocumentFragment();
    for (const r of rows) {
      if (r.gap) continue; // いまは全部出すので、まとめ行は来ない
      const num = h('span', { class: 'diff-num' + (r.removedOnly ? ' removed' : '') }, r.removedOnly ? '−' : String(r.number));
      num.style.width = (digits + 1) + 'ch';
      const row = h('div', { class: 'diff-row', 'data-line': String(r.number) }, num);
      for (const [kind, text] of r.parts) row.append(h('span', { class: 'diff-' + kind }, text));
      if (!r.parts.length) row.append(h('span', { class: 'diff-' + (r.newline || 'same') }, ' '));
      if (!r.removedOnly && !this.rowsByLine.has(r.number)) this.rowsByLine.set(r.number, row);
      frag.append(row);
    }
    this.body.append(frag);
    this.syncScroll();
    this.syncCurrentLine();
  }

  showEmpty(text) {
    this.empty.textContent = text;
    this.empty.hidden = !text;
  }

  /// エディタのいちばん上に見えている行を、差分の欄でも同じ高さに
  syncScroll() {
    const tab = this.app.active;
    if (!this.visible || !tab || tab.paperMode !== 0) return;
    const view = tab.editor.view;
    const scroller = view.scrollDOM;
    // 本文の上の端をエディタと合わせる (桁ルーラーのぶん下げる)
    const top = scroller.getBoundingClientRect().top - this.pane.getBoundingClientRect().top;
    if (this.scroller.style.marginTop !== top + 'px') this.scroller.style.marginTop = Math.max(0, top) + 'px';
    // エディタのいちばん上に見えている行と、その行の画面での高さ
    const visibleTop = scroller.getBoundingClientRect().top;
    const block = view.lineBlockAtHeight(visibleTop - view.documentTop);
    const lineNo = view.state.doc.lineAt(block.from).number;
    const screenY = view.documentTop + block.top;
    const row = this.rowsByLine.get(lineNo) || this.nearestRow(lineNo);
    if (!row) return;
    // 差分の欄の同じ行が、同じ画面の高さに来るまでずらす
    this.scroller.scrollTop += row.getBoundingClientRect().top - screenY;
    this.body.style.tabSize = String(view.state.tabSize);
  }

  nearestRow(lineNo) {
    for (let n = lineNo; n > 0; n--) if (this.rowsByLine.has(n)) return this.rowsByLine.get(n);
    return null;
  }

  /// エディタのカーソル行と同じ行に、同じ色の帯
  syncCurrentLine() {
    if (!this.visible) return;
    const tab = this.app.active;
    this.body.querySelectorAll('.diff-row.current').forEach(e => e.classList.remove('current'));
    if (!tab || tab.paperMode !== 0 || !this.app.prefs.highlightCurrentLine) return;
    const state = tab.editor.view.state;
    if (!state.selection.main.empty) return;
    const row = this.rowsByLine.get(state.doc.lineAt(state.selection.main.head).number);
    if (row) row.classList.add('current');
  }
}
