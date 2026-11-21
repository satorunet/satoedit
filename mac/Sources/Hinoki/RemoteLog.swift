import AppKit
import HinokiCore

/// サーバとのやりとりの記録 (接続・一覧・受信・送信・失敗など)。サーバツリーの下のログ欄に出す
enum RemoteLog {
    enum Level { case info, success, failure }

    struct Entry {
        let time: Date
        let level: Level
        let text: String
    }

    static let didAdd = Notification.Name("RemoteLogDidAdd")
    private(set) static var entries: [Entry] = []
    private static let maxEntries = 500

    /// 記録する (どのスレッドからでもよい。画面には main で知らせる)
    static func add(_ text: String, _ level: Level = .info) {
        let e = Entry(time: Date(), level: level, text: text)
        let post = {
            entries.append(e)
            if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
            NotificationCenter.default.post(name: didAdd, object: nil, userInfo: ["entry": e])
        }
        Thread.isMainThread ? post() : DispatchQueue.main.async(execute: post)
    }

    static func clear() {
        entries = []
        NotificationCenter.default.post(name: didAdd, object: nil)
    }

    static func line(_ e: Entry) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let mark: String
        switch e.level {
        case .info: mark = "•"
        case .success: mark = "✓"
        case .failure: mark = "✗"
        }
        return "\(f.string(from: e.time)) \(mark) \(e.text)"
    }

    static func seconds(since start: Date) -> String {
        String(format: "%.1f", Date().timeIntervalSince(start))
    }
}

/// ログ欄: 新しい行が下に増え、いちばん下を見ていれば自動で追いかける
final class RemoteLogView: NSView {
    private let textView = NSTextView()
    private let scroll = NSScrollView()

    init() {
        super.init(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 3)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel(L("サーバのログ"))
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // ログ欄はいつも暗い色 (端末のような見た目)。文字の色も暗い表示用になる
        scroll.appearance = NSAppearance(named: .darkAqua)
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(srgbRed: 0x1C / 255, green: 0x1E / 255, blue: 0x24 / 255, alpha: 1)
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 4
        textView.insertionPointColor = .white

        let title = NSTextField(labelWithString: L("ログ"))
        title.font = .boldSystemFont(ofSize: 10)
        title.textColor = .secondaryLabelColor
        let copy = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: L("ログをコピー")) ?? NSImage(),
                            target: self, action: #selector(copyAll(_:)))
        let clear = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: L("ログを消す")) ?? NSImage(),
                             target: self, action: #selector(clearAll(_:)))
        for (b, tip) in [(copy, L("ログをコピー")), (clear, L("ログを消す"))] {
            b.isBordered = false
            b.toolTip = tip
            b.imageScaling = .scaleProportionallyDown
            b.widthAnchor.constraint(equalToConstant: 14).isActive = true
            b.heightAnchor.constraint(equalToConstant: 14).isActive = true
        }
        let header = NSStackView(views: [title, NSView(), copy, clear])
        header.spacing = 6

        for v in [header, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(added(_:)), name: RemoteLog.didAdd, object: nil)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func attributed(_ e: RemoteLog.Entry) -> NSAttributedString {
        let color: NSColor
        switch e.level {
        case .info: color = NSColor(white: 0.82, alpha: 1)
        case .success: color = RemoteDocuments.green
        case .failure: color = RemoteDocuments.red
        }
        return NSAttributedString(string: RemoteLog.line(e) + "\n", attributes: [
            .font: textView.font ?? NSFont.systemFont(ofSize: 10), .foregroundColor: color])
    }

    private func rebuild() {
        let s = NSMutableAttributedString()
        RemoteLog.entries.forEach { s.append(attributed($0)) }
        textView.textStorage?.setAttributedString(s)
        textView.scrollToEndOfDocument(nil)
    }

    @objc private func added(_ n: Notification) {
        guard let e = n.userInfo?["entry"] as? RemoteLog.Entry else { return rebuild() }
        // いちばん下を見ているときだけ追いかける (上を読んでいるときは動かさない)
        let clip = scroll.contentView
        let atBottom = clip.bounds.maxY >= textView.frame.maxY - 4
        textView.textStorage?.append(attributed(e))
        // 古い行を切り詰める
        if let ts = textView.textStorage, ts.length > 200_000 {
            ts.deleteCharacters(in: NSRange(location: 0, length: ts.length - 150_000))
        }
        if atBottom { textView.scrollToEndOfDocument(nil) }
    }

    @objc private func copyAll(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(RemoteLog.entries.map(RemoteLog.line).joined(separator: "\n"), forType: .string)
    }

    @objc private func clearAll(_ sender: Any?) { RemoteLog.clear() }
}
