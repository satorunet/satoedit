// 設定の画面: 動作環境 / ファイルタイプ別の設定 / 色・フォント / 追加機能
import { h, modal, confirmBox, promptBox, toast, popupMenu } from './dialogs';
import { openAISettings } from './aipanel';
import { KINDS } from './cryptoui';
import i18n from '../../shared/i18n';
import menuDef from '../../shared/menu';
import themeDef from '../../shared/theme';
import profilesDef from '../../shared/profiles';
import { backupPane } from './backup';

const { t } = i18n;
const ICON_COLORS = [['ai', '藍'], ['shu', '朱'], ['hinoki', 'ひのき緑'], ['sumi', '墨'], ['yamabuki', '山吹'], ['murasaki', '紫'], ['asagi', '浅葱'], ['kinari', '生成り']];
const FONT_CANDIDATES = ['BIZ UDGothic', 'MS Gothic', 'BIZ UDMincho', 'MS Mincho', 'Yu Gothic', 'Meiryo', 'Consolas', 'Cascadia Mono', 'Courier New', 'Osaka-Mono', 'Menlo'];

const box_ = (title, ...children) => box(title, ...children);
function box(title, ...children) {
  return h('fieldset', { class: 'settings-box' }, h('legend', {}, title), ...children);
}

// ---------- 動作環境 ----------

function generalPane(app) {
  const check = (label, key) => h('label', { class: 'check-row' },
    h('input', { type: 'checkbox', checked: !!app.prefs[key], onchange: e => app.setPref(key, e.target.checked) }), label);
  const select = (key, options, convert = x => x) => h('select', { onchange: e => app.setPref(key, convert(e.target.value)) },
    options.map(([value, label]) => h('option', { value, selected: String(app.prefs[key]) === String(value) }, label)));
  return h('div', {},
    box(t('表示'),
      h('div', { class: 'form-row' }, h('label', {}, t('起動したときの表示')),
        select('startPaperMode', [['last', t('前回と同じ')], ['genko', t('原稿用紙')], ['normal', t('標準エディタ')], ['a4', t('A4用紙')]])),
      h('div', { class: 'dim' }, t('アプリを開いたときの白紙を、どの表示で始めるか。「前回と同じ」は、最後に使っていた表示で始めます。')),
      check(t('折り返して表示する'), 'wrap'),
      check(t('改行・タブ・空白 (全角・半角) の記号を表示する'), 'invisibles'),
      check(t('[EOF] を表示する'), 'showEOF'),
      check(t('行番号を表示する'), 'lineNumbers'),
      check(t('桁ルーラーを表示する'), 'columnRuler'),
      check(t('ツールバーを表示する'), 'toolbar'),
      check(t('カーソル行に色を付ける'), 'highlightCurrentLine'),
      check(t('URL・メールアドレスをリンクにする (Ctrl + クリックで開く)'), 'linkURLs'),
      h('div', { class: 'form-row' }, h('label', {}, t('行の数え方')),
        select('lineCounting', [['logical', t('エディタ的 (改行ごとに 1 行)')], ['visual', t('ワープロ的 (折り返しも 1 行)')]])),
      h('div', { class: 'form-row' }, h('label', {}, t('行間')),
        select('lineSpacing', [0, 1, 2, 3, 4, 6, 8].map(n => [n, n === 0 ? t('なし') : `${n} px` + (n === 2 ? ' ' + t('(標準)') : '')]), Number)),
      h('div', { class: 'form-row' }, h('label', {}, t('表示の言語 (Language)')),
        h('select', { onchange: e => app.run('app.language:' + e.target.value) },
          i18n.LANGUAGES.map(l => h('option', { value: l.id, selected: (app.prefs.language || 'auto') === l.id }, t(l.label)))))),
    box(t('編集'),
      check(t('改行したとき前の行のインデントを引き継ぐ (自動インデント)'), 'autoIndent'),
      check(t('プログラムを書くとき、入力中に候補と関数の引数を出す (入力補完)'), 'codeCompletion'),
      check(t('ファイルを開いたとき、前回のカーソル位置に戻す'), 'rememberCaret'),
      h('div', { class: 'dim' }, t('タブ幅は「ファイルタイプ別の設定」で。'))),
    box(t('ファイル'),
      h('div', { class: 'form-row' }, h('label', {}, t('新規ファイルの文字コード')), select('defaultEncoding', menuDef.ENCODINGS)),
      h('div', { class: 'form-row' }, h('label', {}, t('新規ファイルの改行コード')), select('defaultLineEnding', menuDef.LINE_ENDINGS)),
      check(t('上書き保存の前にバックアップ (ファイル名.bak) を作る'), 'backupOnSave'),
      check(t('保存するとき行末の空白を削除する'), 'trimTrailingOnSave')),
    box(t('アップデート'),
      check(t('アップデートを自動で確認'), 'autoUpdateCheck'),
      h('div', { class: 'dim' }, t('起動したときに、新しい版が出ていないかを GitHub で確かめます (1 日に 1 回まで)。')),
      h('div', { class: 'form-row' }, h('button', { class: 'update-check-now', onclick: () => app.run('app.checkUpdate') }, t('アップデートを確認…')))),
    h('div', { class: 'dim' }, t('設定ファイルの場所: {dir}', { dir: app.init.configDir || '' })));
}

