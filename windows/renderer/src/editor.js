// エディタ本体 (CodeMirror 6)。行番号・記号の表示・色分け・リンク・桁ルーラー・上下分割
import { EditorState, Compartment, StateField, StateEffect, RangeSetBuilder, Annotation, Transaction, Facet, EditorSelection, countColumn } from '@codemirror/state';
import {
  EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, drawSelection, gutter, GutterMarker, gutterLineClass,
  rectangularSelection, crosshairCursor, Decoration, ViewPlugin, MatchDecorator, WidgetType, dropCursor,
} from '@codemirror/view';
import {
  history, undo, redo, indentMore, indentLess, copyLineDown, deleteLine, moveLineUp, moveLineDown,
  toggleComment, insertNewline, insertNewlineKeepIndent, cursorMatchingBracket, defaultKeymap, historyKeymap,
} from '@codemirror/commands';
import { indentUnit, bracketMatching } from '@codemirror/language';
import { search, SearchQuery, setSearchQuery, openSearchPanel, closeSearchPanel } from '@codemirror/search';
import { autocompletion, acceptCompletion, completionStatus } from '@codemirror/autocomplete';
import { showTooltip } from '@codemirror/view';
import completion from '../../shared/completion';
import { makeScanner, KINDS, displayWidth } from '../../shared/scanner';

const MAX_HIGHLIGHT_LENGTH = 2000000; // これより長い文書は色分けしない (重くなるため)
export const LINK_PATTERN = /https?:\/\/[^\s<>"'`　「」『』（）、。]+|[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+/g;

// ---------- 色分け ----------

const scannerFacet = Facet.define({ combine: values => (values.length ? values[0] : null) });

function computeTokens(state) {
  const scan = state.facet(scannerFacet);
  if (!scan || state.doc.length > MAX_HIGHLIGHT_LENGTH) return null;
  return scan(state.doc.toString());
}

const tokenField = StateField.define({
  create: computeTokens,
  update(value, tr) {
    if (tr.docChanged || tr.reconfigured) return computeTokens(tr.state);
    return value;
  },
});

const tokenMarks = KINDS.map(k => Decoration.mark({ class: 'tok-' + k }));

function buildTokenDecorations(view) {
  const tokens = view.state.field(tokenField);
  const builder = new RangeSetBuilder();
  if (!tokens) return builder.finish();
  const count = tokens.length / 3;
  let last = -1;
  for (const { from, to } of view.visibleRanges) {
    // 終わりが from より後ろにある最初のトークンを二分探索
    let lo = 0, hi = count;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (tokens[mid * 3 + 1] <= from) lo = mid + 1; else hi = mid;
    }
    for (let i = Math.max(lo, last + 1); i < count && tokens[i * 3] < to; i++) {
      builder.add(tokens[i * 3], tokens[i * 3 + 1], tokenMarks[tokens[i * 3 + 2]]);
      last = i;
    }
  }
  return builder.finish();
}

const tokenPlugin = ViewPlugin.fromClass(class {
  constructor(view) { this.decorations = buildTokenDecorations(view); }
  update(u) {
    if (u.docChanged || u.viewportChanged || u.startState.field(tokenField) !== u.state.field(tokenField)) {
      this.decorations = buildTokenDecorations(u.view);
    }
  }
}, { decorations: v => v.decorations });

// ---------- 改行・タブ・空白の記号、[EOF] ----------

class MarkWidget extends WidgetType {
  constructor(text, cls) { super(); this.text = text; this.cls = cls; }
  eq(other) { return other.text === this.text && other.cls === this.cls; }
  toDOM() {
    const s = document.createElement('span');
    s.className = this.cls;
    s.textContent = this.text;
    s.setAttribute('aria-hidden', 'true');
    return s;
  }
  ignoreEvent() { return true; }
}
const newlineWidget = Decoration.widget({ widget: new MarkWidget('↓', 'cm-inv-nl'), side: 1 });
const eofWidget = Decoration.widget({ widget: new MarkWidget('[EOF]', 'cm-inv-eof'), side: 2 });
const tabMark = Decoration.mark({ class: 'cm-inv-tab' });
const zenkakuMark = Decoration.mark({ class: 'cm-inv-zen' });
const spaceMark = Decoration.mark({ class: 'cm-inv-sp' });

function invisiblesPlugin(showMarks, showEOF) {
  const build = view => {
    const builder = new RangeSetBuilder();
    const doc = view.state.doc;
    let lastLine = 0;
    for (const { from, to } of view.visibleRanges) {
      let pos = from;
      while (pos <= to) {
        const line = doc.lineAt(pos);
        if (line.number > lastLine) {
          lastLine = line.number;
          if (showMarks) {
            const text = line.text;
            if (text.length <= 20000) {
              for (let i = 0; i < text.length; i++) {
                const c = text.charCodeAt(i);
                if (c === 0x20) builder.add(line.from + i, line.from + i + 1, spaceMark);
                else if (c === 0x09) builder.add(line.from + i, line.from + i + 1, tabMark);
                else if (c === 0x3000) builder.add(line.from + i, line.from + i + 1, zenkakuMark);
              }
            }
            if (line.number < doc.lines) builder.add(line.to, line.to, newlineWidget);
          }
          if (showEOF && line.number === doc.lines) builder.add(line.to, line.to, eofWidget);
        }
        pos = line.to + 1;
      }
    }
    return builder.finish();
  };
  return ViewPlugin.fromClass(class {
    constructor(view) { this.decorations = build(view); }
    update(u) { if (u.docChanged || u.viewportChanged) this.decorations = build(u.view); }
  }, { decorations: v => v.decorations });
}

