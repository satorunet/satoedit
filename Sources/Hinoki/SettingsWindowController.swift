import AppKit

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
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTabViewDelegate {
    static let shared = SettingsWindowController()

    /// タブ (タブの見出しで選ぶ)
    enum Tab: String {
        case extensions = "追加機能", general = "動作環境", fileType = "ファイルタイプ別の設定", theme = "色・フォント"
        case keys = "キー割り当て", menu = "メニュー編集", association = "関連付け", ai = "AI アシスタント"
    }

    private let tabView = NSTabView()
    private let panes: [SettingsPane]

    private init() {
        panes = [GeneralSettingsPane(), FileTypeSettingsPane(), ThemeSettingsPane(),
                 KeyBindingSettingsPane(), MenuSettingsPane(), AssociationSettingsPane(),
                 ExtensionsSettingsPane(), AISettingsPane()]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.title = "設定"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 520)
        super.init(window: window)
        window.delegate = self

        tabView.delegate = self
        refreshTabs()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        // 下: 設定内容の保存・復元
        let bottom = SettingsUI.row([
            SettingsUI.button("設定内容の保存…", self, #selector(exportSettings(_:))),
            SettingsUI.button("設定内容の復元…", self, #selector(importSettings(_:))),
            NSView(),
            SettingsUI.button("すべて初期状態に戻す…", self, #selector(resetAll(_:))),
        ])
        bottom.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(tabView)
        content.addSubview(bottom)
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            bottom.topAnchor.constraint(equalTo: tabView.bottomAnchor, constant: 10),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        window.contentView = content
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 拡張機能を切っているときは、その設定タブも出さない
    private func paneVisible(_ pane: SettingsPane) -> Bool {
        pane.title == Tab.ai.rawValue ? EditorExtension.ai.isOn : true
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
    }

    func show(_ tab: Tab? = nil) {
        refreshTabs()
        if let tab = tab, let i = tabView.tabViewItems.firstIndex(where: { ($0.identifier as? String) == tab.rawValue }) {
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
