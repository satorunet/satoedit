# さとるエディタ (Windows 版)

Windows 用の軽いテキストエディタです。本体は C# (.NET Framework 4.8) と Microsoft Edge WebView2 で動きます (配布物は約 2.5 MB)。

> 1.0 より前は Electron で作っていましたが、配布物が 100 MB を超えて重かったため、Windows に最初から入っている .NET と WebView2 を使う今の形に作り直しました。画面側 (renderer/) はそのまま使っています。

Mac 版 (さとるエディタ) と同じ色・同じ使い心地で、日本語のテキストやプログラムを手早く編集できます。表示は日本語と英語を切り替えられます。

- タブで複数のファイルを開ける
- 行番号、桁ルーラー、改行・タブ・全角スペース・半角スペースの記号、[EOF] の表示
- 文字コードの自動判定 (UTF-8 / Shift_JIS / EUC-JP / JIS / UTF-16)。改行コード (LF / CRLF / CR) を保ったまま保存
- 言語ごとの色分けとタブ幅 (21 種類。自分で追加もできる)
- 検索・置換の窓 (正規表現、単語単位、すべて強調)、grep (フォルダ内検索とタグジャンプ)
- 上下分割、行の複製・削除・移動、コメント切り替え、並べ替え、重複行の削除
- テーマ 8 種類 (見本をクリックして切り替え)、色・フォントの変更、アイコンの色 8 色
- 印刷、PDF / Word (.docx) への書き出し、PDF からテキストの読み込み (縦書きの PDF も)
- スクリーンショット: 表示されている部分か文書全体を画像にして、コピーか PNG で保存
- キー割り当て、メニュー編集、ツールバー編集、関連付けとエクスプローラーの右クリックメニュー
- 表示の言語: 日本語 / English (既定は Windows の言語に合わせる。「設定 > 表示の言語」で変更)

「追加機能」はオン・オフでき、オンのときだけ専用のメニューが出ます。

| 追加機能 | 内容 |
|---|---|
| AI アシスタント (既定でオン) | 校正・要約・続きを書くなどをチャットの形で頼める (ChatGPT / Claude / Gemini / OpenAI 互換) |
| 用紙切替 (既定でオン) | 標準エディタ・原稿用紙 (縦書き・横書き)・A4 用紙。原稿用紙は文字数と枚数を下に表示、自動ふりがなつき |
| テキスト管理 (既定でオン) | 左にフォルダとテキストの一覧 (ドキュメント\さとるエディタ)。自動で保存、ピン・ロック・複製・移動、サムネで一覧、テキストごとの版の履歴 |
| リンクで公開 (既定でオン) | テキストを docs.satoru.net に置いてリンクで読めるようにする (公開・リンクだけ・パスワード、期限、更新、公開をやめる)。公開の前に個人情報を確かめる |
| サーバ (SFTP / FTP / FTPS) | 登録したサーバの中を見て回り、ファイルを開いて編集。保存するとサーバに反映 |
| データ暗号化 | 文書を暗号化 (AES-256-GCM) して保存。方法は 6 通り (下の表) |

設定 > バックアップ で、テキスト一覧をパスワードで鍵をかけた 1 つのファイル (.satorubackup) に書き出し・戻しができます。Mac 版と同じ形なので、Mac と Windows のどちらで作っても、どちらでも戻せます。

Mac 版の機能は、Windows 版にもひととおり入っています。

対応 OS: Windows 10 / 11 (64 ビット)

## 使い方

