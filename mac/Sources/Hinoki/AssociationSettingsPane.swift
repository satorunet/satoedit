import AppKit
import HinokiCore
import UniformTypeIdentifiers

/// Finder の右クリックメニュー (サービス / クイックアクション) から呼ばれる処理。
/// 秀丸の「送る」メニューにあたる。Info.plist の NSServices と対になっている。
final class FinderServices: NSObject {
    static let shared = FinderServices()

    /// (メニュー名, メッセージ名, 説明)
    static let services: [(title: String, message: String, label: String)] = [
        (L("satoEditで開く"), "openFilesService", L("ファイルを右クリック →「satoEditで開く」")),
        (L("satoEditで grep"), "grepFolderService", L("フォルダを右クリック →「satoEditで grep」")),
    ]

    private func fileURLs(_ pboard: NSPasteboard) -> [URL] {
        (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    @objc func openFilesService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        NSApp.activate(ignoringOtherApps: true)
        for url in fileURLs(pboard) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, err in
                if let err = err { NSApp.presentError(err) }
            }
        }
    }

    @objc func grepFolderService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        NSApp.activate(ignoringOtherApps: true)
        guard let url = fileURLs(pboard).first else { return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        GrepWindowController.shared.show(seedText: nil, folder: isDir.boolValue ? url : url.deletingLastPathComponent())
    }

    // MARK: 右クリックメニューに出す/出さない (システム設定 > キーボード > サービス と同じ設定)

    private static func statusKey(_ s: (title: String, message: String, label: String)) -> String {
        "\(Bundle.main.bundleIdentifier ?? "net.satoru.satoruEditor") - \(s.title) - \(s.message)"
    }

    private static var pbs: UserDefaults? { UserDefaults(suiteName: "pbs") }

    static func isEnabled(_ index: Int) -> Bool {
        let status = pbs?.dictionary(forKey: "NSServicesStatus") ?? [:]
        guard let entry = status[statusKey(services[index])] as? [String: Any] else { return true } // 未設定なら出る
        return (entry["enabled_context_menu"] as? Bool) ?? true
    }

    static func setEnabled(_ index: Int, _ on: Bool) {
        guard let pbs = pbs else { return }
        var status = pbs.dictionary(forKey: "NSServicesStatus") ?? [:]
        status[statusKey(services[index])] = [
            "enabled_context_menu": on,
            "enabled_services_menu": on,
            "presentation_modes": ["ContextMenu": on, "ServicesMenu": on, "TouchBar": false],
        ]
        pbs.set(status, forKey: "NSServicesStatus")
        pbs.synchronize()
        refreshSystem()
    }

    /// サービスの一覧をシステムに読み直させる
    static func refreshSystem() {
        NSUpdateDynamicServices()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
        p.arguments = ["-update"]
        try? p.run()
    }
}

/// 設定ウインドウの「関連付け」タブ
final class AssociationSettingsPane: NSObject, SettingsPane, NSTableViewDataSource, NSTableViewDelegate {
    let title = L("関連付け")
    let view = NSView()

    static let defaultExtensions = [
        "txt", "text", "log", "md", "markdown", "csv", "tsv", "ini", "conf", "cfg", "toml", "env",
        "json", "yaml", "yml", "xml", "html", "htm", "css", "js", "ts", "jsx", "tsx",
        "swift", "py", "rb", "php", "go", "rs", "c", "h", "cpp", "hpp", "m", "java", "kt",
        "sh", "zsh", "bash", "bat", "sql",
    ]

    private let table = NSTableView()
    private var extensions: [String] = []
    private var serviceChecks: [NSButton] = []
    private let addField = NSTextField()
    private let locationLabel = SettingsUI.label("", small: true)

    private var bundleID: String { Bundle.main.bundleIdentifier ?? "net.satoru.satoruEditor" }

