'use strict';
// メニューの定義 (Windows のメニューバーと、キー操作の両方がこれを使う)。
// 追加機能はオンのときだけ専用のメニュー (AI・用紙・暗号化) が出て、関連する項目はそこにまとまる。
const { PRESETS } = require('./theme');
const { t } = require('./i18n');
const ENCODINGS = [
  ['utf8', 'UTF-8'], ['utf8BOM', 'UTF-8 (BOM付)'], ['shiftJIS', 'Shift_JIS'], ['eucJP', 'EUC-JP'],
  ['iso2022JP', 'JIS'], ['utf16LE', 'UTF-16 LE'], ['utf16BE', 'UTF-16 BE'],
];
const LINE_ENDINGS = [['lf', 'LF'], ['crlf', 'CRLF'], ['cr', 'CR']];

// 追加機能。並びは身近なものを上に
const FEATURES = [
  { id: 'folder', pref: 'folderTreeEnabled', hidden: true, title: 'フォルダツリー', summary: 'フォルダの中身を左にツリーで表示。たくさんのファイルを行き来できます。',
    confirm: '「表示 > フォルダツリー」で出し入れ、「ファイル > フォルダを開く…」でフォルダを選びます。' },
  { id: 'ai', pref: 'aiEnabled', title: 'AI アシスタント', summary: 'AI に校正・要約・続きを書くなどを頼めます。',
    confirm: '・ボタンを押したときだけ、文章が AI の会社に送られます。\n・社外秘や個人情報は送らないでください。\n・使った分だけ料金がかかります。\n・AI の答えは間違うことがあります。\n・暗号化した文書は送りません。' },
  { id: 'paper', pref: 'paperEnabled', title: '用紙切替 (原稿用紙・A4用紙)', summary: '原稿用紙 (縦書き 400 字詰め) や A4 用紙の見た目で書けます。',
    confirm: 'メニューバーの「用紙」で切り替えます。' },
  { id: 'library', pref: 'libraryEnabled', title: 'テキスト管理 (テキスト一覧、履歴)', summary: '左にフォルダとテキストの一覧 (履歴) を出し、サムネで見わたせます。書いたものは自動で保存され、テキストごとに版の履歴も残ります。',
    confirm: '「表示 > テキスト一覧」で出し入れします。テキストは「ドキュメント\\さとるエディタ」に置きます。' },
  { id: 'mado', pref: 'madoEnabled', title: '窓割り (タブを並べて表示)', summary: 'ちがうタブの文書を、1 つのウインドウに左右・上下に並べます。タブを編集画面の端へドラッグしても並べられます。',
    confirm: '「表示 > 窓割り」で並べます。並べた画面の見出しの × で、その画面の文書を閉じます。' },
  { id: 'share', pref: 'shareEnabled', title: 'リンクで公開共有', summary: 'テキストを docs.satoru.net に置いて、リンクで読めるようにします。公開・リンクだけ・パスワードを選べます。',
    confirm: '公開したテキストは、リンクを知った人が読めるようになります。公開の前に、個人情報が入っていないかを確かめます。' },
  { id: 'collab', pref: 'collabEnabled', hidden: true, title: '共同編集 (共有)', summary: '同じ文書を、ほかの人と同時に編集します。チャットつき。Mac 版とも一緒に編集できます。',
    confirm: '・承認した相手には、文書がすべて見えます。\n・承認は、信頼できる相手だけに。\n・通信は共有コードで暗号化されます。コードを知らない人は入れません。\n・使い終わったら「共有を終了」。', needsAgree: true },
  { id: 'server', pref: 'serverEnabled', title: 'サーバ (SFTP / FTP)', summary: 'サーバのファイルを開いて編集。保存するとサーバに反映。',
    confirm: '保存するとすぐサーバに反映されます。本番サーバでは注意。' },
  { id: 'encryption', pref: 'encryptionEnabled', title: 'データ暗号化', confirmTitle: 'データ暗号化をオンにします', summary: '文書を暗号化して保存。開けるのは鍵を持つ本人だけ。',
    confirm: 'パスワードを忘れると、だれにも開けなくなります。' },
];
// 一覧に出すもの (Mac 版と同じ: 共同編集・フォルダツリーは出さない (中身は残してある))
const LISTED_FEATURES = FEATURES.filter(f => !f.hidden && !f.standard);