// ---------- リンク ----------

const linkDecorator = new MatchDecorator({ regexp: LINK_PATTERN, decoration: Decoration.mark({ class: 'cm-link' }) });
const linkPlugin = ViewPlugin.fromClass(class {
  constructor(view) { this.decorations = linkDecorator.createDeco(view); }
  update(u) { this.decorations = linkDecorator.updateDeco(u, this.decorations); }
}, { decorations: v => v.decorations });

export function linkAt(state, pos) {
  const line = state.doc.lineAt(pos);
  const re = new RegExp(LINK_PATTERN.source, 'g');
  let m;
  while ((m = re.exec(line.text))) {
    const from = line.from + m.index, to = from + m[0].length;
    if (pos >= from && pos <= to) return m[0].includes('://') ? m[0] : 'mailto:' + m[0];
  }
  return null;
}

// ---------- 見た目 (色は CSS の変数で切り替える) ----------

const baseTheme = EditorView.theme({
  '&': { color: 'var(--c-text)', backgroundColor: 'var(--c-background)', height: '100%' },
  '&.cm-focused': { outline: 'none' },
  '.cm-scroller': { fontFamily: 'var(--ed-font)', fontSize: 'var(--ed-size)', lineHeight: 'var(--ed-line)', overflow: 'auto' },
  '.cm-content': { caretColor: 'var(--c-caret)', padding: '2px 0' },
  '.cm-line': { padding: '0 4px 0 6px' },
  '.cm-cursor, .cm-dropCursor': { borderLeftColor: 'var(--c-caret)', borderLeftWidth: '2px' },
  '.cm-selectionBackground': { backgroundColor: 'var(--c-selection) !important' },
  '.cm-activeLine': { backgroundColor: 'var(--c-currentLine)' },
  '.cm-gutters': { backgroundColor: 'var(--c-gutterBackground)', color: 'var(--c-gutterText)', border: 'none', borderRight: '1px solid var(--c-gutterSeparator)' },
  '.cm-lineNumbers .cm-gutterElement': { padding: '0 8px 0 10px', minWidth: '3ch' },
  '.cm-activeLineGutter': { backgroundColor: 'transparent', color: 'var(--c-gutterCurrentText)' },
  '.cm-added': { fontWeight: 'bold' },
  '.cm-signature': { padding: '2px 8px', fontFamily: 'var(--ed-font)', fontSize: 'calc(var(--ed-size) - 1px)', color: 'var(--c-text)' },
  '.cm-signature b': { textDecoration: 'underline' },
  '.cm-tooltip': { border: '1px solid var(--c-gutterSeparator)', backgroundColor: 'var(--c-gutterBackground)', borderRadius: '5px' },
  '.cm-tooltip-autocomplete > ul > li': { fontFamily: 'var(--ed-font)', padding: '1px 8px !important' },
  '.cm-tooltip-autocomplete > ul > li[aria-selected]': { backgroundColor: 'var(--accent, #2f6fd0)', color: '#fff' },
  '.cm-completionDetail': { opacity: '0.6', marginLeft: '1em', fontStyle: 'normal' },
  '.cm-completionMatchedText': { textDecoration: 'none', fontWeight: 'bold' },
  '.cm-gutterElement.cm-edited-line': { fontWeight: 'bold' },
  '.cm-matchingBracket': { backgroundColor: 'transparent', outline: '1px solid var(--c-invisible)' },
  '.cm-nonmatchingBracket': { backgroundColor: 'transparent' },
  '.cm-searchMatch': { backgroundColor: 'rgba(255, 213, 0, 0.35)', outline: 'none' },
  '.cm-searchMatch-selected': { backgroundColor: 'rgba(255, 140, 0, 0.6)' },
  '.cm-panels': { display: 'none' },
});

// ---------- 書き換えた所の目印: 足した字を太字に、書き換えた行の行番号を太字に (保存すると消える) ----------

export const clearEditMarks = StateEffect.define();
const addedMark = Decoration.mark({ class: 'cm-added' });
const editPoint = Decoration.mark({ class: '' });
const editedLineMarker = new (class extends GutterMarker { constructor() { super(); this.elementClass = 'cm-edited-line'; } })();

/// { added: 足した字の範囲, points: 書き換えた場所 (消しただけの所も含む) }
const editMarksField = StateField.define({
  create: () => ({ added: Decoration.none, points: [] }),
  update(value, tr) {
    for (const e of tr.effects) if (e.is(clearEditMarks)) return { added: Decoration.none, points: [] };
    if (!tr.docChanged || tr.annotation(loadAnnotation)) return value;
    let added = value.added.map(tr.changes);
    let points = value.points.map(p => tr.changes.mapPos(p, 1));
    const ranges = [];
    tr.changes.iterChangedRanges((fromA, toA, fromB, toB) => {
      if (toB > fromB) ranges.push(addedMark.range(fromB, toB));
      points.push(fromB, toB);
    });
    if (ranges.length) added = added.update({ add: ranges, sort: true });
    if (points.length > 5000) points = points.slice(-5000);
    return { added, points };
  },
  provide: f => [
    EditorView.decorations.from(f, v => v.added),
    gutterLineClass.compute([f], state => {
      const { added, points } = state.field(f);
      const lines = new Set();
      const doc = state.doc;
      for (const p of points) lines.add(doc.lineAt(Math.min(p, doc.length)).from);
      added.between(0, doc.length, (from, to) => {
        for (let pos = from; pos <= to; ) { const l = doc.lineAt(pos); lines.add(l.from); pos = l.to + 1; }
      });
      const b = new RangeSetBuilder();
      for (const from of Array.from(lines).sort((a, c) => a - c)) b.add(from, from, editedLineMarker);
      return b.finish();
    }),
  ],
});
/// 開いた・読み直したときの文字の入れ替え (目印は付けない)
export const loadAnnotation = Annotation.define();

