import AppKit
import PDFKit
import UniformTypeIdentifiers
import HinokiCore

final class EditorWindowController: NSWindowController, NSTextViewDelegate, NSMenuItemValidation, NSWindowDelegate, NSSplitViewDelegate {
    /// 上 (分割していないときはこれだけ)
    let primary: EditorPane
    /// 上下分割したときの下
    private var secondary: EditorPane?
    /// 最後にカーソルがあった面が下なら true
    private var secondaryIsActive = false
    private let splitView = NSSplitView()
    /// 編集面 + (共同編集中は) 右のチャット欄
    let editorArea = NSStackView()
    private lazy var chatPanel: ChatPanel = {
        let p = ChatPanel()
        p.onSend = { [weak self] text in self?.collabSession?.sendChat(text) }
        p.onStop = { [weak self] in self?.stopShareHM(nil) }
        return p
    }()
    /// 左のフォルダツリー (使うときに初めて作る)
    private lazy var folderPanel = FolderTreePanel()
    private var folderPanelCreated = false
    /// 左のテキスト一覧 (メモ帳のように、書いたテキストを並べる)
    private lazy var libraryPanel: TextLibraryPanel = {
        let p = TextLibraryPanel()
        p.onShowGrid = { [weak self] in self?.showLibraryGrid() }
        return p
    }()
    private var libraryPanelCreated = false
    /// いちばん左のフォルダの欄 (テキスト一覧と一緒に出し入れ)
    private lazy var folderListPanel = TextFolderPanel()
    private var libraryGrid: TextLibraryGrid?
    /// 左のサーバツリー (使うときに初めて作る)
    private lazy var remotePanel = RemoteTreePanel()
    private var remotePanelCreated = false
    /// このタブでサーバツリーを × で閉じた
    private var remoteTreeDismissed = false
    /// 共同編集 (共有中・参加中)
    private(set) var collabSession: CollabSession?
    private let statusLabel = NSTextField(labelWithString: "")
    /// 右下の「自動整形」チェック (原稿用紙・A4 のときだけ出る)
    private let formatCheck = NSButton(checkboxWithTitle: L("自動整形"), target: nil, action: nil)
    /// フッター右側: 行・列 | 選択 | 言語 | 文字コード | 改行コード (クリックで変更)
    private let statusCells = StatusCellsView()
    private var highlighter: SyntaxHighlighter!
    /// init 中はまだ document が設定されていないので自前で持つ
    private weak var ownerDocument: Document?
    private(set) var profile: LanguageProfile?
    /// タイトルに ＊ を出しているか・タブのアイコンの拡張子 (変わったときだけ付け直す)
    private var shownEdited = false
    private var shownTabIconExt: String?
    /// メニューで言語を手動指定したら、拡張子による自動判定をしない
    private var profileChosenManually = false

    var hdoc: Document? { (document as? Document) ?? ownerDocument }

    private var activePane: EditorPane { (secondaryIsActive ? secondary : nil) ?? primary }
    private var panes: [EditorPane] { [primary] + (secondary.map { [$0] } ?? []) }
    /// いまカーソルがあるテキストビュー (検索・grep・メニュー操作はこれに対して行う)
    var textView: EditorTextView { activePane.textView }
    private var ruler: LineNumberRulerView { activePane.ruler }
    var isSplit: Bool { secondary != nil }