    override init() {
        super.init()
        extensions = UserDefaults.standard.stringArray(forKey: "associationExtensions") ?? Self.defaultExtensions

        let cols: [(String, String, CGFloat)] = [("on", L("satoEditで開く"), 90), ("ext", L("拡張子"), 110), ("app", L("いま開くアプリ"), 330)]
        for (id, title, w) in cols {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = w
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        let list = SettingsUI.scrolled(table)
        list.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        addField.placeholderString = L("拡張子 (例: vue)")
        addField.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let assocButtons = SettingsUI.row([
            SettingsUI.button(L("すべてsatoEditで開く"), self, #selector(associateAll(_:))),
            SettingsUI.button(L("すべて元に戻す"), self, #selector(releaseAll(_:))),
            NSView(),
            addField,
            SettingsUI.button(L("追加"), self, #selector(addExtension(_:))),
            SettingsUI.button(L("一覧から外す"), self, #selector(removeExtension(_:))),
        ])
        let assocInner = NSStackView(views: [list, assocButtons,
            SettingsUI.label(L("チェックした拡張子は、ダブルクリックでsatoEditが開きます。"), small: true)])
        assocInner.orientation = .vertical
        assocInner.alignment = .leading
        for v in [list, assocButtons] { v.widthAnchor.constraint(equalTo: assocInner.widthAnchor).isActive = true }
        let assocBox = SettingsUI.box(L("関連付け"), assocInner, fillWidth: true)

        var serviceViews: [NSView] = []
        for (i, s) in FinderServices.services.enumerated() {
            let b = NSButton(checkboxWithTitle: s.label, target: self, action: #selector(serviceChanged(_:)))
            b.tag = i
            serviceChecks.append(b)
            serviceViews.append(b)
        }
        serviceViews.append(SettingsUI.label(L("出ないときは右クリックの「サービス」の中にあります。"), small: true))
        let install = SettingsUI.button(L("アプリケーションフォルダに入れる"), self, #selector(installToApplications(_:)))
        serviceViews.append(SettingsUI.row([install, locationLabel]))
        locationLabel.lineBreakMode = .byTruncatingMiddle
        locationLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        locationLabel.toolTip = Bundle.main.bundleURL.path
        let sendInner = NSStackView(views: serviceViews)
        sendInner.orientation = .vertical
        sendInner.alignment = .leading
        sendInner.spacing = 6
        let sendBox = SettingsUI.box(L("送る (Finder の右クリックメニュー)"), sendInner)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        let stack = SettingsUI.fill(view, with: [assocBox, sendBox, spacer])
        for b in [assocBox, sendBox] {
            b.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        refresh()
    }

    func willShow() { refresh() }

    private func refresh() {
        table.reloadData()
        for (i, b) in serviceChecks.enumerated() { b.state = FinderServices.isEnabled(i) ? .on : .off }
        let path = Bundle.main.bundleURL.path
        locationLabel.stringValue = path.hasPrefix("/Applications/") ? L("アプリケーションフォルダに入っています") : L("アプリケーションフォルダに入れると安定します")
    }

    // MARK: 関連付けの読み書き

    /// 識別子を変えたとき (起動したとき 1 回だけ): 前の識別子のアプリで開くようにしてあった拡張子を、いまのアプリに付け替える
    static func migrateHandlers(from oldIDs: [String]) {
        let key = "associationMigratedToSatoruEditor"
        guard let current = Bundle.main.bundleIdentifier, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let olds = Set(oldIDs.map { $0.lowercased() })
        let exts = UserDefaults.standard.stringArray(forKey: "associationExtensions") ?? defaultExtensions
        for ext in exts {
            guard let t = UTType(filenameExtension: ext),
                  let cur = LSCopyDefaultRoleHandlerForContentType(t.identifier as CFString, .all)?.takeRetainedValue() as String?,
                  olds.contains(cur.lowercased()) else { continue }
            LSSetDefaultRoleHandlerForContentType(t.identifier as CFString, .all, current as CFString)
        }
    }

    private func type(for ext: String) -> UTType? { UTType(filenameExtension: ext) }

    private func handler(for ext: String) -> String? {
        guard let t = type(for: ext) else { return nil }
        return LSCopyDefaultRoleHandlerForContentType(t.identifier as CFString, .all)?.takeRetainedValue() as String?
    }

    private func appName(_ id: String?) -> String {
        guard let id = id else { return L("(なし)") }
        if id.lowercased() == bundleID.lowercased() { return MainMenu.appName }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func isOurs(_ ext: String) -> Bool { handler(for: ext)?.lowercased() == bundleID.lowercased() }

    private var previous: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "associationPrevious") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "associationPrevious") }
    }

    private func associate(_ ext: String, _ on: Bool) {
        guard let t = type(for: ext) else { return }
        if on {
            if let cur = handler(for: ext), cur.lowercased() != bundleID.lowercased() {
                var p = previous
                p[ext] = cur
                previous = p
            }
            LSSetDefaultRoleHandlerForContentType(t.identifier as CFString, .all, bundleID as CFString)
        } else {
            let back = previous[ext] ?? "com.apple.TextEdit"
            LSSetDefaultRoleHandlerForContentType(t.identifier as CFString, .all, back as CFString)
            var p = previous
            p.removeValue(forKey: ext)
            previous = p
        }
    }

    // MARK: 表

    func numberOfRows(in tableView: NSTableView) -> Int { extensions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let ext = extensions[row]
        switch tableColumn?.identifier.rawValue {
        case "on":
            let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRow(_:)))
            b.state = isOurs(ext) ? .on : .off
            b.tag = row
            return b
        case "ext":
            return NSTextField(labelWithString: "." + ext)
        default:
            return NSTextField(labelWithString: appName(handler(for: ext)))
        }
    }

    // MARK: 操作

    @objc private func toggleRow(_ sender: NSButton) {
        guard sender.tag < extensions.count else { return }
        associate(extensions[sender.tag], sender.state == .on)
        // Launch Services への反映に少しかかる
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.table.reloadData() }
    }

    @objc private func associateAll(_ sender: Any?) {
        extensions.forEach { associate($0, true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.table.reloadData() }
    }

    @objc private func releaseAll(_ sender: Any?) {
        extensions.filter { isOurs($0) }.forEach { associate($0, false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.table.reloadData() }
    }

    @objc private func addExtension(_ sender: Any?) {
        let ext = addField.stringValue.trimmingCharacters(in: CharacterSet(charactersIn: " .*")).lowercased()
        guard !ext.isEmpty, !extensions.contains(ext) else { NSSound.beep(); return }
        extensions.append(ext)
        UserDefaults.standard.set(extensions, forKey: "associationExtensions")
        addField.stringValue = ""
        table.reloadData()
        table.scrollRowToVisible(extensions.count - 1)
    }

    @objc private func removeExtension(_ sender: Any?) {
        let row = table.selectedRow
        guard row >= 0, row < extensions.count else { NSSound.beep(); return }
        extensions.remove(at: row)
        UserDefaults.standard.set(extensions, forKey: "associationExtensions")
        table.reloadData()
    }

    @objc private func serviceChanged(_ sender: NSButton) {
        FinderServices.setEnabled(sender.tag, sender.state == .on)
    }

    /// いま動いているアプリを /Applications にコピーして登録する
    @objc private func installToApplications(_ sender: Any?) {
        let src = Bundle.main.bundleURL
        let dst = URL(fileURLWithPath: "/Applications").appendingPathComponent(src.lastPathComponent)
        guard src.standardizedFileURL != dst.standardizedFileURL else {
            NSSound.beep()
            return
        }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
            LSRegisterURL(dst as CFURL, true)
            FinderServices.refreshSystem()
            let alert = NSAlert()
            alert.messageText = L("{0} に入れました", dst.path)
            alert.informativeText = L("次からはこちらを起動してください。")
            alert.addButton(withTitle: L("いま入れたほうで起動し直す"))
            alert.addButton(withTitle: L("あとで"))
            if alert.runModal() == .alertFirstButtonReturn {
                let config = NSWorkspace.OpenConfiguration()
                config.createsNewApplicationInstance = true
                NSWorkspace.shared.openApplication(at: dst, configuration: config) { _, _ in
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
            }
        } catch {
            NSApp.presentError(error)
        }
    }
}