// ---------- 入力補完 (VSCode のような候補) と、関数の引数ヒント ----------

const KIND_TYPE = { function: 'function', keyword: 'keyword', type: 'type', property: 'property', tag: 'class', word: 'variable', snippet: 'text' };
const KIND_BOOST = { function: 4, keyword: 3, type: 2, property: 2, tag: 3, snippet: 1, word: 0 };
/// 文書の単語・関数は、文字が変わったときだけ数え直す (大きな文書で打つたびに数えないよう、少し古くても使う)
const symbolCache = new WeakMap();
function docSymbols(state, profile) {
  const doc = state.doc;
  let c = symbolCache.get(doc);
  if (c) return c;
  const text = doc.toString();
  c = { words: completion.words(text), functions: profile ? completion.definedFunctions(text) : [] };
  symbolCache.set(doc, c);
  return c;
}

function completionSource(getProfile, getExtra) {
  return context => {
    const profile = getProfile();
    const language = profile ? profile.name : null;
    const css = language === 'CSS';
    const word = context.matchBefore(css ? /[\w$-]*/ : /[\w$]*/);
    if (!word) return null;
    const before = word.from > 0 ? context.state.sliceDoc(word.from - 1, word.from) : '';
    const tagContext = language === 'HTML / XML' && before === '<';
    const minimum = tagContext ? 1 : 2;
    if (!context.explicit && word.to - word.from < minimum) return null;
    const lib = completion.libraryItems(language);
    const items = [];
    // "JSON.st" のように . のあとなら、"JSON." で始まる候補をその先だけにして出す
    let qualifier = null;
    if (before === '.') {
      const q = context.state.sliceDoc(Math.max(0, word.from - 61), word.from - 1).match(/[\w$]+$/);
      if (q) qualifier = q[0];
    }
    if (qualifier) for (const it of lib) if (it.label.startsWith(qualifier + '.')) items.push(Object.assign({}, it, { label: it.label.slice(qualifier.length + 1) }));
    if (language === 'HTML / XML') {
      for (const it of lib) if (tagContext ? it.kind === 'tag' : it.kind !== 'tag') items.push(it);
    } else {
      for (const it of lib) if (!qualifier || !it.label.includes('.')) items.push(it);
    }
    if (!tagContext) {
      const sym = docSymbols(context.state, profile);
      items.push(...sym.functions);
      if (profile) {
        for (const k of profile.keywords || []) items.push({ label: k, kind: 'keyword', detail: '', params: [] });
        for (const k of profile.types || []) items.push({ label: k, kind: 'type', detail: '', params: [] });
      }
      for (const w of sym.words) items.push({ label: w, kind: 'word', detail: '', params: [] });
    }
    // 拡張機能 (JS) からの候補は、答えを待ってから足す
    const extra = !tagContext && getExtra ? getExtra({ word: context.state.sliceDoc(word.from, word.to), language, line: context.state.doc.lineAt(context.pos).text }) : null;
    const finish = list => buildCompletion(context, list, word, language, css);
    if (extra && typeof extra.then === 'function') return extra.then(list => finish(items.concat(list || [])));
    return finish(items.concat(extra || []));
  };
}

function buildCompletion(context, items, word, language, css) {
    // 同じ名前は、種類の上のもの (関数 > キーワード > 単語) を残す
    const best = new Map();
    for (const it of items) {
      const had = best.get(it.label);
      if (!had || (KIND_BOOST[it.kind] || 0) > (KIND_BOOST[had.kind] || 0)) best.set(it.label, it);
    }
    const typed = context.state.sliceDoc(word.from, word.to);
    const options = [];
    for (const it of best.values()) {
      if (!context.explicit && it.label === typed && it.kind !== 'function') continue; // 打ち終わった単語は出さない
      options.push({
        label: it.label, type: KIND_TYPE[it.kind] || 'text', detail: it.detail || '', boost: KIND_BOOST[it.kind] || 0,
        apply: (view, _c, from, to) => {
          const next = view.state.sliceDoc(to, to + 1);
          const ins = completion.insertion(it, next, language);
          view.dispatch({ changes: { from, to, insert: ins.text }, selection: { anchor: from + ins.caret }, userEvent: 'input.complete', scrollIntoView: true });
        },
      });
    }
    if (!options.length) return null;
    return { from: word.from, options, validFor: css ? /^[\w$-]*$/ : /^[\w$]*$/ };
}

