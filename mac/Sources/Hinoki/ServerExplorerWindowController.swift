import AppKit
import HinokiCore

/// 「サーバ」ウインドウ: 登録したサーバにつないで中を見て回り、ファイルを開いて編集する
final class ServerExplorerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSMenuDelegate {
    static let shared = ServerExplorerWindowController()

    private var servers: [RemoteServer] = RemoteServerStore.servers
    private let serverTable = NSTableView()
    private let fileTable = NSTableView()
    private let pathField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: L("サーバをダブルクリックで接続"))
    private let spinner = NSProgressIndicator()
    /// お気に入り・最近の場所 (押すとメニュー)
    private lazy var placesButton: NSButton = {
        let b = NSButton(title: "★", target: self, action: #selector(showPlaces(_:)))
        b.bezelStyle = .rounded
        b.toolTip = L("お気に入り・最近見た場所へ一発で行く")
        return b
    }()
    private let autoUpload = NSButton(checkboxWithTitle: L("編集をすぐサーバに反映する"),
                                      target: nil, action: nil)

    private var client: RemoteClient? {
        didSet { placesList.serverID = client?.server.id ?? selectedServer?.id }
    }
    private let placesList = RemotePlacesListView()

    private var selectedServer: RemoteServer? {
        let row = serverTable.selectedRow
        return row >= 0 && row < servers.count ? servers[row] : nil
    }
    private var currentPath = "/"
    private var entries: [RemoteEntry] = []
    private var busy = false {
        didSet { busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil) }
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.title = L("サーバ (SFTP / FTP)")
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 380)
        super.init(window: window)
        window.delegate = self
        build(in: window)
        window.center()
        // ファイルの状態が変わったら色を塗り直す。送り終えたら大きさ・日時も新しくする
        NotificationCenter.default.addObserver(forName: RemoteDocuments.stateChanged, object: nil, queue: .main) { [weak self] n in
            guard let self = self, let client = self.client, n.userInfo?["server"] as? String == client.server.id,
                  let path = n.userInfo?["path"] as? String else { return }
            guard (path as NSString).deletingLastPathComponent == self.currentPath
                    || ((path as NSString).deletingLastPathComponent.isEmpty && self.currentPath == "/") else { return }
            if case .uploaded = RemoteDocuments.state(serverID: client.server.id, path: path), !self.busy {
                self.load(self.currentPath)
            } else {
                self.fileTable.reloadData()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 拡張機能を切ったとき (まだ作っていなければ何もしない)
    static func closeIfOpen() {
        NSApp.windows.filter { $0.windowController is ServerExplorerWindowController }.forEach { $0.close() }
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 機能をオンにした直後: ウインドウを出し、まだ 1 つも登録がなければサーバの設定画面も開く
    func showForSetup() {
        show()
        if servers.isEmpty && window?.attachedSheet == nil { addServer(nil) }
    }

    // MARK: 画面

    private func build(in window: NSWindow) {
        // 左: サーバ一覧
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("server"))
        col.title = L("サーバ")
        serverTable.addTableColumn(col)
        serverTable.headerView = nil
        serverTable.dataSource = self
        serverTable.delegate = self
        serverTable.target = self
        serverTable.doubleAction = #selector(connect(_:))
        let serverScroll = SettingsUI.scrolled(serverTable)
        serverScroll.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let serverButtons = SettingsUI.row([
            SettingsUI.button(L("追加"), self, #selector(addServer(_:))),
            SettingsUI.button(L("編集"), self, #selector(editServer(_:))),
            SettingsUI.button(L("削除"), self, #selector(removeServer(_:))),
        ], spacing: 4)
        let connectButton = SettingsUI.button(L("接続"), self, #selector(connect(_:)))
        let left = NSStackView(views: [serverScroll, serverButtons, connectButton])
        left.orientation = .vertical
        left.alignment = .leading

        // 右: ファイル一覧
        for (id, title, w) in [("name", L("名前"), 300.0), ("size", L("サイズ"), 90.0), ("date", L("更新日時"), 160.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = CGFloat(w)
            fileTable.addTableColumn(c)
        }
        fileTable.dataSource = self
        fileTable.delegate = self
        fileTable.target = self
        fileTable.doubleAction = #selector(openItem(_:))
        let rowMenu = NSMenu()
        rowMenu.delegate = self
        fileTable.menu = rowMenu
        fileTable.usesAlternatingRowBackgroundColors = true
        fileTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let fileScroll = SettingsUI.scrolled(fileTable)

        pathField.target = self
        pathField.action = #selector(goToPath(_:))
        pathField.placeholderString = "/path/to/folder"
        pathField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let nav = SettingsUI.row([
            SettingsUI.button(L("↑ 上へ"), self, #selector(goUp(_:))),
            SettingsUI.button("⌂", self, #selector(goHome(_:))),
            placesButton,
            pathField,
            SettingsUI.button(L("更新"), self, #selector(refresh(_:))),
            SettingsUI.button(L("新規ファイル…"), self, #selector(newFile(_:))),
            spinner,
        ], spacing: 4)
        nav.alignment = .centerY

        autoUpload.target = self
        autoUpload.action = #selector(autoUploadChanged(_:))
        autoUpload.state = UserDefaults.standard.bool(forKey: "remoteAutoUpload") ? .on : .off
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.textColor = .secondaryLabelColor

        let right = NSStackView(views: [nav, fileScroll, autoUpload, statusLabel])
        right.orientation = .vertical
        right.alignment = .leading
        for v in [nav, fileScroll, statusLabel] { v.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true }
        statusLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        // 右: お気に入り・最近の場所 (常に出しておく)
        placesList.onPick = { [weak self] place in
            guard let self = self else { return }
            let server = self.client?.server ?? self.selectedServer
            if let s = server { self.connect(to: s, goTo: place) }
        }
        let placesTitle = NSTextField(labelWithString: L("お気に入り・履歴"))
        placesTitle.font = .boldSystemFont(ofSize: 12)
        let side = NSStackView(views: [placesTitle, placesList])
        side.orientation = .vertical
        side.alignment = .leading
        placesList.widthAnchor.constraint(equalTo: side.widthAnchor).isActive = true

        let content = window.contentView ?? NSView()
        for v in [left, right, side] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            left.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            left.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 12),
            right.trailingAnchor.constraint(equalTo: side.leadingAnchor, constant: -12),
            side.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            side.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            side.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            side.widthAnchor.constraint(equalToConstant: 220),
            right.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            right.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            serverScroll.heightAnchor.constraint(equalTo: left.heightAnchor, constant: -64),
            left.widthAnchor.constraint(equalToConstant: 200),
        ])
        fileScroll.setContentHuggingPriority(.init(1), for: .vertical)
    }

    // MARK: 表

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === serverTable ? servers.count : entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === serverTable {
            let s = servers[row]
            let f = NSTextField(labelWithString: "\(s.displayName)  [\(s.kind.rawValue.uppercased())]")
            f.lineBreakMode = .byTruncatingTail
            return f
        }
        let e = entries[row]
        switch tableColumn?.identifier.rawValue {
        case "size":
            return NSTextField(labelWithString: e.isDirectory ? "" : ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))
        case "date":
            return NSTextField(labelWithString: e.displayDate())
        default:
            let icon = e.isDirectory ? "📁 " : (e.isLink ? "🔗 " : "📄 ")
            // このアプリで開いた・書き換えた・送ったファイルは色を変えて、状態を後ろに添える
            let st = client.flatMap { RemoteDocuments.state(serverID: $0.server.id, path: join(currentPath, e.name)) }
            let mark = st.map { $0.mark } ?? ""
            let f = NSTextField(labelWithString: icon + e.name + (mark.isEmpty ? "" : "  (\(mark))"))
            f.lineBreakMode = .byTruncatingMiddle
            if let c = st?.color {
                f.textColor = c
                f.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            }
            guard st?.inProgress == true else { return f }
            // やりとりの途中: 名前の前でぐるぐる回す
            return RemoteDocuments.spinnerRow(f)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === serverTable, client == nil else { return }
        placesList.serverID = selectedServer?.id
    }

    // MARK: サーバの登録

    private func saveServers() {
        RemoteServerStore.servers = servers
        serverTable.reloadData()
    }

    @objc private func addServer(_ sender: Any?) {
        var s = RemoteServer()
        s.user = NSUserName()
        edit(s, isNew: true)
    }

    @objc private func editServer(_ sender: Any?) {
        let row = serverTable.selectedRow
        guard row >= 0, row < servers.count else { NSSound.beep(); return }
        edit(servers[row], isNew: false)
    }

    @objc private func removeServer(_ sender: Any?) {
        let row = serverTable.selectedRow
        guard row >= 0, row < servers.count, let window = window else { NSSound.beep(); return }
        let s = servers[row]
        let alert = NSAlert()
        alert.messageText = L("「{0}」を一覧から削除しますか？", s.displayName)
        alert.informativeText = L("サーバ上のファイルは消えません。")
        alert.addButton(withTitle: L("削除"))
        alert.addButton(withTitle: L("やめる"))
        alert.beginSheetModal(for: window) { [weak self] r in
            guard let self = self, r == .alertFirstButtonReturn else { return }
            s.secret = nil
            RemotePlaces.forget(s.id)
            self.servers.remove(at: row)
            self.saveServers()
        }
    }

    /// サーバの設定画面
    private func edit(_ server: RemoteServer, isNew: Bool) {
        guard let window = window else { return }
        let name = NSTextField(string: server.name)
        let kind = NSPopUpButton()
        RemoteServer.Kind.allCases.forEach { kind.addItem(withTitle: $0.label) }
        kind.selectItem(at: RemoteServer.Kind.allCases.firstIndex(of: server.kind) ?? 0)
        let host = NSTextField(string: server.host)
        host.placeholderString = L("example.com または 192.168.1.10")
        let port = NSTextField(string: String(server.port))
        let user = NSTextField(string: server.user)
        let auth = NSPopUpButton()
        auth.addItems(withTitles: [L("パスワード"), L("鍵ファイル (SFTP)")])
        auth.selectItem(at: server.auth == .key ? 1 : 0)
        let password = NSSecureTextField(string: isNew ? "" : (server.secret ?? ""))
        password.placeholderString = L("パスワード / 鍵のパスフレーズ (なければ空)")
        let key = NSTextField(string: server.keyPath)
        key.placeholderString = "~/.ssh/id_ed25519"
        let chooser = KeyChooser(field: key)
        let choose = NSButton(title: L("選択…"), target: chooser, action: #selector(KeyChooser.choose(_:)))
        let initial = NSTextField(string: server.initialPath)
        initial.placeholderString = L("空ならログインした場所 (例: /var/www/html)")
        let kindWatcher = KindWatcher(kind: kind, port: port)
        kind.target = kindWatcher
        kind.action = #selector(KindWatcher.changed(_:))

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: L("名前")), name],
            [NSTextField(labelWithString: L("種類")), kind],
            [NSTextField(labelWithString: L("ホスト")), host],
            [NSTextField(labelWithString: L("ポート")), port],
            [NSTextField(labelWithString: L("ユーザー")), user],
            [NSTextField(labelWithString: L("ログイン方法")), auth],
            [NSTextField(labelWithString: L("パスワード")), password],
            [NSTextField(labelWithString: L("鍵ファイル")), SettingsUI.row([key, choose], spacing: 4)],
            [NSTextField(labelWithString: L("最初のフォルダ")), initial],
        ])
        grid.rowSpacing = 6
        grid.column(at: 0).xPlacement = .trailing
        for f in [name, host, user, password, key, initial] { f.widthAnchor.constraint(equalToConstant: 260).isActive = true }
        key.widthAnchor.constraint(equalToConstant: 190).isActive = true
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)

        let alert = NSAlert()
        alert.messageText = isNew ? L("サーバを追加") : L("サーバの設定")
        alert.informativeText = L("パスワードはキーチェーンに保存されます。")
        alert.accessoryView = grid
        alert.addButton(withTitle: L("保存"))
        alert.addButton(withTitle: L("キャンセル"))
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] r in
            _ = chooser; _ = kindWatcher // シートが閉じるまで保持
            guard let self = self, r == .alertFirstButtonReturn else { return }
            var s = server
            s.name = name.stringValue.trimmingCharacters(in: .whitespaces)
            s.kind = RemoteServer.Kind.allCases[max(0, kind.indexOfSelectedItem)]
            s.host = host.stringValue.trimmingCharacters(in: .whitespaces)
            s.port = Int(port.stringValue.trimmingCharacters(in: .whitespaces)) ?? s.kind.defaultPort
            s.user = user.stringValue.trimmingCharacters(in: .whitespaces)
            s.auth = auth.indexOfSelectedItem == 1 ? .key : .password
            s.keyPath = key.stringValue.trimmingCharacters(in: .whitespaces)
            s.initialPath = initial.stringValue.trimmingCharacters(in: .whitespaces)
            s.secret = password.stringValue
            if let i = self.servers.firstIndex(where: { $0.id == s.id }) {
                self.servers[i] = s
            } else {
                self.servers.append(s)
            }
            self.saveServers()
            if let i = self.servers.firstIndex(where: { $0.id == s.id }) {
                self.serverTable.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
            }
        }
    }

    // MARK: 接続と移動

    @objc private func connect(_ sender: Any?) {
        let row = serverTable.selectedRow
        guard row >= 0, row < servers.count else { NSSound.beep(); return }
        connect(to: servers[row], goTo: nil)
    }

    /// つなぐ。goTo があればホームではなくそこを開く (ファイルならそれを開いて、一覧はその親)
    private func connect(to s: RemoteServer, goTo place: RemotePlaces.Place?) {
        guard !s.host.isEmpty, !s.user.isEmpty else {
            status(L("ホストとユーザーを設定してください"))
            return
        }
        if let i = servers.firstIndex(where: { $0.id == s.id }) {
            serverTable.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        }
        // もうつながっていれば、そのまま移動
        if let c = client, c.server == s, let place = place {
            return go(to: place)
        }
        client = RemoteClient(server: s)
        // エディタ横のツリーも同じサーバにする (出すかどうかはそのまま)
        if RemoteTree.server?.id != s.id { RemoteTree.setServer(s, show: false) }
        entries = []
        fileTable.reloadData()
        status(L("{0} に接続しています…", s.displayName))
        busy = true
        if let place = place { busy = false; return go(to: place) }
        client?.home { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let path): self.load(path)
            case .failure(let e): self.fail(e)
            }
        }
    }

    private func go(to place: RemotePlaces.Place) {
        if place.isFile {
            let parent = (place.path as NSString).deletingLastPathComponent
            load(parent.isEmpty ? "/" : parent)
            openFile(place.path)
        } else {
            load(place.path)
        }
    }

    /// ★: お気に入り・最近の場所。つないでいなければ、選んでいるサーバのものを出す
    @objc private func showPlaces(_ sender: NSButton) {
        let server: RemoteServer? = client?.server ?? {
            let row = serverTable.selectedRow
            return row >= 0 && row < servers.count ? servers[row] : nil
        }()
        guard let s = server else { status(L("サーバを選んでください")); NSSound.beep(); return }
        let menu = RemotePlaces.menu(serverID: s.id, currentFolder: client?.server == s ? currentPath : nil) { [weak self] place in
            self?.connect(to: s, goTo: place)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private func load(_ path: String) {
        guard let client = client else { return }
        busy = true
        status(L("{0} を読み込んでいます…", path))
        client.list(path) { [weak self] r in
            guard let self = self else { return }
            self.busy = false
            switch r {
            case .success(let list):
                self.currentPath = path
                self.pathField.stringValue = path
                self.entries = list
                self.fileTable.reloadData()
                RemotePlaces.visitFolder(client.server.id, path)
                self.placesList.currentFolder = path
                // エディタ横のツリーでも、この一覧を読み直さずに使う
                RemoteTree.cache[RemoteTree.cacheKey(client.server.id, path)] = list
                self.status(L("{0}: {1}  ({2} 項目)", client.server.displayName, path, list.count))
            case .failure(let e):
                self.fail(e)
            }
        }
    }

    private func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    @objc private func goUp(_ sender: Any?) {
        guard client != nil else { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        load(parent.isEmpty ? "/" : parent)
    }

    @objc private func goHome(_ sender: Any?) {
        guard let client = client else { return }
        client.home { [weak self] r in
            if case .success(let p) = r { self?.load(p) }
        }
    }

    @objc private func goToPath(_ sender: Any?) {
        let p = pathField.stringValue.trimmingCharacters(in: .whitespaces)
        guard client != nil, !p.isEmpty else { return }
        load(p)
    }

    @objc private func refresh(_ sender: Any?) {
        guard client != nil else { connect(nil); return }
        load(currentPath)
    }

    @objc private func openItem(_ sender: Any?) {
        let row = fileTable.clickedRow >= 0 ? fileTable.clickedRow : fileTable.selectedRow
        guard row >= 0, row < entries.count else { return }
        let e = entries[row]
        let path = join(currentPath, e.name)
        if e.isDirectory {
            load(path)
        } else if e.isLink {
            // リンク先がフォルダならフォルダとして、だめならファイルとして開く
            client?.list(path) { [weak self] r in
                if case .success = r { self?.load(path) } else { self?.openFile(path) }
            }
        } else {
            openFile(path)
        }
    }

    /// サーバのファイルを手元にコピーして開く。保存するとサーバへ送り返す
    private func openFile(_ path: String) {
        guard let client = client else { return }
        // エディタ横のサーバツリーは、いまこの窓で見ているフォルダから出す (開いたファイルが選ばれる)
        let folder = (path as NSString).deletingLastPathComponent
        RemoteTree.rootPath[client.server.id] = folder.isEmpty ? "/" : folder
        RemoteTree.scrollY[client.server.id] = 0
        if RemoteTree.server?.id != client.server.id { RemoteTree.setServer(client.server, show: false) }
        busy = true
        status(L("{0} を取ってきています…", path))
        RemoteDocuments.fetchAndOpen(client: client, path: path, toastWindow: window) { [weak self] e in
            guard let self = self else { return }
            self.busy = false
            if let e = e { self.fail(e) } else { self.status(L("{0} を開きました。保存するとサーバに送ります。", path)) }
        }
    }

    @objc private func newFile(_ sender: Any?) {
        guard let client = client, let window = window else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = L("新しいファイル")
        alert.informativeText = L("{0} に作ります", currentPath)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "index.html"
        alert.accessoryView = field
        alert.addButton(withTitle: L("作る"))
        alert.addButton(withTitle: L("やめる"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] r in
            guard let self = self, r == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains("/") else { return }
            let path = self.join(self.currentPath, name)
            let local = RemoteDocuments.makeTempURL(for: path)
            FileManager.default.createFile(atPath: local.path, contents: Data())
            self.busy = true
            client.upload(local, to: path) { [weak self] r in
                guard let self = self else { return }
                self.busy = false
                switch r {
                case .success:
                    self.load(self.currentPath)
                    RemoteDocuments.open(local: local, server: client.server, path: path)
                case .failure(let e):
                    RemoteDocuments.removeTemp(local)
                    self.fail(e)
                }
            }
        }
    }

    // MARK: 右クリック (お気に入り)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = fileTable.clickedRow
        guard let client = client, row >= 0, row < entries.count else { return }
        let e = entries[row]
        let path = join(currentPath, e.name)
        let fav = RemotePlaces.isFavorite(client.server.id, path)
        let item = NSMenuItem(title: fav ? L("お気に入りから外す") : L("お気に入りに入れる"),
                              action: #selector(toggleFavoriteRow(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = RemotePlaces.Place(path: path, isFile: !e.isDirectory) as Any
        item.image = NSImage(systemSymbolName: fav ? "star.slash" : "star", accessibilityDescription: nil)
        menu.addItem(item)
    }

    @objc private func toggleFavoriteRow(_ sender: NSMenuItem) {
        guard let client = client, let p = sender.representedObject as? RemotePlaces.Place else { return }
        RemotePlaces.toggleFavorite(client.server.id, p)
        status(RemotePlaces.isFavorite(client.server.id, p.path) ? L("お気に入りに入れました: {0}", p.path) : L("お気に入りから外しました: {0}", p.path))
    }

    @objc private func autoUploadChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "remoteAutoUpload")
    }

    private func status(_ s: String) {
        statusLabel.stringValue = s
        statusLabel.toolTip = s
    }

    private func fail(_ e: Error) {
        busy = false
        status(L("エラー: ") + e.localizedDescription.components(separatedBy: "\n").first!)
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = L("サーバとのやりとりに失敗しました")
        alert.informativeText = e.localizedDescription
        alert.beginSheetModal(for: window)
    }
}