// ---------- ファイルタイプ別の設定 ----------

function fileTypesPane(app) {
  const pane = h('div', {});
  let selected = (app.active && app.active.profile ? app.active.profile.name : app.profiles[0].name);
  const render = () => {
    const p = app.profiles.find(x => x.name === selected) || app.profiles[0];
    selected = p.name;
    const builtIn = profilesDef.BUILT_IN.some(x => x.name === p.name);
    const customized = app.userProfiles.some(x => x.name === p.name);
    const text = (value, placeholder) => h('input', { type: 'text', class: 'wide', value, placeholder: placeholder || '' });
    const f = {
      extensions: text(p.extensions.join(' '), 'txt log'),
      fileNames: text(p.fileNames.join(' ')),
      tabWidth: h('input', { type: 'number', min: '1', max: '16', value: p.tabWidth, style: { width: '70px' } }),
      useSpaces: h('input', { type: 'checkbox', checked: p.useSpaces }),
      lineComments: text(p.lineComments.join(' '), '// #'),
      blockComments: text(p.blockComments.map(b => b.join(' ')).join(' , '), '/* */'),
      stringDelimiters: text(p.stringDelimiters.join(' ')),
      multilineStrings: text(p.multilineStrings.join(' ')),
      keywords: h('textarea', { class: 'wide', rows: '4' }, p.keywords.join(' ')),
      types: h('textarea', { class: 'wide', rows: '2' }, p.types.join(' ')),
      caseInsensitive: h('input', { type: 'checkbox', checked: p.caseInsensitive }),
      capitalizedIsType: h('input', { type: 'checkbox', checked: p.capitalizedIsType }),
      markupTags: h('input', { type: 'checkbox', checked: p.markupTags }),
    };
    const words = s => s.split(/\s+/).filter(Boolean);
    const save = () => {
      const next = profilesDef.normalize({
        name: p.name, extensions: words(f.extensions.value).map(x => x.replace(/^\*?\./, '')), fileNames: words(f.fileNames.value),
        tabWidth: f.tabWidth.value, useSpaces: f.useSpaces.checked,
        lineComments: words(f.lineComments.value),
        blockComments: f.blockComments.value.split(',').map(x => words(x)).filter(x => x.length === 2),
        stringDelimiters: words(f.stringDelimiters.value), multilineStrings: words(f.multilineStrings.value),
        keywords: words(f.keywords.value), types: words(f.types.value),
        caseInsensitive: f.caseInsensitive.checked, capitalizedIsType: f.capitalizedIsType.checked, markupTags: f.markupTags.checked,
      });
      app.userProfiles = app.userProfiles.filter(x => x.name !== p.name).concat([next]);
      app.api.saveUserProfiles(app.userProfiles);
      app.reloadProfiles();
      toast(t('「{name}」の設定を保存しました', { name: p.name }));
      render();
    };
    const row = (label, el) => h('div', { class: 'form-row' }, h('label', {}, label), el);
    pane.textContent = '';
    pane.append(
      h('div', { class: 'form-row' }, h('label', {}, t('言語')),
        h('select', { onchange: e => { selected = e.target.value; render(); } }, app.profiles.map(x => h('option', { value: x.name, selected: x.name === selected }, x.name))),
        h('button', { onclick: async () => {
          const name = await promptBox(t('言語を追加'), t('名前'), '');
          if (!name || !name.trim()) return;
          if (app.profiles.some(x => x.name === name.trim())) { toast(t('同じ名前の言語があります')); return; }
          app.userProfiles = app.userProfiles.concat([profilesDef.normalize({ name: name.trim() })]);
          app.api.saveUserProfiles(app.userProfiles);
          app.reloadProfiles();
          selected = name.trim();
          render();
        } }, t('追加…'))),
      box(t('このファイルに使う'), row(t('拡張子'), f.extensions), row(t('ファイル名'), f.fileNames)),
      box(t('タブ'), row(t('タブ幅'), f.tabWidth), h('label', { class: 'check-row' }, f.useSpaces, t('Tab キーでスペースを入れる'))),
      box(t('色分け'),
        row(t('行コメント'), f.lineComments), row(t('範囲コメント'), f.blockComments),
        row(t('文字列の区切り'), f.stringDelimiters), row(t('複数行の文字列'), f.multilineStrings),
        row(t('キーワード'), f.keywords), row(t('型名'), f.types),
        h('label', { class: 'check-row' }, f.caseInsensitive, t('大文字と小文字を区別しない')),
        h('label', { class: 'check-row' }, f.capitalizedIsType, t('大文字で始まる名前を型として色付けする')),
        h('label', { class: 'check-row' }, f.markupTags, t('<タグ> を色付けする (HTML / XML)'))),
      h('div', { class: 'form-row' },
        h('button', { class: 'primary', onclick: save }, t('この言語の設定を保存')),
        customized ? h('button', { onclick: async () => {
          if (!(await confirmBox(builtIn ? t('「{name}」を最初の設定に戻しますか？', { name: p.name }) : t('「{name}」を削除しますか？', { name: p.name }), '', builtIn ? t('戻す') : t('削除')))) return;
          app.userProfiles = app.userProfiles.filter(x => x.name !== p.name);
          app.api.saveUserProfiles(app.userProfiles);
          app.reloadProfiles();
          render();
        } }, builtIn ? t('最初の設定に戻す') : t('この言語を削除')) : null));
  };
  render();
  return pane;
}