[docs.satoru.net](https://docs.satoru.net/) か [Releases](https://github.com/satorunet/satoedit/releases) から、どちらかをダウンロードします。

- インストール版: `SatoruEditor-<版>-win-x64-setup.exe` を実行します (管理者の許可は要りません。入れる先は `%LOCALAPPDATA%\Programs\satoruEditor`)。
- ポータブル版: `SatoruEditor-<版>-win-x64-portable.zip` を好きな場所に展開して、`satoruEditor.exe` をダブルクリックします。設定やテキストは、すべてそのフォルダの中の `data` に入ります (exe の横の `portable.txt` が目印)。

Windows 10 / 11 に最初から入っている .NET Framework 4.8 と WebView2 ランタイムを使います。

署名をしていないので、初回は「Windows によって PC が保護されました」と出ることがあります。「詳細情報」→「実行」で起動できます。

## 暗号化の方法

| 方法 | 開くのに要るもの | 別の PC・Mac で開けるか |
|---|---|---|
| パスワード (8 文字以上) | パスワード | 開ける |
| パスコード (数字 6 桁以上) | パスコード | 開ける |
| この PC のロック | Windows にログインしていること | 開けない |
| ワンタイム認証 | スマホの認証アプリの 6 桁 | 開けない |
| 二段階 | パスワード + スマホの認証アプリの 6 桁 | 開けない |
| 鍵ファイル | USB メモリなどに置いた鍵ファイル | 開ける |

パスワード・パスコード・鍵ファイルで暗号化した文書は、Mac 版でもそのまま開けます (ファイルの形が同じ)。「この PC のロック」「ワンタイム認証」「二段階」は、鍵 (の一部) を Windows のログインに結び付けて (DPAPI) この PC に保存します。Mac 版の「この Mac のロック」と違い、開くたびの本人確認 (Windows Hello) は出ません。

## 設定ファイル

`%USERPROFILE%\.satoruEditor\` にあります (ポータブル版は `data\config\`)。`theme.json` (色・フォント)・`profiles.json` (言語)・`ai-usage.json` (AI の利用の記録) は Mac 版と同じ形なので、そのまま持ち運べます。

AI の料金の目安は、アプリに入っている一覧表 (`shared/aimodels.js`、各社の公式の料金ページを 2026-11-18 に確認) を使います。各社のモデル一覧の API は料金を返さないためです。値段が変わったときは、`ai-prices.json` に `{ "モデル名": [入力, 出力] }` (US ドル / 100 万トークン) を書くと、そちらが優先されます。

SFTP で初めてつないだサーバの鍵は `known-hosts.json` に覚え、あとで変わったときは接続を止めます。

## ソースからビルド

Node.js と .NET SDK が必要です (Mac の上でも Windows 用を作れます)。

```sh
npm install
npm test                                # 部品のテスト
node scripts/package-host.js            # 本体 (host/) と画面 (renderer/) をまとめて build/satoruEditor-lite/ と zip を作る
node scripts/package-installer.js       # インストーラー build/satoruEditor-<版>-win-x64-setup.exe
node scripts/package-portable.js        # ポータブル版 build/SatoruEditor-<版>-win-x64-portable.zip
```

実機での確認は、Windows で次を実行すると、画面の画像と結果 (report.json) がフォルダに書き出されます。Parallels の Windows を使うなら `./scripts/vm-host.sh` が、VM にコピー → 点検 → 結果の取り込みまでを行います (インストーラーは `./scripts/vm-installer.sh`)。

```
satoruEditor.exe --selftest=C:\Users\<名前>\satoruEditor-selftest
```

## 構成

| 場所 | 内容 |
|---|---|
| `host/` | 本体 (C# / .NET Framework 4.8 + WebView2)。ウインドウ、メニュー、ファイル、暗号化、印刷、アップデート、自己点検 |
| `installer/` | インストーラー (C#。本体の zip を中に抱えた 1 つの exe) |
| `core/` | 文字コード、暗号化、ワンタイム認証、grep、ふりがな、AI への通信と利用の記録、SFTP / FTP、共同編集の通信と暗号、PDF の読み込み、関連付け (テストあり) |
| `shared/` | 本体側と画面側の両方で使うもの (メニュー、テーマ、言語定義、原稿用紙の決まり、英語の対応表) |
| `renderer/` | 画面側 (エディタは CodeMirror 6) |
| `main.js`, `preload.js`, `scripts/package-win.js` | 前の Electron 版の本体 (いまは配布していません。画面側の開発・テスト用に残しています) |
| `test/` | テスト。`test/fixtures` は Mac 版が作った見本 (暗号化ファイル・文字コード・共同編集の通信。相互に読めることの確認用)。`test/servers.js` はテスト用の小さな SFTP / FTP サーバ。`test/ui/` は画面の確認の手順 |

自動ふりがなの辞書は kuromoji (IPADIC) です。読みは辞書まかせなので、人名などは外れることがあります。

## ライセンス

MIT License。
