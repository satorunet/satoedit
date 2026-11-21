// AI アシスタント (右の欄) と、その設定
import { h, modal, alertBox, toast } from './dialogs';
import i18n from '../../shared/i18n';
import menuDef from '../../shared/menu';
import aiModels from '../../shared/aimodels';
import aiAnswer from '../../shared/aianswer';
import { popupMenu } from './dialogs';
import { icon } from './icons';
import { slidePane } from './util';

const { t } = i18n;
const LIMIT = 100000;
/// 長い答えは、ひとこと・中身ともにこの行数で畳む
const COLLAPSED_LINES = 4;
// 答えを「ユーザーへのひとこと」と「文章に入れる中身」に分けてもらう (中身は <result> で囲む)
const FORMAT_EDIT = '\n\n出力の形: はじめにユーザーへのひとこと (1〜2 文。何をしたか) を書き、そのあと文章に入れる内容だけを <result> と </result> で囲んで出力してください。';
const FORMAT_ASK = '\n\n出力の形: はじめにユーザーへのひとこと (1〜2 文) を書いてください。文章やコードを書く・直す・足す・消すなど、エディタの中身を変える依頼なら、そのあとエディタに入れる内容だけを <result> と </result> で囲んで出力してください (コードも ``` ではなく <result> で囲む)。エディタの中身を変えない質問への答えのときだけ、<result> を使わないでください。';
// 自分で書いた頼みごとは、置き換えに使えるよう「直した全文」を返してもらう (一部だけ返されると、置き換えで残りが消えるため)
const FULL_TEXT = '\n\n(文章を変える依頼なら、入れる内容には、変えていない部分も含めて対象の文章を省略せずに全部入れてください。)';
const SYSTEM = 'あなたはテキストエディタ「さとるエディタ」に組み込まれた文章作成アシスタントです。依頼された結果だけを出力し、前置きや締めの言葉は書かないでください。元の文章がマークダウンを使っていない限り、マークダウンの装飾は使わないでください。';

// 接続先 (本体側の core/ai.js と同じ並び。最初が既定の ChatGPT)
export const PROVIDERS = [
  { id: 'openai', label: 'ChatGPT (OpenAI)', defaultModel: '', keyPage: 'https://platform.openai.com/api-keys',
    guide: '1. 「キーを取りに行く」でキーを作る\n2. 下に貼り、「一覧を取得」でモデルを選ぶ\n3. 「接続テスト」' },
  { id: 'claude', label: 'Claude (Anthropic)', defaultModel: 'claude-opus-5-5', keyPage: 'https://platform.claude.com/',
    guide: '1. 「キーを取りに行く」でキーを作る\n2. 下に貼って「接続テスト」' },
  { id: 'gemini', label: 'Gemini (Google)', defaultModel: '', keyPage: 'https://aistudio.google.com/apikey',
    guide: '1. 「キーを取りに行く」でキーを作る\n2. 下に貼り、「一覧を取得」でモデルを選ぶ\n3. 「接続テスト」' },
  { id: 'custom', label: 'カスタム (OpenAI 互換 API: Ollama・LM Studio など)', defaultModel: '', keyPage: '',
    guide: 'Ollama などに接続します (例: http://localhost:11434/v1)。\nキーは空でも OK。「一覧を取得」→「接続テスト」' },
];
// 文章の書き換えを AI にどこまで任せるか
export const APPLY_MODES = [
  ['auto', '自動で書き換える'],
  ['confirm', '確認してから書き換える'],
  ['never', '書き換えない (読むだけ)'],
];
const providerOf = id => PROVIDERS.find(p => p.id === id) || PROVIDERS[0];

function modelOf(app, id) { return (app.prefs.aiModels || {})[id] || providerOf(id).defaultModel; }
/// 「接続テスト」に成功したときの設定のままかどうか
// (モデルを替えても確かめ直しは要らない。キーや接続先のアドレスを変えたら、もう一度確かめる)
function fingerprint(app, id) { return 'ok|' + (id === 'custom' ? app.prefs.aiCustomBaseURL : ''); }
export function isVerified(app, id) {
  return !!modelOf(app, id) && (app.prefs.aiVerified || {})[id] === fingerprint(app, id);
}