// ---------- 色・フォント ----------

/// テーマの見本 (小さなエディタ画面)
function themePreview(preset, selected, onClick) {
  const c = preset.colors;
  const line = (n, parts, current) => h('div', { class: 'pv-line', style: { background: current ? c.currentLine : 'transparent' } },
    h('span', { class: 'pv-num', style: { color: current ? c.gutterCurrentText : c.gutterText, background: c.gutterBackground, borderRight: `1px solid ${c.gutterSeparator}` } }, n),
    h('span', { class: 'pv-text' }, parts.map(([text, key]) => h('span', { style: { color: c[key] } }, text))));
  return h('button', { class: 'theme-card' + (selected ? ' selected' : ''), 'aria-pressed': selected ? 'true' : 'false', onclick: onClick },
    h('div', { class: 'pv', style: { background: c.background, color: c.text } },
      line('1', [['// メモ', 'comment'], ['↓', 'newlineMark']]),
      line('2', [['const ', 'keyword'], ['x', 'text'], [' = ', 'text'], ['"文字"', 'string'], ['↓', 'newlineMark']], true),
      line('3', [['Type ', 'type'], ['42 ', 'number'], ['<a>', 'tag'], ['[EOF]', 'eof']]),
      h('div', { class: 'pv-status', style: { background: c.statusBackground, color: c.statusText } }, 'UTF-8')),
    h('div', { class: 'theme-name' }, (selected ? '✓ ' : '') + t(preset.name)));
}

function themePane(app) {
  const pane = h('div', {});
  let iconsOpen = false;
  const render = () => {
    const th = app.theme, colors = themeDef.colors(th);
    const fontNames = FONT_CANDIDATES.filter(n => { try { return document.fonts.check(`12px "${n}"`); } catch (e) { return true; } });
    if (!fontNames.includes(th.fontName)) fontNames.unshift(th.fontName);
    pane.textContent = '';
    pane.append(
      box(t('テーマ (見本をクリックして切り替え)'),
        h('div', { class: 'theme-gallery' }, themeDef.PRESETS.map(p => themePreview(p, p.name === th.preset, () => {
          th.preset = p.name; th.overrides = {}; app.saveTheme(); render();
        })))),
      box(t('ウインドウ・フォント'),
        h('div', { class: 'form-row' }, h('label', {}, t('ウインドウ枠の色')),
          h('select', { onchange: e => { th.windowStyle = e.target.value; app.saveTheme(); } },
            themeDef.WINDOW_STYLES.map(w => h('option', { value: w.key, selected: w.key === th.windowStyle }, t(w.label))))),
        h('div', { class: 'form-row' }, h('label', {}, t('フォント')),
          h('select', { onchange: e => { th.fontName = e.target.value; app.saveTheme(); } }, fontNames.map(n => h('option', { value: n, selected: n === th.fontName }, n))),
          h('input', { type: 'number', min: '6', max: '72', value: th.fontSize, style: { width: '64px' }, 'aria-label': t('文字の大きさ'),
            onchange: e => { th.fontSize = Math.max(6, Math.min(72, Number(e.target.value) || themeDef.DEFAULT_FONT_SIZE)); app.saveTheme(); } }), 'px'),
        // いまのアイコン 1 つだけを見せて、押したときだけ色の候補を出す
        h('div', { class: 'form-row' }, h('label', {}, t('アプリのアイコン')),
          h('button', { class: 'icon-color selected', title: t('押すと、ほかの色を選べます'), 'aria-label': t('アプリのアイコン'), 'aria-expanded': iconsOpen ? 'true' : 'false',
            onclick: () => { iconsOpen = !iconsOpen; render(); } },
            h('img', { src: `../assets/icons/${app.prefs.iconColor || 'ai'}.png`, alt: '', width: '30', height: '30' })),
          iconsOpen ? h('div', { class: 'icon-colors' }, ICON_COLORS.filter(([id]) => id !== (app.prefs.iconColor || 'ai')).map(([id, name]) => h('button', {
            class: 'icon-color', title: t(name), 'aria-label': t(name),
            onclick: () => { iconsOpen = false; app.setPref('iconColor', id); render(); },
          }, h('img', { src: `../assets/icons/${id}.png`, alt: '', width: '30', height: '30' })))) : h('span', { class: 'dim' }, t('押すと、ほかの色を選べます')))),
      box(t('色を 1 つずつ変える'),
        h('div', { class: 'dim' }, t('(*) の項目は、ウインドウ枠の色が「テーマに合わせる」以外のとき、変えない限り枠と同じ色になります。')),
        h('div', { class: 'color-grid' }, themeDef.ENTRIES.map(e => {
          const value = themeDef.normalizeHex(colors[e.key]) || '#000000';
          const changed = !!th.overrides[e.key];
          return h('div', { class: 'color-row' },
            h('input', { type: 'color', value: value.slice(0, 7), 'aria-label': t(e.label),
              oninput: ev => {
                const alpha = value.length === 9 ? value.slice(7) : '';
                const next = themeDef.normalizeHex(ev.target.value + alpha);
                if (next === themeDef.normalizeHex(themeDef.presetNamed(th.preset).colors[e.key])) delete th.overrides[e.key]; else th.overrides[e.key] = next;
                app.saveTheme();
              },
              onchange: () => render() }),
            h('span', { class: 'color-label' }, t(e.label)),
            changed ? h('button', { class: 'link-button', onclick: () => { delete th.overrides[e.key]; app.saveTheme(); render(); } }, t('戻す')) : null);
        })),
        h('div', { class: 'form-row top-gap' }, h('button', { onclick: () => { th.overrides = {}; app.saveTheme(); render(); } }, t('すべての色をテーマの色に戻す')))));
  };
  render();
  return pane;
}

