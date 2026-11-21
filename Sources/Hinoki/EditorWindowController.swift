import AppKit
import PDFKit
import HinokiCore

final class EditorWindowController: NSWindowController, NSTextViewDelegate, NSMenuItemValidation, NSWindowDelegate, NSSplitViewDelegate {
    /// 上 (分割していないときはこれだけ)
    private let primary: EditorPane
    /// 上下分割したときの下
    private var secondary: EditorPane?
    /// 最後にカーソルがあった面が下なら true
    private var secondaryIsActive = false
    private let splitView = NSSplitView()
    /// 編集面 + (共同編集中は) 右のチャット欄
    private let editorArea = NSStackView()
    private lazy var chatPanel: ChatPanel = {
        let p = ChatPanel()
        p.onSend = { [weak self] text in self?.collabSession?.sendChat(text) }
        p.onStop = { [weak self] in self?.stopShareHM(nil) }
        return p
    }()
    /// 左のフォルダツリー (使うときに初めて作る)
    private lazy var folderPanel = FolderTreePanel()
    private var folderPanelCreated = false
    /// 共同編集 (共有中・参加中)
    private(set) var collabSession: CollabSession?
    private let statusLabel = NSTextField(labelWithString: "")
    /// 右下の「自動整形」チェック (作文用紙・A4 のときだけ出る)
    private let formatCheck = NSButton(checkboxWithTitle: "自動整形", target: nil, action: nil)
    /// フッター右側: 行・列 | 選択 | 言語 | 文字コード | 改行コード (クリックで変更)
    private let statusCells = StatusCellsView()
    private var highlighter: SyntaxHighlighter!
    /// init 中はまだ document が設定されていないので自前で持つ
    private weak var ownerDocument: Document?
    private(set) var profile: LanguageProfile?
    /// メニューで言語を手動指定したら、拡張子による自動判定をしない
    private var profileChosenManually = false

    private var hdoc: Document? { (document as? Document) ?? ownerDocument }

    private var activePane: EditorPane { (secondaryIsActive ? secondary : nil) ?? primary }
    private var panes: [EditorPane] { [primary] + (secondary.map { [$0] } ?? []) }
    /// いまカーソルがあるテキストビュー (検索・grep・メニュー操作はこれに対して行う)
    var textView: EditorTextView { activePane.textView }
    private var ruler: LineNumberRulerView { activePane.ruler }
    var isSplit: Bool { secondary != nil }

    static var editorFont: NSFont { Theme.font }
    private let divider = NSView()

    init(document: Document) {
        primary = EditorPane()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)

