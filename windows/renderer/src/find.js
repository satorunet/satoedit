// 検索・置換の窓 (文書の上に浮かぶ別の窓) と、grep (フォルダ内検索)
import { h, modal, floatWindow, floatOpen, toast, alertBox } from './dialogs';
import i18n from '../../shared/i18n';

const { t } = i18n;

export class FindController {
  constructor(app) {
    this.app = app;
    this.spec = { text: '', replace: '', caseSensitive: false, wholeWord: false, regexp: false, wrap: true, highlight: true };
    this.grepOptions = { pattern: '', root: '', fileMask: '*', useRegex: false, caseSensitive: false, recursive: true };
    this.grepId = null;
    this.window = null;
    app.api.on('grep:matches', (id, list) => { if (id === this.grepId) this.addMatches(list); });
    app.api.on('grep:done', (id, result) => { if (id === this.grepId) this.grepDone(result); });
  }

  editor() { return this.app.active.editor; }

  close() {
    if (this.window) this.window.close();
  }

  onTabChange() {
    if (this.window && this.spec.text) this.refreshCount();
  }

  /// 検索の窓を出す (replace = true なら置換の欄も)
  show(replace) {
    this.replaceMode = !!replace;
    const sel = this.editor().selectionText();
    if (sel && !sel.includes('\n') && sel.length <= 200) this.spec.text = sel;
    const spec = this.spec;
    const textInput = h('input', { type: 'text', class: 'wide', value: spec.text, placeholder: t('検索する文字列'), 'aria-label': t('検索する文字列') });
    const replaceInput = h('input', { type: 'text', class: 'wide', value: spec.replace, placeholder: t('置換後の文字列'), 'aria-label': t('置換後の文字列') });
    const status = h('div', { class: 'find-status', role: 'status' });
    const inSelection = h('input', { type: 'checkbox' });
    const check = (label, key) => h('label', { class: 'check-row' },
      h('input', { type: 'checkbox', checked: spec[key], onchange: e => { spec[key] = e.target.checked; this.refreshCount(); } }), label);
    const sync = () => { spec.text = textInput.value; spec.replace = replaceInput.value; };
    const body = h('div', { class: 'find-body' },
      h('div', { class: 'form-row' }, h('label', {}, t('検索')), textInput),
      replace ? h('div', { class: 'form-row' }, h('label', {}, t('置換')), replaceInput) : null,
      h('div', { class: 'find-options' },
        check(t('大文字と小文字を区別'), 'caseSensitive'), check(t('単語単位'), 'wholeWord'), check(t('正規表現'), 'regexp'),
        check(t('文書の端まで来たら先頭に戻る'), 'wrap'), check(t('見つかった所をすべて強調'), 'highlight'),
        replace ? h('label', { class: 'check-row' }, inSelection, t('選択した範囲だけ置換')) : null),
      h('div', { class: 'find-buttons' },
        h('button', { class: 'primary', onclick: () => { sync(); this.next(false); } }, t('次を検索') + ' (F3)'),
        h('button', { onclick: () => { sync(); this.next(true); } }, t('前を検索')),
        replace ? h('button', { onclick: () => { sync(); this.replaceOne(); } }, t('置換')) : null,
        replace ? h('button', { onclick: () => { sync(); this.replaceAll(inSelection.checked); } }, t('すべて置換')) : null),
      status);
    this.status = status;
    this.window = floatWindow({
      id: 'find', title: replace ? t('置換') : t('検索'), body, width: 440,
      onClose: () => {
        this.window = null;
        this.status = null;
        for (const tab of this.app.tabs) tab.editor.clearSearchHighlight();
        this.app.focusEditor();
      },
    });
    textInput.addEventListener('input', () => { sync(); this.refreshCount(); });
    replaceInput.addEventListener('input', sync);
    const onEnter = e => {
      if (e.key !== 'Enter' || e.isComposing) return;
      e.preventDefault();
      sync();
      this.next(e.shiftKey);
    };
    textInput.addEventListener('keydown', onEnter);
    replaceInput.addEventListener('keydown', onEnter);
    textInput.focus();
    textInput.select();
    this.refreshCount();
  }

