import AppKit
import HinokiCore

/// 画面に出す言葉 (日本語 / 英語) の切り替え。
/// 設定 "language" は auto (macOS の言語に合わせる) / ja / en。言葉そのものは HinokiCore の I18n と L() が受け持つ。
/// メニューやウインドウは起動のときに作るので、切り替えは次に起動したときから効く。
enum AppLanguage {
    static let prefKey = "language"

    /// 設定に入れられる値と、画面に出す名前 (名前は、どちらの言語の人にも読めるよう訳さない)
    static let choices: [(id: String, label: String)] = [
        ("auto", "自動 (macOS の言語に合わせる)"),
        ("ja", "日本語"),
        ("en", "English"),
    ]

    static var setting: String {
        let v = UserDefaults.standard.string(forKey: prefKey) ?? "auto"
        return I18n.settings.contains(v) ? v : "auto"
    }

    /// macOS の言語の並び (このアプリだけの上書きは見ない)
    static var systemLanguages: [String] {
        (UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String])
            ?? Locale.preferredLanguages
    }

    /// 起動のいちばん最初に呼ぶ (メニューを作る前)
    static func setUp() {
        I18n.setLanguage(I18n.resolve(setting: setting, systemLanguages: systemLanguages))
        syncSystemPanels()
    }

    /// 保存・印刷の画面など macOS が出す部品の言葉も、選んだ言語に合わせる (次の起動から効く)
    private static func syncSystemPanels() {
        let d = UserDefaults.standard
        if setting == "auto" {
            d.removeObject(forKey: "AppleLanguages")
        } else {
            d.set([setting], forKey: "AppleLanguages")
        }
    }

    /// 言語を選び直す。いま出ている画面は変えられないので、起動し直すかを聞く
    static func change(to id: String) {
        guard I18n.settings.contains(id), id != setting else { return }
        UserDefaults.standard.set(id, forKey: prefKey)
        syncSystemPanels()
        NotificationCenter.default.post(name: .viewSettingsDidChange, object: nil)
        let next = I18n.resolve(setting: id, systemLanguages: systemLanguages)
        guard next != I18n.language else { return } // 見た目は変わらない (自動 ⇔ 同じ言語)
        let alert = NSAlert()
        // これから使う言語の人が読めるように、両方の言葉で書く
        alert.messageText = "表示の言語は、次に起動したときから変わります。\nThe display language changes the next time you start the app."
        alert.addButton(withTitle: "今すぐ起動し直す (Restart Now)")
        alert.addButton(withTitle: "あとで (Later)")
        if alert.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    /// 終了したあとで、同じアプリをもう一度開く。保存していない文書があれば、いつもどおり終了の前に聞かれる
    static func relaunch() {
        let bundle = Bundle.main.bundlePath
        guard bundle.hasSuffix(".app") else { NSApp.terminate(nil); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // このアプリが終わるのを待ってから開く (終了をやめたときは、あとで終了したときに開く)
        p.arguments = ["-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; open \"$1\"",
                       String(ProcessInfo.processInfo.processIdentifier), bundle]
        try? p.run()
        NSApp.terminate(nil)
    }
}
