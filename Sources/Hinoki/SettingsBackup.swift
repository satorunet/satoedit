import AppKit
import UniformTypeIdentifiers
import HinokiCore

/// 設定内容の保存・復元 (秀丸の「設定内容の保存/復元」にあたる)。
/// 動作環境・キー割り当て・メニュー編集・色とフォント・ファイルタイプ別の設定を 1 つの JSON ファイルにまとめる。
enum SettingsBackup {
    static let formatName = "さとるエディタ設定"
    static let formatVersion = 1

    // MARK: 書き出し

    static func exportSettings() {
        let panel = NSSavePanel()
        panel.title = "設定内容の保存"
        panel.message = "動作環境・ファイルタイプ別の設定・色とフォント・キー割り当て・メニュー編集をまとめて保存します"
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        panel.nameFieldStringValue = "さとるエディタ設定_\(f.string(from: Date())).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try makeBundle().write(to: url, options: .atomic)
        } catch {
            NSApp.presentError(error)
        }
    }

    static func makeBundle() throws -> Data {
        let d = UserDefaults.standard
        var prefs: [String: Any] = [:]
        for key in Prefs.defaults.keys {
            if let v = d.object(forKey: key) { prefs[key] = v }
        }
        var root: [String: Any] = [
            "_形式": formatName,
            "_版": formatVersion,
            "動作環境": prefs,
            "キー割り当て": MenuCustomizer.overrides.mapValues { ["key": $0.key, "mods": $0.mods] },
            "隠したメニュー": Array(MenuCustomizer.hidden).sorted(),
        ]
        // 色・フォントとファイルタイプ別の設定はファイルの中身をそのまま入れる
        Theme.save()
        if let data = try? Data(contentsOf: Theme.userFileURL),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            root["色・フォント"] = obj
        }
        if let data = try? Data(contentsOf: ProfileStore.userFileURL),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            root["ファイルタイプ別の設定"] = obj
        } else {
            root["ファイルタイプ別の設定"] = []
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: 読み込み

    static func importSettings() {
        let panel = NSOpenPanel()
        panel.title = "設定内容の復元"
        panel.message = "保存しておいた設定ファイルを選んでください"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let alert = NSAlert()
        alert.messageText = "設定を復元しますか？"
        alert.informativeText = "いまの設定は置き換わります。"
        alert.addButton(withTitle: "復元する")
        alert.addButton(withTitle: "いまの設定を保存してから復元")
        alert.addButton(withTitle: "やめる")
        switch alert.runModal() {
        case .alertFirstButtonReturn: break
        case .alertSecondButtonReturn: exportSettings()
        default: return
        }
        do {
            try restore(from: try Data(contentsOf: url))
        } catch {
            NSApp.presentError(error)
        }
    }

    static func restore(from data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = root["_形式"] as? String, kind == formatName || kind == "さと丸エディタ設定" else {
            throw NSError(domain: "Satomaru", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "さとるエディタの設定ファイルではありません",
            ])
        }
        let d = UserDefaults.standard
        let fm = FileManager.default
        try fm.createDirectory(at: Theme.userFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let prefs = root["動作環境"] as? [String: Any] {
            for key in Prefs.defaults.keys {
                if let v = prefs[key] { d.set(v, forKey: key) } else { d.removeObject(forKey: key) }
            }
        }
        if let keys = root["キー割り当て"] as? [String: [String: Any]] {
            var o: [String: MenuCustomizer.Shortcut] = [:]
            for (id, v) in keys {
                if let k = v["key"] as? String, let m = v["mods"] as? NSNumber {
                    o[id] = MenuCustomizer.Shortcut(key: k, mods: m.uintValue)
                }
            }
            MenuCustomizer.overrides = o
        }
        if let hidden = root["隠したメニュー"] as? [String] {
            MenuCustomizer.hidden = Set(hidden)
        }
        if let theme = root["色・フォント"] {
            let data = try JSONSerialization.data(withJSONObject: theme, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: Theme.userFileURL, options: .atomic)
            Theme.reload()
            Theme.save() // 説明つきの見やすい形に書き直す
        }
        if let profiles = root["ファイルタイプ別の設定"] {
            let data = try JSONSerialization.data(withJSONObject: profiles, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: ProfileStore.userFileURL, options: .atomic)
            Profiles.reload()
        }
        NotificationCenter.default.post(name: .viewSettingsDidChange, object: nil)
        SettingsWindowController.shared.refreshPanes()
    }

    // MARK: 初期化

    static func resetAll() {
        let alert = NSAlert()
        alert.messageText = "すべての設定を最初の状態に戻しますか？"
        alert.informativeText = "すべての設定が最初の状態に戻ります。"
        alert.addButton(withTitle: "初期状態に戻す")
        alert.addButton(withTitle: "いまの設定を保存してから戻す")
        alert.addButton(withTitle: "やめる")
        switch alert.runModal() {
        case .alertFirstButtonReturn: break
        case .alertSecondButtonReturn: exportSettings()
        default: return
        }
        let d = UserDefaults.standard
        Prefs.defaults.keys.forEach { d.removeObject(forKey: $0) }
        MenuCustomizer.overrides = [:]
        MenuCustomizer.hidden = []
        try? FileManager.default.removeItem(at: Theme.userFileURL)
        Theme.reload()
        try? FileManager.default.removeItem(at: ProfileStore.userFileURL)
        Profiles.reload()
        NotificationCenter.default.post(name: .viewSettingsDidChange, object: nil)
        SettingsWindowController.shared.refreshPanes()
    }
}
