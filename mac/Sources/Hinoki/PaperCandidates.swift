import AppKit
import HinokiCore

/// ツールバーの「用紙切替」ボタンやメニューに出す候補 (設定 > 用紙モード で選ぶ)
enum PaperCandidates {
    /// 並びはボタンで切り替わる順
    static let all: [(id: String, label: String)] = [
        ("normal", "標準エディタ"), ("genkoV", "原稿用紙 (縦書き)"), ("genkoH", "原稿用紙 (横書き)"), ("a4", "A4用紙"),
    ]
    private static let key = "paperCandidates"

    /// 出す候補 (はじめは全部。1 つも無いときは標準エディタだけ)
    static var enabled: [String] {
        let ids = all.map(\.id)
        guard let saved = UserDefaults.standard.stringArray(forKey: key) else { return ids }
        let list = ids.filter { saved.contains($0) }
        return list.isEmpty ? ["normal"] : list
    }
    static func isOn(_ id: String) -> Bool { enabled.contains(id) }
    static func set(_ id: String, on: Bool) {
        var s = Set(enabled)
        if on { s.insert(id) } else { s.remove(id) }
        UserDefaults.standard.set(all.map(\.id).filter { s.contains($0) }, forKey: key)
        NotificationCenter.default.post(name: .viewSettingsDidChange, object: nil)
    }
    /// メニューの tag (0 標準 / 1 縦書き / 2 A4 / 3 横書き)
    static func id(forTag tag: Int) -> String? {
        switch tag { case 0: return "normal"; case 1: return "genkoV"; case 2: return "a4"; case 3: return "genkoH"; default: return nil }
    }
}

extension EditorWindowController {
    /// いまの用紙 (候補の id)
    var currentPaperID: String {
        switch paperMode {
        case .genko: return horizontalGenko ? "genkoH" : "genkoV"
        case .a4: return "a4"
        case .normal: return "normal"
        }
    }

    /// 候補の id の用紙にする
    func applyPaperID(_ id: String) {
        switch id {
        case "genkoV", "genkoH":
            setGenkoHorizontal(id == "genkoH", remember: true)
            if paperMode != .genko { applyPaperMode(.genko) }
        case "a4": applyPaperMode(.a4)
        default: applyPaperMode(.normal)
        }
        updateStatus()
    }
}