const AI_ACTIONS = [
  { id: 'continueWriting', apply: 'insert', title: '続きを書く', instruction: '次の文章の続きを、同じ文体・言語で自然に書いてください。続きの部分だけを出力してください。' },
  { id: 'proofread', apply: 'replace', title: '校正', instruction: '次の文章の誤字脱字・文法の誤り・表記ゆれを直してください。直した後の全文だけを出力し、説明は付けないでください。' },
  { id: 'summarize', apply: 'none', title: '要約', instruction: '次の文章を要点がわかるように短く要約してください。' },
  { id: 'rewrite', apply: 'replace', title: '読みやすく', instruction: '次の文章を、意味を変えずに、より読みやすく自然な文章に書き直してください。書き直した文章だけを出力してください。' },
  { id: 'translate', apply: 'replace', title: '翻訳 (日⇔英)', instruction: '次の文章が日本語なら英語に、それ以外なら日本語に翻訳してください。訳文だけを出力してください。' },
  { id: 'explain', apply: 'none', title: '説明', instruction: '次の文章 (またはプログラム) が何を言っているか・何をしているかを、わかりやすく日本語で説明してください。' },
];

// 用紙切替の候補 (Mac 版 PaperCandidates と同じ id。並びはボタンで切り替わる順)。prefs.paperCandidates に覚える
const PAPER_CANDIDATES = [['normal', '標準エディタ', 0], ['genkoV', '原稿用紙 (縦書き)', 1], ['genkoH', '原稿用紙 (横書き)', 3], ['a4', 'A4用紙', 2]];
/// 出す候補 (はじめは全部。1 つも無いときは標準エディタだけ)
function paperCandidates(p) {
  const saved = p && Array.isArray(p.paperCandidates) ? p.paperCandidates : null;
  if (!saved) return PAPER_CANDIDATES.map(c => c[0]);
  const list = PAPER_CANDIDATES.map(c => c[0]).filter(id => saved.includes(id));
  return list.length ? list : ['normal'];
}
/// paperMode (0 標準 / 1 原稿用紙 / 2 A4) と横書きか → 候補の id
function paperCandidateOf(mode, horizontal) { return mode === 1 ? (horizontal ? 'genkoH' : 'genkoV') : mode === 2 ? 'a4' : 'normal'; }

const sep = { type: 'separator' };
const item = (label, id, accel, extra) => Object.assign({ label, id, accel: accel || '' }, extra || {});
const header = label => ({ label, header: true });