// ---------- 追加機能 ----------

const FEATURE_ICONS = { encryption: '🔒', paper: '📜', folder: '🗂', ai: '✨', collab: '👥', server: '🖥' };

/// 「追加機能」: システム設定のような 1 行ずつの一覧。スイッチで入れたり外したりする。
/// 内蔵の機能と、JS で作られた拡張機能を同じように並べる (Mac 版と同じ形)
function featuresPane(app, opts = {}) {
  const pane = h('div', { class: 'features-list' });
  const open = {};
  if (opts.expand) open[opts.expand] = true;
  const sw = (on, onchange) => h('label', { class: 'switch', onclick: e => e.stopPropagation() },
    h('input', { type: 'checkbox', checked: on, onchange: e => onchange(e.target.checked) }), h('span', { class: 'switch-knob' }));
  const row = ({ key, on, icon, name, summary, extra, onToggle, details, dim }) => {
    const body = details && open[key] ? h('div', { class: 'feature-body' }, details()) : null;
    return h('div', { class: 'feature-row-wrap', 'data-key': key },
      h('div', { class: 'feature-row' + (dim ? ' dim-row' : ''), onclick: () => { if (details) { open[key] = !open[key]; render(); } } },
        sw(on, onToggle), extra || h('span', { class: 'feature-extra' }),
        h('span', { class: 'feature-icon' }, icon && icon.startsWith('data:') ? h('img', { src: icon, alt: '' }) : (icon || '🧩')),
        h('span', { class: 'feature-texts' }, h('span', { class: 'feature-name' }, name), h('span', { class: 'feature-summary-line', title: summary }, summary))),
      body);
  };
  const builtInDetails = f => () => {
    const on = !!app.prefs[f.pref];
    const box = h('div', {}, ...t(f.confirm).split('\n').map(line => h('div', { class: 'dim' }, line)));
    if (f.id === 'encryption') {
      box.append(
        h('label', { class: 'check-row top-gap' }, h('input', { type: 'checkbox', checked: !!app.prefs.encryptAlways, disabled: !on,
          onchange: e => app.setPref('encryptAlways', e.target.checked) }), t('いつも暗号化して保存する')),
        h('div', { class: 'top-gap' }, t('暗号化の方法 (最初に選ばれるものを選べます)')),
        h('div', { class: 'kind-list' }, KINDS.map(k => h('label', { class: 'kind-row' },
          h('input', { type: 'radio', name: 'default-kind', checked: (app.prefs.encDefaultKind || 'device') === k.id, onchange: () => app.setPref('encDefaultKind', k.id) }),
          h('span', {}, h('span', { class: 'kind-label' }, t(k.label)), h('span', { class: 'dim kind-note' }, t(k.note)))))));
    }
    if (f.id === 'ai') box.append(h('div', { class: 'top-gap form-row' }, h('button', { disabled: !on, onclick: () => openAISettings(app) }, t('AI の設定…')),
      h('button', { disabled: !on, onclick: () => app.run('ai.localLLM') }, t('ローカルLLM簡単設定…'))));
    if (f.id === 'library') box.append(h('div', { class: 'top-gap form-row' }, h('button', { onclick: () => { document.querySelectorAll('.settings-tab').forEach(b => { if (b.textContent === t('バックアップ')) b.click(); }); } }, t('詳細設定…'))));
    if (f.id === 'paper') {
      const check = (label, key) => h('label', { class: 'check-row' }, h('input', { type: 'checkbox', checked: !!app.prefs[key], disabled: !on, onchange: e => app.setPref(key, e.target.checked) }), label);
      // 切り替えの候補: ツールバーの用紙切替・用紙メニュー・下の欄に出すもの (Mac 版と同じ。1 つも無いときは標準エディタだけ)
      const shown = menuDef.paperCandidates(app.prefs);
      const pick = h('div', { class: 'paper-candidates' }, menuDef.PAPER_CANDIDATES.map(([id, label]) => h('label', { class: 'check-row' },
        h('input', { type: 'checkbox', 'data-paper': id, checked: shown.includes(id), disabled: !on, onchange: e => {
          const boxes = Array.from(e.target.closest('.paper-candidates').querySelectorAll('input[data-paper]'));
          app.setPref('paperCandidates', boxes.filter(b => b.checked).map(b => b.dataset.paper));
        } }), t(label))),
        h('div', { class: 'dim' }, t('ツールバーの用紙切替のボタンで、チェックしたものを順に切り替えます。')));
      box.append(h('div', { class: 'top-gap' }), box_(t('切り替えの候補'), pick),
        check(t('原稿用紙: 自動整形 (題名 3 マス下げ・名前 下寄せ・段落 1 マス下げ)'), 'genkoAutoFormat'),
        check(t('原稿用紙: 半角の英数字を全角にする'), 'genkoFullWidth'),
        check(t('原稿用紙: 自動ふりがな'), 'genkoFurigana'),
        check(t('A4: 自動整形 (題名 中央・名前 右寄せ・段落 1 字下げ)'), 'a4AutoFormat'),
        check(t('保存のとき、見たままの PDF も一緒に作る'), 'paperSavePDF'));
    }
    return box;
  };
  const pluginDetails = p => () => {
    const m = p.manifest;
    const perms = m.permissions.map(x => app.plugins.permissionText(x));
    const src = (app.prefs.pluginSources || {})[m.id];
    const fmt = d => d.toTimeString().slice(0, 8);
    const log = h('pre', { class: 'plugin-log' }, p.log.slice(-100).map(l => h('div', { class: l.error ? 'err' : '' }, `${fmt(l.date)} ${l.error ? '✗' : '•'} ${l.text}`)));
    setTimeout(() => { log.scrollTop = log.scrollHeight; }, 0);
    return h('div', {},
      m.description ? h('div', {}, m.description) : null,
      h('div', { class: 'dim' }, t('作者: {a}   版: {v}', { a: m.author || '?', v: m.version })),
      h('div', { class: 'dim' }, perms.length ? t('使う権限: {p}', { p: perms.join('、') }) : t('特別な権限は使いません (文書の読み書きだけ)')),
      src ? h('div', { class: 'dim' }, t('入れた元: {s}', { s: src })) : null,
      h('div', { class: 'top-gap' }, p.commands.length ? t('メニュー「追加機能」に出るコマンド:') : t('メニューのコマンドはありません')),
      ...p.commands.map(c => h('div', { class: 'dim' }, '• ' + c.title + (c.accel ? '  (' + c.accel + ')' : ''))),
      h('div', { class: 'top-gap' }, t('ログ')), log);
  };
  const addMenu = el => {
    const r = el.getBoundingClientRect();
    popupMenu([
      { label: t('URL から入れる (GitHub など)…'), action: async () => {
        const url = await promptBox(t('URL から拡張機能を入れる'), t('GitHub のリポジトリの URL か、zip の URL を貼ってください。'), '', { placeholder: 'https://github.com/user/plugin' });
        if (url && url.trim()) await app.plugins.install({ url: url.trim() });
      } },
      { label: t('フォルダ・zip から入れる…'), action: async () => {
        const paths = await app.api.openDialog({ properties: ['openFile', 'openDirectory'], filters: [{ name: 'zip', extensions: ['zip'] }] });
        const p = Array.isArray(paths) ? paths[0] : paths;
        if (p) await app.plugins.install({ path: p });
      } },
      'sep',
      { label: t('自分で作る (ひな形を作る)…'), action: () => app.plugins.createTemplate() },
      { label: t('作り方 (API の説明) を見る'), action: () => app.plugins.openDocs() },
      { label: t('拡張機能のフォルダを開く'), action: () => app.plugins.revealFolder() },
    ], r.left, r.bottom + 2);
  };
  const render = () => {
    pane.textContent = '';
    pane.append(h('div', { class: 'dim' }, t('スイッチを入れると、メニューとボタンに出ます。行を押すと説明が出ます。')));
    pane.append(h('div', { class: 'feature-group-title' }, t('内蔵の機能')));
    pane.append(h('div', { class: 'feature-group' }, menuDef.LISTED_FEATURES.map(f => row({
      key: f.id, on: !!app.prefs[f.pref], icon: FEATURE_ICONS[f.id], name: t(f.title), summary: t(f.summary),
      onToggle: async want => { await app.toggleFeature(f.id, want); render(); }, details: builtInDetails(f),
    }))));
    const list = app.plugins.plugins;
    pane.append(h('div', { class: 'feature-group-title' }, t('JS 拡張機能 ({n})', { n: list.length })));
    const rows = list.map(p => row({
      key: 'plugin:' + p.manifest.id, on: app.plugins.isEnabled(p), icon: p.icon, name: p.manifest.name, dim: !app.plugins.isEnabled(p),
      summary: p.loadError ? '⚠︎ ' + p.loadError : p.manifest.description,
      extra: h('button', { class: 'feature-extra icon-button', title: t('そのほかの操作'), onclick: e => {
        e.stopPropagation();
        const r = e.currentTarget.getBoundingClientRect();
        const src = (app.prefs.pluginSources || {})[p.manifest.id];
        popupMenu([
          { label: t('読み直す'), action: () => app.plugins.loadAll() },
          ...(src && /^(https?:|github\.com)/.test(src) ? [{ label: t('新しい版を取ってくる'), action: () => app.plugins.update(p) }] : []),
          { label: t('フォルダをエクスプローラーで表示'), action: () => app.plugins.revealFolder(p) },
          { label: t('main.js を開く'), action: () => app.openPath(p.folder + '/' + p.manifest.main) },
          'sep',
          { label: t('外す (ごみ箱へ)…'), action: () => app.plugins.uninstall(p) },
        ], r.left, r.bottom + 2);
      } }, '⋯'),
      onToggle: want => { app.plugins.setEnabled(p, want); render(); }, details: pluginDetails(p),
    }));
    // 枠のいちばん下: 「＋ 拡張機能を追加…」
    rows.push(h('div', { class: 'feature-row add-row' },
      h('button', { class: 'primary', onclick: e => addMenu(e.currentTarget) }, t('＋ 拡張機能を追加…')),
      list.length ? null : h('span', { class: 'dim' }, t('まだありません。URL・フォルダ・zip から入れたり、自分で作ったりできます。'))));
    pane.append(h('div', { class: 'feature-group' }, rows));
  };
  app.plugins.onChange = () => { if (pane.isConnected) render(); };
  render();
  if (opts.expand) setTimeout(() => { const el = pane.querySelector(`[data-key="${opts.expand}"]`); if (el) el.scrollIntoView({ block: 'start' }); }, 60);
  return pane;
}

