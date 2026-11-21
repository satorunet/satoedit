import AppKit
import HinokiCore

/// 設定ウインドウの 1 タブ
protocol SettingsPane: AnyObject {
    var title: String { get }
    var view: NSView { get }
    func willShow()
    func willHide()
}

extension SettingsPane {
    func willShow() {}
    func willHide() {}
}

/// 設定ウインドウ (色・フォント / ファイルタイプ別 / 動作環境 / キー割り当て / メニュー編集)
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTabViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = SettingsWindowController()

    /// タブ (タブの見出しで選ぶ。見出しは日本語の名前を L() に通したもの)
    enum Tab: String {
        case extensions = "追加機能", general = "動作環境", fileType = "ファイルタイプ別の設定", theme = "色・フォント"
        case keys = "キー割り当て", menu = "メニュー編集", association = "関連付け", ai = "AI アシスタント"
        case encryption = "暗号化", paper = "用紙モード", speech = "読み上げ・音声入力", backup = "バックアップ"
    }

    private let tabView = NSTabView()
    private let panes: [SettingsPane]

    // 左の見出しの列: 「基本」と「追加機能」の 2 つに分ける
    private enum SidebarRow {
        case header(String)
        case pane(SettingsPane)
    }
    private var sidebarRows: [SidebarRow] = []
    private let sidebar = NSTableView()
    /// 基本の設定 (いつも出す)
    private static let basicTabs: [Tab] = [.general, .fileType, .theme, .paper, .keys, .menu, .association, .backup]
    /// 追加機能の設定 (その機能を入れているときだけ出す。「追加機能」そのものはいつも)
    private static let extensionTabs: [Tab] = [.extensions, .ai, .encryption, .speech]

    private static func symbol(_ title: String) -> String {
        switch title {
        case L(Tab.general.rawValue): return "gearshape"
        case L(Tab.fileType.rawValue): return "doc.text"
        case L(Tab.theme.rawValue): return "paintpalette"
        case L(Tab.keys.rawValue): return "keyboard"
        case L(Tab.menu.rawValue): return "list.bullet"
        case L(Tab.association.rawValue): return "link"
        case L(Tab.extensions.rawValue): return "puzzlepiece.extension"
        case L(Tab.ai.rawValue): return "sparkles"
        case L(Tab.encryption.rawValue): return "lock"
        case L(Tab.paper.rawValue): return "doc.plaintext"
        case L(Tab.speech.rawValue): return "waveform"
        case L(Tab.backup.rawValue): return "externaldrive.badge.timemachine"
        default: return "circle"
        }
    }

    private init() {
        panes = [GeneralSettingsPane(), FileTypeSettingsPane(), ThemeSettingsPane(),
                 KeyBindingSettingsPane(), MenuSettingsPane(), AssociationSettingsPane(),
                 ExtensionsSettingsPane(), AISettingsPane(), EncryptionSettingsPane(), PaperSettingsPane(), SpeechSettingsPane(), BackupSettingsPane()]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.title = L("設定")
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 520)
        super.init(window: window)
        window.delegate = self

        tabView.delegate = self
        tabView.tabViewType = .noTabsNoBorder // 選ぶのは左の列で
        let col = NSTableColumn(identifier: .init("s"))
        sidebar.addTableColumn(col)
        sidebar.headerView = nil
        sidebar.rowHeight = 26
        sidebar.style = .sourceList
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.backgroundColor = .clear
        let sideScroll = NSScrollView()
        sideScroll.documentView = sidebar
        sideScroll.drawsBackground = false
        sideScroll.hasVerticalScroller = false
        sideScroll.translatesAutoresizingMaskIntoConstraints = false
        let sideBack = NSVisualEffectView()
        sideBack.material = .sidebar
        sideBack.blendingMode = .behindWindow
        sideBack.translatesAutoresizingMaskIntoConstraints = false
        refreshTabs()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        // 下: 設定内容の保存・復元
        let bottom = SettingsUI.row([
            SettingsUI.button(L("設定内容の保存…"), self, #selector(exportSettings(_:))),
            SettingsUI.button(L("設定内容の復元…"), self, #selector(importSettings(_:))),
            NSView(),
            SettingsUI.button(L("すべて初期状態に戻す…"), self, #selector(resetAll(_:))),
        ])
        bottom.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(sideBack)
        content.addSubview(sideScroll)
        content.addSubview(tabView)
        content.addSubview(bottom)
        NSLayoutConstraint.activate([
            sideBack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sideBack.topAnchor.constraint(equalTo: content.topAnchor),
            sideBack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sideBack.widthAnchor.constraint(equalToConstant: 190),
            sideScroll.leadingAnchor.constraint(equalTo: sideBack.leadingAnchor),
            sideScroll.trailingAnchor.constraint(equalTo: sideBack.trailingAnchor),
            sideScroll.topAnchor.constraint(equalTo: sideBack.topAnchor, constant: 8),
            sideScroll.bottomAnchor.constraint(equalTo: sideBack.bottomAnchor, constant: -8),
            tabView.leadingAnchor.constraint(equalTo: sideBack.trailingAnchor, constant: 8),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            bottom.topAnchor.constraint(equalTo: tabView.bottomAnchor, constant: 10),
            bottom.leadingAnchor.constraint(equalTo: sideBack.trailingAnchor, constant: 18),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        window.contentView = content
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 拡張機能を切っているときは、その設定タブも出さない
    private func paneVisible(_ pane: SettingsPane) -> Bool {
        switch pane.title {
        case L(Tab.ai.rawValue): return EditorExtension.ai.isOn
        case L(Tab.encryption.rawValue): return EditorExtension.encryption.isOn
        case L(Tab.speech.rawValue): return EditorExtension.speech.isOn
        default: return true
        }
    }

    func refreshTabs() {
        let wanted = panes.filter(paneVisible)
        let current = tabView.tabViewItems.compactMap { $0.identifier as? String }
        guard current != wanted.map({ $0.title }) else { return }
        let selected = tabView.selectedTabViewItem?.identifier as? String
        tabView.delegate = nil
        tabView.tabViewItems.forEach { tabView.removeTabViewItem($0) }
        for pane in wanted {
            let item = NSTabViewItem(identifier: pane.title)
            item.label = pane.title
            item.view = pane.view
            tabView.addTabViewItem(item)
        }
        if let s = selected, let i = wanted.firstIndex(where: { $0.title == s }) { tabView.selectTabViewItem(at: i) }
        tabView.delegate = self
        rebuildSidebar()
    }

    // MARK: 左の見出しの列

    private func rebuildSidebar() {
        func pane(_ t: Tab) -> SettingsPane? { panes.first { $0.title == L(t.rawValue) }.flatMap { paneVisible($0) ? $0 : nil } }
        var rows: [SidebarRow] = [.header(L("基本"))]
        rows += Self.basicTabs.compactMap(pane).map { .pane($0) }
        rows.append(.header(L("追加機能")))
        rows += Self.extensionTabs.compactMap(pane).map { .pane($0) }
        sidebarRows = rows
        sidebar.reloadData()
        selectSidebarRow()
    }

    /// いま出ている設定の行を選んだ状態にする
    private func selectSidebarRow() {
        guard let id = tabView.selectedTabViewItem?.identifier as? String,
              let i = sidebarRows.firstIndex(where: { if case .pane(let p) = $0 { return p.title == id }; return false }) else { return }
        if sidebar.selectedRow != i { sidebar.selectRowIndexes([i], byExtendingSelection: false) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sidebarRows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = sidebarRows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .pane = sidebarRows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch sidebarRows[row] {
        case .header(let t):
            let f = NSTextField(labelWithString: t)
            f.font = .systemFont(ofSize: 11, weight: .semibold)
            f.textColor = .secondaryLabelColor
            return f
        case .pane(let p):
            let cell = NSTableCellView()
            let iv = NSImageView(image: NSImage(systemSymbolName: Self.symbol(p.title), accessibilityDescription: nil) ?? NSImage())
            iv.contentTintColor = .controlAccentColor
            let tf = NSTextField(labelWithString: p.title)
            tf.font = .systemFont(ofSize: 13)
            tf.lineBreakMode = .byTruncatingTail
            cell.imageView = iv
            cell.textField = tf
            for v in [iv, tf] as [NSView] {
                v.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(v)
            }
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 18),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 7),
                tf.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let r = sidebar.selectedRow
        guard r >= 0, r < sidebarRows.count, case .pane(let p) = sidebarRows[r],
              let i = tabView.tabViewItems.firstIndex(where: { ($0.identifier as? String) == p.title }) else { return }
        if tabView.indexOfTabViewItem(tabView.selectedTabViewItem ?? NSTabViewItem()) != i { tabView.selectTabViewItem(at: i) }
    }

    func show(_ tab: Tab? = nil) {
        refreshTabs()
        if let tab = tab, let i = tabView.tabViewItems.firstIndex(where: { ($0.identifier as? String) == L(tab.rawValue) }) {
            tabView.selectTabViewItem(at: i)
        }
        currentPane?.willShow()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private var currentPane: SettingsPane? {
        guard let id = tabView.selectedTabViewItem?.identifier as? String else { return nil }
        return panes.first { $0.title == id }
    }

    func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        currentPane?.willHide()
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        currentPane?.willShow()
        selectSidebarRow()
    }

    /// 復元・初期化のあと、全タブの表示を作り直す
    func refreshPanes() {
        panes.forEach { $0.willShow() }
    }

    @objc private func exportSettings(_ sender: Any?) { SettingsBackup.exportSettings() }
    @objc private func importSettings(_ sender: Any?) { SettingsBackup.importSettings() }
    @objc private func resetAll(_ sender: Any?) { SettingsBackup.resetAll() }

    func windowWillClose(_ notification: Notification) {
        currentPane?.willHide()
    }
}

// MARK: - 部品

enum SettingsUI {
    static func label(_ s: String, bold: Bool = false, small: Bool = false) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        if bold { f.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
        if small {
            f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            f.textColor = .secondaryLabelColor
        }
        return f
    }

    /// 長い説明: 決まった幅で折り返す (小さな灰色の字)
    static func note(_ s: String, width: CGFloat = 520) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        f.textColor = .secondaryLabelColor
        f.preferredMaxLayoutWidth = width
        f.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }

    static func button(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        return b
    }

    static func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = spacing
        s.alignment = .firstBaseline
        return s
    }

    /// 縦に積んで view いっぱいに置く
    static func fill(_ view: NSView, with views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        return stack
    }

    /// 見出し + 薄い角丸の背景に入れた中身。中身の高さに合わせて伸びる
    static func box(_ title: String, _ content: NSView, fillWidth: Bool = false) -> NSView {
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 6
        panel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.04).cgColor
        panel.layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        panel.layer?.borderWidth = 1
        panel.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            fillWidth ? content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12)
                      : content.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10),
        ])
        let section = NSStackView(views: [label(title, bold: true), panel])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6
        panel.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    /// 表をスクロールビューに入れる
    static func scrolled(_ table: NSTableView) -> NSScrollView {
        let sv = NSScrollView()
        sv.documentView = table
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }
}