/// state: { prefs, paperMode (0-2), languages: [名前], recent: [パス] } → メニューの木
function build(state) {
  const p = state.prefs || {};
  const on = key => !!p[key];
  const check = (label, id, accel, checked, extra) => item(label, id, accel, Object.assign({ type: 'checkbox', checked: !!checked }, extra || {}));
  const radio = (label, id, checked, accel) => item(label, id, accel, { type: 'radio', checked: !!checked });
  const paper = state.paperMode || 0;

  const file = [
    item('新規作成', 'file.new', 'Ctrl+N'),
    item('開く…', 'file.open', 'Ctrl+O'),
  ];
  if (on('folderTreeEnabled')) file.push(item('フォルダを開く…', 'folder.open', 'Ctrl+Shift+O'));
  file.push({ label: '最近使ったファイル', submenu: (state.recent || []).length
    ? (state.recent || []).map(f => item(f, 'file.openRecent:' + f)).concat([sep, item('一覧を消去', 'file.clearRecent')])
    : [item('(なし)', '', '', { enabled: false })] });
  file.push(sep,
    item('閉じる', 'file.close', 'Ctrl+W'),
    item('上書き保存', 'file.save', 'Ctrl+S'),
    item('名前を付けて保存…', 'file.saveAs', 'Ctrl+Shift+S'),
    item('名前を変更…', 'file.rename'),
    item('保存時の状態に戻す', 'file.revert'),
    ...(p.libraryEnabled !== false && p.versionHistory !== false ? [item('版の履歴…', 'file.versions', '', { enabled: !!state.hasPath })] : []),
    item('巨大ファイル: 位置へ移動…', 'huge.jump', '', { enabled: !!state.hugeFile }),
    sep,
    item('印刷…', 'file.print', 'Ctrl+P'),
    sep,
    header('PDF・Word'),
    item('PDF として書き出す…', 'file.exportPDF', 'Ctrl+Shift+P'),
    item('Word (.docx) として書き出す…', 'file.exportWord'),
    item('PDF からテキストを読み込む…', 'file.importPDF'),
    sep,
    item('スクリーンショット (画像にする)…', 'file.screenshot', 'Ctrl+Alt+S'),
    sep,
    item('satoEditの終了', 'app.quit', 'Alt+F4'));

  const edit = [
    item('元に戻す', 'edit.undo', 'Ctrl+Z'),
    item('やり直し', 'edit.redo', 'Ctrl+Y'),
    sep,
    item('切り取り', 'edit.cut', 'Ctrl+X', { role: 'cut' }),
    item('コピー', 'edit.copy', 'Ctrl+C', { role: 'copy' }),
    item('貼り付け', 'edit.paste', 'Ctrl+V', { role: 'paste' }),
    item('すべて選択', 'edit.selectAll', 'Ctrl+A'),
    sep,
    { label: '行', submenu: [
      item('行を複製', 'line.duplicate', 'Ctrl+D'),
      item('行を削除', 'line.delete', 'Ctrl+Shift+K'),
      item('行を上へ移動', 'line.moveUp', 'Alt+Up'),
      item('行を下へ移動', 'line.moveDown', 'Alt+Down'),
      sep,
      item('インデント', 'line.indent', 'Ctrl+]'),
      item('逆インデント', 'line.outdent', 'Ctrl+['),
      item('コメント / コメント解除', 'line.toggleComment', 'Ctrl+/'),
      sep,
      item('行を並べ替え', 'line.sort'),
      item('重複行を削除', 'line.unique'),
      item('行末の空白を削除', 'line.trim'),
    ] },
    { label: '変換', submenu: [
      item('大文字に', 'convert.upper'),
      item('小文字に', 'convert.lower'),
      item('先頭を大文字に', 'convert.capitalize'),
      sep,
      item('半角の英数字を全角に', 'convert.fullWidth'),
    ] },
  ];

  const search = [
    item('検索… (条件を決めて探す)', 'find.show', 'Ctrl+F'),
    item('次を検索', 'find.next', 'F3'),
    item('前を検索', 'find.previous', 'Shift+F3'),
    item('選択部分を検索語にする', 'find.useSelection', 'Ctrl+E'),
    sep,
    item('置換…', 'find.replace', 'Ctrl+R'),
    sep,
    item('grep…', 'grep.show', 'Ctrl+Shift+F'),
    sep,
    item('指定行へ移動…', 'goto.line', 'Ctrl+G'),
    item('対応する括弧へ移動', 'goto.bracket', 'Ctrl+Shift+M'),
  ];

  const view = [
    check('折り返し', 'view.wrap', '', p.wrap),
    check('改行・タブ・空白の記号を表示', 'view.invisibles', '', p.invisibles),
    check('行番号を表示', 'view.lineNumbers', '', p.lineNumbers),
    check('桁ルーラーを表示', 'view.columnRuler', '', p.columnRuler),
    check('ツールバーを表示', 'view.toolbar', '', p.toolbar),
    { label: '行の数え方', submenu: [
      radio('エディタ的 (改行ごとに 1 行)', 'view.lineCounting:logical', p.lineCounting !== 'visual'),
      radio('ワープロ的 (折り返しも 1 行)', 'view.lineCounting:visual', p.lineCounting === 'visual'),
    ] },
  ];
  if (p.libraryEnabled !== false) {
    view.push(check('テキスト一覧', 'library.toggle', 'Ctrl+Shift+L', p.libraryVisible === true));
    view.push(item('テキストをサムネで一覧', 'library.grid', 'Ctrl+Alt+Shift+L'));
    view.push(item('テキスト管理の設定…', 'settings.open:backup'));
  }
  if (on('folderTreeEnabled')) view.push(check('フォルダツリー', 'folder.toggle', 'Ctrl+Shift+E', p.folderTreeVisible));
  view.push(check('差分 (編集前との違い) を表示', 'view.diff', 'Ctrl+Shift+D', !!p.diffVisible));
  view.push(sep,
    check('上下に分割', 'view.split', 'Ctrl+Shift+2', state.split && !state.splitSide),
    check('左右に分割', 'view.splitSide', 'Ctrl+Shift+3', state.split && state.splitSide),
    item('分割したもう一方へ移動', 'view.switchPane', 'F6'));
  if (p.madoEnabled !== false) {
    // 窓割り: ちがうタブの文書を 1 つのウインドウに並べる (mado.js)。キーは Mac 版の ⌃⌘ を Ctrl+Alt にしたもの
    const m = state.mado || {};
    const many = (m.tabs || 0) >= 2;
    view.push({ label: '窓割り', submenu: [
      check('タブを左右に並べる', 'mado.sideBySide', 'Ctrl+Alt+Right', m.active && m.dir === 'row', { enabled: many }),
      check('タブを上下に並べる', 'mado.stacked', 'Ctrl+Alt+Down', m.active && m.dir === 'col', { enabled: many }),
      item('この画面を左右に分割', 'mado.splitPaneSide', 'Ctrl+Alt+Shift+Right', { enabled: !!m.partner }),
      item('この画面を上下に分割', 'mado.splitPaneStacked', 'Ctrl+Alt+Shift+Down', { enabled: !!m.partner }),
      item('並べるのをやめる (タブに戻す)', 'mado.unsplit', 'Ctrl+Alt+Up', { enabled: !!m.active }),
      sep,
      item('次の画面へ', 'mado.next', 'Ctrl+Alt+]', { enabled: !!m.shown }),
      item('前の画面へ', 'mado.previous', 'Ctrl+Alt+[', { enabled: !!m.shown }),
      item('画面の大きさをそろえる', 'mado.equalize', '', { enabled: !!m.active }),
      sep,
      item('この画面をタブに戻す', 'mado.returnToTab', '', { enabled: !!m.shown }),
    ] });
  }
  view.push(
    sep,
    item('前のタブ', 'tab.previous', 'Ctrl+Shift+Tab'),
    item('次のタブ', 'tab.next', 'Ctrl+Tab'),
    sep,
    item('文字を大きく', 'view.zoomIn', 'Ctrl+;'),
    item('文字を小さく', 'view.zoomOut', 'Ctrl+-'));

  const menus = [
    { label: 'ファイル(&F)', submenu: file },
    { label: '編集(&E)', submenu: edit },
    { label: '検索(&S)', submenu: search },
    { label: '表示(&V)', submenu: view },
  ];

  if (on('aiEnabled')) {
    menus.push({ label: 'AI(&A)', submenu: [
      check('AI アシスタントを表示', 'ai.toggle', 'Ctrl+Shift+A', p.aiVisible),
      sep,
      ...AI_ACTIONS.map(a => item(a.title, 'ai.action:' + a.id)),
      sep,
      item('利用状況と料金…', 'ai.usage'),
      item('AI の設定…', 'ai.settings'),
      item('ローカルLLM簡単設定…', 'ai.localLLM'),
    ] });
  }
  if (on('paperEnabled')) {
    const h = !!state.genkoHorizontal;
    // 「切り替えの候補」でチェックしたもの (と、いまの用紙) だけを出す
    const cur = paperCandidateOf(paper, h), shown = paperCandidates(p);
    const want = id => id === cur || shown.includes(id);
    menus.push({ label: '用紙(&P)', submenu: [
      ...(want('normal') ? [radio('標準エディタ', 'paper.mode:0', paper === 0)] : []),
      ...(want('genkoV') ? [radio('原稿用紙 (縦書き 400 字詰め)', 'paper.mode:1', paper === 1 && !h)] : []),
      ...(want('genkoH') ? [radio('原稿用紙 (横書き 400 字詰め)', 'paper.mode:3', paper === 1 && h)] : []),
      ...(want('a4') ? [radio('A4 用紙 (横書き 40 字 × 36 行)', 'paper.mode:2', paper === 2)] : []),
      sep,
      check('保存のとき、見たままの PDF も一緒に作る', 'paper.toggle:paperSavePDF', '', p.paperSavePDF),
      sep,
      check('原稿用紙: 自動整形 (題名 3 マス下げ・名前 下寄せ・段落 1 マス下げ)', 'paper.toggle:genkoAutoFormat', '', p.genkoAutoFormat),
      check('原稿用紙: 改行のたび全角スペースを入れる (自動整形オフのとき)', 'paper.toggle:genkoAutoIndent', '', p.genkoAutoIndent),
      check('原稿用紙: 半角の英数字を全角にする', 'paper.toggle:genkoFullWidth', '', p.genkoFullWidth),
      check('原稿用紙: 漢字にふりがなを付ける (自動)', 'paper.toggle:genkoFurigana', '', p.genkoFurigana),
      sep,
      check('A4: 自動整形 (題名 中央・名前 右寄せ・段落 1 字下げ)', 'paper.toggle:a4AutoFormat', '', p.a4AutoFormat),
      item('A4 段落: 自動', 'paper.align:auto', '', { enabled: paper === 2 }),
      item('A4 段落: 左寄せ', 'paper.align:left', 'Ctrl+Alt+L', { enabled: paper === 2 }),
      item('A4 段落: 中央寄せ', 'paper.align:center', 'Ctrl+Alt+C', { enabled: paper === 2 }),
      item('A4 段落: 右寄せ', 'paper.align:right', 'Ctrl+Alt+R', { enabled: paper === 2 }),
      sep,
      item('用紙モードの設定…', 'settings.feature:paper'),
    ] });
  }
  if (on('shareEnabled')) {
    // 公開 (リンクで公開)。Mac 版と同じ別のメニュー
    const pub = state.published || null;
    menus.push({ label: '公開(&U)', submenu: [
      item('リンクで公開共有…', 'share.publish', 'Ctrl+Alt+U', { enabled: !state.encrypted }),
      item('公開中のページを更新（変更を反映）', 'share.update', '', { enabled: !!(pub && state.shareNeedsUpdate) }),
      item('公開の設定…', 'share.settings', '', { enabled: !!pub }),
      sep,
      item(pub ? t('公開中ページ表示（id:{id}）', { id: pub.id }) : '公開中ページ表示', 'share.open', '', { enabled: !!pub }),
      item('公開中のリンクをコピー', 'share.copy', '', { enabled: !!pub }),
      item('公開をやめる…', 'share.unpublish', '', { enabled: !!pub }),
      sep,
      item('公開したリンク…', 'share.list'),
      sep,
      check('公開する前に個人情報を確認する', 'share.togglePrivacy', '', !p.sharePrivacyCheckOff),
      sep,
      item('リンクで公開共有の設定…', 'settings.feature:share'),
    ] });
  }
  if (on('collabEnabled')) {
    menus.push({ label: '共有(&H)', submenu: [
      item('この文書を共有する…', 'collab.host'),
      item('共有に参加…', 'collab.join'),
      sep,
      check('チャットを表示', 'collab.toggleChat', '', p.collabChatVisible),
      item('共有を終了 / 抜ける', 'collab.stop', '', { enabled: !!state.collabActive }),
    ] });
  }
  if (on('serverEnabled')) {
    menus.push({ label: 'サーバ(&R)', submenu: [
      item('サーバにつなぐ (SFTP / FTP)…', 'server.open', 'Ctrl+Alt+O'),
      check('編集をすぐサーバに反映する', 'server.toggleAuto', '', p.remoteAutoUpload),
      check('サーバツリーをエディタの横に出す', 'server.tree', 'Ctrl+Alt+E', !!p.remoteTreeVisible),
      sep,
      item('サーバの設定…', 'server.settings'),
    ] });
  }
  if (on('encryptionEnabled')) {
    menus.push({ label: '暗号化(&C)', submenu: [
      item('暗号化して保存…', 'crypto.encrypt', '', { enabled: !state.encrypted }),
      item('暗号化の方法を変える…', 'crypto.changeMethod', '', { enabled: !!state.encrypted }),
      item('鍵の変更…', 'crypto.changeKey', '', { enabled: !!state.encrypted }),
      item('暗号化を解除…', 'crypto.decrypt', '', { enabled: !!state.encrypted }),
      sep,
      item('この文書の暗号化の設定…', 'crypto.settings'),
      sep,
      check('いつも暗号化して保存する', 'crypto.toggleAlways', '', p.encryptAlways),
      sep,
      item('データ暗号化の設定…', 'settings.feature:encryption'),
    ] });
  }

  menus.push({ label: '追加機能(&X)', submenu: [
    ...LISTED_FEATURES.map(f => check(f.title, 'feature.toggle:' + f.id, '', p[f.pref])),
    // JS 拡張機能のコマンド (拡張機能ごとにまとめる。名前は拡張機能が決めたもの)
    ...((state.pluginMenu || []).length ? [sep] : []),
    ...(state.pluginMenu || []).map(pl => ({ label: pl.icon + ' ' + pl.name, raw: true, submenu: pl.commands.map(c => Object.assign(item(c.title, 'plugin.run:' + pl.id + '/' + c.id, c.accel), { raw: true })) })),
    sep,
    item('追加機能を入れる・外す…', 'settings.open:features'),
  ] });

  const current = state.current || {};
  menus.push({ label: '設定(&O)', submenu: [
    item('動作環境…', 'settings.open:general', 'Ctrl+,'),
    item('ファイルタイプ別の設定…', 'settings.open:filetypes'),
    item('色・フォント…', 'settings.open:theme'),
    item('キー割り当て…', 'settings.open:keys'),
    item('メニュー編集…', 'settings.open:menu'),
    item('ツールバーを編集…', 'settings.open:toolbar'),
    item('関連付け・右クリックメニュー…', 'settings.open:assoc'),
    sep,
    { label: '表示の言語 (Language)', submenu: [
      radio('自動 (Windows の言語に合わせる)', 'app.language:auto', (p.language || 'auto') === 'auto'),
      radio('日本語', 'app.language:ja', p.language === 'ja'),
      radio('English', 'app.language:en', p.language === 'en'),
    ] },
    sep,
    item('設定内容の保存…', 'settings.export'),
    item('設定内容の復元…', 'settings.import'),
    item('すべて初期状態に戻す…', 'settings.reset'),
    sep,
    { label: '保存する文字コード', submenu: ENCODINGS.map(([id, name]) => radio(name, 'doc.encoding:' + id, current.encoding === id)) },
    { label: '文字コードを指定して開き直す', submenu: ENCODINGS.map(([id, name]) => item(name, 'doc.reopen:' + id)) },
    { label: '改行コード', submenu: LINE_ENDINGS.map(([id, name]) => radio(name, 'doc.lineEnding:' + id, current.lineEnding === id)) },
    sep,
    { label: '言語 (このファイル)', submenu: [
      radio('自動 (拡張子で判定)', 'doc.language:', !current.languageOverride),
      sep,
      ...(state.languages || []).map(n => radio(n, 'doc.language:' + n, current.languageOverride === n)),
    ] },
    { label: 'テーマ', submenu: PRESETS.map(t => radio(t.name, 'theme.preset:' + t.name, state.themePreset === t.name)) },
    sep,
    item('アップデートを確認…', 'app.checkUpdate'),
    item('satoEditについて', 'app.about'),
  ] });
  return translate(customize(menus, p, !!state.forSettings));
}

