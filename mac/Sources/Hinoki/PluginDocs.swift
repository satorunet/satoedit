import Foundation

/// 拡張機能の作り方 (開発者向け) と、ひな形
enum PluginDocs {
    static let template = #"""
    // satoEdit 拡張機能のひな形
    // 保存すると、すぐ読み直されます。console.log の内容は「追加機能」画面のこの拡張機能のカードで見られます。

    // メニュー「追加機能」に出るコマンド
    satoru.commands.register({ id: 'hello', title: '今日の日付を入れる', key: 'cmd+shift+d' }, () => {
      const d = new Date();
      const text = `${d.getFullYear()}/${d.getMonth() + 1}/${d.getDate()}`;
      satoru.editor.insert(text);
      satoru.ui.toast('日付を入れました', text);
    });

    // 選んだ文字を大文字に
    satoru.commands.register({ id: 'upper', title: '選んだ文字を大文字に' }, () => {
      const sel = satoru.editor.getSelection();
      if (!sel.text) { satoru.ui.alert('文字を選んでください'); return; }
      satoru.editor.replaceSelection(sel.text.toUpperCase());
    });

    // 保存の直前に呼ばれる (ここで本文を書き換えると、その内容で保存される)
    satoru.on('beforeSave', info => {
      console.log('保存します:', info.fileName);
    });

    // 入力補完に候補を足す
    satoru.completion.register(ctx => {
      if (ctx.word.length < 2) return [];
      return [{ label: 'satoru', detail: 'ひな形の候補', kind: 'word' }];
    });

    """#

    static let readme = #"""
    # satoEdit 拡張機能の作り方

    拡張機能は、1 つのフォルダです。

    ```
    my-plugin/
      manifest.json   … 名前・版・作者・使う権限
      main.js         … 本体 (JavaScript)
      icon.png        … (なくてよい) 一覧に出す絵
    ```

    `~/.satoruEditor/plugins/` に置くか、「追加機能」画面の ＋ から
    フォルダ・zip・URL (GitHub のリポジトリでも可) を指定して入れます。
    自分の拡張機能を公開するときは、このフォルダを GitHub に置くか zip にして URL を配ってください。

    ## manifest.json

    ```json
    {
      "id": "my-plugin",
      "name": "わたしの拡張",
      "version": "1.0.0",
      "author": "あなたの名前",
      "description": "何をするものか",
      "icon": "🧩",
      "main": "main.js",
      "permissions": [],
      "homepage": "https://github.com/you/my-plugin"
    }
    ```

    - `id` … 英小文字・数字・`-` `.` `_` だけ。ほかと重ならない名前に
    - `icon` … 絵文字 1 つ、またはフォルダの中の画像ファイル名
    - `permissions` … 使うものだけ書く。入れるときに利用者に見せて確認します
      - `"network"` … `satoru.fetch` でネットにつなぐ
      - `"clipboard"` … `satoru.clipboard` を使う

    何も書かなければ、開いている文書の読み書きと画面への表示だけができます。
    ファイルやほかのアプリには触れません。

    ## API (`satoru`)

    ### コマンド
    ```js
    satoru.commands.register({ id: 'x', title: 'メニューに出す名前', key: 'cmd+shift+x' }, () => { ... });
    ```
    メニュー「追加機能 > (拡張機能の名前)」に出ます。`key` は省略可 (`cmd` `shift` `alt` `ctrl` と 1 文字)。

    ### 文書
    ```js
    satoru.editor.getText()              // 全文
    satoru.editor.setText(text)          // 全文を置き換え (取り消せます)
    satoru.editor.getSelection()         // { start, end, text }
    satoru.editor.replaceSelection(text) // 選んだ所を置き換え
    satoru.editor.insert(text)           // カーソルの所に入れる
    satoru.editor.select(start, end)     // 選ぶ (文字の位置は UTF-16 単位。JS の文字列と同じ)
    satoru.editor.language()             // "PHP" など
    satoru.editor.fileName()
    satoru.editor.filePath()             // サーバのファイルならサーバ上のパス
    ```

    ### イベント
    ```js
    satoru.on('open', info => {})        // 文書を開いた
    satoru.on('beforeSave', info => {})  // 保存の直前 (本文を書き換えるとその内容で保存)
    satoru.on('save', info => {})        // 保存した
    ```
    `info` は `{ fileName, path, language, remote }`。

    ### 入力補完
    ```js
    satoru.completion.register(ctx => [
      'そのまま入る文字',
      { label: 'myFunc', detail: '(a, b)', kind: 'function' },
    ]);
    ```
    `ctx` は `{ word, language, line }`。`kind` は function / keyword / type / property / word。
    打つたびに呼ばれるので、軽く作ってください。

    ### 画面
    ```js
    satoru.ui.toast('タイトル', '説明')
    satoru.ui.alert('メッセージ')
    satoru.ui.confirm('よいですか？')        // true / false
    satoru.ui.prompt('名前は？', '初期値')   // 文字 / null
    ```

    ### 保存しておく値 (拡張機能ごと)
    ```js
    satoru.storage.set('count', 3);
    satoru.storage.get('count', 0);
    ```

    ### クリップボード (`"clipboard"` 権限)
    ```js
    satoru.clipboard.readText()
    satoru.clipboard.writeText('...')
    ```

    ### ネット (`"network"` 権限)
    ```js
    const res = await satoru.fetch('https://example.com/api', { method: 'POST', headers: {...}, body: '...' });
    res.status; res.ok; await res.text(); await res.json();
    ```

    ### そのほか
    `console.log` / `console.error`、`setTimeout` / `clearTimeout` が使えます。
    `satoru.version` はアプリの版です。

    ## 試しながら作る

    `~/.satoruEditor/plugins/` の中の main.js をこのエディタで開いて保存すると、その場で読み直されます。
    エラーや `console.log` は「追加機能」画面で、その拡張機能のカードを押すと見られます。
    """#
}