        window.backgroundColor = Theme.footerBackground
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "SatomaruEditor"
        window.toolbar = EditorToolbar.shared.makeToolbar()
        window.toolbarStyle = .expanded
        super.init(window: window)
        window.delegate = self
        ownerDocument = document
        shouldCascadeWindows = true
        highlighter = SyntaxHighlighter(textView: primary.textView)
        NotificationCenter.default.addObserver(self, selector: #selector(profilesDidChange),
                                               name: .profilesDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(viewSettingsDidChange),
                                               name: .viewSettingsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applyFolderTree),
                                               name: .folderTreeDidChange, object: nil)
        applyFolderTree()
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange),
                                               name: .themeDidChange, object: nil)

        setUp(primary)
        setUpLayout(in: window)
        applyViewSettings()
        load(document.text)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: 構築

    private func setUp(_ pane: EditorPane) {
        let tv = pane.textView
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        // ⌘F の検索バー (インクリメンタル検索・置換つき)
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.delegate = self
        tv.onBecomeFirstResponder = { [weak self, weak pane] in
            guard let self = self, let pane = pane else { return }
            self.secondaryIsActive = pane === self.secondary
            self.updateStatus()
        }

        let font = Self.editorFont
        tv.font = font
        let style = NSMutableParagraphStyle()
        style.lineSpacing = CGFloat(UserDefaults.standard.double(forKey: "lineSpacing")) // 行間 (動作環境)
        style.tabStops = []
        style.defaultTabInterval = ("0" as NSString).size(withAttributes: [.font: font]).width * 4
        tv.defaultParagraphStyle = style
        tv.typingAttributes = [.font: font, .paragraphStyle: style, .foregroundColor: Theme.text]
        tv.drawsBackground = true
        pane.scrollView.drawsBackground = true
        applyColors(to: pane)
    }

    private func applyColors(to pane: EditorPane) {
        let tv = pane.textView
        tv.backgroundColor = Theme.background
        tv.insertionPointColor = Theme.caret
        tv.selectedTextAttributes = [.backgroundColor: Theme.selection]
        tv.currentLineColor = Theme.currentLine
        pane.scrollView.backgroundColor = Theme.background
        pane.scrollView.scrollerKnobStyle = Theme.isDarkBackground ? .light : .dark
    }

    private func setUpLayout(in window: NSWindow) {
        let content = window.contentView!
        splitView.isVertical = false // 上下に並べる
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(primary.scrollView)
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = Theme.footerText
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        applyDividerColor()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        editorArea.orientation = .horizontal
        editorArea.spacing = 0
        editorArea.alignment = .height
        editorArea.translatesAutoresizingMaskIntoConstraints = false
        editorArea.addArrangedSubview(splitView)
        content.addSubview(editorArea)
        content.addSubview(divider)
        content.addSubview(statusLabel)
        formatCheck.target = self
        formatCheck.action = #selector(formatCheckChanged(_:))
        formatCheck.controlSize = .small
        formatCheck.font = .systemFont(ofSize: 11)
        formatCheck.isHidden = true
        formatCheck.translatesAutoresizingMaskIntoConstraints = false
        statusCells.onClick = { [weak self] id, view in self?.statusCellClicked(id, view) }
        statusCells.textColor = Theme.footerText
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        // 右寄せ: [項目…] [自動整形]
        let rightStack = NSStackView(views: [statusCells, formatCheck])
        rightStack.spacing = 10
        rightStack.alignment = .centerY
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.setContentHuggingPriority(.required, for: .horizontal)
        content.addSubview(rightStack)
        NSLayoutConstraint.activate([
            rightStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            rightStack.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -10),
            editorArea.topAnchor.constraint(equalTo: content.topAnchor),
            editorArea.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            editorArea.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            divider.topAnchor.constraint(equalTo: editorArea.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 5),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
    }

    private func load(_ text: String) {
        let tv = primary.textView
        tv.string = text
        if let storage = tv.textStorage {
            storage.setAttributes(tv.typingAttributes, range: NSRange(location: 0, length: storage.length))
        }
        panes.forEach { $0.textView.setSelectedRange(NSRange(location: 0, length: 0)) }
        tv.undoManager?.removeAllActions()
        panes.forEach { $0.ruler.textChanged() }
        applyProfile()
        restoreCaretPosition()
        updateStatus()
    }

    // MARK: 上下分割

    @objc func toggleSplitHM(_ sender: Any?) {
        if let lower = secondary {
            // 下で作業していたら、その位置を上に引き継いでから閉じる
            if secondaryIsActive {
                let sel = lower.textView.selectedRange()
                let visible = lower.scrollView.contentView.bounds.origin
                primary.textView.setSelectedRange(sel)
                primary.scrollView.contentView.scroll(to: visible)
                primary.scrollView.reflectScrolledClipView(primary.scrollView.contentView)
            }
            secondaryIsActive = false
            lower.detach()
            secondary = nil
            splitView.adjustSubviews()
            window?.makeFirstResponder(primary.textView)
        } else {
            guard let storage = primary.textView.textStorage else { return }
            let lower = EditorPane(sharing: storage)
            secondary = lower
            setUp(lower)
            splitView.addArrangedSubview(lower.scrollView)
            splitView.adjustSubviews()
            splitView.setPosition(floor(splitView.bounds.height / 2), ofDividerAt: 0)
            applyViewSettings()
            applyProfile(keepCurrent: true)
            // 下にも同じ位置を表示して、カーソルを下へ
            let sel = primary.textView.selectedRange()
            lower.textView.setSelectedRange(sel)
            lower.textView.scrollRangeToVisible(sel)
            window?.makeFirstResponder(lower.textView)
        }
        updateStatus()
    }

    /// 上と下のカーソルを行き来する
    @objc func switchSplitPaneHM(_ sender: Any?) {
        guard let lower = secondary else { NSSound.beep(); return }
        window?.makeFirstResponder(secondaryIsActive ? primary.textView : lower.textView)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 60)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.height - 60)
    }

    // MARK: テーマ

    private func applyDividerColor() {
        // 枠に合わせた色はライト/ダークで変わるので、ウインドウの見た目で解決してから使う
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        var cg = Theme.footerSeparator.cgColor
        appearance.performAsCurrentDrawingAppearance { cg = Theme.footerSeparator.cgColor }
        divider.layer?.backgroundColor = cg
    }

    /// 色・フォントが変わったときに付け直す
    func themeDidChangePublic() { themeDidChange() }
    func applyViewSettingsPublic() { applyViewSettings() }

    @objc private func themeDidChange() {
        let font = Theme.font
        for pane in panes {
            pane.textView.font = font
            pane.textView.typingAttributes[.font] = font
            pane.textView.typingAttributes[.foregroundColor] = Theme.text
            applyColors(to: pane)
        }
        if let storage = primary.textView.textStorage, storage.length > 0 {
            storage.addAttributes([.font: font, .foregroundColor: Theme.text],
                                  range: NSRange(location: 0, length: storage.length))
        }
        window?.backgroundColor = Theme.footerBackground
        statusLabel.textColor = Theme.footerText
        statusCells.textColor = Theme.footerText
        applyDividerColor()
        applyProfile(keepCurrent: true) // タブ幅の再計算と色付けのやり直し
        for pane in panes {
            pane.textView.needsDisplay = true
            pane.ruler.needsDisplay = true
            pane.columnRuler.needsDisplay = true
        }
        refreshPaper()
    }

    // MARK: 表示設定

    private var wraps: Bool { UserDefaults.standard.bool(forKey: "wrap") }
    private var showsInvisibles: Bool { UserDefaults.standard.bool(forKey: "invisibles") }
    private var showsLineNumbers: Bool { UserDefaults.standard.bool(forKey: "lineNumbers") }
    private var showsColumnRuler: Bool { UserDefaults.standard.bool(forKey: "columnRuler") }
    private var countsVisualLines: Bool { UserDefaults.standard.string(forKey: "lineCounting") == "visual" }

    private func applyViewSettings() {
        for pane in panes { applyViewSettings(to: pane) }
    }

    private func applyViewSettings(to pane: EditorPane) {
        // 用紙モード中は用紙の設定を優先する
        if pane.textView.paperMode != .normal {
            refreshPaper()
            return
        }
        let textView = pane.textView
        let scrollView = pane.scrollView
        guard let tc = textView.textContainer else { return }
        if wraps {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            tc.widthTracksTextView = true
            textView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: textView.frame.height))
        } else {
            scrollView.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = [.width]
            tc.widthTracksTextView = false
            tc.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        (textView.layoutManager as? InvisiblesLayoutManager)?.showsInvisibles = showsInvisibles
        textView.showsEOF = Prefs.bool("showEOF")
        textView.highlightsCurrentLine = Prefs.bool("highlightCurrentLine")
        pane.ruler.countsVisualLines = countsVisualLines
        scrollView.hasVerticalRuler = showsLineNumbers
        scrollView.hasHorizontalRuler = showsColumnRuler
        scrollView.rulersVisible = showsLineNumbers || showsColumnRuler
        scrollView.tile()
        pane.ruler.needsDisplay = true
        pane.columnRuler.needsDisplay = true
    }

    @objc private func viewSettingsDidChange() {
        // 行間が変わったときのために段落の書式を付け直す
        if let ps = primary.textView.defaultParagraphStyle,
           ps.lineSpacing != CGFloat(UserDefaults.standard.double(forKey: "lineSpacing")) {
            applyProfile(keepCurrent: true)
        }
        // 共有機能をオフにしたら、進行中の共有・参加も止める
        if !Prefs.bool("collabEnabled") {
            if let s = collabSession, s.isActive { stopShareHM(nil) }
            if collabSession != nil { chatPanel.isHidden = true }
        }
        if !EditorExtension.ai.isOn { aiTurnedOff() }
        else if aiPanelVisible {
            // 設定や接続テストの結果を AI 欄に反映
            aiPanel.refreshProvider()
            aiPanel.setReady(AISettings.isReady)
        }
        if !EditorExtension.paper.isOn && paperMode != .normal { applyPaperMode(.normal) }
        applyFolderTree()
        if paperMode != .normal { scheduleGenkoAdjust() } else { highlighter.highlightNow() }
        applyViewSettings()
        updateStatus()
    }

    private func toggleDefault(_ key: String) {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        // 開いている全タブに反映
        NotificationCenter.default.post(name: .viewSettingsDidChange, object: nil)
    }

    @objc func toggleWrapHM(_ sender: Any?) { toggleDefault("wrap") }
    @objc func toggleInvisiblesHM(_ sender: Any?) { toggleDefault("invisibles") }
    @objc func toggleLineNumbersHM(_ sender: Any?) { toggleDefault("lineNumbers") }
    @objc func toggleColumnRulerHM(_ sender: Any?) { toggleDefault("columnRuler") }

    @objc func setLineCountingHM(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        UserDefaults.standard.set(mode, forKey: "lineCounting")
        NotificationCenter.default.post(name: .viewSettingsDidChange, object: nil)
    }

    // MARK: 指定行へ移動

    @objc func goToLineHM(_ sender: Any?) {
        guard let window = window else { return }
        let total = ruler.lineCount
        let alert = NSAlert()
        alert.messageText = "指定行へ移動"
        alert.informativeText = "行番号 (1〜\(total))" + (countsVisualLines ? "  ※ワープロ的な数え方" : "")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "移動")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn,
                  let n = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) else { return }
            guard let self = self else { return }
            self.textView.goTo(location: self.ruler.startOfLine(n - 1))
        }
    }

    // MARK: カーソル位置の記憶

    private static let positionsKey = "caretPositions"

    private func restoreCaretPosition() {
        guard Prefs.bool("rememberCaret"), let path = hdoc?.fileURL?.path,
              let positions = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Int],
              let loc = positions[path] else { return }
        let r = NSRange(location: min(loc, (textView.string as NSString).length), length: 0)
        textView.setSelectedRange(r)
        DispatchQueue.main.async { [weak self] in self?.textView.scrollRangeToVisible(r) }
    }

    func saveCaretPosition() {
        guard let path = hdoc?.fileURL?.path else { return }
        var positions = UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Int] ?? [:]
        positions[path] = textView.selectedRange().location
        if positions.count > 300 { positions = Dictionary(uniqueKeysWithValues: Array(positions).suffix(300)) }
        UserDefaults.standard.set(positions, forKey: Self.positionsKey)
    }

    func windowWillClose(_ notification: Notification) {
        collabSession?.stop()
        saveCaretPosition()
    }

    func reloadFromDocument() {
        guard let doc = hdoc else { return }
        load(doc.text)
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        window?.makeFirstResponder(primary.textView)
    }

    /// ⌘T とタブバーの「＋」ボタン
    override func newWindowForTab(_ sender: Any?) {
        do {
            try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
        } catch {
            presentError(error)
        }
    }

    /// 起動直後や 1 枚目からタブバーを出しておく (右端の＋でタブを増やせる)
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if let w = window, let group = w.tabGroup, !group.isTabBarVisible {
            w.toggleTabBar(nil)
        }
    }

    // MARK: 言語プロファイル

    func fileURLDidChange() {
        if !profileChosenManually { applyProfile() }
        updateStatus()
        if folderPanelCreated { folderPanel.currentFile = hdoc?.fileURL }
    }

    // MARK: フォルダツリー

    /// 機能のオン・オフと「表示 > フォルダツリー」に合わせて、左のツリーを出し入れする
    @objc private func applyFolderTree() {
        let show = EditorExtension.folder.isOn && FolderTree.isVisible
        if show {
            if !folderPanelCreated {
                folderPanelCreated = true
                editorArea.insertArrangedSubview(folderPanel, at: 0)
            }
            folderPanel.isHidden = false
            folderPanel.currentFile = hdoc?.fileURL
            folderPanel.reload(nil)
        } else if folderPanelCreated {
            folderPanel.isHidden = true
        }
    }

    /// タブを切り替えたとき: ほかのタブでのツリーの開き具合・スクロール位置を引き継ぐ
    func windowDidBecomeKey(_ notification: Notification) {
        if folderPanelCreated, !folderPanel.isHidden { folderPanel.syncFromShared() }
    }

    func windowDidResignKey(_ notification: Notification) {
        if folderPanelCreated, !folderPanel.isHidden { folderPanel.rememberScroll() }
    }

    @objc private func profilesDidChange() {
        if let current = profile, profileChosenManually {
            profile = Profiles.store.profile(named: current.name)
        }
        applyProfile(keepCurrent: profileChosenManually)
    }

    private func applyProfile(keepCurrent: Bool = false) {
        if !keepCurrent && !profileChosenManually {
            let name = hdoc?.fileURL?.lastPathComponent ?? ""
            profile = Profiles.store.profile(forFileName: name)
        }
        let tabWidth = profile?.tabWidth ?? 4
        let font = primary.textView.font ?? Self.editorFont
        let style = NSMutableParagraphStyle()
        style.lineSpacing = CGFloat(UserDefaults.standard.double(forKey: "lineSpacing")) // 行間 (動作環境)
        style.tabStops = []
        style.defaultTabInterval = ("0" as NSString).size(withAttributes: [.font: font]).width * CGFloat(tabWidth)
        for tv in panes.map({ $0.textView }) {
            tv.softTabWidth = (profile?.useSpaces ?? false) ? tabWidth : nil
            tv.indentWidth = tabWidth
            tv.lineCommentPrefix = profile?.lineComments.first?.trimmingCharacters(in: .whitespaces)
            tv.defaultParagraphStyle = style
            tv.typingAttributes[.paragraphStyle] = style
        }
        if let storage = primary.textView.textStorage, storage.length > 0 {
            storage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: storage.length))
        }
        highlighter.setProfile(profile)
        refreshPaper()
        updateStatus()
    }

    @objc func setLanguageHM(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String {
            profile = Profiles.store.profile(named: name)
            profileChosenManually = true
        } else {
            // 「自動」
            profileChosenManually = false
        }
        applyProfile(keepCurrent: profileChosenManually)
    }

    func textDidChange(_ notification: Notification) {
        highlighter.textDidChange()
        scheduleGenkoAdjust()
        scheduleRemoteAutoSave()
    }

    // MARK: ステータスバー

    private func updateStatus() {
        guard let doc = hdoc ?? (textView.window?.windowController?.document as? Document) else {
            statusLabel.stringValue = ""
            return
        }
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        let loc = min(sel.location, ns.length)
        let (lineNo, lineStart) = ruler.line(at: loc)
        let line = lineNo + 1
        let col = TextMetrics.displayWidth(of: ns.substring(with: NSRange(location: lineStart, length: loc - lineStart))) + 1
        // 左側: サーバ・暗号化・用紙の状態
        var notes: [String] = []
        if let p = paperStatus { notes.append(p) }
        if let k = doc.encryptionKey {
            let how: String
            switch k.kind {
            case .device: how = "この Mac のロック"
            case .totp: how = "ワンタイム認証"
            case .keyfile: how = "鍵ファイル"
            case .twoStep: how = "二段階"
            case .passcode: how = "パスコード"
            case .password: how = "パスワード"
            }
            notes.append("🔒 暗号化 (\(how))")
        }
        if let r = remoteStatus { notes.append(r) }
        // 右下の自動整形チェック
        let mode = paperMode
        formatCheck.isHidden = mode == .normal
        if mode != .normal {
            formatCheck.title = mode == .genko ? "作文の自動整形" : "A4 の自動整形"
            formatCheck.toolTip = mode == .genko ? "題名 3 マス下げ・名前 下寄せ・段落 1 マス下げ" : "題名 中央・名前 右寄せ・段落 1 字下げ"
            formatCheck.state = UserDefaults.standard.bool(forKey: mode == .genko ? "genkoAutoFormat" : "a4AutoFormat") ? .on : .off
        }
        statusLabel.stringValue = notes.joined(separator: "      ")
        statusLabel.toolTip = statusLabel.stringValue
        // 右側: 項目ごとに区切って右寄せ。クリックで変更できる
        var items: [StatusCellsView.Item] = [
            .init(id: "pos", title: "\(line) 行  \(col) 列", tip: "クリックで指定行へ移動"),
        ]
        if sel.length > 0 { items.append(.init(id: "sel", title: "\(sel.length) 文字選択", tip: "選んでいる文字数")) }
        items.append(.init(id: "lang", title: profile?.name ?? "テキスト", tip: "クリックで言語 (色分け・タブ幅) を変更"))
        items.append(.init(id: "enc", title: doc.encoding.displayName, tip: "クリックで文字コードを変更"))
        items.append(.init(id: "eol", title: doc.lineEnding.displayName, tip: "クリックで改行コードを変更"))
        statusCells.set(items)
    }

    /// フッターの項目をクリック → その場で変更メニューを出す
    private func statusCellClicked(_ id: String, _ view: NSView) {
        guard let doc = hdoc else { return }
        func entry(_ title: String, _ action: Selector, _ object: String?, on: Bool) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.representedObject = object
            i.state = on ? .on : .off
            return i
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        switch id {
        case "pos":
            goToLineHM(nil)
            return
        case "lang":
            menu.addItem(entry("自動 (拡張子で判定)", #selector(setLanguageHM(_:)), nil, on: !profileChosenManually))
            menu.addItem(.separator())
            for p in Profiles.store.profiles {
                menu.addItem(entry(p.name, #selector(setLanguageHM(_:)), p.name, on: profileChosenManually && profile?.name == p.name))
            }
        case "enc":
            let head = NSMenuItem(title: "保存する文字コード", action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            for e in TextEncoding.allCases {
                menu.addItem(entry(e.displayName, #selector(setSaveEncodingHM(_:)), e.rawValue, on: e == doc.encoding))
            }
            menu.addItem(.separator())
            let reopen = NSMenu()
            for e in TextEncoding.allCases {
                let i = entry(e.displayName, #selector(reopenWithEncodingHM(_:)), e.rawValue, on: false)
                i.isEnabled = doc.fileURL != nil && !doc.isEncrypted
                reopen.addItem(i)
            }
            let holder = NSMenuItem(title: "文字化けしているとき: 指定して開き直す", action: nil, keyEquivalent: "")
            holder.submenu = reopen
            holder.isEnabled = doc.fileURL != nil && !doc.isEncrypted
            menu.addItem(holder)
        case "eol":
            for le in LineEnding.allCases {
                menu.addItem(entry(le.displayName, #selector(setLineEndingHM(_:)), le.rawValue, on: le == doc.lineEnding))
            }
        default:
            return
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if (notification.object as? NSTextView) === textView {
            updateStatus()
            updateAITarget()
            collabSession?.localSelectionChanged()
        }
    }

    /// ペーストなどで入ってきた CR / CRLF は LF に揃える (保存時に元の改行コードへ戻す)
    func textView(_ tv: NSTextView, shouldChangeTextIn range: NSRange, replacementString s: String?) -> Bool {
        guard let s = s, (s as NSString).range(of: "\r").location != NSNotFound else { return true }
        let fixed = TextCodec.normalizeLineEndings(s)
        if tv.shouldChangeText(in: range, replacementString: fixed) {
            tv.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: fixed, attributes: tv.typingAttributes))
            tv.didChangeText()
        }
        return false
    }

    // MARK: 文字コード・改行コード

    @objc func setSaveEncodingHM(_ sender: NSMenuItem) {
        guard let doc = hdoc, let raw = sender.representedObject as? String, let e = TextEncoding(rawValue: raw) else { return }
        doc.encoding = e
        doc.updateChangeCount(.changeDone)
        updateStatus()
    }

    @objc func setLineEndingHM(_ sender: NSMenuItem) {
        guard let doc = hdoc, let raw = sender.representedObject as? String, let le = LineEnding(rawValue: raw) else { return }
        doc.lineEnding = le
        doc.updateChangeCount(.changeDone)
        updateStatus()
    }

    @objc func reopenWithEncodingHM(_ sender: NSMenuItem) {
        if hdoc?.isEncrypted == true { NSSound.beep(); return }
        guard let doc = hdoc, let url = doc.fileURL,
              let raw = sender.representedObject as? String, let e = TextEncoding(rawValue: raw) else {
            NSSound.beep()
            return
        }
        if doc.isDocumentEdited {
            let alert = NSAlert()
            alert.messageText = "変更を破棄して \(e.displayName) で開き直しますか？"
            alert.addButton(withTitle: "開き直す")
            alert.addButton(withTitle: "キャンセル")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            doc.apply(try TextCodec.decode(try Data(contentsOf: url), as: e))
            doc.updateChangeCount(.changeCleared)
        } catch {
            presentError(error)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let doc = hdoc else { return false }
        let raw = item.representedObject as? String
        switch item.action {
        case #selector(EditorWindowController.setSaveEncodingHM(_:)):
            item.state = raw == doc.encoding.rawValue ? .on : .off
        case #selector(EditorWindowController.setLineEndingHM(_:)):
            item.state = raw == doc.lineEnding.rawValue ? .on : .off
        case #selector(EditorWindowController.setLanguageHM(_:)):
            if let name = raw {
                item.state = profileChosenManually && profile?.name == name ? .on : .off
            } else {
                item.state = profileChosenManually ? .off : .on
            }
        case #selector(EditorWindowController.toggleWrapHM(_:)):
            item.state = wraps ? .on : .off
        case #selector(EditorWindowController.toggleInvisiblesHM(_:)):
            item.state = showsInvisibles ? .on : .off
        case #selector(EditorWindowController.toggleLineNumbersHM(_:)):
            item.state = showsLineNumbers ? .on : .off
        case #selector(EditorWindowController.setLineCountingHM(_:)):
            item.state = (item.representedObject as? String == "visual") == countsVisualLines ? .on : .off
        case #selector(EditorWindowController.toggleColumnRulerHM(_:)):
            item.state = showsColumnRuler ? .on : .off
        case #selector(EditorWindowController.toggleSplitHM(_:)):
            item.state = isSplit ? .on : .off
        case #selector(EditorWindowController.switchSplitPaneHM(_:)):
            return isSplit
        case #selector(EditorWindowController.startShareHM(_:)):
            return Prefs.bool("collabEnabled")
        case #selector(EditorWindowController.togglePaperAutoFormatHM(_:)):
            item.state = UserDefaults.standard.bool(forKey: (item.representedObject as? String) ?? "") ? .on : .off
        case #selector(EditorWindowController.setParagraphAlignHM(_:)):
            guard paperMode == .a4, let storage = primary.textView.textStorage, storage.length > 0 else { item.state = .off; return false }
            let loc = min(textView.selectedRange().location, storage.length - 1)
            let v = storage.attribute(.paperAlign, at: loc, effectiveRange: nil) as? String
            item.state = [nil, "left", "center", "right"][max(0, min(3, item.tag))] == v ? .on : .off
        case #selector(EditorWindowController.toggleGenkoAssistHM(_:)):
            item.state = UserDefaults.standard.bool(forKey: (item.representedObject as? String) ?? "") ? .on : .off
        case #selector(EditorWindowController.setPaperModeHM(_:)):
            item.state = item.tag == paperMode.rawValue ? .on : .off
        case #selector(EditorWindowController.decryptDocumentHM(_:)):
            return doc.isEncrypted
        case #selector(EditorWindowController.stopShareHM(_:)):
            return collabSession?.isActive ?? false
        case #selector(EditorWindowController.toggleChatHM(_:)):
            return collabSession != nil
        case #selector(EditorWindowController.reopenWithEncodingHM(_:)):
            return doc.fileURL != nil
        default:
            break
        }
        return true
    }
}

// MARK: - 共同編集

extension EditorWindowController {
    var collabStorage: NSTextStorage? { primary.textView.textStorage }
    var collabText: String { primary.textView.string }
    var collabTitle: String { hdoc?.displayName ?? "共有" }

    /// 参加した側: 届いた状態でこのウインドウを共同編集にする
    func attachCollab(_ session: CollabSession) {
        collabSession = session
        session.attach(self)
        showChat(true)
        chatPanel.setAddress(nil)
        chatPanel.setStopTitle("抜ける", enabled: true)
        chatPanel.append(name: nil, color: nil, text: "共同編集に参加しました。ここでチャットできます。")
    }

    /// ほかの人の変更を文章に反映する (自分の Undo の記録には入れない)
    func collabApply(_ op: TextOp) {
        guard let storage = primary.textView.textStorage else { return }
        let length = storage.length
        let loc = max(0, min(op.loc, length))
        let len = max(0, min(op.len, length - loc))
        let selections = panes.map { $0.textView.selectedRange() }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: loc, length: len),
                                  with: NSAttributedString(string: op.text, attributes: primary.textView.typingAttributes))
        storage.endEditing()
        for (pane, sel) in zip(panes, selections) {
            let s = op.transformPosition(sel.location)
            let e = op.transformPosition(sel.location + sel.length)
            pane.textView.setSelectedRange(NSRange(location: s, length: max(0, e - s)))
        }
        // 位置がずれた Undo は危ないので消す
        primary.textView.undoManager?.removeAllActions()
        highlighter.textDidChange()
        scheduleGenkoAdjust()
        hdoc?.updateChangeCount(.changeDone)
        updateStatus()
    }

    func collabCursorsChanged() {
        guard let s = collabSession else {
            panes.forEach { $0.textView.remoteCursors = [] }
            return
        }
        let list = s.cursors.compactMap { id, c -> EditorTextView.RemoteCursor? in
            guard id != s.myID else { return nil }
            let name = s.users[id]?.name ?? "?"
            return EditorTextView.RemoteCursor(loc: c.loc, len: c.len, name: name, color: CollabSession.color(for: id))
        }
        panes.forEach { $0.textView.remoteCursors = list }
    }

    func collabUsersChanged() {
        guard let s = collabSession else { return }
        chatPanel.setUsers(Array(s.users.values), myID: s.myID)
        if !s.isActive { chatPanel.setStopTitle("終了しました", enabled: false) }
    }

    func collabChat(from user: CollabUser?, text: String) {
        showChat(true)
        chatPanel.append(name: user?.name, color: user?.color, text: text)
        if user != nil, user?.id != collabSession?.myID, !(window?.isKeyWindow ?? false) {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    private func showChat(_ show: Bool) {
        if show {
            if chatPanel.superview == nil { editorArea.addArrangedSubview(chatPanel) }
            chatPanel.isHidden = false
        } else {
            chatPanel.isHidden = true
        }
    }

    // MARK: メニュー

    /// この文書を共有する
    @objc func startShareHM(_ sender: Any?) {
        guard let window = window else { return }
        if hdoc?.isEncrypted == true {
            let alert = NSAlert()
            alert.messageText = "暗号化した文書は共有できません"
            alert.informativeText = "先に暗号化を解除してください。"
            alert.beginSheetModal(for: window)
            return
        }
        guard Prefs.bool("collabEnabled") else {
            let alert = NSAlert()
            alert.messageText = "共有機能はオフになっています"
            alert.informativeText = "「追加機能 > 共同編集」でオンにしてください。"
            alert.beginSheetModal(for: window)
            return
        }
        if let s = collabSession, s.isActive {
            showChat(true)
            chatPanel.focusInput()
            return
        }
        let alert = NSAlert()
        alert.messageText = "この文書を共有します"
        alert.informativeText = "アドレスとコードが出るので、相手に伝えてください。"
        let name = NSTextField(string: UserDefaults.standard.string(forKey: "collabName") ?? CollabSession.computerName)
        let port = NSTextField(string: String(UserDefaults.standard.integer(forKey: "collabPort") > 0 ? UserDefaults.standard.integer(forKey: "collabPort") : Int(CollabSession.defaultPort)))
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "表示名"), name],
            [NSTextField(labelWithString: "ポート"), port],
        ])
        grid.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
        name.widthAnchor.constraint(equalToConstant: 220).isActive = true
        alert.accessoryView = grid
        alert.addButton(withTitle: "共有を始める")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .alertFirstButtonReturn else { return }
            let n = name.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? CollabSession.computerName : name.stringValue
            guard let p = UInt16(port.stringValue.trimmingCharacters(in: .whitespaces)), p >= 1024 else {
                self.presentError(NSError(domain: "Satoru", code: 11, userInfo: [NSLocalizedDescriptionKey: "ポートは 1024〜65535 の数字にしてください"]))
                return
            }
            UserDefaults.standard.set(n, forKey: "collabName")
            UserDefaults.standard.set(Int(p), forKey: "collabPort")
            do {
                try self.beginHosting(name: n, port: p)
            } catch {
                self.presentError(error)
            }
        }
    }

    /// 共有を始めて、チャット欄に参加用アドレスを出す
    func beginHosting(name: String, port p: UInt16) throws {
        collabSession = try CollabSession.host(editor: self, name: name, port: p)
        let addrs = CollabSession.localAddresses()
        let addr = addrs.first.map { "\($0):\(p)" } ?? "(IP アドレスが見つかりません):\(p)"
        showChat(true)
        let code = collabSession?.code ?? ""
        chatPanel.setAddress(addr, code: code)
        chatPanel.setStopTitle("共有を終了", enabled: true)
        chatPanel.append(name: nil, color: nil, text: "相手に「\(addr)」とコード「\(code)」を伝えてください。")
        if addrs.count > 1 {
            chatPanel.append(name: nil, color: nil, text: "ほかのアドレス: " + addrs.dropFirst().map { "\($0):\(p)" }.joined(separator: "、"))
        }
        collabUsersChanged()
    }

    @objc func stopShareHM(_ sender: Any?) {
        guard let s = collabSession, s.isActive else { return }
        s.stop()
        chatPanel.setAddress(nil)
        chatPanel.append(name: nil, color: nil, text: s.role == .host ? "共有を終了しました。" : "共同編集から抜けました。")
    }

    @objc func toggleChatHM(_ sender: Any?) {
        guard collabSession != nil else { NSSound.beep(); return }
        showChat(chatPanel.isHidden || chatPanel.superview == nil)
    }
}

// MARK: - サーバのファイル

private var remoteStatusKey = 0
private var remoteSaveKey = 0

extension EditorWindowController {
    fileprivate var remoteStatus: String? {
        get { objc_getAssociatedObject(self, &remoteStatusKey) as? String }
        set { objc_setAssociatedObject(self, &remoteStatusKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var remoteSaveWork: DispatchWorkItem? {
        get { objc_getAssociatedObject(self, &remoteSaveKey) as? DispatchWorkItem }
        set { objc_setAssociatedObject(self, &remoteSaveKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    func remoteStatusChanged(_ text: String) {
        remoteStatus = text
        updateStatus()
    }

    /// 「すぐサーバに反映」がオンなら、入力が止まって 2 秒後に保存 (→ サーバへ送信)
    fileprivate func scheduleRemoteAutoSave() {
        guard let doc = hdoc, doc.remote != nil, UserDefaults.standard.bool(forKey: "remoteAutoUpload") else { return }
        remoteSaveWork?.cancel()
        let work = DispatchWorkItem { [weak doc] in
            guard let doc = doc, doc.isDocumentEdited else { return }
            doc.save(nil)
        }
        remoteSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    @objc func openServersHM(_ sender: Any?) {
        ServerExplorerWindowController.shared.show()
    }
}

// MARK: - 流出防止 (暗号化)

extension EditorWindowController {
    func encryptionChanged() {
        updateStatus()
        // タイトルとタブの鍵マークを付け直す
        synchronizeWindowTitleWithDocumentName()
    }

    /// 暗号化している文書は、ウインドウのタイトルとタブのファイル名の前に鍵マークを付ける
    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        hdoc?.isEncrypted == true ? "🔒 " + displayName : displayName
    }

    /// 暗号化して保存する (暗号化済みならパスワードを変える)
    @objc func encryptDocumentHM(_ sender: Any?) {
        guard let doc = hdoc else { return }
        if collabSession?.isActive == true {
            NSSound.beep()
            return
        }
        let name = doc.fileURL?.lastPathComponent ?? doc.displayName ?? "この文書"
        guard let key = PasswordPrompt.createKey(for: name) else { return }
        doc.encryptionKey = key
        doc.updateChangeCount(.changeDone)
        doc.save(nil)
    }

    /// 暗号化をやめて普通のテキストとして保存する
    @objc func decryptDocumentHM(_ sender: Any?) {
        guard let doc = hdoc, doc.isEncrypted, let window = window else { return }
        let alert = NSAlert()
        alert.messageText = "暗号化を解除しますか？"
        alert.informativeText = "だれでも読めるファイルに戻ります。"
        alert.addButton(withTitle: "解除して保存")
        alert.addButton(withTitle: "やめる")
        alert.beginSheetModal(for: window) { r in
            guard r == .alertFirstButtonReturn else { return }
            doc.encryptionKey = nil
            doc.plainSaveChosen = true // いま解除を選んだばかりなので、保存時に聞き直さない
            doc.updateChangeCount(.changeDone)
            doc.save(nil)
        }
    }
}

// MARK: - AI アシスタント

private var aiPanelKey = 0
private var aiClientKey = 0

extension EditorWindowController {
    private var aiPanel: AIPanel {
        if let p = objc_getAssociatedObject(self, &aiPanelKey) as? AIPanel { return p }
        let p = AIPanel()
        p.onRun = { [weak self] instruction in self?.runAI(instruction) }
        p.onInsert = { [weak self] text in self?.insertAIResult(text, replace: false) }
        p.onReplace = { [weak self] text in self?.insertAIResult(text, replace: true) }
        p.onCancel = { [weak self] in self?.aiClient?.cancel() }
        p.onClose = { [weak self] in self?.showAIPanel(false) }
        p.onOpenSettings = { SettingsWindowController.shared.show(.ai) }
        objc_setAssociatedObject(self, &aiPanelKey, p, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return p
    }

    private var aiClient: AIClient? {
        get { objc_getAssociatedObject(self, &aiClientKey) as? AIClient }
        set { objc_setAssociatedObject(self, &aiClientKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var aiPanelVisible: Bool {
        guard let p = objc_getAssociatedObject(self, &aiPanelKey) as? AIPanel else { return false }
        return p.superview != nil && !p.isHidden
    }

    private func showAIPanel(_ show: Bool) {
        let p = aiPanel
        if show {
            if p.superview == nil { editorArea.addArrangedSubview(p) }
            p.isHidden = false
            p.refreshProvider()
            p.setReady(AISettings.isReady)
            updateAITarget()
        } else {
            p.isHidden = true
            window?.makeFirstResponder(textView)
        }
    }

    /// 使えない状態なら説明して設定へ案内する
    private func ensureAIReady() -> Bool {
        guard let window = window else { return false }
        if !AISettings.isEnabled {
            let alert = NSAlert()
            alert.messageText = "AI アシスタントはオフになっています"
            alert.informativeText = "「追加機能 > AI アシスタント」でオンにしてください。"
            alert.addButton(withTitle: "設定を開く")
            alert.addButton(withTitle: "あとで")
            alert.beginSheetModal(for: window) { r in
                if r == .alertFirstButtonReturn { SettingsWindowController.shared.show(.ai) }
            }
            return false
        }
        return true
    }

    /// AI アシスタントを切ったら欄を閉じて問い合わせも止める
    func aiTurnedOff() {
        aiClient?.cancel()
        if aiPanelVisible { showAIPanel(false) }
    }

    /// AI アシスタントをオンにした直後に、横の AI 欄を出す
    func revealAIPanel() {
        showAIPanel(true)
    }

    @objc func toggleAIHM(_ sender: Any?) {
        if aiPanelVisible { showAIPanel(false); return }
        guard ensureAIReady() else { return }
        showAIPanel(true)
    }

    /// メニューの「校正」などから直接
    @objc func aiActionHM(_ sender: NSMenuItem) {
        guard ensureAIReady() else { return }
        showAIPanel(true)
        let actions = AIPanel.Action.allCases
        guard sender.tag >= 0, sender.tag < actions.count else { return }
        runAI(actions[sender.tag].instruction)
    }

    func updateAITarget() {
        guard aiPanelVisible else { return }
        let sel = textView.selectedRange()
        aiPanel.setTarget(sel.length > 0 ? "対象: 選んでいる \(sel.length) 文字" : "対象: 文書全体 (範囲を選ぶとそこだけ)")
    }

    private func runAI(_ instruction: String) {
        guard let window = window, let doc = hdoc else { return }
        // 設定と接続の確認が済むまでは送らない
        guard AISettings.isReady else {
            aiPanel.setReady(false)
            let alert = NSAlert()
            alert.messageText = "AI がまだ設定されていません"
            alert.informativeText = "API キーとモデルを入れて「接続テスト」に成功すると使えます。"
            alert.addButton(withTitle: "設定を開く")
            alert.addButton(withTitle: "あとで")
            alert.beginSheetModal(for: window) { r in
                if r == .alertFirstButtonReturn { SettingsWindowController.shared.show(.ai) }
            }
            return
        }
        if doc.isEncrypted {
            let alert = NSAlert()
            alert.messageText = "暗号化した文書は AI に送りません"
            alert.informativeText = "流出防止のためです。"
            alert.beginSheetModal(for: window)
            return
        }
        aiClient?.cancel()
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        let target = sel.length > 0 ? ns.substring(with: sel) : ns as String
        let limit = 200_000
        if (target as NSString).length > limit {
            let alert = NSAlert()
            alert.messageText = "文章が長すぎます"
            alert.informativeText = "\(limit) 文字まで。範囲を選んで分けて送ってください。"
            alert.beginSheetModal(for: window)
            return
        }
        let system = "あなたはテキストエディタ「さとるエディタ」に組み込まれた文章作成アシスタントです。依頼された結果だけを出力し、前置きや締めの言葉は書かないでください。元の文章がマークダウンを使っていない限り、マークダウンの装飾は使わないでください。"
        let prompt = target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? instruction
            : instruction + "\n\n対象の文章:\n<<<\n" + target + "\n>>>"
        let panel = aiPanel
        panel.begin(sel.length > 0 ? "対象: 選んでいる \(sel.length) 文字" : "対象: 文書全体")
        let client = AIClient()
        aiClient = client
        client.send(system: system, prompt: prompt, onDelta: { [weak panel] t in panel?.append(t) }) { [weak self, weak panel] err in
            panel?.end(error: err)
            // 今回使った量と料金の目安、今日の合計
            let u = client.usage
            if u.inputTokens > 0 || u.outputTokens > 0 {
                let cost = AIPricing.cost(u, provider: client.provider, model: client.model)
                let today = AIUsageLog.summary { Calendar.current.isDateInToday($0.date) }
                panel?.setUsage("今回: 入力 \(u.inputTokens)・出力 \(u.outputTokens) トークン\(u.estimated ? " (推定)" : "")\n目安 \(AIPricing.format(cost))\n今日の合計: \(today.costText)")
            }
            if self?.aiClient === client { self?.aiClient = nil }
        }
    }

    private func insertAIResult(_ text: String, replace: Bool) {
        guard !text.isEmpty else { return }
        let sel = textView.selectedRange()
        if replace && sel.length == 0 {
            NSSound.beep()
            aiPanel.setTarget("置き換えるには、先に文書の範囲を選んでください")
            return
        }
        let range = replace ? sel : NSRange(location: NSMaxRange(sel), length: 0)
        window?.makeFirstResponder(textView)
        textView.insertText(text, replacementRange: range)
    }
}

// MARK: - 用紙モード (作文用紙・A4)

private var genkoWorkKey = 0
private var a4ResizeKey = 0

extension EditorWindowController {
    var paperMode: EditorTextView.PaperMode { primary.textView.paperMode }

    /// 作文アシストのオン・オフ
    @objc func toggleGenkoAssistHM(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
    }

    @objc func setPaperModeHM(_ sender: NSMenuItem) {
        guard let m = EditorTextView.PaperMode(rawValue: sender.tag) else { return }
        applyPaperMode(m)
    }

    /// ツールバーのボタン: 通常 → 作文用紙 → A4 → 通常
    @objc func cyclePaperModeHM(_ sender: Any?) {
        applyPaperMode(EditorTextView.PaperMode(rawValue: (paperMode.rawValue + 1) % 3) ?? .normal)
    }

    func applyPaperMode(_ mode: EditorTextView.PaperMode) {
        let old = paperMode
        panes.forEach { $0.textView.paperMode = mode }
        if mode == .normal {
            guard old != .normal else { return }
            for pane in panes {
                pane.textView.setLayoutOrientation(.horizontal)
                pane.textView.minSize = .zero
                pane.textView.textContainer?.lineFragmentPadding = 5
                pane.textView.textContainerInset = NSSize(width: 4, height: 6)
            }
            for pane in panes {
                if pane.textView.layoutManager?.delegate === GenkoGlyphDelegate.shared { pane.textView.layoutManager?.delegate = nil }
                (pane.textView.layoutManager as? InvisiblesLayoutManager)?.suppressesSelectionFill = false
                (pane.textView.textContainer as? PagedTextContainer)?.pageStride = 0
                pane.textView.layoutManager?.usesFontLeading = true
            }
            highlighter.linksEnabled = true
            // 作文用紙の字送りを消す
            if let storage = primary.textView.textStorage, storage.length > 0 {
                storage.removeAttribute(.kern, range: NSRange(location: 0, length: storage.length))
            }
            panes.forEach { $0.textView.typingAttributes.removeValue(forKey: .kern) }
            // 縦書きにすると行番号・桁ルーラーの付き方が変わるので付け直す
            for pane in panes {
                pane.scrollView.verticalRulerView = pane.ruler
                pane.scrollView.horizontalRulerView = pane.columnRuler
                pane.ruler.orientation = .verticalRuler
                pane.columnRuler.orientation = .horizontalRuler
                pane.ruler.textChanged()
            }
            themeDidChangePublic()
            applyViewSettingsPublic()
            // 作文用紙で決めた大きさの制限を外す (縦書きから戻すと縦横が入れ替わって残るため最後に)
            for pane in panes {
                pane.textView.minSize = .zero
                pane.textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                pane.textView.autoresizingMask = [.width]
                pane.scrollView.tile()
            }
            // 行番号の幅が決まってから、見えている幅に合わせる
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.paperMode == .normal else { return }
                for pane in self.panes {
                    let visible = pane.scrollView.documentVisibleRect.size
                    pane.textView.setFrameSize(NSSize(width: visible.width, height: max(pane.textView.frame.height, visible.height)))
                    pane.textView.sizeToFit()
                }
            }
        } else {
            refreshPaper()
        }
        updateStatus()
    }

    /// 用紙モードの見た目を (設定が変わったあとにも) かけ直す
    func refreshPaper() {
        let mode = paperMode
        guard mode != .normal else { return }
        guard let storage = primary.textView.textStorage else { return }
        let ink = NSColor(white: 0.1, alpha: 1)
        let font: NSFont
        let style = NSMutableParagraphStyle()
        var kern: CGFloat = 0
        switch mode {
        case .genko:
            font = NSFont(name: "HiraMinProN-W3", size: 19) ?? .systemFont(ofSize: 19)
            let cell: CGFloat = 28
            panes.forEach { $0.textView.genkoCell = cell }
            // 全角 1 文字がちょうど 1 マスになるよう字送りを足す (細かい調整は genkoAdjust で 1 文字ずつ)
            kern = cell - font.pointSize
            style.minimumLineHeight = cell
            style.maximumLineHeight = cell
            // スペースや英単語のところで早めに折り返すと次の列からずれるので、1 字ずつ折り返す
            style.lineBreakMode = .byCharWrapping
            // 1 文字目もマスの真ん中に来るよう、列の頭を半分ずらす
            let head = (cell - font.pointSize) / 2 + EditorTextView.genkoAlongShift * font.pointSize
            style.firstLineHeadIndent = head
            style.headIndent = head
        case .a4:
            // 用紙 1 枚がウインドウに収まる倍率 (小さすぎると読めないので 0.7 倍まで)
            let clip = primary.scrollView.contentSize
            var L = EditorTextView.A4Layout()
            let fitH = (clip.height - EditorTextView.A4Layout.gap * 2) / 842
            let fitW = (clip.width - EditorTextView.A4Layout.gap * 2) / 595
            L.scale = max(0.7, min(fitH, fitW, 2.0))
            L.pageX = max(EditorTextView.A4Layout.gap, (clip.width - L.pageW) / 2)
            panes.forEach { $0.textView.a4Layout = L }
            // ワープロの標準: 10.5 pt・40 字 × 36 行
            font = NSFont(name: "HiraMinProN-W3", size: 10.5 * L.scale) ?? .systemFont(ofSize: 10.5 * L.scale)
            let pitch = L.textHeight / 36
            style.minimumLineHeight = pitch
            style.maximumLineHeight = pitch
        case .normal:
            return
        }
        style.lineSpacing = 0
        style.tabStops = []
        style.defaultTabInterval = font.pointSize * 4
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .paragraphStyle: style, .kern: kern]
        if mode == .genko {
            // 字をマスの左右の真ん中に寄せる (描画を測って決めた補正: フォントサイズの約 0.2 倍)
            attrs[.baselineOffset] = EditorTextView.genkoCrossShift * font.pointSize
        }
        if storage.length > 0 {
            // 手で決めた段落の寄せ (A4) は残す
            var manual: [(NSRange, Any)] = []
            storage.enumerateAttribute(.paperAlign, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
                if let v = v { manual.append((r, v)) }
            }
            storage.beginEditing()
            storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
            for (r, v) in manual { storage.addAttribute(.paperAlign, value: v, range: r) }
            storage.endEditing()
        }
        highlighter.linksEnabled = false
        highlighter.setProfile(nil) // 用紙モードでは色分けしない
        for pane in panes {
            let tv = pane.textView
            tv.typingAttributes = attrs
            tv.defaultParagraphStyle = style
            tv.font = font
            tv.insertionPointColor = ink
            tv.selectedTextAttributes = [.backgroundColor: NSColor(srgbRed: 0.75, green: 0.85, blue: 1, alpha: 1)]
            tv.showsEOF = false
            tv.highlightsCurrentLine = false
            (tv.layoutManager as? InvisiblesLayoutManager)?.showsInvisibles = false
            pane.scrollView.rulersVisible = false
            pane.scrollView.scrollerKnobStyle = .dark
            guard let tc = tv.textContainer else { continue }
            tc.lineFragmentPadding = 0
            switch mode {
            case .genko:
                tv.layoutManager?.delegate = GenkoGlyphDelegate.shared
                // 選択の塗りは自前で描く (標準の塗りだと枠線が隠れる)
                tv.selectedTextAttributes = [.backgroundColor: NSColor.clear]
                (tv.layoutManager as? InvisiblesLayoutManager)?.suppressesSelectionFill = true
                // フォント自身の行間が空の列にだけ足されて、後ろの列がずれるのを防ぐ
                tv.layoutManager?.usesFontLeading = false
                tv.setLayoutOrientation(.vertical)
                let cell = tv.genkoCell
                // 20 マス + 頭のずらし分 (21 文字目は入らない長さ)
                let lineLength = cell * CGFloat(EditorTextView.genkoRows) + cell / 2
                tv.textContainerInset = NSSize(width: 24, height: 24)
                tc.widthTracksTextView = false
                tc.heightTracksTextView = false
                // 縦書きでは container の幅が 1 行 (= 1 列) の長さ
                tc.containerSize = NSSize(width: lineLength, height: CGFloat.greatestFiniteMagnitude)
                // 縦書きでは大きさの指定も 90° 回る: 「縦に伸びる」= 画面では列が左へ増える
                tv.isVerticallyResizable = true
                tv.isHorizontallyResizable = false
                // 用紙の高さは 20 マスが必ず入る大きさに (ウインドウが低ければ縦にスクロール)
                tv.autoresizingMask = []
                pane.scrollView.hasHorizontalScroller = true
                pane.scrollView.hasVerticalScroller = true
                fitGenkoPaper(pane)
                observeClipResize(pane)
                pane.scrollView.backgroundColor = EditorTextView.paperColor
            case .a4:
                if tv.layoutManager?.delegate === GenkoGlyphDelegate.shared { tv.layoutManager?.delegate = nil }
                (tv.layoutManager as? InvisiblesLayoutManager)?.suppressesSelectionFill = false
                tv.setLayoutOrientation(.horizontal)
                // フォント自身の行間 (半角ぶん) が足されると 1 ページ 36 行に収まらないので使わない
                tv.layoutManager?.usesFontLeading = false
                let L = tv.a4Layout
                tc.widthTracksTextView = false
                tc.containerSize = NSSize(width: font.pointSize * 40 + 0.5, height: CGFloat.greatestFiniteMagnitude)
                if let paged = tc as? PagedTextContainer {
                    paged.pageStride = L.stride
                    paged.textHeight = L.textHeight
                }
                tv.textContainerInset = NSSize(width: L.pageX + L.marginLeft, height: EditorTextView.A4Layout.gap + L.marginTop)
                tv.isHorizontallyResizable = false
                tv.isVerticallyResizable = true
                tv.autoresizingMask = [.width]
                pane.scrollView.hasHorizontalScroller = false
                pane.scrollView.backgroundColor = NSColor(white: 0.55, alpha: 1)
                tv.setFrameSize(NSSize(width: pane.scrollView.contentSize.width, height: tv.frame.height))
                fitA4Pages(pane)
                observeClipResize(pane)
            case .normal:
                break
            }
            tv.needsDisplay = true
        }
        if mode == .genko { genkoAdjust() }
        if mode == .a4 {
            restorePaperAlignmentsIfNeeded()
            a4Format()
            panes.forEach { fitA4Pages($0) }
        }
    }

    // MARK: 自動整形

    /// 段落の最初の字が空白やかぎかっこなら、字下げはしない
    private func startsIndented(_ text: String) -> Bool {
        guard let f = text.first else { return true }
        return f.isWhitespace || "「『（(〈《【".contains(f)
    }

    /// 段落ごとに呼ぶ: (何番目の段落か, 改行を除いた文字列, 改行を含む範囲)
    private func forEachParagraph(_ storage: NSTextStorage, _ body: (Int, String, NSRange) -> Void) {
        let ns = storage.string as NSString
        var loc = 0
        var index = 0
        while loc < ns.length {
            let r = ns.lineRange(for: NSRange(location: loc, length: 0))
            var content = ns.substring(with: r)
            if content.hasSuffix("\n") { content.removeLast() }
            body(index, content, r)
            index += 1
            loc = NSMaxRange(r)
        }
    }

    /// 作文用紙の決まり: 題名は 3 マス下げ、名前は下寄せ (下を 1 マス空ける)、本文の段落は 1 マス下げ
    private func genkoFormat(_ storage: NSTextStorage, cell: CGFloat) {
        guard let base = primary.textView.defaultParagraphStyle else { return }
        let auto = UserDefaults.standard.bool(forKey: "genkoAutoFormat")
        let rows = EditorTextView.genkoRows
        forEachParagraph(storage) { index, text, range in
            let count = text.utf16.filter { !UTF16.isTrailSurrogate($0) }.count
            var down = 0
            if auto, count > 0 {
                if index == 0 { down = count <= rows - 3 ? 3 : 0 }
                else if index == 1 { down = count < rows ? rows - count - 1 : 0 }
                else if !startsIndented(text) { down = 1 }
            }
            let style = (base.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.firstLineHeadIndent = base.headIndent + CGFloat(down) * cell
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    /// A4 の 1 段落ぶんの書式: 手で決めた寄せ → なければ自動 (題名は中央、名前は右、本文は 1 字下げ)
    private func a4Style(index: Int, text: String, manual: String?, base: NSParagraphStyle, fontSize: CGFloat) -> NSParagraphStyle {
        let auto = UserDefaults.standard.bool(forKey: "a4AutoFormat")
        let style = (base.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        var align = "left"
        if let m = manual { align = m }
        else if auto, !text.isEmpty { align = index == 0 ? "center" : (index == 1 ? "right" : "left") }
        style.firstLineHeadIndent = 0
        style.headIndent = 0
        style.tailIndent = 0
        switch align {
        case "center": style.alignment = .center
        case "right":
            style.alignment = .right
            style.tailIndent = -fontSize // 右端を 1 字空ける
        default:
            style.alignment = .left
            if auto, manual == nil, index >= 2, !startsIndented(text) { style.firstLineHeadIndent = fontSize }
        }
        return style
    }

    func a4Format() {
        guard paperMode == .a4, let storage = primary.textView.textStorage, storage.length > 0,
              let base = primary.textView.defaultParagraphStyle, let font = primary.textView.font else { return }
        storage.beginEditing()
        forEachParagraph(storage) { index, text, range in
            let manual = storage.attribute(.paperAlign, at: range.location, effectiveRange: nil) as? String
            storage.addAttribute(.paragraphStyle, value: a4Style(index: index, text: text, manual: manual, base: base, fontSize: font.pointSize), range: range)
        }
        storage.endEditing()
    }

    /// PDF 用: A4 の書式 (寄せ・字下げ) をつけた文章
    func a4AttributedString(fontSize: CGFloat, pitch: CGFloat) -> NSAttributedString {
        let font = NSFont(name: "HiraMinProN-W3", size: fontSize) ?? .systemFont(ofSize: fontSize)
        let base = NSMutableParagraphStyle()
        base.minimumLineHeight = pitch
        base.maximumLineHeight = pitch
        let out = NSMutableAttributedString(string: primary.textView.string, attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: base])
        guard paperMode == .a4, let storage = primary.textView.textStorage else { return out }
        forEachParagraph(storage) { index, text, range in
            let manual = storage.attribute(.paperAlign, at: range.location, effectiveRange: nil) as? String
            out.addAttribute(.paragraphStyle, value: a4Style(index: index, text: text, manual: manual, base: base, fontSize: fontSize), range: range)
        }
        return out
    }

    /// 選んでいる段落の寄せを変える (0 = 自動, 1 = 左, 2 = 中央, 3 = 右)
    @objc func setParagraphAlignHM(_ sender: NSMenuItem) {
        guard paperMode == .a4, let storage = primary.textView.textStorage, storage.length > 0 else { NSSound.beep(); return }
        let ns = storage.string as NSString
        let sel = textView.selectedRange()
        let range = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: min(sel.length, ns.length - min(sel.location, ns.length))))
        guard range.length > 0 else { NSSound.beep(); return }
        let values = [nil, "left", "center", "right"]
        storage.beginEditing()
        if let v = values[max(0, min(3, sender.tag))] {
            storage.addAttribute(.paperAlign, value: v, range: range)
        } else {
            storage.removeAttribute(.paperAlign, range: range)
        }
        storage.endEditing()
        a4Format()
        panes.forEach { fitA4Pages($0) }
        hdoc?.updateChangeCount(.changeDone)
    }

    @objc private func formatCheckChanged(_ sender: NSButton) {
        guard paperMode != .normal else { return }
        UserDefaults.standard.set(sender.state == .on, forKey: paperMode == .genko ? "genkoAutoFormat" : "a4AutoFormat")
        NotificationCenter.default.post(name: .viewSettingsDidChange, object: nil)
        window?.makeFirstResponder(textView)
    }

    /// 自動整形のオン・オフ
    @objc func togglePaperAutoFormatHM(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        NotificationCenter.default.post(name: .viewSettingsDidChange, object: nil)
    }

    // 手で決めた寄せはテキストファイルに書けないので、ファイルごとに「何段落目か」で覚えておく
    private static let alignKey = "paperAlignments"

    func savePaperAlignments() {
        guard let path = hdoc?.fileURL?.path, let storage = primary.textView.textStorage else { return }
        var map: [String: String] = [:]
        forEachParagraph(storage) { index, _, range in
            if let v = storage.attribute(.paperAlign, at: range.location, effectiveRange: nil) as? String { map[String(index)] = v }
        }
        var all = UserDefaults.standard.dictionary(forKey: Self.alignKey) as? [String: [String: String]] ?? [:]
        if map.isEmpty { all.removeValue(forKey: path) } else { all[path] = map }
        UserDefaults.standard.set(all, forKey: Self.alignKey)
    }

    private func restorePaperAlignmentsIfNeeded() {
        guard let path = hdoc?.fileURL?.path, let storage = primary.textView.textStorage, storage.length > 0,
              let map = (UserDefaults.standard.dictionary(forKey: Self.alignKey) as? [String: [String: String]])?[path] else { return }
        var has = false
        storage.enumerateAttribute(.paperAlign, in: NSRange(location: 0, length: storage.length)) { v, _, stop in
            if v != nil { has = true; stop.pointee = true }
        }
        guard !has else { return }
        storage.beginEditing()
        forEachParagraph(storage) { index, _, range in
            if let v = map[String(index)] { storage.addAttribute(.paperAlign, value: v, range: range) }
        }
        storage.endEditing()
    }

    /// 作文用紙: 1 文字ずつ字送りを決めて、どの文字もちょうど 1 マスに、マスの真ん中に来るようにする。
    /// 文字 i の字送り = マス − (自分の幅 + 次の文字の幅) / 2 にすると、どの文字も (マス − 幅) / 2 の位置から始まる。
    func genkoAdjust() {
        guard paperMode == .genko, let storage = primary.textView.textStorage, storage.length > 0,
              let font = primary.textView.font else { return }
        let cell = primary.textView.genkoCell
        let em = font.pointSize
        let ctFont = font as CTFont
        let ns = storage.string as NSString
        let n = ns.length
        // 縦書きで立てて並ぶ文字 (全角) は 1em、横に寝る文字 (半角) は横幅ぶん進む
        var adv = [CGFloat](repeating: em, count: n)
        var i = 0
        while i < n {
            let c = ns.character(at: i)
            if c == 0x0A || c == 0x20 || c == 0x09 {
                // 改行・半角スペース・タブ (スペースとタブは全角の空きとして並べている: GenkoGlyphDelegate)
                adv[i] = em
            } else if UTF16.isLeadSurrogate(c) {
                adv[i] = em
                if i + 1 < n { adv[i + 1] = 0 }
                i += 2
                continue
            } else if TextMetrics.displayWidth(of: String(utf16CodeUnits: [c], count: 1)) < 2 {
                var ch = c
                var glyph: CGGlyph = 0
                if CTFontGetGlyphsForCharacters(ctFont, &ch, &glyph, 1) {
                    var size = CGSize.zero
                    CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &size, 1)
                    adv[i] = size.width
                } else {
                    adv[i] = em / 2
                }
            }
            i += 1
        }
        storage.beginEditing()
        var j = 0
        while j < n {
            let c = ns.character(at: j)
            var len = 1
            if UTF16.isLeadSurrogate(c), j + 1 < n { len = 2 }
            var next = j + len
            if next < n, ns.character(at: next) == 0x0A { next = n } // 改行の前は次の列の頭とみなす
            let nextAdv = next < n ? adv[next] : em
            // 改行に字送りが付いていると、空の列の幅がその分広がって後ろの列がずれるので 0 にする
            let kern = c == 0x0A ? 0 : cell - (adv[j] + nextAdv) / 2
            storage.addAttribute(.kern, value: kern, range: NSRange(location: j, length: len))
            j += len
        }
        genkoFormat(storage, cell: cell)
        storage.endEditing()
    }

    /// 入力のたびに字送りを直す (少しまとめて)
    func scheduleGenkoAdjust() {
        guard paperMode != .normal else { return }
        genkoWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.paperMode == .a4 {
                self.a4Format()
                self.panes.forEach { self.fitA4Pages($0) }
                self.updateStatus()
            } else {
                self.genkoAdjust()
            }
        }
        genkoWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    private var genkoWork: DispatchWorkItem? {
        get { objc_getAssociatedObject(self, &genkoWorkKey) as? DispatchWorkItem }
        set { objc_setAssociatedObject(self, &genkoWorkKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// A4: 最後のページまで用紙が全部見えるよう、高さを用紙の枚数ぶんにする
    func fitA4Pages(_ pane: EditorPane) {
        let tv = pane.textView
        guard tv.paperMode == .a4, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        lm.ensureLayout(for: tc)
        let L = tv.a4Layout
        let height = EditorTextView.A4Layout.gap + CGFloat(tv.a4PageCount) * L.stride
        tv.minSize = NSSize(width: 0, height: max(height, pane.scrollView.contentSize.height))
        tv.setFrameSize(NSSize(width: tv.frame.width, height: max(tv.frame.height, tv.minSize.height)))
        tv.sizeToFit()
        tv.needsDisplay = true
    }

    private var a4ResizeWork: DispatchWorkItem? {
        get { objc_getAssociatedObject(self, &a4ResizeKey) as? DispatchWorkItem }
        set { objc_setAssociatedObject(self, &a4ResizeKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// 作文用紙: 用紙はウインドウいっぱい以上、高さは 20 マスが必ず入る大きさ (低いウインドウでは縦にスクロール)
    private func fitGenkoPaper(_ pane: EditorPane) {
        let tv = pane.textView
        guard tv.paperMode == .genko else { return }
        let lineLength = tv.genkoCell * CGFloat(EditorTextView.genkoRows) + tv.genkoCell / 2
        let paperHeight = lineLength + tv.textContainerInset.height * 2
        let clip = pane.scrollView.contentSize
        // minSize は回った向き (width = 画面の縦, height = 画面の横) で指定する
        tv.minSize = NSSize(width: max(paperHeight, clip.height), height: clip.width)
        tv.maxSize = NSSize(width: max(paperHeight, clip.height), height: CGFloat.greatestFiniteMagnitude)
        tv.setFrameSize(NSSize(width: max(tv.frame.width, clip.width), height: max(paperHeight, clip.height)))
        tv.sizeToFit()
        tv.needsDisplay = true
    }

    private func observeClipResize(_ pane: EditorPane) {
        let clip = pane.scrollView.contentView
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: clip)
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipResized(_:)),
                                               name: NSView.frameDidChangeNotification, object: clip)
    }

    @objc private func clipResized(_ note: Notification) {
        for pane in panes where pane.scrollView.contentView === note.object as? NSView {
            fitGenkoPaper(pane)
        }
        // A4: ウインドウの大きさに合わせて用紙の倍率を決め直す (サイズ変更が止まってから)
        if paperMode == .a4 {
            a4ResizeWork?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.refreshPaper() }
            a4ResizeWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
        }
    }

    /// 状態表示用: 作文用紙なら何枚分、A4 なら何ページか
    var paperStatus: String? {
        let tv = primary.textView
        guard tv.paperMode != .normal, let lm = tv.layoutManager else { return nil }
        var lines = 0
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { _, _, _, _, _ in lines += 1 }
        lines = max(1, lines)
        switch tv.paperMode {
        case .genko: return "作文用紙 \((lines + 19) / 20) 枚 (\(lines) 行)"
        case .a4: return "A4 \(tv.a4PageCount) ページ"
        case .normal: return nil
        }
    }
}

// MARK: - PDF

extension EditorWindowController {
    /// いまの見た目のまま PDF にする (作文用紙はマス目つき縦書き、それ以外は A4)
    func writePaperPDF(to url: URL) throws {
        if paperMode == .genko {
            try GenkoPDF.write(textView: primary.textView, to: url)
        } else {
            let pitch = (842 - 99 - 85 - 0.5) / 36.0
            try PDFExport.write(text: a4AttributedString(fontSize: 10.5, pitch: CGFloat(pitch)), to: url)
        }
    }

    /// 用紙モードで保存したとき、同じ場所に同じ名前の PDF も作る
    func savePaperPDFIfNeeded(textURL: URL) {
        guard paperMode != .normal, UserDefaults.standard.bool(forKey: "paperSavePDF"),
              textURL.pathExtension.lowercased() != "pdf" else { return }
        let pdf = textURL.deletingPathExtension().appendingPathExtension("pdf")
        do {
            try writePaperPDF(to: pdf)
            remoteStatusChanged("📄 PDF も保存: \(pdf.lastPathComponent)")
        } catch {
            presentError(error)
        }
    }

    @objc func exportWordHM(_ sender: Any?) {
        guard let doc = hdoc else { return }
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["docx"]
        let name = doc.fileURL?.lastPathComponent ?? doc.displayName ?? "文書"
        panel.nameFieldStringValue = (name as NSString).deletingPathExtension + ".docx"
        panel.message = paperMode == .genko ? "Word では横書きになります (文章と段落はそのまま)" : "Word (.docx) にします"
        let text = a4AttributedString(fontSize: 10.5, pitch: 18)
        let run: (URL) -> Void = { url in
            do {
                try WordExport.write(text: text, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                NSApp.presentError(error)
            }
        }
        if let w = window {
            panel.beginSheetModal(for: w) { r in if r == .OK, let u = panel.url { run(u) } }
        } else if panel.runModal() == .OK, let u = panel.url {
            run(u)
        }
    }

    /// 印刷: 「PDF として書き出す」と同じ見た目 (作文用紙ならマス目つき、ふつうは A4・40 字 × 36 行) を一度 PDF にして印刷する
    @objc func printDocumentHM(_ sender: Any?) {
        guard hdoc != nil else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("satoru-print-\(UUID().uuidString).pdf")
        do {
            if paperMode == .genko {
                try writePaperPDF(to: url)
            } else {
                let pitch = (842 - 99 - 85 - 0.5) / 36.0
                try PDFExport.write(text: a4AttributedString(fontSize: 10.5, pitch: CGFloat(pitch)), to: url)
            }
            // 中身はメモリに読んでしまい、一時ファイルはすぐ消す (暗号化した文書の平文をディスクに残さない)
            let data = try Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            guard let pdf = PDFDocument(data: data), let info = NSPrintInfo.shared.copy() as? NSPrintInfo else {
                throw NSError(domain: "Satoru", code: 36, userInfo: [NSLocalizedDescriptionKey: "印刷の準備ができませんでした"])
            }
            // 作文用紙は、紙を横向きにして 1 枚 (400 字) を紙いっぱいに真ん中へ刷る
            let genko = paperMode == .genko
            if genko {
                info.orientation = .landscape
                info.isHorizontallyCentered = true
                info.isVerticallyCentered = true
            }
            guard let op = pdf.printOperation(for: info, scalingMode: genko ? .pageScaleToFit : .pageScaleDownToFit,
                                              autoRotate: !genko) else {
                throw NSError(domain: "Satoru", code: 36, userInfo: [NSLocalizedDescriptionKey: "印刷の準備ができませんでした"])
            }
            op.jobTitle = hdoc?.displayName ?? "文書"
            if let w = window {
                op.runModal(for: w, delegate: nil, didRun: nil, contextInfo: nil)
            } else {
                op.run()
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            NSApp.presentError(error)
        }
    }

    @objc func exportPDFHM(_ sender: Any?) {
        guard let doc = hdoc else { return }
        if paperMode == .genko {
            let panel = NSSavePanel()
            panel.allowedFileTypes = ["pdf"]
            let name = doc.fileURL?.lastPathComponent ?? doc.displayName ?? "作文"
            panel.nameFieldStringValue = (name as NSString).deletingPathExtension + ".pdf"
            panel.message = "作文用紙のまま (マス目つき・縦書き) PDF にします"
            let run: (URL) -> Void = { [weak self] url in
                do {
                    try self?.writePaperPDF(to: url)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    NSApp.presentError(error)
                }
            }
            if let w = window {
                panel.beginSheetModal(for: w) { r in if r == .OK, let u = panel.url { run(u) } }
            } else if panel.runModal() == .OK, let u = panel.url {
                run(u)
            }
            return
        }
        let pitch = (842 - 99 - 85 - 0.5) / 36.0
        PDFExport.export(text: a4AttributedString(fontSize: 10.5, pitch: CGFloat(pitch)),
                         suggestedName: doc.fileURL?.lastPathComponent ?? doc.displayName ?? "文書", from: window)
    }
}