// 隠せない項目 (これを隠すと設定に戻れなくなる)
const ALWAYS_SHOWN = new Set(['settings.open:general', 'app.quit']);

/// キー割り当て (prefs.keys) とメニュー編集 (prefs.hiddenMenu) を反映する。
/// forSettings のときは隠さず、もとのキー (defaultAccel) も残す (設定の画面で一覧にするため)
function customize(items, p, forSettings) {
  const keys = p.keys || {};
  const hidden = new Set(forSettings ? [] : (p.hiddenMenu || []));
  const out = [];
  for (const m of items) {
    if (m.submenu) {
      m.submenu = customize(m.submenu, p, forSettings);
      if (m.submenu.some(x => x.type !== 'separator' && !x.header)) out.push(m);
      continue;
    }
    if (m.id && hidden.has(baseId(m.id)) && !ALWAYS_SHOWN.has(m.id)) continue;
    if (m.id && !m.role) {
      m.defaultAccel = m.accel || '';
      if (Object.prototype.hasOwnProperty.call(keys, m.id)) m.accel = keys[m.id] || '';
    }
    out.push(m);
  }
  // 項目を隠したあとに残った、頭・末尾・連続の区切り線と、中身のない見出しを消す
  const cleaned = [];
  out.forEach((m, i) => {
    const sepLike = m.type === 'separator';
    if (sepLike && (cleaned.length === 0 || cleaned[cleaned.length - 1].type === 'separator')) return;
    if (m.header && (i + 1 >= out.length || out[i + 1].type === 'separator' || out[i + 1].header)) return;
    cleaned.push(m);
  });
  while (cleaned.length && cleaned[cleaned.length - 1].type === 'separator') cleaned.pop();
  return cleaned;
}

