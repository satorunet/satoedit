# さとるエディタ (β テスト版)

編集・管理・共有がサクサクできる、Mac / Windows 用のテキストエディタです。

- サイト・ダウンロード: https://docs.satoru.net/
- いまは **β テスト版** です。不具合やご意見は、[GitHub の Issues](https://github.com/satorunet/satoedit/issues) か X ([@satorunet](https://x.com/satorunet)) で受け付けています。

## できること

**書く**
- 標準エディタ (行番号・桁ルーラー・改行や空白の記号・[EOF])、原稿用紙 (縦書き・横書き、自動でふりがな)、A4 用紙を、ツールバーの「用紙切替」で切り替え。切り替えに出す用紙は設定で選べる
- 文字コードの自動判定 (UTF-8 / Shift_JIS / EUC-JP / JIS / UTF-16)、改行コードを保ったまま保存
- 言語ごとの色分け、正規表現の検索・置換、grep、差分の表示、ウィンドウの分割
- AI アシスト: 画面の右はしのタブから横に出る欄で、校正・要約・読みやすく・翻訳・続きを書く などを頼める (ChatGPT・Claude・Gemini・ローカル LLM)
- 読み上げ (Mac): パソコンの標準の声か VOICEVOX で読み上げ
- 印刷、PDF・Word への書き出し

**まとめる**
- テキスト一覧: 左にテキストの一覧とフォルダ (上下 2 段 / 左右 2 列)。ファイル名・拡張子・フォルダ・更新の時間がひと目でわかる。好きな場所のフォルダも開ける
- 版の履歴: 保存するたびにテキストごとの git で版を残す。Word 風に違いを表示、前の版に戻す。残す数は設定で (はじめは 20)
- パスワード付きのバックアップ (一覧と版の履歴をまるごと)

**共有する**
- リンクで公開共有: 文章をインターネット上に公開して URL を発行 (公開・リンクを知っている人だけ・パスワード)。原稿用紙は原稿用紙のまま、エディタは行番号と色のまま
- 公開の前に、電話番号・住所・名前などの個人情報が入っていないかを手元で確かめる
- 公開したあとの更新、変更の履歴と差分、期限の細かい設定
- 公開したページでは、読み上げ (ずんだもん)・テキストや画像でのコピー・用紙の切り替えができる

**そのほか**
- サーバ (SFTP / FTP / FTPS) のファイルをツリーで辿って編集
- データ暗号化 (AES-256-GCM)
- 追加機能: AI・用紙切替・テキスト管理・リンクで公開共有・読み上げ・サーバ・データ暗号化を、それぞれオン・オフ。各メニューから設定へすぐ移れる

対応 OS: macOS 11 以降 (Apple シリコン / Intel)、Windows 10 / 11 (64 ビット)

## 構成

| 場所 | 内容 |
|---|---|
| `mac` | Mac 版 (Swift / AppKit)。Swift Package |
| `mac/Sources/HinokiCore` | 画面に依存しない部分 (文字コード判定、行の計算、言語プロファイル、色分け、grep、個人情報の確認、バックアップ など) |
| `mac/Sources/Hinoki` | 画面 (Hinoki は開発中の名前) |
| `mac/Tests` | テスト |
| `mac/scripts` | 組み立て・署名・DMG 作成、アイコン作成 |
| `windows` | Windows 版 (C# .NET Framework 4.8 + WebView2)。`host` が本体、`renderer` が画面、`installer` がインストーラー |
| `server/docs` | リンクで公開共有のサーバ (Python 標準ライブラリ + SQLite) |
| `server/site` | サイト (docs.satoru.net) |

## ソースからビルド

**Mac** (Xcode かコマンドラインツール、Swift 5.5 以降)

```sh
cd mac
swift test                         # テスト
./scripts/bundle.sh --dev          # 動作確認用の build/さとるエディタ.app
./scripts/bundle.sh --dmg          # 両対応でビルドして配布用の DMG も作る
```

**Windows** (Node.js と .NET SDK。Mac 上でも組み立てられる)

```sh
cd windows
npm install
node scripts/package-host.js       # build/satoruEditor-1.0.0-win-x64-lite.zip
node scripts/package-installer.js  # build/satoruEditor-1.0.0-win-x64-setup.exe
node test/run.js                   # テスト
```

## ライセンス

MIT License。[LICENSE](LICENSE) を見てください。
