import AppKit

/// 後から足した機能 (拡張機能)。それぞれ使う・使わないを選べ、使わないものはメニュー・ツールバー・設定画面から消える。
enum EditorExtension: String, CaseIterable {
    case collab, server, ai, encryption, paper, folder

    var prefKey: String {
        switch self {
        case .collab: return "collabEnabled"
        case .server: return "serverEnabled"
        case .ai: return "aiEnabled"
        case .encryption: return "encryptionEnabled"
        case .paper: return "paperEnabled"
        case .folder: return "folderTreeEnabled"
        }
    }

    var title: String {
        switch self {
        case .collab: return "共同編集 (共有)"
        case .server: return "サーバ (SFTP / FTP)"
        case .ai: return "AI アシスタント"
        case .encryption: return "流出防止 (暗号化して保存)"
        case .paper: return "用紙モード (作文用紙・A4)"
        case .folder: return "フォルダツリー"
        }
    }

    var summary: String {
        switch self {
        case .collab: return "同じ文書を、ほかの人と同時に編集します。チャットつき。"
        case .server: return "サーバのファイルを開いて編集。保存するとサーバに反映。"
        case .ai: return "AI に校正・要約・続きを書くなどを頼めます。"
        case .encryption: return "文書を暗号化して保存。開けるのは鍵を持つ本人だけ。"
        case .paper: return "作文用紙 (縦書き) や A4 用紙の見た目で書けます。"
        case .folder: return "フォルダの中身を左にツリーで表示。たくさんのファイルを行き来できます。"
        }
    }

    /// ツールバーのボタン
    var toolbarIDs: [String] {
        switch self {
        case .collab: return ["share"]
        case .server: return ["server"]
        case .ai: return ["ai"]
        case .encryption: return []
        case .paper: return ["paper"]
        case .folder: return ["folder"]
        }
    }

    /// メニューバーの見出しごと消すもの
    var topMenus: [String] {
        switch self {
        case .collab: return ["共有"]
        case .ai: return ["AI"]
        case .server: return ["サーバ"]
        case .encryption: return ["暗号化"]
        case .paper: return ["用紙"]
        case .folder: return []
        }
    }

    /// 個別に消すメニュー項目 (動作名)
    var menuActions: [String] {
        switch self {
        case .collab: return ["startShareHM:", "joinShareHM:", "toggleChatHM:", "stopShareHM:"]
        case .server: return ["openServersHM:", "toggleRemoteAutoUploadHM:"]
        case .ai: return ["toggleAIHM:", "aiActionHM:", "openAISettingsHM:", "openAIUsageHM:"]
        case .encryption: return ["encryptDocumentHM:", "decryptDocumentHM:", "toggleEncryptAlwaysHM:"]
        case .paper: return ["setPaperModeHM:", "cyclePaperModeHM:", "toggleGenkoAssistHM:", "togglePaperAutoFormatHM:", "setParagraphAlignHM:"]
        case .folder: return ["toggleFolderTreeHM:", "openFolderHM:"]
        }
    }

    /// 見出しで消すサブメニュー
    var subMenus: [String] {
        []
    }

    /// 画面とメニューに並べる順 (身近なものを上に、サーバなど設定が要るものを下に)
    static let displayOrder: [EditorExtension] = [.encryption, .paper, .folder, .ai, .collab, .server]

    var isOn: Bool { UserDefaults.standard.bool(forKey: prefKey) }

