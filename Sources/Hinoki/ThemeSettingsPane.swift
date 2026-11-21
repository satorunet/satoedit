import AppKit

/// 設定ウインドウの「色・フォント」タブ。
/// 上のテーマの見本 (小さなエディタ画面) をクリックしてまとめて切り替え、下の色ボタンで 1 項目ずつ変えられる。変更はすぐ全タブに反映。
final class ThemeSettingsPane: NSObject, SettingsPane {
    let title = "色・フォント"
    let view = NSView()

    private lazy var gallery = ThemeGalleryView { [weak self] name in self?.choosePreset(name) }
    private let customLabel = NSTextField(labelWithString: "")
    private let resetAllButton = NSButton(title: "個別の変更をすべて戻す", target: nil, action: nil)
    private let fontLabel = NSTextField(labelWithString: "")
    private let sizeStepper = NSStepper()
    private let windowStylePopup = NSPopUpButton()
    private let iconChooser = AppIconChooserView()
    private var wells: [NSColorWell] = []
    private var labels: [NSTextField] = []
    private var resetButtons: [NSButton] = []
    private var updating = false

    private var window: NSWindow? { view.window }

    override init() {
        super.init()
        buildUI()
        refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange),
                                               name: .themeDidChange, object: nil)
    }

    func willShow() {
        refresh()
        // カラーパネルで透明度も選べるように
        NSColorPanel.shared.showsAlpha = true
    }

    func willHide() {
        wells.forEach { $0.deactivate() }
    }

    // MARK: 画面

    private func buildUI() {
        // テーマ
        resetAllButton.target = self
        resetAllButton.action = #selector(resetAll(_:))
        resetAllButton.bezelStyle = .rounded
        customLabel.textColor = .secondaryLabelColor
        let hint = SettingsUI.label("見本をクリックすると、開いているすべてのタブがすぐ切り替わります", small: true)
        let presetRow = NSStackView(views: [bold("テーマ"), hint, customLabel, NSView(), resetAllButton])
        presetRow.spacing = 10

        // フォント
        let fontButton = NSButton(title: "フォントを選ぶ…", target: self, action: #selector(chooseFont(_:)))
        fontButton.bezelStyle = .rounded
        sizeStepper.minValue = 6
        sizeStepper.maxValue = 72
        sizeStepper.increment = 1
        sizeStepper.valueWraps = false
        sizeStepper.target = self
        sizeStepper.action = #selector(sizeChanged(_:))
        let fontRow = NSStackView(views: [bold("フォント"), fontLabel, sizeStepper, fontButton])
        fontRow.spacing = 10

        // ウインドウ枠
        for w in Theme.windowStyles { windowStylePopup.addItem(withTitle: w.label) }
        windowStylePopup.target = self
        windowStylePopup.action = #selector(windowStyleChanged(_:))
        let styleRow = NSStackView(views: [bold("ウインドウ枠・メニュー"), windowStylePopup])
        styleRow.spacing = 10

        // アプリのアイコン (色ちがい)
        let iconRow = NSStackView(views: [bold("アプリのアイコン"), iconChooser,
                                          SettingsUI.label("Dock と Finder のアイコンが変わります", small: true)])
        iconRow.spacing = 10
        iconRow.isHidden = !AppIcon.isAvailable

        // 色 (2 列)
        let grid = NSGridView()
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        let half = (Theme.entries.count + 1) / 2
        for row in 0..<half {
            var cells: [NSView] = []
            for col in 0..<2 {
                let i = row + col * half
                if i < Theme.entries.count {
                    cells += makeCells(index: i)
                } else {
                    cells += [NSGridCell.emptyContentView, NSGridCell.emptyContentView, NSGridCell.emptyContentView]
                }
                if col == 0 { cells.append(NSGridCell.emptyContentView) }
            }
            grid.addRow(with: cells)
        }
        grid.column(at: 3).width = 24
        for c in [0, 4] { grid.column(at: c).xPlacement = .trailing }
        grid.rowAlignment = .none
        for r in 0..<grid.numberOfRows { grid.row(at: r).yPlacement = .center }

        let colorBox = SettingsUI.box("色 (四角をクリックで変更、↺ でテーマの色に戻す。(*) はウインドウ枠が灰色/macOS のとき、変えない限り枠と同じ色)", grid)

        // 下
        let jsonButton = NSButton(title: "theme.json を直接編集…", target: self, action: #selector(openJSON(_:)))
        jsonButton.bezelStyle = .rounded
        let note = NSTextField(labelWithString: "設定は ~/.satomaru/theme.json に保存されます")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let bottomRow = NSStackView(views: [note, NSView(), jsonButton])

        let stack = NSStackView(views: [presetRow, gallery, fontRow, styleRow, iconRow, colorBox, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in [presetRow, gallery, fontRow, styleRow, colorBox, bottomRow] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }

        // 見本を入れると縦に長いので、小さい画面でも収まるようにスクロールさせる
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.widthAnchor.constraint(equalTo: clip.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
    }

    private func makeCells(index i: Int) -> [NSView] {
        let label = NSTextField(labelWithString: Theme.entries[i].label)
        let well = NSColorWell()
        well.tag = i
        well.target = self
        well.action = #selector(colorChanged(_:))
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        well.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let reset = NSButton(title: "↺", target: self, action: #selector(resetOne(_:)))
        reset.tag = i
        reset.bezelStyle = .inline
        reset.toolTip = "テーマの色に戻す"
        labels.append(label)
        wells.append(well)
        resetButtons.append(reset)
        return [label, well, reset]
    }

    private func bold(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return f
    }

    private func refresh() {
        updating = true
        defer { updating = false }
        gallery.refresh()
        iconChooser.refresh()
        let n = Theme.overrides.count
        customLabel.stringValue = n == 0 ? "" : "＋ \(n) 項目を個別に変更中"
        resetAllButton.isEnabled = n > 0
        let font = Theme.font
        let size = font.pointSize == font.pointSize.rounded() ? "\(Int(font.pointSize))" : "\(font.pointSize)"
        fontLabel.stringValue = "\(font.displayName ?? font.fontName)  \(size) pt"
        fontLabel.font = NSFont(descriptor: font.fontDescriptor, size: NSFont.systemFontSize)
        sizeStepper.doubleValue = Double(font.pointSize)
        if let i = Theme.windowStyles.firstIndex(where: { $0.key == Theme.windowStyle }) {
            windowStylePopup.selectItem(at: i)
        }
        for (i, e) in Theme.entries.enumerated() {
            let custom = Theme.overrides[e.key] != nil
            wells[i].color = Theme.color(forKey: e.key)
            labels[i].stringValue = (custom ? "● " : "") + e.label
            labels[i].font = custom ? .boldSystemFont(ofSize: NSFont.systemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
            resetButtons[i].isEnabled = custom
        }
    }

    @objc private func themeDidChange() {
        refresh()
    }

    // MARK: 操作

    private func choosePreset(_ name: String) {
        guard name != Theme.presetName || !Theme.overrides.isEmpty else { return }
        let n = Theme.overrides.count
        guard n > 0, let window = window else {
            Theme.selectPreset(name)
            return
        }
        let alert = NSAlert()
        alert.messageText = "テーマを「\(name)」に切り替えますか？"
        alert.informativeText = "個別に変えた \(n) 項目の色は消えます。"
        alert.addButton(withTitle: "切り替える")
        alert.addButton(withTitle: "やめる")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                Theme.selectPreset(name)
            } else {
                self?.refresh()
            }
        }
    }

    @objc private func windowStyleChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        guard i >= 0, i < Theme.windowStyles.count else { return }
        Theme.setWindowStyle(Theme.windowStyles[i].key)
    }

    @objc private func resetAll(_ sender: Any?) {
        Theme.resetAllColors()
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard !updating else { return }
        Theme.setColor(sender.color, forKey: Theme.entries[sender.tag].key)
    }

    @objc private func resetOne(_ sender: NSButton) {
        Theme.resetColor(forKey: Theme.entries[sender.tag].key)
    }

    @objc private func sizeChanged(_ sender: NSStepper) {
        let f = Theme.font
        Theme.setFont(NSFont(descriptor: f.fontDescriptor, size: CGFloat(sender.doubleValue)) ?? f)
    }

    @objc private func chooseFont(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        let fm = NSFontManager.shared
        fm.target = self
        fm.action = #selector(changeFont(_:))
        fm.setSelectedFont(Theme.font, isMultiple: false)
        fm.orderFrontFontPanel(self)
    }

    @objc func changeFont(_ sender: Any?) {
        guard let fm = sender as? NSFontManager else { return }
        Theme.setFont(fm.convert(Theme.font))
    }

    @objc private func openJSON(_ sender: Any?) {
        Theme.openUserFile()
    }
}
