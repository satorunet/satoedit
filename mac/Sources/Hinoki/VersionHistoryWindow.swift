import AppKit
import HinokiCore

/// 版の履歴の窓: 左に版の一覧 (新しい順)、右にその版の中身か、今の内容との違い。
/// 「この版に戻す」で、エディタの本文をその版にする (⌘Z で取り消せる)
final class VersionHistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private static var open: [VersionHistoryWindowController] = []
    private let url: URL
    private var versions: [VersionStore.Version] = []
    private let table = NSTableView()
    private let textView = NSTextView()
    private let showDiff = NSSegmentedControl(labels: [L("この版"), L("今との違い"), L("Word 風")], trackingMode: .selectOne, target: nil, action: nil)
    private let info = NSTextField(labelWithString: "")
    private let restoreButton = NSButton(title: L("この版に戻す"), target: nil, action: nil)
    private let copyButton = NSButton(title: L("この版をコピー"), target: nil, action: nil)

    static func show(for url: URL, select commit: String? = nil) {
        let w: VersionHistoryWindowController
        if let have = open.first(where: { $0.url == url }) {
            have.reload()
            w = have
        } else {
            w = VersionHistoryWindowController(url: url)
            open.append(w)
        }
        if let c = commit, let row = w.versions.firstIndex(where: { $0.commit == c }) {
            w.table.selectRowIndexes([row], byExtendingSelection: false)
            w.table.scrollRowToVisible(row)
        }
        w.showWindow(nil)
        w.window?.makeKeyAndOrderFront(nil)
    }

    private init(url: URL) {
        self.url = url
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = L("版の履歴: {0}", url.lastPathComponent)
        window.minSize = NSSize(width: 640, height: 360)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        build()
        reload()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            Self.open.removeAll { $0 === self }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let col = NSTableColumn(identifier: .init("v"))
        col.title = L("保存した日時")
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 36
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        let left = NSScrollView()
        left.documentView = table
        left.hasVerticalScroller = true

        textView.isEditable = false
        textView.isRichText = true
        textView.font = Theme.font
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        let right = NSScrollView()
        right.documentView = textView
        right.hasVerticalScroller = true

        showDiff.selectedSegment = 0
        showDiff.target = self
        showDiff.action = #selector(refreshContent)
        restoreButton.target = self
        restoreButton.action = #selector(restore(_:))
        copyButton.target = self
        copyButton.action = #selector(copy(_:))
        info.textColor = .secondaryLabelColor
        info.lineBreakMode = .byTruncatingTail
        let bar = NSStackView(views: [showDiff, info, NSView(), copyButton, restoreButton])
        bar.spacing = 10
        let rightBox = NSStackView(views: [bar, right])
        rightBox.orientation = .vertical
        rightBox.spacing = 8
        rightBox.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(rightBox)
        left.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        window?.contentView = split
        split.setPosition(240, ofDividerAt: 0)
    }

    private func reload() {
        versions = VersionStore.history(url)
        table.reloadData()
        if !versions.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        // 確かめ用: いちばん古い版を Word 風で見せる
        if ProcessInfo.processInfo.environment["SATORU_TEST_WORDDIFF"] != nil, versions.count > 1 {
            showDiff.selectedSegment = 2
            table.selectRowIndexes([versions.count - 1], byExtendingSelection: false)
        }
        refreshContent()
    }

    // MARK: 一覧

    func numberOfRows(in tableView: NSTableView) -> Int { max(versions.count, 1) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let t = NSTextField(labelWithString: "")
        let d = NSTextField(labelWithString: "")
        d.font = .systemFont(ofSize: 10)
        d.textColor = .secondaryLabelColor
        if versions.isEmpty {
            t.stringValue = L("まだ版がありません")
            d.stringValue = L("保存すると、ここに残ります")
        } else {
            let v = versions[row]
            let df = DateFormatter()
            df.locale = Locale.current
            df.setLocalizedDateFormatFromTemplate("yMMMdHms")
            t.stringValue = (row == 0 ? L("いちばん新しい版") + " ・ " : "") + TextLibrary.dateText(v.date)
            d.stringValue = df.string(from: v.date)
        }
        let s = NSStackView(views: [t, d])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 0
        s.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(s)
        NSLayoutConstraint.activate([s.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                                     s.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { refreshContent() }

    // MARK: 中身

    private var selected: VersionStore.Version? {
        let r = table.selectedRow
        return r >= 0 && r < versions.count ? versions[r] : nil
    }

    private func versionText(_ v: VersionStore.Version) -> String? {
        VersionStore.content(v, of: url).flatMap { try? TextCodec.decode($0).text }
    }

    /// 今の内容 (開いていれば画面の本文、なければファイル)
    private func currentText() -> String {
        if let d = NSDocumentController.shared.document(for: url) as? Document, let tv = d.editor?.textView { return tv.string }
        return (try? Data(contentsOf: url)).flatMap { try? TextCodec.decode($0).text } ?? ""
    }

    @objc private func refreshContent() {
        let enabled = selected != nil
        restoreButton.isEnabled = enabled
        copyButton.isEnabled = enabled
        showDiff.isEnabled = enabled
        guard let v = selected, let text = versionText(v) else {
            textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
            info.stringValue = ""
            return
        }
        let base: [NSAttributedString.Key: Any] = [.font: Theme.font, .foregroundColor: NSColor.labelColor]
        if showDiff.selectedSegment == 0 {
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: base))
            info.stringValue = L("{0} 字", text.count)
            return
        }
        if showDiff.selectedSegment == 2 {
            // Word の変更履歴のように: 文章の中に、消した字 (赤の取り消し線) と足した字 (青の下線) をそのまま並べる
            let d = TextDiff.inline(old: text, new: currentText(), context: 1_000_000)
            let out = NSMutableAttributedString()
            if d.tooLarge {
                out.append(NSAttributedString(string: L("大きすぎて比べられません"), attributes: base))
            } else if !d.hasChanges {
                out.append(NSAttributedString(string: L("今の内容と同じです"), attributes: base))
            }
            for seg in d.segments {
                var a = base
                switch seg.kind {
                case .removed:
                    a[.foregroundColor] = NSColor.systemRed
                    a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    a[.strikethroughColor] = NSColor.systemRed
                    a[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.08)
                case .added:
                    a[.foregroundColor] = NSColor.systemBlue
                    a[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    a[.underlineColor] = NSColor.systemBlue
                    a[.backgroundColor] = NSColor.systemBlue.withAlphaComponent(0.08)
                case .gap:
                    a[.foregroundColor] = NSColor.secondaryLabelColor
                case .same:
                    break
                }
                out.append(NSAttributedString(string: seg.kind == .gap ? L("… {0} 行 同じ …", seg.skipped) + "\n" : seg.text, attributes: a))
            }
            textView.textStorage?.setAttributedString(out)
            info.stringValue = L("赤の取り消し線 = この版から消した所 ・ 青の下線 = 足した所")
            return
        }
        // 今との違い: この版 → 今 で、消えた行は赤、増えた行は緑
        let d = TextDiff.compare(old: text, new: currentText())
        let out = NSMutableAttributedString()
        for row in d.rows {
            var a = base
            let mark: String
            switch row.kind {
            case .removed: a[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.18); mark = "− "
            case .added: a[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.18); mark = "+ "
            case .gap: a[.foregroundColor] = NSColor.secondaryLabelColor; mark = "  "
            case .same: mark = "  "
            }
            let line = row.kind == .gap ? L("… {0} 行 同じ …", row.skipped) : row.text
            out.append(NSAttributedString(string: mark + line + "\n", attributes: a))
        }
        if !d.hasChanges { out.append(NSAttributedString(string: L("今の内容と同じです"), attributes: base)) }
        textView.textStorage?.setAttributedString(out)
        info.stringValue = L("今のほうが +{0} 行 / −{1} 行", d.added, d.removed)
    }

    @objc private func copy(_ sender: Any?) {
        guard let v = selected, let t = versionText(v) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }

    /// エディタの本文をこの版にする (開いていなければ開く)。⌘Z で取り消せる
    @objc private func restore(_ sender: Any?) {
        guard let v = selected, let t = versionText(v) else { return }
        let apply: (Document) -> Void = { d in
            guard let tv = d.editor?.textView else { return }
            let all = NSRange(location: 0, length: (tv.string as NSString).length)
            if tv.shouldChangeText(in: all, replacementString: t) {
                tv.replaceCharacters(in: all, with: t)
                tv.didChangeText()
                tv.undoManager?.setActionName(L("この版に戻す"))
            }
            d.editor?.window?.makeKeyAndOrderFront(nil)
        }
        if let d = NSDocumentController.shared.document(for: url) as? Document {
            apply(d)
        } else {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, _ in
                if let d = doc as? Document { DispatchQueue.main.async { apply(d) } }
            }
        }
    }
}

extension EditorWindowController {
    /// ファイル > 版の履歴…
    @objc func versionHistoryHM(_ sender: Any?) {
        guard let u = hdoc?.fileURL else { NSSound.beep(); return }
        guard VersionStore.gitAvailable else { return VersionStore.explainMissingGit(window) }
        hdoc?.save(nil)   // 今の内容も版に入れてから見せる
        VersionStore.noteSaved(u, now: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { VersionHistoryWindowController.show(for: u) }
    }
}

extension VersionStore {
    /// git が使えないとき: 入れ方を案内する
    static func explainMissingGit(_ window: NSWindow?) {
        let a = NSAlert()
        a.messageText = L("版の記録には git が要ります")
        a.informativeText = L("Mac の「コマンドライン・デベロッパ・ツール」を入れると使えます (無料)。「入れる」を押すと、Mac の入れる画面が開きます。")
        a.addButton(withTitle: L("入れる"))
        a.addButton(withTitle: L("キャンセル"))
        let go: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .alertFirstButtonReturn else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
            p.arguments = ["--install"]
            try? p.run()
        }
        if let w = window { a.beginSheetModal(for: w, completionHandler: go) } else { go(a.runModal()) }
    }
}