    /// スクリーンショット用: 編集面の全体 (ルーラー・分割も含む)、文字の面、行番号の幅
    var screenshotArea: NSView { splitView }
    var screenshotTextView: EditorTextView { textView }
    var screenshotGutterWidth: CGFloat { ruler.ruleThickness }

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
        // ボタンが入りきらないときに出る「»」を「≡」の絵にする (出るたびに作り直されるので、大きさが変わるたびにかけ直す)
        for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didEndLiveResizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                DispatchQueue.main.async { EditorToolbar.restyleOverflowButton(in: window) }
            }
        }
        // 開いた直後は、ツールバーが並び終わるのを待ってから
        for delay in [0.3, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in EditorToolbar.restyleOverflowButton(in: window) }
        }
        window.toolbarStyle = .expanded
        super.init(window: window)
        window.delegate = self
        ownerDocument = document
        shouldCascadeWindows = true
        highlighter = SyntaxHighlighter(textView: primary.textView)
        NotificationCenter.default.addObserver(self, selector: #selector(genkoOrientationChanged(_:)), name: .genkoOrientationDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(librarySelectionChanged(_:)), name: TextLibrary.selectionDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(profilesDidChange),
                                               name: .profilesDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(viewSettingsDidChange),
                                               name: .viewSettingsDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applyLibraryPanel),
                                               name: TextLibrary.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applyLibraryPanel),
                                               name: .viewSettingsDidChange, object: nil)   // 追加機能で入り切りしたとき
        NotificationCenter.default.addObserver(self, selector: #selector(libraryLayoutChanged),
                                               name: TextLibrary.layoutDidChange, object: nil)   // 1 列 / 2 列
        NotificationCenter.default.addObserver(self, selector: #selector(resetPanels),
                                               name: SettingsBackup.resetPanelsNotification, object: nil)   // すべて初期状態に戻す
        NotificationCenter.default.addObserver(self, selector: #selector(applyFolderTree),
                                               name: .folderTreeDidChange, object: nil)
        applyFolderTree()
        applyLibraryPanel()
        NotificationCenter.default.addObserver(self, selector: #selector(applyRemoteTree),
                                               name: .remoteTreeDidChange, object: nil)
        applyRemoteTree()
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
        // フォーカスがないときの選択は、同じ色を少し薄くして塗る
        (tv.layoutManager as? InvisiblesLayoutManager)?.inactiveSelectionColor = Theme.selection
        tv.currentLineColor = Theme.currentLine
        let lineText = Theme.currentLineText
        tv.currentLineTextColor = lineText.alphaComponent > 0 ? lineText : nil
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
        // 横の欄 (AI・差分・チャット) が増えたら、欄ではなく本文の幅を縮める (欄が本文に重ならないように)
        splitView.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        splitView.setContentHuggingPriority(.init(100), for: .horizontal)
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
        // 大きな文書は、見えている所だけ組む (全体を組み終わるのを待たない)
        let big = (text as NSString).length > 1_000_000
        panes.forEach { $0.textView.layoutManager?.allowsNonContiguousLayout = big }
        tv.string = text
        if let storage = tv.textStorage {
            storage.setAttributes(tv.typingAttributes, range: NSRange(location: 0, length: storage.length))
        }
        panes.forEach { $0.textView.setSelectedRange(NSRange(location: 0, length: 0)) }
        tv.undoManager?.removeAllActions()
        diffBaseline = text // 差分表示の「編集前」
        panes.forEach { $0.ruler.textChanged() }
        applyProfile()
        restoreCaretPosition()
        applyFileMode()
        // 版の記録: はじめて開くテキストは、開いたときの中身を最初の版にする
        if let u = hdoc?.fileURL, hdoc?.partial == nil, hdoc?.isEncrypted == false { VersionStore.noteOpened(u) }
        updateStatus()
        updateTabIcon()
        DispatchQueue.main.async { [weak self] in PluginManager.shared.emit("open", editor: self) }
    }

    // MARK: 上下分割

    @objc func toggleSplitHM(_ sender: Any?) { toggleSplit(sideBySide: false) }
    @objc func toggleSplitSideHM(_ sender: Any?) { toggleSplit(sideBySide: true) }

    /// sideBySide: true なら左右に、false なら上下に並べる。もう分割しているとき、違う向きを選んだら向きだけ変える
    private func toggleSplit(sideBySide: Bool) {
        if secondary != nil, splitView.isVertical != sideBySide {
            splitView.isVertical = sideBySide
            splitView.adjustSubviews()
            splitView.setPosition(floor((sideBySide ? splitView.bounds.width : splitView.bounds.height) / 2), ofDividerAt: 0)
            panes.forEach { applyViewSettings(to: $0) }
            return
        }
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
            window?.makeFirstResponder(primary.textView.focusTarget)
        } else {
            guard let storage = primary.textView.textStorage else { return }
            let lower = EditorPane(sharing: storage)
            secondary = lower
            setUp(lower)
            splitView.isVertical = sideBySide
            splitView.addArrangedSubview(lower.scrollView)
            splitView.adjustSubviews()
            splitView.setPosition(floor((sideBySide ? splitView.bounds.width : splitView.bounds.height) / 2), ofDividerAt: 0)
            applyViewSettings()
            applyProfile(keepCurrent: true)
            // 下にも同じ位置を表示して、カーソルを下へ
            let sel = primary.textView.selectedRange()
            lower.textView.setSelectedRange(sel)
            lower.textView.scrollRangeToVisible(sel)
            window?.makeFirstResponder(lower.textView.focusTarget)
        }
        updateStatus()
    }

    /// 上と下のカーソルを行き来する
    @objc func switchSplitPaneHM(_ sender: Any?) {
        guard let lower = secondary else { NSSound.beep(); return }
        window?.makeFirstResponder((secondaryIsActive ? primary.textView : lower.textView).focusTarget)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 60)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, (splitView.isVertical ? splitView.bounds.width : splitView.bounds.height) - 60)
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
        updateAITab()
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
        applyRemoteTree()
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
        alert.messageText = L("指定行へ移動")
        alert.informativeText = L("行番号 (1〜{0})", total) + (countsVisualLines ? L("  ※ワープロ的な数え方") : "")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L("移動"))
        alert.addButton(withTitle: L("キャンセル"))
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
        closeDetachedAIWindow() // 取り出した AI のウインドウだけ残らないように
    }

    func reloadFromDocument() {
        guard let doc = hdoc else { return }
        load(doc.text)
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        DispatchQueue.main.async { [weak self] in self?.updateAITab() }
        window?.makeFirstResponder(primary.textView.focusTarget)
    }

    /// 本文に入力できるようにする (左のツリーからファイルを開いたあとなど)
    /// 横の欄を出したとき、本文が狭くなりすぎないようにウインドウを広げる (画面からははみ出さない)
    func fitWindowForSidePanels() {
        guard let w = window, !w.styleMask.contains(.fullScreen) else { return }
        editorArea.layoutSubtreeIfNeeded()
        let panels = editorArea.arrangedSubviews.filter { $0 !== splitView && !$0.isHidden }
            .reduce(CGFloat(0)) { $0 + max($1.fittingSize.width, $1.frame.width) }
        let minEditor: CGFloat = 520
        let needed = panels + minEditor
        let current = w.contentView?.bounds.width ?? 0
        guard needed > current, let screen = (w.screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = w.frame
        let grow = needed - current
        f.size.width = min(f.width + grow, screen.width)
        // 右にはみ出すなら左へずらす
        if f.maxX > screen.maxX { f.origin.x = max(screen.minX, screen.maxX - f.width) }
        w.setFrame(f, display: true, animate: true)
    }

    func focusEditor() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(primary.textView.focusTarget)
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
        updateAITab()
        if let w = window, let group = w.tabGroup, !group.isTabBarVisible {
            w.toggleTabBar(nil)
        }
    }

    // MARK: 言語プロファイル

    func fileURLDidChange() {
        // 別のファイルに入れ替え中は、いまの表示を新しいファイルに書かない (そのファイルの表示で開く)
        if hdoc?.switchingFile != true { rememberPaperModeForLibrary(paperMode) }
        updateTabIcon()
        if !profileChosenManually { applyProfile() }
        updateStatus()
        if folderPanelCreated { folderPanel.currentFile = hdoc?.fileURL }
        if libraryPanelCreated { libraryPanel.currentFile = hdoc?.fileURL }
        if remotePanelCreated { remotePanel.currentRemotePath = hdoc?.remote?.path }
    }

    // MARK: フォルダツリー

    /// 機能のオン・オフと「表示 > フォルダツリー」に合わせて、左のツリーを出し入れする
    /// 左のテキスト一覧を出し入れする (いちばん左に置く)
    /// 上下に並べるときの入れ物 (上にフォルダの欄、下にテキストの一覧)
    private lazy var libraryColumn: NSStackView = {
        let v = NSStackView()
        v.orientation = .vertical
        v.spacing = 0
        v.distribution = .fill
        return v
    }()
    private var libraryColumnConstraints: [NSLayoutConstraint] = []
    /// 上下 2 段のとき、テキストの一覧とフォルダの欄の間に置くバー (区別しやすく)
    private lazy var libraryDivider: NSView = {
        let v = LibraryDividerBar()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()
    private weak var libraryFitHeight: NSLayoutConstraint?
    private weak var libraryAutoCap: NSLayoutConstraint?
    /// 上下 2 段のとき、フォルダの欄の高さ (区切りのバーで変えたとき)
    static let folderPaneHeightKey = "libraryFolderPaneHeight"

    /// 左右 (フォルダの欄が左) / 上下 (フォルダの欄が上、テキストの一覧が下) に並べ直す
    private func arrangeLibraryPanels() {
        for v in [folderListPanel, libraryPanel, libraryDivider, libraryColumn] as [NSView] {
            if let sv = v.superview as? NSStackView { sv.removeArrangedSubview(v) }
            v.removeFromSuperview()
        }
        NSLayoutConstraint.deactivate(libraryColumnConstraints)
        libraryColumnConstraints = []
        if TextLibrary.oneColumn {
            // フォルダの欄の幅は一覧に合わせ、高さは 1/3 くらい
            TextLibrary.widthConstraint(of: folderListPanel)?.isActive = false
            TextLibrary.setResizeLink(folderListPanel, to: libraryPanel)   // フォルダの欄の右端をつかんでも、幅を変えられる
            // 上にフォルダの欄、下にテキストの一覧
            libraryColumn.addArrangedSubview(folderListPanel)
            libraryColumn.addArrangedSubview(libraryDivider)   // フォルダとテキストの間の区切りのバー
            libraryColumn.addArrangedSubview(libraryPanel)
            editorArea.insertArrangedSubview(libraryColumn, at: 0)
            // フォルダの欄はフォルダの数に合わせた高さ (多いときは半分まで)。残りは全部テキストの一覧
            // 区切りのバーをつかんで動かすと、その高さを覚える (ダブルクリックで、フォルダの数に合わせた高さに戻す)
            let manual = UserDefaults.standard.object(forKey: Self.folderPaneHeightKey) as? Double
            let fit = folderListPanel.heightAnchor.constraint(equalToConstant: manual.map { CGFloat($0) } ?? max(80, folderListPanel.contentHeight))
            // ウインドウの高さを変える力 (510) より弱くする: ウインドウはいつでも縮められ、フォルダの欄はそれに合わせて縮む
            fit.priority = NSLayoutConstraint.Priority(499)
            libraryFitHeight = fit
            let autoCap = folderListPanel.heightAnchor.constraint(lessThanOrEqualTo: libraryColumn.heightAnchor, multiplier: 0.5)
            libraryAutoCap = autoCap
            libraryColumnConstraints = [
                fit,
                folderListPanel.heightAnchor.constraint(lessThanOrEqualTo: libraryColumn.heightAnchor, multiplier: 0.5),   // 半分まで (入りきらないフォルダは中でスクロール)
                folderListPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
                folderListPanel.widthAnchor.constraint(equalTo: libraryPanel.widthAnchor),
            ]
            NSLayoutConstraint.activate(libraryColumnConstraints)
            autoCap.isActive = manual == nil
            folderListPanel.onContentHeightChange = { [weak self] h in
                guard UserDefaults.standard.object(forKey: Self.folderPaneHeightKey) == nil else { return }
                self?.libraryFitHeight?.constant = max(80, h)
            }
            if let bar = libraryDivider as? LibraryDividerBar {
                var start: CGFloat = 0
                bar.onDragBegan = { [weak self] in start = self?.folderListPanel.frame.height ?? 0 }
                bar.onDrag = { [weak self] dy in
                    guard let self = self else { return }
                    let maxH = self.libraryColumn.frame.height * 0.5
                    let h = min(maxH, max(50, start + dy))
                    self.libraryAutoCap?.isActive = false
                    self.libraryFitHeight?.constant = h
                    UserDefaults.standard.set(Double(h), forKey: Self.folderPaneHeightKey)
                }
                bar.onDoubleClick = { [weak self] in
                    guard let self = self else { return }
                    UserDefaults.standard.removeObject(forKey: Self.folderPaneHeightKey)
                    self.libraryAutoCap?.isActive = true
                    NSAnimationContext.runAnimationGroup { c in
                        c.duration = 0.2
                        c.allowsImplicitAnimation = true
                        self.libraryFitHeight?.constant = max(80, self.folderListPanel.contentHeight)
                        self.libraryColumn.layoutSubtreeIfNeeded()
                    }
                }
            }
        } else {
            TextLibrary.widthConstraint(of: folderListPanel)?.isActive = true
            editorArea.insertArrangedSubview(folderListPanel, at: 0)
            editorArea.insertArrangedSubview(libraryPanel, at: 1)
        }
    }

    /// すべて初期状態に戻した: 欄の開け閉めと並び方を、はじめの状態にする
    @objc private func resetPanels() {
        if aiWindow != nil { toggleAIDetached(animated: false) }
        if aiPanelVisible { showAIPanel(false) }
        if diffPanelVisible { showDiffPanel(false) }
        remoteTreeDismissed = false
        applyRemoteTree()
        if libraryPanelCreated { arrangeLibraryPanels() }
        applyLibraryPanel()
        updateAITab()
    }

    @objc private func libraryLayoutChanged() {
        guard libraryPanelCreated else { return }
        arrangeLibraryPanels()
        applyLibraryPanel()
    }

    @objc private func applyLibraryPanel() {
        if TextLibrary.isVisible && !remoteTreeShown {
            if !libraryPanelCreated {
                libraryPanelCreated = true
                arrangeLibraryPanels()
                // 一覧の検索欄に入力の場所を取られないよう、本文に戻す
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, let w = self.window, (w.firstResponder as? NSTextView)?.isFieldEditor == true else { return }
                    w.makeFirstResponder(self.textView.focusTarget)
                }
            }
            // 左はしから滑らせて出す (上下のときは入れ物ごと、左右のときは 2 つの欄をいっしょに)
            if TextLibrary.oneColumn {
                libraryPanel.isHidden = false
                folderListPanel.isHidden = false
                slideSide([libraryColumn], open: true, fromLeft: true)
            } else {
                slideSide([folderListPanel, libraryPanel], open: true, fromLeft: true)
            }
            libraryPanel.currentFile = hdoc?.fileURL
        } else if libraryPanelCreated {
            slideSide(TextLibrary.oneColumn ? [libraryColumn] : [folderListPanel, libraryPanel], open: false, fromLeft: true)
        }
    }

    /// テキスト一覧をカード (サムネ) で、本文の場所いっぱいに出す。もう一度押すか「閉じる」・Esc で戻る
    @objc func showLibraryGridHM(_ sender: Any?) {
        if libraryGrid != nil { closeLibraryGrid() } else { showLibraryGrid() }
    }

    func showLibraryGrid() {
        guard libraryGrid == nil, let content = window?.contentView else { return }
        let g = TextLibraryGrid()
        g.onClose = { [weak self] in self?.closeLibraryGrid() }
        content.addSubview(g)
        NSLayoutConstraint.activate([
            g.topAnchor.constraint(equalTo: editorArea.topAnchor),
            g.bottomAnchor.constraint(equalTo: editorArea.bottomAnchor),
            g.leadingAnchor.constraint(equalTo: editorArea.leadingAnchor),
            g.trailingAnchor.constraint(equalTo: editorArea.trailingAnchor),
        ])
        libraryGrid = g
        window?.makeFirstResponder(g)
    }

    func closeLibraryGrid() {
        libraryGrid?.removeFromSuperview()
        libraryGrid = nil
        window?.makeFirstResponder(textView.focusTarget)
    }

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

    /// 機能のオン・オフと「サーバツリー」に合わせて、左のサーバツリーを出し入れする
    @objc private func applyRemoteTree() {
        // サーバのファイルを編集しているタブは、閉じるボタンで消すまで自動で出す
        let remoteTab = hdoc?.remote != nil && !remoteTreeDismissed
        let show = EditorExtension.server.isOn && (RemoteTree.isVisible || remoteTab)
        if show {
            if !remotePanelCreated {
                remotePanelCreated = true
                // フォルダツリーがあればその右に
                editorArea.insertArrangedSubview(remotePanel, at: folderPanelCreated ? 1 : 0)
            }
            remotePanel.isHidden = false
            remotePanel.currentRemotePath = hdoc?.remote?.path
            remotePanel.reload(nil)
        } else if remotePanelCreated {
            remotePanel.isHidden = true
        }
        applyLibraryPanel()   // サーバのツリーを出しているあいだは、手元の履歴 (テキスト一覧) を隠す
    }


    /// サーバのファイルを開いた・開き直したとき: このタブにサーバツリーを出し、そのサーバに合わせる
    func remoteDocumentChanged() {
        updateTabIcon()
        guard let r = hdoc?.remote else { return applyRemoteTree() }
        remoteTreeDismissed = false
        if RemoteTree.server?.id != r.server.id { RemoteTree.setServer(r.server, show: false) }
        applyRemoteTree()
    }

    /// このタブでサーバツリーが出ているか
    var remoteTreeShown: Bool { remotePanelCreated && !remotePanel.isHidden }

    /// サーバツリーの × を押した (このタブでは自動で出さない)
    func dismissRemoteTree() {
        remoteTreeDismissed = true
        RemoteTree.setVisible(false)
        applyRemoteTree()
    }

    /// テキスト一覧の左の欄で選んでいるフォルダ (タブごと。新しいタブは開いたときのものから始める)
    var librarySelection = TextLibrary.selectedGroup

    /// フォルダを選び直したら、いま前にあるタブのものとして覚える (ほかのタブは前のまま)
    @objc private func librarySelectionChanged(_ note: Notification) {
        // 前にあるタブ (アプリが裏にあるときは、いちばん手前のエディタ)
        let front = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.orderedWindows.first { $0.windowController is EditorWindowController }
        guard let w = window, w === front else { return }
        librarySelection = TextLibrary.selectedGroup
    }

    /// タブを切り替えたとき: ほかのタブでのツリーの開き具合・スクロール位置を引き継ぐ
    func windowDidBecomeKey(_ notification: Notification) {
        // テキスト一覧のフォルダは、このタブで選んでいたものに戻す
        if TextLibrary.selectedGroup != librarySelection { TextLibrary.selectedGroup = librarySelection }
        if folderPanelCreated, !folderPanel.isHidden { folderPanel.syncFromShared() }
        // サーバツリー: このタブで開いているファイルを選ぶ
        if remotePanelCreated, !remotePanel.isHidden {
            remotePanel.currentRemotePath = hdoc?.remote?.path
            remotePanel.syncFromShared()
        }
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

    /// 名前 (拡張子) のない文書で、言語が「テキスト」のままなら、中身から言語の見当をつけて色分けする
    /// (新規の文書に AI がコードを入れたとき、色分けされず全部白い字になるのを防ぐ)
    func guessLanguageIfUnnamed() {
        guard let doc = hdoc, doc.fileURL == nil, doc.remote == nil, profile == nil, !profileChosenManually,
              let name = LanguageGuess.guess(textView.string), let p = Profiles.store.profile(named: name) else { return }
        profile = p
        applyProfile(keepCurrent: true)
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
            tv.completion.language = profile?.name
            tv.completion.keywords = profile?.keywords ?? []
            tv.completion.types = profile?.types ?? []
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

    /// 原稿用紙のあいだは文字の面を画面から外しているので、取り消しの記録先をここで教える
    func undoManager(for view: NSTextView) -> UndoManager? { hdoc?.undoManager }

    func textDidChange(_ notification: Notification) {
        // メモ帳のような自動保存 (打った文字だけでなく、AI・音声入力などで入った文字でも)
        hdoc?.touched = true
        hdoc?.scheduleLibrarySave()
        highlighter.textDidChange()
        scheduleGenkoAdjust()
        scheduleRemoteAutoSave()
        // 原稿用紙の字数はカーソルが動かない書き換え (取り消しなど) でも変わる
        if paperMode == .genko { DispatchQueue.main.async { [weak self] in self?.updateStatus() } }
    }

    // MARK: ステータスバー

    func updateStatus() {
        guard let doc = hdoc ?? (textView.window?.windowController?.document as? Document) else {
            statusLabel.stringValue = ""
            return
        }
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        let loc = min(sel.location, ns.length)
        let (lineNo, lineStart) = ruler.line(at: loc)
        let line = lineNo + 1
        // とても長い 1 行では、桁を数えるのに全角・半角を見分けない (遅くなるので)
        let col = loc - lineStart > 200_000 ? loc - lineStart + 1
            : TextMetrics.displayWidth(of: ns.substring(with: NSRange(location: lineStart, length: loc - lineStart))) + 1
        // 左側: サーバ・暗号化・用紙の状態
        var notes: [String] = []
        if let p = paperStatus { notes.append(p) }
        // 暗号化の種類は、右側の項目 (押すと変えられる) に出す。流出防止を使っていないときだけ、ここに出す
        if let k = doc.encryptionKey, !EditorExtension.encryption.isOn {
            notes.append(L("🔒 暗号化 ({0})", PasswordPrompt.shortName(k.kind)))
        }
        if let r = remoteStatus { notes.append(r) }
        if let p = doc.partial {
            notes.append(L("一部分だけ読み込み中: {0} 〜 {1} (全体 {2})", HugeFile.sizeText(p.offset), HugeFile.sizeText(p.end), HugeFile.sizeText(p.fileSize)))
        }
        // 右下の自動整形チェック
        let mode = paperMode
        // 横書きの原稿用紙では作文の自動整形を使わないので、チェックも出さない
        formatCheck.isHidden = mode == .normal || (mode == .genko && horizontalGenko)
        if mode != .normal {
            formatCheck.title = mode == .genko ? L("作文の自動整形") : L("A4 の自動整形")
            formatCheck.toolTip = mode == .genko ? L("題名 3 マス下げ・名前 下寄せ・段落 1 マス下げ") : L("題名 中央・名前 右寄せ・段落 1 字下げ")
            formatCheck.state = UserDefaults.standard.bool(forKey: mode == .genko ? "genkoAutoFormat" : "a4AutoFormat") ? .on : .off
        }
        statusLabel.stringValue = notes.joined(separator: "      ")
        statusLabel.toolTip = statusLabel.stringValue
        // 右側: 項目ごとに区切って右寄せ。クリックで変更できる
        var items: [StatusCellsView.Item] = []
        if mode == .genko, let i = activePane.genkoView?.info {
            // 原稿用紙: 字数・枚数・カーソルのマス
            items.append(.init(id: "chars", title: L("{0} 字", i.chars), tip: L("文字数 (改行は数えません)")))
            items.append(.init(id: "sheets", title: L("{0} / {1} 枚", i.sheet, i.sheets), tip: L("いまの用紙 / 全部の枚数 (1 枚 400 字)")))
            items.append(.init(id: "cell", title: (horizontalGenko ? L("{0} 行 {1} マス", i.column, i.row) : L("{0} 列 {1} マス", i.column, i.row)), tip: L("カーソルの位置")))
            if i.selected > 0 { items.append(.init(id: "sel", title: L("選択 {0} 字", i.selected), tip: L("選んでいる文字数"))) }
        } else {
            items.append(.init(id: "pos", title: L("{0} 行  {1} 列", line, col), tip: L("クリックで指定行へ移動")))
            if sel.length > 0 { items.append(.init(id: "sel", title: L("{0} 文字選択", sel.length), tip: L("選んでいる文字数"))) }
        }
        if let s = collabSession, s.isActive {
            // 共同編集中: いま何人つながっているか (自分も入れて)。押すとチャット欄
            let n = max(1, s.users.count)
            items.append(.init(id: "collab", title: "👥 " + (s.role == .host ? L("共有中 {0} 人", n) : L("参加中 {0} 人", n)),
                               tip: L("共同編集でつながっている人数 (自分も入れて)。クリックでチャットを出す / しまう")))
        }
        if EditorExtension.ai.isOn {
            // AI を使える状態かどうかが、いつでも分かるように
            let ok = AISettings.isReady
            items.append(.init(id: "ai", title: ok ? "●" : L("AI 未設定"),
                               tip: ok ? L("接続を確認済みです。クリックで AI アシスタントを出す / しまう") : L("まだ使えません。クリックで AI の設定を開く")))
        }
        if EditorExtension.encryption.isOn {
            // 暗号化の種類。押すと方法を選び直せる
            if let k = doc.encryptionKey {
                items.append(.init(id: "crypt", title: "🔒 " + PasswordPrompt.shortName(k.kind), tip: L("暗号化しています。クリックで暗号化の方法を変更")))
            } else {
                items.append(.init(id: "crypt", title: "🔓 " + L("暗号化なし"), tip: L("暗号化していません。クリックで暗号化の方法を選ぶ")))
            }
        }
        if EditorExtension.paper.isOn {
            // 用紙: 標準 / 原稿用紙 / A4。押すと切り替えられる
            items.append(.init(id: "paper", title: Self.paperModeName(paperMode, horizontal: horizontalGenko), tip: L("用紙 (クリックで切り替え)")))
        }
        items.append(.init(id: "lang", title: profile.map { L($0.name) } ?? L("テキスト"), tip: L("クリックで言語 (色分け・タブ幅) を変更")))
        items.append(.init(id: "enc", title: doc.encoding.displayName, tip: L("クリックで文字コードを変更")))
        items.append(.init(id: "eol", title: doc.lineEnding.displayName, tip: L("クリックで改行コードを変更")))
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
        case "collab":
            toggleChatHM(nil)
            return
        case "ai":
            if AISettings.isReady { toggleAIHM(nil) } else { SettingsWindowController.shared.show(.ai) }
            return
        case "paper":
            let horizontal = horizontalGenko
            _ = horizontal
            let cur = currentPaperID
            for (id, label) in PaperCandidates.all where PaperCandidates.isOn(id) || id == cur {
                let title = L(label), on = id == cur
                let tag = id == "normal" ? 0 : id == "genkoV" ? 1 : id == "a4" ? 2 : id == "genkoH" ? Self.horizontalGenkoTag : 0
                let i = NSMenuItem(title: title, action: #selector(setPaperModeHM(_:)), keyEquivalent: "")
                i.target = self
                i.tag = tag
                i.state = on ? .on : .off
                menu.addItem(i)
            }
        case "lang":
            menu.addItem(entry(L("自動 (拡張子で判定)"), #selector(setLanguageHM(_:)), nil, on: !profileChosenManually))
            menu.addItem(.separator())
            for p in Profiles.store.profiles {
                menu.addItem(entry(L(p.name), #selector(setLanguageHM(_:)), p.name, on: profileChosenManually && profile?.name == p.name))
            }
        case "enc":
            let head = NSMenuItem(title: L("保存する文字コード"), action: nil, keyEquivalent: "")
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
            let holder = NSMenuItem(title: L("文字化けしているとき: 指定して開き直す"), action: nil, keyEquivalent: "")
            holder.submenu = reopen
            holder.isEnabled = doc.fileURL != nil && !doc.isEncrypted
            menu.addItem(holder)
        case "crypt":
            let head = NSMenuItem(title: doc.isEncrypted ? L("暗号化の方法を変える") : L("暗号化の方法を選ぶ"), action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            let current = doc.encryptionKey?.kind
            for (i, kind) in PasswordPrompt.kindOrder.enumerated() {
                let item = entry(PasswordPrompt.shortName(kind), #selector(changeEncryptionKindHM(_:)), String(i), on: kind == current)
                item.isEnabled = collabSession?.isActive != true
                menu.addItem(item)
            }
            // 鍵の変更 (方法はそのままで、パスワードや鍵だけを新しくする) は別の枠にする
            menu.addItem(.separator())
            let rekey = entry(L("鍵の変更…"), #selector(changeEncryptionKeyHM(_:)), nil, on: false)
            rekey.isEnabled = doc.isEncrypted && collabSession?.isActive != true
            menu.addItem(rekey)
            let off = entry(L("暗号化を解除…"), #selector(decryptDocumentHM(_:)), nil, on: false)
            off.isEnabled = doc.isEncrypted
            menu.addItem(off)
            menu.addItem(.separator())
            menu.addItem(entry(L("この文書の暗号化の設定…"), #selector(openEncryptionSettingsHM(_:)), nil, on: false))
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

    /// 巨大なファイルの、読み込む範囲を選び直す (全部読み込むこともできる)
    @objc func changePartialRangeHM(_ sender: Any?) {
        guard let doc = hdoc, let url = doc.fileURL, let size = try? PartialFile.fileSize(of: url) else { NSSound.beep(); return }
        if doc.isDocumentEdited {
            let alert = NSAlert()
            alert.messageText = L("変更を保存していません")
            alert.informativeText = L("読み込む範囲を変えると、保存していない変更はなくなります。")
            alert.addButton(withTitle: L("変更を破棄して続ける"))
            alert.addButton(withTitle: L("キャンセル"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        switch HugeFile.ask(name: url.lastPathComponent, size: size, current: doc.partial) {
        case .cancel: return
        case .whole: doc.partial = nil; doc.nextPart = (0, size)
        case .part(let o, let l): doc.nextPart = (o, l)
        }
        do {
            try doc.revert(toContentsOf: url, ofType: doc.fileType ?? DocumentController.textType)
        } catch {
            presentError(error)
        }
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
            alert.messageText = L("変更を破棄して {0} で開き直しますか？", e.displayName)
            alert.addButton(withTitle: L("開き直す"))
            alert.addButton(withTitle: L("キャンセル"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            doc.apply(try TextCodec.decode(try doc.partial.map { try PartialFile.read(url, $0) } ?? Data(contentsOf: url, options: .mappedIfSafe), as: e))
            doc.updateChangeCount(.changeCleared)
        } catch {
            presentError(error)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let doc = hdoc else { return false }
        let raw = item.representedObject as? String
        switch item.action {
        // メニュー「公開」: いまのファイルが公開中のときだけ使える
        case #selector(EditorWindowController.updatePublishedHM(_:)):
            // 公開してから書き換えたときだけ押せる
            return publishedNeedsUpdate
        case #selector(EditorWindowController.openPublishedHM(_:)):
            // 公開中なら「公開中ページ表示（id:xxxx）」と、どのページかを出す
            let r = doc.fileURL.flatMap { ShareLink.record(for: $0) }
            item.title = r.map { L("公開中ページ表示（id:{0}）", $0.id) } ?? L("公開中ページ表示")
            return r != nil
        case #selector(EditorWindowController.publishSettingsHM(_:)),
             #selector(EditorWindowController.copyPublishedLinkHM(_:)), #selector(EditorWindowController.unpublishCurrentHM(_:)):
            return doc.fileURL.flatMap { ShareLink.record(for: $0) } != nil
        case #selector(EditorWindowController.togglePrivacyCheckHM(_:)):
            item.state = UserDefaults.standard.bool(forKey: ShareLink.privacyCheckOffKey) ? .off : .on
            return true
        case #selector(EditorWindowController.toggleDiffHM(_:)):
            item.state = diffPanelVisible ? .on : .off
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
            item.state = isSplit && !splitView.isVertical ? .on : .off
        case #selector(EditorWindowController.toggleSplitSideHM(_:)):
            item.state = isSplit && splitView.isVertical ? .on : .off
        case #selector(EditorWindowController.switchSplitPaneHM(_:)):
            return isSplit
        case #selector(EditorWindowController.changePartialRangeHM(_:)):
            return doc.fileURL != nil && doc.encryptionKey == nil
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
            let horizontal = horizontalGenko
            switch item.tag {
            case Self.horizontalGenkoTag: item.state = paperMode == .genko && horizontal ? .on : .off
            case EditorTextView.PaperMode.genko.rawValue: item.state = paperMode == .genko && !horizontal ? .on : .off
            default: item.state = item.tag == paperMode.rawValue ? .on : .off
            }
            // 設定で外した候補は出さない
            if let id = PaperCandidates.id(forTag: item.tag) { item.isHidden = !PaperCandidates.isOn(id) && item.state != .on }
        case #selector(EditorWindowController.decryptDocumentHM(_:)),
             #selector(EditorWindowController.changeEncryptionKeyHM(_:)),
             #selector(EditorWindowController.changeEncryptionMethodHM(_:)):
            return doc.isEncrypted && collabSession?.isActive != true
        case #selector(EditorWindowController.encryptDocumentHM(_:)):
            return !doc.isEncrypted && collabSession?.isActive != true
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
    var collabTitle: String { hdoc?.displayName ?? L("共有") }

    /// 参加した側: 届いた状態でこのウインドウを共同編集にする
    func attachCollab(_ session: CollabSession) {
        collabSession = session
        session.attach(self)
        showChat(true)
        chatPanel.setAddress(nil)
        chatPanel.setStopTitle(L("抜ける"), enabled: true)
        chatPanel.append(name: nil, color: nil, text: L("共同編集に参加しました。ここでチャットできます。"))
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
        if !s.isActive { chatPanel.setStopTitle(L("終了しました"), enabled: false) }
        updateStatus() // フッターの人数も
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
            fitWindowForSidePanels()
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
            alert.messageText = L("暗号化した文書は共有できません")
            alert.informativeText = L("先に暗号化を解除してください。")
            alert.beginSheetModal(for: window)
            return
        }
        guard Prefs.bool("collabEnabled") else {
            let alert = NSAlert()
            alert.messageText = L("共有機能はオフになっています")
            alert.informativeText = L("「追加機能 > 共同編集」でオンにしてください。")
            alert.beginSheetModal(for: window)
            return
        }
        if let s = collabSession, s.isActive {
            showChat(true)
            chatPanel.focusInput()
            return
        }
        let alert = NSAlert()
        alert.messageText = L("この文書を共有します")
        alert.informativeText = L("アドレスとコードが出るので、相手に伝えてください。")
        let name = NSTextField(string: UserDefaults.standard.string(forKey: "collabName") ?? CollabSession.computerName)
        let port = NSTextField(string: String(UserDefaults.standard.integer(forKey: "collabPort") > 0 ? UserDefaults.standard.integer(forKey: "collabPort") : Int(CollabSession.defaultPort)))
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: L("表示名")), name],
            [NSTextField(labelWithString: L("ポート")), port],
        ])
        grid.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
        name.widthAnchor.constraint(equalToConstant: 220).isActive = true
        alert.accessoryView = grid
        alert.addButton(withTitle: L("共有を始める"))
        alert.addButton(withTitle: L("キャンセル"))
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .alertFirstButtonReturn else { return }
            let n = name.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? CollabSession.computerName : name.stringValue
            guard let p = UInt16(port.stringValue.trimmingCharacters(in: .whitespaces)), p >= 1024 else {
                self.presentError(NSError(domain: "Satoru", code: 11, userInfo: [NSLocalizedDescriptionKey: L("ポートは 1024〜65535 の数字にしてください")]))
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
        let local = addrs.first.map { "\($0):\(p)" }
        showChat(true)
        let code = collabSession?.code ?? ""
        // インターネット側の IP (グローバル IP) を調べるあいだは、LAN の中の IP を出しておく
        chatPanel.setAddress(local ?? L("(IP アドレスが見つかりません):{0}", p), code: code)
        chatPanel.setStopTitle(L("共有を終了"), enabled: true)
        chatPanel.append(name: nil, color: nil, text: L("共有を始めました (名前: {0}、ポート {1})。", name, p))
        chatPanel.append(name: nil, color: nil, text: L("インターネット側の IP アドレスを調べています…"))
        collabUsersChanged()
        CollabSession.publicAddress { [weak self] ip in
            guard let self = self, let session = self.collabSession, session.isActive else { return }
            if let ip = ip {
                let addr = "\(ip):\(p)"
                self.chatPanel.setAddress(addr, code: code)
                self.chatPanel.append(name: nil, color: nil, text: L("相手に「{0}」とコード「{1}」を伝えてください。", addr, code))
                // グローバル IP でつながるのは、ルーターがこの Mac へ通してくれるときだけ
                self.chatPanel.append(name: nil, color: nil, text: L("インターネット越しにつなぐには、ルーターで「ポート {0} (TCP) をこの Mac ({1}) へ転送する」設定が要ります。", p, addrs.first ?? "?"))
                if let l = local {
                    self.chatPanel.append(name: nil, color: nil, text: L("同じ Wi-Fi・LAN の中の人は「{0}」でつながります。", l))
                }
            } else {
                // 調べられなかった (ネットにつながっていない など) ときは、LAN の中の IP のまま
                let addr = local ?? L("(IP アドレスが見つかりません):{0}", p)
                self.chatPanel.append(name: nil, color: nil, text: L("インターネット側の IP アドレスを調べられませんでした。同じ Wi-Fi・LAN の中の人には「{0}」とコード「{1}」を伝えてください。", addr, code))
            }
            if addrs.count > 1 {
                self.chatPanel.append(name: nil, color: nil, text: L("ほかのアドレス: ") + addrs.dropFirst().map { "\($0):\(p)" }.joined(separator: "、"))
            }
        }
    }

    @objc func stopShareHM(_ sender: Any?) {
        guard let s = collabSession, s.isActive else { return }
        s.stop()
        chatPanel.setAddress(nil)
        chatPanel.append(name: nil, color: nil, text: s.role == .host ? L("共有を終了しました。") : L("共同編集から抜けました。"))
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

    /// 暗号化している文書は、ウインドウのタイトルとタブのファイル名の前に鍵マークを付ける。
    /// 編集して保存していない文書は、名前の後ろに ＊ を付ける (保存すると消える)
    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        // 編集して保存していないときは、名前の後ろに「 ＊」
        let edited = shownEdited ? " " + L("＊") : ""
        // Finder の設定で拡張子を隠していても、タブ・タイトルには拡張子まで出す (.txt / .html など)
        var name = displayName
        if let u = hdoc?.fileURL, hdoc?.remote == nil, !u.pathExtension.isEmpty, name == u.deletingPathExtension().lastPathComponent {
            name = u.lastPathComponent
        }
        return (hdoc?.isEncrypted == true ? "🔒 " + name : name) + edited
    }

    /// 編集した・保存したで、タイトルの ＊ を付け直す (変わったときだけ)
    /// 文書が「編集済み」になった・保存で解けたときに AppKit が呼ぶ (閉じるボタンの点と同じ合図)
    override func setDocumentEdited(_ dirtyFlag: Bool) {
        super.setDocumentEdited(dirtyFlag)
        editedStateChanged(dirtyFlag)
    }

    func editedStateChanged(_ flag: Bool? = nil) {
        let edited = flag ?? (hdoc?.isDocumentEdited == true)
        guard edited != shownEdited else { return }
        shownEdited = edited
        // 保存した (または取り消しで元に戻った) ら、書き換えた行の目印を消す
        if !edited {
            panes.forEach { $0.ruler.clearEditedMarks() }
            diffBaseline = textView.string // 保存したら、それを新しい「編集前」に
        }
        synchronizeWindowTitleWithDocumentName()
    }

    /// タブに、ファイルの種類のアイコンを出す
    func updateTabIcon() {
        guard let w = window else { return }
        let name = hdoc?.remote.map { ($0.path as NSString).lastPathComponent } ?? hdoc?.fileURL?.lastPathComponent ?? ""
        let ext = (name as NSString).pathExtension.lowercased()
        // 手元のファイルはそのファイル自身のアイコン (Finder と同じ)、サーバのファイルは種類のアイコン
        let local = hdoc?.remote == nil ? hdoc?.fileURL?.path : nil
        let key = local ?? ("." + ext)
        guard key != shownTabIconExt || w.tab.accessoryView == nil else { return }
        shownTabIconExt = key
        let type = ext.isEmpty ? UTType.plainText : (UTType(filenameExtension: ext) ?? .plainText)
        let image = local.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSWorkspace.shared.icon(for: type)
        image.size = NSSize(width: 16, height: 16)
        let iv = NSImageView(image: image)
        iv.imageScaling = .scaleProportionallyDown
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: 16).isActive = true
        iv.heightAnchor.constraint(equalToConstant: 16).isActive = true
        w.tab.accessoryView = iv
    }

    /// 暗号化して保存する (暗号化済みならパスワードを変える)
    @objc func encryptDocumentHM(_ sender: Any?) {
        guard let doc = hdoc else { return }
        if collabSession?.isActive == true {
            NSSound.beep()
            return
        }
        let name = doc.fileURL?.lastPathComponent ?? doc.displayName ?? L("この文書")
        guard let key = PasswordPrompt.createKey(for: name) else { return }
        doc.encryptionKey = key
        doc.updateChangeCount(.changeDone)
        doc.save(nil)
    }

    /// ステータスバーから暗号化の方法を選び直す。選んだ方法で鍵を作り直して保存する
    @objc func changeEncryptionKindHM(_ sender: NSMenuItem) {
        guard let i = Int(sender.representedObject as? String ?? ""), PasswordPrompt.kindOrder.indices.contains(i) else { return }
        reencrypt(with: PasswordPrompt.kindOrder[i])
    }

    /// 暗号化の方法を変える (方法を選ぶ画面から)
    @objc func changeEncryptionMethodHM(_ sender: Any?) {
        reencrypt(with: nil)
    }

    /// 鍵の変更: 方法はそのままで、パスワード・パスコード・鍵ファイルなどを新しくする
    @objc func changeEncryptionKeyHM(_ sender: Any?) {
        guard let kind = hdoc?.encryptionKey?.kind else { return }
        reencrypt(with: kind, keyOnly: true)
    }

    /// 新しい鍵で暗号化して保存し直す。kind が nil なら方法を選ぶところから
    private func reencrypt(with kind: FileCrypto.Kind?, keyOnly: Bool = false) {
        guard let doc = hdoc else { return }
        if collabSession?.isActive == true {
            NSSound.beep()
            return
        }
        let name = doc.fileURL?.lastPathComponent ?? doc.displayName ?? L("この文書")
        let key = keyOnly ? PasswordPrompt.createKey(for: name, onlyKind: kind)
                          : PasswordPrompt.createKey(for: name, initialKind: kind ?? doc.encryptionKey?.kind)
        guard let key = key else { return }
        doc.encryptionKey = key
        doc.updateChangeCount(.changeDone)
        doc.save(nil)
    }

    /// この文書の暗号化の設定 (ステータスバーとは別の画面): いまの方法を見て、方法の変更・鍵の変更・解除を選ぶ
    @objc func openEncryptionSettingsHM(_ sender: Any?) {
        guard let doc = hdoc, let window = window else { return }
        let alert = NSAlert()
        alert.messageText = L("この文書の暗号化の設定")
        let popup = NSPopUpButton()
        PasswordPrompt.kindOrder.forEach { popup.addItem(withTitle: PasswordPrompt.shortName($0)) }
        let current = doc.encryptionKey?.kind
        popup.selectItem(at: current.flatMap { k in PasswordPrompt.kindOrder.firstIndex(of: k) } ?? PasswordPrompt.defaultKindIndex)
        let label = NSTextField(labelWithString: L("暗号化の方法"))
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        row.frame = NSRect(origin: .zero, size: NSSize(width: 340, height: 26))
        alert.accessoryView = row
        if let k = current {
            alert.informativeText = L("いま: 🔒 {0} で暗号化しています。", PasswordPrompt.shortName(k))
                + "\n" + L("「方法を変える」は下で選んだ方法で、「鍵の変更」は同じ方法のまま新しい鍵で暗号化し直します。")
            alert.addButton(withTitle: L("方法を変える"))
            alert.addButton(withTitle: L("鍵の変更…"))
            alert.addButton(withTitle: L("暗号化を解除…"))
            alert.addButton(withTitle: L("閉じる"))
        } else {
            alert.informativeText = L("いま: 🔓 暗号化していません。下で選んだ方法で暗号化して保存できます。")
            alert.addButton(withTitle: L("暗号化する"))
            alert.addButton(withTitle: L("閉じる"))
        }
        let locked = collabSession?.isActive == true
        alert.buttons.dropLast().forEach { $0.isEnabled = !locked }
        if locked { alert.informativeText += "\n" + L("共同編集のあいだは変えられません。") }
        alert.beginSheetModal(for: window) { [weak self] r in
            guard let self = self else { return }
            let chosen = PasswordPrompt.kindOrder[max(0, popup.indexOfSelectedItem)]
            // シートが閉じてから次の画面を出す
            DispatchQueue.main.async {
                if current == nil {
                    if r == .alertFirstButtonReturn { self.reencrypt(with: chosen) }
                    return
                }
                switch r {
                case .alertFirstButtonReturn: self.reencrypt(with: chosen)
                case .alertSecondButtonReturn: self.changeEncryptionKeyHM(nil)
                case .alertThirdButtonReturn: self.decryptDocumentHM(nil)
                default: break
                }
            }
        }
    }

    /// 暗号化をやめて普通のテキストとして保存する
    @objc func decryptDocumentHM(_ sender: Any?) {
        guard let doc = hdoc, doc.isEncrypted, let window = window else { return }
        let alert = NSAlert()
        alert.messageText = L("暗号化を解除しますか？")
        alert.informativeText = L("だれでも読めるファイルに戻ります。")
        alert.addButton(withTitle: L("解除して保存"))
        alert.addButton(withTitle: L("やめる"))
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
private var aiWindowKey = 0
private var aiWindowCloseKey = 0
private var aiClientKey = 0
private var aiTabKey = 0
private var pendingSlideKey = 0
private var aiLastAnswerKey = 0

extension EditorWindowController {
    private var aiPanel: AIPanel {
        if let p = objc_getAssociatedObject(self, &aiPanelKey) as? AIPanel { return p }
        let p = AIPanel()
        p.onRun = { [weak self] instruction, kind, shown in self?.runAI(instruction, kind: kind, shown: shown) }
        p.onCancel = { [weak self] in self?.aiClient?.cancel() }
        p.onClose = { [weak self] in self?.showAIPanel(false) }
        p.onToggleDetach = { [weak self] in self?.toggleAIDetached() }
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

    /// 取り出した AI アシスタントのウインドウ (取り出していなければ nil)
    private var aiWindow: NSWindow? {
        get { objc_getAssociatedObject(self, &aiWindowKey) as? NSWindow }
        set { objc_setAssociatedObject(self, &aiWindowKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// 文書を閉じるとき: 取り出した AI のウインドウも閉じる
    func closeDetachedAIWindow() {
        guard let w = aiWindow else { return }
        if let o = objc_getAssociatedObject(self, &aiWindowCloseKey) { NotificationCenter.default.removeObserver(o) }
        objc_setAssociatedObject(self, &aiWindowCloseKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        aiWindow = nil
        w.orderOut(nil)
    }

    /// AI アシスタントの欄を、別のウインドウに取り出す / エディタの横に戻す
    func toggleAIDetached(animated: Bool = true) {
        defer { updateAITab() }
        let p = aiPanel
        if let w = aiWindow {
            // 戻す
            if let o = objc_getAssociatedObject(self, &aiWindowCloseKey) { NotificationCenter.default.removeObserver(o) }
            objc_setAssociatedObject(self, &aiWindowCloseKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            aiWindow = nil
            p.removeFromSuperview()
            w.orderOut(nil)
            p.setDetached(false)
            editorArea.addArrangedSubview(p)
            fitWindowForSidePanels()
            if animated {
                // 右はしから枠ごと滑らせて戻す
                p.isHidden = true
                editorArea.layoutSubtreeIfNeeded()
                window?.makeKeyAndOrderFront(nil)
                slideAIPanel(p, open: true)
            } else {
                p.isHidden = false
            }
            return
        }
        // 取り出す: いまの欄の位置あたりに、同じくらいの大きさのウインドウを出す
        let screenRect = p.window.flatMap { win in p.superview.map { win.convertToScreen($0.convert(p.frame, to: nil)) } }
        editorArea.removeArrangedSubview(p)
        p.removeFromSuperview()
        p.setDetached(true)
        let size = NSSize(width: max(320, screenRect?.width ?? 360), height: max(420, screenRect?.height ?? 560))
        let w = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        w.title = L("AI アシスタント") + " — " + (hdoc?.displayName ?? "")
        w.isFloatingPanel = true // エディタの上に浮かせる (書きながら使えるように)
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 280, height: 320)
        let host = NSView()
        w.contentView = host
        host.addSubview(p)
        NSLayoutConstraint.activate([
            p.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            p.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            p.topAnchor.constraint(equalTo: host.topAnchor),
            p.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        if !w.setFrameUsingName("SatoruAIWindow"), let r = screenRect {
            w.setFrameOrigin(NSPoint(x: r.minX + 20, y: r.minY + 20))
        }
        w.setFrameAutosaveName("SatoruAIWindow")
        aiWindow = w
        p.isHidden = false
        // 赤いボタンで閉じたら、閉じずにエディタの横 (元の場所) に戻す
        let o = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            guard let self = self, self.aiWindow != nil else { return }
            DispatchQueue.main.async { self.toggleAIDetached() }
        }
        objc_setAssociatedObject(self, &aiWindowCloseKey, o, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        w.makeKeyAndOrderFront(nil)
    }

    /// 原稿用紙 (作文) のときは、AI の欄の定型の依頼を作文向けにする
    func syncAIEssayMode() {
        guard let p = objc_getAssociatedObject(self, &aiPanelKey) as? AIPanel else { return }
        p.essayMode = paperMode == .genko
    }

    private func showAIPanel(_ show: Bool) {
        defer { updateAITab() }
        let p = aiPanel
        p.essayMode = paperMode == .genko
        if let w = aiWindow {
            // 取り出しているとき: そのウインドウを出す / しまう
            if show {
                p.isHidden = false
                w.makeKeyAndOrderFront(nil)
                p.refreshProvider()
                p.setReady(AISettings.isReady)
                p.refreshApplyMode()
            } else {
                toggleAIDetached(animated: false) // しまうときは、エディタの横に戻してから隠す
                p.isHidden = true
                window?.makeFirstResponder(textView.focusTarget)
            }
            return
        }
        if show {
            if p.superview == nil { editorArea.addArrangedSubview(p) }
            let wasHidden = p.isHidden || p.window == nil
            // 欄のぶんウインドウを広げる (広げる幅は、欄を出した状態で測る)
            p.isHidden = false
            fitWindowForSidePanels()
            if wasHidden { p.isHidden = true; editorArea.layoutSubtreeIfNeeded() }
            p.refreshProvider()
            p.setReady(AISettings.isReady)
            p.refreshApplyMode()
            if wasHidden { slideAIPanel(p, open: true) } else { p.isHidden = false }
        } else {
            window?.makeFirstResponder(textView.focusTarget)
            slideAIPanel(p, open: false)
        }
    }

    /// AI の欄を、右からすっと出し入れする (サイドメニューのように)
    private func slideAIPanel(_ p: NSView, open: Bool) {
        slideSide([p], open: open, fromLeft: false) { [weak self] in self?.updateAITab() }
    }

    /// 横の欄を、はしから枠ごとすっと出し入れする (引き出しのように)。
    /// 動くあいだだけ、欄を「だんだん広がる入れ物」に入れる。欄の中身は最後の幅のままなので、中の入力欄などは飛んでこない。
    /// 本文の幅も、いっしょにだんだん変わる。「視差効果を減らす」のときや、ウインドウがまだ出ていないときは、すぐ切り替える
    private func slideSide(_ views: [NSView], open: Bool, fromLeft: Bool, done: (() -> Void)? = nil) {
        finishSlide()   // 前の動きが残っていれば、すぐ終わらせる
        let moving = views.filter { $0.isHidden == open || $0.superview == nil }
        guard !moving.isEmpty, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false, window?.isVisible == true,
              let index = editorArea.arrangedSubviews.firstIndex(where: { moving.contains($0) }) else {
            views.forEach { $0.isHidden = !open }
            done?()
            return
        }
        // 出したときの幅を測る
        moving.forEach { $0.isHidden = false }
        editorArea.layoutSubtreeIfNeeded()
        let widths = moving.map { max($0.frame.width, $0.fittingSize.width) }
        let total = widths.reduce(0, +)
        // 入れ物に入れ替える
        let slot = NSView()
        slot.wantsLayer = true
        slot.layer?.masksToBounds = true
        slot.translatesAutoresizingMaskIntoConstraints = false
        for v in moving {
            editorArea.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        editorArea.insertArrangedSubview(slot, at: index)
        var cs: [NSLayoutConstraint] = []
        var prev: NSView? = nil
        for (v, w) in zip(moving, widths) {
            slot.addSubview(v)
            cs += [v.topAnchor.constraint(equalTo: slot.topAnchor), v.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
                   v.widthAnchor.constraint(equalToConstant: w)]
            if let p = prev { cs.append(v.leadingAnchor.constraint(equalTo: p.trailingAnchor)) }
            prev = v
        }
        // 左の欄は右はしを、右の欄は左はしを入れ物にくっつける (はしの外から出てくるように見える)
        if fromLeft { cs.append(moving.last!.trailingAnchor.constraint(equalTo: slot.trailingAnchor)) }
        else { cs.append(moving.first!.leadingAnchor.constraint(equalTo: slot.leadingAnchor)) }
        let wc = slot.widthAnchor.constraint(equalToConstant: open ? 0 : total)
        cs.append(wc)
        NSLayoutConstraint.activate(cs)
        editorArea.layoutSubtreeIfNeeded()
        let restore: () -> Void = { [weak self] in
            guard let self = self else { return }
            NSLayoutConstraint.deactivate(cs)
            let at = self.editorArea.arrangedSubviews.firstIndex(of: slot) ?? index
            self.editorArea.removeArrangedSubview(slot)
            slot.removeFromSuperview()
            for (k, v) in moving.enumerated() {
                v.removeFromSuperview()
                v.isHidden = !open
                self.editorArea.insertArrangedSubview(v, at: min(at + k, self.editorArea.arrangedSubviews.count))
            }
            self.editorArea.layoutSubtreeIfNeeded()
            done?()
        }
        pendingSlide = restore
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = open ? 0.26 : 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: open ? .easeOut : .easeIn)
            ctx.allowsImplicitAnimation = true
            wc.animator().constant = open ? total : 0
            editorArea.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            guard let self = self, self.pendingSlide != nil else { return }
            self.finishSlide()
        })
    }

    private func finishSlide() {
        guard let f = pendingSlide else { return }
        pendingSlide = nil
        f()
    }
    private var pendingSlide: (() -> Void)? {
        get { objc_getAssociatedObject(self, &pendingSlideKey) as? () -> Void }
        set { objc_setAssociatedObject(self, &pendingSlideKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// 使えない状態なら説明して設定へ案内する
    private func ensureAIReady() -> Bool {
        guard let window = window else { return false }
        if !AISettings.isEnabled {
            let alert = NSAlert()
            alert.messageText = L("AI アシスタントはオフになっています")
            alert.informativeText = L("「追加機能 > AI アシスタント」でオンにしてください。")
            alert.addButton(withTitle: L("設定を開く"))
            alert.addButton(withTitle: L("あとで"))
            alert.beginSheetModal(for: window) { r in
                if r == .alertFirstButtonReturn { SettingsWindowController.shared.show(.ai) }
            }
            return false
        }
        return true
    }

    /// AI アシストの欄を閉じているあいだ、画面の右の端に出す小さなつまみ (押すと開く)
    private var aiTab: NSButton {
        if let b = objc_getAssociatedObject(self, &aiTabKey) as? NSButton { return b }
        // 目立ちすぎないよう: 文字なしの小さなアイコンだけ、うすい灰色の地に
        let img = NSImage(systemSymbolName: "sparkles", accessibilityDescription: L("AI アシスト"))?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) ?? NSImage()
        // タブの右 8pt は画面の外なので、アイコンはそのぶん左に寄せる (見えているところの真ん中に)
        let padded = NSImage(size: NSSize(width: img.size.width + 8, height: img.size.height), flipped: false) { r in
            img.draw(in: NSRect(x: 0, y: 0, width: img.size.width, height: img.size.height))
            return true
        }
        padded.isTemplate = true
        let b = AITabButton(image: padded, target: self, action: #selector(openAIFromTab(_:)))
        b.isBordered = false
        b.contentTintColor = .systemPurple   // AI らしく、ほんのり紫に
        b.toolTip = L("AI アシストを開く")
        b.wantsLayer = true
        b.applyColors()   // 地は上のバーや下の状態表示と同じ色 (透けない)
        b.layer?.cornerRadius = 7
        b.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]   // 左の角だけ丸く (右の端にくっつける)
        b.translatesAutoresizingMaskIntoConstraints = false
        objc_setAssociatedObject(self, &aiTabKey, b, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return b
    }

    /// つまみを出すか決める: AI アシストを使っていて、欄を閉じていて、取り出してもいないとき
    func updateAITab() {
        let show = EditorExtension.ai.isOn && !aiPanelVisible && aiWindow == nil
        let b = aiTab
        if show && b.superview == nil, let host = editorArea.superview {
            host.addSubview(b, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                // 右の角は画面の外に出して、右はしにくっついて見えるように
                b.trailingAnchor.constraint(equalTo: editorArea.trailingAnchor, constant: 8),
                b.centerYAnchor.constraint(equalTo: editorArea.centerYAnchor, constant: -40),
                b.widthAnchor.constraint(equalToConstant: 28),
                b.heightAnchor.constraint(equalToConstant: 36),
            ])
        }
        b.isHidden = !show
    }

    @objc private func openAIFromTab(_ sender: Any?) {
        guard ensureAIReady() else { return }
        showAIPanel(true)
    }

    /// AI アシスタントを切ったら欄を閉じて問い合わせも止める
    func aiTurnedOff() {
        aiClient?.cancel()
        if aiPanelVisible { showAIPanel(false) }
    }

    /// AI アシスタントをオンにした直後に、横の AI 欄を出す
    /// 動作確認用: AI の欄の入力欄に文字を入れる
    func fillAIInputForTest(_ text: String) { aiPanel.fillInputForTest(text) }

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
        let a = actions[sender.tag]
        runAI(a.instruction, kind: a.apply, shown: a.title)
    }

    /// AI を使える状態か (ステータスバーの表示用)
    var aiIsReady: Bool { AISettings.isReady }

    /// 1 回の依頼。答えを待つあいだに選択が変わっても、もとの場所を書き換えられるように、頼んだときの対象を覚えておく
    final class AIJob {
        var from: Int
        var to: Int
        var original: String
        let kind: AIPanel.ApplyKind
        init(from: Int, to: Int, original: String, kind: AIPanel.ApplyKind) {
            self.from = from
            self.to = to
            self.original = original
            self.kind = kind
        }
    }

    /// 動作確認用: 最後に足した答えの吹き出し
    var lastAIAnswerForTesting: AIAnswerView? { objc_getAssociatedObject(self, &aiLastAnswerKey) as? AIAnswerView }
    var aiPanelForTesting: AIPanel { aiPanel }

    func runAI(_ instruction: String, kind: AIPanel.ApplyKind, shown: String) {
        guard let window = window, let doc = hdoc else { return }
        let panel = aiPanel
        guard !panel.running else { return }
        // 設定と接続の確認が済むまでは送らない
        guard AISettings.isReady else {
            panel.setReady(false)
            let alert = NSAlert()
            alert.messageText = L("AI がまだ設定されていません")
            alert.informativeText = L("API キーとモデルを入れて「接続テスト」に成功すると使えます。")
            alert.addButton(withTitle: L("設定を開く"))
            alert.addButton(withTitle: L("あとで"))
            alert.beginSheetModal(for: window) { r in
                if r == .alertFirstButtonReturn { SettingsWindowController.shared.show(.ai) }
            }
            return
        }
        if doc.isEncrypted {
            let alert = NSAlert()
            alert.messageText = L("暗号化した文書は AI に送りません")
            alert.informativeText = L("流出防止のためです。")
            alert.beginSheetModal(for: window)
            return
        }
        aiClient?.cancel()
        // 対象: 選んでいる範囲。何も選んでいなければ文書全体
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        let selected = sel.length > 0 && NSMaxRange(sel) <= ns.length
        let target = selected ? ns.substring(with: sel) : ns as String
        let limit = 200_000
        if (target as NSString).length > limit {
            let alert = NSAlert()
            alert.messageText = L("文章が長すぎます")
            alert.informativeText = L("{0} 文字まで。範囲を選んで分けて送ってください。", limit)
            alert.beginSheetModal(for: window)
            return
        }
        let job = AIJob(from: selected ? sel.location : 0, to: selected ? NSMaxRange(sel) : ns.length, original: target, kind: kind)
        var system = L("あなたはテキストエディタ「さとるエディタ」に組み込まれた文章作成アシスタントです。依頼された結果だけを出力し、前置きや締めの言葉は書かないでください。元の文章がマークダウンを使っていない限り、マークダウンの装飾は使わないでください。")
        // 原稿用紙 (作文) を開いているときは、作文の書き方の決まりを守ってもらう
        if paperMode == .genko {
            system += L("\n\nいま書いているのは、原稿用紙 (縦書き 400 字詰め) の作文です。作文の形と、原稿用紙の書き方の決まりを守ってください。\n作文の形: 1 行目に題名、2 行目に名前、3 行目は空けて、4 行目から本文。題名・名前の行には空白を入れない (題名を 3 マス下げる・名前を下に寄せるのは、アプリが自動で行う)。文書全体を書き直すときは、この形のまま出力する。\n本文の決まり: 段落の初めは全角スペース 1 つで 1 字下げる。会話は「」で囲み、行を改める (会話の行は字下げしない)。数字は漢数字で書く。英字・記号・半角の文字はできるだけ使わない (使うときは全角)。句読点やかっこも 1 字として数える。文体 (です・ます / だ・である) はもとの作文にそろえる。マークダウンや箇条書きは使わない。")
        }
        // 自分で書いた頼みごとは、置き換えに使えるよう「直した全文」を返してもらう (一部だけ返されると、置き換えで残りが消えるため)
        let fullText = kind == .ask && !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L("\n\n(文章を変える依頼なら、入れる内容には、変えていない部分も含めて対象の文章を省略せずに全部入れてください。)")
            : ""
        // 答えを「ユーザーへのひとこと」と「文章に入れる中身」に分けてもらう (中身は <result> で囲む)
        let format: String
        switch kind {
        case .replace, .insert:
            format = L("\n\n出力の形: はじめにユーザーへのひとこと (1〜2 文。何をしたか) を書き、そのあと文章に入れる内容だけを <result> と </result> で囲んで出力してください。")
        case .ask:
            format = L("\n\n出力の形: はじめにユーザーへのひとこと (1〜2 文) を書いてください。文章やコードを書く・直す・足す・消すなど、エディタの中身を変える依頼なら、そのあとエディタに入れる内容だけを <result> と </result> で囲んで出力してください (コードも ``` ではなく <result> で囲む)。エディタの中身を変えない質問への答えのときだけ、<result> を使わないでください。")
        case .none:
            format = ""
        }
        let prompt = target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? instruction + format
            : instruction + fullText + format + L("\n\n対象の文章:\n<<<\n") + target + "\n>>>"
        let name = doc.fileURL?.lastPathComponent ?? doc.displayName ?? L("文書")
        let note = selected ? L("対象: 選んでいる {0} 文字", Genko.characterCount(target)) : L("対象: 文書全体")
        let answer = panel.addExchange(request: shown, note: L("{0} ・ {1}", name, note))
        objc_setAssociatedObject(self, &aiLastAnswerKey, answer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        answer.onApply = { [weak self, weak answer] replace in self?.applyAI(job, replace: replace, answer: answer) }
        answer.onReflect = { [weak self, weak answer] in self?.reflectAI(answer) }
        panel.refreshProvider()
        panel.setRunning(true)
        let client = AIClient()
        aiClient = client
        client.send(system: system, prompt: prompt, onDelta: { [weak answer] t in answer?.append(t) }) { [weak self, weak panel, weak answer] err in
            let cancelled = err == nil && client.wasCancelled
            // 今回使った量と料金の目安
            var usage = ""
            let u = client.usage
            if u.inputTokens > 0 || u.outputTokens > 0 {
                let cost = AIPricing.cost(u, provider: client.provider, model: client.model)
                usage = L("入力 {0} / 出力 {1} トークン", u.inputTokens, u.outputTokens) + (u.estimated ? " " + L("(見積もり)") : "") + L(" ・ ") + AIPricing.format(cost)
            }
            answer?.finish(error: err?.localizedDescription, cancelled: cancelled, usage: usage)
            if self?.aiClient === client { self?.aiClient = nil }
            panel?.setRunning(false)
            if err == nil, !cancelled, let answer = answer, !answer.text.isEmpty { self?.aiFinished(job, answer: answer) }
            panel?.scrollDown()
        }
    }

    /// 答えが出そろったあと: 設定に応じて、自動で書き換えるか、確かめるか、何もしないか
    private func aiFinished(_ job: AIJob, answer: AIAnswerView) {
        let mode = AISettings.applyMode
        // 自分で書いた頼みごと (.ask) も、書き換える設定なら対象を置き換える。要約・説明 (.none) は読むだけ
        guard mode != "never", job.kind == .replace || job.kind == .insert || job.kind == .ask else { return }
        // 自分で書いた頼みごとで、入れる中身がない (質問への答え) ときは書き換えない
        if job.kind == .ask && !answer.hasContent { return }
        let replace = job.kind != .insert
        if mode == "auto" {
            applyAI(job, replace: replace, answer: answer)
        } else {
            answer.showConfirm(replace: replace) { [weak self, weak answer] in self?.applyAI(job, replace: replace, answer: answer) }
        }
    }

    /// 答えを文章に入れる。replace = 頼んだときの対象 (選んでいた範囲、なければ文書全体) を置き換える。そうでなければ対象のあとに足す。
    /// どちらも ⌘Z で戻せる
    func applyAI(_ job: AIJob, replace: Bool, answer: AIAnswerView?) {
        guard let answer = answer, !answer.applyText.isEmpty, AISettings.applyMode != "never" else { return }
        answer.hideConfirm()
        let tv = primary.textView
        let now = tv.string
        // 待っているあいだに文章が変わっていたら、もとの文章を探し直す
        guard let range = AIApply.locate(in: now, from: job.from, to: job.to, original: job.original) else {
            let alert = NSAlert()
            alert.messageText = L("書き換えられませんでした")
            alert.informativeText = L("頼んだあとに文章が変わったので、置き換える場所が分からなくなりました。「コピー」して貼り付けてください。")
            if let w = window { alert.beginSheetModal(for: w) } else { alert.runModal() }
            return
        }
        // 入れるのは中身だけ (ユーザーへのひとことは入れない)
        let text = TextCodec.normalizeLineEndings(answer.applyText)
        let length = (text as NSString).length
        if replace {
            guard tv.replace(range, with: text, select: NSRange(location: range.location, length: length)) else { NSSound.beep(); return }
            typeIn(NSRange(location: range.location, length: length))
            // もう一度押しても、いま入れた答えを対象にする
            job.from = range.location
            job.to = range.location + length
            job.original = text
            remoteStatusChanged("✓ " + L("置き換えました (⌘Z で戻せます)"))
        } else {
            let piece = AIApply.insertion(after: NSMaxRange(range), in: now, text: text)
            let at = NSRange(location: NSMaxRange(range), length: 0)
            guard tv.replace(at, with: piece, select: NSRange(location: at.location, length: (piece as NSString).length)) else { NSSound.beep(); return }
            typeIn(NSRange(location: at.location, length: (piece as NSString).length))
            remoteStatusChanged("✓ " + L("足しました (⌘Z で戻せます)"))
        }
        guessLanguageIfUnnamed()
        window?.makeFirstResponder(tv.focusTarget)
    }
}

// MARK: - AI の答えを本文に反映する

extension EditorWindowController {
    /// 「⋮ > 反映」: 本文をまるごと答えの中身に置き換える (⌘Z 1 回で戻せる)
    func reflectAI(_ answer: AIAnswerView?) {
        guard let answer = answer, !answer.applyText.isEmpty else { return }
        answer.hideConfirm()
        let tv = primary.textView
        let text = TextCodec.normalizeLineEndings(answer.applyText)
        let all = NSRange(location: 0, length: (tv.string as NSString).length)
        let length = (text as NSString).length
        guard tv.replace(all, with: text, select: NSRange(location: 0, length: length)) else { NSSound.beep(); return }
        typeIn(NSRange(location: 0, length: length))
        remoteStatusChanged("✓ " + L("本文を答えに置き換えました (⌘Z で戻せます)"))
        window?.makeFirstResponder(tv.focusTarget)
    }
}

// MARK: - AI の答えを打っているように見せる

/// 1 字ずつ見せている途中の状態
private final class TypeInState {
    var timer: Timer?
    var finish: () -> Void = {}
}
private var typeInKey = 0

extension EditorWindowController {
    /// range (いま入れた AI の答え) を、キーボードで打っているように少しずつ見せる。
    /// 文字そのものは最初に全部入れてあるので、⌘Z 1 回で戻せ、保存・共同編集にもすぐ全部が入る。終わったら range を選んだ状態にする
    func typeIn(_ range: NSRange) {
        stopTypeIn()
        let tv = primary.textView
        let ns = tv.string as NSString
        guard range.length > 0, NSMaxRange(range) <= ns.length else { return }
        let state = TypeInState()
        objc_setAssociatedObject(self, &typeInKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let expectedLength = ns.length
        // 長い答えでも 1 秒たらずで終わるように、1 回に出す字数を決める (短いときも 1 回に 2 字以上)
        let step = max(2, Int((Double(range.length) / 40).rounded(.up)))
        var shown = 0
        let setHidden: (NSRange?) -> Void = { [weak self] h in
            self?.panes.forEach { $0.textView.revealHidden = h; $0.genkoView?.revealHidden = h }
        }
        state.finish = { [weak self, weak state] in
            state?.timer?.invalidate()
            state?.timer = nil
            setHidden(nil)
            guard let self = self else { return }
            objc_setAssociatedObject(self, &typeInKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            if (tv.string as NSString).length == expectedLength {
                tv.setSelectedRange(range)
                tv.scrollRangeToVisible(range)
            }
        }
        setHidden(range)
        tv.setSelectedRange(NSRange(location: range.location, length: 0))
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self, weak state] _ in
            guard let self = self, let state = state else { return }
            let now = tv.string as NSString
            // 途中で文章が書き換わったら (入力・共同編集の相手など)、すぐ全部見せて終える
            guard now.length == expectedLength else { state.finish(); return }
            shown = min(range.length, shown + step)
            // 絵文字などの 2 つで 1 字のものを途中で切らない
            if shown < range.length {
                let r = now.rangeOfComposedCharacterSequence(at: range.location + shown)
                shown = NSMaxRange(r) - range.location
            }
            if shown >= range.length { state.finish(); return }
            let caret = NSRange(location: range.location + shown, length: 0)
            setHidden(NSRange(location: caret.location, length: range.length - shown))
            tv.setSelectedRange(caret)
            tv.scrollRangeToVisible(caret)
        }
        state.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 見せている途中なら、残りを全部見せて終える
    func stopTypeIn() {
        (objc_getAssociatedObject(self, &typeInKey) as? TypeInState)?.finish()
    }
}

// MARK: - 用紙モード (原稿用紙・A4)

private var genkoWorkKey = 0
private var a4ResizeKey = 0

extension EditorWindowController {
    var paperMode: EditorTextView.PaperMode { primary.textView.paperMode }

    /// フッターに出す用紙の名前
    static func paperModeName(_ m: EditorTextView.PaperMode, horizontal: Bool = false) -> String {
        switch m {
        case .normal: return L("標準エディタ")
        case .genko: return horizontal ? L("原稿用紙 (横書き)") : L("原稿用紙 (縦書き)")
        case .a4: return L("A4用紙")
        }
    }

    /// 作文アシストのオン・オフ
    @objc func toggleGenkoAssistHM(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
    }

    /// 開いたファイルに表示が書いてあれば (拡張属性)、その表示で開く (作文の縦・横、A4)
    func applyFileMode() {
        guard EditorExtension.paper.isOn else { return }   // 用紙切替を切っているときは、いつも標準エディタ
        guard let u = hdoc?.fileURL, let m = TextLibrary.mode(for: u.standardizedFileURL.resolvingSymlinksInPath().path) else {
            // 入れ替えたファイルに表示が書いていなければ、標準エディタに戻す
            if hdoc?.switchingFile == true, paperMode != .normal { applyPaperMode(.normal) }
            return
        }
        switch m {
        case "genko", "genkoH":
            // このタブだけ向きを変える (ほかのタブはそのまま)
            setGenkoHorizontal(m == "genkoH", remember: false)
            if paperMode != .genko { applyPaperMode(.genko) }
        case "a4":
            if paperMode != .a4 { applyPaperMode(.a4) }
        default:
            break
        }
    }

    /// テキスト一覧に、この文書の表示 (作文か) を覚えさせる
    func rememberPaperModeForLibrary(_ mode: EditorTextView.PaperMode) {
        let m: String? = mode == .genko ? (horizontalGenko ? "genkoH" : "genko") : mode == .a4 ? "a4" : nil
        TextLibrary.setMode(m, for: hdoc?.fileURL)
    }

    /// 横書きの原稿用紙か
    var horizontalGenko: Bool { primary.textView.genkoHorizontal }

    /// このタブの原稿用紙の向きを変える。remember = 新しいタブの向きとしても覚える (自分で選んだとき)
    func setGenkoHorizontal(_ h: Bool, remember: Bool) {
        if remember { UserDefaults.standard.set(h, forKey: "genkoHorizontal") }
        guard horizontalGenko != h else { return }
        panes.forEach { $0.textView.genkoHorizontal = h }
        if paperMode == .genko {
            rememberPaperModeForLibrary(.genko)
            refreshPaper()
        }
        updateStatus()
    }

    /// メニュー「用紙」: tag 0 = 通常、1 = 原稿用紙 (縦書き)、2 = A4、3 = 原稿用紙 (横書き)
    static let horizontalGenkoTag = 3

    @objc func setPaperModeHM(_ sender: NSMenuItem) {
        if sender.tag == Self.horizontalGenkoTag || sender.tag == EditorTextView.PaperMode.genko.rawValue {
            let horizontal = sender.tag == Self.horizontalGenkoTag
            // 縦 ⇔ 横 の切り替えは、このタブだけ
            setGenkoHorizontal(horizontal, remember: true)
            if paperMode == .genko { return }
            applyPaperMode(.genko)
            return
        }
        guard let m = EditorTextView.PaperMode(rawValue: sender.tag) else { return }
        applyPaperMode(m)
    }

    /// 縦書き ⇔ 横書きの原稿用紙が切り替わったとき (ほかのウインドウも含めて)
    @objc func genkoOrientationChanged(_ note: Notification) {
        guard paperMode == .genko else { return }
        rememberPaperModeForLibrary(.genko)
        refreshPaper()
        updateStatus()
    }

    /// ツールバーのボタン: 通常 → 原稿用紙 → A4 → 通常
    @objc func cyclePaperModeHM(_ sender: Any?) {
        // 設定で選んだ候補だけを、順に回る
        let list = PaperCandidates.enabled
        let i = list.firstIndex(of: currentPaperID).map { ($0 + 1) % list.count } ?? 0
        applyPaperID(list[i])
    }

    func applyPaperMode(_ mode: EditorTextView.PaperMode) {
        defer {
            updateStatus() // フッターの「標準 / 原稿用紙 / A4」を合わせる
            syncAIEssayMode()
        }
        let old = paperMode
        panes.forEach { $0.textView.paperMode = mode }
        // 最後に使った表示を覚えておく (次に起動したとき「前回と同じ」で使う)
        UserDefaults.standard.set(mode == .genko ? "genko" : mode == .a4 ? "a4" : "normal", forKey: "lastPaperMode")
        rememberPaperModeForLibrary(mode)
        if mode == .normal {
            guard old != .normal else { return }
            for pane in panes {
                showTextView(in: pane)
                pane.textView.minSize = .zero
                pane.textView.textContainer?.lineFragmentPadding = 5
                pane.textView.textContainerInset = NSSize(width: 4, height: 6)
                (pane.textView.textContainer as? PagedTextContainer)?.pageStride = 0
                pane.textView.layoutManager?.usesFontLeading = true
            }
            highlighter.linksEnabled = true
            // 用紙モードで外した行番号・桁ルーラーを付け直す
            for pane in panes {
                pane.scrollView.verticalRulerView = pane.ruler
                pane.scrollView.horizontalRulerView = pane.columnRuler
                pane.ruler.orientation = .verticalRuler
                pane.columnRuler.orientation = .horizontalRuler
                pane.ruler.textChanged()
            }
            themeDidChangePublic()
            applyViewSettingsPublic()
            // 用紙モードで決めた大きさの制限を外す
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
        // あとから分割した面にも同じ用紙モードを伝える
        for pane in panes where pane.textView.paperMode != mode { pane.textView.paperMode = mode }
        for pane in panes { pane.textView.genkoHorizontal = horizontalGenko }
        if mode == .genko {
            refreshGenko()
            return
        }
        guard let storage = primary.textView.textStorage else { return }
        let ink = NSColor(white: 0.1, alpha: 1)
        let font: NSFont
        let style = NSMutableParagraphStyle()
        switch mode {
        case .genko:
            return
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
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .paragraphStyle: style]
        if storage.length > 0 {
            // 手で決めた段落の寄せ (A4) は残す
            var manual: [(NSRange, Any)] = []
            storage.enumerateAttribute(.paperAlign, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
                if let v = v { manual.append((r, v)) }
            }
            storage.beginEditing()
            storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
            var edits: [NSRange] = [], added: [NSRange] = []
            storage.enumerateAttribute(.editedLine, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
                if v != nil { edits.append(r) }
            }
            storage.enumerateAttribute(.addedText, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
                if v != nil { added.append(r) }
            }
            for (r, v) in manual { storage.addAttribute(.paperAlign, value: v, range: r) }
            for r in edits { storage.addAttribute(.editedLine, value: true, range: r) }
            for r in added { storage.addAttribute(.addedText, value: true, range: r) }
            storage.endEditing()
        }
        highlighter.linksEnabled = false
        highlighter.setProfile(nil) // 用紙モードでは色分けしない
        for pane in panes {
            showTextView(in: pane)
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
                break
            case .a4:
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
        if mode == .a4 {
            restorePaperAlignmentsIfNeeded()
            a4Format()
            panes.forEach { fitA4Pages($0) }
        }
    }

    /// 原稿用紙: 文字の面 (EditorTextView) を画面から外し、マス目の面 (GenkoView) を代わりに出す。
    /// 文章と選択は EditorTextView が持ち続けるので、保存・検索・共同編集などはそのまま動く
    private func refreshGenko() {
        highlighter.linksEnabled = false
        highlighter.setProfile(nil) // 用紙モードでは色分けしない
        for pane in panes {
            let tv = pane.textView
            let g = pane.genkoView ?? GenkoView(textView: tv)
            pane.genkoView = g
            tv.genkoProxy = g
            g.onBecomeFirstResponder = tv.onBecomeFirstResponder
            (tv.textContainer as? PagedTextContainer)?.pageStride = 0
            pane.scrollView.rulersVisible = false
            pane.scrollView.scrollerKnobStyle = .dark
            pane.scrollView.hasHorizontalScroller = true
            pane.scrollView.hasVerticalScroller = true
            pane.scrollView.backgroundColor = GenkoView.deskColor
            // 文字の面が残した「横書きの I」を、縦書き用に替える (外へ出て戻ったときも縦のままに)
            pane.scrollView.documentCursor = g.horizontal ? .iBeam : .iBeamCursorForVerticalLayout
            if pane.scrollView.documentView !== g {
                let focused = window?.firstResponder === tv
                pane.scrollView.documentView = g
                if focused { window?.makeFirstResponder(g) }
            }
            g.settingsChanged()
        }
    }

    /// 原稿用紙をやめるとき: 文字の面を画面に戻す
    private func showTextView(in pane: EditorPane) {
        guard let g = pane.genkoView, pane.scrollView.documentView === g else { return }
        let focused = window?.firstResponder === g
        pane.textView.genkoProxy = nil
        pane.scrollView.documentCursor = .iBeam
        pane.scrollView.documentView = pane.textView
        if focused { window?.makeFirstResponder(pane.textView) }
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
        window?.makeFirstResponder(textView.focusTarget)
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

    /// 入力のたびに A4 の書式を直す (少しまとめて)。原稿用紙はマス目の面が自分で並べ直す
    func scheduleGenkoAdjust() {
        guard paperMode == .a4 else { return }
        genkoWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.paperMode == .a4 else { return }
            self.a4Format()
            self.panes.forEach { self.fitA4Pages($0) }
            self.updateStatus()
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

    private func observeClipResize(_ pane: EditorPane) {
        let clip = pane.scrollView.contentView
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: clip)
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipResized(_:)),
                                               name: NSView.frameDidChangeNotification, object: clip)
    }

    @objc private func clipResized(_ note: Notification) {
        // A4: ウインドウの大きさに合わせて用紙の倍率を決め直す (サイズ変更が止まってから)
        if paperMode == .a4 {
            a4ResizeWork?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.refreshPaper() }
            a4ResizeWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
        }
    }

    /// 状態表示用: A4 なら何ページか
    var paperStatus: String? {
        let tv = primary.textView
        // 原稿用紙の字数・枚数は、右側の項目に出す
        guard tv.paperMode == .a4 else { return nil }
        return L("A4 {0} ページ", tv.a4PageCount)
    }
}

// MARK: - PDF

extension EditorWindowController {
    /// いまの見た目のまま PDF にする (原稿用紙はマス目つき縦書き、それ以外は A4)
    func writePaperPDF(to url: URL) throws {
        if paperMode == .genko {
            // ふりがなは、画面の取り直しを待たずにここで付け直す (書いた直後でも抜けないように)
            let text = primary.textView.string
            try GenkoPDF.write(text: text, autoFormat: primary.textView.genkoAutoFormat,
                               ruby: UserDefaults.standard.bool(forKey: "genkoFurigana") ? Furigana.ruby(for: text) : [],
                               horizontal: horizontalGenko, to: url)
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
            remoteStatusChanged(L("📄 PDF も保存: {0}", pdf.lastPathComponent))
        } catch {
            presentError(error)
        }
    }

    @objc func exportWordHM(_ sender: Any?) {
        guard let doc = hdoc else { return }
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["docx"]
        let name = doc.fileURL?.lastPathComponent ?? doc.displayName ?? L("文書")
        panel.nameFieldStringValue = (name as NSString).deletingPathExtension + ".docx"
        panel.message = paperMode == .genko ? L("Word では横書きになります (文章と段落はそのまま)") : L("Word (.docx) にします")
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

    /// 印刷: 「PDF として書き出す」と同じ見た目 (原稿用紙ならマス目つき、ふつうは A4・40 字 × 36 行) を一度 PDF にして印刷する
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
                throw NSError(domain: "Satoru", code: 36, userInfo: [NSLocalizedDescriptionKey: L("印刷の準備ができませんでした")])
            }
            // 原稿用紙は、紙を横向きにして 1 枚 (400 字) を紙いっぱいに真ん中へ刷る
            let genko = paperMode == .genko
            if genko {
                info.orientation = .landscape
                info.isHorizontallyCentered = true
                info.isVerticallyCentered = true
            }
            guard let op = pdf.printOperation(for: info, scalingMode: genko ? .pageScaleToFit : .pageScaleDownToFit,
                                              autoRotate: !genko) else {
                throw NSError(domain: "Satoru", code: 36, userInfo: [NSLocalizedDescriptionKey: L("印刷の準備ができませんでした")])
            }
            op.jobTitle = hdoc?.displayName ?? L("文書")
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
            let name = doc.fileURL?.lastPathComponent ?? doc.displayName ?? L("作文")
            panel.nameFieldStringValue = (name as NSString).deletingPathExtension + ".pdf"
            panel.message = L("原稿用紙のまま (マス目つき・縦書き、1 枚 400 字を A4 横 1 ページに) PDF にします")
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
                         suggestedName: doc.fileURL?.lastPathComponent ?? doc.displayName ?? L("文書"), from: window)
    }
}

extension Notification.Name {
    /// 原稿用紙の縦書き ⇔ 横書きが切り替わった
    static let genkoOrientationDidChange = Notification.Name("satoru.genkoOrientationDidChange")
}


/// 画面の右はしの AI タブ: 地は上のバー・下の状態表示と同じ色で塗る (ほんの少しだけ透ける)。明るい・暗いの切り替えにも合わせる
final class AITabButton: NSButton {
    func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor   // ほんの少しだけ透かす
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
        layer?.borderWidth = 1
        layer?.cornerRadius = 7
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]   // 左の角だけ丸く (右の端にくっつける)
    }
    override func layout() {
        super.layout()
        applyColors()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    // 上に乗ったら指のカーソルに (下の本文の I の形のカーソルに負けないよう、出入りでも切り替える)
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
}


/// テキストの一覧とフォルダの欄の間のバー: 細い帯に、上の線
final class LibraryDividerBar: NSView {
    override var isFlipped: Bool { true }
    /// つかんで上下に動かす (dy: 下へ動かした量) / ダブルクリック
    var onDragBegan: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onDoubleClick: (() -> Void)?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(); return }
        let y0 = event.locationInWindow.y
        onDragBegan?()
        while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseUp { break }
            onDrag?(y0 - e.locationInWindow.y)
        }
    }
    /// 選んでいるフォルダの名前 (下のテキストがどのフォルダのものかわかるように)
    private let label = NSTextField(labelWithString: "")
    private lazy var height = heightAnchor.constraint(equalToConstant: 20)

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            height,
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: TextLibrary.selectionDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: TextLibrary.didChange, object: nil)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func refresh() {
        let key = TextLibrary.selectedGroup
        var symbol = "folder", text: String
        parentName = ""
        if key == "all" { symbol = "tray.full"; text = L("すべて") }
        else if key == "root" { text = TextLibrary.rootName }
        else if key == "other" { text = L("ほかの場所") }
        else if key == "shared" { text = L("公開共有中") }
        else if key.hasPrefix("sub:") {
            let rel = String(key.dropFirst(4))
            symbol = TextLibrary.folderIcon(rel).symbol
            // 深いときは、ひとつ上の親と自分の名前だけ (長くなって崩れないように)
            let parts = rel.split(separator: "/").map(String.init)
            text = parts.last ?? rel
            if parts.count > 1 { parentName = parts[parts.count - 2] }
        } else if key.hasPrefix("ext:") { text = (String(key.dropFirst(4)) as NSString).lastPathComponent }
        else if let keys = TextLibrary.multiKeys(key) { symbol = "folder.fill"; text = L("{0} 個のフォルダ", keys.count) }
        else { text = "" }
        iconSymbol = symbol
        currentName = text
        label.toolTip = L("下のテキストは「{0}」の中のものです", parentName.isEmpty ? text : parentName + " › " + text)
        fit()
    }

    private var iconSymbol = "folder", currentName = "", parentName = ""
    private var lastWidth: CGFloat = -1

    /// 「親 › 自分」の文字。入りきらないときは親を「..」で縮め、自分の名前を残す
    private func make(_ parent: String?) -> NSAttributedString {
        let t = NSMutableAttributedString()
        if let img = NSImage(systemSymbolName: iconSymbol, accessibilityDescription: nil) {
            let a = NSTextAttachment()
            a.image = img.withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
            t.append(NSAttributedString(attachment: a))
            t.append(NSAttributedString(string: " "))
        }
        if let p = parent { t.append(NSAttributedString(string: p + " › ")) }
        t.append(NSAttributedString(string: currentName))
        let tail = NSMutableParagraphStyle()
        tail.lineBreakMode = .byTruncatingTail
        t.addAttributes([.font: label.font!, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: tail],
                        range: NSRange(location: 0, length: t.length))
        return t
    }
    private func fit() {
        let room = bounds.width - 16
        guard !parentName.isEmpty, room > 0 else { label.attributedStringValue = make(nil); return }
        let full = make(parentName)
        if full.size().width + 4 <= room { label.attributedStringValue = full; return }
        // 親の名前を後ろから縮めていく (いちばん短くて「..」だけ)
        var p = parentName
        while !p.isEmpty {
            p.removeLast()
            let a = make(p + "..")
            if a.size().width + 4 <= room { label.attributedStringValue = a; return }
        }
        let dots = make("..")
        label.attributedStringValue = dots.size().width + 4 <= room ? dots : make(nil)
    }
    override func layout() {
        super.layout()
        if bounds.width != lastWidth { lastWidth = bounds.width; fit() }
    }

    override func draw(_ dirtyRect: NSRect) {
        // 薄い地に、上下の細い線 (上のフォルダの欄との境目をはっきり)
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        bounds.fill()
        NSColor.labelColor.withAlphaComponent(0.2).setFill()   // 上の線 (はっきり)
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSColor.labelColor.withAlphaComponent(0.08).setFill()  // 下の線 (うすく)
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}