  say(message, warn) {
    if (this.status) {
      this.status.textContent = message;
      this.status.classList.toggle('warn', !!warn);
    } else if (message && warn) {
      toast(message);
    }
  }

  refreshCount() {
    if (!this.spec.text) { this.editor().clearSearchHighlight(); this.say(''); return; }
    const n = this.editor().count(this.spec);
    if (n < 0) this.say(t('正規表現が正しくありません'), true);
    else this.say(n === 0 ? t('見つかりません') : t('{n} 件', { n }), n === 0);
  }

  next(backward) {
    if (!this.spec.text) { this.show(false); return; }
    const r = this.editor().find(Object.assign({}, this.spec, { highlight: this.spec.highlight && !!this.window }), backward);
    if (r.invalid) this.say(t('正規表現が正しくありません'), true);
    else if (!r.found) this.say(t('「{text}」は見つかりません', { text: this.spec.text }), true);
    else if (r.wrapped) this.say(backward ? t('先頭まで探したので、末尾から探しました') : t('末尾まで探したので、先頭から探しました'));
    else if (this.window) this.refreshCount();
  }

  useSelection() {
    const sel = this.editor().selectionText();
    if (!sel) return;
    this.spec.text = sel;
    if (this.window) this.show(this.replaceMode);
    else toast(t('検索語: {text}', { text: sel.length > 40 ? sel.slice(0, 40) + '…' : sel }));
  }

  replaceOne() {
    if (!this.spec.text) return;
    const r = this.editor().replaceOne(this.spec);
    if (r.invalid) this.say(t('正規表現が正しくありません'), true);
    else if (!r.found) this.say(t('これ以上は見つかりません'), true);
  }

  replaceAll(inSelection) {
    if (!this.spec.text) return;
    const n = this.editor().replaceAll(this.spec, inSelection);
    if (n < 0) this.say(t('正規表現が正しくありません'), true);
    else this.say(n === 0 ? t('見つかりません') : t('{n} 件を置換しました', { n }), n === 0);
  }

  // ---------- grep ----------

  async grepDialog(rootOverride) {
    const app = this.app, o = this.grepOptions;
    if (rootOverride) o.root = rootOverride;
    const tab = app.active;
    const sel = tab.paperMode === 0 ? tab.editor.selectionText() : '';
    if (sel && !sel.includes('\n') && sel.length <= 200) o.pattern = sel;
    if (!o.root) o.root = app.prefs.folderTreeRoot || '';
    if (!o.root && tab.path) o.root = (await app.api.pathInfo(tab.path)).dir;
    if (!o.root) o.root = app.init.homeDir || '';
    const pattern = h('input', { type: 'text', class: 'wide', value: o.pattern, autofocus: true });
    const root = h('input', { type: 'text', class: 'wide', value: o.root });
    const mask = h('input', { type: 'text', class: 'wide', value: o.fileMask, placeholder: '*.txt;*.md' });
    const check = (label, key) => h('label', { class: 'check-row' }, h('input', { type: 'checkbox', checked: o[key], onchange: e => { o[key] = e.target.checked; } }), label);
    const error = h('div', { class: 'find-status warn' });
    const body = h('div', {},
      h('div', { class: 'form-row' }, h('label', {}, t('検索する文字列')), pattern),
      h('div', { class: 'form-row' }, h('label', {}, t('検索するフォルダ')), root,
        h('button', { onclick: async () => { const d = await app.api.openDialog({ directory: true, title: t('検索するフォルダ'), defaultPath: root.value || undefined }); if (d[0]) root.value = d[0]; } }, t('参照…'))),
      h('div', { class: 'form-row' }, h('label', {}, t('ファイルの種類')), mask),
      h('div', { class: 'find-options' }, check(t('正規表現'), 'useRegex'), check(t('大文字と小文字を区別'), 'caseSensitive'), check(t('サブフォルダも検索'), 'recursive')),
      error);
    const ok = await modal({
      title: t('grep (フォルダ内検索)'), body, width: 520,
      buttons: [{ label: t('検索'), value: true, primary: true, validate: () => {
        if (!pattern.value) { error.textContent = t('検索する文字列を入れてください'); return false; }
        if (!root.value) { error.textContent = t('検索するフォルダを選んでください'); return false; }
        if (o.useRegex) { try { new RegExp(pattern.value, 'u'); } catch (e) { error.textContent = t('正規表現が正しくありません'); return false; } }
        return true;
      } }, { label: t('キャンセル'), value: false, cancel: true }],
    });
    if (!ok) return;
    o.pattern = pattern.value; o.root = root.value; o.fileMask = mask.value || '*';
    this.startGrep();
  }

