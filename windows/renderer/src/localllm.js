// 「ローカルLLM簡単設定」: 自分の PC の中で動く軽い LLM (Ollama) を、入れる・選ぶ・つなぐ を 1 つの画面で。
// 文章は外に送られず、料金もかからない (Mac 版と同じ流れ)
import { h, floatWindow, confirmBox, alertBox, toast } from './dialogs';
import i18n from '../../shared/i18n';
import llm from '../../shared/localllm';

const { t } = i18n;
let current = null;

export function openLocalLLM(app) {
  if (current) return;
  const api = app.api;
  const state = { status: null, required: { build: llm.FALLBACK_MIN_BUILD, checked: false }, installing: null, pulling: null, pullProgress: null };

  const stateIcon = h('span', { class: 'llm-dot' }, '●');
  const stateText = h('span', {});
  const compat = h('div', { class: 'llm-compat' });
  const installBtn = h('button', { class: 'primary', onclick: () => install() }, t('Ollama を自動で入れる'));
  const pageBtn = h('button', { onclick: () => api.openExternal(llm.DOWNLOAD_PAGE) }, t('公式ページを開く…'));
  const startBtn = h('button', { onclick: async () => { await api.llmStart(); stateText.textContent = t('起動しています…'); } }, t('Ollama を起動する'));
  const bar = h('progress', { class: 'llm-bar', max: '1', value: '0', hidden: true });
  const barText = h('span', { class: 'dim llm-bar-text' });
  const table = h('div', { class: 'llm-table' });
  const nameField = h('input', { type: 'text', placeholder: t('ほかのモデルの名前 (例: phi4-mini)'), style: { width: '220px' } });
  const currentText = h('div', { class: 'llm-current' });

  const body = h('div', { class: 'llm' },
    h('div', { class: 'llm-lead dim' }, t('文章は外に送られません。料金もかかりません。軽いモデルなので、短い文章の手直しや、ちょっとしたコード向きです (長い文書は、範囲を選んで頼んでください)。')),
    h('div', { class: 'llm-box' }, h('div', { class: 'llm-box-title' }, t('1. Ollama (AI を動かす無料のソフト)')),
      h('div', { class: 'llm-state' }, stateIcon, stateText), compat,
      h('div', { class: 'form-row' }, installBtn, pageBtn, startBtn, bar, barText)),
    h('div', { class: 'llm-box' }, h('div', { class: 'llm-box-title' }, t('2. モデルを入れて「使う」')), table,
      h('div', { class: 'form-row' }, nameField, h('button', { onclick: () => pull(nameField.value.trim()) }, t('入れる')),
        h('span', { class: 'tb-space' }), h('button', { onclick: () => api.openExternal('https://ollama.com/library') }, t('モデルの一覧を見る…')))),
    h('div', { class: 'llm-box' }, h('div', { class: 'llm-box-title' }, t('いまの接続先')), currentText));

  const win = floatWindow({ id: 'localllm', title: t('ローカルLLM簡単設定'), body, width: 640, onClose: () => { clearInterval(timer); current = null; } });
  current = win;

  const offInstall = api.on('llm:install', p => {
    if (!state.installing) return;
    const f = p.total ? p.got / p.total : null;
    bar.hidden = false;
    if (f === null) bar.removeAttribute('value'); else bar.value = String(f);
    barText.textContent = f === null ? llm.sizeText(p.got) : t('ダウンロードしています… {p}% ({a} / {b})', { p: Math.floor(f * 100), a: llm.sizeText(p.got), b: llm.sizeText(p.total) });
  });
  const offPull = api.on('llm:pull', (name, p) => {
    if (state.pulling !== name) return;
    state.pullProgress = p;
    render();
  });
  void offInstall; void offPull;

  const osText = () => {
    const s = state.status;
    if (!s || s.platform !== 'win32') return 'Windows';
    return `Windows (${s.release})`;
  };
  /// この PC の Windows で動くか (入れる前に確かめる)
  const compatible = () => {
    const s = state.status;
    if (!s || s.platform !== 'win32') return true; // 画面の確認用 (Windows 以外) は止めない
    return s.build >= state.required.build;
  };

  function render() {
    const s = state.status;
    const running = !!(s && s.running), installed = !!(s && s.installed);
    if (!s) { stateIcon.style.color = 'var(--chrome-dim)'; stateText.textContent = t('確かめています…'); }
    else if (running) { stateIcon.style.color = '#28c840'; stateText.textContent = t('Ollama は動いています。'); }
    else if (installed) { stateIcon.style.color = '#f0a020'; stateText.textContent = t('Ollama は入っていますが、動いていません。「Ollama を起動する」を押してください。'); }
    else if (state.installing) { stateIcon.style.color = '#3b82f6'; stateText.textContent = t('入れています…'); }
    else { stateIcon.style.color = '#f0a020'; stateText.textContent = t('Ollama がまだ入っていません。「Ollama を自動で入れる」を押すと、公式サイトから取ってきて、正規の配布ファイルかを確かめてから入れます。'); }
    // 入れる前の確かめ: この PC の Windows で動くか
    const ok = compatible();
    const source = state.required.checked ? t('公式の説明書で確認') : t('アプリに入っている情報で判断');
    compat.textContent = ok
      ? '✓ ' + t('この PC ({os}) は Ollama に対応しています。({src})', { os: osText(), src: source })
      : '✗ ' + t('この PC ({os}) では Ollama は動きません。Windows 10 の 22H2 (ビルド {b}) 以降が必要です。Windows Update で新しくしてください。({src})', { os: osText(), b: state.required.build, src: source });
    compat.className = 'llm-compat ' + (ok ? 'ok' : 'ng');
    compat.hidden = installed;
    installBtn.hidden = installed;
    pageBtn.hidden = installed;
    installBtn.disabled = !!state.installing || !ok;
    startBtn.hidden = !(installed && !running);
    bar.hidden = !state.installing;
    if (!state.installing) barText.textContent = '';

    // おすすめ + それ以外に入っているもの
    const have = s ? s.models : [];
    const rows = llm.RECOMMENDED.map(r => {
      const m = have.find(x => llm.sameModel(x.name, r.name));
      return { name: r.name, note: t(r.note), size: m ? llm.sizeText(m.size) : t('約 {n} GB', { n: r.sizeGB.toFixed(1) }), installed: !!m };
    });
    for (const m of have) if (!llm.RECOMMENDED.some(r => llm.sameModel(r.name, m.name))) rows.push({ name: m.name, note: t('入っているモデル'), size: llm.sizeText(m.size), installed: true });
    if (state.pulling && !rows.some(r => llm.sameModel(r.name, state.pulling))) rows.push({ name: state.pulling, note: '', size: '', installed: false });
    const p = app.prefs;
    const inUse = name => p.aiProvider === 'custom' && String(p.aiCustomBaseURL || '').includes('11434') && llm.sameModel((p.aiModels || {}).custom || '', name);
    table.textContent = '';
    for (const r of rows) {
      const isPulling = state.pulling && llm.sameModel(state.pulling, r.name);
      let middle = h('span', { class: 'dim' }, r.note);
      if (isPulling) {
        const f = state.pullProgress && state.pullProgress.fraction;
        const pb = h('progress', { max: '1' });
        if (f !== null && f !== undefined) pb.value = String(f);
        middle = h('span', { class: 'llm-pull' }, pb, h('span', {}, f !== null && f !== undefined ? Math.floor(f * 100) + '%' : '…'));
      }
      const main = h('button', {
        class: r.installed && !inUse(r.name) ? 'primary' : '',
        disabled: isPulling ? false : (!running || (r.installed && inUse(r.name)) || (!r.installed && !!state.pulling)),
        onclick: () => (isPulling ? api.llmCancelPull() : r.installed ? use(r.name) : pull(r.name)),
      }, isPulling ? t('中止') : r.installed ? (inUse(r.name) ? t('使用中') : t('使う')) : t('入れる'));
      const del = r.installed && !isPulling ? h('button', { disabled: !running, onclick: () => remove(r.name) }, t('消す')) : null;
      table.append(h('div', { class: 'llm-row' },
        h('span', { class: 'llm-name' }, (inUse(r.name) ? '● ' : '') + r.name), h('span', { class: 'llm-size dim' }, r.size),
        h('span', { class: 'llm-note' }, middle), h('span', { class: 'llm-actions' }, main, del)));
    }
    const usingLocal = p.aiProvider === 'custom' && String(p.aiCustomBaseURL || '').includes('11434');
    currentText.textContent = usingLocal
      ? t('AI アシスタントは、ローカルの「{name}」を使います。', { name: (p.aiModels || {}).custom || '' })
      : t('AI アシスタントは、いまほかの接続先につないでいます。上の一覧で「使う」を押すと、ローカルの AI に切り替わります。');
  }

  async function refresh() {
    try { state.status = await api.llmStatus(); } catch (_) { /* そのまま */ }
    render();
  }

  async function install() {
    if (!compatible()) return;
    if (!(await confirmBox(t('Ollama を入れますか？'), t('公式サイト (ollama.com) から配布ファイルを取ってきて (約 2 GB)、正規の署名かを確かめてから、インストールの画面を開きます。少し時間がかかります。'), t('入れる')))) return;
    state.installing = true;
    render();
    const r = await api.llmInstall();
    state.installing = null;
    if (!r.ok) {
      const msg = /signature/.test(r.error) ? t('正規の配布ファイルだと確かめられなかったので、入れませんでした') : r.error;
      if (!/cancelled/.test(r.error)) await alertBox(t('Ollama を入れられませんでした'), msg);
    } else {
      toast(t('インストールの画面を開きました。終わると、ここが自動で緑になります'));
    }
    refresh();
  }

  async function pull(name) {
    if (!name) return;
    if (!llm.isValidModelName(name)) { await alertBox(t('モデルの名前が正しくありません'), name); return; }
    if (state.pulling) { await alertBox(t('いま別のモデルを入れています'), t('終わってから、もう一度押してください。')); return; }
    state.pulling = name;
    state.pullProgress = null;
    render();
    const r = await api.llmPull(name);
    state.pulling = null;
    if (!r.ok && !/cancelled/.test(r.error)) await alertBox(t('「{name}」を入れられませんでした', { name }), r.error);
    else if (r.ok) toast(t('「{name}」を入れました', { name }));
    refresh();
  }

  async function remove(name) {
    if (!(await confirmBox(t('「{name}」を消しますか？', { name }), t('モデルのファイルを PC から消します。あとでまた入れられます。'), t('消す')))) return;
    await api.llmDelete(name);
    refresh();
  }

  /// AI アシスタントの接続先を、このモデルにする
  function use(name) {
    const base = llm.OPENAI_BASE;
    app.setPref('aiCustomBaseURL', base);
    app.setPref('aiModels', Object.assign({}, app.prefs.aiModels, { custom: name }));
    app.setPref('aiVerified', Object.assign({}, app.prefs.aiVerified, { custom: 'ok|' + base }));
    app.setPref('aiProvider', 'custom');
    if (!app.prefs.aiEnabled) app.setPref('aiEnabled', true); // ローカルなので、外に送る前の確認は要らない
    if (app.ai) app.ai.refresh();
    toast(t('AI アシスタントを「{name}」につなぎました', { name }));
    render();
  }

  render();
  api.llmRequiredBuild().then(r => { state.required = r; render(); }).catch(() => {});
  refresh();
  // 入れ終わった・起動したのに気づけるよう、開いているあいだは 2 秒ごとに見直す
  const timer = setInterval(refresh, 2000);
}