    /// オンにする前の説明 (なければそのままオン)
    func confirmEnable() -> Bool {
        switch self {
        case .collab: return CollabConsent.confirmEnable()
        case .ai: return AIConsent.confirmEnable()
        case .encryption:
            let a = NSAlert()
            a.messageText = "流出防止 (暗号化) をオンにします"
            a.accessoryView = diagram()
            a.informativeText = "パスワードを忘れると、だれにも開けなくなります。"
            a.addButton(withTitle: "オンにする")
            a.addButton(withTitle: "やめる")
            return a.runModal() == .alertFirstButtonReturn
        case .server:
            let a = NSAlert()
            a.messageText = "サーバ (SFTP / FTP) をオンにします"
            a.accessoryView = diagram()
            a.informativeText = "保存するとすぐサーバに反映されます。本番サーバでは注意。"
            a.addButton(withTitle: "オンにする")
            a.addButton(withTitle: "やめる")
            return a.runModal() == .alertFirstButtonReturn
        case .paper:
            let a = NSAlert()
            a.messageText = "用紙モードをオンにします"
            a.informativeText = "メニューバーの「用紙」で切り替えます。"
            a.accessoryView = diagram()
            a.addButton(withTitle: "オンにする")
            a.addButton(withTitle: "やめる")
            return a.runModal() == .alertFirstButtonReturn
        case .folder:
            let a = NSAlert()
            a.messageText = "フォルダツリーをオンにします"
            a.informativeText = "「表示 > フォルダツリー」で出し入れ、「ファイル > フォルダを開く…」でフォルダを選びます。"
            a.accessoryView = diagram()
            a.addButton(withTitle: "オンにする")
            a.addButton(withTitle: "やめる")
            return a.runModal() == .alertFirstButtonReturn
        }
    }

    /// オン・オフを切り替える (オンにするときは説明を出す)。切り替えたら true
    @discardableResult
    func set(_ on: Bool) -> Bool {
        if on == isOn { return true }
        if on && !confirmEnable() { return false }
        UserDefaults.standard.set(on, forKey: prefKey)
        if !on && self == .server { ServerExplorerWindowController.closeIfOpen() }
        if !on && self == .encryption { UserDefaults.standard.set(false, forKey: "encryptAlways") }
        ExtensionUI.apply()
        NotificationCenter.default.post(name: .viewSettingsDidChange, object: nil)
        if on { reveal() }
        return true
    }

    /// オンにした直後に、その機能を画面に出す (オンにしただけでは何も変わって見えないのを防ぐ)。
    /// 共同編集と暗号化は、相手や文書を選んで始める操作なので自動では始めない (メニューとボタンだけ出る)
    private func reveal() {
        switch self {
        case .server:
            ServerExplorerWindowController.shared.showForSetup()
        case .ai, .paper:
            guard let w = NSApp.orderedWindows.first(where: { $0.windowController is EditorWindowController }),
                  let editor = w.windowController as? EditorWindowController else { return }
            if self == .ai { editor.revealAIPanel() } else { editor.applyPaperMode(.genko) }
            // 設定ウインドウから切り替えたときも見えるように、エディタをそのすぐ後ろへ持ってくる
            if let key = NSApp.keyWindow, key !== w { w.order(.below, relativeTo: key.windowNumber) }
        case .folder:
            // 左にツリーを出す。まだフォルダを選んでいなければ、続けて選んでもらう
            FolderTree.setVisible(true)
            if FolderTree.root == nil { FolderTree.chooseRoot() }
        case .collab, .encryption:
            break
        }
    }

    static func extensionFor(toolbarID id: String) -> EditorExtension? {
        allCases.first { $0.toolbarIDs.contains(id) }
    }
}

/// オン・オフをメニューとツールバーに反映する
enum ExtensionUI {
    static func hides(_ item: NSMenuItem, topLevel: Bool) -> Bool {
        for e in EditorExtension.allCases where !e.isOn {
            if topLevel && e.topMenus.contains(item.title) { return true }
            if item.hasSubmenu && e.subMenus.contains(item.title) { return true }
            if let a = item.action, e.menuActions.contains(NSStringFromSelector(a)) { return true }
        }
        return false
    }