/// 関数のかっこの中を書いているあいだ、上に name(a, **b**, c) を出す
function signatureHint(getProfile) {
  const compute = state => {
    const profile = getProfile();
    const sel = state.selection.main;
    if (!profile || !sel.empty) return null;
    const pos = sel.head;
    const from = Math.max(0, pos - 3000);
    const text = state.sliceDoc(from, pos);
    const ctx = completion.callContext(text, text.length);
    if (!ctx) return null;
    const all = docSymbols(state, profile).functions.concat(completion.libraryItems(profile.name));
    let qualified = ctx.name;
    if (ctx.nameStart > 1 && text[ctx.nameStart - 1] === '.') {
      const q = text.slice(0, ctx.nameStart - 1).match(/[\w$]+$/);
      if (q) qualified = q[0] + '.' + ctx.name;
    }
    const f = all.find(x => x.kind === 'function' && x.label === qualified) || all.find(x => x.kind === 'function' && x.label === ctx.name);
    if (!f || !f.params.length) return null;
    return { pos: from + ctx.nameStart, above: true, strictSide: false, arrow: false,
      create: () => {
        const dom = document.createElement('div');
        dom.className = 'cm-signature';
        const last = f.params[f.params.length - 1];
        const active = /^(\.\.\.|\*)/.test(last) ? Math.min(ctx.argIndex, f.params.length - 1) : ctx.argIndex;
        dom.append(document.createTextNode(f.label + '('));
        f.params.forEach((p, i) => {
          if (i) dom.append(document.createTextNode(', '));
          const s = document.createElement(i === active ? 'b' : 'span');
          s.textContent = p;
          dom.append(s);
        });
        dom.append(document.createTextNode(')'));
        return { dom };
      } };
  };
  return StateField.define({
    create: compute,
    update(value, tr) { return tr.docChanged || tr.selection ? compute(tr.state) : value; },
    provide: f => showTooltip.from(f),
  });
}

const syncAnnotation = Annotation.define();
/// 共同編集で、ほかの人から届いた変更 (自分の変更として送り返さない・元に戻すの記録に入れない)
export const remoteAnnotation = Annotation.define();

// ---------- 行の数え方「ワープロ的」: 折り返した行も 1 行と数える ----------

/// 何行目の見た目か (1 始まり)。行の高さはどこも同じなので、上からの距離で数える
function visualRowAt(view, top) {
  return Math.round(top / Math.max(1, view.defaultLineHeight)) + 1;
}
class NumberMarker extends GutterMarker {
  constructor(n) { super(); this.n = n; }
  eq(o) { return o.n === this.n; }
  toDOM() { return document.createTextNode(String(this.n)); }
}
/// 各行の頭に、その行が見た目で何行目から始まるかを出す (折り返した分だけ番号がとぶ)
const visualLineNumbers = [
  gutter({
    class: 'cm-lineNumbers',
    lineMarker: (view, line) => new NumberMarker(visualRowAt(view, line.top)),
    lineMarkerChange: u => u.geometryChanged || u.docChanged || u.viewportChanged,
    initialSpacer: view => new NumberMarker(visualRowAt(view, view.contentHeight)),
    updateSpacer: (spacer, u) => new NumberMarker(visualRowAt(u.view, u.view.contentHeight)),
  }),
];

// ---------- 共同編集: ほかの人のカーソル (名前つき) ----------

const setRemoteCursors = StateEffect.define();
class RemoteCaret extends WidgetType {
  constructor(name, color) { super(); this.name = name; this.color = color; }
  eq(o) { return o.name === this.name && o.color === this.color; }
  toDOM() {
    const s = document.createElement('span');
    s.className = 'cm-remote-caret';
    s.style.borderLeftColor = this.color;
    const label = document.createElement('span');
    label.className = 'cm-remote-name';
    label.style.background = this.color;
    label.textContent = this.name;
    s.append(label);
    return s;
  }
  ignoreEvent() { return true; }
}
const remoteCursorsField = StateField.define({
  create: () => Decoration.none,
  update(value, tr) {
    for (const e of tr.effects) {
      if (!e.is(setRemoteCursors)) continue;
      const n = tr.state.doc.length;
      const ranges = [];
      for (const c of e.value) {
        const from = Math.max(0, Math.min(n, c.loc)), to = Math.max(from, Math.min(n, c.loc + c.len));
        if (to > from) ranges.push(Decoration.mark({ attributes: { style: `background-color: ${c.color}40` } }).range(from, to));
        ranges.push(Decoration.widget({ widget: new RemoteCaret(c.name, c.color), side: 1 }).range(to));
      }
      return Decoration.set(ranges, true);
    }
    return tr.docChanged ? value.map(tr.changes) : value;
  },
  provide: f => EditorView.decorations.from(f),
});

/// 置き換える文字列 (正規表現のときは $1 $& などを展開する)
function replacementFor(query, spec, value) {
  const text = typeof query.unquote === 'function' ? query.unquote(spec.replace || '') : (spec.replace || '');
  if (!spec.regexp || !value.match) return text;
  return text.replace(/\$([$&]|\d+)/g, (m, i) => {
    if (i === '$') return '$';
    if (i === '&') return value.match[0];
    return i !== '0' && Number(i) < value.match.length ? (value.match[Number(i)] || '') : m;
  });
}

function tabCommand(view) {
  const state = view.state;
  // 範囲を選んでいたら (1 行の中でも)、その行をまとめて右へずらす
  if (state.selection.ranges.some(r => !r.empty)) return indentMore(view);
  const unit = state.facet(indentUnit);
  view.dispatch(state.changeByRange(range => {
    let insert = '\t';
    if (unit !== '\t') {
      const line = state.doc.lineAt(range.from);
      const col = countColumn(line.text.slice(0, range.from - line.from), state.tabSize);
      insert = ' '.repeat(state.tabSize - (col % state.tabSize));
    }
    return { changes: { from: range.from, to: range.to, insert }, range: EditorSelection.cursor(range.from + insert.length) };
  }), { userEvent: 'input', scrollIntoView: true });
  return true;
}

