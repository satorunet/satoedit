import AppKit
import HinokiCore

/// 設定ウインドウの「追加機能」タブ。
/// システム設定のような 1 行ずつの一覧で、スイッチだけで入れたり外したりできる。
/// 内蔵の機能 (共同編集・サーバ…) と、JS で作られた拡張機能を同じように並べる
final class ExtensionsSettingsPane: NSObject, SettingsPane {
    let title = L("追加機能")
    let view = NSView()

    private let scroll = NSScrollView()
    private let grid = FlippedView()
    private let addButton = NSButton()
    private var popover: NSPopover?

    override init() {
        super.init()
        let heading = NSTextField(labelWithString: L("追加機能"))
        heading.font = .systemFont(ofSize: 17, weight: .bold)
        let sub = SettingsUI.label(L("スイッチを入れると、メニューとボタンに出ます。行を押すと説明が出ます。"), small: true)
        sub.lineBreakMode = .byWordWrapping
        sub.maximumNumberOfLines = 2
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addButton.title = L("＋ 拡張機能を追加")
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addClicked(_:))
        addButton.keyEquivalent = ""

        let titles = NSStackView(views: [heading, sub])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        let top = NSStackView(views: [titles])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 12
        titles.setContentHuggingPriority(.defaultLow, for: .horizontal)
        top.translatesAutoresizingMaskIntoConstraints = false

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = grid
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(top)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            top.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(relayoutNote), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildNote), name: .viewSettingsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildNote), name: .pluginsDidChange, object: nil)
        rebuild()
    }

    func willShow() { rebuild() }
    func willHide() { popover?.close() }

    @objc private func relayoutNote() { relayout() }
    @objc private func rebuildNote() { rebuild() }

    // MARK: 一覧 (システム設定のような、角の丸い枠の中に 1 行ずつ)

    private enum Entry {
        case builtIn(EditorExtension)
        case plugin(Plugin)
        case add
    }

    private struct Section {
        let title: String
        let box: GroupBox
        let rows: [NSView]
    }
    private var sections: [Section] = []
    private var headers: [NSTextField] = []

    private func rebuild() {
        grid.subviews.forEach { $0.removeFromSuperview() }
        headers = []
        let pm = PluginManager.shared
        let builtIn = EditorExtension.displayOrder.map { makeRow(.builtIn($0)) }
        var plugins: [NSView] = pm.plugins.map { makeRow(.plugin($0)) }
        // 枠のいちばん下: 「＋ 拡張機能を追加…」(入っていないときは、その横に案内も)
        let add = NSButton(title: L("＋ 拡張機能を追加…"), target: self, action: #selector(addClicked(_:)))
        add.bezelStyle = .rounded
        add.controlSize = .regular
        add.bezelColor = .controlAccentColor
        var addViews: [NSView] = [add]
        if plugins.isEmpty {
            let empty = NSTextField(labelWithString: L("まだありません。URL・フォルダ・zip から入れたり、自分で作ったりできます。"))
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            empty.lineBreakMode = .byTruncatingTail
            addViews.append(empty)
        }
        let addRow = NSStackView(views: addViews)
        addRow.spacing = 10
        plugins.append(PaddedRow(addRow))
        sections = [
            Section(title: L("内蔵の機能"), box: GroupBox(), rows: builtIn),
            Section(title: L("JS 拡張機能 ({0})", pm.plugins.count), box: GroupBox(), rows: plugins),
        ]
        for s in sections {
            let h = NSTextField(labelWithString: s.title)
            h.font = .systemFont(ofSize: 11, weight: .semibold)
            h.textColor = .secondaryLabelColor
            headers.append(h)
            grid.addSubview(h)
            grid.addSubview(s.box)
            s.rows.forEach { s.box.addSubview($0) }
        }
        relayout()
    }

    private static let rowHeight: CGFloat = 44

    private func relayout() {
        let width = max(300, scroll.contentView.bounds.width)
        let inset: CGFloat = 16
        let boxWidth = width - inset * 2
        var y: CGFloat = 2
        for (i, s) in sections.enumerated() {
            let h = headers[i]
            h.sizeToFit()
            h.frame.origin = NSPoint(x: inset + 4, y: y)
            y += h.frame.height + 4
            let height = CGFloat(s.rows.count) * Self.rowHeight
            s.box.frame = NSRect(x: inset, y: y, width: boxWidth, height: height)
            s.box.separators = max(0, s.rows.count - 1)
            s.box.rowHeight = Self.rowHeight
            for (k, r) in s.rows.enumerated() {
                r.frame = NSRect(x: 0, y: CGFloat(k) * Self.rowHeight, width: boxWidth, height: Self.rowHeight)
            }
            y += height + 16
        }
        grid.frame = NSRect(x: 0, y: 0, width: width, height: max(y, scroll.contentView.bounds.height))
    }

    private func makeRow(_ e: Entry) -> NSView {
        switch e {
        case .builtIn(let ext):
            let r = AppRow(icon: ext.icon, image: nil, name: ext.title, summary: ext.summary)
            r.setSwitch(ext.isOn) { [weak self] on in self?.setBuiltIn(ext, on) }
            if ext.isOn, ext.hasDetailSettings {
                r.setGear(L("詳細設定…")) { ext.openDetailSettings() }
            }
            r.onClick = { [weak self, weak r] in
                guard let r = r else { return }
                self?.showDetail(of: .builtIn(ext), from: r)
            }
            return r
        case .plugin(let p):
            let pm = PluginManager.shared
            let on = pm.isEnabled(p)
            var summary = p.manifest.description
            if let err = p.loadError { summary = "⚠︎ " + err }
            let r = AppRow(icon: pm.iconText(p), image: pm.iconImage(p), name: p.manifest.name, summary: summary)
            r.setSwitch(on) { on in pm.setEnabled(p, on) }
            var items: [(String, () -> Void)] = []
            items.append((L("読み直す"), { pm.reload(p) }))
            if let src = pm.source(of: p), src.hasPrefix("http") || src.hasPrefix("github.com") {
                items.append((L("新しい版を取ってくる"), { [weak self] in pm.update(p, window: self?.view.window) }))
            }
            items.append((L("フォルダを Finder で表示"), { pm.revealFolder(p) }))
            items.append((L("main.js を開く"), {
                NSDocumentController.shared.openDocument(withContentsOf: p.folder.appendingPathComponent(p.manifest.main), display: true) { _, _, _ in }
            }))
            items.append((L("外す (ゴミ箱へ)…"), { [weak self] in self?.remove(p) }))
            r.setMenu(items)
            r.onClick = { [weak self, weak r] in
                guard let r = r else { return }
                self?.showDetail(of: .plugin(p), from: r)
            }
            return r
        case .add:
            return NSView()
        }
    }

    // MARK: 操作

    private func setBuiltIn(_ e: EditorExtension, _ on: Bool) {
        e.set(on) // オンにするときの説明で「やめる」を押したら、スイッチは戻す (rebuild で)
        SettingsWindowController.shared.refreshTabs()
        rebuild()
    }

    private func remove(_ p: Plugin) {
        _ = PluginManager.shared.uninstall(p)
        rebuild()
    }

    @objc private func addClicked(_ sender: NSButton) {
        addMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private func addMenu() -> NSMenu {
        let m = NSMenu()
        func item(_ title: String, _ action: Selector) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            m.addItem(i)
        }
        item(L("URL から入れる (GitHub など)…"), #selector(installFromURL))
        item(L("フォルダ・zip から入れる…"), #selector(installFromFile))
        m.addItem(.separator())
        item(L("自分で作る (ひな形を作る)…"), #selector(createTemplate))
        item(L("作り方 (API の説明) を見る"), #selector(openDocs))
        item(L("拡張機能のフォルダを開く"), #selector(openFolder))
        return m
    }

    @objc private func installFromURL() {
        let a = NSAlert()
        a.messageText = L("URL から拡張機能を入れる")
        a.informativeText = L("GitHub のリポジトリの URL か、zip の URL を貼ってください。")
        let field = NSTextField(string: "")
        field.placeholderString = "https://github.com/user/plugin"
        field.frame = NSRect(x: 0, y: 0, width: 380, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: L("入れる"))
        a.addButton(withTitle: L("やめる"))
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        PluginManager.shared.install(fromURLText: field.stringValue, window: view.window) { [weak self] _ in self?.rebuild() }
    }

    @objc private func installFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedFileTypes = ["zip"]
        panel.message = L("拡張機能のフォルダ (manifest.json が入ったもの) か zip を選んでください")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        PluginManager.shared.install(from: url, source: nil, window: view.window)
        rebuild()
    }

    @objc private func createTemplate() { PluginManager.shared.createTemplate(window: view.window) }
    @objc private func openDocs() { PluginManager.shared.openDocs() }
    @objc private func openFolder() { PluginManager.shared.revealFolder() }

    // MARK: 説明 (カードを押したとき)

    private func showDetail(of e: Entry, from card: NSView) {
        popover?.close()
        let vc = NSViewController()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        func text(_ s: String, size: CGFloat = 12, bold: Bool = false, gray: Bool = false) -> NSTextField {
            let f = NSTextField(wrappingLabelWithString: s)
            f.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
            if gray { f.textColor = .secondaryLabelColor }
            f.preferredMaxLayoutWidth = 440
            f.isSelectable = true
            return f
        }
        switch e {
        case .builtIn(let ext):
            stack.addArrangedSubview(text("\(ext.icon)  \(ext.title)", size: 16, bold: true))
            stack.addArrangedSubview(text(ext.summary))
            stack.addArrangedSubview(ext.diagram(width: 440))
            if ext.isOn, ext.hasDetailSettings {
                let b = NSButton(title: L("詳細設定…"), target: nil, action: nil)
                b.bezelStyle = .rounded
                let handler = ClosureTarget { [weak self] in self?.popover?.close(); ext.openDetailSettings() }
                b.target = handler
                b.action = #selector(ClosureTarget.fire)
                objc_setAssociatedObject(b, &ClosureTarget.key, handler, .OBJC_ASSOCIATION_RETAIN)
                stack.addArrangedSubview(b)
            }
        case .plugin(let p):
            let m = p.manifest
            let pm = PluginManager.shared
            stack.addArrangedSubview(text("\(pm.iconText(p))  \(m.name)", size: 16, bold: true))
            if !m.description.isEmpty { stack.addArrangedSubview(text(m.description)) }
            var info = [L("作者: {0}   版: {1}", m.author.isEmpty ? "?" : m.author, m.version)]
            let perms = m.permissions.compactMap { PluginManifest.Permission(rawValue: $0) }.map { PluginManager.permissionText($0) }
            info.append(perms.isEmpty ? L("特別な権限は使いません (文書の読み書きだけ)") : L("使う権限: {0}", perms.joined(separator: "、")))
            if let src = pm.source(of: p) { info.append(L("入れた元: {0}", src)) }
            if let home = m.homepage { info.append(home) }
            stack.addArrangedSubview(text(info.joined(separator: "\n"), size: 11, gray: true))
            let cmds = p.commands.map { "• " + $0.title }
            stack.addArrangedSubview(text(cmds.isEmpty ? L("メニューのコマンドはありません") : L("メニュー「追加機能」に出るコマンド:") + "\n" + cmds.joined(separator: "\n"), size: 11))
            // ログ (console.log・エラー)
            let logView = NSTextView()
            logView.isEditable = false
            logView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            logView.backgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1)
            logView.textColor = NSColor(white: 0.85, alpha: 1)
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            let s = NSMutableAttributedString()
            for line in p.log.suffix(100) {
                s.append(NSAttributedString(string: "\(f.string(from: line.date)) \(line.error ? "✗" : "•") \(line.text)\n", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: line.error ? NSColor(red: 1, green: 0.45, blue: 0.45, alpha: 1) : NSColor(white: 0.85, alpha: 1),
                ]))
            }
            logView.textStorage?.setAttributedString(s)
            let logScroll = NSScrollView()
            logScroll.documentView = logView
            logScroll.hasVerticalScroller = true
            logView.autoresizingMask = [.width]
            logScroll.translatesAutoresizingMaskIntoConstraints = false
            logScroll.widthAnchor.constraint(equalToConstant: 440).isActive = true
            logScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
            stack.addArrangedSubview(text(L("ログ"), size: 11, bold: true))
            stack.addArrangedSubview(logScroll)
            logView.scrollToEndOfDocument(nil)
        case .add:
            return
        }
        vc.view = stack
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = vc
        pop.show(relativeTo: card.bounds, of: card, preferredEdge: .maxX)
        popover = pop
    }
}

/// ボタンの動作をクロージャで書くための小物
final class ClosureTarget: NSObject {
    static var key = 0
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}

/// 角の丸い、少し色の付いた枠 (行と行の間に細い線を引く)
final class GroupBox: NSView {
    override var isFlipped: Bool { true }
    var separators = 0 { didSet { needsDisplay = true } }
    var rowHeight: CGFloat = 44 { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.035)).setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        for i in 0..<separators {
            NSRect(x: 12, y: CGFloat(i + 1) * rowHeight - 0.5, width: bounds.width - 24, height: 1).fill()
        }
    }
}