    static func apply() {
        MenuCustomizer.apply()
        // ツールバー: 同じ名前のツールバーは全ウインドウで連動するので 1 つ直せばよい
        guard let toolbar = NSApp.windows.compactMap({ $0.toolbar }).first(where: { $0.identifier == EditorToolbar.identifier }) else { return }
        for i in toolbar.items.indices.reversed() {
            let raw = toolbar.items[i].itemIdentifier.rawValue.replacingOccurrences(of: "satomaru.", with: "")
            if let e = EditorExtension.extensionFor(toolbarID: raw), !e.isOn { toolbar.removeItem(at: i) }
        }
        for e in EditorExtension.allCases where e.isOn {
            for id in e.toolbarIDs {
                let ident = NSToolbarItem.Identifier("satomaru.\(id)")
                guard !toolbar.items.contains(where: { $0.itemIdentifier == ident }) else { continue }
                // 右端の「色・フォント」の前あたりに入れる
                let idx = toolbar.items.firstIndex { $0.itemIdentifier == .flexibleSpace } ?? toolbar.items.count
                toolbar.insertItem(withItemIdentifier: ident, at: idx)
            }
        }
    }
}

/// 設定ウインドウの「追加機能」タブ。
/// 機能ごとに開閉できる段になっていて、使っていない機能は閉じて短い説明だけを見せる。
final class ExtensionsSettingsPane: NSObject, SettingsPane {
    let title = "追加機能"
    let view = NSView()

    /// 1 機能ぶんの段
    private struct Section {
        let ext: EditorExtension
        let check: NSButton
        let disclosure: NSButton
        let body: NSView
        var wasOn: Bool
    }

    private var sections: [Section] = []
    private let encryptAlways = NSButton(checkboxWithTitle: "いつも暗号化して保存する", target: nil, action: nil)
    /// 暗号化の方法 (最初に選んでおくものを選ぶ)
    private var kindRadios: [NSButton] = []