/// 1 つの文書ぶんのエディタ。上下に分割したときは 2 つ目の画面 (secondary) が同じ文章を映す
export class Editor {
  constructor({ parent, text, onChange, onSelection, onFocus, onLink }) {
    this.onChange = onChange || (() => {});
    this.onSelection = onSelection || (() => {});
    this.onFocus = onFocus || (() => {});
    this.onLink = onLink || (() => {});
    this.secondary = null;
    this.lastFocused = null;
    this.c = {
      wrap: new Compartment(), numbers: new Compartment(), invisibles: new Compartment(), active: new Compartment(),
      links: new Compartment(), language: new Compartment(), enter: new Compartment(), readOnly: new Compartment(),
      completion: new Compartment(),
    };
    /// 拡張機能 (JS) からの候補を足すとき
    this.extraCompletions = null;
    this.config = { prefs: {}, profile: null };
    this.view = new EditorView({
      parent,
      state: EditorState.create({ doc: text || '', extensions: this.extensions(true) }),
      dispatchTransactions: (trs, view) => this.dispatchFrom(view, trs),
    });
    this.lastFocused = this.view;
  }

  extensions(primary) {
    const self = this;
    const c = this.c;
    const p = this.config.prefs, profile = this.config.profile;
    return [
      primary ? history() : [],
      c.completion.of(self.completionExtension(p, profile)),
      keymap.of([
        // 候補が出ているときの Tab は「入れる」
        { key: 'Tab', run: v => (completionStatus(v.state) === 'active' ? acceptCompletion(v) : tabCommand(v)), shift: indentLess },
        // 分割した下の画面からの元に戻す・やり直しは、上の画面の履歴を使う
        ...(primary ? [] : [
          { key: 'Mod-z', run: () => undo(self.view), preventDefault: true },
          { key: 'Mod-y', run: () => redo(self.view), preventDefault: true },
          { key: 'Mod-Shift-z', run: () => redo(self.view), preventDefault: true },
        ]),
      ]),
      c.enter.of(self.enterExtension(p)),
      keymap.of([...defaultKeymap, ...(primary ? historyKeymap : [])]),
      drawSelection(), dropCursor(), rectangularSelection(), crosshairCursor(),
      EditorState.allowMultipleSelections.of(true),
      bracketMatching(),
      search({ createPanel: () => ({ dom: document.createElement('div') }) }),
      tokenField, tokenPlugin, baseTheme, remoteCursorsField, editMarksField,
      c.wrap.of(p.wrap ? EditorView.lineWrapping : []),
      c.numbers.of(self.numbersExtension(p)),
      c.invisibles.of(invisiblesPlugin(!!p.invisibles, !!p.showEOF)),
      c.active.of(p.highlightCurrentLine ? highlightActiveLine() : []),
      c.links.of(p.linkURLs ? linkPlugin : []),
      c.language.of(self.languageExtension(profile)),
      c.readOnly.of(self.readOnlyOn ? [EditorState.readOnly.of(true)] : []),
      EditorView.updateListener.of(u => {
        if (u.docChanged && u.view === self.view) self.onChange(u);
        if (u.selectionSet || u.docChanged || u.focusChanged) {
          if (u.view.hasFocus) self.lastFocused = u.view;
          self.onSelection(u.view);
        }
        if (u.focusChanged && u.view.hasFocus) self.onFocus(u.view);
        if (u.geometryChanged || u.viewportChanged || u.docChanged) self.onGeometry && self.onGeometry(u.view);
      }),
      EditorView.domEventHandlers({
        mousedown(event, view) {
          if (!(event.ctrlKey || event.metaKey) || event.button !== 0) return false;
          const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
          const url = pos === null ? null : linkAt(view.state, pos);
          if (!url || !self.config.prefs.linkURLs) return false;
          event.preventDefault();
          self.onLink(url);
          return true;
        },
        scroll(event, view) { self.onGeometry && self.onGeometry(view); },
        // ファイルを放り込んだら、中身を入れずに開く (開くのはウインドウの drop で)。Alt を押していれば、これまでどおり
        drop(event) {
          const files = event.dataTransfer && event.dataTransfer.files;
          return !!(files && files.length && !event.altKey);
        },
      }),
    ];
  }

  /// 入力補完: プログラムのファイルでは打つと候補が出る。ただのテキストでは Ctrl+Space のときだけ
  completionExtension(p, profile) {
    const self = this;
    const getProfile = () => self.config.profile;
    const auto = p.codeCompletion !== false && !!profile;
    return [
      autocompletion({
        override: [completionSource(getProfile, info => (self.extraCompletions ? self.extraCompletions(info) : []))],
        activateOnTyping: auto, maxRenderedOptions: 60, icons: true, closeOnBlur: true,
      }),
      auto ? signatureHint(getProfile) : [],
    ];
  }

  numbersExtension(p) {
    if (!p.lineNumbers) return [];
    return [this.countsVisual(p) ? visualLineNumbers : lineNumbers(), highlightActiveLineGutter()];
  }

  /// ワープロ的に数えるか (折り返さない表示では、見た目の行と改行の行が同じなのでエディタ的に数える)
  countsVisual(p) { const q = p || this.config.prefs; return q.lineCounting === 'visual' && !!q.wrap; }

  enterExtension(p) {
    return keymap.of([{ key: 'Enter', run: p.autoIndent === false ? insertNewline : insertNewlineKeepIndent }]);
  }

  languageExtension(profile) {
    const tab = profile ? profile.tabWidth : 4;
    const spaces = profile ? profile.useSpaces : false;
    const comment = {};
    if (profile && profile.lineComments.length) comment.line = profile.lineComments[0].trim();
    if (profile && profile.blockComments.length) comment.block = { open: profile.blockComments[0][0], close: profile.blockComments[0][1] };
    return [
      EditorState.tabSize.of(tab),
      indentUnit.of(spaces ? ' '.repeat(tab) : '\t'),
      scannerFacet.of(profile ? makeScanner(profile) : null),
      EditorState.languageData.of(() => [{ commentTokens: comment }]),
    ];
  }

