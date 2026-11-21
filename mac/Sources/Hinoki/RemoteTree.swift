import AppKit
import HinokiCore

extension Notification.Name {
    static let remoteTreeDidChange = Notification.Name("SatomaruRemoteTreeDidChange")
}

/// エディタの左に出すサーバのツリーの、全ウインドウ (タブ) で共通の状態
enum RemoteTree {
    private static let visibleKey = "remoteTreeVisible"
    private static let serverKey = "remoteTreeServer"
    private static let widthKey = "remoteTreeWidth"

    static var isVisible: Bool { UserDefaults.standard.bool(forKey: visibleKey) }

    static var width: CGFloat {
        get {
            let w = CGFloat(UserDefaults.standard.double(forKey: widthKey))
            return w < 1 ? 260 : min(max(w, 180), 600)
        }
        set { UserDefaults.standard.set(Double(min(max(newValue, 180), 600)), forKey: widthKey) }
    }

    /// ツリーに出すサーバ (なければ登録の最初)
    static var server: RemoteServer? {
        let list = RemoteServerStore.servers
        let id = UserDefaults.standard.string(forKey: serverKey)
        return list.first { $0.id == id } ?? list.first
    }

    /// 開いているフォルダのパス (サーバごと)
    static var expanded: [String: Set<String>] = [:]
    /// ツリーのいちばん上のフォルダ (サーバごと)。どのタブでも同じ所から見えるように
    static var rootPath: [String: String] = [:]
    /// スクロール位置 (サーバごと)。タブを切り替えても・ファイルを開いて新しいタブになっても同じ所が見える
    static var scrollY: [String: CGFloat] = [:]
    /// 読み込んだフォルダの中身 (サーバ ID + パス → 一覧)。窓どうしで使い回す
    static var cache: [String: [RemoteEntry]] = [:]
    static func cacheKey(_ serverID: String, _ path: String) -> String { serverID + "\n" + path }

    static func setVisible(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: visibleKey)
        NotificationCenter.default.post(name: .remoteTreeDidChange, object: nil)
    }

    static func setServer(_ s: RemoteServer, show: Bool = true) {
        UserDefaults.standard.set(s.id, forKey: serverKey)
        if show { UserDefaults.standard.set(true, forKey: visibleKey) }
        NotificationCenter.default.post(name: .remoteTreeDidChange, object: nil)
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }
}

/// ツリーの 1 項目
final class RemoteNode: NSObject {
    let path: String
    var entry: RemoteEntry?
    let isDirectory: Bool
    var children: [RemoteNode]?
    var loading = false
    var error: String?

    init(path: String, entry: RemoteEntry?, isDirectory: Bool) {
        self.path = path
        self.entry = entry
        self.isDirectory = isDirectory
    }

    var name: String { entry?.name ?? path }
}