  startGrep() {
    const app = this.app, o = this.grepOptions, pane = app.el.grepPane;
    if (this.grepId) app.api.grepCancel(this.grepId);
    this.grepId = 'g' + Date.now();
    this.grepCount = 0;
    this.grepSummary = h('span', { class: 'grep-summary' }, t('検索中…'));
    this.grepStop = h('button', { onclick: () => app.api.grepCancel(this.grepId) }, t('中止'));
    this.grepList = h('div', { class: 'grep-list', role: 'list', tabindex: '0' });
    pane.textContent = '';
    pane.append(h('div', { class: 'grep-head' },
      h('strong', {}, 'grep: ' + o.pattern), h('span', { class: 'dim' }, o.root), this.grepSummary, h('span', { class: 'tb-space' }), this.grepStop,
      h('button', { onclick: () => this.closeGrep(), title: t('閉じる') }, '✕')), this.grepList);
    pane.hidden = false;
    this.grepList.addEventListener('click', e => {
      const row = e.target.closest('.grep-row');
      if (!row) return;
      for (const x of this.grepList.querySelectorAll('.grep-row.selected')) x.classList.remove('selected');
      row.classList.add('selected');
      app.openPath(row.dataset.file, { line: Number(row.dataset.line) }); // タグジャンプ
    });
    app.api.grepStart(this.grepId, o.root, { pattern: o.pattern, useRegex: o.useRegex, caseSensitive: o.caseSensitive, fileMask: o.fileMask, recursive: o.recursive, maxResults: 10000 });
    app.scheduleRuler();
  }

  addMatches(list) {
    const root = this.grepOptions.root.replace(/[\\/]+$/, '');
    const frag = document.createDocumentFragment();
    for (const m of list) {
      let name = m.file;
      if (name.toLowerCase().startsWith(root.toLowerCase())) name = name.slice(root.length).replace(/^[\\/]/, '');
      frag.append(h('div', { class: 'grep-row', role: 'listitem', 'data-file': m.file, 'data-line': m.line, title: m.file },
        h('span', { class: 'grep-file' }, `${name}(${m.line})`), h('span', { class: 'grep-text' }, ': ' + m.text.trim().slice(0, 300))));
    }
    this.grepList.append(frag);
    this.grepCount += list.length;
    this.grepSummary.textContent = t('{n} 件…', { n: this.grepCount });
  }

  grepDone(r) {
    this.grepStop.hidden = true;
    if (r.error) { this.grepSummary.textContent = t('エラー'); alertBox(t('検索できませんでした'), r.error); return; }
    let s = t('{n} 件 ({files} ファイルを調べました)', { n: this.grepCount, files: r.scanned || 0 });
    if (r.cancelled) s += ' ' + t('(途中で中止)');
    else if (r.truncated) s += ' ' + t('(多すぎるので 10,000 件で打ち切り)');
    this.grepSummary.textContent = s;
  }

  closeGrep() {
    if (this.grepId) this.app.api.grepCancel(this.grepId);
    this.grepId = null;
    this.app.el.grepPane.hidden = true;
    this.app.el.grepPane.textContent = '';
    this.app.scheduleRuler();
    this.app.focusEditor();
  }
}

export { floatOpen };