/// 文字だけの行 (「まだありません」など)
final class PaddedRow: NSView {
    init(_ content: NSView) {
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// 一覧の 1 行: [スイッチ] [⚙] [⋯] [絵] 名前 / ひとこと説明 ……
final class AppRow: NSView {
    var onClick: (() -> Void)?
    /// 絵の左の位置 (スイッチ + ⚙ + ⋯ の列のあと)
    static let iconX: CGFloat = 70

    private let toggle = NSSwitch()
    private var toggleAction: ((Bool) -> Void)?
    private let gear = NSButton()
    private var gearAction: (() -> Void)?
    private let more = NSButton()
    private var menuItems: [(String, () -> Void)] = []
    private var hovering = false

    init(icon: String, image: NSImage?, name: String, summary: String) {
        super.init(frame: .zero)
        wantsLayer = true

        let iconBox = BubbleView()
        iconBox.wantsLayer = true
        iconBox.layer?.cornerRadius = 7
        iconBox.fill = NSColor.controlAccentColor.withAlphaComponent(0.16)
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        if let image = image {
            let iv = NSImageView(image: image)
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.translatesAutoresizingMaskIntoConstraints = false
            iconBox.addSubview(iv)
            NSLayoutConstraint.activate([
                iv.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor), iv.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 20), iv.heightAnchor.constraint(equalToConstant: 20),
            ])
        } else {
            let t = NSTextField(labelWithString: icon)
            t.font = .systemFont(ofSize: 16)
            t.alignment = .center
            t.translatesAutoresizingMaskIntoConstraints = false
            iconBox.addSubview(t)
            NSLayoutConstraint.activate([t.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor), t.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor)])
        }

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        let summaryLabel = NSTextField(labelWithString: summary)
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.toolTip = summary
        let texts = NSStackView(views: [nameLabel, summaryLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        texts.translatesAutoresizingMaskIntoConstraints = false
        texts.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        summaryLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        for (b, symbol, tip, action) in [(gear, "gearshape", L("詳細設定…"), #selector(gearClicked)),
                                        (more, "ellipsis.circle", L("そのほかの操作"), #selector(moreClicked))] {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.isBordered = false
            b.contentTintColor = .secondaryLabelColor
            b.toolTip = tip
            b.target = self
            b.action = action
            b.isHidden = true
        }
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggled)
        // 左端にまとめる: [スイッチ] と、小さなボタン 1 つ (内蔵は ⚙、JS 拡張は ⋯。どちらか片方だけ)
        for b in [gear, more] {
            b.imageScaling = .scaleProportionallyDown
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 14).isActive = true
            b.heightAnchor.constraint(equalToConstant: 14).isActive = true
            b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        }
        let controls = NSStackView(views: [toggle, gear, more])
        controls.spacing = 4
        controls.setContentHuggingPriority(.required, for: .horizontal)
        controls.setContentCompressionResistancePriority(.required, for: .horizontal)
        controls.translatesAutoresizingMaskIntoConstraints = false

        for v in [iconBox, texts, controls] as [NSView] { addSubview(v) }
        // [スイッチ ⚙ ⋯] [絵] 名前 / 説明 ……… (説明は右端まで目いっぱい使う)
        // スイッチ・ボタンの列は幅をそろえて、行ごとに絵と名前の位置がずれないようにする
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor),
            // ふだんは決まった位置 (行ごとにそろう)。スイッチが大きくて重なるときだけ右へずらす
            { let c = iconBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.iconX); c.priority = .defaultHigh; return c }(),
            iconBox.leadingAnchor.constraint(greaterThanOrEqualTo: controls.trailingAnchor, constant: 6),
            iconBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconBox.widthAnchor.constraint(equalToConstant: 28),
            iconBox.heightAnchor.constraint(equalToConstant: 28),
            texts.leadingAnchor.constraint(equalTo: iconBox.trailingAnchor, constant: 12),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
            texts.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSwitch(_ on: Bool, action: @escaping (Bool) -> Void) {
        toggle.state = on ? .on : .off
        toggleAction = action
    }

    func setGear(_ tip: String, action: @escaping () -> Void) {
        gear.toolTip = tip
        gear.isHidden = false
        gearAction = action
    }

    func setMenu(_ items: [(String, () -> Void)]) {
        menuItems = items
        more.isHidden = items.isEmpty
    }

    @objc private func toggled() { toggleAction?(toggle.state == .on) }
    @objc private func gearClicked() { gearAction?() }

    @objc private func moreClicked() {
        let m = NSMenu()
        for (i, it) in menuItems.enumerated() {
            let item = NSMenuItem(title: it.0, action: #selector(menuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            m.addItem(item)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 2), in: more)
    }

    @objc private func menuPicked(_ sender: NSMenuItem) {
        guard menuItems.indices.contains(sender.tag) else { return }
        menuItems[sender.tag].1()
    }

    // 行のどこを押しても (スイッチ・ボタン以外) 説明を出す
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.labelColor.withAlphaComponent(0.04).setFill()
        bounds.fill()
    }
}
