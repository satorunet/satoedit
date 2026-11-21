# さとるエディタ (iPhone / iPad 版) 1.0.1 β

UIKit で書いた iPhone / iPad 版。iOS 15 以上。Bundle ID `net.satoru.satoruEditor.ios`、表示名「さとるエディタ」。

## できること
- **書く**: 標準エディタ (行番号・ゴシック/明朝/等幅・文字の大きさ) と 原稿用紙 (縦 20×20 朱 / 横 緑、自動ふりがな・作文の自動整形)。
  右上の印で エディタ / 原稿用紙 (縦) / 原稿用紙 (横) を切り替え、ファイルごとに覚える (Mac 版と同じ拡張属性 `net.satoru.satoruEditor.mode#S`)。
  原稿用紙のときは上に原稿用紙、下に書く欄。書く欄で書くと (日本語入力の変換中も) すぐマスに入る。マスをタップするとそこにカーソル。ピンチで拡大。
- **テキスト一覧**: 書類フォルダの .txt (ファイル App の「このiPhone内 > さとるエディタ」から見える)。フォルダ 1 段、新しい順、探す、作る・名前を変える・フォルダへ移す・消す。
  「新規テキスト」のまま書き始めると、閉じたときに 1 行目の名前に付け替える。文字コード (Shift_JIS など) と改行はもとのまま保存。
- **AI アシスト**: ChatGPT / Claude / Gemini / OpenAI 互換。キーは iOS のキーチェーン。校正・要約・読みやすく・翻訳・続きを書く (原稿用紙では作文向けの依頼も)。答えは少しずつ届き、置き換える / 挿入 / コピー。
- **リンクで公開共有**: docs.satoru.net に公開 (Mac 版と同じ API・同じ中身)。公開前に個人情報を点検。公開したリンクの一覧から 開く / コピー / 公開をやめる。

## ビルドと起動 (シミュレータ)
```
cd ~/Hinoki/ios
./scripts/build_sim.sh "iPhone 11"        # gen_xcodeproj.py → xcodebuild (Debug, iphonesimulator)
xcrun simctl boot "iPhone 11"; open -a Simulator
xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/SatoruEditor.app
xcrun simctl launch booted net.satoru.satoruEditor.ios
```
Xcode で開くときは `SatoruEditor.xcodeproj` (スキーム SatoruEditor)。

### プロジェクトの作り方
XcodeGen などは使えないので、`scripts/gen_xcodeproj.py` が `SatoruEditor.xcodeproj` を書く。**ファイルを足したら、もう一度実行する**
(`build_sim.sh` は毎回実行する)。ターゲットは 2 つ:
- `HinokiCore` … `../mac/Sources/HinokiCore/*.swift` をそのまま参照する静的ライブラリ (Mac 版と同じ原稿用紙・ふりがな・I18n・AI の答えの分け方・個人情報の点検・文字コード)。
- `SatoruEditor` … `SatoruEditor/*.swift`。
アイコンは `scripts/make_icon.sh` (Mac 版の make_icon.swift の絵を、塗った背景に載せる)。

### 動作確認 (画面を自動で動かして撮る)
```
./scripts/selftest.sh library|editor|genko|genkoH|ai|share|links ["iPhone 11"]
SATORU_AI_BASE_URL=http://127.0.0.1:8765/v1 ./scripts/selftest.sh ai   # 偽の AI (fakeai2.py <port> <返事のファイル>) を先に起動
SATORU_SHARE_PUBLISH=1 ./scripts/selftest.sh share  # 本当に 1 件公開して、すぐ公開をやめる
SATORU_LANG=en ./scripts/selftest.sh library        # 英語
```
画像は `build/screens/<機種>/`。見本のテキストを作り直してから始める (`SATORU_SEED=0` で作らない)。
英語の対応がない言葉を探す: `python3 scripts/check_strings.py`。

## App Store に出すには (この Mac ではできない)
- この Mac は macOS 12 / Xcode 13.1 (iOS 15 SDK)。今の App Store は新しい Xcode・SDK で作ったものしか受け付けないので、**新しい Xcode のある Mac か CI** (GitHub Actions の macOS ランナーなど) でアーカイブする。
  `python3 scripts/gen_xcodeproj.py` のあと
  `xcodebuild -project SatoruEditor.xcodeproj -scheme SatoruEditor -configuration Release -sdk iphoneos -archivePath build/SatoruEditor.xcarchive archive DEVELOPMENT_TEAM=99NFJH4MCR`
  → `xcodebuild -exportArchive ... -exportOptionsPlist` (method app-store) → Transporter / `xcrun altool` / App Store Connect API で送る。
- App Store Connect でアプリ (Bundle ID `net.satoru.satoruEditor.ios`) を作り、配布用の証明書・プロファイル (自動署名なら Xcode にアカウントを入れる)。
- 新しい Xcode で必要になるもの: プライバシーマニフェスト `PrivacyInfo.xcprivacy` (UserDefaults を使う理由 `CA92.1`、ファイルの日時 `C617.1`) を `SatoruEditor/` に置き、gen_xcodeproj.py のリソースに足す。
  iPad のマルチタスク (Split View) を正式に使うなら UIScene に移すか `UIRequiresFullScreen` を決める。
- スクリーンショット (6.7"/6.5"/iPad 12.9")、説明文、プライバシーポリシーの URL (AI のキーは端末だけ・公開は docs.satoru.net に送る、と書く)、輸出規制 (暗号は標準のもののみ → `ITSAppUsesNonExemptEncryption = NO` 済み)。
- iCloud Drive の同期は未対応 (署名に iCloud の権限が要る)。

## まだできないこと・限り
- 原稿用紙の上で直接打つことはできない (下の書く欄で打つ)。iPhone の縦向きでは用紙が小さいので、ピンチで拡大するか横向きに。
- PDF・画像への書き出し、検索・置換、変更履歴、公開中のページの設定変更 (期限・公開のしかたの変更) は Mac 版のみ。公開中のページの「更新」はできる。
- 公開ページの「画像」(Mac 版がスクリーンショットを送るもの) は送っていない。
- テーマは「ライト」相当の 1 つだけ (ダークモードでもエディタは白)。