// ---------- キー割り当て・メニュー編集・ツールバー ----------

/// 設定用に、全部の機能をオンにしたメニューを作る (隠した項目も、もとのキーも見える)
function fullMenu(app) {
  const prefs = Object.assign({}, app.prefs, { aiEnabled: true, paperEnabled: true, encryptionEnabled: true, folderTreeEnabled: true });
  return menuDef.build(Object.assign({}, app.menuState(), { prefs, recent: [], languages: [], forSettings: true, encrypted: true, paperMode: 2 }));
}

/// メニューの木を、(見出しの道すじ, 項目) の並びにする。引数で増える項目 (言語など) は 1 つにまとめる
function menuRows(menus) {
  const rows = [], seen = new Set();
  const walk = (items, trail) => {
    for (const m of items) {
      if (m.type === 'separator' || m.header) continue;
      const label = m.label.replace(/\(&.\)/, '').replace('&', '');
      if (m.submenu) { walk(m.submenu, trail.concat(label)); continue; }
      if (!m.id) continue;
      const id = menuDef.baseId(m.id);
      if (seen.has(id)) continue;
      seen.add(id);
      rows.push({ id, item: m, trail, label: id === m.id ? label : trail[trail.length - 1], grouped: id !== m.id });
    }
  };
  walk(menus, []);
  return rows;
}