/// AI アシスタントの欄。依頼と答えが、チャットのように上から順に積み上がる。
/// (1 回ごとの依頼は独立していて、前の答えを覚えて続きを話すわけではない。毎回、いまの文章を対象にする)
export class AIPanel {
  constructor(app) {
    this.app = app;
    this.jobs = new Map();
    this.running = null;
    const pane = app.el.aiPane;
    this.provider = h('div', { class: 'ai-provider dim' });
    this.badge = h('span', { class: 'ai-badge', role: 'status' });
    this.notice = h('div', { class: 'ai-notice' }, h('div', {}, t('まだ使えません。AI の設定をして「接続テスト」で確認してください。')),
      h('button', { onclick: () => openAISettings(app) }, t('設定を開く')));
    this.log = h('div', { class: 'ai-log', role: 'log', 'aria-label': t('AI とのやりとり'), tabindex: '0' });
    this.empty = h('div', { class: 'ai-empty dim' }, t('頼みたいことを書いて送るか、入力欄の「…」から定型の依頼を選びます。範囲を選んでいればその部分、選んでいなければ文書全体が対象です。'));
    this.log.append(this.empty);
    this.actionButtons = [];
    // 入力欄の「…」: 定型の依頼 (校正・要約・続きを書く など) を選ぶ
    this.templateButton = h('button', { class: 'ai-template', title: t('定型の依頼 (校正・要約・続きを書く など) を選ぶ'), 'aria-label': t('定型の依頼を選ぶ'),
      onclick: e => {
        const r = e.currentTarget.getBoundingClientRect();
        const ready = isVerified(app, app.prefs.aiProvider || 'openai') && !this.running;
        // 見やすく: 大きめの字・広めの幅で、ボタンの上に出す (下の入力欄に重ならないよう。Mac 版と同じ)
        popupMenu([{ label: t('定型の依頼'), header: true }, ...menuDef.AI_ACTIONS.map(a => ({ label: t(a.title), disabled: !ready, action: () => this.runAction(a.id) }))],
          Math.min(r.left, window.innerWidth - 248), r.top - 2, { alignBottom: true, className: 'ai-template-menu' });
      } }, '…');
    this.detachButton = h('button', { class: 'icon-button', title: t('別のウインドウに取り出す'), 'aria-label': t('別のウインドウに取り出す'), onclick: () => this.toggleDetached() }, '⧉');
    // 文章の書き換えをどこまで AI に任せるか
    this.applyMode = h('select', { class: 'ai-apply-mode', 'aria-label': t('AI による書き換え'), onchange: e => { app.setPref('aiApply', e.target.value); this.refresh(); } },
      APPLY_MODES.map(([id, label]) => h('option', { value: id }, t(label))));
    this.prompt = h('textarea', { class: 'ai-input', rows: '1', placeholder: t('AI に頼みたいことを書く'), 'aria-label': t('AI に頼みたいことを書く') });
    this.sendButton = h('button', { class: 'ai-send', title: t('送信 (Enter)'), 'aria-label': t('送信'), onclick: () => this.runCustom() }, '↑');
    this.stopButton = h('button', { class: 'ai-send stop', hidden: true, title: t('中止'), 'aria-label': t('中止'), onclick: () => this.cancel() }, '■');
    pane.append(
      h('div', { class: 'ai-head' }, h('strong', {}, t('AI アシスタント')), this.badge, h('span', { class: 'tb-space' }),
        this.detachButton,
        h('button', { class: 'icon-button', title: t('メニュー (設定など)'), 'aria-label': t('メニュー (設定など)'), onclick: e => this.headerMenu(e.currentTarget) }, '≡'),
        // 取り出しているときの ✕ は、閉じずにエディタの横に戻す (Mac 版と同じ)
        h('button', { class: 'icon-button', title: t('閉じる'), 'aria-label': t('閉じる'), onclick: () => { if (this.detached) this.toggleDetached(); else app.setPref('aiVisible', false); } }, '✕')),
      this.provider, this.notice, this.log,
      h('div', { class: 'ai-composer' }, this.prompt, this.templateButton, this.sendButton, this.stopButton),
      h('div', { class: 'ai-foot' }, h('span', { class: 'dim' }, t('Enter で送信 ・ Shift+Enter で改行')), h('span', { class: 'tb-space' }), this.applyMode));
    this.prompt.addEventListener('keydown', e => {
      if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && e.keyCode !== 229) { e.preventDefault(); this.runCustom(); }
    });
    // 書いた行数に合わせて入力欄を伸ばす
    this.prompt.addEventListener('input', () => this.growInput());
    app.api.on('ai:delta', (id, text) => { const job = this.jobs.get(id); if (job) job.onDelta(text); });
    app.api.on('ai:done', (id, result) => { const job = this.jobs.get(id); if (job) { this.jobs.delete(id); job.onDone(result); } });
    // 左の端をドラッグして幅を変える
    this.resizer = h('div', { class: 'ai-resizer', title: t('ドラッグで幅を変える') });
    pane.prepend(this.resizer);
    pane.style.width = (app.prefs.aiWidth || 340) + 'px';
    let dragging = false;
    this.resizer.addEventListener('mousedown', e => { if (!this.detached) { dragging = true; e.preventDefault(); } });
    window.addEventListener('mousemove', e => {
      if (!dragging) return;
      const right = pane.getBoundingClientRect().right;
      pane.style.width = Math.max(260, Math.min(Math.min(900, window.innerWidth - 300), right - e.clientX)) + 'px';
      app.scheduleRuler();
    });
    window.addEventListener('mouseup', () => {
      if (!dragging) return;
      dragging = false;
      app.prefs.aiWidth = parseInt(pane.style.width, 10) || 340;
      app.api.setPref('aiWidth', app.prefs.aiWidth);
    });
    this.refresh();
  }

  /// 「≡」: やりとりを消す・利用状況・設定・ローカル LLM
  headerMenu(el) {
    const r = el.getBoundingClientRect();
    popupMenu([
      { label: t('やりとりを消す'), action: () => this.clear() },
      { label: t('利用状況と料金…'), action: () => openAIUsage(this.app) },
      { label: t('AI の設定…'), action: () => openAISettings(this.app) },
      { label: t('ローカルLLM簡単設定…'), action: () => this.app.run('ai.localLLM') },
    ], r.left - 160, r.bottom + 2);
  }

  /// 欄を取り出して、ウインドウの中に浮かせる (見出しをつかんで動かし、右下で大きさを変える) / 元に戻す
  toggleDetached() {
    const pane = this.app.el.aiPane;
    this.detached = !this.detached;
    pane.classList.toggle('detached', this.detached);
    this.detachButton.textContent = this.detached ? '⇤' : '⧉';
    this.detachButton.title = this.detached ? t('エディタの横に戻す') : t('別のウインドウに取り出す');
    if (this.detached) {
      const r = pane.getBoundingClientRect();
      Object.assign(pane.style, { left: Math.max(20, r.left - 40) + 'px', top: (r.top + 30) + 'px', height: Math.min(600, r.height - 40) + 'px' });
    } else {
      Object.assign(pane.style, { left: '', top: '', height: '' });
      pane.style.width = (this.app.prefs.aiWidth || 340) + 'px';
    }
    this.app.scheduleRuler();
    this.updateTab();
    if (!this.dragReady) {
      this.dragReady = true;
      let drag = null;
      pane.querySelector('.ai-head').addEventListener('mousedown', e => {
        if (!this.detached || e.target.closest('button')) return;
        const r = pane.getBoundingClientRect();
        drag = { dx: e.clientX - r.left, dy: e.clientY - r.top };
        e.preventDefault();
      });
      window.addEventListener('mousemove', e => {
        if (!drag) return;
        pane.style.left = Math.max(0, Math.min(window.innerWidth - 120, e.clientX - drag.dx)) + 'px';
        pane.style.top = Math.max(0, Math.min(window.innerHeight - 60, e.clientY - drag.dy)) + 'px';
      });
      window.addEventListener('mouseup', () => { drag = null; });
    }
  }

  /// 書いた文字に合わせて入力欄を高くする (折り返して、欄の高さの 4 割まで。それより長いと中で動かす)
  growInput() {
    const pane = this.app.el.aiPane, el = this.prompt;
    const limit = Math.max(140, Math.min(360, (pane.clientHeight || 500) * 0.4));
    el.style.height = 'auto';
    const want = el.scrollHeight;
    el.style.height = Math.min(limit, want) + 'px';
    el.style.overflowY = want > limit ? 'auto' : 'hidden';
  }

  /// 出す / しまう (右はしから、欄ごと滑らせる)。しまっているあいだは右はしに小さなつまみ
  setVisible(on) {
    const pane = this.app.el.aiPane;
    const now = pane.dataset.sliding ? pane.dataset.sliding === 'in' : !pane.hidden;
    if (now !== on) {
      if (this.detached) { pane.hidden = !on; this.app.scheduleRuler(); } else slidePane(pane, on, false, () => this.app.scheduleRuler());
    }
    if (on) this.refresh();
    this.updateTab();
  }

  /// 右はしのつまみ (AI の欄を閉じているときに出す。押すと開く)
  updateTab() {
    const app = this.app;
    if (!this.tab) {
      this.tab = h('button', { id: 'ai-tab', title: t('AI アシスタントを開く'), 'aria-label': t('AI アシスタントを開く'), onclick: () => {
        if (isVerified(app, app.prefs.aiProvider || 'openai')) app.setPref('aiVisible', true); else openAISettings(app);
      } }, icon('ai', 16));
      document.getElementById('main').append(this.tab);
    }
    this.tab.hidden = !(app.prefs.aiEnabled && !app.prefs.aiVisible && !this.detached);
  }

  refresh() {
    const app = this.app, id = app.prefs.aiProvider || 'openai';
    const ready = isVerified(app, id);
    const mode = app.prefs.aiApply || 'confirm';
    this.provider.textContent = `${providerOf(id).label.split(' (')[0]}${modelOf(app, id) ? ' · ' + modelOf(app, id) : ''}`;
    this.notice.hidden = ready;
    this.badge.textContent = ready ? '●' : t('未設定'); // 使えるときは緑の印だけ
    this.badge.className = 'ai-badge ' + (ready ? 'ok' : 'off');
    this.badge.title = ready ? t('接続を確認済みです。AI を使えます。') : t('まだ使えません。AI の設定をして「接続テスト」で確認してください。');
    for (const b of this.actionButtons) b.disabled = !ready || !!this.running;
    this.templateButton.disabled = !ready || !!this.running;
    this.sendButton.hidden = !!this.running;
    this.stopButton.hidden = !this.running;
    this.sendButton.disabled = !ready;
    this.applyMode.value = mode;
    // 「書き換えない」のときは、挿入・置き換えを使えなくする (コピーだけ)
    for (const b of this.log.querySelectorAll('.ai-apply')) b.disabled = mode === 'never' || !!this.running;
    app.updateStatus();
  }

  clear() {
    if (this.running) this.cancel();
    this.log.textContent = '';
    this.log.append(this.empty);
  }

  scrollDown() { this.log.scrollTop = this.log.scrollHeight; }

  runAction(id) {
    const a = menuDef.AI_ACTIONS.find(x => x.id === id);
    if (a) this.run(t(a.instruction), a.apply, t(a.title));
  }

  runCustom() {
    const instruction = this.prompt.value.trim();
    if (!instruction || this.running) return;
    this.prompt.value = '';
    this.growInput();
    // 自分で書いた頼みごと。「自動で書き換える」のときは、答えの中身で対象を置き換える
    this.run(instruction, 'ask', instruction);
  }

  /// applyKind: 答えの使い方 ('replace' = 対象を置き換える, 'insert' = 対象のあとに足す, 'none' = 読むだけ, 'ask' = 自分で決める)
  async run(instruction, applyKind, shown) {
    const app = this.app, tab = app.active;
    if (this.running) return;
    if (!isVerified(app, app.prefs.aiProvider || 'openai')) { openAISettings(app); return; }
    if (tab.enc) { await alertBox(t('暗号化した文書は送りません'), t('暗号化を解除してから使ってください。')); return; }
    if (tab.paper) app.syncFromPaper(tab);
    // 対象の場所を覚えておく (答えを待つあいだに選択が変わっても、もとの場所を書き換えられるように)
    const whole = tab.getText();
    const range = tab.target().selectionRange();
    const selected = range.to > range.from ? whole.slice(range.from, range.to) : '';
    const text = selected || whole;
    if (text.length > LIMIT) { await alertBox(t('長すぎて送れません'), t('{n} 文字まで。範囲を選んで分けて送ってください。', { n: LIMIT.toLocaleString() })); return; }
    const job = { tab, from: selected ? range.from : 0, to: selected ? range.to : whole.length, original: text, applyKind: applyKind || 'ask', text: '' };

    // やりとりに、依頼 (右) と答え (左) を足す
    this.empty.remove();
    const targetNote = selected ? t('対象: 選んでいる {n} 文字', { n: selected.length }) : t('対象: 文書全体');
    this.log.append(h('div', { class: 'ai-msg user' }, h('div', { class: 'ai-text' }, shown || instruction), h('div', { class: 'ai-meta ai-target' }, `${tab.name} ・ ${targetNote}`)));
    const body = h('div', { class: 'ai-text collapsed' }, h('span', { class: 'ai-typing' }, '…'));
    const content = h('pre', { class: 'ai-content collapsed', hidden: true });
    const toggle = h('button', { class: 'ai-toggle link-button', hidden: true });
    const usage = h('span', { class: 'ai-meta ai-usage', hidden: true });
    const confirm = h('div', { class: 'ai-confirm', hidden: true });
    let usageText = '';
    // 右下の角の「⋮」: 挿入・置き換え・コピー・使った量
    const more = h('button', { class: 'ai-more', hidden: true, title: t('挿入・置き換え・使った量'), 'aria-label': t('挿入・置き換え・使った量'),
      onclick: e => {
        const r = e.currentTarget.getBoundingClientRect();
        const canApply = (app.prefs.aiApply || 'confirm') !== 'never' && !this.running;
        const items = [
          { label: t('挿入'), disabled: !canApply, action: () => this.apply(job, 'insert', confirm) },
          { label: t('置き換え'), disabled: !canApply, action: () => this.apply(job, 'replace', confirm) },
          { label: t('コピー'), action: () => { app.api.copyText(applyText(job)); toast(t('コピーしました')); } },
        ];
        if (usageText) items.push('sep', { label: usageText, disabled: true });
        popupMenu(items, r.left - 150, r.bottom + 2);
      } }, '⋮');
    let collapsed = true;
    const render = () => {
      const p = aiAnswer.split(job.text);
      if (p.content !== null) {
        body.textContent = p.message;
        body.hidden = !p.message;
        content.textContent = p.content;
        content.hidden = false;
      } else {
        body.textContent = p.message || job.text;
        body.hidden = false;
        content.hidden = true;
      }
      // 長いときだけ「全部表示 / たたむ」
      const long = [body, content].some(el => !el.hidden && el.scrollHeight > el.clientHeight + 2);
      const n = (p.content !== null ? p.content : (p.message || job.text)).split('\n').length;
      toggle.hidden = !(long || !collapsed);
      toggle.textContent = collapsed ? t('▼ 全部表示 ({n} 行)', { n }) : t('▲ たたむ');
    };
    toggle.onclick = () => {
      collapsed = !collapsed;
      body.classList.toggle('collapsed', collapsed);
      content.classList.toggle('collapsed', collapsed);
      render();
    };
    const answer = h('div', { class: 'ai-msg ai' }, body, content, toggle, confirm, usage, more);
    answer.style.setProperty('--ai-lines', String(COLLAPSED_LINES));
    this.log.append(answer);
    this.scrollDown();

    const id = 'ai' + Date.now() + Math.random().toString(36).slice(2, 6);
    this.running = id;
    this.refresh();
    const format = job.applyKind === 'ask' ? t(FORMAT_ASK) : (job.applyKind === 'none' ? '' : t(FORMAT_EDIT));
    const full = job.applyKind === 'ask' && text.trim() ? t(FULL_TEXT) : '';
    const prompt = text.trim() ? `${instruction}${full}${format}\n\n${t('対象の文章:')}\n<<<\n${text}\n>>>` : instruction + format;
    this.jobs.set(id, {
      onDelta: piece => {
        const atBottom = this.log.scrollHeight - this.log.scrollTop - this.log.clientHeight < 40;
        job.text += piece;
        render();
        if (atBottom) this.scrollDown();
      },
      onDone: result => {
        this.running = null;
        if (result.error) {
          body.textContent = (job.text ? job.text + '\n\n' : '') + result.error;
          answer.classList.add('error');
        } else {
          if (!job.text) body.textContent = result.cancelled ? '' : t('(答えが空でした)');
          else render();
          // 中止したことだけは答えの下に見せる。使った量は「⋮」の中へ
          if (result.cancelled) { usage.textContent = t('中止しました'); usage.hidden = false; }
          else if (result.usage) {
            const u = result.usage;
            usageText = t('入力 {a} / 出力 {b} トークン', { a: u.inputTokens.toLocaleString(), b: u.outputTokens.toLocaleString() }) + (u.estimated ? ' ' + t('(見積もり)') : '');
          }
          more.hidden = !job.text;
        }
        this.refresh();
        if (!result.error && !result.cancelled && job.text) this.finished(job, confirm);
        this.scrollDown();
      },
    });
    app.api.aiSend(id, { system: t(SYSTEM), prompt });
  }

  /// 答えが出そろったあと: 設定に応じて、自動で書き換えるか、確かめるか、何もしないか
  finished(job, confirm) {
    const mode = this.app.prefs.aiApply || 'confirm';
    if (mode === 'never' || job.applyKind === 'none') return;
    // 自分で書いた頼みごとで、入れる中身がない (質問への答え) ときは書き換えない
    if (job.applyKind === 'ask' && aiAnswer.split(job.text).content === null) return;
    const how = job.applyKind === 'insert' ? 'insert' : 'replace';
    if (mode === 'auto') { this.apply(job, how, confirm); return; }
    // 確認してから書き換える
    const replace = how === 'replace';
    confirm.textContent = '';
    confirm.append(
      h('div', {}, replace ? t('この答えで、対象の文章を置き換えますか？') : t('この答えを、対象の文章のあとに足しますか？')),
      h('div', { class: 'form-row' },
        h('button', { class: 'primary', onclick: () => this.apply(job, how, confirm) }, replace ? t('置き換える') : t('足す')),
        h('button', { onclick: () => { confirm.hidden = true; } }, t('書き換えない'))));
    confirm.hidden = false;
  }

  cancel() {
    if (this.running) this.app.api.aiCancel(this.running);
  }

  /// 答えを文章に入れる。how: 'replace' = 頼んだときの対象 (選んでいた範囲、なければ文書全体) を置き換える、'insert' = 対象のあとに足す
  apply(job, how, confirm) {
    const app = this.app;
    if (!job || !job.text) return;
    // 入れるのは中身だけ (ユーザーへのひとことは入れない)
    const text = applyText(job);
    if (!text) return;
    if ((app.prefs.aiApply || 'confirm') === 'never') return;
    if (confirm) confirm.hidden = true;
    if (!app.tabs.includes(job.tab)) { toast(t('もとの文書が閉じられています。コピーして使ってください。')); return; }
    if (job.tab.paper) app.syncFromPaper(job.tab);
    const now = job.tab.getText();
    // 待っているあいだに文章が変わっていたら、もとの文章を探し直す
    let from = job.from, to = job.to;
    if (now.slice(from, to) !== job.original) {
      const at = job.original ? now.indexOf(job.original) : -1;
      if (at < 0 || now.indexOf(job.original, at + 1) >= 0) {
        alertBox(t('書き換えられませんでした'), t('頼んだあとに文章が変わったので、置き換える場所が分からなくなりました。「コピー」して貼り付けてください。'));
        return;
      }
      from = at; to = at + job.original.length;
    }
    if (how === 'replace') {
      app.replaceRange(job.tab, from, to, text);
      job.from = from;
      job.to = from + text.length;
      job.original = text;
      toast(t('置き換えました (Ctrl+Z で戻せます)'));
    } else {
      const piece = (to === 0 || now.slice(to - 1, to) === '\n' ? '' : '\n') + text;
      app.replaceRange(job.tab, to, to, piece);
      toast(t('足しました (Ctrl+Z で戻せます)'));
    }
    if (app.active !== job.tab) app.activate(job.tab);
    // 名前のない文書なら、中身から言語の見当をつけて色分けする
    app.guessLanguageIfUnnamed(job.tab);
  }
}