/// エディタの左に出すサーバのツリー。クリックで開き、状態 (編集中・送信中・更新済み) を色で出す
final class RemoteTreePanel: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let serverPopup = NSPopUpButton()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var widthConstraint: NSLayoutConstraint!

    private var client: RemoteClient? {
        didSet { placesList.serverID = client?.server.id }
    }
    /// 下: お気に入り・最近の場所 (常に出しておく)
    private let placesList = RemotePlacesListView(compact: true)
    /// いちばん下: やりとりのログ
    private let logView = RemoteLogView()
    private var root: RemoteNode?
    private var restoringScroll = false
    /// タブを切り替えたが、ファイルのあるフォルダをまだ読み込み中
    private var pendingReveal = false
    private var loadingCount = 0 { didSet { loadingCount > 0 ? spinner.startAnimation(nil) : spinner.stopAnimation(nil) } }
    /// いま編集しているサーバのファイル (ツリーで選んでおく)
    var currentRemotePath: String? { didSet { if oldValue != currentRemotePath { selectCurrent(scrolling: false) } } }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: RemoteTree.width)
        widthConstraint.isActive = true

        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        serverPopup.controlSize = .small
        serverPopup.font = .boldSystemFont(ofSize: 12)
        serverPopup.isBordered = false
        serverPopup.target = self
        serverPopup.action = #selector(serverChosen(_:))
        serverPopup.toolTip = L("ツリーに出すサーバを選ぶ")
        serverPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let reloadButton = iconButton("arrow.clockwise", L("再読み込み"), #selector(reloadClicked(_:)))
        let placesButton = iconButton("star", L("お気に入り・最近見た場所へ一発で行く"), #selector(showPlaces(_:)))
        let windowButton = iconButton("externaldrive.connected.to.line.below", L("サーバウインドウを開く"), #selector(openExplorer(_:)))
        let closeButton = iconButton("xmark", L("サーバツリーを閉じる"), #selector(closeClicked(_:)))
        let header = NSStackView(views: [serverPopup, spinner, placesButton, reloadButton, windowButton, closeButton])
        header.orientation = .horizontal
        header.spacing = 4

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
        outline.setAccessibilityLabel(L("サーバツリー"))
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)

        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle

        // 色の説明 (狭い幅でも収まるように 2 段)
        let legendTop = NSStackView(views: [
            Self.legendDot(RemoteDocuments.purple, L("開き中")),
            Self.legendDot(RemoteDocuments.orange, L("編集中")),
        ])
        let legendBottom = NSStackView(views: [
            Self.legendDot(RemoteDocuments.blue, L("送受信中")),
            Self.legendDot(RemoteDocuments.green, L("更新済み")),
        ])
        legendTop.spacing = 8
        legendBottom.spacing = 8
        let legend = NSStackView(views: [legendTop, legendBottom])
        legend.orientation = .vertical
        legend.alignment = .leading
        legend.spacing = 1

        let line = NSBox()
        line.boxType = .separator
        let handle = ResizeHandle { [weak self] delta in self?.resize(by: delta) }

        placesList.onPick = { [weak self] place in
            guard let self = self else { return }
            if place.isFile { self.open(RemoteNode(path: place.path, entry: nil, isDirectory: false)) }
            else { self.goTo(folder: place.path) }
        }
        let placesLine = NSBox()
        placesLine.boxType = .separator

        let logLine = NSBox()
        logLine.boxType = .separator
        statusLabel.isHidden = true // 状況はログ欄に出す

        for v in [header, scroll, emptyLabel, placesLine, placesList, legend, logLine, logView, statusLabel, line, handle] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5),
            scroll.bottomAnchor.constraint(equalTo: placesLine.topAnchor, constant: -2),
            placesLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            placesLine.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            placesLine.bottomAnchor.constraint(equalTo: placesList.topAnchor, constant: -2),
            placesList.leadingAnchor.constraint(equalTo: leadingAnchor),
            placesList.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            placesList.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.3),
            placesList.bottomAnchor.constraint(equalTo: legend.topAnchor, constant: -4),
            legend.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            legend.bottomAnchor.constraint(equalTo: logLine.topAnchor, constant: -4),
            logLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            logLine.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            logLine.bottomAnchor.constraint(equalTo: logView.topAnchor, constant: -2),
            // いちばん下: ログ欄
            logView.leadingAnchor.constraint(equalTo: leadingAnchor),
            logView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            logView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            logView.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.18),
            logView.heightAnchor.constraint(greaterThanOrEqualToConstant: 70),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),
            handle.trailingAnchor.constraint(equalTo: trailingAnchor),
            handle.topAnchor.constraint(equalTo: topAnchor),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.widthAnchor.constraint(equalToConstant: 5),
        ])

        // スクロールしたら覚える (ほかのタブ・新しく開いたタブで同じ位置に)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged(_:)),
                                               name: RemoteDocuments.stateChanged, object: nil)
        reload(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func legendDot(_ color: NSColor, _ text: String) -> NSView {
        let l = NSTextField(labelWithString: "● " + text)
        l.font = .systemFont(ofSize: 10)
        let s = NSMutableAttributedString(string: l.stringValue, attributes: [.font: l.font!, .foregroundColor: NSColor.secondaryLabelColor])
        s.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: 1))
        l.attributedStringValue = s
        return l
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let b = NSButton(image: image, target: self, action: action)
        b.isBordered = false
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        return b
    }

    // MARK: 読み込み

    /// サーバの選び直し・共通の状態の変化のときに呼ぶ
    @objc func reload(_ sender: Any?) {
        widthConstraint.constant = RemoteTree.width
        let servers = RemoteServerStore.servers
        serverPopup.removeAllItems()
        servers.forEach { serverPopup.addItem(withTitle: $0.displayName); serverPopup.lastItem?.representedObject = $0.id }
        guard let s = RemoteTree.server else {
            client = nil
            root = nil
            outline.reloadData()
            showEmpty(L("サーバが登録されていません。\n右上のボタンからサーバウインドウを開いて登録してください。"))
            return
        }
        if let i = servers.firstIndex(where: { $0.id == s.id }) { serverPopup.selectItem(at: i) }
        if client?.server != s || root == nil {
            client = RemoteClient(server: s)
            connect()
        } else if let shared = RemoteTree.rootPath[s.id], shared != root?.path {
            // ほかの所 (サーバウインドウなど) で見るフォルダが変わった
            root = RemoteNode(path: shared, entry: nil, isDirectory: true)
            placesList.currentFolder = shared
            outline.reloadData()
            restoringScroll = true
            load(root!, force: false)
        } else {
            outline.reloadData()
            selectCurrent(scrolling: true)
        }
    }

    private func showEmpty(_ text: String?) {
        emptyLabel.stringValue = text ?? ""
        emptyLabel.isHidden = text == nil
        scroll.isHidden = text != nil
    }

    private func connect() {
        guard let client = client else { return }
        let s = client.server
        guard !s.host.isEmpty, !s.user.isEmpty else {
            showEmpty(L("ホストとユーザーを設定してください"))
            return
        }
        statusLabel.stringValue = L("接続: {0}", client.connectionText)
        // ほかのタブで見ていた所があれば、つなぎ直さずにそこから出す
        if let shared = RemoteTree.rootPath[s.id] {
            root = RemoteNode(path: shared, entry: nil, isDirectory: true)
            showEmpty(nil)
            placesList.currentFolder = shared
            restoringScroll = true
            load(root!, force: false)
            return
        }
        showEmpty(L("{0} に接続しています…", s.displayName))
        loadingCount += 1
        client.home { [weak self] r in
            guard let self = self, self.client === client else { return }
            self.loadingCount -= 1
            switch r {
            case .success(let path):
                self.root = RemoteNode(path: path, entry: nil, isDirectory: true)
                RemoteTree.rootPath[s.id] = path
                self.placesList.currentFolder = path
                self.showEmpty(nil)
                self.load(self.root!, force: false)
            case .failure(let e):
                self.showEmpty(L("つなげませんでした") + "\n\n" + (e.localizedDescription.components(separatedBy: "\n").first ?? ""))
            }
        }
    }

    /// フォルダの中身を読む (覚えている中身があればそれを先に出す)
    private func load(_ node: RemoteNode, force: Bool) {
        guard let client = client, node.isDirectory else { return }
        let key = RemoteTree.cacheKey(client.server.id, node.path)
        if !force, let cached = RemoteTree.cache[key] {
            apply(cached, to: node)
            return
        }
        guard !node.loading else { return }
        node.loading = true
        if node !== root { outline.reloadItem(node) }
        loadingCount += 1
        client.list(node.path) { [weak self] r in
            guard let self = self, self.client === client else { return }
            node.loading = false
            self.loadingCount -= 1
            switch r {
            case .success(let list):
                RemoteTree.cache[key] = list
                self.apply(list, to: node)
                self.statusLabel.stringValue = L("接続: {0}", client.connectionText)
            case .failure(let e):
                node.error = e.localizedDescription.components(separatedBy: "\n").first
                node.children = []
                self.statusLabel.stringValue = L("エラー: ") + (node.error ?? "")
                self.outline.reloadItem(node === self.root ? nil : node, reloadChildren: true)
            }
        }
    }

    private func apply(_ list: [RemoteEntry], to node: RemoteNode) {
        // 開いていたフォルダは同じ物を使い回す (開き具合を保つ)
        let old = Dictionary((node.children ?? []).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        node.children = list.map { e in
            let p = RemoteTree.join(node.path, e.name)
            if let n = old[p] { n.entry = e; return n }
            return RemoteNode(path: p, entry: e, isDirectory: e.isDirectory)
        }
        outline.reloadItem(node === root ? nil : node, reloadChildren: true)
        // 前に開いていたフォルダを開き直す
        guard let sid = client?.server.id else { return }
        for c in node.children ?? [] where c.isDirectory && RemoteTree.expanded[sid]?.contains(c.path) == true {
            outline.expandItem(c)
        }
        if restoringScroll {
            // 開いていたフォルダの中身が並んでから元の位置へ (キャッシュから読むので、ここで揃っている)
            restoringScroll = false
            let y = RemoteTree.scrollY[sid] ?? 0
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                self.scroll.reflectScrolledClipView(self.scroll.contentView)
                // 開いたファイルが見えていなければ、そこまでスクロール (見えていれば動かない)
                if self.pendingReveal { self.revealTabFile() } else { self.selectCurrent(scrolling: true) }
            }
            return
        }
        if pendingReveal { revealTabFile() } else { selectCurrent(scrolling: false) }
    }

    private func revealCurrent() { selectCurrent(scrolling: true) }

    /// タブを切り替えてこのタブが手前に来たとき: ほかのタブでの見た目 (いちばん上のフォルダ・開いたフォルダ・スクロール) に揃え、
    /// このタブのファイルを選ぶ (閉じたフォルダの中なら、そこまで開いて見える所へ)
    func syncFromShared() {
        guard let client = client, let r = root else { return }
        let sid = client.server.id
        if let shared = RemoteTree.rootPath[sid], shared != r.path {
            root = RemoteNode(path: shared, entry: nil, isDirectory: true)
            placesList.currentFolder = shared
            outline.reloadData()
            load(root!, force: false)
        } else {
            // ほかのタブで開いた・閉じたフォルダを揃える
            func walk(_ n: RemoteNode) {
                for c in n.children ?? [] where c.isDirectory {
                    let want = RemoteTree.expanded[sid]?.contains(c.path) == true
                    if want && !outline.isItemExpanded(c) { outline.expandItem(c) }
                    else if !want && outline.isItemExpanded(c) { outline.collapseItem(c) }
                    if want { walk(c) }
                }
            }
            walk(r)
        }
        revealTabFile()
    }

    /// このタブのファイルを選び、見えるようにする (祖先のフォルダを開く)
    private func revealTabFile() {
        guard let p = currentRemotePath, let r = root, let sid = client?.server.id else { return }
        let base = r.path.hasSuffix("/") ? r.path : r.path + "/"
        guard p.hasPrefix(base) else { selectCurrent(scrolling: false); return }
        // ルートからファイルまでのフォルダを順に開く (中身はキャッシュがあればすぐ、なければ読み込み後に選び直す)
        var node = r
        pendingReveal = false
        let parts = p.dropFirst(base.count).split(separator: "/").dropLast()
        for part in parts {
            // 中身がまだ届いていない: 届いたらもう一度ここへ
            guard let kids = node.children else { pendingReveal = true; break }
            guard let next = kids.first(where: { $0.isDirectory && $0.name == part }) else { break }
            if !outline.isItemExpanded(next) {
                RemoteTree.expanded[sid, default: []].insert(next.path)
                outline.expandItem(next)
            }
            node = next
        }
        if node.children == nil && !parts.isEmpty { pendingReveal = true }
        selectCurrent(scrolling: true)
    }

    /// いま編集しているファイルをツリーで選ぶ。scrolling が false なら、見えていなくてもスクロールしない
    /// (ファイルを開いたときなどに、ツリーが勝手に動かないように)
    private func selectCurrent(scrolling: Bool) {
        guard let p = currentRemotePath else { outline.deselectAll(nil); return }
        let row = (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? RemoteNode)?.path == p }
        if let row = row {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if scrolling { outline.scrollRowToVisible(row) }
        }
    }

    @objc private func scrolled(_ n: Notification) {
        guard !restoringScroll, let sid = client?.server.id, window?.isKeyWindow == true else { return }
        RemoteTree.scrollY[sid] = scroll.contentView.bounds.origin.y
    }

    /// ファイルの状態が変わった: 色を塗り直す。送り終えたら、そのフォルダを読み直して大きさ・日時を新しくする
    @objc private func stateChanged(_ n: Notification) {
        guard let client = client, n.userInfo?["server"] as? String == client.server.id,
              let path = n.userInfo?["path"] as? String else { return }
        let row = (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? RemoteNode)?.path == path }
        if let row = row, let node = outline.item(atRow: row) as? RemoteNode {
            outline.reloadItem(node)
            if case .uploaded = RemoteDocuments.state(serverID: client.server.id, path: path) {
                client.stat(path) { [weak self] e in
                    guard let self = self, let e = e else { return }
                    node.entry = e
                    self.outline.reloadItem(node)
                }
            }
        }
    }

    // MARK: 表

    private func children(of item: Any?) -> [RemoteNode] {
        if let n = item as? RemoteNode { return n.children ?? [] }
        return root?.children ?? []
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? RemoteNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? RemoteNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("remoteCell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let iv = NSImageView()
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingMiddle
            [iv, tf].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; c.addSubview($0) }
            c.imageView = iv
            c.textField = tf
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16),
                iv.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        let symbol = node.isDirectory ? "folder" : (node.entry?.isLink == true ? "link" : "doc.text")
        cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let st = client.flatMap { RemoteDocuments.state(serverID: $0.server.id, path: node.path) }
        // やりとりの途中 (受信中・送信中) や、フォルダを読み込み中は、アイコンの代わりにぐるぐる
        let busy = st?.inProgress == true || (node.isDirectory && node.loading)
        let spin: NSProgressIndicator = (cell.subviews.first { $0 is NSProgressIndicator } as? NSProgressIndicator) ?? {
            let p = NSProgressIndicator()
            p.style = .spinning
            p.controlSize = .small
            p.isDisplayedWhenStopped = false
            p.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(p)
            if let iv = cell.imageView {
                NSLayoutConstraint.activate([
                    p.centerXAnchor.constraint(equalTo: iv.centerXAnchor),
                    p.centerYAnchor.constraint(equalTo: iv.centerYAnchor),
                    p.widthAnchor.constraint(equalToConstant: 14),
                    p.heightAnchor.constraint(equalToConstant: 14),
                ])
            }
            return p
        }()
        cell.imageView?.isHidden = busy
        busy ? spin.startAnimation(nil) : spin.stopAnimation(nil)
        var title = node.name
        if let mark = st?.mark, !mark.isEmpty { title += "  (\(mark))" }
        if node.error != nil { title += "  ⚠︎" }
        cell.textField?.stringValue = title
        if let c = st?.color {
            cell.textField?.textColor = c
            cell.imageView?.contentTintColor = c
            cell.textField?.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        } else {
            cell.textField?.textColor = .labelColor
            cell.imageView?.contentTintColor = node.isDirectory ? .controlAccentColor : .secondaryLabelColor
            cell.textField?.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        var tip = node.path
        if let e = node.entry, !e.isDirectory { tip += "\n" + RemoteDocuments.describe(e) }
        if let err = node.error { tip += "\n" + err }
        cell.toolTip = tip
        return cell
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? RemoteNode, let sid = client?.server.id else { return }
        RemoteTree.expanded[sid, default: []].insert(node.path)
        if node.children == nil { load(node, force: false) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? RemoteNode, let sid = client?.server.id else { return }
        RemoteTree.expanded[sid]?.remove(node.path)
    }

    // MARK: 操作

    /// クリック: フォルダは開け閉め。ファイルは選ぶだけで、開くかどうかを小さな吹き出しで聞く
    @objc private func rowClicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? RemoteNode else { return }
        if node.isDirectory {
            outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
        } else if NSApp.currentEvent?.clickCount ?? 1 < 2 {
            askToOpen(node, row: row)
        }
    }

    /// ダブルクリック: 聞かずに開く
    @objc private func rowDoubleClicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? RemoteNode, !node.isDirectory else { return }
        confirmPopover?.close()
        open(node)
    }

    /// Return キー: 選んでいるファイルを開く
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76,
           let node = outline.item(atRow: outline.selectedRow) as? RemoteNode, !node.isDirectory {
            confirmPopover?.close()
            open(node)
        } else {
            super.keyDown(with: event)
        }
    }

    private var confirmPopover: NSPopover?

    private func askToOpen(_ node: RemoteNode, row: Int) {
        confirmPopover?.close()
        // もう開いているタブがあれば、聞かずにそのタブを出す
        if let c = client, let doc = RemoteDocuments.openDocument(server: c.server, path: node.path) {
            doc.showWindows()
            doc.editor?.focusEditor()
            return
        }
        let vc = NSViewController()
        let title = NSTextField(labelWithString: L("「{0}」を開きますか？", node.name))
        title.font = .boldSystemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingMiddle
        var detail = node.path
        if let e = node.entry { detail += "\n" + RemoteDocuments.describe(e) }
        let info = NSTextField(wrappingLabelWithString: detail)
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        info.preferredMaxLayoutWidth = 260
        let openButton = NSButton(title: L("開く"), target: self, action: #selector(confirmOpen(_:)))
        openButton.keyEquivalent = "\r"
        openButton.bezelStyle = .rounded
        let cancel = NSButton(title: L("やめる"), target: self, action: #selector(confirmCancel(_:)))
        cancel.keyEquivalent = "\u{1B}"
        cancel.bezelStyle = .rounded
        let buttons = NSStackView(views: [NSView(), cancel, openButton])
        let stack = NSStackView(views: [title, info, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        title.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        vc.view = stack
        pendingOpen = node
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        pop.show(relativeTo: outline.rect(ofRow: row), of: outline, preferredEdge: .maxX)
        pop.contentViewController?.view.window?.makeFirstResponder(openButton)
        confirmPopover = pop
    }

    private var pendingOpen: RemoteNode?

    @objc private func confirmOpen(_ sender: Any?) {
        confirmPopover?.close()
        if let n = pendingOpen { open(n) }
        pendingOpen = nil
    }

    @objc private func confirmCancel(_ sender: Any?) {
        confirmPopover?.close()
        pendingOpen = nil
    }

    private func open(_ node: RemoteNode) {
        guard let client = client else { return }
        loadingCount += 1
        statusLabel.stringValue = L("{0} を取ってきています…", node.path)
        RemoteDocuments.fetchAndOpen(client: client, path: node.path, toastWindow: window) { [weak self] e in
            guard let self = self else { return }
            self.loadingCount -= 1
            self.statusLabel.stringValue = e == nil ? L("接続: {0}", client.connectionText)
                : L("エラー: ") + (e!.localizedDescription.components(separatedBy: "\n").first ?? "")
        }
    }

    @objc private func serverChosen(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String,
              let s = RemoteServerStore.servers.first(where: { $0.id == id }) else { return }
        RemoteTree.setServer(s)
    }

    @objc private func reloadClicked(_ sender: Any?) {
        guard let client = client, let root = root else { reload(nil); connect(); return }
        // 開いているフォルダをすべて読み直す
        let sid = client.server.id
        RemoteTree.cache = RemoteTree.cache.filter { !$0.key.hasPrefix(sid + "\n") }
        func walk(_ n: RemoteNode) {
            guard n.isDirectory, n === root || outline.isItemExpanded(n) else { return }
            load(n, force: true)
            (n.children ?? []).forEach(walk)
        }
        walk(root)
    }

    /// ★: お気に入り・最近の場所。フォルダはツリーのいちばん上にして開く。ファイルは開く
    @objc private func showPlaces(_ sender: NSButton) {
        guard let client = client else { NSSound.beep(); return }
        let sid = client.server.id
        let menu = RemotePlaces.menu(serverID: sid, currentFolder: root?.path) { [weak self] place in
            guard let self = self else { return }
            if place.isFile {
                self.open(RemoteNode(path: place.path, entry: nil, isDirectory: false))
            } else {
                self.goTo(folder: place.path)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// ツリーのいちばん上を、このフォルダにする
    func goTo(folder path: String) {
        guard let client = client else { return }
        root = RemoteNode(path: path, entry: nil, isDirectory: true)
        RemoteTree.rootPath[client.server.id] = path
        RemoteTree.scrollY[client.server.id] = 0
        outline.reloadData()
        showEmpty(nil)
        load(root!, force: false)
        RemotePlaces.visitFolder(client.server.id, path)
        placesList.currentFolder = path
        statusLabel.stringValue = path
    }

    @objc private func openExplorer(_ sender: Any?) { ServerExplorerWindowController.shared.show() }
    @objc private func closeClicked(_ sender: Any?) {
        if let editor = window?.windowController as? EditorWindowController { editor.dismissRemoteTree() }
        else { RemoteTree.setVisible(false) }
    }

    private func resize(by delta: CGFloat) {
        RemoteTree.width = widthConstraint.constant + delta
        widthConstraint.constant = RemoteTree.width
    }

    // MARK: 右クリック

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard outline.clickedRow >= 0, let node = outline.item(atRow: outline.clickedRow) as? RemoteNode else { return }
        if !node.isDirectory {
            let open = NSMenuItem(title: L("開く"), action: #selector(menuOpen(_:)), keyEquivalent: "")
            open.target = self; open.representedObject = node
            menu.addItem(open)
        } else {
            let reload = NSMenuItem(title: L("再読み込み"), action: #selector(menuReload(_:)), keyEquivalent: "")
            reload.target = self; reload.representedObject = node
            menu.addItem(reload)
        }
        let copy = NSMenuItem(title: L("パスをコピー"), action: #selector(menuCopyPath(_:)), keyEquivalent: "")
        copy.target = self; copy.representedObject = node
        menu.addItem(copy)
    }

    @objc private func menuOpen(_ sender: NSMenuItem) { (sender.representedObject as? RemoteNode).map(open) }
    @objc private func menuReload(_ sender: NSMenuItem) {
        if let n = sender.representedObject as? RemoteNode { load(n, force: true) }
    }
    @objc private func menuCopyPath(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? RemoteNode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(n.path, forType: .string)
    }

    private final class ResizeHandle: NSView {
        let onDrag: (CGFloat) -> Void
        init(_ onDrag: @escaping (CGFloat) -> Void) { self.onDrag = onDrag; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func mouseDragged(with event: NSEvent) { onDrag(event.deltaX) }
        override func mouseDown(with event: NSEvent) {}
    }
}