function keysPane(app) {
  const pane = h('div', {});
  const render = () => {
    const rows = menuRows(fullMenu(app)).filter(r => !r.grouped);
    const keys = Object.assign({}, app.prefs.keys || {});
    const used = new Map();
    for (const r of rows) if (r.item.accel) used.set(r.item.accel, (used.get(r.item.accel) || []).concat([r.label]));
    const set = (id, accel) => {
      const item = rows.find(r => r.id === id).item;
      if (accel === item.defaultAccel) delete keys[id]; else keys[id] = accel;
      app.setPref('keys', keys);
      render();
    };
    let lastTop = '';
    const list = h('div', { class: 'key-list' });
    for (const r of rows) {
      if (r.trail[0] !== lastTop) { lastTop = r.trail[0]; list.append(h('div', { class: 'key-group' }, lastTop)); }
      const fixed = !!r.item.role || r.id === 'app.quit';
      const clash = r.item.accel && (used.get(r.item.accel) || []).length > 1;
      const input = h('input', { type: 'text', class: 'key-input' + (clash ? ' clash' : ''), readonly: true, disabled: fixed, value: r.item.accel || '',
        placeholder: t('(なし)'), 'aria-label': r.label, title: clash ? t('ほかの項目と同じキーです: {names}', { names: used.get(r.item.accel).filter(n => n !== r.label).join(', ') }) : t('ここを選んで、割り当てたいキーを押します') });
      input.addEventListener('keydown', e => {
        if (e.key === 'Tab') return;
        e.preventDefault();
        e.stopPropagation();
        if (e.key === 'Backspace' || e.key === 'Delete') { set(r.id, ''); return; }
        const accel = menuDef.acceleratorOf(e);
        if (!accel) return;
        // 文字のキーだけでは割り当てない (文字が打てなくなるため)
        if (!/^(Ctrl|Alt)\+/.test(accel) && !/^(Shift\+)?F\d+$/.test(accel)) return;
        set(r.id, accel);
      });
      const changed = Object.prototype.hasOwnProperty.call(keys, r.id);
      list.append(h('div', { class: 'key-row' },
        h('span', { class: 'key-label' }, r.trail.slice(1).concat([r.label]).join(' > ')),
        input,
        changed ? h('button', { class: 'link-button', onclick: () => { delete keys[r.id]; app.setPref('keys', keys); render(); } }, t('戻す')) : h('span', { class: 'key-spacer' })));
    }
    const top = pane.parentNode ? pane.parentNode.scrollTop : 0;
    pane.textContent = '';
    pane.append(
      h('div', { class: 'dim' }, t('キーの欄を選んで、割り当てたいキーを押します。Backspace で割り当てを消します。切り取り・コピー・貼り付けは変えられません。')),
      h('div', { class: 'form-row' }, h('button', { onclick: async () => {
        if (!(await confirmBox(t('すべてのキーを最初の割り当てに戻しますか？'), '', t('戻す')))) return;
        app.setPref('keys', {});
        render();
      } }, t('すべて最初の割り当てに戻す'))),
      list);
    if (pane.parentNode) pane.parentNode.scrollTop = top;
  };
  render();
  return pane;
}