/// 鍵ファイルの選択ボタン用
private final class KeyChooser: NSObject {
    let field: NSTextField
    init(field: NSTextField) { self.field = field }

    @objc func choose(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        panel.message = L("秘密鍵のファイル (id_ed25519 など、.pub ではないほう) を選んでください")
        if panel.runModal() == .OK, let url = panel.url { field.stringValue = url.path }
    }
}

/// 種類を変えたらポートの既定値も変える
private final class KindWatcher: NSObject {
    let kind: NSPopUpButton
    let port: NSTextField
    init(kind: NSPopUpButton, port: NSTextField) { self.kind = kind; self.port = port }

    @objc func changed(_ sender: Any?) {
        let k = RemoteServer.Kind.allCases[max(0, kind.indexOfSelectedItem)]
        if ["21", "22", ""].contains(port.stringValue) { port.stringValue = String(k.defaultPort) }
    }
}

/// サーバから開いたファイルの管理
enum RemoteDocuments {
    /// サーバのファイルの、このアプリでの状態 (一覧やツリーの色分けに使う)
    enum State: Equatable {
        case opened            // 開いただけ
        case downloading       // サーバから取ってきている
        case editing           // 書き換えたが、まだサーバに送っていない
        case uploading         // 送信中
        case uploaded(Date)    // 送った
        case failed            // 送れなかった

