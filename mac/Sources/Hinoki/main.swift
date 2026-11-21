import AppKit
import HinokiCore

// SSH 接続の手伝い役として呼ばれたときは、画面を出さずに仕事だけして終わる (RemoteClient.swift 参照)
RemoteHelper.runIfNeeded()

// 識別子を net.satoru.satoruEditor に変えたので、前の設定を 1 回だけ引き継ぐ (設定ファイルの置き場所も)
SettingsMigration.run()
AppPaths.migrate()
// 設定の初期値は、メニューを作る前に入れておく (初めて起動したとき、初めからオンの機能のメニューが出るように)
UserDefaults.standard.register(defaults: Prefs.defaults)
// 見えなくした機能 (共同編集) は、前にオンにしていてもオフにする
for e in EditorExtension.hidden { UserDefaults.standard.set(false, forKey: e.prefKey) }

// 画面に出す言葉 (日本語 / 英語) を決める。メニューを作る前に済ませる
AppLanguage.setUp()

let app = NSApplication.shared
_ = DocumentController() // 最初に作ったものが NSDocumentController.shared になる
let delegate = AppDelegate()
app.delegate = delegate
app.mainMenu = MainMenu.build()
MenuCustomizer.setUp(app.mainMenu!) // キー割り当て・メニュー編集・拡張機能のオンオフを反映
app.setActivationPolicy(.regular)
app.run()
