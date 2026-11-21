import AppKit
import HinokiCore

/// フォルダ内のファイルを横断検索し、結果のダブルクリック (タグジャンプ) で該当行を開く
final class GrepWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = GrepWindowController()

    private let patternField = NSTextField(string: "")
    private let folderField = NSTextField(string: "")
    private let maskField = NSTextField(string: "*")
    private let regexCheck = NSButton(checkboxWithTitle: "正規表現", target: nil, action: nil)
    private let caseCheck = NSButton(checkboxWithTitle: "大文字と小文字を区別", target: nil, action: nil)
    private let recursiveCheck = NSButton(checkboxWithTitle: "サブフォルダも検索", target: nil, action: nil)
    private let searchButton = NSButton(title: "検索", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()

    private var results: [GrepMatch] = []
    private var root: URL?
    private var generation = 0
    private var running = false

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.title = "grep"

        window.tabbingMode = .disallowed
        super.init(window: window)
        buildUI(in: window)
        let d = UserDefaults.standard
        folderField.stringValue = d.string(forKey: "grepFolder") ?? FileManager.default.homeDirectoryForCurrentUser.path
        maskField.stringValue = d.string(forKey: "grepMask") ?? "*"
        recursiveCheck.state = .on
        window.center()
        window.setFrameAutosaveName("GrepWindow")
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI(in window: NSWindow) {
        patternField.placeholderString = "検索する文字列"
        maskField.placeholderString = "*.swift;*.txt"
        patternField.target = self
        patternField.action = #selector(startSearch)
        searchButton.target = self
        searchButton.action = #selector(startSearch)
        searchButton.keyEquivalent = "\r"
        let browse = NSButton(title: "参照…", target: self, action: #selector(chooseFolder))

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "検索:"), patternField],
            [NSTextField(labelWithString: "フォルダ:"), NSStackView(views: [folderField, browse])],
            [NSTextField(labelWithString: "ファイル:"), maskField],
            [NSGridCell.emptyContentView, NSStackView(views: [regexCheck, caseCheck, recursiveCheck, searchButton])],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.setContentHuggingPriority(.defaultHigh, for: .vertical)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.title = "結果"
        table.addTableColumn(column)
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        column.width = 2000

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle

        let stack = NSStackView(views: [grid, scroll, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 10, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            patternField.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),
            folderField.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
        ])
    }

    // MARK: 公開

    /// 開いているファイルのフォルダと選択文字列を初期値にして表示
    func show(seedText: String?, folder: URL?) {
        if let s = seedText, !s.isEmpty, !s.contains("\n") { patternField.stringValue = s }
        if let f = folder { folderField.stringValue = f.path }
        showWindow(nil)
        window?.makeFirstResponder(patternField)
    }

    // MARK: 操作

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: folderField.stringValue)
        panel.beginSheetModal(for: window!) { [weak self] resp in
            if resp == .OK, let url = panel.url { self?.folderField.stringValue = url.path }
        }
    }

    @objc private func startSearch() {
        if running {
            generation += 1 // 中止
            return
        }
        let pattern = patternField.stringValue
        guard !pattern.isEmpty else { NSSound.beep(); return }
        let folder = URL(fileURLWithPath: (folderField.stringValue as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            statusLabel.stringValue = "フォルダが見つかりません: \(folder.path)"
            NSSound.beep()
            return
        }
        UserDefaults.standard.set(folderField.stringValue, forKey: "grepFolder")
        UserDefaults.standard.set(maskField.stringValue, forKey: "grepMask")

        let options = GrepOptions(pattern: pattern,
                                  useRegex: regexCheck.state == .on,
                                  caseSensitive: caseCheck.state == .on,
                                  fileMask: maskField.stringValue,
                                  recursive: recursiveCheck.state == .on)
        do { _ = try options.makeRegex() } catch {
            statusLabel.stringValue = "正規表現が正しくありません"
            NSSound.beep()
            return
        }

        results = []
        root = folder
        table.reloadData()
        generation += 1
        let myGeneration = generation
        running = true
        searchButton.title = "中止"
        statusLabel.stringValue = "検索中…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var batch: [GrepMatch] = []
            var lastFlush = Date()
            let cancelled = { () -> Bool in
                var c = false
                DispatchQueue.main.sync { c = self?.generation != myGeneration }
                return c
            }
            func flush() {
                let items = batch
                batch = []
                DispatchQueue.main.async {
                    guard let self = self, self.generation == myGeneration else { return }
                    self.results += items
                    self.table.reloadData()
                    self.statusLabel.stringValue = "検索中… \(self.results.count) 件"
                }
            }
            var checkCounter = 0
            try? Grep.search(root: folder, options: options, isCancelled: {
                checkCounter += 1
                return checkCounter % 50 == 0 ? cancelled() : false
            }) { m in
                batch.append(m)
                if Date().timeIntervalSince(lastFlush) > 0.2 {
                    flush()
                    lastFlush = Date()
                }
            }
            flush()
            DispatchQueue.main.async {
                guard let self = self else { return }
                let wasCancelled = self.generation != myGeneration
                if !wasCancelled || self.running {
                    self.running = false
                    self.searchButton.title = "検索"
                }
                if !wasCancelled {
                    self.statusLabel.stringValue = "\(self.results.count) 件見つかりました"
                        + (self.results.count >= options.maxResults ? " (上限に達したので打ち切りました)" : "")
                        + "  — ダブルクリックでその行へジャンプ"
                } else {
                    self.statusLabel.stringValue = "中止しました (\(self.results.count) 件)"
                }
            }
        }
    }

    @objc private func openSelected() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0 && row < results.count else { return }
        let m = results[row]
        NSDocumentController.shared.openDocument(withContentsOf: m.url, display: true) { doc, _, error in
            if let error = error { NSApp.presentError(error); return }
            (doc as? Document)?.editor?.textView.goTo(line: m.line)
            (doc as? Document)?.editor?.window?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: テーブル

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = id
            f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            f.lineBreakMode = .byClipping
            return f
        }()
        let m = results[row]
        var path = m.url.path
        if let r = root?.path, path.hasPrefix(r + "/") { path = String(path.dropFirst(r.count + 1)) }
        let line = m.text.trimmingCharacters(in: .whitespaces)
        let s = NSMutableAttributedString(string: "\(path)(\(m.line)): ", attributes: [.foregroundColor: Theme.tag])
        s.append(NSAttributedString(string: String(line.prefix(400)), attributes: [.foregroundColor: Theme.text]))
        cell.attributedStringValue = s
        return cell
    }
}
