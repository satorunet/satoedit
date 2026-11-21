import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let folderTreeDidChange = Notification.Name("SatomaruFolderTreeDidChange")
}

/// 左のフォルダツリーの、全ウインドウ (タブ) で共通の状態。
/// どのタブに切り替えても同じフォルダ・同じ開き具合で見えるように、ここにまとめて持つ。
enum FolderTree {
    private static let rootKey = "folderTreeRoot"
    private static let visibleKey = "folderTreeVisible"
    private static let widthKey = "folderTreeWidth"
    private static let expandedKey = "folderTreeExpanded"

    static var root: URL? {
        guard let p = UserDefaults.standard.string(forKey: rootKey) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    static var isVisible: Bool { UserDefaults.standard.bool(forKey: visibleKey) }

    static var width: CGFloat {
        get {
            let w = CGFloat(UserDefaults.standard.double(forKey: widthKey))
            return w < 1 ? 240 : min(max(w, 160), 600)
        }
        set { UserDefaults.standard.set(Double(min(max(newValue, 160), 600)), forKey: widthKey) }
    }

    /// 開いているフォルダのパス
    static var expanded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: expandedKey) ?? []) {
        didSet {
            // 覚えるのは多くても 500 個まで (起動のたびに読むので)
            UserDefaults.standard.set(Array(expanded.sorted().prefix(500)), forKey: expandedKey)
        }
    }

    /// タブを切り替えても同じ位置が見えるように、スクロール位置を引き継ぐ
    static var scrollY: CGFloat = 0

    static func setVisible(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: visibleKey)
        NotificationCenter.default.post(name: .folderTreeDidChange, object: nil)
    }

    static func setRoot(_ url: URL) {
        UserDefaults.standard.set(url.standardizedFileURL.path, forKey: rootKey)
        expanded = []
        scrollY = 0
        UserDefaults.standard.set(true, forKey: visibleKey)
        NotificationCenter.default.post(name: .folderTreeDidChange, object: nil)
    }

    /// フォルダを選んでツリーに出す
    static func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "ツリーに出すフォルダを選んでください"
        panel.prompt = "このフォルダを開く"
        if let r = root { panel.directoryURL = r }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setRoot(url)
    }

    /// エディタで開くファイルか (画像・動画・圧縮ファイルなどは既定のアプリに任せる)
    static func opensInEditor(_ url: URL) -> Bool {
        let ext = url.pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return true }
        if type.isDynamic { return true } // 知らない拡張子はテキストとして開いてみる
        let texty: [UTType] = [.text, .sourceCode, .json, .xml, .yaml, .propertyList, .script, .log]
        if texty.contains(where: { type.conforms(to: $0) }) { return true }
        let binary: [UTType] = [.image, .audiovisualContent, .archive, .pdf, .executable, .diskImage, .font,
                                .spreadsheet, .presentation, .bundle, .application]
        return !binary.contains { type.conforms(to: $0) }
    }
}