  dispatchFrom(view, trs) {
    view.update(trs);
    const other = view === this.view ? this.secondary : this.view;
    if (!other) return;
    for (const tr of trs) {
      if (tr.changes.empty || tr.annotation(syncAnnotation)) continue;
      const annotations = [syncAnnotation.of(true)];
      const userEvent = tr.annotation(Transaction.userEvent);
      if (userEvent) annotations.push(Transaction.userEvent.of(userEvent));
      other.dispatch({ changes: tr.changes, annotations });
    }
  }

  views() { return this.secondary ? [this.view, this.secondary] : [this.view]; }
  get active() { return this.lastFocused && this.views().includes(this.lastFocused) ? this.lastFocused : this.view; }

  /// 表示の設定と言語を反映する
  configure(prefs, profile) {
    this.config = { prefs: Object.assign({}, prefs), profile };
    const c = this.c, p = this.config.prefs;
    for (const v of this.views()) {
      v.dispatch({ effects: [
        c.wrap.reconfigure(p.wrap ? EditorView.lineWrapping : []),
        c.numbers.reconfigure(this.numbersExtension(p)),
        c.invisibles.reconfigure(invisiblesPlugin(!!p.invisibles, !!p.showEOF)),
        c.active.reconfigure(p.highlightCurrentLine ? highlightActiveLine() : []),
        c.links.reconfigure(p.linkURLs ? linkPlugin : []),
        c.language.reconfigure(this.languageExtension(profile)),
        c.enter.reconfigure(this.enterExtension(p)),
        c.completion.reconfigure(this.completionExtension(p, profile)),
      ] });
    }
  }

  remeasure() { for (const v of this.views()) v.requestMeasure(); }

  /// 保存したとき: 書き換えた所の目印を消す
  clearEditMarks() { for (const v of this.views()) v.dispatch({ effects: clearEditMarks.of(null) }); }

  /// 共同編集: ほかの人の変更を反映する (元に戻すの記録には入れない)
  applyRemoteOp(op) {
    const n = this.view.state.doc.length;
    const from = Math.max(0, Math.min(n, op.loc)), to = Math.max(from, Math.min(n, op.loc + op.len));
    this.view.dispatch({ changes: { from, to, insert: op.text }, annotations: [remoteAnnotation.of(true), Transaction.addToHistory.of(false)] });
  }

  /// 共同編集: ほかの人のカーソルを出す。list: [{ loc, len, name, color }]
  setRemoteCursors(list) {
    for (const v of this.views()) v.dispatch({ effects: setRemoteCursors.of(list) });
  }

  split(parent) {
    if (this.secondary) return;
    this.secondary = new EditorView({
      parent,
      state: EditorState.create({ doc: this.view.state.doc, extensions: this.extensions(false) }),
      dispatchTransactions: (trs, view) => this.dispatchFrom(view, trs),
    });
  }

  unsplit() {
    if (!this.secondary) return;
    this.secondary.destroy();
    this.secondary = null;
    this.lastFocused = this.view;
  }

  getText() { return this.view.state.doc.toString(); }

  /// 書き換えられないようにする (ロックしたファイル)
  setReadOnly(on) {
    this.readOnlyOn = !!on;
    const eff = this.c.readOnly.reconfigure(on ? [EditorState.readOnly.of(true)] : []);
    this.view.dispatch({ effects: eff });
    if (this.secondary) this.secondary.dispatch({ effects: eff });
  }

  /// いくつもの範囲を選ぶ (公開の前の個人情報の見直し)
  selectRanges(ranges) {
    const len = this.view.state.doc.length;
    const list = ranges.filter(r => r.to <= len).map(r => EditorSelection.range(r.from, r.to));
    if (!list.length) return;
    this.view.dispatch({ selection: EditorSelection.create(list, 0), scrollIntoView: true });
    this.view.focus();
  }

  /// 文章を丸ごと入れ替える。keepHistory が false なら「元に戻す」の記録もやり直す (開き直したとき)
  setText(text, keepHistory) {
    if (keepHistory) {
      this.view.dispatch({ changes: { from: 0, to: this.view.state.doc.length, insert: text }, annotations: loadAnnotation.of(true) });
      this.clearEditMarks();
      return;
    }
    const hadSecondary = this.secondary ? this.secondary.dom.parentNode : null;
    this.unsplit();
    this.view.setState(EditorState.create({ doc: text, extensions: this.extensions(true) }));
    if (hadSecondary) this.split(hadSecondary);
  }

  focus() { this.active.focus(); }
  destroy() { this.unsplit(); this.view.destroy(); }

  // ---------- 編集の操作 ----------

  run(command) { const v = this.active; const ok = command(v); v.focus(); return ok; }
  undo() { undo(this.view); this.active.focus(); }
  redo() { redo(this.view); this.active.focus(); }
  selectAll() { const v = this.active; v.dispatch({ selection: { anchor: 0, head: v.state.doc.length } }); v.focus(); }
  duplicateLine() { this.run(copyLineDown); }
  deleteLine() { this.run(deleteLine); }
  moveLineUp() { this.run(moveLineUp); }
  moveLineDown() { this.run(moveLineDown); }
  indent() { this.run(indentMore); }
  outdent() { this.run(indentLess); }
  toggleComment() { this.run(toggleComment); }
  jumpToBracket() { this.run(cursorMatchingBracket); }

