import AppKit

/// 「サーバ」ウインドウ: 登録したサーバにつないで中を見て回り、ファイルを開いて編集する
final class ServerExplorerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static let shared = ServerExplorerWindowController()

    private var servers: [RemoteServer] = RemoteServerStore.servers
    private let serverTable = NSTableView()
    private let fileTable = NSTableView()
    private let pathField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "サーバをダブルクリックで接続")
    private let spinner = NSProgressIndicator()
    private let autoUpload = NSButton(checkboxWithTitle: "編集をすぐサーバに反映する",
                                      target: nil, action: nil)

    private var client: RemoteClient?
    private var currentPath = "/"
    private var entries: [RemoteEntry] = []
    private var busy = false {
        didSet { busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil) }
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.title = "サーバ (SFTP / FTP)"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 360)
        super.init(window: window)
        window.delegate = self
        build(in: window)
        window.center()
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
        col.title = "サーバ"
        serverTable.addTableColumn(col)
        serverTable.headerView = nil
        serverTable.dataSource = self
        serverTable.delegate = self
        serverTable.target = self
        serverTable.doubleAction = #selector(connect(_:))
        let serverScroll = SettingsUI.scrolled(serverTable)
        serverScroll.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let serverButtons = SettingsUI.row([
            SettingsUI.button("追加", self, #selector(addServer(_:))),
            SettingsUI.button("編集", self, #selector(editServer(_:))),
            SettingsUI.button("削除", self, #selector(removeServer(_:))),
        ], spacing: 4)
        let connectButton = SettingsUI.button("接続", self, #selector(connect(_:)))
        let left = NSStackView(views: [serverScroll, serverButtons, connectButton])
        left.orientation = .vertical
        left.alignment = .leading

        // 右: ファイル一覧
        for (id, title, w) in [("name", "名前", 300.0), ("size", "サイズ", 90.0), ("date", "更新日時", 130.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = CGFloat(w)
            fileTable.addTableColumn(c)
        }
        fileTable.dataSource = self
        fileTable.delegate = self
        fileTable.target = self
        fileTable.doubleAction = #selector(openItem(_:))
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
            SettingsUI.button("↑ 上へ", self, #selector(goUp(_:))),
            SettingsUI.button("⌂", self, #selector(goHome(_:))),
            pathField,
            SettingsUI.button("更新", self, #selector(refresh(_:))),
            SettingsUI.button("新規ファイル…", self, #selector(newFile(_:))),
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

        let content = window.contentView ?? NSView()
        for v in [left, right] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            left.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            left.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 12),
            right.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
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
            return NSTextField(labelWithString: e.date)
        default:
            let icon = e.isDirectory ? "📁 " : (e.isLink ? "🔗 " : "📄 ")
            let f = NSTextField(labelWithString: icon + e.name)
            f.lineBreakMode = .byTruncatingMiddle
            return f
        }
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
        alert.messageText = "「\(s.displayName)」を一覧から削除しますか？"
        alert.informativeText = "サーバ上のファイルは消えません。"
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "やめる")
        alert.beginSheetModal(for: window) { [weak self] r in
            guard let self = self, r == .alertFirstButtonReturn else { return }
            s.secret = nil
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
        host.placeholderString = "example.com または 192.168.1.10"
        let port = NSTextField(string: String(server.port))
        let user = NSTextField(string: server.user)
        let auth = NSPopUpButton()
        auth.addItems(withTitles: ["パスワード", "鍵ファイル (SFTP)"])
        auth.selectItem(at: server.auth == .key ? 1 : 0)
        let password = NSSecureTextField(string: isNew ? "" : (server.secret ?? ""))
        password.placeholderString = "パスワード / 鍵のパスフレーズ (なければ空)"
        let key = NSTextField(string: server.keyPath)
        key.placeholderString = "~/.ssh/id_ed25519"
        let chooser = KeyChooser(field: key)
        let choose = NSButton(title: "選択…", target: chooser, action: #selector(KeyChooser.choose(_:)))
        let initial = NSTextField(string: server.initialPath)
        initial.placeholderString = "空ならログインした場所 (例: /var/www/html)"
        let kindWatcher = KindWatcher(kind: kind, port: port)
        kind.target = kindWatcher
        kind.action = #selector(KindWatcher.changed(_:))

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "名前"), name],
            [NSTextField(labelWithString: "種類"), kind],
            [NSTextField(labelWithString: "ホスト"), host],
            [NSTextField(labelWithString: "ポート"), port],
            [NSTextField(labelWithString: "ユーザー"), user],
            [NSTextField(labelWithString: "ログイン方法"), auth],
            [NSTextField(labelWithString: "パスワード"), password],
            [NSTextField(labelWithString: "鍵ファイル"), SettingsUI.row([key, choose], spacing: 4)],
            [NSTextField(labelWithString: "最初のフォルダ"), initial],
        ])
        grid.rowSpacing = 6
        grid.column(at: 0).xPlacement = .trailing
        for f in [name, host, user, password, key, initial] { f.widthAnchor.constraint(equalToConstant: 260).isActive = true }
        key.widthAnchor.constraint(equalToConstant: 190).isActive = true
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)

        let alert = NSAlert()
        alert.messageText = isNew ? "サーバを追加" : "サーバの設定"
        alert.informativeText = "パスワードはキーチェーンに保存されます。"
        alert.accessoryView = grid
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
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
        let s = servers[row]
        guard !s.host.isEmpty, !s.user.isEmpty else {
            status("ホストとユーザーを設定してください")
            return
        }
        client = RemoteClient(server: s)
        entries = []
        fileTable.reloadData()
        status("\(s.displayName) に接続しています…")
        busy = true
        client?.home { [weak self] r in
            guard let self = self else { return }
            switch r {
            case .success(let path): self.load(path)
            case .failure(let e): self.fail(e)
            }
        }
    }

    private func load(_ path: String) {
        guard let client = client else { return }
        busy = true
        status("\(path) を読み込んでいます…")
        client.list(path) { [weak self] r in
            guard let self = self else { return }
            self.busy = false
            switch r {
            case .success(let list):
                self.currentPath = path
                self.pathField.stringValue = path
                self.entries = list
                self.fileTable.reloadData()
                self.status("\(client.server.displayName): \(path)  (\(list.count) 項目)")
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
        let local = RemoteDocuments.localURL(server: client.server, path: path)
        busy = true
        status("\(path) を取ってきています…")
        client.download(path, to: local) { [weak self] r in
            guard let self = self else { return }
            self.busy = false
            switch r {
            case .success:
                self.status("\(path) を開きました。保存するとサーバに送ります。")
                RemoteDocuments.open(local: local, server: client.server, path: path)
            case .failure(let e):
                self.fail(e)
            }
        }
    }

    @objc private func newFile(_ sender: Any?) {
        guard let client = client, let window = window else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "新しいファイル"
        alert.informativeText = "\(currentPath) に作ります"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "index.html"
        alert.accessoryView = field
        alert.addButton(withTitle: "作る")
        alert.addButton(withTitle: "やめる")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] r in
            guard let self = self, r == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains("/") else { return }
            let path = self.join(self.currentPath, name)
            let local = RemoteDocuments.localURL(server: client.server, path: path)
            try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: local.path, contents: Data())
            self.busy = true
            client.upload(local, to: path) { [weak self] r in
                guard let self = self else { return }
                self.busy = false
                switch r {
                case .success:
                    self.load(self.currentPath)
                    RemoteDocuments.open(local: local, server: client.server, path: path)
                case .failure(let e): self.fail(e)
                }
            }
        }
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
        status("エラー: " + e.localizedDescription.components(separatedBy: "\n").first!)
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = "サーバとのやりとりに失敗しました"
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
        panel.message = "秘密鍵のファイル (id_ed25519 など、.pub ではないほう) を選んでください"
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
    /// 手元のコピーの置き場所 (~/Library/Caches/…/remote/<サーバ>/<パス>)
    static func localURL(server: RemoteServer, path: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let base = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "satoru-editor")
            .appendingPathComponent("remote").appendingPathComponent(server.id)
        return path.split(separator: "/").reduce(base) { $0.appendingPathComponent(String($1)) }
    }

    static func open(local: URL, server: RemoteServer, path: String) {
        // すでに開いていれば読み直す
        if let doc = NSDocumentController.shared.document(for: local) as? Document {
            try? doc.revert(toContentsOf: local, ofType: doc.fileType ?? DocumentController.textType)
            doc.remote = Document.RemoteOrigin(server: server, path: path)
            doc.showWindows()
            return
        }
        NSDocumentController.shared.openDocument(withContentsOf: local, display: true) { doc, _, error in
            if let error = error { NSApp.presentError(error); return }
            guard let doc = doc as? Document else { return }
            doc.remote = Document.RemoteOrigin(server: server, path: path)
            doc.editor?.remoteStatusChanged("サーバ: \(server.displayName) \(path)")
        }
    }
}
