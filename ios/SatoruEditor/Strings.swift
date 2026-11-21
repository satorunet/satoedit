import Foundation
import HinokiCore

// 画面に出す言葉。Mac 版と同じく、プログラムの中は日本語で書き、英語のときだけ対応表で置き換える。
// 対応表は Mac 版と共通の I18nEnglish (HinokiCore) を使い、iPhone / iPad 版だけの言葉は下の iosEnglish に足す。
// (このモジュールの L が HinokiCore の L より優先される)

func L(_ key: String, _ args: Any...) -> String {
    var s = key
    if I18n.language == "en" { s = IOSStrings.english[key] ?? I18n.english[key] ?? key }
    for (i, a) in args.enumerated() { s = s.replacingOccurrences(of: "{\(i)}", with: "\(a)") }
    return s
}

enum IOSStrings {
    /// 設定 "language" (auto / ja / en) から言語を決める
    static func applyLanguage() {
        I18n.setLanguage(I18n.resolve(setting: UserDefaults.standard.string(forKey: "language"), systemLanguages: Locale.preferredLanguages))
    }

    static let english: [String: String] = {
        var t: [String: String] = [:]
        var pending: String?
        for raw in iosEnglish.components(separatedBy: "\n") {
            if raw.isEmpty || (pending == nil && raw.hasPrefix("#")) { pending = nil; continue }
            if let ja = pending {
                t[ja.replacingOccurrences(of: "\\n", with: "\n")] = raw.replacingOccurrences(of: "\\n", with: "\n")
                pending = nil
            } else {
                pending = raw
            }
        }
        return t
    }()

    // 日本語の行・英語の行の 2 行で 1 組。組と組の間は空行
    static let iosEnglish = """
さとるエディタ
Satoru Editor

テキスト一覧
Texts

すべて
All

フォルダ
Folders

新しいテキスト
New Text

新しいフォルダ
New Folder

フォルダの名前
Folder name

フォルダを作る
Create Folder

フォルダの名前を変える
Rename Folder

フォルダを消す
Delete Folder

中のテキストも消えます。消してよいですか？
The texts inside will be deleted too. Delete?

名前を変える
Rename

フォルダへ移す
Move to Folder

消す
Delete

消してよいですか？
Delete this?

「{0}」を消します。元に戻せません。
"{0}" will be deleted. This cannot be undone.

その名前はもう使われています
That name is already in use

テキストを探す
Search texts

まだテキストがありません。右上の ＋ で書き始めましょう。
No texts yet. Tap + at the top right to start writing.

見つかりませんでした
Nothing found

いちばん上 (フォルダなし)
Top level (no folder)

エディタ
Editor

原稿用紙 (縦)
Manuscript (vertical)

原稿用紙 (横)
Manuscript (horizontal)

表示
View

{0} 字
{0} chars

{0} 字 ・ {1} 枚
{0} chars · {1} sheets

行番号
Line Numbers

文字の形
Font

明朝
Mincho

ゴシック
Gothic

等幅
Monospace

文字の大きさ
Font Size

ふりがな (自動)
Furigana (auto)

作文の自動整形 (題名・名前・段落)
Essay auto-format (title, name, paragraphs)

完了
Done

閉じる
Close

キャンセル
Cancel

OK
OK

設定
Settings

言語
Language

自動 (iPhone の設定に合わせる)
Automatic (follow the device)

日本語
Japanese

AI アシスト
AI Assist

AI の設定
AI Settings

接続先
Provider

API キー
API Key

キーを保存済み (変えるときだけ入れる)
Key saved (enter only to change)

キーを貼り付け
Paste your key

モデル
Model

アドレス
Base URL

キーを取りに行く
Get a Key

キーを消す
Delete Key

保存して接続テスト
Save and Test

接続できました
Connected

接続できませんでした
Could not connect

対象: 選んでいる {0} 文字
Target: {0} selected characters

対象: 文書全体
Target: whole document

送る
Send

中止
Stop

置き換える
Replace

挿入
Insert

コピー
Copy

コピーしました
Copied

置き換えました
Replaced

挿入しました
Inserted

作文
Essay

答えを待っています…
Waiting for the answer…

リンクで公開共有
Share via Link

公開したリンク
Published Links

まだ公開したものはありません
Nothing published yet

ブラウザで開く
Open in Browser

リンクをコピー
Copy Link

公開をやめる
Unpublish

公開をやめました
Unpublished

公開をやめられませんでした
Could not unpublish

公開のしかた
Visibility

題名
Title

公開の期限
Expires

公開する
Publish

公開しています…
Publishing…

ほかのアプリで共有
Share with Other Apps

公開する前に個人情報を点検する
Check for personal info before publishing

テキストのフォルダ
Text folder

ファイル App の「このiPhone内」>「さとるエディタ」にあります。
Find it in the Files app under On My iPhone > Satoru Editor.

このバージョン
This Version

新規テキスト
New Text

やめて見直す
Review

このまま公開する
Publish Anyway

次からこの確認を出さない
Don't check again

書く
Write

ここに書く (原稿用紙に入ります)
Write here (it goes onto the manuscript paper)

縦書きの原稿用紙の上をタップすると、そこから書けます。
Tap a square on the manuscript to start writing there.

公開中
Published

テキストが空です
The text is empty

表示を切り替える
Switch View

{0} 件
{0} items

AI に頼む
Ask AI

もとに戻す
Undo

やり直す
Redo

API キーを入れてください (設定 > AI の設定)。
Enter an API key (Settings > AI Settings).

モデルを選んでください (設定 > AI の設定)。
Choose a model (Settings > AI Settings).

まだ使えません
Not set up yet

キーはこの iPhone / iPad のキーチェーンにだけ保存します。
The key is stored only in this device's keychain.

一覧
Texts

公開をやめるには「公開したリンク」から。
To unpublish, use Published Links.

名前を入れてください
Enter a name

最安 & 最速
Cheapest & fastest

置き換える場所が分からなくなりました
Can't find the text to replace

頼んだあとで文章が変わったためです。コピーして貼り付けてください。
The text changed after you asked. Copy the answer and paste it instead.

開けませんでした
Could not open
"""
}