/// 文章に入れるもの: <result> の中身。囲みがなければ答え全体
function applyText(job) {
  const p = aiAnswer.split(job.text || '');
  return p.content !== null ? p.content : (job.text || '');
}

/// AI の設定のダイアログ (接続先・キー・モデル・接続テスト)
export async function openAISettings(app) {
  const api = app.api;
  let status = await api.aiStatus();
  let current = app.prefs.aiProvider || 'openai';
  const select = h('select', {}, PROVIDERS.map(p => h('option', { value: p.id, selected: p.id === current }, t(p.label))));
  const guide = h('div', { class: 'ai-guide' });
  const keyInput = h('input', { type: 'password', class: 'wide', autocomplete: 'off', placeholder: t('API キー') });
  const keyState = h('span', { class: 'dim' });
  const keyLink = h('button', {}, t('キーを取りに行く'));
  const baseRow = h('div', { class: 'form-row' });
  const baseInput = h('input', { type: 'text', class: 'wide', value: app.prefs.aiCustomBaseURL || '' });
  baseRow.append(h('label', {}, t('アドレス')), baseInput);
  const modelInput = h('input', { type: 'text', class: 'wide', list: 'ai-models', placeholder: t('モデル名') });
  const modelList = h('datalist', { id: 'ai-models' });
  const presets = h('div', { class: 'kind-list', role: 'radiogroup', 'aria-label': t('モデル') });
  const customRow = h('div', { class: 'form-row' });
  const banner = h('div', { class: 'ai-banner', role: 'status' });
  const yen = app.prefs.aiYenPerDollar || 150;
  /// 「入力 $0.10 / 出力 $0.50 ・ 1,000 字の校正で 約 ¥0.1」のような料金の説明
  const priceText = model => {
    const p = aiModels.priceOf(model, app.init.aiPriceOverrides);
    if (!p) return t('料金不明 (利用状況の画面で単価を入れると計算します)');
    const y = aiModels.sampleCost(p) * yen;
    let text = t('入力 ${a} / 出力 ${b} (100 万トークン) ・ 日本語 1,000 字の校正で 約 ¥{c}', { a: p.input, b: p.output, c: y < 10 ? y.toFixed(y < 1 ? 2 : 1) : Math.round(y) });
    const change = aiModels.upcomingChange(model);
    if (change) text += ' ' + t('({date} から 入力 ${a} / 出力 ${b})', { date: change.from, a: change.input, b: change.output });
    return text;
  };
  /// いまのモデルが、かんたん選択のどれに当たるか ('fast' | 'quality' | 'custom')
  let choice = 'custom';
  const renderPresets = () => {
    const set = aiModels.PRESETS[current];
    const model = modelInput.value.trim();
    presets.textContent = '';
    const option = (id, label, name, note) => h('label', { class: 'kind-row' },
      h('input', { type: 'radio', name: 'ai-preset', checked: choice === id, onchange: () => { choice = id; if (name) modelInput.value = name; renderPresets(); } }),
      h('span', {}, h('span', { class: 'kind-label' }, label + (name ? ' — ' + name : '')), h('span', { class: 'dim kind-note' }, note)));
    if (set) {
      presets.append(
        option('fast', t('最安 & 最速 (おすすめ)'), set.fast, priceText(set.fast)),
        option('quality', t('内容重視'), set.quality, priceText(set.quality)));
    }
    presets.append(option('custom', t('自分で選ぶ'), '', choice === 'custom' && model ? priceText(model) : t('一覧から好きなモデルを選びます。')));
    customRow.hidden = choice !== 'custom';
  };
  const pickChoice = () => {
    const set = aiModels.PRESETS[current], model = modelInput.value.trim();
    choice = set && model === set.fast ? 'fast' : set && model === set.quality ? 'quality' : 'custom';
    // まだ何も選んでいなければ、最安 & 最速を選んでおく
    if (set && !model) { choice = 'fast'; modelInput.value = set.fast; }
  };
  const result = h('div', { class: 'ai-test', role: 'status' });
  const say = (text, kind) => { result.textContent = text; result.className = 'ai-test ' + (kind || ''); };

  const saveInputs = async () => {
    if (keyInput.value.trim()) {
      const r = await api.aiSetKey(current, keyInput.value.trim());
      if (r.status !== 'ok') { say(r.message, 'warn'); return false; }
      keyInput.value = '';
      status = await api.aiStatus();
      const verified = Object.assign({}, app.prefs.aiVerified || {});
      delete verified[current]; // キーを変えたら、接続テストをやり直す
      app.prefs.aiVerified = verified;
      api.setPref('aiVerified', verified);
    }
    const models = Object.assign({}, app.prefs.aiModels || {});
    models[current] = modelInput.value.trim();
    app.prefs.aiModels = models;
    api.setPref('aiModels', models);
    if (current === 'custom') { app.prefs.aiCustomBaseURL = baseInput.value.trim(); api.setPref('aiCustomBaseURL', app.prefs.aiCustomBaseURL); }
    app.prefs.aiProvider = current;
    api.setPref('aiProvider', current);
    return true;
  };
  const show = () => {
    const p = providerOf(current);
    guide.textContent = t(p.guide);
    keyLink.hidden = !p.keyPage;
    baseRow.hidden = current !== 'custom';
    modelInput.value = modelOf(app, current);
    modelList.textContent = '';
    pickChoice();
    renderPresets();
    keyState.textContent = status[current] && status[current].hasKey ? t('キーは保存済み (変えるときだけ入れ直す)') : (current === 'custom' ? t('キーなしでも使えます') : t('キーはまだありません'));
    say('', 'ok');
    showBanner();
  };
  const showBanner = () => {
    const ok = isVerified(app, current);
    banner.textContent = ok ? '✓ ' + t('AI 利用可能 (接続を確認済み)') : t('まだ使えません。キーを入れて「接続テスト」を押してください。');
    banner.className = 'ai-banner ' + (ok ? 'ok' : 'off');
  };
  modelInput.addEventListener('input', renderPresets);
  select.addEventListener('change', () => { current = select.value; show(); });
  keyLink.addEventListener('click', () => api.openExternal(providerOf(current).keyPage));

  const listButton = h('button', { onclick: async () => {
    if (!(await saveInputs())) return;
    say(t('一覧を取得しています…'));
    const r = await api.aiListModels(current);
    if (r.status !== 'ok') { say(r.message, 'warn'); return; }
    modelList.textContent = '';
    for (const m of r.models) modelList.append(h('option', { value: m }));
    say(t('{n} 個のモデルが見つかりました。モデル名の欄から選んでください。', { n: r.models.length }), 'ok');
    if (!modelInput.value && r.models.length) modelInput.value = r.models[0];
    renderPresets();
    modelInput.focus();
  } }, t('一覧を取得'));

  const testButton = h('button', { class: 'primary', onclick: async () => {
    if (!(await saveInputs())) return;
    if (!modelInput.value.trim()) { say(t('モデルを選んでください'), 'warn'); return; }
    say(t('接続を確かめています…'));
    testButton.disabled = true;
    const id = 'aitest' + Date.now();
    const done = await new Promise(resolve => {
      let got = '';
      app.ai.jobs.set(id, { onDelta: x => { got += x; }, onDone: r => resolve(Object.assign({ got }, r)) });
      api.aiSend(id, { provider: current, model: modelInput.value.trim(), system: 'You are a connection test.', prompt: 'Reply with the single word: OK', noLog: true });
    });
    testButton.disabled = false;
    if (done.error) { say(done.error, 'warn'); return; }
    const verified = Object.assign({}, app.prefs.aiVerified || {});
    verified[current] = fingerprint(app, current);
    app.prefs.aiVerified = verified;
    api.setPref('aiVerified', verified);
    say(t('つながりました。使えます。'), 'ok');
    showBanner();
    app.ai.refresh();
  } }, t('接続テスト'));

  show();
  await modal({
    title: t('AI の設定'), width: 540, noEnter: true,
    body: h('div', {},
      banner,
      h('div', { class: 'form-row' }, h('label', {}, t('接続先')), select),
      guide,
      h('div', { class: 'form-row' }, h('label', {}, t('API キー')), keyInput, keyLink),
      h('div', { class: 'form-row' }, h('label', {}), keyState),
      baseRow,
      h('div', { class: 'top-gap' }, t('モデル (かんたん選択)')), presets,
      (customRow.append(h('label', {}, t('モデル')), modelInput, modelList, listButton), customRow),
      h('div', { class: 'form-row' }, h('label', {}), testButton),
      result,
      h('div', { class: 'dim top-gap' }, t('API キーは、Windows のログインに結び付けて暗号化し、この PC の中だけに保存します。')),
      h('div', { class: 'dim' }, t('料金はアプリに入っている一覧表 ({date} に確認) による目安です。', { date: aiModels.UPDATED }))),
    buttons: [{ label: t('閉じる'), value: true, primary: true, cancel: true, validate: saveInputs }],
  });
  app.ai.refresh();
}