function menuPane(app) {
  const pane = h('div', {});
  const render = () => {
    const rows = menuRows(fullMenu(app));
    const hidden = new Set(app.prefs.hiddenMenu || []);
    let lastTop = '';
    const list = h('div', { class: 'key-list' });
    for (const r of rows) {
      if (r.trail[0] !== lastTop) { lastTop = r.trail[0]; list.append(h('div', { class: 'key-group' }, lastTop)); }
      const locked = menuDef.ALWAYS_SHOWN.has(r.id);
      list.append(h('label', { class: 'check-row' },
        h('input', { type: 'checkbox', checked: !hidden.has(r.id), disabled: locked, onchange: e => {
          if (e.target.checked) hidden.delete(r.id); else hidden.add(r.id);
          app.setPref('hiddenMenu', Array.from(hidden));
        } }),
        r.trail.slice(1).concat([r.label]).join(' > ')));
    }
    pane.textContent = '';
    pane.append(
      h('div', { class: 'dim' }, t('チェックを外した項目は、メニューに出なくなります (キー操作も効かなくなります)。')),
      h('div', { class: 'form-row' }, h('button', { onclick: () => { app.setPref('hiddenMenu', []); render(); } }, t('すべて表示する'))),
      list);
  };
  render();
  return pane;
}

function toolbarPane(app) {
  const pane = h('div', {});
  const buttons = app.TOOLBAR.filter(b => Array.isArray(b));
  const defaults = () => app.TOOLBAR_DEFAULT.slice();
  const render = () => {
    const layout = Array.isArray(app.prefs[app.TOOLBAR_PREF]) ? app.prefs[app.TOOLBAR_PREF].slice() : defaults();
    const save = next => { app.setPref(app.TOOLBAR_PREF, next); render(); };
    const move = (i, d) => { const j = i + d; if (j < 0 || j >= layout.length) return; const x = layout[i]; layout[i] = layout[j]; layout[j] = x; save(layout); };
    const nameOf = n => (n === '-' ? t('― 区切り ―') : n === 'space' ? t('― 余白 (ここから右寄せ) ―') : t((buttons.find(b => b[0] === n) || [n, n])[1]));
    const list = h('div', { class: 'key-list' }, layout.map((n, i) => h('div', { class: 'key-row' },
      h('span', { class: 'key-label' }, nameOf(n)),
      h('button', { disabled: i === 0, 'aria-label': t('上へ'), onclick: () => move(i, -1) }, '↑'),
      h('button', { disabled: i === layout.length - 1, 'aria-label': t('下へ'), onclick: () => move(i, 1) }, '↓'),
      h('button', { onclick: () => { layout.splice(i, 1); save(layout); } }, t('外す')))));
    const missing = buttons.filter(b => !layout.includes(b[0]));
    pane.textContent = '';
    pane.append(
      h('div', { class: 'dim' }, t('ツールバーに並べるボタンと順番を決めます。使っていない追加機能のボタンは、並べても出ません。')),
      list,
      h('div', { class: 'form-row' }, h('label', {}, t('足す')),
        missing.map(b => h('button', { onclick: () => { layout.push(b[0]); save(layout); } }, t(b[1]))),
        h('button', { onclick: () => { layout.push('-'); save(layout); } }, t('区切り')),
        h('button', { onclick: () => { layout.push('space'); save(layout); } }, t('余白'))),
      h('div', { class: 'form-row' }, h('button', { onclick: () => save(null) }, t('最初の並びに戻す'))));
  };
  render();
  return pane;
}