  selectionRange() { const m = this.active.state.selection.main; return { from: m.from, to: m.to }; }

  /// from〜to を text に置き換えて、置き換えたところを選ぶ (元に戻せる)
  replaceRange(from, to, text) {
    const v = this.view;
    v.dispatch({ changes: { from, to, insert: text }, selection: { anchor: from, head: from + text.length }, scrollIntoView: true, userEvent: 'input' });
  }

  selectionText() {
    const s = this.active.state;
    return s.sliceDoc(s.selection.main.from, s.selection.main.to);
  }

  replaceSelection(text) {
    const v = this.active;
    v.dispatch(v.state.replaceSelection(text), { scrollIntoView: true, userEvent: 'input' });
    v.focus();
  }

  insertAtCursorEnd(text) {
    const v = this.active;
    const to = v.state.selection.main.to;
    v.dispatch({ changes: { from: to, insert: text }, selection: { anchor: to + text.length }, scrollIntoView: true, userEvent: 'input' });
    v.focus();
  }

  /// 選んでいる行 (選んでいなければ全部の行) を作り替える
  transformLines(fn) {
    const v = this.active, state = v.state, sel = state.selection.main;
    let from = 0, to = state.doc.length;
    if (!sel.empty) {
      from = state.doc.lineAt(sel.from).from;
      const endLine = state.doc.lineAt(sel.to);
      to = sel.to === endLine.from && sel.to > sel.from ? sel.to - 1 : endLine.to;
    }
    const before = state.sliceDoc(from, to);
    const after = fn(before.split('\n')).join('\n');
    if (after !== before) {
      v.dispatch({ changes: { from, to, insert: after }, selection: sel.empty ? undefined : { anchor: from, head: from + after.length }, userEvent: 'input' });
    }
    v.focus();
  }

  /// 選んでいる文字を作り替える (選んでいなければカーソルのある単語)
  transformSelection(fn) {
    const v = this.active, state = v.state;
    let { from, to } = state.selection.main;
    if (from === to) {
      const word = state.wordAt(from);
      if (!word) return;
      from = word.from; to = word.to;
    }
    const after = fn(state.sliceDoc(from, to));
    v.dispatch({ changes: { from, to, insert: after }, selection: { anchor: from, head: from + after.length }, userEvent: 'input' });
    v.focus();
  }

  goToLine(line, column, visual) {
    const v = this.active, doc = v.state.doc;
    if (visual && this.countsVisual()) {
      // 見た目で n 行目の頭へ。その行のあたりまで動かしてから、画面の位置で場所を決める
      const lh = Math.max(1, v.defaultLineHeight), top = (Math.max(1, line) - 1) * lh;
      const block = v.lineBlockAtHeight(top);
      v.dispatch({ selection: { anchor: block.from }, effects: EditorView.scrollIntoView(block.from, { y: 'center' }) });
      requestAnimationFrame(() => {
        const rect = v.contentDOM.getBoundingClientRect();
        const pos = v.posAtCoords({ x: rect.left + 2, y: v.documentTop + top + lh / 2 }, false);
        if (pos !== null) v.dispatch({ selection: { anchor: pos }, effects: EditorView.scrollIntoView(pos, { y: 'center' }) });
        v.focus();
      });
      return;
    }
    const l = doc.line(Math.max(1, Math.min(doc.lines, line)));
    const pos = Math.min(l.to, l.from + Math.max(0, (column || 1) - 1));
    v.dispatch({ selection: { anchor: pos }, effects: EditorView.scrollIntoView(pos, { y: 'center' }) });
    v.focus();
  }

  setCaret(pos) {
    const p = Math.max(0, Math.min(this.view.state.doc.length, pos));
    this.view.dispatch({ selection: { anchor: p }, effects: EditorView.scrollIntoView(p, { y: 'center' }) });
  }

  /// ステータスバーに出す情報
  info() {
    const v = this.active, state = v.state, sel = state.selection.main;
    const line = state.doc.lineAt(sel.head);
    let visual = null;
    if (this.countsVisual()) {
      const lh = Math.max(1, v.defaultLineHeight);
      const at = v.coordsAtPos(sel.head, sel.assoc || 1);
      const blockTop = v.lineBlockAt(sel.head).top;
      const top = at ? at.top - v.documentTop : blockTop;
      visual = { line: visualRowAt(v, Math.max(0, top - (at ? (lh - (at.bottom - at.top)) / 2 : 0))), lines: Math.max(1, visualRowAt(v, v.contentHeight - 4 - lh)) };
    }
    return {
      visual,
      line: line.number,
      column: countColumn(line.text.slice(0, sel.head - line.from), state.tabSize) + 1,
      displayColumn: displayWidth(line.text.slice(0, sel.head - line.from).replace(/\t/g, ' ')) + 1,
      lines: state.doc.lines, length: state.doc.length,
      selected: state.selection.ranges.reduce((n, r) => n + (r.to - r.from), 0),
      head: sel.head,
    };
  }

  // ---------- 検索 ----------

  setSearch(spec) {
    const query = new SearchQuery({
      search: spec.text, caseSensitive: !!spec.caseSensitive, regexp: !!spec.regexp, wholeWord: !!spec.wholeWord,
      replace: spec.replace || '', literal: !spec.regexp,
    });
    for (const v of this.views()) {
      v.dispatch({ effects: setSearchQuery.of(query) });
      if (spec.highlight === false) closeSearchPanel(v); else openSearchPanel(v);
    }
    return query;
  }