        var color: NSColor? {
            switch self {
            case .opened: return RemoteDocuments.purple
            case .downloading: return RemoteDocuments.blue
            case .editing: return RemoteDocuments.orange
            case .uploading: return RemoteDocuments.blue
            case .uploaded: return RemoteDocuments.green
            case .failed: return RemoteDocuments.red
            }
        }
        /// ぐるぐるを出す (やりとりの途中)
        var inProgress: Bool { self == .downloading || self == .uploading }

        var mark: String {
            switch self {
            case .opened: return L("タブで開き中")
            case .downloading: return L("受信中")
            case .editing: return L("編集中")
            case .uploading: return L("送信中")
            case .uploaded(let d):
                let f = DateFormatter(); f.dateFormat = "HH:mm"
                return L("更新 {0}", f.string(from: d))
            case .failed: return L("送信失敗")
            }
        }
    }

    // 状態の色: 白地でも読める濃さ (明るい表示では濃く、暗い表示では明るく。白地とのコントラスト 4.5:1 以上)
    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        func c(_ h: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? c(dark) : c(light)
        }
    }
    static let green = dynamic(light: 0x1A7F37, dark: 0x5AD487)
    static let orange = dynamic(light: 0xB35900, dark: 0xFFA94D)
    static let blue = dynamic(light: 0x0B5CD5, dark: 0x6CB6FF)
    static let red = dynamic(light: 0xC62828, dark: 0xFF6B6B)
    static let purple = dynamic(light: 0x7B3FC4, dark: 0xC49BFF)

    static let stateChanged = Notification.Name("RemoteDocumentsStateChanged")

    /// 文字の前に、回っているぐるぐるを付けた行
    static func spinnerRow(_ label: NSTextField) -> NSView {
        let spin = NSProgressIndicator()
        spin.style = .spinning
        spin.controlSize = .small
        spin.startAnimation(nil)
        spin.setAccessibilityLabel(L("やりとり中"))
        let row = NSStackView(views: [spin, label])
        row.spacing = 4
        spin.widthAnchor.constraint(equalToConstant: 14).isActive = true
        spin.heightAnchor.constraint(equalToConstant: 14).isActive = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }
    private static var states: [String: State] = [:]
    private static func key(_ serverID: String, _ path: String) -> String { serverID + "\n" + path }

    static func state(serverID: String, path: String) -> State? { states[key(serverID, path)] }

    /// 状態を消す (タブを閉じて、何もしていないファイル)
    static func clearState(server: RemoteServer, path: String) {
        guard states.removeValue(forKey: key(server.id, path)) != nil else { return }
        NotificationCenter.default.post(name: stateChanged, object: nil, userInfo: ["server": server.id, "path": path])
    }

    static func setState(_ s: State, server: RemoteServer, path: String) {
        let k = key(server.id, path)
        guard states[k] != s else { return }
        states[k] = s
        NotificationCenter.default.post(name: stateChanged, object: nil,
                                        userInfo: ["server": server.id, "path": path])
    }

    /// サーバ上の大きさと日時を一行で
    static func describe(_ e: RemoteEntry?) -> String {
        guard let e = e else { return "" }
        return L("サーバ上: {0} · {1}", ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file), e.displayDate())
    }

    // MARK: 手元の一時ファイル
    // サーバのファイルは、開くたびに別の一時フォルダ (…/satoruEditor-remote/<ランダム>/<ファイル名>) に取ってくる。
    // 同じ名前のファイルや、前に開いたコピーとぶつからない。タブを閉じたら消す。起動時に残りも消す。

    /// 送信中に閉じたタブの一時ファイル (送り終えたら消す)
    static var removeAfterUpload: Set<URL> = []

    static var tempRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("satoruEditor-remote", isDirectory: true)
    }

    /// 新しい一時ファイルの場所 (ファイル名はサーバと同じにして、言語の判定やタイトルに使う)
    static func makeTempURL(for path: String) -> URL {
        let name = (path as NSString).lastPathComponent
        let dir = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent(name.isEmpty ? "file" : name)
    }

    /// 一時ファイルを、入れてあるフォルダごと消す (一時フォルダの外のファイルには触らない)
    static func removeTemp(_ url: URL?) {
        guard let url = url else { return }
        let dir = url.deletingLastPathComponent().resolvingSymlinksInPath()
        guard dir.deletingLastPathComponent().path == tempRoot.resolvingSymlinksInPath().path else { return }
        if (try? FileManager.default.removeItem(at: dir)) != nil {
            RemoteLog.add(L("手元の一時ファイルを消しました: {0}", url.lastPathComponent))
        }
    }

    /// 起動したとき: 前回の残り (落ちたときなど) をまとめて消す
    static func removeLeftovers() {
        // 開いているタブが使っているものは残す
        let inUse = Set(NSDocumentController.shared.documents.compactMap { $0.fileURL?.deletingLastPathComponent().resolvingSymlinksInPath().path })
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: nil)) ?? []
            where !inUse.contains(dir.resolvingSymlinksInPath().path) {
            try? fm.removeItem(at: dir)
        }
        // 前の版の置き場所も片付ける
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "satoru-editor")
            .appendingPathComponent("remote"))
    }

    /// このサーバのファイルをもう開いているタブ
    static func openDocument(server: RemoteServer, path: String) -> Document? {
        NSDocumentController.shared.documents.compactMap { $0 as? Document }
            .first { $0.remote?.server.id == server.id && $0.remote?.path == path }
    }

    /// サーバから取ってきてエディタで開く。接続と結果をトーストで知らせる
    /// - Parameter toastWindow: 取ってくるあいだの「接続中」を出す窓 (なければ出さない)
    static func fetchAndOpen(client: RemoteClient, path: String, toastWindow: NSWindow?,
                             _ done: ((Error?) -> Void)? = nil) {
        // 開いていて書き換え途中なら、取り直して上書きせずにそのタブを出す
        if let doc = openDocument(server: client.server, path: path), doc.isDocumentEdited {
            doc.showWindows()
            doc.editor?.focusEditor()
            Toast.show(in: doc.editor?.presentingWindow, key: "remote", kind: .info, title: L("編集中のタブを出しました"),
                       detail: L("保存していない変更があるので、サーバから取り直していません。") + "\n" + path)
            done?(nil)
            return
        }
        let local = makeTempURL(for: path)
        let started = Date()
        let before = state(serverID: client.server.id, path: path)
        setState(.downloading, server: client.server, path: path)
        let toastKey = "fetch:" + client.server.id + path
        Toast.show(in: toastWindow, key: toastKey, kind: .progress,
                   title: L("{0} を読み込んでいます…", (path as NSString).lastPathComponent),
                   detail: L("接続: {0}", client.connectionText))
        client.download(path, to: local) { r in
            switch r {
            case .success:
                RemotePlaces.visitFile(client.server.id, path)
                let secs = Date().timeIntervalSince(started)
                Toast.show(in: toastWindow, key: toastKey, kind: .success, title: L("読み込みました"),
                           detail: path)
                client.stat(path) { entry in
                    open(local: local, server: client.server, path: path) { doc in
                        var lines = [L("接続: {0}", client.connectionText), path]
                        let info = describe(entry)
                        if !info.isEmpty { lines.append(info) }
                        lines.append(L("{0} 秒で取得。保存するとサーバへ送ります。", String(format: "%.1f", secs)))
                        Toast.show(in: doc.editor?.presentingWindow, key: "remote", kind: .success,
                                   title: L("サーバから読み込みました"), detail: lines.joined(separator: "\n"))
                    }
                }
                done?(nil)
            case .failure(let e):
                if let b = before { setState(b, server: client.server, path: path) } else { clearState(server: client.server, path: path) }
                removeTemp(local)
                Toast.show(in: toastWindow, key: toastKey, kind: .failure,
                           title: L("{0} を読み込めませんでした", (path as NSString).lastPathComponent),
                           detail: L("接続: {0}", client.connectionText) + "\n" + (e.localizedDescription.components(separatedBy: "\n").first ?? ""))
                done?(e)
            }
        }
    }

    static func open(local: URL, server: RemoteServer, path: String, opened: ((Document) -> Void)? = nil) {
        // すでに開いていれば、取り直した一時ファイルに切り替えて、前の一時ファイルは消す
        if let doc = openDocument(server: server, path: path) {
            let old = doc.fileURL
            try? doc.revert(toContentsOf: local, ofType: doc.fileType ?? DocumentController.textType)
            if old?.standardizedFileURL != local.standardizedFileURL { removeTemp(old) }
            doc.remote = Document.RemoteOrigin(server: server, path: path)
            doc.showWindows()
            doc.editor?.focusEditor()
            setState(.opened, server: server, path: path)
            opened?(doc)
            return
        }
        NSDocumentController.shared.openDocument(withContentsOf: local, display: true) { doc, _, error in
            if let error = error { removeTemp(local); NSApp.presentError(error); return }
            // ビューア (画像・バイナリ) で見せたときは、ビューアが閉じるときに消す
            guard let doc = doc as? Document else { clearState(server: server, path: path); return }
            doc.remote = Document.RemoteOrigin(server: server, path: path)
            doc.editor?.remoteStatusChanged(L("サーバ: {0} {1}", server.displayName, path))
            doc.editor?.focusEditor()
            setState(.opened, server: server, path: path)
            opened?(doc)
        }
    }
}
