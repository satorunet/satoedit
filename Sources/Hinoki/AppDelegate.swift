import AppKit
import HinokiCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleExtensionHM(_:)),
           let e = (menuItem.representedObject as? String).flatMap(EditorExtension.init(rawValue:)) {
            // 開いた瞬間に分かるよう、ON / OFF を色つきで頭に出す (title は変えない: キー割り当てが名前で覚えているため)
            menuItem.state = .off
            let t = NSMutableAttributedString()
            t.append(NSAttributedString(string: e.isOn ? "● ON   " : "○ OFF  ", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .bold),
                .foregroundColor: e.isOn ? NSColor.systemGreen : NSColor.secondaryLabelColor,
            ]))
            t.append(NSAttributedString(string: e.title, attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: e.isOn ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]))
            menuItem.attributedTitle = t
            menuItem.toolTip = (e.isOn ? "クリックでオフにします。" : "クリックでオンにします。") + e.summary
        }
        if menuItem.action == #selector(toggleFolderTreeHM(_:)) {
            menuItem.state = FolderTree.isVisible ? .on : .off
        }
        if menuItem.action == #selector(toggleRemoteAutoUploadHM(_:)) {
            menuItem.state = Prefs.bool("remoteAutoUpload") ? .on : .off
        }
        if menuItem.action == #selector(toggleEncryptAlwaysHM(_:)) {
            menuItem.state = Prefs.bool("encryptAlways") ? .on : .off
        }
        if menuItem.action == #selector(joinShareHM(_:)) {
            return Prefs.bool("collabEnabled")
        }
        if menuItem.action == #selector(selectThemePresetHM(_:)) {
            let current = (menuItem.representedObject as? String) == Theme.presetName
            menuItem.state = current ? (Theme.overrides.isEmpty ? .on : .mixed) : .off
        }
        return true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: Prefs.defaults)
    }

    func applicationWillTerminate(_ notification: Notification) {
        for case let doc as Document in NSDocumentController.shared.documents {
            doc.editor?.saveCaretPosition()
        }
    }

    private var currentEditor: EditorWindowController? {
        NSApp.mainWindow?.windowController as? EditorWindowController
    }

    @objc func showFindPanelHM(_ sender: Any?) {
        FindPanelController.shared.show()
    }

    @objc func showReplacePanelHM(_ sender: Any?) { FindPanelController.shared.show(focusReplace: true) }
    @objc func useSelectionForFindHM(_ sender: Any?) { FindPanelController.shared.useSelection() }
    @objc func findNextRegexHM(_ sender: Any?) { FindPanelController.shared.findNext() }
    @objc func findPreviousRegexHM(_ sender: Any?) { FindPanelController.shared.findPrevious() }

    @objc func grepHM(_ sender: Any?) {
        var seed: String?
        if let tv = currentEditor?.textView {
            seed = (tv.string as NSString).substring(with: tv.selectedRange())
        }
        let folder = (currentEditor?.document as? NSDocument)?.fileURL?.deletingLastPathComponent()
        GrepWindowController.shared.show(seedText: seed, folder: folder)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 新しいウインドウは常にタブとして開く
        NSWindow.allowsAutomaticWindowTabbing = true
        // 設定で選んだ色のアイコンにする (Finder 側は選んだときに変えてあるので、ここでは Dock だけ)
        AppIcon.apply(updateFinder: false)
        NSApp.activate(ignoringOtherApps: true)
        // Finder の右クリックメニュー (サービス) から呼ばれる
        NSApp.servicesProvider = FinderServices.shared
        NSUpdateDynamicServices()
        Theme.load()
        if let err = Theme.loadError {
            let alert = NSAlert()
            alert.messageText = "theme.json に問題があります (その項目は既定値を使います)"
            alert.informativeText = err
            alert.runModal()
        }
        if let err = Profiles.store.loadError {
            let alert = NSAlert()
            alert.messageText = "言語プロファイルの読み込みに失敗しました"
            alert.informativeText = err
            alert.runModal()
        }
    }

    /// 書式 > テーマ から切り替え
    @objc func selectThemePresetHM(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let n = Theme.overrides.count
        if n > 0 {
            let alert = NSAlert()
            alert.messageText = "テーマを「\(name)」に切り替えますか？"
            alert.informativeText = "個別に変えた \(n) 項目の色は消えます。"
            alert.addButton(withTitle: "切り替える")
            alert.addButton(withTitle: "やめる")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Theme.selectPreset(name)
    }

    // MARK: 共同編集に参加

    private var joining: CollabSession?
    private var waitingPanel: NSPanel?

    /// 「機能」メニュー: 拡張機能の ON / OFF (オンにするときは説明を出す)
    @objc func toggleExtensionHM(_ sender: NSMenuItem) {
        guard let e = (sender.representedObject as? String).flatMap(EditorExtension.init(rawValue:)) else { return }
        e.set(!e.isOn)
        SettingsWindowController.shared.refreshTabs()
    }

    /// 表示 > フォルダツリー: 左のツリーを出し入れ (フォルダをまだ選んでいなければ選んでもらう)
    @objc func toggleFolderTreeHM(_ sender: Any?) {
        guard EditorExtension.folder.isOn else { NSSound.beep(); return }
        let show = !FolderTree.isVisible
        FolderTree.setVisible(show)
        if show && FolderTree.root == nil { FolderTree.chooseRoot() }
    }

    /// ファイル > フォルダを開く…
    @objc func openFolderHM(_ sender: Any?) {
        guard EditorExtension.folder.isOn else { NSSound.beep(); return }
        FolderTree.chooseRoot()
    }

    @objc func openExtensionsSettingsHM(_ sender: Any?) { SettingsWindowController.shared.show(.extensions) }

    @objc func joinShareHM(_ sender: Any?) {
        guard Prefs.bool("collabEnabled") else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "共同編集に参加"
        alert.informativeText = "聞いたアドレスとコードを入れてください。"
        let addr = NSTextField(string: UserDefaults.standard.string(forKey: "collabLastAddress") ?? "")
        addr.placeholderString = "例: 192.168.1.10:\(CollabSession.defaultPort)"
        let name = NSTextField(string: UserDefaults.standard.string(forKey: "collabName") ?? CollabSession.computerName)
        let codeField = NSTextField(string: "")
        codeField.placeholderString = "例: ABCD-EFGH-JKLM-NPQR"
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "アドレス"), addr],
            [NSTextField(labelWithString: "共有コード"), codeField],
            [NSTextField(labelWithString: "表示名"), name],
        ])
        grid.frame = NSRect(x: 0, y: 0, width: 330, height: 86)
        addr.widthAnchor.constraint(equalToConstant: 240).isActive = true
        alert.accessoryView = grid
        alert.addButton(withTitle: "参加する")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = addr
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // 「アドレス  共有コード: XXXX」をまとめて貼り付けられても分ける
        var text = addr.stringValue.trimmingCharacters(in: .whitespaces)
        var code = codeField.stringValue
        if let r = text.range(of: "共有コード:") {
            if code.trimmingCharacters(in: .whitespaces).isEmpty { code = String(text[r.upperBound...]) }
            text = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        guard CollabCipher.normalize(code).count == 16 else {
            let a = NSAlert()
            a.messageText = "共有コードを入れてください"
            a.informativeText = "例: ABCD-EFGH-JKLM-NPQR"
            a.runModal()
            return
        }
        var host = text
        var port = CollabSession.defaultPort
        if let i = text.lastIndex(of: ":"), let p = UInt16(text[text.index(after: i)...]) {
            host = String(text[..<i])
            port = p
        }
        guard !host.isEmpty else { NSSound.beep(); return }
        let n = name.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? CollabSession.computerName : name.stringValue
        UserDefaults.standard.set(text, forKey: "collabLastAddress")
        UserDefaults.standard.set(n, forKey: "collabName")

        let session = CollabSession.join(host: host, port: port, name: n, code: code)
        joining = session
        showWaiting("\(host):\(port) に接続しています。相手が承認するのを待っています…")
        session.onWelcome = { [weak self] text, title in
            self?.closeWaiting()
            let doc = Document()
            doc.text = text
            NSDocumentController.shared.addDocument(doc)
            doc.makeWindowControllers()
            doc.showWindows()
            doc.displayName = "共有: " + (title.isEmpty ? host : title)
            doc.editor?.attachCollab(session)
            self?.joining = nil
        }
        session.onJoinFailed = { [weak self] reason in
            self?.closeWaiting()
            self?.joining = nil
            let a = NSAlert()
            a.messageText = "参加できませんでした"
            a.informativeText = reason
            a.runModal()
        }
    }

    private func showWaiting(_ message: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 110),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "共同編集に参加"
        let label = NSTextField(wrappingLabelWithString: message)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let cancel = NSButton(title: "やめる", target: self, action: #selector(cancelJoin(_:)))
        cancel.bezelStyle = .rounded
        let row = NSStackView(views: [spinner, label])
        row.alignment = .top
        let stack = NSStackView(views: [row, cancel])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 12, right: 16)
        label.widthAnchor.constraint(equalToConstant: 310).isActive = true
        panel.contentView = stack
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        waitingPanel = panel
    }

    private func closeWaiting() {
        waitingPanel?.orderOut(nil)
        waitingPanel = nil
    }

    @objc private func cancelJoin(_ sender: Any?) {
        joining?.cancelJoin()
        joining = nil
        closeWaiting()
    }

    @objc func importPDFHM(_ sender: Any?) { PDFImport.choose() }
    @objc func openAIUsageHM(_ sender: Any?) { AIUsageWindowController.shared.show() }

    @objc func openAISettingsHM(_ sender: Any?) { SettingsWindowController.shared.show(.ai) }

    @objc func toggleRemoteAutoUploadHM(_ sender: Any?) {
        UserDefaults.standard.set(!Prefs.bool("remoteAutoUpload"), forKey: "remoteAutoUpload")
    }

    @objc func toggleEncryptAlwaysHM(_ sender: Any?) {
        Prefs.set(!Prefs.bool("encryptAlways"), "encryptAlways")
    }

    @objc func openServersHM(_ sender: Any?) {
        ServerExplorerWindowController.shared.show()
    }

    @objc func openThemeHM(_ sender: Any?) { SettingsWindowController.shared.show(.theme) }
    @objc func openSettingsHM(_ sender: Any?) { SettingsWindowController.shared.show() }
    @objc func openGeneralSettingsHM(_ sender: Any?) { SettingsWindowController.shared.show(.general) }
    @objc func openFileTypeSettingsHM(_ sender: Any?) { SettingsWindowController.shared.show(.fileType) }
    @objc func openKeySettingsHM(_ sender: Any?) { SettingsWindowController.shared.show(.keys) }
    @objc func openMenuSettingsHM(_ sender: Any?) { SettingsWindowController.shared.show(.menu) }
    @objc func openAssociationSettingsHM(_ sender: Any?) { SettingsWindowController.shared.show(.association) }
    @objc func exportSettingsHM(_ sender: Any?) { SettingsBackup.exportSettings() }
    @objc func importSettingsHM(_ sender: Any?) { SettingsBackup.importSettings() }

    @objc func openProfilesHM(_ sender: Any?) {
        SettingsWindowController.shared.show(.fileType)
    }
}

/// Info.plist なしでも (swift run でも) どんなファイルでもテキストとして開けるようにする
final class DocumentController: NSDocumentController {
    static let textType = "public.plain-text"

    override var defaultType: String? { Self.textType }

    override func documentClass(forType typeName: String) -> AnyClass? { Document.self }

    override func typeForContents(of url: URL) throws -> String { Self.textType }

    override func runModalOpenPanel(_ openPanel: NSOpenPanel, forTypes types: [String]?) -> Int {
        super.runModalOpenPanel(openPanel, forTypes: nil)
    }

    /// PDF は中の文字を取り出して、新しい (名前のない) 文書として開く。元の PDF は書き換えない
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        guard url.pathExtension.lowercased() == "pdf" else {
            return super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
        }
        do {
            let doc = try PDFImport.openAsText(url)
            completionHandler(doc, false, nil)
        } catch {
            completionHandler(nil, false, error)
        }
    }
}