/// 料金の表示 ($ と、だいたいの円)
function money(dollars, unknown, yen) {
  if (dollars === 0 && unknown) return t('料金不明');
  let s;
  if (dollars === 0) s = '$0';
  else {
    const y = dollars * yen;
    s = (dollars < 0.01 ? '$' + dollars.toFixed(4) : '$' + dollars.toFixed(2)) + ' (' + t('約 ¥{n}', { n: y < 10 ? y.toFixed(1) : Math.round(y).toLocaleString() }) + ')';
  }
  return s + (unknown ? ' + ' + t('料金不明の分') : '');
}

/// AI の利用状況と料金のダイアログ
export async function openAIUsage(app) {
  const api = app.api;
  const body = h('div', {});
  const render = async () => {
    const u = await api.aiUsage();
    const line = s => t('{n} 回 ・ 入力 {a} / 出力 {b} トークン', { n: s.count, a: s.input.toLocaleString(), b: s.output.toLocaleString() });
    const card = (title, s) => h('div', { class: 'usage-card' }, h('div', { class: 'dim' }, title), h('div', { class: 'usage-cost' }, money(s.cost, s.unknownCost, u.yen)), h('div', { class: 'dim' }, line(s)));
    const provider = app.prefs.aiProvider || 'openai';
    const mine = (u.prices || {})[provider] || {};
    const inPrice = h('input', { type: 'number', min: '0', step: '0.01', value: mine.input || '', placeholder: u.current && !u.current.custom ? String(u.current.input) : '', style: { width: '90px' } });
    const outPrice = h('input', { type: 'number', min: '0', step: '0.01', value: mine.output || '', placeholder: u.current && !u.current.custom ? String(u.current.output) : '', style: { width: '90px' } });
    const yen = h('input', { type: 'number', min: '1', step: '1', value: u.yen, style: { width: '80px' } });
    const savePrices = async () => {
      const prices = Object.assign({}, app.prefs.aiPrices || {});
      const i = Number(inPrice.value) || 0, o = Number(outPrice.value) || 0;
      if (i > 0 || o > 0) prices[provider] = { input: i, output: o }; else delete prices[provider];
      app.prefs.aiPrices = prices;
      await api.setPref('aiPrices', prices);
      app.prefs.aiYenPerDollar = Math.max(1, Number(yen.value) || 150);
      await api.setPref('aiYenPerDollar', app.prefs.aiYenPerDollar);
      render();
    };
    const page = (u.pages || {})[provider];
    body.textContent = '';
    body.append(
      h('div', { class: 'usage-cards' }, card(t('今日'), u.summary.today), card(t('今月'), u.summary.month), card(t('これまで'), u.summary.total)),
      h('table', { class: 'usage-table' },
        h('thead', {}, h('tr', {}, [t('月'), t('回数'), t('入力トークン'), t('出力トークン'), t('料金の目安')].map(x => h('th', {}, x)))),
        h('tbody', {}, u.summary.months.length
          ? u.summary.months.map(m => h('tr', {}, h('td', {}, m.month), h('td', {}, m.count), h('td', {}, m.input.toLocaleString()), h('td', {}, m.output.toLocaleString()), h('td', {}, money(m.cost, m.unknownCost, u.yen))))
          : h('tr', {}, h('td', { colspan: '5', class: 'dim' }, t('まだ記録がありません'))))),
      h('div', { class: 'settings-box' },
        h('div', {}, t('単価 (US ドル / 100 万トークン): {name}', { name: (PROVIDERS.find(p => p.id === provider) || PROVIDERS[0]).label.split(' (')[0] })),
        h('div', { class: 'form-row' }, h('label', {}, t('入力')), inPrice, h('label', { style: { minWidth: '0' } }, t('出力')), outPrice,
          page ? h('button', { onclick: () => api.openExternal(page) }, t('料金のページを開く')) : null),
        h('div', { class: 'form-row' }, h('label', {}, t('1 ドル')), yen, t('円'), h('span', { class: 'tb-space' }), h('button', { class: 'primary', onclick: savePrices }, t('単価を保存'))),
        h('div', { class: 'dim' }, t('料金は目安です。正しい金額は、各サービスの請求を見てください。単価を空にすると、公開されている料金 (分かるものだけ) を使います。'))),
      h('div', { class: 'form-row' }, h('button', { onclick: async () => {
        if (!(await modal({ title: t('利用の記録を消しますか？'), body: '', buttons: [{ label: t('消す'), value: true, primary: true }, { label: t('キャンセル'), value: false, cancel: true }] }))) return;
        await api.aiUsageClear();
        render();
      } }, t('記録を消す'))));
  };
  await render();
  await modal({ title: t('AI の利用状況と料金'), width: 640, noEnter: true, body, buttons: [{ label: t('閉じる'), value: true, primary: true, cancel: true }] });
}
