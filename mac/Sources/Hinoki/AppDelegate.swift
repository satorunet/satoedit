import AppKit
import HinokiCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleAutoUpdateHM(_:)) {
            menuItem.state = AppUpdater.shared.automaticChecksOn ? .on : .off
            return AppUpdater.shared.isAvailable
        }
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
            menuItem.toolTip = (e.isOn ? L("クリックでオフにします。") : L("クリックでオンにします。")) + e.summary
        }
        if menuItem.action == #selector(tileWindowsSideBySideHM(_:)) || menuItem.action == #selector(tileWindowsStackedHM(_:)) {
            return WindowTiling.canTile // 文書が 2 つ以上のときだけ
        }
        if menuItem.action == #selector(setDisplayLanguageHM(_:)) {
            menuItem.state = (menuItem.representedObject as? String) == AppLanguage.setting ? .on : .off
        }
        if menuItem.action == #selector(toggleTextLibraryHM(_:)) {
            menuItem.state = TextLibrary.isVisible ? .on : .off
        }
        if menuItem.action == #selector(toggleFolderTreeHM(_:)) {
            menuItem.state = FolderTree.isVisible ? .on : .off
        }
        if menuItem.action == #selector(toggleRemoteTreeHM(_:)) {
            let ed = NSApp.keyWindow?.frontEditor
            menuItem.state = (ed?.remoteTreeShown ?? RemoteTree.isVisible) ? .on : .off
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
        VersionStore.flushAll()   // 待っている版の記録を済ませてから終える
        for case let doc as Document in NSDocumentController.shared.documents {
            doc.editor?.saveCaretPosition()
        }
    }

    private var currentEditor: EditorWindowController? {
        NSApp.mainWindow?.frontEditor
    }

    /// 設定 > 表示の言語 (Language)
    @objc func setDisplayLanguageHM(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        AppLanguage.change(to: id)
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

    // MARK: 割窓 (ウインドウを並べる)

    @objc func tileWindowsSideBySideHM(_ sender: Any?) { WindowTiling.tile(.sideBySide) }
    @objc func tileWindowsStackedHM(_ sender: Any?) { WindowTiling.tile(.stacked) }

    /// 起動したとき (と、ウインドウがないときに Dock から開いたとき) の白紙の表示。
    /// 設定「起動したときの表示」で決める (はじめは標準エディタ)。「前回と同じ」なら最後に使っていた表示
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        guard let doc = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true) else { return false }
        if let editor = doc.windowControllers.first as? EditorWindowController, EditorExtension.paper.isOn {
            let d = UserDefaults.standard
            var mode = d.string(forKey: "startPaperMode") ?? "normal"
            if mode == "last" { mode = d.string(forKey: "lastPaperMode") ?? "normal" }
            switch mode {
            case "normal": break
            case "a4": editor.applyPaperMode(.a4)
            default: editor.applyPaperMode(.genko)
            }
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 新しいウインドウは常にタブとして開く
        NSWindow.allowsAutomaticWindowTabbing = true
        // 設定で選んだ色のアイコンにする (Finder 側は選んだときに変えてあるので、ここでは Dock だけ)
        AppIcon.apply(updateFinder: false)
        AppUpdater.shared.start()   // 自動アップデート (配布用のアプリのときだけ動く)
        TextLibrary.autoICloud()    // iCloud Drive が使えるなら、最初から iCloud にテキストを置く
        NSApp.activate(ignoringOtherApps: true)
        // Finder の右クリックメニュー (サービス) から呼ばれる
        NSApp.servicesProvider = FinderServices.shared
        // テキスト一覧: はじめては「最近使ったファイル」から作る
        TextLibrary.seedFromRecents()
        TextLibrary.dropKnownInsideExternal()
        VersionStore.migrateOld()   // 版の履歴を、前の形 (1 つの大きな記録) からテキストごとの記録に移す
        VersionStore.pruneAll()     // 上限より多い履歴があれば、古いものを消す (上限を下げたあとなど)
        // 識別子を変えたので、前のアプリに結び付けてあった拡張子をこのアプリに付け替える (1 回だけ)
        AssociationSettingsPane.migrateHandlers(from: SettingsMigration.oldDomains)
        // サーバから取ってきた一時ファイルの、前回の残りを消す
        RemoteDocuments.removeLeftovers()
        // JS の拡張機能を読み込む (~/.satoruEditor/plugins)
        PluginManager.shared.loadAll()
        if Mado.isEnabled { Mado.install() }   // 窓割り (タブを並べる) の見張りを始める
        SelfTest.runIfRequested()
        SelfTestMado.runIfRequested()
        SelfTestLatency.runIfRequested()
        NSUpdateDynamicServices()
        AISettings.migrateVerified()
        Theme.load()
        if let err = Theme.loadError {
            let alert = NSAlert()
            alert.messageText = L("theme.json に問題があります (その項目は既定値を使います)")
            alert.informativeText = err
            alert.runModal()
        }
        if let err = Profiles.store.loadError {
            let alert = NSAlert()
            alert.messageText = L("言語プロファイルの読み込みに失敗しました")
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
            alert.messageText = L("テーマを「{0}」に切り替えますか？", L(name))
            alert.informativeText = L("個別に変えた {0} 項目の色は消えます。", n)
            alert.addButton(withTitle: L("切り替える"))
            alert.addButton(withTitle: L("やめる"))
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

    /// 表示 > テキスト一覧: 左の一覧を出し入れ
    @objc func toggleTextLibraryHM(_ sender: Any?) {
        TextLibrary.setVisible(!TextLibrary.isVisible)
    }

    /// 表示 > フォルダツリー: 左のツリーを出し入れ (フォルダをまだ選んでいなければ選んでもらう)
    @objc func toggleFolderTreeHM(_ sender: Any?) {
        guard EditorExtension.folder.isOn else { NSSound.beep(); return }
        let show = !FolderTree.isVisible
        FolderTree.setVisible(show)
        if show && FolderTree.root == nil { FolderTree.chooseRoot() }
    }

    /// サーバ > サーバツリーをエディタの横に出す (サーバ未登録ならサーバウインドウを開く)
    @objc func toggleRemoteTreeHM(_ sender: Any?) {
        guard EditorExtension.server.isOn else { NSSound.beep(); return }
        if RemoteServerStore.servers.isEmpty { ServerExplorerWindowController.shared.show(); return }
        // いまのタブで出ていれば消す (サーバのファイルのタブで自動で出ているときも)
        if let ed = NSApp.keyWindow?.frontEditor, ed.remoteTreeShown {
            ed.dismissRemoteTree()
        } else {
            RemoteTree.setVisible(true)
        }
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
        alert.messageText = L("共同編集に参加")
        alert.informativeText = L("聞いたアドレスとコードを入れてください。")
        let addr = NSTextField(string: UserDefaults.standard.string(forKey: "collabLastAddress") ?? "")
        addr.placeholderString = L("例: 192.168.1.10:{0}", CollabSession.defaultPort)
        let name = NSTextField(string: UserDefaults.standard.string(forKey: "collabName") ?? CollabSession.computerName)
        let codeField = NSTextField(string: "")
        codeField.placeholderString = L("例: ABCD-EFGH-JKLM-NPQR")
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: L("アドレス")), addr],
            [NSTextField(labelWithString: L("共有コード")), codeField],
            [NSTextField(labelWithString: L("表示名")), name],
        ])
        grid.frame = NSRect(x: 0, y: 0, width: 330, height: 86)
        addr.widthAnchor.constraint(equalToConstant: 240).isActive = true
        alert.accessoryView = grid
        alert.addButton(withTitle: L("参加する"))
        alert.addButton(withTitle: L("キャンセル"))
        alert.window.initialFirstResponder = addr
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // 「アドレス  共有コード: XXXX」をまとめて貼り付けられても分ける
        var text = addr.stringValue.trimmingCharacters(in: .whitespaces)
        var code = codeField.stringValue
        if let r = text.range(of: L("共有コード:")) {
            if code.trimmingCharacters(in: .whitespaces).isEmpty { code = String(text[r.upperBound...]) }
            text = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        guard CollabCipher.normalize(code).count == 16 else {
            let a = NSAlert()
            a.messageText = L("共有コードを入れてください")
            a.informativeText = L("例: ABCD-EFGH-JKLM-NPQR")
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
        showWaiting(L("{0}:{1} に接続しています。相手が承認するのを待っています…", host, port))
        session.onWelcome = { [weak self] text, title in
            self?.closeWaiting()
            let doc = Document()
            doc.text = text
            NSDocumentController.shared.addDocument(doc)
            doc.makeWindowControllers()
            doc.showWindows()
            doc.displayName = L("共有: ") + (title.isEmpty ? host : title)
            doc.editor?.attachCollab(session)
            self?.joining = nil
        }
        session.onJoinFailed = { [weak self] reason in
            self?.closeWaiting()
            self?.joining = nil
            let a = NSAlert()
            a.messageText = L("参加できませんでした")
            a.informativeText = reason
            a.runModal()
        }
    }

    private func showWaiting(_ message: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 110),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = L("共同編集に参加")
        let label = NSTextField(wrappingLabelWithString: message)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let cancel = NSButton(title: L("やめる"), target: self, action: #selector(cancelJoin(_:)))
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
    @objc func openPaperSettingsHM(_ sender: Any?) { SettingsWindowController.shared.show(.paper) }
    // 追加機能ごとの設定の画面へ (メニューの「…の設定…」)
    @objc func openEncryptionPrefsHM(_ sender: Any?) { SettingsWindowController.shared.show(.encryption) }
    @objc func openLibraryPrefsHM(_ sender: Any?) { SettingsWindowController.shared.show(.backup) }
    @objc func openPublishPrefsHM(_ sender: Any?) { SettingsWindowController.shared.show(.extensions) }
    @objc func openLocalAIHM(_ sender: Any?) { LocalAIWindowController.shared.show() }

    /// 公式サイト
    static let officialURL = "https://docs.satoru.net"

    /// 「satoEditについて」: 標準の画面に、公式サイトのリンクを足す
    @objc func showAboutHM(_ sender: Any?) {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let credits = NSMutableAttributedString(string: L("公式サイト") + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: center,
        ])
        credits.append(NSAttributedString(string: Self.officialURL, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .link: URL(string: Self.officialURL) as Any, .paragraphStyle: center,
        ]))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }

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
    // 自動アップデート
    @objc func checkForUpdatesHM(_ sender: Any?) { AppUpdater.shared.checkForUpdates(sender) }
    @objc func toggleAutoUpdateHM(_ sender: Any?) { AppUpdater.shared.toggleAutomaticChecks(sender) }
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

    /// サーバの一時ファイルは「最近使った項目」に入れない (閉じたら消えるので)
    override func noteNewRecentDocumentURL(_ url: URL) {
        if url.resolvingSymlinksInPath().path.hasPrefix(RemoteDocuments.tempRoot.resolvingSymlinksInPath().path + "/") { return }
        super.noteNewRecentDocumentURL(url)
        // テキスト一覧 (履歴) には、開いただけでは入れない。書き換えて保存したときに入れる (Document の保存のあと)
    }

    override func runModalOpenPanel(_ openPanel: NSOpenPanel, forTypes types: [String]?) -> Int {
        super.runModalOpenPanel(openPanel, forTypes: nil)
    }

    /// PDF は中の文字を取り出して、新しい (名前のない) 文書として開く。元の PDF は書き換えない
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        guard url.pathExtension.lowercased() == "pdf" else {
            // 画像はかんたんビューア、それ以外のバイナリはバイナリ表示で見せる (エディタでは開かない)
            if displayDocument, document(for: url) == nil, FileViewers.showIfNeeded(url) {
                return completionHandler(nil, false, nil)
            }
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
