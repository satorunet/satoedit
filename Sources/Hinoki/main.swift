import AppKit

// SSH 接続の手伝い役として呼ばれたときは、画面を出さずに仕事だけして終わる (RemoteClient.swift 参照)
RemoteHelper.runIfNeeded()

let app = NSApplication.shared
_ = DocumentController() // 最初に作ったものが NSDocumentController.shared になる
let delegate = AppDelegate()
app.delegate = delegate
app.mainMenu = MainMenu.build()
MenuCustomizer.setUp(app.mainMenu!) // キー割り当て・メニュー編集・拡張機能のオンオフを反映
app.setActivationPolicy(.regular)
app.run()
