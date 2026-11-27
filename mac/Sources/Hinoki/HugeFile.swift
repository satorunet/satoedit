import AppKit
import HinokiCore

/// 巨大なファイルを開くときの聞き方と、その設定
enum HugeFile {
    /// これ以上の大きさのファイルは、全部は読まずに見ている所の近くだけを読む (MB。HugeFileWindow)。0 なら全部読む
    static var thresholdMB: Int {
        let v = UserDefaults.standard.integer(forKey: "hugeFileMB")
        return v < 0 ? 0 : v
    }
    /// 一部分だけ読み込むときの、はじめの大きさ (MB)
    static var partMB: Int { max(1, UserDefaults.standard.integer(forKey: "hugePartMB")) }

    static func sizeText(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.1f MB", mb)
    }

    enum Choice {
        case whole
        case part(offset: UInt64, length: UInt64)
        case cancel
    }

    /// 巨大なファイルを開く前に聞く。current があれば、その範囲をはじめの値にする (範囲の変更用)
    static func ask(name: String, size: UInt64, current: PartialFile.Part? = nil) -> Choice {
        let alert = NSAlert()
        alert.messageText = L("「{0}」は {1} あります", name, sizeText(size))
        alert.informativeText = L("全部読み込むと、開くのに時間がかかり、メモリもたくさん使います。\n一部分だけ読み込めば、すぐに開けます。書き換えて保存すると、その部分だけがファイルに反映されます。")
        let totalMB = Int((size + 1_048_575) / 1_048_576)
        let from = NSTextField(string: "\(current.map { Int($0.offset / 1_048_576) } ?? 0)")
        let len = NSTextField(string: "\(current.map { max(1, Int(($0.length + 1_048_575) / 1_048_576)) } ?? min(partMB, totalMB))")
        for f in [from, len] {
            f.alignment = .right
            f.widthAnchor.constraint(equalToConstant: 70).isActive = true
        }
        let row = NSStackView(views: [NSTextField(labelWithString: L("先頭から")), from,
                                      NSTextField(labelWithString: L("MB の位置から")), len,
                                      NSTextField(labelWithString: L("MB 分"))])
        row.spacing = 6
        let note = NSTextField(labelWithString: L("全体は {0} MB です。行の途中では切らず、行の切れ目に合わせます。", totalMB))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let box = NSStackView(views: [row, note])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 6
        box.frame = NSRect(x: 0, y: 0, width: 420, height: 50)
        alert.accessoryView = box
        alert.addButton(withTitle: L("一部分だけ読み込む"))
        alert.addButton(withTitle: L("全部読み込む"))
        alert.addButton(withTitle: L("キャンセル"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let o = UInt64(max(0, from.integerValue)) * 1_048_576
            let l = UInt64(max(1, len.integerValue)) * 1_048_576
            return .part(offset: min(o, size), length: l)
        case .alertSecondButtonReturn:
            return .whole
        default:
            return .cancel
        }
    }
}
