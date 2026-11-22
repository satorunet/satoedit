/// 英語の対応表 (日本語 → 英語)。
/// 1 つの言葉は「日本語の行・英語の行」の 2 行で、言葉と言葉の間は空行。言葉の中の改行は \n と書く。# で始まる行は見出し。
/// 行の終わりの空白も言葉の一部なので、消さないこと。{0} {1} … は、その場で入る言葉や数。
/// 足りないものは swift test (I18nTests) が知らせる。Windows 版の shared/en.js と同じ言葉は、同じ訳にしてある。
enum I18nEnglish {
    static let text = #"""
  (追加)
  (added)

  — ダブルクリックでその行へジャンプ
  — double-click to jump to the line

  ※ワープロ的な数え方
  * counting wrapped lines

 (PDF から)
 (from PDF)

 ({0} から 入力 ${1} / 出力 ${2})
 (from {0}: input ${1} / output ${2})

 (上限に達したので打ち切りました)
 (stopped at the limit)

 (変更あり)
 (modified)

 (標準)
 (default)

 + 料金不明の分
 + usage with unknown price

 ・ 
 ·

(IP アドレスが見つかりません):{0}
(no IP address found):{0}

(なし)
(None)

(モデル未設定)
(no model set)

(答えが空でした)
(The answer was empty)

(見積もり)
(estimated)

(長いので途中までです)
(too long; only the first part)

1 ドル =
$1 =

1. 「キーを取りに行く」でキーを作る\n2. 下に貼って「接続テスト」
1. Create a key with "Get a key"\n2. Paste it below and "Test connection"

1. 「キーを取りに行く」でキーを作る\n2. 下に貼り、「一覧を取得」でモデルを選ぶ\n3. 「接続テスト」
1. Create a key with "Get a key"\n2. Paste it below, then pick a model with "List models"\n3. "Test connection"

2 回の入力が違います。
The two entries do not match.

6 桁が違います。(あと {0} 回)
The 6 digits are wrong. ({0} tries left)

6 桁が違います。スマホに出ている最新のものを入れてください。
The 6 digits are wrong. Enter the latest ones shown on your phone.

6 桁の数字
6 digits

A4 {0} ページ
A4 {0} pages

A4 の自動整形
A4 auto format

A4 段落: 中央寄せ
A4 Paragraph: Center

A4 段落: 右寄せ
A4 Paragraph: Align Right

A4 段落: 左寄せ
A4 Paragraph: Align Left

A4 段落: 自動
A4 Paragraph: Automatic

A4 用紙
A4 paper

A4 用紙 (横書き 40 字 × 36 行)
A4 Page (horizontal, 40 × 36)

A4: 自動整形 (題名 中央・名前 右寄せ・段落 1 字下げ)
A4: Auto Format (title centered, name right, paragraphs indented)

A4・40 字 × 36 行で PDF にします
Export as PDF in A4, 40 characters × 36 lines

AI がまだ設定されていません
The AI is not set up yet

AI が回答を断りました。
The AI declined to answer.

AI とのやりとり
Conversation with the AI

AI による書き換え
Rewriting by the AI

AI に校正・要約・続きを書くなどを頼めます。
Ask an AI to proofread, summarize, continue writing and more.

AI に頼みたいことを書く
Write what you want the AI to do

AI の利用状況と料金
AI Usage and Cost

AI の設定…
AI Settings…

AI アシスタント
AI Assistant

AI アシスタント (⇧⌘A)
AI Assistant (⇧⌘A)

AI アシスタントはオフです。「追加機能」でオンにしてください。
The AI Assistant is off. Turn it on in "Extras".

AI アシスタントはオフになっています
The AI Assistant is turned off

AI アシスタントをオンにする前に
Before you turn on the AI Assistant

AI アシスタントを表示 / 隠す
Show / Hide AI Assistant

AI 側でエラーが起きました
The AI service reported an error

AI 側のエラーです。少し待ってください。
The AI service had an error. Please wait a moment.

AI 利用可能 (接続を確認済み)
AI ready (connection confirmed)

AI 未設定
AI not set up

API キー
API key

API キー (いらなければ空)
API key (leave empty if not needed)

API キーが違います。
The API key is wrong.

API キーとモデルを入れて「接続テスト」に成功すると使えます。
Enter an API key and a model, then pass "Test Connection".

API キーを入れてください (設定 > AI アシスタント)。
Enter an API key (Settings > AI Assistant).

API キーを貼り付け
Paste your API key

Dock と Finder のアイコンが変わります
Changes the icon in the Dock and Finder

English
English

Enter で送信 ・ Shift+Enter で改行
Enter: send · Shift+Enter: new line

Finder に表示
Show in Finder

HTML タグ・grep のファイル名
HTML tags, grep file names

HTML/XML のタグに色を付ける
Color HTML/XML tags

JSON として読めません: {0}
Cannot read as JSON: {0}

Ollama などに接続します (例: http://localhost:11434/v1)。\nキーは空でも OK。「一覧を取得」→「接続テスト」
Connects to Ollama and similar (e.g. http://localhost:11434/v1).\nThe key may be empty. "List models" → "Test connection"

PDF からテキストを読み込む…
Import Text from PDF…

PDF として書き出す…
Export as PDF…

PDF を作れませんでした
Could not create the PDF

PDF を開けませんでした
Could not open the PDF

PDF・Word
PDF and Word

Tab キーでスペースを入れる
Insert spaces with the Tab key

URL・メールアドレス (リンク)
URLs and email addresses (links)

URL・メールアドレスをリンクにする (⌘ クリックで開く)
Make URLs and e-mail addresses links (⌘-click to open)

UTF-8 (BOM付)
UTF-8 (with BOM)

Word (.docx) として書き出す…
Export as Word (.docx)…

Word (.docx) にします
Export as Word (.docx)

Word では横書きになります (文章と段落はそのまま)
In Word the text will be horizontal (text and paragraphs are kept)

[EOF] を表示する
Show [EOF]

\n\n対象の文章:\n<<<\n
\n\nText:\n<<<\n

\n\n手元には保存済み。もう一度保存で送り直します。
\n\nIt is saved locally. Save again to retry the upload.

\nコード: {0}
\nCode: {0}

example.com または 192.168.1.10
example.com or 192.168.1.10

macOS の設定に合わせる
Follow macOS

profiles.json を直接編集…
Edit profiles.json Directly…

さとるエディタで grep
grep with Satoru Editor

さとるエディタ
Satoru Editor

さとるエディタで開く
Open with Satoru Editor

さとるエディタの設定ファイルではありません
This is not a Satoru Editor settings file

さとるエディタの鍵.
Satoru Editor key.

さとるエディタ設定_{0}.json
Satoru Editor settings_{0}.json

theme.json に問題があります (その項目は既定値を使います)
There is a problem in theme.json (defaults are used for those items)

theme.json を直接編集…
Edit theme.json Directly…

windowStyle は gray / theme / system のどれかにしてください
windowStyle must be gray, theme or system

{0}  共有コード: {1}
{0}  Share code: {1}

{0} (自分)
{0} (you)

{0} / {1} 枚
Sheet {0} / {1}

{0} さんが参加しました
{0} joined

{0} さんが抜けました
{0} left

{0} では保存できない文字が含まれています。
It contains characters that cannot be saved as {0}.

{0} として読み込めませんでした。
Could not read as {0}.

{0} について
About {0}

{0} に作ります
It will be created in {0}

{0} に入れました
Copied to {0}

{0} に問い合わせています…
Asking {0}…

{0} に接続しています…
Connecting to {0}…

{0} の色が読めません (#RRGGBB か #RRGGBBAA で書いてください)
Cannot read the color of {0} (write it as #RRGGBB or #RRGGBBAA)

{0} の説明を開閉
Show or hide details for {0}

{0} は「{1}」で使われています
{0} is used by "{1}"

{0} をサーバに送れませんでした
Could not send {0} to the server

{0} を取ってきています…
Fetching {0}…

{0} を終了
Quit {0}

{0} を読み込めませんでした: {1}
Could not load {0}: {1}

{0} を読み込んでいます…
Loading {0}…

{0} を開きました。保存するとサーバに送ります。
Opened {0}. Saving uploads it to the server.

{0} を隠す
Hide {0}

{0} トークン
{0} tokens

{0} ・ {1}
{0} · {1}

{0} 件
{0} found

{0} 件 (多いので途中まで。もう少し絞ってください)
{0} items (too many, showing only some; narrow it down a little)

{0} 件見つかりました
{0} found

{0} 個置換しました
Replaced {0}

{0} 個見つかりました
Found {0}

{0} 列 {1} マス
Col {0}, cell {1}

{0} 回・{1} トークン\n{2}
{0} requests · {1} tokens\n{2}

{0} 字
{0} chars

{0} 文字まで。範囲を選んで分けて送ってください。
Up to {0} characters. Select a range and send it in parts.

{0} 文字以上にしてください。
Use at least {0} characters.

{0} 文字選択
{0} chars selected

{0} 行  {1} 列
Ln {0}, Col {1}

{0}: {1}  ({2} 項目)
{0}: {1}  ({2} items)

{0}:{1} に接続しています。相手が承認するのを待っています…
Connecting to {0}:{1}. Waiting for the host to approve…

{0}が違います。
Wrong {0}.

{0}月
{0}

↑ {0} に送信中…
↑ Sending to {0}…

↑ 上へ
↑ Up

① アドレスとコードを伝える
① Tell them the address and code

② 相手が申し込む
② They ask to join

③ 承認すると文書が届く
③ Approve, and the document is sent

④ 一緒に編集・チャット
④ Edit and chat together

▼ から選んで「保存」してください。
Choose from ▼ and press "Save".

● 組み込みの設定から変更あり
● Changed from the built-in settings

✓ AI 利用可能
✓ AI ready

✓ {0} に反映 {1}
✓ Uploaded to {0} {1}

✓ 接続できました。AI アシスタントが使えます ({0}): 
✓ Connected. The AI Assistant is ready ({0}):

✗ サーバへの送信に失敗
✗ Upload to the server failed

「{0}」が共同編集に参加しようとしています
"{0}" wants to join shared editing

「{0}」に割り当てるキーを押してください
Press the key to assign to "{0}"

「{0}」は二段階で暗号化されています。
"{0}" is encrypted with two steps.

「{0}」は暗号化されています。
"{0}" is encrypted.

「{0}」をどちらで保存しますか？
How do you want to save "{0}"?

「{0}」をゴミ箱に入れますか？
Move "{0}" to the Trash?

「{0}」を一覧から削除しますか？
Remove "{0}" from the list?

「{0}」を暗号化したときの鍵ファイルが見つかりません。\nUSB メモリなどを挿して「もう一度探す」を押すか、鍵ファイルを選んでください。
The key file used to encrypt "{0}" was not found.\nPlug in the USB stick and press "Search Again", or choose the key file.

「{0}」を開く
Open "{0}"

「{0}」を開く鍵ファイルを選んでください
Choose the key file that opens "{0}"

「一覧を取得」で選ぶか、名前を入力
Pick with "Get List", or type a name

「共有する」を押す
Press "Share"

「参加」を押す
Press "Join"

「接続できました」と日本語で一言だけ返してください。
Reply with just the words "Connected".

「表示 > フォルダツリー」で出し入れ、「ファイル > フォルダを開く…」でフォルダを選びます。
Show or hide it with View > Folder Tree. Choose the folder with File > Open Folder….

「追加機能 > AI アシスタント」でオンにしてください。
Turn it on in "Extras > AI Assistant".

「追加機能 > 共同編集」でオンにしてください。
Turn it on in "Extras > Shared Editing".

あとで
Later

あなた
You

あなたはテキストエディタ「さとるエディタ」に組み込まれた文章作成アシスタントです。依頼された結果だけを出力し、前置きや締めの言葉は書かないでください。元の文章がマークダウンを使っていない限り、マークダウンの装飾は使わないでください。
You are a writing assistant built into the text editor "Satoru Editor". Output only the requested result, with no preamble or closing remarks. Do not use Markdown formatting unless the original text uses it.

ある鍵ファイルを選ぶ…
Choose an Existing Key File…

いつも暗号化して保存する
Always Save Encrypted

いま: {0}\nやめるときは esc
Now: {0}\nPress esc to cancel

いまの用紙 / 全部の枚数 (1 枚 400 字)
Current sheet / number of sheets (400 characters each)

いまの設定は置き換わります。
The current settings will be replaced.

いまの設定を保存してから復元
Save Current Settings, Then Restore

いまの設定を保存してから戻す
Save Current Settings, Then Reset

いま入れたほうで起動し直す
Restart from the New Copy

いま見えている範囲を、そのまま画像にします。
Makes an image of exactly what you see now.

いま開くアプリ
Currently opens with

ここから上には見つかりません
Not found above this point

ここから下には見つかりません
Not found below this point

この Mac で本人確認が使えません: {0}
Identity check is not available on this Mac: {0}

この Mac のロック
This Mac's lock

この Mac のロック (Touch ID / Mac のパスワード)
This Mac's lock (Touch ID / Mac password)

この PDF には文字がありません (画像だけの PDF は読めません)
This PDF has no text (image-only PDFs cannot be read)

このアプリでは読めない新しい形式の暗号化ファイルです
This encrypted file uses a newer format that this app cannot read

このファイル
this file

このファイルの鍵はこの Mac にありません。暗号化した Mac でしか開けません。
The key for this file is not on this Mac. It can only be opened on the Mac that encrypted it.

このフォルダを開く
Open This Folder

この文書
this document

この文書を共有して共同編集する
Share this document for shared editing

この文書を共有します
Share This Document

この文書を共有する…
Share This Document…

この文書を暗号化したときの鍵ファイルではありません
This is not the key file used to encrypt this document

この答えで、対象の文章を置き換えますか？
Replace the target text with this answer?

この答えを、対象の文章のあとに足しますか？
Add this answer after the target text?

この鍵ファイルで暗号化しますか？
Encrypt with this key file?

これで暗号化
Encrypt with This

これは鍵ファイルではありません
This is not a key file

これまでの合計
Total so far

さくら (ピンク)
Sakura (Pink)

しまう
Minimize

すべてさとるエディタで開く
Open All with Satoru Editor

すべてのタブを表示
Show All Tabs

すべての設定が最初の状態に戻ります。
All settings return to their initial state.

すべての設定を最初の状態に戻しますか？
Reset all settings to their initial state?

すべてを手前に移動
Bring All to Front

すべてを表示
Show All

すべてを選択
Select All

すべて元に戻す
Restore All

すべて初期状態に戻す…
Reset Everything…

すべて既定に戻す
Restore All Defaults

すべて置換
Replace All

すべて表示に戻す
Show All Again

そちらの割り当てを外して、「{0}」に割り当てますか？
Remove that assignment and assign it to "{0}"?

そのまま保存
Save Without Encryption

だれか
Someone

だれでも読めるファイルに戻ります。
It becomes a file that anyone can read.

つながりません。アドレスとコードを確認してください。
Cannot connect. Check the address and code.

つながりません。アドレスを確認してください。
Cannot connect. Check the address.

どの Mac でも開けます。長いほど安全。
Opens on any Mac. The longer, the safer.

なし
None

ひのき緑
Cypress green

ふつう
Normal

ほかのアドレス: 
Other addresses:

ほかを隠す
Hide Others

まだ使えません。AI の設定をして「接続テスト」で確認してください。
Not ready yet. Set up the AI and confirm with "Test connection".

まだ使えません。\nAI の設定をして「接続テスト」で確認してください。
Not ready yet.\nSet up the AI and confirm with "Test Connection".

まだ使えません。キーを入れて「接続テスト」を押してください。
Not ready yet. Enter a key and press "Test connection".

まだ使えません。クリックで AI の設定を開く
Not ready yet. Click to open the AI settings

もう一度
Again

もう一度探す
Search Again

やめる
Cancel

やりとりを消す
Clear the conversation

やり直し
Redo

やり直し (⌘⇧Z)
Redo (⌘⇧Z)

やり直す
Redo

わかりました
I understand

アイコンの色 {0}
Icon color {0}

アドレス
Address

アドレスが正しくありません
The address is not valid

アドレスとコードが出るので、相手に伝えてください。
An address and a code will be shown; tell them to your partner.

アドレスとコードで参加\n→ 一緒に編集・チャット
Join with address and code\n→ edit and chat together

アプリのアイコン
App icon

アプリのアイコン: {0}
App icon: {0}

アプリケーションフォルダに入っています
Installed in the Applications folder

アプリケーションフォルダに入れる
Move to Applications Folder

アプリケーションフォルダに入れると安定します
More reliable when placed in the Applications folder

インデント
Indent

ウインドウ
Window

ウインドウ上下分割
Split Window Top/Bottom

ウインドウ枠・メニュー
Window Frame & Menus

エディタで開く
Open in the Editor

エディタ的 (改行ごとに 1 行)
Editor style (one line per line break)

エラー
Error

エラー ({0})
Error ({0})

エラー: 
Error:

エラーで終了しました (コード {0})
Ended with an error (code {0})

オンにする
Turn On

カスタム (OpenAI 互換 API: Ollama・LM Studio など)
Custom (OpenAI-compatible API: Ollama, LM Studio, …)

カット
Cut

カーソル (キャレット)
Caret

カーソルの位置
Caret position

カーソル行に色を付ける
Highlight the current line

カーソル行の背景
Current line background

カーソル行の行番号
Current line number

キャンセル
Cancel

キー
Key

キーのページ
Key page

キーを割り当てる…
Assign a Key…

キーを取りに行く…
Get a Key…

キーワード
Keywords

キーワード (空白・改行区切り)
Keywords (separated by spaces or new lines)

キー割り当て
Keys

キー割り当て…
Key Assignments…

クリックで「{0}」に切り替え
Click to switch to "{0}"

クリックでオフにします。
Click to turn off.

クリックでオンにします。
Click to turn on.

クリックで指定行へ移動
Click to go to a line

クリックで改行コードを変更
Click to change the line endings

クリックで文字コードを変更
Click to change the encoding

クリックで言語 (色分け・タブ幅) を変更
Click to change the language (coloring, tab width)

クリックで開く
Click to open

グラフと履歴が空になります (各社への支払いには関係ありません)。
The chart and history will be emptied (this does not affect what you pay the providers).

コピー
Copy

コピー (⌘C)
Copy (⌘C)

コピーしました
Copied

コメント
Comments

コメント / コメント解除
Toggle Comment

ゴミ箱から戻せます。
You can put it back from the Trash.

ゴミ箱に入れる
Move to Trash

サイズ
Size

サブフォルダも検索
Include subfolders

サーバ
Server

サーバ (SFTP / FTP)
Servers (SFTP / FTP)

サーバ (SFTP / FTP) につないでファイルを開く (⌃⌘O)
Connect to a server (SFTP / FTP) and open a file (⌃⌘O)

サーバ (SFTP / FTP) をオンにします
Turn On Servers (SFTP / FTP)

サーバ: {0} {1}
Server: {0} {1}

サーバが見つかりません。\n\n{0}
The server was not found.\n\n{0}

サーバとのやりとりに失敗しました
The server operation failed

サーバにつなぐ (SFTP / FTP)…
Connect to a Server (SFTP / FTP)…

サーバのファイルを開いて編集。保存するとサーバに反映。
Open and edit files on a server. Saving writes them back.

サーバの設定
Server Settings

サーバの鍵が前と違うので止めました (なりすましの恐れ)。\n\n{0}
Stopped because the server's key has changed (possible impersonation).\n\n{0}

サーバをダブルクリックで接続
Double-click a server to connect

サーバを追加
Add a Server

サーバ上のファイルは消えません。
Files on the server are not deleted.

シェル
Shell

スクリーンショット (画像にする)
Screenshot (make an image)

スクリーンショット (画像にする): 見えている部分か文書全体を、コピーまたは PNG で保存
Screenshot (make an image): copy or save as PNG the visible part or the whole document

スクリーンショット (画像にする)…
Screenshot (Make an Image)…

ステータスバーの文字 (*)
Status bar text (*)

ステータスバーの背景 (*)
Status bar background (*)

スマホの登録をやめました。
Phone setup was cancelled.

スマホの認証アプリ (Google Authenticator など) でこの QR コードを読み、出てきた 6 桁を入れてください。
Scan this QR code with your phone's authenticator app (such as Google Authenticator) and enter the 6 digits it shows.

スマホをなくすと開けなくなります。設定キーを控えておくと、新しいスマホに登録し直せます。
If you lose your phone you cannot open the file. Keep the setup key so you can register a new phone.

タブで開く
Opens in a tab

タブ・全角空白の記号
Tab and full-width space marks

タブ幅
Tab width

タブ幅は「ファイルタイプ別の設定」で。
Tab width is set under File Type Settings.

ダブルクリックして、キーを押す。太字は変更したもの。
Double-click, then press a key. Bold items have been changed.

ダーク
Dark

チェックした拡張子は、ダブルクリックでさとるエディタが開きます。
Checked extensions open in Satoru Editor when double-clicked.

チェックを外すとメニューに出なくなります。
Unchecked items no longer appear in the menus.

チャットを表示 / 隠す
Show / Hide Chat

ツリーに出すフォルダを選び直す
Choose another folder for the tree

ツリーに出すフォルダを選んでください
Choose the folder to show in the tree

ツールバーを編集…
Edit Toolbar…

テキスト
Text

テキストとして読み込む PDF を選んでください
Choose a PDF to import as text

テーマ
Theme

テーマ {0}
Theme {0}

テーマに合わせる
Match the theme

テーマの色に戻す
Return to the theme color

テーマを「{0}」に切り替えますか？
Switch the theme to "{0}"?

トークン
Tokens

バックアップを作れませんでした: {0}
Could not create a backup: {0}

バッチファイル
Batch File

パスをコピー
Copy Path

パスコード
Passcode

パスコード (数字 6 桁以上)
Passcode (6 or more digits)

パスコード (数字)
Passcode (digits)

パスワード
Password

パスワード (8 文字以上)
Password (8 or more characters)

パスワード (パスコード) が違うか、ファイルが壊れています
Wrong password (passcode), or the file is damaged

パスワード / 鍵のパスフレーズ (なければ空)
Password / key passphrase (empty if none)

パスワードが違います。
Wrong password.

パスワードとスマホの 6 桁の両方が要ります。この Mac でしか開けません。
Needs both the password and the 6 digits from your phone. Opens only on this Mac.

パスワードは {0} 文字以上にしてください。
Use a password of at least {0} characters.

パスワードはキーチェーンに保存されます。
The password is stored in the keychain.

パスワードを忘れると、だれにも開けなくなります。
If you forget the password, nobody can open the document.

パスワード・パスコードは、忘れるとだれにも開けなくなります。
If you forget a password or passcode, nobody can open the file.

パスワード付きの PDF は読めません
Password-protected PDFs cannot be read

ピンクダーク
Pink Dark

ファイル
File

ファイル:
Files:

ファイルから検索 (⌘⇧F)
Find in files (⌘⇧F)

ファイルを右クリック →「さとるエディタで開く」
Right-click a file → "Open with Satoru Editor"

ファイルを開いたとき、前回のカーソル位置に戻す
Return to the last caret position when opening a file

ファイルを開く (⌘O)
Open a file (⌘O)

ファイルタイプ
File Type

ファイルタイプ別の設定
File Types

ファイルタイプ別の設定…
File Type Settings…

ファイル名
File names

ファイル名で絞り込み
Filter by file name

フォルダ
Folder

フォルダ:
Folder:

フォルダが見つかりません: {0}
Folder not found: {0}

フォルダの中身も一緒にゴミ箱に入ります。ゴミ箱から戻せます。
The folder's contents go to the Trash too. You can put them back from the Trash.

フォルダの中身を左にツリーで表示。たくさんのファイルを行き来できます。
Shows a folder as a tree on the left, to move between many files.

フォルダを右クリック →「さとるエディタで grep」
Right-click a folder → "grep with Satoru Editor"

フォルダを選ぶ
Choose a folder

フォルダを開く…
Open Folder…

フォルダツリー
Folder Tree

フォルダツリーをオンにします
Turn On the Folder Tree

フォルダツリーを出す / しまう (⌘⇧E)
Show / hide the folder tree (⌘⇧E)

フォルダツリーを閉じる
Close the Folder Tree

フォルダ未選択
No Folder Selected

フォント
Font

フォント "{0}" が見つかりません
Font "{0}" was not found

フォントを選ぶ…
Choose Font…

ブロックコメント
Block comment

ペースト
Paste

ホスト
Host

ホストが参加を断りました
The host declined the request

ホストとユーザーを設定してください
Set the host and user

ポート
Port

ポートは 1024〜65535 の数字にしてください
The port must be a number from 1024 to 65535

ポート番号が正しくありません
The port number is not valid

ミッドナイト (青)
Midnight (Blue)

メッセージ (return で送信)
Message (return to send)

メニュー
Menu

メニューを消去
Clear Menu

メニューバーの「用紙」で切り替えます。
Switch with the "Paper" menu.

メニュー名で絞り込み
Filter by menu name

メニュー名やキーで絞り込み
Filter by menu name or key

メニュー編集
Menus

メニュー編集…
Edit Menus…

メニュー項目
Menu Item

モデル
Model

モデル (かんたん選択)
Model (quick choice)

モデルが見つかりません。
The model was not found.

モデルの一覧を取得しています…
Getting the list of models…

モデルを選んでください
Choose a model

モデルを選んでください (設定 > AI アシスタント)。
Choose a model (Settings > AI Assistant).

ユーザー
User

ライト
Light

リンクをコピー
Copy Link

リンクを開く
Open Link

ログインできません。\n\n{0}
Cannot log in.\n\n{0}

ログインできません。ユーザー名とパスワードを確認してください。\n\n{0}
Cannot log in. Check the user name and password.\n\n{0}

ログイン方法
Login method

ワンタイム認証
One-time code

ワンタイム認証 (スマホの認証アプリ)
One-time code (phone authenticator app)

ワンタイム認証: スマホを登録
One-time Code: Set Up Your Phone

ワンタイム認証を {0} 回まちがえたので、開くのをやめました。
The one-time code was wrong {0} times, so opening was cancelled.

ワープロ的 (折り返しも 1 行)
Word-processor style (wrapped lines count too)

・ボタンを押したときだけ、文章が AI の会社に送られます。\n・社外秘や個人情報は送らないでください。\n・使った分だけ料金がかかります。\n・AI の答えは間違うことがあります。\n・暗号化した文書は送りません。
• Text is sent to the AI company only when you press a button.\n• Do not send confidential or personal information.\n• You are charged for what you use.\n• AI answers can be wrong.\n• Encrypted documents are never sent.

一周する (端まで行ったら反対の端から)
Wrap around (continue from the other end)

一番外側が { } ではありません
The outermost value is not { }

一覧から外す
Remove from List

一覧から好きなモデルを選びます。
Pick any model from the list.

一覧を取得
List models

一覧表にないモデルの単価 ($ / 100 万トークン)  入力
Price for models not in the table ($ per 1M tokens)  Input

左右に分割
Split Left and Right

ウインドウ左右分割
Split Window Left and Right

ウインドウを左右に並べる
Tile Windows Left and Right

ウインドウを上下に並べる
Tile Windows Top and Bottom

タブにまとめる
Merge All Windows into Tabs

左右分割
Side by Side

左右に分割 / 分割をやめる (⌃⌥⌘S)
Split left and right / stop splitting (⌃⌥⌘S)

「{0}」は {1} あります
"{0}" is {1}

全部読み込むと、開くのに時間がかかり、メモリもたくさん使います。\n一部分だけ読み込めば、すぐに開けます。書き換えて保存すると、その部分だけがファイルに反映されます。
Loading all of it takes time and a lot of memory.\nLoading only a part opens right away. When you edit and save, only that part of the file is replaced.

先頭から
From

MB の位置から
MB into the file, load

MB 分
MB

全体は {0} MB です。行の途中では切らず、行の切れ目に合わせます。
The whole file is {0} MB. The range is adjusted to line boundaries.

一部分だけ読み込む
Load a Part

全部読み込む
Load All

一部分だけ読み込んだ文書は、暗号化して保存できません。全部読み込んでから暗号化してください。
A partially loaded document cannot be saved encrypted. Load the whole file first.

一部分だけ読み込み中: {0} 〜 {1} (全体 {2})
Partially loaded: {0} – {1} (of {2})

変更を保存していません
You have unsaved changes

読み込む範囲を変えると、保存していない変更はなくなります。
Changing the loaded range discards your unsaved changes.

変更を破棄して続ける
Discard and Continue

巨大ファイル: 読み込む範囲を変える…
Huge File: Change Loaded Range…

用紙モード
Paper Mode

原稿用紙
Manuscript Paper

詳細設定
Advanced Settings

キーを消す
Delete Key

キーを消しました
Key deleted

保存済み (変えるときだけ貼り付け)
Saved (paste only to change)

使う機能にチェック。使わない機能はメニューに出ません。▶ で説明を開閉、⚙ で細かい設定へ。
Check the features you use. Unused features stay out of the menus. ▶ shows the description, ⚙ opens detailed settings.

{0} の細かい設定を開く
Open detailed settings for {0}

開いている文書の鍵の変更・暗号化の解除は、メニューの「暗号化」か、下のステータスバーの 🔒 から行えます。
To change the key or remove encryption for an open document, use the Encryption menu or the 🔒 in the status bar.

考え中
Thinking

クリックで閉じる
Click to close

編集中
Editing

送信中
Uploading

更新 {0}
Updated {0}

送信失敗
Upload failed

サーバ上: {0} · {1}
On server: {0} · {1}

接続: {0}
Connection: {0}

読み込みました
Loaded

{0} 秒で取得。保存するとサーバへ送ります。
Fetched in {0} s. Saving sends it back to the server.

サーバから読み込みました
Loaded from server

{0} を読み込めませんでした
Couldn't load {0}

サーバへ送信中…
Uploading to server…

{0} に送信 ({1} 秒)
Sent at {0} ({1} s)

サーバに保存しました
Saved to server

サーバに送れませんでした
Couldn't upload to server

更新済み
Updated

サーバウインドウを開く
Open server window

サーバツリーを閉じる
Close server tree

ツリーに出すサーバを選ぶ
Choose the server to show

サーバツリー
Server tree

サーバツリーをエディタの横に出す
Show server tree beside editor

サーバが登録されていません。\n右上のボタンからサーバウインドウを開いて登録してください。
No servers registered.\nOpen the server window with the button at the top right to add one.

つなげませんでした
Couldn't connect

編集中のタブを出しました
Showing the tab you are editing

保存していない変更があるので、サーバから取り直していません。
It has unsaved changes, so it was not fetched again from the server.

このフォルダをお気に入りから外す
Remove this folder from favorites

このフォルダをお気に入りに入れる
Add this folder to favorites

お気に入り
Favorites

(まだありません)
(none yet)

最近見たフォルダ
Recent folders

最近開いたファイル
Recently opened files

履歴を消す
Clear history

お気に入り・最近見た場所へ一発で行く
Jump to a favorite or recent place

サーバを選んでください
Choose a server

お気に入りから外す
Remove from favorites

お気に入りに入れる
Add to favorites

お気に入りに入れました: {0}
Added to favorites: {0}

お気に入りから外しました: {0}
Removed from favorites: {0}

サーバを選ぶと出ます
Choose a server to see them

★ または右クリックで追加
Add with ★ or right-click

お気に入り・履歴
Favorites & history

受信中
Downloading

やりとり中
In progress

窓に合わせる
Fit to window

実寸
Actual size

ほかのアプリで開く
Open in another app

{0} (バイナリ表示)
{0} (binary view)

位置
Offset

16 進数
Hex

文字
Text

{0} ({1} バイト)・読むだけ
{0} ({1} bytes) · read only

位置 (16 進)
Offset (hex)

テキストとして開く
Open as text

タブで開き中
Open in tab

開き中
Open

接続しています: {0}
Connecting: {0}

接続しました ({0} 秒)。最初のフォルダ: {1}
Connected ({0} s). Start folder: {1}

一覧を読み込み中: {0}
Listing: {0}

一覧: {0} ({1} 項目、{2} 秒)
Listed: {0} ({1} items, {2} s)

一覧を読めませんでした: {0} — {1}
Couldn't list: {0} — {1}

秒まで分かる一覧が使えないので、ふつうの一覧にします
Precise listing not available; using the normal listing

受信中: {0}
Downloading: {0}

受信しました: {0} ({1}、{2} 秒)
Downloaded: {0} ({1}, {2} s)

受信できませんでした: {0} — {1}
Couldn't download: {0} — {1}

送信中: {0} ({1})
Uploading: {0} ({1})

送信しました: {0} ({1} 秒)
Uploaded: {0} ({1} s)

送信できませんでした: {0} — {1}
Couldn't upload: {0} — {1}

手元の一時ファイルを消しました: {0}
Removed local temp file: {0}

サーバのログ
Server log

ログ
Log

ログをコピー
Copy log

ログを消す
Clear log

送受信中
Transferring

「{0}」を開きますか？
Open “{0}”?

プログラムを書くとき、入力中に候補と関数の引数を出す (入力補完)
Suggest completions and function parameters while typing code (code completion)

候補は ↑↓ で選び、Enter か Tab で入れます。Esc で閉じます。⌃Space か ⌥Esc でいつでも出せます。
Use ↑↓ to choose a suggestion and Enter or Tab to insert it. Esc closes the list. Press ⌃Space or ⌥Esc to show it any time.

GitHub のリポジトリの URL か、zip の URL を貼ってください。
Paste the URL of a GitHub repository or a zip file.

JavaScript を動かせませんでした
Could not start JavaScript

URL から入れる (GitHub など)…
Install from URL (GitHub etc.)…

URL が正しくありません: {0}
Invalid URL: {0}

URL から拡張機能を入れる
Install an Extension from URL

URL から入れたものではないので、更新できません
This was not installed from a URL, so it cannot be updated

main.js を開く
Open main.js

main.js を書き換えて保存すると、すぐ読み直します
Edit and save main.js to reload it right away

manifest.json が見つかりません
manifest.json not found

manifest.json に問題があります: {0}
Problem in manifest.json: {0}

zip の中に、フォルダの外へ書き出すファイルがあります
The zip contains files that would be written outside the folder

{0} 行目
line {0}

{0} が見つかりません
{0} not found

{0} を読めませんでした
Could not read {0}

{0} がフォルダの外を指しています
{0} points outside the folder

＋ 拡張機能を追加
+ Add Extension

「{0}」を {1} から {2} に入れ替えますか？
Replace “{0}” {1} with {2}?

「{0}」を入れました
Installed “{0}”

「{0}」を入れますか？
Install “{0}”?

「{0}」を外しますか？
Remove “{0}”?

「{0}」を読み直しました
Reloaded “{0}”

名前 (英小文字・数字・-) を入れてください。~/.satoruEditor/plugins の中にひな形を作ります。
Enter a name (lowercase letters, digits, -). A template is created in ~/.satoruEditor/plugins.

内蔵
Built-in

外す
Remove

作者: {0}   版: {1}
Author: {0}   Version: {1}

作り方 (API の説明) を見る
How to Make One (API Guide)

入れる
Install

追加…
Add…

権限「{0}」がないので使えません。manifest.json の permissions に書いてください
No “{0}” permission. Add it to permissions in manifest.json

読み直す
Reload

使う権限: {0}
Permissions: {0}

入れた元: {0}
Installed from: {0}

自分で作る (ひな形を作る)…
Make Your Own (Create Template)…

フォルダを Finder で表示
Show Folder in Finder

入れ替える
Replace

詳細設定…
Settings…

フォルダ・zip から入れる…
Install from Folder or Zip…

大きすぎます (20 MB まで)
Too large (20 MB max)

説明をここに
Description here

入っている機能 ({0})
Installed ({0})

読み込みました (コマンド {0} 個)
Loaded ({0} commands)

そのほかの操作
More Actions

ネットにつなぐ
Access the network

一時的に止める
Pause

入れられる機能
Available

拡張機能を追加
Add Extension

ほかの人が作った JS の拡張機能を、URL・フォルダ・zip から入れます。自分で作ることもできます。
Install JS extensions made by others from a URL, folder or zip. You can also make your own.

拡張機能のフォルダ (manifest.json が入ったもの) か zip を選んでください
Choose an extension folder (containing manifest.json) or a zip

ひな形を作りました
Template created

ダウンロードしました
Downloaded

新しい拡張機能を作る
Make a New Extension

新しい版を取ってくる
Get the Latest Version

特別な権限は使いません (文書の読み書きだけ)
No special permissions (only reads and edits the document)

ダウンロードしています…
Downloading…

拡張機能のフォルダを開く
Open Extensions Folder

追加機能を入れる・外す…
Install / Remove Features…

クリップボードを読み書きする
Read and write the clipboard

ダウンロードできませんでした
Download failed

フォルダはゴミ箱に移します。
The folder will be moved to the Trash.

ダウンロードできませんでした: {0}
Download failed: {0}

名前に使えない文字があります: {0}
The name contains characters that cannot be used: {0}

メニューのコマンドはありません
No menu commands

拡張機能を入れられませんでした
Could not install the extension

メニュー「追加機能」から使えます
Use it from the Features menu

同じ名前のフォルダがもうあります
A folder with that name already exists

メニュー「追加機能」に出るコマンド:
Commands in the Features menu:

この拡張機能にはネットを使う権限がありません
This extension does not have network permission

ほかの人が作ったプログラムです。信頼できる作者のものだけ入れてください。
This is a program made by someone else. Install only extensions from authors you trust.

使いたい機能を「入れる」と、メニューとボタンに出ます。いらなくなったら「外す」だけ。カードを押すと説明が出ます。
Install a feature and it appears in the menus and toolbar. Remove it when you no longer need it. Click a card for details.

新規作成
New

新規作成 (⌘N)
New document (⌘N)

＊
*

カーソル行の文字 (透明にすると色を変えない)
Cursor line text (transparent = unchanged)

＋{0} 行 追加   −{1} 行 削除
+{0} added   −{1} removed

差分 (編集前との違い) を表示
Show Diff (Changes Since Opened/Saved)

差分
Diff

差分: 編集前とどこが変わったかを横に表示 (⇧⌘D)
Diff: show what changed since opened/saved, beside the text (⇧⌘D)

同じ行 {0} 行
{0} unchanged lines

変更はありません
No changes

大きすぎるので比べていません
Too large to compare

用紙 (クリックで 標準エディタ・原稿用紙・A4用紙 を切り替え)
Paper (click to switch: standard editor, manuscript, A4 paper)

標準
Standard

\n\n(文章を変える依頼なら、入れる内容には、変えていない部分も含めて対象の文章を省略せずに全部入れてください。)
\n\n(If this is a request to change the text, the content to insert must include the entire target text, including unchanged parts, without omitting anything.)

\n\n出力の形: はじめにユーザーへのひとこと (1〜2 文。何をしたか) を書き、そのあと文章に入れる内容だけを <result> と </result> で囲んで出力してください。
\n\nOutput format: first write a short note to the user (1–2 sentences on what you did), then output only the content to insert, wrapped in <result> and </result>.

▼ 全部表示 ({0} 行)
▼ Show all ({0} lines)

▲ たたむ
▲ Collapse

メニュー (設定など)
Menu (settings, etc.)

\n\n出力の形: はじめにユーザーへのひとこと (1〜2 文) を書いてください。文章やコードを書く・直す・足す・消すなど、エディタの中身を変える依頼なら、そのあとエディタに入れる内容だけを <result> と </result> で囲んで出力してください (コードも ``` ではなく <result> で囲む)。エディタの中身を変えない質問への答えのときだけ、<result> を使わないでください。
\n\nOutput format: first write a short note to the user (1–2 sentences). If the request changes the editor contents (writing, fixing, adding or deleting text or code), then output only the content to put in the editor, wrapped in <result> and </result> (wrap code in <result> too, not ```). Only when answering a question that does not change the editor contents, do not use <result>.

1. Ollama (AI を動かす無料のソフト)
1. Ollama (free software that runs the AI)

2. モデルを入れて「使う」
2. Install a model and click Use

AI アシスタントを「{0}」につなぎました
AI Assistant is now connected to “{0}”

AI アシスタントは、いま「{0}」につないでいます。上の一覧で「使う」を押すと、ローカルの AI に切り替わります。
AI Assistant is currently connected to “{0}”. Click Use in the list above to switch to the local AI.

AI アシスタントは、ローカルの「{0}」を使います。
AI Assistant uses the local model “{0}”.

Ollama を起動する
Start Ollama

Ollama は動いています。
Ollama is running.

Ollama は入っていますが、動いていません。「Ollama を起動する」を押してください。
Ollama is installed but not running. Click Start Ollama.

約 {0} GB
about {0} GB

「{0}」を消しますか？
Delete “{0}”?

「{0}」を入れられませんでした
Could not install “{0}”

自分の Mac の中で動く AI
AI That Runs on Your Own Mac

使用中
In use

大きさ
Size

ローカルLLM簡単設定…
Local LLM Easy Setup…

ローカルLLM簡単設定
Local LLM Easy Setup

エディタの AI アシスタントで、そのまま使えます
You can use it right away in the editor's AI Assistant

いまの接続先
Current connection

入っているモデル
Installed model

確かめています…
Checking…

起動しています…
Starting…

軽い。英語が得意
Light. Good at English

ほかのモデルの名前 (例: phi4-mini)
Another model name (e.g. phi4-mini)

モデルのファイルを Mac から消します。あとでまた入れられます。
This deletes the model files from this Mac. You can install it again later.

「使う」を押すと、AI アシスタントがこのモデルになります
Click Use to make AI Assistant use this model

モデルの一覧を見る…
Browse Models…

軽い。プログラム向き
Light. For code

軽い。日本語もそこそこ
Light. Decent at Japanese

速さと賢さのバランス型
Balance of speed and quality

日本語がしっかり。メモリ 8 GB 以上で
Solid Japanese. Needs 8 GB of memory or more

いま別のモデルを入れています
Another model is being installed

モデルの名前が正しくありません
Invalid model name

いちばん軽い。短い文章の手直し向き
Lightest. For touching up short text

終わってから、もう一度押してください。
Try again after it finishes.

文章は外に送られません。料金もかかりません。軽いモデルなので、短い文章の手直しや、ちょっとしたコード向きです (長い文書は、範囲を選んで頼んでください)。
Your text is not sent anywhere, and it costs nothing. These are light models, suited to touching up short text or small pieces of code (for long documents, select a range first).

Ollama を入れました
Ollama installed

Ollama を入れますか？
Install Ollama?

Ollama を自動で入れる
Install Ollama Automatically

Ollama を入れられませんでした
Could not install Ollama

Ollama がまだ入っていません。「Ollama を自動で入れる」を押すと、公式サイトから取ってきて「アプリケーション」に入れ、起動するところまで行います。
Ollama is not installed yet. Click Install Ollama Automatically to download it from the official site, put it in Applications and launch it.

いまの Ollama は macOS {0} 以上が必要です。この Mac は macOS {1} なので動きません。「公式ページを開く…」から、古い版を探すか、macOS を新しくしてください。
The current Ollama requires macOS {0} or later. This Mac runs macOS {1}, so it will not run. Use “Open Official Page…” to look for an older version, or update macOS.

公式サイト (ollama.com) からダウンロードして、「アプリケーション」フォルダに入れて起動します。\n正規のアプリか、この Mac で動く版かを確かめてから入れます。数百 MB あるので、少し時間がかかります。
Downloads from the official site (ollama.com), puts it in the Applications folder and launches it.\nIt is checked to be the genuine app and to run on this Mac before installing. It is a few hundred MB, so this takes a little while.

公式ページを開く…
Open Official Page…

ダウンロードしています… {0}% ({1} / {2})
Downloading… {0}% ({1} / {2})

ダウンロードしたファイルを開けませんでした
Could not open the downloaded file

確かめて、アプリケーションに入れています…
Checking and installing into Applications…

起動したら、下の一覧からモデルを入れてください
Once it starts, install a model from the list below

「アプリケーション」フォルダに入れられませんでした
Could not copy into the Applications folder

ダウンロードしたファイルの中に、アプリが見つかりません
No app found in the downloaded file

正規のアプリだと確かめられなかったので、入れませんでした
It could not be verified as the genuine app, so it was not installed

この Mac (macOS {0}) では Ollama は動きません。macOS {1} 以上が必要です。
Ollama does not run on this Mac (macOS {0}). macOS {1} or later is required.

この Mac (macOS {0}・{1}) は、いまの Ollama (macOS {2} 以上) に対応しています。({3})
This Mac (macOS {0}, {1}) supports the current Ollama (macOS {2} or later). ({3})

この Mac は macOS {0} ({1}) です。いまの Ollama は macOS {2} 以上が必要なので動きません。代わりに、この Mac でも動く前の版 ({3}) を入れます。({4})
This Mac runs macOS {0} ({1}). The current Ollama requires macOS {2} or later, so it will not run. An earlier version ({3}) that runs on this Mac will be installed instead. ({4})

この Mac の macOS では、いまの版が動かないので、前の版 ({0}) を入れます。
The current version does not run on this Mac's macOS, so the earlier version ({0}) will be installed.

前の版の Ollama ({0}) を自動で入れる
Install Earlier Ollama ({0}) Automatically

この版の Ollama は、この Mac の CPU ({0}) では動きません。
This version of Ollama does not run on this Mac's CPU ({0}).

公式の説明書で確認
checked against the official documentation

アプリに入っている情報で判断
based on information built into the app

定型の依頼 (校正・要約・続きを書く など) を選ぶ
Choose a preset request (proofread, summarize, continue writing, …)

定型の依頼を選ぶ
Choose a preset request

定型の依頼
Preset Requests

挿入・置き換え・使った量
Insert, replace, usage

JS 拡張機能 ({0})
JS Extensions ({0})

外す (ゴミ箱へ)…
Remove (Move to Trash)…

内蔵の機能
Built-in Features

スイッチを入れると、メニューとボタンに出ます。行を押すと説明が出ます。
Turn a switch on and the feature appears in the menus and toolbar. Click a row for details.

基本
Basics

＋ 拡張機能を追加…
+ Add Extension…

まだありません。URL・フォルダ・zip から入れたり、自分で作ったりできます。
None yet. Install one from a URL, folder or zip, or make your own.

ドラッグで幅を変える
Drag to resize

{0} 行
{0} lines

エディタの横に戻す
Dock Beside the Editor

別のウインドウに取り出す
Open in a Separate Window

公式サイト
Official website

インターネット側の IP アドレスを調べています…
Looking up the internet-side IP address…

インターネット越しにつなぐには、ルーターで「ポート {0} (TCP) をこの Mac ({1}) へ転送する」設定が要ります。
To connect over the internet, your router must forward port {0} (TCP) to this Mac ({1}).

同じ Wi-Fi・LAN の中の人は「{0}」でつながります。
People on the same Wi-Fi / LAN can connect with “{0}”.

インターネット側の IP アドレスを調べられませんでした。同じ Wi-Fi・LAN の中の人には「{0}」とコード「{1}」を伝えてください。
Could not look up the internet-side IP address. Give people on the same Wi-Fi / LAN “{0}” and the code “{1}”.

{0} さんが参加しました (いま {1} 人)
{0} joined (now {1})

{0} さんが抜けました (いま {1} 人)
{0} left (now {1})

参加中 ({0} 人): 
Participants ({0}): 

共有を始めました (名前: {0}、ポート {1})。
Sharing started (name: {0}, port {1}).

共有中 {0} 人
Sharing: {0} people

参加中 {0} 人
Joined: {0} people

共同編集でつながっている人数 (自分も入れて)。クリックでチャットを出す / しまう
People connected to this shared document (including you). Click to show or hide the chat

アプリ全体 (ウインドウ全体)
Whole app (entire window)

ツールバー・タブ・横の欄・フッターも入れて、ウインドウをまるごと画像にします。
Captures the entire window, including the toolbar, tabs, side panels and footer.

誤字・表記を直す (作文)
Fix typos and notation (essay)

次の作文の誤字脱字・送りがな・句読点・表記ゆれを直してください。原稿用紙の作文の決まりに合わせ、内容や言い回しは変えないでください。直した後の全文だけを出力してください。
Fix typos, okurigana, punctuation and inconsistent notation in the following essay. Follow the rules for essays on manuscript paper, and do not change the content or wording. Output only the full corrected text.

読みやすく (作文)
Make it readable (essay)

次の作文を、書いた人らしさと内容を変えずに、読みやすい作文に整えてください。整えた後の全文だけを出力してください。
Polish the following essay so it reads well, keeping the writer's voice and content. Output only the full polished text.

続きを書く (作文)
Continue writing (essay)

次の作文の続きを、同じ文体・同じ書き手の気持ちで自然に書いてください。続きの部分だけを出力してください。
Continue the following essay naturally, in the same style and with the same writer's feelings. Output only the continuation.

400 字にまとめる
Condense to 400 characters

次の作文を、原稿用紙 1 枚 (400 字) ほどにまとめてください。題名と名前の行は残し、まとめた後の全文だけを出力してください。
Condense the following essay to about one sheet of manuscript paper (400 characters). Keep the title and name lines, and output only the full condensed text.

800 字にふくらませる
Expand to 800 characters

次の作文を、内容を変えずに、くわしい様子や気持ちを足して原稿用紙 2 枚 (800 字) ほどにしてください。題名と名前の行は残し、ふくらませた後の全文だけを出力してください。
Expand the following essay to about two sheets of manuscript paper (800 characters) by adding details and feelings, without changing the content. Keep the title and name lines, and output only the full expanded text.

先生のように講評
Review like a teacher

次の作文を読んで、先生のように講評してください。よいところを 3 つ、もっとよくなるところを 3 つ、書いた人に伝わるやさしい言葉で書いてください。
Read the following essay and review it like a teacher: three good points and three points to improve, in gentle words the writer will understand.

題名を考える
Suggest titles

次の作文に合う題名の案を 5 つ考えてください。
Suggest five titles that fit the following essay.

作文の定型の依頼
Essay Requests

\n\nいま書いているのは、原稿用紙 (縦書き 400 字詰め) の作文です。作文の形と、原稿用紙の書き方の決まりを守ってください。\n作文の形: 1 行目に題名、2 行目に名前、3 行目は空けて、4 行目から本文。題名・名前の行には空白を入れない (題名を 3 マス下げる・名前を下に寄せるのは、アプリが自動で行う)。文書全体を書き直すときは、この形のまま出力する。\n本文の決まり: 段落の初めは全角スペース 1 つで 1 字下げる。会話は「」で囲み、行を改める (会話の行は字下げしない)。数字は漢数字で書く。英字・記号・半角の文字はできるだけ使わない (使うときは全角)。句読点やかっこも 1 字として数える。文体 (です・ます / だ・である) はもとの作文にそろえる。マークダウンや箇条書きは使わない。
\n\nThe document is a Japanese essay on manuscript paper (vertical, 400 characters per sheet). Keep the essay layout and the manuscript-paper conventions.\nLayout: line 1 is the title, line 2 the writer's name, line 3 blank, and the body from line 4. Put no spaces on the title and name lines (the app indents the title by three cells and pushes the name down automatically). When rewriting the whole document, output it in this layout.\nBody: indent each paragraph with one full-width space; put dialogue in 「」 on its own line (dialogue lines are not indented); write numbers in kanji numerals; avoid Latin letters, symbols and half-width characters (use full-width if needed); punctuation and brackets count as one character each; keep the original style (desu/masu or da/de aru); do not use Markdown or bullet points.

題名・名前・本文の形に整える
Arrange as title, name and body

次の作文を、原稿用紙の作文の形 (1 行目に題名、2 行目に名前、3 行目は空けて、4 行目から本文) に整えてください。題名や名前が分からなければ、題名は内容に合うものを考え、名前の行は「名前」としてください。本文は原稿用紙の決まりに合わせ、内容は変えないでください。整えた後の全文だけを出力してください。
Arrange the following essay in the manuscript-paper layout (line 1 title, line 2 name, line 3 blank, body from line 4). If the title or name is unknown, make up a fitting title and use 「名前」 for the name line. Follow the manuscript-paper conventions in the body without changing the content. Output only the full arranged text.

いま見えている A4 用紙 1 枚を、ちょうど用紙が入る大きさで画像にします。
Captures the A4 page you are looking at, framed to fit the page.

いま見えている原稿用紙 1 枚を、ちょうど用紙が入る大きさで画像にします。
Captures the manuscript sheet you are looking at, framed to fit the sheet.

上下に分割
Split Top/Bottom

上下に分割 / 分割をやめる (⌃⌘S)
Split top/bottom / stop splitting (⌃⌘S)

上書き保存 (⌘S)
Save (⌘S)

上書き保存の前にバックアップ (ファイル名.bak) を作る
Make a backup (filename.bak) before overwriting

上検索
Find Up

上限に達したか、混んでいます。少し待ってください。
You hit a limit or the service is busy. Please wait a moment.

頼みたいことを書いて送るか、入力欄の「…」から定型の依頼を選びます。範囲を選んでいればその部分、選んでいなければ文書全体が対象です。
Write what you want and send it, or pick a preset request from “…” in the input box. If a range is selected, it applies to that part; otherwise to the whole document.

下検索
Find Down

中止
Stop

中止しました
Stopped

中止しました ({0} 件)
Stopped ({0} found)

二段階
Two-step

二段階 (パスワード + ワンタイム認証)
Two-step (password + one-time code)

今日
Today

今月
This month

作る
Create

作文
Essay

作文の自動整形
Manuscript auto format

原稿用紙 (縦書き 400 字詰め)
Manuscript Paper (vertical, 400 characters)

原稿用紙 (縦書き) や A4 用紙の見た目で書けます。
Write on what looks like manuscript paper (vertical) or A4 paper.

原稿用紙: 半角の英数字を全角にする
Manuscript: Convert Half-width Letters and Digits to Full-width

原稿用紙: 改行のたび全角スペースを入れる (自動整形オフのとき)
Manuscript: Insert a Full-width Space after Each Line Break (when auto format is off)

原稿用紙: 漢字にふりがなを付ける (自動)
Manuscript: Add Furigana to Kanji (automatic)

原稿用紙: 自動整形 (題名 3 マス下げ・名前 下寄せ・段落 1 マス下げ)
Manuscript: Auto Format (title 3 cells down, name at the bottom, paragraphs 1 cell down)

原稿用紙\n(縦書き)
Manuscript paper\n(vertical)

原稿用紙のまま (マス目つき・縦書き、1 枚 400 字を A4 横 1 ページに) PDF にします
Export as PDF keeping the manuscript paper (grid, vertical writing; one 400-character sheet per A4 landscape page)

原稿用紙の漢字に、自動でふりがなを付ける
Add furigana to kanji on manuscript paper automatically

使い方: ⇧⌘A で開き、文章を選んでボタンを押す。
How to use: open with ⇧⌘A, select some text and press a button.

使う
Use

使う AI
AI service

使う機能にチェック。使わない機能はメニューに出ません。▶ で説明を開閉できます。
Check the features you use. Unused features do not appear in the menus. Use ▶ to show or hide details.

例: " '
e.g. " '

例: /* */ , <!-- -->
e.g. /* */ , <!-- -->

例: //
e.g. //

例: 192.168.1.10:{0}
e.g. 192.168.1.10:{0}

例: 2.5
e.g. 2.5

例: ABCD-EFGH-JKLM-NPQR
e.g. ABCD-EFGH-JKLM-NPQR

例: Makefile .zshrc
e.g. Makefile .zshrc

例: c h cpp (空白区切り)
e.g. c h cpp (space separated)

保存
Save

保存しておいた設定ファイルを選んでください
Choose the settings file you saved

保存しました
Saved

保存しました。「接続テスト」で確認すると使えるようになります。
Saved. It becomes usable once "Test Connection" succeeds.

保存するとき行末の空白を削除する
Trim trailing spaces when saving

保存するとすぐサーバに反映されます。本番サーバでは注意。
Saving changes the server immediately. Be careful on production servers.

保存する文字コード
Encoding for Saving

保存のとき、見たままの PDF も一緒に作る
Also create a matching PDF when saving

保存時の状態に戻す
Revert to Saved

個別に変えた {0} 項目の色は消えます。
The colors of {0} items you changed individually will be lost.

個別の変更をすべて戻す
Undo All Individual Changes

元に戻す
Undo

元に戻す (⌘Z)
Undo (⌘Z)

先に暗号化を解除してください。
Remove the encryption first.

先頭まで検索したので末尾から検索しました
Reached the top; continued from the end

先頭を大文字に
Capitalize

入力 ${0} / 出力 ${1} (100 万トークン) ・ 日本語 1,000 字の校正で 約 ¥{2}
Input ${0} / output ${1} per million tokens · about ¥{2} to proofread 1,000 Japanese characters

入力 {0} / 出力 {1} トークン
Input {0} / output {1} tokens

入力トークン
Input tokens

共同編集
Shared Editing

共同編集 (共有)
Shared Editing (Sharing)

共同編集から抜けました。
You left shared editing.

共同編集に参加
Join Shared Editing

共同編集に参加しました。ここでチャットできます。
You joined shared editing. You can chat here.

共同編集のしくみ
How Shared Editing Works

共同編集・AI などは「追加機能」でオン・オフ。
Shared editing, AI and others are turned on and off in "Extras".

共有
Share

共有: 
Shared:

共有に参加…
Join Sharing…

共有を始められませんでした: {0}
Could not start sharing: {0}

共有を始める
Start Sharing

共有を終了
End Sharing

共有を終了 / 抜ける
End Sharing / Leave

共有を終了しました。
Sharing ended.

共有コード
Share code

共有コード:
Share code:

共有コードを入れてください
Enter the share code

共有機能はオフになっています
Sharing is turned off

内容重視
Best quality

円で計算
yen

再読み込み
Reload

出ないときは右クリックの「サービス」の中にあります。
If it does not appear, look inside "Services" in the right-click menu.

出力
Output

出力トークン
Output tokens

分割
Split

分割したもう一方へ移動
Switch to Other Pane

切り取り
Cut

切り取り (⌘X)
Cut (⌘X)

切り替え
Switch

切り替える
Switch

初期状態に戻す
Reset

別の文字コードを指定して開き直してください。
Reopen it with a different encoding.

別の鍵ファイル…
Another Key File…

別名で保存…
Save As…

別名保存
Save As

利用の記録を消しますか？
Clear the usage log?

利用可能
Ready

利用状況と料金…
Usage and Cost…

利用状況と料金を見る…
View Usage and Cost…

削除
Delete

前のタブ
Previous Tab

前を検索
Find Previous

割り当てる
Assign

割り当てを外す
Remove Assignment

動作環境
General

動作環境…
Preferences…

動作環境・ファイルタイプ別の設定・色とフォント・キー割り当て・メニュー編集をまとめて保存します
Saves the general settings, file type settings, colors and fonts, key assignments and menu editing together

単語単位で探す
Whole words only

印刷…
Print…

印刷の準備ができませんでした
Could not prepare for printing

参加する
Join

参加できませんでした
Could not join

参加中: 
Participants:

参加用: {0}
Join at: {0}

参照…
Browse…

取り消す
Undo

受け付けられませんでした。
The request was not accepted.

同じ文書を、ほかの人と同時に編集します。チャットつき。
Edit the same document with other people at the same time. Includes chat.

名前
Name

名前に / や : は使えません。
A name cannot contain / or :.

名前を付けて保存 (⌘⇧S)
Save with a new name (⌘⇧S)

名前を入れてください。
Enter a name.

名前を変更
Rename

名前を変更…
Rename…

名無し
Anonymous

和紙 (暖色ライト)
Washi (Warm Light)

回数
Requests

型名
Types

型名など (空白・改行区切り)
Type names etc. (separated by spaces or new lines)

墨
Ink black

変えたあと、起動し直すと切り替わります。
Takes effect after you restart the app.

変換
Convert

変更
Rename

変更はすぐ反映されます。
Changes apply immediately.

変更を破棄して {0} で開き直しますか？
Discard changes and reopen as {0}?

大文字で始まる語を型名の色にする
Color words starting with a capital as type names

大文字と小文字を区別
Match case

大文字と小文字を区別する
Match case

大文字に
To Uppercase

大文字・小文字を区別しない
Ignore case

安全上の理由で回答されませんでした ({0})
No answer was given for safety reasons ({0})

対応する括弧へ移動
Go to Matching Bracket

対象: 文書全体
Target: whole document

対象: 選んでいる {0} 文字
Target: {0} selected characters

小文字に
To Lowercase

山吹
Golden yellow

左にツリー
Tree on the left

復元する
Restore

承認する
Approve

折り返し
Word Wrap

折り返して表示する
Wrap long lines

抜ける
Leave

押すと、ほかの色を選べます
Click to choose another color

拡大/縮小
Zoom

拡張子
Extensions

拡張子 (例: vue)
Extension (e.g. vue)

指定行へ移動
Go to Line

指定行へ移動 (⌘L)
Go to line (⌘L)

指定行へ移動…
Go to Line…

挿入
Insert

挿入・置き換え
Insert / Replace

探しています…
Searching…

接続
Connect

接続が切れました。
The connection was lost.

接続できませんでした: {0}
Could not connect: {0}

接続を断られました。ポートを確認してください。\n\n{0}
The connection was refused. Check the port.\n\n{0}

接続を確認済みです。AI を使えます。
The connection is confirmed. The AI is ready to use.

接続を確認済みです。クリックで AI アシスタントを出す / しまう
Connection confirmed. Click to show / hide the AI Assistant

接続テスト
Test connection

接続元: {0}\n承認すると、この文書が相手に見えます。
From: {0}\nIf you approve, they will be able to see this document.

接続先
Service

改行したとき前の行のインデントを引き継ぐ (自動インデント)
Keep the previous line's indent on Enter (auto indent)

改行コード
Line Endings

改行マーク ↓
Line break mark ↓

改行・タブ・空白 (全角・半角) の記号を表示する
Show marks for line breaks, tabs and spaces (full- and half-width)

改行・タブ・空白の記号を表示
Show Line Breaks, Tabs and Spaces

数える
Count

数値
Numbers

数字 {0} 桁以上にしてください。
Use at least {0} digits.

文字コードを指定して開き直す
Reopen with Encoding

文字列
Strings

文字列の囲み
String quotes

文字化けしているとき: 指定して開き直す
If the text is garbled: reopen with an encoding

文字数 (改行は数えません)
Character count (line breaks are not counted)

文書
Document

文書を暗号化して保存。開けるのは鍵を持つ本人だけ。
Saves documents encrypted. Only someone with the key can open them.

文書全体
Whole document

文章が長すぎます
The text is too long

文章を選ぶ
Select text

料金
Cost

料金のページ
Pricing page

料金はアプリに入っている一覧表 ({0} に確認) による目安です。モデルを替えても、接続テストのやり直しは要りません。
Prices are estimates from the table built into the app (checked on {0}). Changing the model does not require another connection test.

料金は目安です (1 ドル = {0} 円で計算)。正確な金額は各社の請求画面で確認してください。
Costs are estimates (calculated at $1 = {0} yen). Check each provider's billing page for exact amounts.

料金不明
cost unknown

料金不明 (下で単価を入れると計算します)
Price unknown (enter a price below to calculate)

断る
Decline

新しいタブ (⌘T)
New tab (⌘T)

新しいファイル
New File

新しいファイルタイプ
New File Type

新しいファイルタイプ {0}
New File Type {0}

新しく作る…
Create New…

新規
New

新規.txt
new.txt

新規タブ
New Tab

新規ファイル
New File

新規ファイル…
New File…

新規ファイルの改行コード
Line endings for new files

新規ファイルの文字コード
Encoding for new files

新規フォルダ
New Folder

新規フォルダ…
New Folder…

既定に戻す
Restore Default

既定のアプリで開く
Open with the Default App

日別 (30 日)
Daily (30 days)

日本語
日本語 (Japanese)

時間切れです。ホストとポートを確認してください。\n\n{0}
Timed out. Check the host and port.\n\n{0}

普通の文字
Plain text

暖色ダーク
Warm Dark

暗号化
Encryption

暗号化されたファイルではありません
This is not an encrypted file

暗号化した文書は AI に送りません
Encrypted documents are not sent to the AI

暗号化した文書は共有できません
Encrypted documents cannot be shared

暗号化して保存
Save Encrypted

暗号化して保存… / 鍵の変更…
Encrypt and Save… / Change Key…

暗号化する
Encrypt

暗号化すると、鍵を持つ本人しか開けません。\nこの文書では、次の保存からは聞きません。
If encrypted, only the person with the key can open it.\nYou will not be asked again for this document.

暗号化に使う鍵ファイルを選んでください
Choose the key file to encrypt with

暗号化のしかた
How to Encrypt

暗号化の方法 (暗号化するときに最初に選ばれているものを選べます。保存のときに変えることもできます)
Encryption method (choose the one selected first when you encrypt; you can change it when saving)

暗号化を解除…
Remove Encryption…

暗号化を解除しますか？
Remove the encryption?

暗号化ファイル\n(だれも読めない)
Encrypted file\n(nobody can read it)

更新
Refresh

更新日時
Modified

書き換えない
Don't Rewrite

書き換えない (読むだけ)
Never rewrite (read only)

書き換えられませんでした
Could not rewrite

書式 > 文字コード で UTF-8 などに変更してから保存してください。
Change the encoding to UTF-8 or similar in Format > Encoding, then save.

最初のフォルダ
Initial folder

最大 
max

最安 & 最速 (おすすめ)
Cheapest and fastest (recommended)

最近使ったファイル
Recent Files

月
Month

月別 (12 か月)
Monthly (12 months)

未設定
Not set up

未設定です (設定を開いてください)
Not set up (open Settings)

末尾まで検索したので先頭から検索しました
Reached the end; continued from the top

本人だけ開ける
Only you can open it

本人確認できませんでした: {0}
Could not confirm your identity: {0}

本文の背景
Text background

朱
Vermilion

校正
Proofread

桁ルーラーを表示
Show Column Ruler

桁ルーラーを表示する
Show the column ruler

検索
Find

検索 (⌘F)
Find (⌘F)

検索:
Find:

検索… (条件を決めて探す)
Find…

検索する文字列
Find what

検索の条件
Search Options

検索・置換
Find & Replace

検索中…
Searching…

検索中… {0} 件
Searching… {0} found

次からはこちらを起動してください。
Start this copy from now on.

次のタブ
Next Tab

次の文章 (またはプログラム) が何を言っているか・何をしているかを、わかりやすく日本語で説明してください。
Explain clearly, in English, what the following text (or program) says or does.

次の文章が日本語なら英語に、それ以外なら日本語に翻訳してください。訳文だけを出力してください。
If the following text is Japanese, translate it into English; otherwise translate it into Japanese. Output only the translation.

次の文章の続きを、同じ文体・言語で自然に書いてください。続きの部分だけを出力してください。
Continue the following text naturally, in the same style and language. Output only the continuation.

次の文章の誤字脱字・文法の誤り・表記ゆれを直してください。直した後の全文だけを出力し、説明は付けないでください。
Fix typos, grammar mistakes and inconsistent spelling in the following text. Output only the full corrected text, with no explanation.

次の文章を、意味を変えずに、より読みやすく自然な文章に書き直してください。書き直した文章だけを出力してください。
Rewrite the following text so it reads more clearly and naturally, without changing the meaning. Output only the rewritten text.

次の文章を要点がわかるように短く要約してください。
Summarize the following text briefly so the main points are clear.

次を検索
Find Next

正規表現
Regular expression

正規表現が正しくありません
The regular expression is not valid

注意\n・承認した相手には、文書がすべて見えます。\n・承認は、信頼できる相手だけに。\n・使い終わったら「共有を終了」。
Note\n• Anyone you approve can see the whole document.\n• Approve only people you trust.\n• Choose "End Sharing" when you are done.

流出防止 (暗号化) をオンにします
Turn On Leak Protection (Encryption)

流出防止 (暗号化して保存)
Leak Protection (Save Encrypted)

流出防止のためです。
This is to prevent leaks.

浅葱
Pale blue-green

消す
Clear

灰色
Gray

無料 (手元の AI)
Free (local AI)

生成り
Ecru

用紙
Paper

用紙モード (原稿用紙・A4)
Paper Mode (Manuscript, A4)

用紙モード: 通常 → 原稿用紙 → A4
Paper mode: Normal → Manuscript → A4

用紙モードをオンにします
Turn On Paper Mode

画像
Image

画像として保存…
Save as Image…

画像にする範囲を選んでください。
Choose what to make into an image.

画像にできませんでした
Could not make the image

登録する
Register

目安の料金
Estimated cost

相手
Partner

相手に「{0}」とコード「{1}」を伝えてください。
Tell your partner the address "{0}" and the code "{1}".

知らないプリセット: {0} (使えるもの: {1})
Unknown preset: {0} (available: {1})

知らない項目: {0}
Unknown item: {0}

短く答えてください。
Answer briefly.

確認してから書き換える
Ask before rewriting

秘密鍵のファイル (id_ed25519 など、.pub ではないほう) を選んでください
Choose the private key file (id_ed25519 or similar; not the .pub one)

移動
Go

種類
Type

空ならログインした場所 (例: /var/www/html)
Empty = where you land after signing in (e.g. /var/www/html)

答え
Answer

簡易検索バー (ウインドウ内)
Find Bar (in the window)

約 ¥
about ¥

約 ¥%.1f
about ¥%.1f

紫
Purple

終了しました
Ended

組み込みのファイルタイプは名前を変えられません
Built-in file types cannot be renamed

組み込みの設定に戻す
Restore Built-in Settings

組み込みの設定のまま
Same as the built-in settings

結果
Results

続きを書く
Continue

編集
Edit

編集をすぐサーバに反映する
Upload Edits Automatically

置き換え
Replace

置き換えました (⌘Z で戻せます)
Replaced (⌘Z to undo)

置き換える
Replace

置換
Replace

置換 (⌘R)
Replace (⌘R)

置換:
Replace:

置換…
Replace…

置換後の文字列 (正規表現では \1 で後方参照)
Replacement text (with regular expressions, \1 is a back reference)

翻訳 (日⇔英)
Translate (JA⇔EN)

聞いたアドレスとコードを入れてください。
Enter the address and code you were given.

自分で追加したファイルタイプ
A file type you added

自分で選ぶ
Choose myself

自動 (macOS の言語に合わせる)
Automatic (follow macOS)

自動 (拡張子で判定)
Automatic (by extension)

自動で書き換える
Rewrite automatically

自動整形
Auto Format

色 (四角をクリックで変更、↺ でテーマの色に戻す。(*) はウインドウ枠が灰色/macOS のとき、変えない限り枠と同じ色)
Colors (click a square to change, ↺ to return to the theme color. (*) follows the frame color while the frame is gray/macOS, unless changed)

色・フォント
Colors

色・フォント (⌘,)
Colors & Fonts (⌘,)

色・フォント…
Colors and Font…

藍
Indigo

行
Lines

行の数え方
Line Counting

行を上へ移動
Move Line Up

行を下へ移動
Move Line Down

行を並べ替え
Sort Lines

行を削除
Delete Line

行を複製
Duplicate Line

行を複製 (⌘D)
Duplicate line (⌘D)

行コメント
Line comments

行末の空白を削除
Trim Trailing Spaces

行番号
Line numbers

行番号 (1〜{0})
Line number (1–{0})

行番号と本文の区切り線
Line between numbers and text

行番号の背景
Line number background

行番号を表示
Show Line Numbers

行番号を表示する
Show line numbers

行移動
Go to

行複製
Duplicate

行間
Line spacing

表示
View

表示されている部分
Visible part

表示の言語 (Language)
Display Language (表示の言語)

表示名
Display name

複数行の文字列
Multi-line strings

要約
Summarize

見えていない部分も含めて、最初から最後までを 1 枚の画像にします。
Makes one image from beginning to end, including the parts not on screen.

見つかった所をすべて強調する
Highlight all matches

見つからないか、権限がありません。\n\n{0}
Not found, or you do not have permission.\n\n{0}

見つかりません
Not found

見本をクリックすると、開いているすべてのタブがすぐ切り替わります
Click a sample and every open tab switches at once

覚えなくて OK。この Mac でしか開けません。
Nothing to remember. Opens only on this Mac.

覚えやすいけど、パスワードより弱め。
Easy to remember, but weaker than a password.

解除して保存
Remove and Save

言語 (このファイル)
Language (This File)

言語プロファイルの読み込みに失敗しました
Could not load the language profiles

記録を消す…
Clear Records…

設定
Settings

設定…
Settings…

設定は ~/.satoruEditor/theme.json に保存されます
Settings are stored in ~/.satoruEditor/theme.json

設定を復元しますか？
Restore the settings?

設定を開く
Open Settings

設定キー: {0}
Setup key: {0}

設定内容の保存
Export Settings

設定内容の保存…
Export Settings…

設定内容の復元
Import Settings

設定内容の復元…
Import Settings…

説明
Explain

読みは Mac に入っている辞書で付けます。人名などは外れることがあります。印刷・PDF にも入ります。
Readings come from the dictionary built into your Mac. Names and the like may be wrong. They are included in printing and PDF.

読みやすく
Polish

貼り付け
Paste

貼り付け (⌘V)
Paste (⌘V)

足しました (⌘Z で戻せます)
Added (⌘Z to undo)

足す
Add

追加
Add

追加機能
Extras

追加機能の説明と設定…
About the Extras and Their Settings…

送る
Send

送る (Finder の右クリックメニュー)
Send To (Finder right-click menu)

送信
Send

送信 (Enter)
Send (Enter)

逆インデント
Outdent

通常
Normal

選んだ鍵ファイルは、この文書を暗号化したときのものではありません。
The key file you chose is not the one used to encrypt this document.

選んでいる文字数
Number of selected characters

選択 {0} 字
{0} selected

選択…
Choose…

選択範囲の中だけ置換する
Replace only within the selection

選択範囲の背景
Selection background

選択部分を検索語にする
Use Selection for Find

重複行を削除
Remove Duplicate Lines

鍵で開く
Open with the key

鍵を作れませんでした
Could not create the key

鍵を作れませんでした。ほかの方法を選んでください。
Could not create the key. Choose another method.

鍵を保存できませんでした。ほかの方法を選んでください。
Could not store the key. Choose another method.

鍵ファイル
Key file

鍵ファイル (SFTP)
Key file (SFTP)

鍵ファイル (USB メモリなど)
Key file (on a USB drive, for example)

鍵ファイルがあるときだけ開けます。別の Mac でも開けます。
Opens only when the key file is present. Works on other Macs too.

鍵ファイルを USB メモリなどに置くと、それを挿しているときだけ開けます。\nなくすと開けなくなるので、控え (コピー) を別の場所にも置いてください。
If you keep the key file on a USB stick or similar, the document opens only while it is plugged in.\nIf you lose it you cannot open the document, so keep a copy somewhere else too.

鍵ファイルを置く場所を選んでください (USB メモリなど)
Choose where to put the key file (a USB stick, for example)

鍵ファイルを選びませんでした。
No key file was chosen.

鍵ファイルを選ぶ…
Choose Key File…

閉じる
Close

開き直す
Reopen

開く
Open

開く ←\n保存するとすぐ反映 →
Open ←\nSaving uploads at once →

開く…
Open…

開くたびにスマホに出る 6 桁を入れます。この Mac でしか開けません。
Enter the 6 digits shown on your phone each time. Opens only on this Mac.

関連付け
Associations

関連付け・右クリックメニュー…
File Associations and Context Menu…

頼んだあとに文章が変わったので、置き換える場所が分からなくなりました。「コピー」して貼り付けてください。
The text changed after you asked, so the place to replace is no longer clear. Use "Copy" and paste it yourself.

頼んだときの対象 (選んでいた範囲、なければ文書全体) をこの答えに置き換える
Replace the text you asked about (the selection at that time, or the whole document) with this answer

頼んだときの対象のあとに足す
Add after the text you asked about

題名 3 マス下げ・名前 下寄せ・段落 1 マス下げ
Title down 3 cells, name at the bottom, paragraphs down 1 cell

題名 中央・名前 右寄せ・段落 1 字下げ
Title centered, name right-aligned, paragraphs indented

黒板 (緑)
Blackboard (Green)

＋ {0} 項目を個別に変更中
+ {0} items changed individually

📄 PDF も保存: {0}
📄 PDF also saved: {0}

🔒 {0}を入れてください
🔒 Enter the {0}

🔒 コードを知らない人は入れません
🔒 Nobody can join without the code

🔒 パスワードと、スマホの認証アプリの 6 桁を入れてください
🔒 Enter the password and the 6 digits from your phone's authenticator app

🔒 ワンタイム認証: スマホの認証アプリの 6 桁を入れてください
🔒 One-time code: enter the 6 digits from your phone's authenticator app

🔒 暗号化 ({0})
🔒 Encrypted ({0})

🔒 鍵ファイルが必要です
🔒 A key file is required

🖼 画像をコピーしました ({0} × {1})
🖼 Image copied ({0} × {1})

🖼 画像を保存しました: {0}
🖼 Image saved: {0}

暗号化しています。クリックで暗号化の方法を変更
Encrypted. Click to change the encryption method

暗号化していません。クリックで暗号化の方法を選ぶ
Not encrypted. Click to choose an encryption method

暗号化なし
Not encrypted

暗号化の方法を変える
Change the encryption method

暗号化の方法を選ぶ
Choose an encryption method

暗号化の方法を変える…
Change the Encryption Method…

鍵の変更…
Change Key…

この文書の暗号化の設定…
Encryption Settings for This Document…

この文書の暗号化の設定
Encryption Settings for This Document

暗号化の方法
Encryption method

いま: 🔒 {0} で暗号化しています。
Now: 🔒 encrypted with {0}.

「方法を変える」は下で選んだ方法で、「鍵の変更」は同じ方法のまま新しい鍵で暗号化し直します。
"Change Method" re-encrypts with the method chosen below; "Change Key" re-encrypts with a new key using the same method.

方法を変える
Change Method

いま: 🔓 暗号化していません。下で選んだ方法で暗号化して保存できます。
Now: 🔓 not encrypted. You can encrypt and save with the method chosen below.

暗号化する
Encrypt

共同編集のあいだは変えられません。
This cannot be changed while co-editing.

鍵の変更 ({0})
Change Key ({0})

暗号化して保存…
Encrypt and Save…

{0} が許可されていません
{0} is not allowed

声
Voice

文章
Text

話す
Speak

速く
Faster

音声
Speech

マイク
Microphone

声で入力 (始める / 止める)
Dictate (Start / Stop)

ゆっくり
Slower

声で読む
Read aloud

読み上げ
Read Aloud

音声入力
Dictation

音声認識
Speech recognition

読み上げる / 止める (⌥⌘R)
Read aloud / stop (⌥⌘R)

読み上げる / 止める (選んだところ・なければカーソルから)
Read Aloud / Stop (Selection, or from the Cursor)

文字になる
Becomes text

試しに聞く
Listen

聞き取り中… 話してください (もう一度押すと止まります)
Listening… speak now (press again to stop)
聞こえています…
Listening…
止める
Stop
音声入力を止めます (esc キーでも止まります)
Stop dictation (esc also stops it)
うまく聞き取れませんでした ({0})
Couldn't recognize speech ({0})
聞き取り中… 話してください
Listening… speak now
音声認識の回数の上限に達しました
Speech recognition limit reached
Apple の音声認識は、短い時間に使える回数が決まっています。少し時間をおいてから、もう一度お試しください。
Apple's speech recognition can only be used a limited number of times in a short period. Please wait a while and try again.

「システム設定 > プライバシーとセキュリティ」で、さとるエディタに {0} を許可してください。
Allow {0} for Satoru Editor in "System Settings > Privacy & Security".

メニュー「音声 > 声で入力」かツールバーのマイクのボタンで始めます。話した言葉はカーソルの位置に入ります。少し黙ると、そこまでが文章に入ります。\n声は Apple のサーバに送って文字にします (インターネットが必要です)。
Start with "Speech > Dictate" or the microphone button in the toolbar. Your words go in at the cursor; when you pause, what you said so far is added.\nYour voice is sent to Apple's servers to be turned into text (an internet connection is needed).

読み上げを止める
Stop Reading

声は「システム設定 > アクセシビリティ > 読み上げコンテンツ」で増やせます。
You can add voices in "System Settings > Accessibility > Spoken Content".

システム設定を開く
Open System Settings

読み上げ・音声入力
Read Aloud & Dictation

いまは音声入力を使えません
Dictation is not available right now

読み上げ・音声入力の設定…
Read Aloud & Dictation Settings…

声で入力。もう一度押すと止まる
Dictate. Press again to stop

読み上げ・音声入力をオンにします
Turn On Read Aloud & Dictation

インターネットにつながっているか確かめてください。
Check that you are connected to the internet.

メニューバーの「音声」とツールバーのボタンで使います。\n音声入力では、声を Apple のサーバに送って文字にします。はじめて使うとき、マイクと音声認識の許可を聞かれます。
Use it from the "Speech" menu and the toolbar buttons.\nDictation sends your voice to Apple's servers to turn it into text. The first time, macOS asks for microphone and speech recognition access.

春の遠足。先週の金曜日、学校の遠足で動物園に行きました。
This is how the text will be read aloud.

文章を声で読み上げます。マイクで話して、声で文字を入力できます。
Reads your text aloud, and lets you type by speaking into the microphone.

反映
Apply to Document

反映・コピー・使った量
Apply, copy, usage

本文をまるごと、この答えに置き換える (⌘Z で戻せます)
Replace the whole document with this answer (⌘Z to undo)

本文を答えに置き換えました (⌘Z で戻せます)
Replaced the document with the answer (⌘Z to undo)

(高音質)
(enhanced)

Mac の声
Mac Voices

Mac に入っている声
Voices built into the Mac

VOICEVOX (無料の読み上げソフト) を使うと、キャラクターのきれいな声で読み上げます。「かんたんインストール」で入れると、キャラクターの声もまとめて入り、ON / OFF・削除もここでできます。
With VOICEVOX (free text-to-speech software), text is read aloud in clear character voices. "Easy Install" also installs the character voices, and you can turn it ON / OFF or delete it here.

VOICEVOX {0} につながりました
Connected to VOICEVOX {0}

VOICEVOX を起動
Start VOICEVOX

VOICEVOX を入手…
Get VOICEVOX…

VOICEVOX を起動しています…
Starting VOICEVOX…

VOICEVOX につながりません。VOICEVOX を起動してください。
Cannot connect to VOICEVOX. Please start VOICEVOX.

VOICEVOX が見つかりません。「VOICEVOX を入手…」から入れてください。
VOICEVOX was not found. Install it with "Get VOICEVOX…".

VOICEVOX の答えを読めませんでした
Could not read the response from VOICEVOX

VOICEVOX から答えがありませんでした ({0})
VOICEVOX did not respond ({0})

VOICEVOX で読み上げられませんでした
Could not read aloud with VOICEVOX

停止
Stop

再生
Play

抑揚
Intonation

速さ
Speed

音量
Volume

高さ
Pitch

一時停止
Pause

利用規約
Terms of Use

声の種類
Voice type

声の高さ
Pitch

最初から
From the Beginning

話す速さ
Speed

読み上げ中 (VOICEVOX:{0})
Reading aloud (VOICEVOX:{0})

ずんだもん (ノーマル)
Zundamon (Normal)

つなぎ直す
Reconnect

一時停止中
Paused

読み上げ中
Reading aloud

キャラクター
Character

初期値に戻す
Reset to Defaults

声は「システム設定 > アクセシビリティ > 読み上げコンテンツ」で増やせます (きれいな「拡張」の声もダウンロードできます)。
You can add voices in "System Settings > Accessibility > Spoken Content" (higher-quality "enhanced" voices can be downloaded too).

エンジンのアドレス
Engine address

声を作っています…
Generating voice…

キャラクターごとの利用規約を守ってください。読み上げた声を公開するときは「VOICEVOX:キャラクター名」と書く必要があります。
Follow each character's terms of use. When you publish audio, you must credit it as "VOICEVOX:character name".

起動したときの表示
View at startup

前回と同じ
Same as last time

エディタ (通常)
Editor (plain)

アプリを開いたときの白紙を、どの表示で始めるか。「前回と同じ」は、最後に使っていた表示で始めます。
Which view a new blank document starts in when the app opens. "Same as last time" starts in the view you used last.

ON (VOICEVOX で読み上げる)
ON (read aloud with VOICEVOX)

VOICEVOX をインストール…
Install VOICEVOX…

VOICEVOX を削除しますか？
Delete VOICEVOX?

VOICEVOX をインストールします
Install VOICEVOX

VOICEVOX が入っていません。「かんたんインストール」で入れられます。
VOICEVOX is not installed. You can install it with "Easy Install".

VOICEVOX の最新版を調べられませんでした。インターネットにつながっているか確かめてください。
Could not check the latest VOICEVOX. Check that you are connected to the internet.

この Mac 用の VOICEVOX が見つかりませんでした ({0})。
No VOICEVOX build for this Mac was found ({0}).

公式の配布物 (約 2 GB) をダウンロードして、このアプリ専用の場所に入れます。少し時間がかかります。\n\nVOICEVOX の利用規約と、キャラクターごとの利用規約に同意したうえで使ってください。読み上げた声を公開するときは「VOICEVOX:キャラクター名」と書く必要があります。
Downloads the official package (about 2 GB) into a folder used only by this app. This takes a while.\n\nUse it only after agreeing to the VOICEVOX terms of use and each character's terms. When you publish audio, you must credit it as "VOICEVOX:character name".

利用規約を見る
View Terms of Use

インストール済み ({0})
Installed ({0})

ダウンロード中… {0}%
Downloading… {0}%

展開しています…
Extracting…

このアプリで入れた VOICEVOX (約 2 GB) を消します。読み上げは Mac の声に戻ります。
Deletes the VOICEVOX installed by this app (about 2 GB). Reading aloud goes back to the Mac voices.

展開に失敗しました
Extraction failed

かんたんインストール (約 2 GB)
Easy Install (about 2 GB)

同意してインストール
Agree and Install

配布物の中にエンジンが見つかりませんでした
The engine was not found in the package

OFF
OFF

その他
More

その他 (隠れたボタン)
More (hidden buttons)

ウインドウが狭くて隠れたボタンを、ここから選べます
Choose buttons that are hidden because the window is narrow

隠れているボタンはありません
No hidden buttons

ツールバーをカスタマイズ…
Customize Toolbar…

原稿用紙のマス目の外 (字にかぶらない)
Outside the manuscript grid (does not cover text)

書いている字の横
Next to the text being typed

予測変換の出る場所
Prediction position

日本語入力の予測変換 (打っている途中に出る候補) を出す場所です。出さないようにするには、Mac の「システム設定 > キーボード > 入力ソース > 日本語」で「推測候補表示」を切ります (ほかのアプリでも出なくなります)。
Where the Japanese input method shows its predictions (suggestions while typing). To hide them, turn off "Show predictive candidates" in "System Settings > Keyboard > Input Sources > Japanese" on the Mac (this affects other apps too).

用紙切替
Paper

用紙切替: 標準エディタ → 原稿用紙 → A4用紙
Switch paper: standard editor → manuscript → A4 paper

スクショ
Screenshot

隠れたボタン
Hidden buttons

AIアシスト
AI Assist

原稿用紙 (横書き 400 字詰め)
Manuscript Paper (Horizontal, 400 Characters)

原稿用紙 (横書き)
Manuscript paper (horizontal)

原稿用紙 (縦書き)
Manuscript paper (vertical)

エディタ
Editor

{0} 行 {1} マス
Row {0}, Cell {1}

A4用紙
A4 paper

標準エディタ
Standard editor

Finder で表示
Show in Finder

{0} / {1} 件
{0} / {1}

全 {0} 件
{0} total

メモ {0}
Note {0}

サムネ一覧
Thumbnails

サムネで一覧 (カードで見渡す)
Show as thumbnails (cards)

テキスト一覧
Texts

新しいテキスト
New text

テキストをサムネ (カード) で見渡す (⌥⌘⇧L)
View texts as thumbnails (⌥⌘⇧L)

暗号化された文書
Encrypted document

テキスト一覧を出す / しまう (⌘⇧L)
Show / hide the text list (⌘⇧L)

テキスト一覧を閉じる
Close the text list

題名・本文で絞り込み
Filter by title or text

テキストをサムネで一覧
Show Texts as Thumbnails

すべて
All

新しい名前
New name

フォルダ「{0}」をゴミ箱に入れますか？
Move the folder "{0}" to the Trash?

フォルダに移動
Move to Folder

フォルダの名前
Folder name

新しいフォルダ
New Folder

フォルダの名前を変更
Rename Folder

中のテキストも一緒にゴミ箱に入ります。
The texts inside are moved to the Trash too.

OK
OK

メモ
Notes

ほかの場所
Elsewhere

{0} のコピー {1}
{0} copy {1}

{0} のコピー
{0} copy

「{0}」を削除しますか？
Delete "{0}"?

「{0}」を移す場所を選んでください
Choose where to move "{0}"

削除 (ゴミ箱に入れる)
Delete (Move to Trash)

複製
Duplicate

ロック (書き換え・削除を防ぐ)
Lock (prevent changes and deletion)

ピン固定 (いちばん上に)
Pin (keep at the top)

ここに移動
Move Here

一覧から外す (ファイルは残す)
Remove from List (keep the file)

ロックを外す
Unlock

ピン固定を外す
Unpin

ほかの場所を選ぶ…
Choose Another Location…

ゴミ箱に入れます。ゴミ箱から戻すこともできます。
It is moved to the Trash. You can restore it from the Trash.

{0}：{1}
{0}: {1}

{0} 枚
{0} sheets

印
Marks

中身
Content

場所
Location

字数
Characters

行数
Lines

ロック
Locked

ピン固定
Pinned

作った日
Created

変えた日
Modified

文字コード
Encoding

ファイルの情報…
File Info…

新規フォルダ (選んでいるフォルダの中に作る)
New folder (inside the selected folder)

「{0}」の中に作るフォルダの名前
Name of the folder to create in "{0}"

この中に新規フォルダ…
New Folder Inside…

いちばん上の階層へ出す
Move to Top Level

中のテキストとフォルダも一緒にゴミ箱に入ります。
The texts and folders inside are moved to the Trash too.

更新：{0}
Modified: {0}

種類：{0}
Kind: {0}

{0} ファイル
{0} file

・
, 

たった今
just now

{0} 分前
{0} min ago

{0} 時間前
{0} hr ago

昨日
yesterday

{0} 日前
{0} days ago

星
Star

ハート
Heart

本
Book

えんぴつ
Pencil

学校
School

仕事
Work

家
Home

旅行
Travel

写真
Photos

音楽
Music

葉っぱ
Leaf

アイデア
Ideas

旗
Flag

しおり
Bookmark

トレイ
Tray

人
People

予定
Schedule

買い物
Shopping

あそび
Games

赤
Red

オレンジ
Orange

黄
Yellow

緑
Green

青緑
Teal

青
Blue

ピンク
Pink

茶
Brown

グレー
Gray

アイコン
Icon

1 年
1 year

1 日
1 day

30 日
30 days

7 日
7 days

「{0}」の公開をやめますか？
Stop publishing "{0}"?

公開 (だれでも読める・検索にも出る)
Public (anyone can read; searchable)

公開
Public

期限
Expires

題名
Title

文章をインターネット上に公開して URL を発行します。
Publishes your text on the internet and gives you a URL.

公開する
Publish

期限なし
No expiry

パスワード (4 文字以上)
Password (4+ characters)

公開した日
Published

公開の期限
Expires after

パスワードは 4 文字以上にしてください
Use at least 4 characters for the password

リンクで公開
Publish as Link

公開しました
Published

公開のしかた
Visibility

公開をやめる
Unpublish

ブラウザで開く
Open in Browser

リンクで公開…
Publish as Link…

公開したリンク
Published Links

公開したリンク…
Published Links…

公開できませんでした
Could not publish

リンクをコピーしました。
The link was copied.

リンクを知っている人だけ
Anyone with the link

公開をやめるには「ファイル > 公開したリンク…」から。
To unpublish, use "File > Published Links…".

公開をやめられませんでした
Could not unpublish

パスワードを知っている人だけ
Only people with the password

暗号化した文書は公開できません
Encrypted documents cannot be published

サーバから答えがありませんでした ({0})
No response from the server ({0})

リンクを開いても読めなくなります。
The link will no longer work.

読む人にはパスワードも伝えてください。
Tell readers the password too.

短い時間にたくさん公開したので、少し待ってからもう一度試してください。
You published many items in a short time. Wait a little and try again.

新規テキスト
New Text

作成日時
Created

公開中: {0}
Published: {0}

共有リンク
Share link

期限 {0}
expires {0}
このテキストは公開中です
This text is already published
公開中のページを今の内容に更新できます (リンクはそのまま。前の内容は変更履歴に残ります)。
You can update the published page to the current text (same link; earlier versions stay in the change history).
公開中のページを更新
Update Published Page
公開中のページを更新（変更を反映）
Update Published Page (Apply Changes)
公開してから変更していないので、更新するものはありません。
Nothing has changed since it was published, so there's nothing to update.
新しいリンクで公開…
Publish with a New Link…
更新できませんでした
Couldn't update
このページはもう公開されていません。もう一度公開してください。
This page is no longer published. Please publish it again.
公開中のページを更新しました
Published page updated
前の内容は、ページの「変更履歴」から見られます。
Earlier versions are in the page's change history.
電話番号
Phone number
メールアドレス
Email address
郵便番号
Postal code
住所
Address
カード番号
Card number
マイナンバーらしき番号
Possible My Number (ID number)
名前
Name
やめて見直す
Stop and Review
このまま公開する
Publish Anyway
次からこの確認を出さない
Don't show this check again
個人情報が入っているかもしれません
This may contain personal information
公開すると、リンクを知った人が読めるようになります。このまま公開してよいですか？
Once published, anyone with the link can read it. Publish anyway?
公開
Publish
公開中ページ表示
Show Published Page
公開中ページ表示（id:{0}）
Show Published Page (id: {0})
公開中のリンクをコピー
Copy Published Link
公開をやめる…
Unpublish…
公開する前に個人情報を確認する
Check for Personal Info Before Publishing
(今までの変更履歴は消しました)
(the earlier change history was deleted)
変更履歴: 残す
Change history: kept
変更履歴: 残さない
Change history: not kept
変更履歴を残す (更新したとき、前の内容もページから見られる)
Keep change history (earlier versions stay viewable on the page after updates)
今ある変更履歴を消す
Delete the existing change history
日時を指定…
Pick a Date…
上下 / 左右に並べ替える
Stack vertically / side by side
Mac の設定の声 ({0})
Mac's System Voice ({0})
用紙 (クリックで切り替え)
Paper (click to switch)
切り替えの候補
Switch Choices
用紙モードの設定…
Paper Mode Settings…
テキスト管理の設定…
Text Management Settings…
サーバの設定…
Server Settings…
データ暗号化の設定…
Data Encryption Settings…
リンクで公開共有の設定…
Share via Link Settings…
アップデートを確認…
Check for Updates…
公開中のページにも反映しますか？
Update the published page too?
このテキストはリンクで公開中です。保存した内容を、公開中のページにも反映できます。
This text is published by link. You can apply what you saved to the published page too.
反映する
Update Page
今はしない
Not Now
「みんなのメモ」に掲載 OK (サイトの一覧に載ります)
OK to list in “Everyone's Memos” (shown on the site)
ファイルの名前を変更
Rename File
元のファイルの名前を変えます (中身はそのまま)。
Renames the original file (its contents stay the same).
「{0}」はもうあります
“{0}” already exists
ほかの名前にしてください。
Please choose another name.
ロックしているので名前を変えられません
This file is locked, so it can't be renamed
今日まで
Until End of Today
明日まで
Until End of Tomorrow
3 日
3 days
期間を指定…
Set a Duration…
期日を指定…
Set an End Date…
期間: {0}
Duration: {0}
期日: {0} まで
Until {0}
日
days
時間
hours
分
min
秒
sec
0 秒
0 sec
公開の期間
Publishing Duration
公開してから、どれだけのあいだ読めるようにするかを決めます。
Choose how long the page stays readable after publishing.
期間は 10 秒以上にしてください
Make the duration at least 10 seconds
公開の期日
Publishing End Date
この日時まで読めるようにします。
The page stays readable until this date and time.
時刻
Time
今より後の日時を選んでください
Choose a date and time in the future
「左上のボタン」で新規フォルダ
New folder with the 「button at the top left」
「左上のボタン」で新規ファイル
New file with the 「button at the top left」
公開共有中
Shared by Link
履歴から消す
Remove from history
この履歴を消す (フォルダそのものは消しません)
Remove from this list (the folder itself is not deleted)
読み込み中…
Loading…
フォルダの欄の基準にする、この Mac の中のフォルダを選んでください
Choose a folder on this Mac to use as the base of the folder list
一覧に出す、この Mac の中のフォルダを選んでください (中のテキストが出ます)
Choose a folder on this Mac to show in the list (its texts will appear)
iCloud Drive の中のフォルダは選べません
Folders in iCloud Drive can't be chosen
この Mac の中のフォルダを選んでください。iCloud のテキストは、▾ ボタンの「iCloud」で見られます。
Choose a folder on this Mac. To see iCloud texts, pick “iCloud” from the ▾ button.
任意フォルダ…
Any Folder…
見るテキストの置き場所: iCloud (iPhone 版と同じ)・この Mac・好きなフォルダ
Where to see texts from: iCloud (same as iPhone), this Mac, or any folder
見つかりませんでした
Nothing found
このフォルダには、まだテキストがありません
This folder has no texts yet
左上のボタンで新しく作れます
Use the button at the top left to create one
まだテキストがありません
No texts yet
この公開をやめる鍵が合いませんでした。
The key to stop this publication did not match.
ページはまだ公開されたままです。
The page is still published.
新しく作りました
Newly created
{0} 個のフォルダ
{0} folders
下のテキストは「{0}」の中のものです
The texts below are in “{0}”
「{0}」の中に作る
Inside “{0}”
別のフォルダとして、いちばん上に作る
As a separate folder at the top level
ほかの場所のフォルダを開く…
Open a Folder from Elsewhere…
ゴミ箱 (選んだテキストを削除。ファイルやフォルダをここに置いても削除できます)
Trash (deletes the selected texts. You can also drop files or folders here to delete them)
版の履歴
Version History
iCloud に置くと、iPhone / iPad のさとるエディタでも同じテキストが使えます。
Store texts in iCloud to use the same texts in Satoru Editor on your iPhone / iPad.
保存するたびに版を残します。テキスト一覧の右クリックから、前の版を見たり戻したりできます。
Keeps a version each time you save. Right-click a text in the list to view or restore earlier versions.
戻しても、今あるファイルは消えません。パスワードを忘れると開けないので注意。
Restoring never deletes existing files. If you forget the password, the backup can't be opened.
テキスト・フォルダ・版の履歴などが、まるごと入ります。
Includes texts, folders, version history and more.
テキストを、パスワード付きの 1 つのファイルにまとめて保存します。別の Mac にも戻せます。
Saves all your texts into one password-protected file. You can restore it on another Mac too.
この Mac
This Mac
ローカル
Local
どちらに置いたテキストを見るか (iCloud は iPhone 版と同じ)
Which texts to show (iCloud is shared with the iPhone app)
Finder で開く
Open in Finder
iCloud Drive に置く
Store in iCloud Drive
iCloud Drive に置く…
Store in iCloud Drive…
iCloud Drive が使える Mac では、はじめから iCloud Drive の「さとるエディタ」に置きます。同じ Apple ID の iPhone / iPad のさとるエディタでも、同じテキストを読んだり書いたりできます。
On a Mac with iCloud Drive, texts are stored in “さとるエディタ” in iCloud Drive from the start. Satoru Editor on an iPhone / iPad with the same Apple ID can read and write the same texts.
iCloud Drive の「さとるエディタ」フォルダのテキストを、この Mac の書類フォルダに写して、これからはそこに保存します。iCloud Drive のファイルは消しません。
Copies the texts in the “さとるエディタ” folder in iCloud Drive to this Mac's Documents folder and saves there from now on. Files in iCloud Drive are not deleted.
{0} 個のファイルを写しました。
Copied {0} files.
この Mac では iCloud Drive がオフです (システム設定 > Apple ID > iCloud で iCloud Drive をオンにしてください)。
iCloud Drive is off on this Mac (turn it on in System Settings > Apple ID > iCloud).
この Mac に戻す
Move Back to This Mac
この Mac に戻す…
Move Back to This Mac…
テキストを iCloud Drive に置きますか？
Store your texts in iCloud Drive?
テキストをこの Mac に戻しますか？
Move your texts back to this Mac?
今のテキストを iCloud Drive の「さとるエディタ」フォルダに写して、これからはそこに保存します。この Mac の書類フォルダのファイルは消しません。
Copies your current texts to the “さとるエディタ” folder in iCloud Drive and saves there from now on. Files in this Mac's Documents folder are not deleted.
いまの置き場所: iCloud Drive の「さとるエディタ」
Current location: “さとるエディタ” in iCloud Drive
いまの置き場所: この Mac の書類フォルダ
Current location: this Mac's Documents folder
テキストの置き場所 (iCloud)
Where Texts Are Stored (iCloud)
置き場所を変えました
Storage location changed
置き場所を変えられませんでした
Couldn't change the storage location
置き場所を変えると、今のテキストを新しい場所に写します。前の場所のファイルは消しません。版の記録はこの Mac の中のままです。
Changing the location copies your current texts to the new place. Files in the old place are not deleted. Version history stays on this Mac.
アップデートを自動で確認
Automatically Check for Updates
この版ではアップデートを確認できません
This build can't check for updates
配布用のアプリ (ダウンロードした DMG から入れたもの) で使えます。
Available in the release app (installed from the downloaded DMG).
ツールバーの用紙切替のボタンで、チェックしたものを順に切り替えます。
The paper switch button in the toolbar cycles through the checked items.
テキストを探す
Find a text
この中に新しいテキスト
New Text Here
AI アシスト
AI Assist
AI アシストを開く
Open AI Assist
リンクで公開共有
Share via Link
リンクで公開共有…
Share via Link…
フォルダを開く
Open Folder
好きな場所のフォルダを開いて、中のテキストを一覧に出す
Open a folder anywhere and list its texts
一覧から外す (フォルダは消さない)
Remove from List (folder is kept)
一覧に出すフォルダを選んでください (中のテキストが出ます)
Choose a folder to show in the list (its texts will appear)
題名 (なくてもかまいません)
Title (optional)
履歴：まだありません
History: none yet
履歴：{0} 個 (最新 {1})
History: {0} versions (latest {1})
クリア
Clear
一覧から {0} 件を外します。ファイルそのものは消しません。さとるエディタのフォルダの中のテキストはそのままです。
Removes {0} items from the list. The files themselves are not deleted. Texts in the SatoruEditor folder stay.
すべて消す
Delete All
履歴の操作
History Actions
サムネで一覧
Thumbnail View
保存フォルダを Finder で開く
Show Save Folder in Finder
版の履歴をすべて消す…
Delete All Version History…
版の履歴をすべて消しますか？
Delete all version history?
「ほかの場所」の履歴をクリア…
Clear "Other Places" from History…
版の履歴・バックアップの設定…
Version History & Backup Settings…
「ほかの場所」の履歴をクリアしますか？
Clear "Other Places" from the history?
すべてのテキストの、前の版の記録を消します。テキストそのものは消しません。元に戻せません。
Deletes the earlier-version records of every text. The texts themselves stay. This can't be undone.
テキスト管理 (テキスト一覧、履歴)
Text Management (Text List, History)
左にフォルダとテキストの一覧 (履歴) を出し、サムネで見わたせます。書いたものは自動で保存され、テキストごとに版の履歴も残ります。
Shows folders and your texts (history) on the left, with a thumbnail view. Writing is saved automatically, and each text keeps its version history.
テキスト一覧 (履歴管理)
Text List (History)
左にフォルダとテキストの一覧 (履歴) を出します。書いたものは自動で保存され、更新した順に並びます。
Shows folders and your texts (history) on the left. Writing is saved automatically and listed by update time.
書く
Write
自動で保存
Saved automatically
一覧に並ぶ
Listed
すぐ
Right away
更新順
By update
版の履歴 (バージョン管理)
Version History
保存のたびに、テキストごとの版を残します。前の版を見たり、違いを見たり、戻したりできます。
Keeps a version of each text every time it's saved. View, compare, or restore earlier versions.
版が残る
Versions kept
前の版に戻す
Restore an earlier version
そのたびに
Every time
いつでも
Anytime
URL を送る
Send the URL
テキストを docs.satoru.net に置いて、リンクで読めるようにします。公開・リンクだけ・パスワードを選べます。
Puts your text on docs.satoru.net so it can be read via a link. Choose public, link-only, or password.
リンクで読める
Readable via link
用紙切替 (原稿用紙・A4用紙)
Paper Switching (Manuscript · A4)
データ暗号化
Data Encryption
データ暗号化をオンにします
Turning on data encryption
テキストごとに残す版の数
Versions kept per text
(それより古い版は消えます)
(older versions are deleted)
{0} 個まで
Up to {0}
残す版を {0} 個までにしますか？
Keep only {0} versions?
今ある履歴も、テキストごとに新しい {0} 個だけ残して、それより古い版は消します。元に戻せません。
Existing history will also be trimmed to the newest {0} versions per text. This can't be undone.
減らす
Reduce
版：まだありません
Versions: none yet
版：{0} 個 (最新 {1})
Versions: {0} (latest {1})
ほか {0} 個…
{0} more…
版の履歴も入れる
Include version history
Word 風
Word Style
大きすぎて比べられません
Too large to compare
赤の取り消し線 = この版から消した所 ・ 青の下線 = 足した所
Red strikethrough = removed since this version · blue underline = added
{0} 個のフォルダを選んでいます
{0} folders selected
いちばん上の階層へ出す ({0} 個)
Move to Top Level ({0})
{0} 個のフォルダをゴミ箱に入れる…
Move {0} Folders to Trash…
{0} 個のフォルダをゴミ箱に入れますか？
Move {0} folders to the Trash?
開いたときの中身: {0}
As opened: {0}
{0} 件を削除…
Delete {0} Items…
{0} 件を選んでいます
{0} items selected
{0} 件のテキストを削除しますか？
Delete {0} texts?
ロックしている {0} 件は削除しません。
{0} locked items will not be deleted.
ロックしているので削除できません
It's locked, so it can't be deleted
右クリックの「ロックを外す」で外してから削除してください。
Unlock it from the right-click menu first, then delete it.
Mac の「コマンドライン・デベロッパ・ツール」を入れると使えます (無料)。「入れる」を押すと、Mac の入れる画面が開きます。
Install the Mac's free Command Line Developer Tools to use it. "Install" opens the Mac installer.
git が見つかりません。Mac の「コマンドライン・デベロッパ・ツール」を入れると使えます。
git was not found. Install the Mac's Command Line Developer Tools to use this.
… {0} 行 同じ …
… {0} unchanged lines …
保存: {0}
Saved: {0}
この版
This Version
版の記録 (git)
Version History (git)
版の履歴: {0}
Version History: {0}
今のほうが +{0} 行 / −{1} 行
Current: +{0} / −{1} lines
記録はこの Mac の中 (~/.satoruEditor/history) に、テキストごとの git で置きます。あなたのフォルダには何も作りません。Finder で動かしたり名前を変えたりしても履歴はついていき、テキストを削除すると履歴も消えます。暗号化した文書は記録しません。
Versions are kept on this Mac, one git repository per text (~/.satoruEditor/history). Nothing is added to your folders. History follows a text even when moved or renamed in Finder, and is erased when the text is deleted. Encrypted documents are not recorded.
今との違い
Changes Since
版の履歴…
Version History…
記録の場所を Finder で開く
Show in Finder
版の記録には git が要ります
Version history needs git
この版に戻す
Restore This Version
保存した日時
Saved
この版をコピー
Copy This Version
いちばん新しい版
Latest
名前・場所の変更: {0}
Renamed or moved: {0}
まだ版がありません
No versions yet
今の内容と同じです
Same as the current text
保存すると、ここに残ります
Versions appear here when you save
保存のたびに、テキストごとの版を残す
Keep a version of each text every time it's saved
保存するたびに、そのテキストの中身を記録します (自動保存が続くあいだは 20 秒ごとに 1 つにまとめます。⌘S で保存したときは、すぐ記録します)。ファイル > 版の履歴… や、テキスト一覧の右クリックから、前の版を見たり、今との違いを見たり、戻したりできます。
Each save records the text (continuous autosaves are grouped every 20 seconds; ⌘S records right away). Use File > Version History… or right-click a text in the list to view earlier versions, compare them with now, or restore one.
入るもの: さとるエディタのフォルダのファイルすべて (フォルダの形のまま)、一覧に出ている「ほかの場所」のテキスト、表示 (作文など)・ピン・ロック・日時、版の履歴、フォルダのアイコンと並び、公開したリンクの記録。
Included: every file in the SatoruEditor folder (with its folders), texts from other places shown in the list, display mode (manuscript etc.), pins, locks, dates, version history, folder icons and order, and published-link records.
戻すときは、今あるファイルは消しません。同じ名前で中身が違うものは「(バックアップ)」を付けて別に置きます。パスワードを忘れると、このバックアップは開けません。
Restoring never deletes existing files; a file with the same name but different content is saved alongside with "(backup)". If you forget the password, the backup can't be opened.
テキストのバックアップ
Text Backup
(バックアップ {0})
(backup {0})
(バックアップ)
(backup)
2 つのパスワードが違います
The two passwords don't match
{0} に作ったバックアップ: テキスト {1} 件・フォルダ {2} 個
Backup made {0}: {1} texts, {2} folders
{0} 件のテキストを、パスワードで鍵をかけて保存しました ({1})。
Saved {0} texts, locked with your password ({1}).
戻す
Restore
書き出す…
Export…
パスワードは 8 文字以上にしてください
Use at least 8 characters for the password
バックアップ
Backup
新しく戻したもの {0} 件 ・ 同じだったので飛ばしたもの {1} 件 ・ 名前を変えて戻したもの {2} 件
Restored {0} new · skipped {1} identical · restored {2} under a new name
戻せなかったもの {0} 件
{0} could not be restored
読み込むバックアップ (.satorubackup) を選んでください
Choose a backup (.satorubackup) to restore
バックアップから戻す (読み込む)…
Restore from Backup (Import)…
パスワードが違います
Wrong password
読み込めませんでした
Couldn't open it
テキストをバックアップ (書き出す)…
Back Up Texts (Export)…
テキストをバックアップ
Back Up Texts
ほかの場所から戻したもの
Restored from other places
バックアップのパスワード
Backup password
バックアップから戻しました
Restored from the backup
公開したリンクの記録も入れる (更新・公開をやめるための合言葉も)
Include published-link records (with the tokens to update or unpublish)
さとるエディタのバックアップ
SatoruEditor Backup
バックアップから戻しますか？
Restore from this backup?
バックアップを作っています…
Creating the backup…
バックアップを書き出しました
Backup exported
バックアップを書き出せませんでした
Couldn't export the backup
さとるエディタのバックアップではありません
This isn't a SatoruEditor backup
テキスト一覧のファイルを、パスワードで鍵をかけた 1 つのファイルに書き出します。読み込むと、別の Mac にも戻せます。
Exports your text library into one file locked with a password. You can restore it on another Mac.
パスワードを忘れると、このバックアップは開けません。
If you forget the password, this backup can't be opened.
新しい版のさとるエディタで作ったバックアップです。アプリを新しくしてください
This backup was made by a newer SatoruEditor. Please update the app
さとるエディタのフォルダに戻します。今あるファイルは消しません。同じ名前で中身が違うものは「(バックアップ)」を付けて別に置きます。
Restores into the SatoruEditor folder. Existing files are kept; a file with the same name but different content is saved alongside with "(backup)".
変えない ({0} まで)
Keep (until {0})
変えない (期限なし)
Keep (no expiry)
変更する
Change
公開の設定
Publishing Settings
公開の設定…
Publishing Settings…
公開の設定を変えました
Publishing settings changed
変えないときは空のまま
Leave empty to keep
設定を変えられませんでした
Couldn't change the settings
公開をやめる・設定を変えるには、メニューの「公開」から。
To unpublish or change settings, use the Publish menu.
"""#
}