    override init() {
        super.init()
        var views: [NSView] = [SettingsUI.label("使う機能にチェック。使わない機能はメニューに出ません。▶ で説明を開閉できます。", small: true)]
        for (i, e) in EditorExtension.displayOrder.enumerated() {
            let disclosure = NSButton(title: "", target: self, action: #selector(disclosureClicked(_:)))
            disclosure.bezelStyle = .disclosure
            disclosure.setButtonType(.pushOnPushOff)
            disclosure.tag = i
            disclosure.setAccessibilityLabel("\(e.title) の説明を開閉")
            let name = NSTextField(labelWithString: e.title)
            name.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            // 見出しの文字を押しても開閉できる
            let click = NSClickGestureRecognizer(target: self, action: #selector(titleClicked(_:)))
            name.addGestureRecognizer(click)
            name.tag = i
            let check = NSButton(checkboxWithTitle: "使う", target: self, action: #selector(toggled(_:)))
            check.tag = i
            let header = NSStackView(views: [disclosure, name, NSView(), check])
            header.orientation = .horizontal
            header.spacing = 6

            let desc = NSTextField(wrappingLabelWithString: e.summary)
            desc.font = .systemFont(ofSize: 11)
            desc.textColor = .secondaryLabelColor
            desc.preferredMaxLayoutWidth = 560

            // 開いたときだけ見える中身: しくみの図と、その機能の細かい設定
            var inner: [NSView] = [e.diagram(width: 440)]
            if e == .encryption {
                encryptAlways.target = self
                encryptAlways.action = #selector(encryptAlwaysChanged(_:))
                inner.append(encryptAlways)
                inner.append(makeKindChooser())
            }
            let body = NSStackView(views: inner)
            body.orientation = .vertical
            body.alignment = .leading
            body.spacing = 6

            let column = NSStackView(views: [header, desc, body])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 5
            column.translatesAutoresizingMaskIntoConstraints = false
            header.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

            let panel = NSView()
            panel.wantsLayer = true
            panel.layer?.cornerRadius = 6
            panel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.04).cgColor
            panel.layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
            panel.layer?.borderWidth = 1
            panel.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(column)
            NSLayoutConstraint.activate([
                column.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
                column.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
                column.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
                column.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
            ])
            views.append(panel)
            sections.append(Section(ext: e, check: check, disclosure: disclosure, body: body, wasOn: e.isOn))
            setExpanded(i, e.isOn)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        views.append(spacer)
        // 開くと縦に長くなるので、スクロールできるようにする
        let content = FlippedView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = content
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        let stack = SettingsUI.fill(content, with: views, spacing: 8)
        for v in views.dropFirst().dropLast() {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshFromNote), name: .viewSettingsDidChange, object: nil)
    }

    func willShow() { refresh() }

    @objc private func refreshFromNote() { refresh() }

    private func setExpanded(_ i: Int, _ expanded: Bool) {
        sections[i].body.isHidden = !expanded
        sections[i].disclosure.state = expanded ? .on : .off
    }

    private func refresh() {
        for i in sections.indices {
            let on = sections[i].ext.isOn
            sections[i].check.state = on ? .on : .off
            // オンにしたら開き、オフにしたら閉じる (手で開閉した状態は、切り替えるまでそのまま)
            if on != sections[i].wasOn {
                sections[i].wasOn = on
                setExpanded(i, on)
            }
        }
        encryptAlways.state = Prefs.bool("encryptAlways") ? .on : .off
        encryptAlways.isEnabled = EditorExtension.encryption.isOn
        let chosen = PasswordPrompt.defaultKindIndex
        for (i, r) in kindRadios.enumerated() {
            r.state = i == chosen ? .on : .off
            r.isEnabled = EditorExtension.encryption.isOn
        }
    }

    /// 暗号化の方法の説明と、最初に選んでおく方法の選択
    private func makeKindChooser() -> NSView {
        let heading = SettingsUI.label("暗号化の方法 (暗号化するときに最初に選ばれているものを選べます。保存のときに変えることもできます)", small: true)
        var rows: [NSView] = [heading]
        for (i, k) in PasswordPrompt.kindChoices.enumerated() {
            let radio = NSButton(radioButtonWithTitle: k.title, target: self, action: #selector(kindChosen(_:)))
            radio.tag = i
            kindRadios.append(radio)
            let note = SettingsUI.label(k.note, small: true)
            let row = NSStackView(views: [radio, note])
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .firstBaseline
            rows.append(row)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 0, right: 0)
        return stack
    }

    /// ラジオボタンは 1 つずつ別の行に入れているので、選んだもの以外は refresh で外す
    @objc private func kindChosen(_ sender: NSButton) {
        PasswordPrompt.defaultKindIndex = sender.tag
        refresh()
    }

    @objc private func disclosureClicked(_ sender: NSButton) {
        setExpanded(sender.tag, sender.state == .on)
    }

    @objc private func titleClicked(_ sender: NSClickGestureRecognizer) {
        guard let i = sender.view?.tag, sections.indices.contains(i) else { return }
        setExpanded(i, sections[i].body.isHidden)
    }

    @objc private func toggled(_ sender: NSButton) {
        sections[sender.tag].ext.set(sender.state == .on)
        refresh()
        SettingsWindowController.shared.refreshTabs()
    }

    @objc private func encryptAlwaysChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "encryptAlways")
    }
}

// MARK: - 図

/// 左から右へ流れる簡単な図: [絵 + 名前] → [絵 + 名前] → …
final class FlowDiagramView: NSView {
    struct Step { let icon: String; let title: String }
    struct Arrow { let label: String; let both: Bool }

    let steps: [Step]
    let arrows: [Arrow]