  clearSearchHighlight() { for (const v of this.views()) closeSearchPanel(v); }

  /// 次 (前) を探して選ぶ。見つからなければ false。wrap が false なら文書の端で止まる
  find(spec, backward) {
    const query = this.setSearch(spec);
    if (!query.valid) return { found: false, invalid: true };
    const v = this.active, state = v.state, sel = state.selection.main;
    let match = null, wrapped = false;
    const first = cursor => { const r = cursor.next(); return r.done ? null : r.value; };
    if (!backward) {
      match = first(query.getCursor(state, sel.to));
      // 空の一致で同じ場所にとどまらないように
      if (match && match.from === match.to && match.from === sel.from && sel.empty) match = first(query.getCursor(state, Math.min(state.doc.length, sel.to + 1)));
      if (!match && spec.wrap !== false) { match = first(query.getCursor(state, 0)); wrapped = !!match; }
    } else {
      const lastBefore = limit => {
        let found = null;
        const cur = query.getCursor(state, 0, limit);
        for (let r = cur.next(); !r.done; r = cur.next()) found = r.value;
        return found;
      };
      match = lastBefore(sel.from);
      if (!match && spec.wrap !== false) { match = lastBefore(state.doc.length); wrapped = !!match; }
    }
    if (!match) return { found: false };
    v.dispatch({ selection: { anchor: match.from, head: match.to }, effects: EditorView.scrollIntoView(match.from, { y: 'center' }), userEvent: 'select.search' });
    return { found: true, wrapped };
  }

  count(spec) {
    const query = this.setSearch(spec);
    if (!query.valid) return -1;
    let n = 0;
    const cur = query.getCursor(this.view.state);
    for (let r = cur.next(); !r.done && n < 100000; r = cur.next()) n += 1;
    return n;
  }

  /// いま選んでいるところが一致していれば置き換えて、次を探す
  replaceOne(spec) {
    const query = this.setSearch(spec);
    if (!query.valid) return { found: false, invalid: true };
    const v = this.active, state = v.state, sel = state.selection.main;
    const r = query.getCursor(state, sel.from).next();
    if (!r.done && r.value.from === sel.from && r.value.to === sel.to) {
      const insert = replacementFor(query, spec, r.value);
      v.dispatch({ changes: { from: sel.from, to: sel.to, insert }, selection: { anchor: sel.from + insert.length }, userEvent: 'input.replace' });
    }
    return this.find(spec, false);
  }

  /// すべて置き換える (inSelection なら選んでいる範囲だけ)。置き換えた数を返す
  replaceAll(spec, inSelection) {
    const query = this.setSearch(spec);
    if (!query.valid) return -1;
    const v = this.active, state = v.state, sel = state.selection.main;
    const from = inSelection && !sel.empty ? sel.from : 0;
    const to = inSelection && !sel.empty ? sel.to : state.doc.length;
    const changes = [];
    const cur = query.getCursor(state, from, to);
    for (let r = cur.next(); !r.done; r = cur.next()) {
      changes.push({ from: r.value.from, to: r.value.to, insert: replacementFor(query, spec, r.value) });
    }
    if (changes.length) v.dispatch({ changes, userEvent: 'input.replace.all' });
    return changes.length;
  }
}

/// 桁ルーラーを描く (10 桁ごとに数字、5 桁ごとに長い目盛り)
export function drawRuler(canvas, view, colors) {
  const dpr = window.devicePixelRatio || 1;
  const width = canvas.clientWidth, height = canvas.clientHeight;
  if (!width || !height) return;
  if (canvas.width !== Math.round(width * dpr) || canvas.height !== Math.round(height * dpr)) {
    canvas.width = Math.round(width * dpr);
    canvas.height = Math.round(height * dpr);
  }
  const g = canvas.getContext('2d');
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  g.fillStyle = colors.background;
  g.fillRect(0, 0, width, height);
  if (!view) return;
  const cw = view.defaultCharacterWidth;
  if (!cw || cw < 2) return;
  const line = view.contentDOM.querySelector('.cm-line');
  const canvasLeft = canvas.getBoundingClientRect().left;
  let x0 = view.contentDOM.getBoundingClientRect().left - canvasLeft + 6;
  if (line) x0 = line.getBoundingClientRect().left - canvasLeft + parseFloat(getComputedStyle(line).paddingLeft || '0');
  const gutters = view.dom.querySelector('.cm-gutters');
  const gutterRight = (gutters ? gutters.getBoundingClientRect().right : view.scrollDOM.getBoundingClientRect().left) - canvasLeft;
  g.save();
  g.beginPath();
  g.rect(Math.max(0, gutterRight), 0, width, height);
  g.clip();
  g.strokeStyle = colors.text;
  g.fillStyle = colors.text;
  g.font = '10px "Segoe UI", sans-serif';
  g.textBaseline = 'top';
  g.lineWidth = 1;
  const start = Math.max(0, Math.floor((gutterRight - x0) / cw));
  const end = Math.ceil((width - x0) / cw);
  g.beginPath();
  for (let col = start; col <= end; col++) {
    const x = Math.round(x0 + col * cw) + 0.5;
    const tick = col % 10 === 0 ? height : (col % 5 === 0 ? 7 : 4);
    g.moveTo(x, height);
    g.lineTo(x, height - tick);
    if (col % 10 === 0) g.fillText(String(col), x + 2, 0);
  }
  g.stroke();
  g.restore();
  g.fillStyle = colors.separator;
  g.fillRect(0, height - 1, width, 1);
}