// ---------- 関連付け・右クリックメニュー ----------

function assocPane(app) {
  const pane = h('div', {}, h('div', { class: 'dim' }, t('読み込み中…')));
  const render = async () => {
    const st = await app.api.assocStatus();
    pane.textContent = '';
    if (!st.supported) { pane.append(h('div', {}, t('この機能は Windows で使えます。'))); return; }
    const fileMenu = h('input', { type: 'checkbox', checked: st.fileMenu });
    const folderMenu = h('input', { type: 'checkbox', checked: st.folderMenu });
    const exts = h('textarea', { class: 'wide', rows: '3', spellcheck: 'false' }, (st.extensions.length ? st.extensions : []).join(' '));
    const result = h('div', { class: 'ai-test', role: 'status' });
    pane.append(
      box(t('エクスプローラーの右クリックメニュー'),
        h('label', { class: 'check-row' }, fileMenu, t('ファイルの右クリックに「エディタβで開く」を出す')),
        h('label', { class: 'check-row' }, folderMenu, t('フォルダの右クリックに「エディタβで grep」を出す'))),
      box(t('「プログラムから開く」の一覧にエディタβを出す拡張子'),
        exts,
        h('div', { class: 'form-row' },
          h('button', { onclick: () => { exts.value = st.defaults.join(' '); } }, t('よく使う拡張子を入れる')),
          h('button', { onclick: () => { exts.value = ''; } }, t('空にする'))),
        h('div', { class: 'dim' }, t('ダブルクリックで開く「既定のアプリ」は、Windows が守っているのでここからは変えられません。ファイルを右クリック →「プログラムから開く」→「別のプログラムを選択」でエディタβを選び、「常にこのアプリを使って開く」にチェックしてください。'))),
      h('div', { class: 'form-row' }, h('button', { class: 'primary', onclick: async () => {
        result.textContent = t('設定しています…');
        result.className = 'ai-test';
        const r = await app.api.assocApply({ fileMenu: fileMenu.checked, folderMenu: folderMenu.checked, extensions: exts.value.split(/[\s,;]+/).filter(Boolean) });
        if (r.status === 'ok') { await render(); toast(t('設定しました')); }
        else { result.textContent = t('設定できなかったものがあります: {what}', { what: r.message }); result.className = 'ai-test warn'; }
      } }, t('この内容で設定する')),
      h('span', { class: 'dim' }, t('このユーザーの設定だけを変えます。チェックを外して設定し直せば、元に戻ります。'))),
      result);
  };
  render();
  return pane;
}

// 左の列は「基本」と「追加機能」の 2 つに分ける
const PANES = [
  { id: 'general', title: '動作環境', build: generalPane, group: '基本' },
  { id: 'filetypes', title: 'ファイルタイプ別の設定', build: fileTypesPane, group: '基本' },
  { id: 'theme', title: '色・フォント', build: themePane, group: '基本' },
  { id: 'keys', title: 'キー割り当て', build: keysPane, group: '基本' },
  { id: 'menu', title: 'メニュー編集', build: menuPane, group: '基本' },
  { id: 'toolbar', title: 'ツールバーを編集', build: toolbarPane, group: '基本' },
  { id: 'assoc', title: '関連付け・右クリックメニュー', build: assocPane, group: '基本' },
  { id: 'backup', title: 'バックアップ', build: backupPane, group: '基本' },
  { id: 'features', title: '追加機能', build: featuresPane, group: '追加機能' },
];

let settingsOpen = false;
export async function openSettings(app, paneId, opts = {}) {
  if (settingsOpen) return;
  settingsOpen = true;
  let current = PANES.some(p => p.id === paneId) ? paneId : 'general';
  const content = h('div', { class: 'settings-content' });
  const tabs = h('div', { class: 'settings-tabs', role: 'tablist' });
  const show = () => {
    tabs.textContent = '';
    let group = null;
    for (const p of PANES) {
      if (p.group !== group) {
        group = p.group;
        tabs.append(h('div', { class: 'settings-group' }, t(group)));
      }
      tabs.append(h('button', { class: 'settings-tab' + (p.id === current ? ' active' : ''), role: 'tab', 'aria-selected': p.id === current ? 'true' : 'false',
        onclick: () => { current = p.id; show(); } }, t(p.title)));
    }
    content.textContent = '';
    content.append(PANES.find(p => p.id === current).build(app, opts));
    opts = {};
    content.scrollTop = 0;
  };
  show();
  await modal({
    title: t('設定'), width: 760, className: 'settings-modal', noEnter: true,
    body: h('div', { class: 'settings' }, tabs, content),
    buttons: [{ label: t('閉じる'), value: true, primary: true, cancel: true }],
  });
  settingsOpen = false;
  app.focusEditor();
}