/// ツリーの 1 項目 (ファイルかフォルダ)。フォルダの中身は開いたときに初めて読む
final class FileNode: NSObject {
    let url: URL
    let isDirectory: Bool
    /// 絞り込みの結果では、フォルダからの相対パスを出す
    var detail: String?
    private(set) var children: [FileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    var name: String { url.lastPathComponent }

    func loadChildrenIfNeeded() -> [FileNode] {
        if let c = children { return c }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        let nodes = items.map { u -> FileNode in
            let r = try? u.resourceValues(forKeys: Set(keys))
            // .app などのパッケージは 1 つのファイルとして扱う
            return FileNode(url: u, isDirectory: r?.isDirectory == true && r?.isPackage != true)
        }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        children = nodes
        return nodes
    }
}

/// 左に出すフォルダツリー。ファイルをクリックするとタブで開く。右クリックで新規・名前変更・削除など
final class FolderTreePanel: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSSearchFieldDelegate {
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let titleButton = NSButton(title: "", target: nil, action: nil)
    private let search = NSSearchField()
    private let emptyButton = NSButton(title: "フォルダを開く…", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private var widthConstraint: NSLayoutConstraint!

    private var rootNode: FileNode?
    /// 絞り込み中はツリーの代わりにこの一覧を出す
    private var filtered: [FileNode]?
    private var filterGeneration = 0
    private var restoring = false
    /// いま編集している文書 (ツリーで選んでおく)
    var currentFile: URL? { didSet { if oldValue != currentFile { revealCurrentFile() } } }

    static let maxFilterResults = 500

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: FolderTree.width)
        widthConstraint.isActive = true

        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        // 見出し: フォルダ名 (押すとフォルダを選び直す)・再読み込み・閉じる
        titleButton.target = self
        titleButton.action = #selector(chooseFolder(_:))
        titleButton.isBordered = false
        titleButton.font = .boldSystemFont(ofSize: 12)
        titleButton.alignment = .left
        titleButton.lineBreakMode = .byTruncatingMiddle
        titleButton.imagePosition = .imageLeading
        titleButton.toolTip = "ツリーに出すフォルダを選び直す"
        titleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let reloadButton = iconButton("arrow.clockwise", "再読み込み", #selector(reloadClicked(_:)))
        let closeButton = iconButton("xmark", "フォルダツリーを閉じる", #selector(closeClicked(_:)))
        let header = NSStackView(views: [titleButton, NSView(), reloadButton, closeButton])
        header.orientation = .horizontal
        header.spacing = 4

        search.placeholderString = "ファイル名で絞り込み"
        search.delegate = self
        search.target = self
        search.action = #selector(searchChanged(_:))
        search.sendsSearchStringImmediately = true
        search.controlSize = .small
        search.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .small
        outline.indentationPerLevel = 12
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked(_:))
        outline.doubleAction = #selector(rowDoubleClicked(_:))
        outline.autosaveExpandedItems = false
        outline.setAccessibilityLabel("フォルダツリー")
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        emptyButton.target = self
        emptyButton.action = #selector(chooseFolder(_:))
        emptyButton.bezelStyle = .rounded

        countLabel.font = .systemFont(ofSize: 10)
        countLabel.textColor = .secondaryLabelColor
        countLabel.lineBreakMode = .byTruncatingTail

        let line = NSBox()
        line.boxType = .separator
        let handle = ResizeHandle { [weak self] delta in self?.resize(by: delta) }

        for v in [header, search, scroll, emptyButton, countLabel, line, handle] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            search.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 5),
            scroll.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -2),
            countLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            countLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            emptyButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),
            handle.trailingAnchor.constraint(equalTo: trailingAnchor),
            handle.topAnchor.constraint(equalTo: topAnchor),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.widthAnchor.constraint(equalToConstant: 5),
        ])
        reload(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let b = NSButton(image: image, target: self, action: action)
        b.isBordered = false
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        return b
    }

    // MARK: 中身の読み込み

    /// フォルダを読み直す (開いていたフォルダと選択はそのまま)。共通の状態が変わったときにも呼ぶ
    @objc func reload(_ sender: Any?) {
        widthConstraint.constant = FolderTree.width
        let root = FolderTree.root
        emptyButton.isHidden = root != nil
        scroll.isHidden = root == nil
        search.isHidden = root == nil
        titleButton.title = root?.lastPathComponent ?? "フォルダ未選択"
        if let r = root {
            let icon = NSWorkspace.shared.icon(forFile: r.path)
            icon.size = NSSize(width: 16, height: 16)
            titleButton.image = icon
        } else {
            titleButton.image = nil
        }
        rootNode = root.map { FileNode(url: $0, isDirectory: true) }
        if filtered != nil {
            startFilter()
        } else {
            reloadTree()
        }
    }

    private func reloadTree() {
        restoring = true
        outline.reloadData()
        if let r = rootNode { expandRemembered(under: r) }
        restoring = false
        countLabel.stringValue = ""
        revealCurrentFile()
    }

    private func expandRemembered(under node: FileNode) {
        for child in node.loadChildrenIfNeeded() where child.isDirectory && FolderTree.expanded.contains(child.url.path) {
            outline.expandItem(child)
            expandRemembered(under: child)
        }
    }

    /// タブを切り替えてこのウインドウが手前に来たとき: ほかのタブでの変更 (開き具合・スクロール) に合わせる
    func syncFromShared() {
        if rootNode?.url != FolderTree.root || widthConstraint.constant != FolderTree.width {
            reload(nil)
        } else if filtered == nil {
            restoring = true
            if let r = rootNode { syncExpansion(under: r) }
            restoring = false
        }
        var origin = scroll.contentView.bounds.origin
        origin.y = FolderTree.scrollY
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        revealCurrentFile()
    }

    private func syncExpansion(under node: FileNode) {
        for child in node.loadChildrenIfNeeded() where child.isDirectory {
            let want = FolderTree.expanded.contains(child.url.path)
            if want != outline.isItemExpanded(child) {
                if want { outline.expandItem(child) } else { outline.collapseItem(child) }
            }
            if want { syncExpansion(under: child) }
        }
    }

    func rememberScroll() {
        FolderTree.scrollY = scroll.contentView.bounds.origin.y
    }

    /// 編集中の文書がツリーの中にあれば、そこまで開いて選ぶ (スクロール位置は動かさない)
    private func revealCurrentFile() {
        guard filtered == nil, let root = rootNode, let file = currentFile?.standardizedFileURL else { return }
        let rootPath = root.url.standardizedFileURL.path
        guard file.path.hasPrefix(rootPath + "/") else { outline.deselectAll(nil); return }
        var node = root
        for part in file.path.dropFirst(rootPath.count + 1).split(separator: "/") {
            guard let next = node.loadChildrenIfNeeded().first(where: { $0.name == String(part) }) else { return }
            if next.isDirectory && !outline.isItemExpanded(next) { outline.expandItem(next) }
            node = next
        }
        let row = outline.row(forItem: node)
        if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }

    // MARK: 絞り込み

    @objc private func searchChanged(_ sender: Any?) {
        if search.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            filterGeneration += 1
            filtered = nil
            reloadTree()
        } else {
            startFilter()
        }
    }

    /// フォルダの中を別スレッドでたどって、名前に文字を含むファイルを集める (多すぎるときは途中で打ち切る)
    private func startFilter() {
        guard let root = rootNode?.url else { return }
        let words = search.stringValue.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return }
        filterGeneration += 1
        let generation = filterGeneration
        filtered = []
        outline.reloadData()
        countLabel.stringValue = "探しています…"
        let limit = Self.maxFilterResults
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [FileNode] = []
            var scanned = 0
            var truncated = false
            let rootPath = root.standardizedFileURL.path
            let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let u = e?.nextObject() as? URL {
                scanned += 1
                if scanned % 2000 == 0, self?.filterGeneration != generation { return } // 打ち直されたらやめる
                if scanned > 300_000 { truncated = true; break }
                let name = u.lastPathComponent.lowercased()
                guard words.allSatisfy({ name.contains($0) }) else { continue }
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if isDir { continue }
                let node = FileNode(url: u, isDirectory: false)
                let dir = u.deletingLastPathComponent().standardizedFileURL.path
                node.detail = dir.count > rootPath.count ? String(dir.dropFirst(rootPath.count + 1)) : ""
                found.append(node)
                if found.count >= limit { truncated = true; break }
            }
            DispatchQueue.main.async {
                guard let self = self, self.filterGeneration == generation, self.filtered != nil else { return }
                self.filtered = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                self.outline.reloadData()
                self.countLabel.stringValue = truncated ? "\(found.count) 件 (多いので途中まで。もう少し絞ってください)" : "\(found.count) 件"
            }
        }
    }

    // MARK: NSOutlineView

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let f = filtered { return item == nil ? f.count : 0 }
        guard let node = (item as? FileNode) ?? rootNode else { return 0 }
        return node.loadChildrenIfNeeded().count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let f = filtered { return f[index] }
        return ((item as? FileNode) ?? rootNode!).loadChildrenIfNeeded()[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        filtered == nil && (item as? FileNode)?.isDirectory == true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("file")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let image = NSImageView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.font = .systemFont(ofSize: 12)
            for v in [image, text] as [NSView] {
                v.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(v)
            }
            cell.imageView = image
            cell.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: node.url.path)
        if let detail = node.detail, !detail.isEmpty {
            let s = NSMutableAttributedString(string: node.name)
            s.append(NSAttributedString(string: "  " + detail, attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                                                                           .font: NSFont.systemFont(ofSize: 10)]))
            cell.textField?.attributedStringValue = s
        } else {
            cell.textField?.stringValue = node.name
        }
        cell.toolTip = node.url.path
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !restoring, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        FolderTree.expanded.insert(node.url.path)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !restoring, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
        // 閉じたフォルダの下も忘れる
        let prefix = node.url.path
        FolderTree.expanded = FolderTree.expanded.filter { $0 != prefix && !$0.hasPrefix(prefix + "/") }
    }

    // MARK: クリック

    private func node(atRow row: Int) -> FileNode? {
        row >= 0 ? outline.item(atRow: row) as? FileNode : nil
    }

    /// フォルダは開閉、テキストのファイルはタブで開く
    @objc private func rowClicked(_ sender: Any?) {
        guard let node = node(atRow: outline.clickedRow) else { return }
        if node.isDirectory {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else if FolderTree.opensInEditor(node.url) {
            openInEditor(node.url)
        }
    }

    /// 画像などエディタで開かないものは、ダブルクリックで既定のアプリへ
    @objc private func rowDoubleClicked(_ sender: Any?) {
        guard let node = node(atRow: outline.clickedRow), !node.isDirectory, !FolderTree.opensInEditor(node.url) else { return }
        NSWorkspace.shared.open(node.url)
    }

    private func openInEditor(_ url: URL) {
        rememberScroll()
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error = error, (error as? CocoaError)?.code != .userCancelled { NSApp.presentError(error) }
        }
    }

    @objc private func chooseFolder(_ sender: Any?) { FolderTree.chooseRoot() }
    @objc private func reloadClicked(_ sender: Any?) { reload(nil) }
    @objc private func closeClicked(_ sender: Any?) { FolderTree.setVisible(false) }

    private func resize(by delta: CGFloat) {
        FolderTree.width = widthConstraint.constant + delta
        widthConstraint.constant = FolderTree.width
    }

    // MARK: 右クリックのメニュー

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard rootNode != nil else { return }
        let clicked = node(atRow: outline.clickedRow)
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let i = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            i.target = self
            i.representedObject = clicked
            menu.addItem(i)
        }
        if let n = clicked {
            if !n.isDirectory {
                add("エディタで開く", #selector(menuOpen(_:)))
                add("既定のアプリで開く", #selector(menuOpenExternally(_:)))
            }
            add("Finder に表示", #selector(menuRevealInFinder(_:)))
            menu.addItem(.separator())
        }
        add("新規ファイル…", #selector(menuNewFile(_:)))
        add("新規フォルダ…", #selector(menuNewFolder(_:)))
        if clicked != nil {
            add("名前を変更…", #selector(menuRename(_:)))
            add("ゴミ箱に入れる", #selector(menuTrash(_:)))
            menu.addItem(.separator())
            add("パスをコピー", #selector(menuCopyPath(_:)))
        }
        menu.addItem(.separator())
        add("再読み込み", #selector(reloadClicked(_:)))
    }

    private func target(_ sender: NSMenuItem) -> FileNode? { sender.representedObject as? FileNode }

    /// 新しく作る場所: フォルダを右クリックしたらその中、ファイルならその隣、何もないところならいちばん上
    private func directory(for sender: NSMenuItem) -> URL? {
        guard let n = target(sender) else { return rootNode?.url }
        return n.isDirectory ? n.url : n.url.deletingLastPathComponent()
    }

    @objc private func menuOpen(_ sender: NSMenuItem) {
        if let n = target(sender) { openInEditor(n.url) }
    }

    @objc private func menuOpenExternally(_ sender: NSMenuItem) {
        if let n = target(sender) { NSWorkspace.shared.open(n.url) }
    }

    @objc private func menuRevealInFinder(_ sender: NSMenuItem) {
        if let n = target(sender) { NSWorkspace.shared.activateFileViewerSelecting([n.url]) }
    }

    @objc private func menuCopyPath(_ sender: NSMenuItem) {
        guard let n = target(sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(n.url.path, forType: .string)
    }

    /// 名前を聞く。やめたら nil。"/" を含む名前や空の名前は受け付けない
    private func askName(title: String, initial: String, button: String) -> String? {
        var message = ""
        var value = initial
        while true {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.stringValue = value
            alert.accessoryView = field
            alert.addButton(withTitle: button)
            alert.addButton(withTitle: "やめる")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            value = field.stringValue.trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value == "." || value == ".." {
                message = "名前を入れてください。"
            } else if value.contains("/") || value.contains(":") {
                message = "名前に / や : は使えません。"
            } else {
                return value
            }
        }
    }

    private func finish(_ error: Error?, expand dir: URL? = nil) {
        if let error = error { NSApp.presentError(error) }
        if let d = dir, d != rootNode?.url { FolderTree.expanded.insert(d.path) }
        rememberScroll()
        reload(nil)
        syncFromShared()
    }

    @objc private func menuNewFile(_ sender: NSMenuItem) {
        guard let dir = directory(for: sender), let name = askName(title: "新規ファイル", initial: "新規.txt", button: "作る") else { return }
        let url = dir.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            finish(CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path]))
            return
        }
        do {
            try Data().write(to: url, options: .withoutOverwriting)
            finish(nil, expand: dir)
            openInEditor(url)
        } catch {
            finish(error)
        }
    }

    @objc private func menuNewFolder(_ sender: NSMenuItem) {
        guard let dir = directory(for: sender), let name = askName(title: "新規フォルダ", initial: "新規フォルダ", button: "作る") else { return }
        let url = dir.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            FolderTree.expanded.insert(url.path)
            finish(nil, expand: dir)
        } catch {
            finish(error)
        }
    }

    @objc private func menuRename(_ sender: NSMenuItem) {
        guard let n = target(sender), let name = askName(title: "名前を変更", initial: n.name, button: "変更"), name != n.name else { return }
        let dest = n.url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: n.isDirectory)
        // 開いている文書があれば、新しい場所へついてくるように「移動」として知らせる
        var coordError: NSError?
        var moveError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: n.url, options: .forMoving, writingItemAt: dest, options: .forReplacing,
                               error: &coordError) { from, to in
            do {
                guard !FileManager.default.fileExists(atPath: to.path) else {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: to.path])
                }
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            } catch {
                moveError = error
            }
        }
        if moveError == nil, coordError == nil, n.isDirectory {
            // 開いていたフォルダは新しい名前で覚え直す
            let old = n.url.path
            FolderTree.expanded = Set(FolderTree.expanded.map { p in
                p == old || p.hasPrefix(old + "/") ? dest.path + p.dropFirst(old.count) : p
            })
        }
        finish(moveError ?? coordError)
    }

    @objc private func menuTrash(_ sender: NSMenuItem) {
        guard let n = target(sender) else { return }
        let alert = NSAlert()
        alert.messageText = "「\(n.name)」をゴミ箱に入れますか？"
        alert.informativeText = n.isDirectory ? "フォルダの中身も一緒にゴミ箱に入ります。ゴミ箱から戻せます。" : "ゴミ箱から戻せます。"
        alert.addButton(withTitle: "ゴミ箱に入れる")
        alert.addButton(withTitle: "やめる")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: n.url, resultingItemURL: nil)
            finish(nil)
        } catch {
            finish(error)
        }
    }

    // MARK: 幅を変えるつまみ

    private final class ResizeHandle: NSView {
        let onDrag: (CGFloat) -> Void
        init(onDrag: @escaping (CGFloat) -> Void) {
            self.onDrag = onDrag
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func mouseDragged(with event: NSEvent) { onDrag(event.deltaX) }
        override func mouseDown(with event: NSEvent) {} // ウインドウの移動にしない
    }
}