/// 「最近使ったファイル」のように引数で増える項目は、引数を除いた名前でまとめて扱う
function baseId(id) {
  return /^(file\.openRecent|doc\.language|theme\.preset):/.test(id) ? id.slice(0, id.indexOf(':')) : id;
}

/// 見出しを今の言語にする (ファイル名や文字コード名のように対応表にないものはそのまま)
function translate(items) {
  for (const m of items) {
    if (m.label) m.label = t(m.label);
    if (m.submenu) translate(m.submenu);
  }
  return items;
}

/// メニューの木を平らにして [項目] を返す (キー操作の表を作るのに使う)
function flatten(menus, out = []) {
  for (const m of menus) {
    if (m.submenu) flatten(m.submenu, out);
    else if (m.id) out.push(m);
  }
  return out;
}

/// keydown イベント → "Ctrl+Shift+S" のような表記
function acceleratorOf(e) {
  let key = e.key;
  if (key === 'Control' || key === 'Shift' || key === 'Alt' || key === 'Meta') return '';
  const names = { ArrowUp: 'Up', ArrowDown: 'Down', ArrowLeft: 'Left', ArrowRight: 'Right', ' ': 'Space', '+': ';' };
  // Shift を押すと記号が変わるキーは、押した場所で見る
  const byCode = { Digit2: '2', Slash: '/', BracketLeft: '[', BracketRight: ']', Comma: ',', Minus: '-', Semicolon: ';', Equal: ';' };
  if (e.code && byCode[e.code]) key = byCode[e.code];
  else if (names[key]) key = names[key];
  else if (key.length === 1) key = key.toUpperCase();
  const mods = [];
  if (e.ctrlKey || e.metaKey) mods.push('Ctrl');
  if (e.altKey) mods.push('Alt');
  if (e.shiftKey) mods.push('Shift');
  return mods.concat(key).join('+');
}

module.exports = { FEATURES, LISTED_FEATURES, AI_ACTIONS, PAPER_CANDIDATES, paperCandidates, paperCandidateOf, ENCODINGS, LINE_ENDINGS, ALWAYS_SHOWN, build, flatten, acceleratorOf, baseId };