    init(steps: [Step], arrows: [Arrow], width: CGFloat = 460) {
        self.steps = steps
        self.arrows = arrows
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 96))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 96).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let n = CGFloat(steps.count)
        let boxW: CGFloat = 104, boxH: CGFloat = 80
        let area = bounds.insetBy(dx: 3, dy: 0) // 枠線が端で切れないように
        let gap = (area.width - boxW * n) / max(1, n - 1)
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        var boxes: [NSRect] = []
        for (i, s) in steps.enumerated() {
            let r = NSRect(x: area.minX + CGFloat(i) * (boxW + gap), y: 8, width: boxW, height: boxH)
            boxes.append(r)
            let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            accent.withAlphaComponent(0.10).setFill()
            path.fill()
            accent.setStroke()
            path.lineWidth = 1.5
            path.stroke()
            (s.icon as NSString).draw(in: NSRect(x: r.minX, y: r.minY + 8, width: r.width, height: 36),
                                      withAttributes: [.font: NSFont.systemFont(ofSize: 28), .paragraphStyle: center])
            (s.title as NSString).draw(in: NSRect(x: r.minX + 2, y: r.minY + 48, width: r.width - 4, height: 30),
                                       withAttributes: [.font: NSFont.boldSystemFont(ofSize: 11), .paragraphStyle: center,
                                                        .foregroundColor: NSColor.labelColor])
        }
        for (i, a) in arrows.enumerated() where i + 1 < boxes.count {
            let x0 = boxes[i].maxX + 6, x1 = boxes[i + 1].minX - 6
            let y = boxes[i].midY + 6
            accent.setStroke()
            accent.setFill()
            let line = NSBezierPath()
            line.lineWidth = 2
            line.move(to: NSPoint(x: x0, y: y))
            line.line(to: NSPoint(x: x1, y: y))
            line.stroke()
            func head(_ x: CGFloat, _ right: Bool) {
                let d: CGFloat = right ? -1 : 1
                let p = NSBezierPath()
                p.move(to: NSPoint(x: x, y: y))
                p.line(to: NSPoint(x: x + 8 * d, y: y - 5))
                p.line(to: NSPoint(x: x + 8 * d, y: y + 5))
                p.close()
                p.fill()
            }
            head(x1, true)
            if a.both { head(x0, false) }
            (a.label as NSString).draw(in: NSRect(x: x0 - 10, y: y - 30, width: x1 - x0 + 20, height: 28), withAttributes: [
                .font: NSFont.systemFont(ofSize: 10), .paragraphStyle: center, .foregroundColor: NSColor.secondaryLabelColor,
            ])
        }
    }
}

extension EditorExtension {
    /// しくみの図
    func diagram(width: CGFloat = 460) -> NSView {
        typealias S = FlowDiagramView.Step
        typealias A = FlowDiagramView.Arrow
        switch self {
        case .collab:
            return FlowDiagramView(steps: [S(icon: "💻", title: "あなた"), S(icon: "💻", title: "相手")],
                                   arrows: [A(label: "アドレスとコードで参加\n→ 一緒に編集・チャット", both: true)], width: width)
        case .server:
            return FlowDiagramView(steps: [S(icon: "📝", title: "さとるエディタ"), S(icon: "🖥", title: "サーバ")],
                                   arrows: [A(label: "開く ←\n保存するとすぐ反映 →", both: true)], width: width)
        case .ai:
            return FlowDiagramView(steps: [S(icon: "📝", title: "文章を選ぶ"), S(icon: "✨", title: "AI"), S(icon: "✅", title: "挿入・置き換え")],
                                   arrows: [A(label: "送る", both: false), A(label: "答え", both: false)], width: width)
        case .encryption:
            return FlowDiagramView(steps: [S(icon: "📄", title: "文書"), S(icon: "🔒", title: "暗号化ファイル\n(だれも読めない)"), S(icon: "🔑", title: "本人だけ開ける")],
                                   arrows: [A(label: "保存", both: false), A(label: "鍵で開く", both: false)], width: width)
        case .folder:
            return FlowDiagramView(steps: [S(icon: "📁", title: "フォルダを選ぶ"), S(icon: "🗂", title: "左にツリー"), S(icon: "📝", title: "クリックで開く")],
                                   arrows: [A(label: "表示", both: false), A(label: "タブで開く", both: false)], width: width)
        case .paper:
            return FlowDiagramView(steps: [S(icon: "📄", title: "ふつう"), S(icon: "📜", title: "作文用紙\n(縦書き)"), S(icon: "📃", title: "A4 用紙")],
                                   arrows: [A(label: "切り替え", both: true), A(label: "切り替え", both: true)], width: width)
        }
    }
}

/// 上から並べるための (y が下向きの) 入れ物
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
