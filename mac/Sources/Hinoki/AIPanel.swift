import AppKit
import HinokiCore

/// エディタ右側の AI アシスタント欄。
/// 依頼 (右) と答え (左) が、チャットのように上から順に積み上がる。
/// (1 回ごとの依頼は独立していて、前の答えを覚えて続きを話すわけではない。毎回、いまの文章を対象にする)
final class AIPanel: NSView, NSTextViewDelegate {
    /// 答えの使い方
    enum ApplyKind {
        /// 対象を置き換える
        case replace
        /// 対象のあとに足す
        case insert
        /// 読むだけ
        case none
        /// 自分で書いた頼みごと (「自動で書き換える」なら対象を置き換える)
        case ask
    }

    /// 依頼の種類
    enum Action: CaseIterable {
        case continueWriting, proofread, summarize, rewrite, translate, explain

        var title: String { L(titleKey) }

        /// 日本語の名前 (メニューの項目を覚えておく名前にも使う)
        var titleKey: String {
            switch self {
            case .continueWriting: return "続きを書く"
            case .proofread: return "校正"
            case .summarize: return "要約"
            case .rewrite: return "読みやすく"
            case .translate: return "翻訳 (日⇔英)"
            case .explain: return "説明"
            }
        }

        var instruction: String {
            switch self {
            case .continueWriting: return L("次の文章の続きを、同じ文体・言語で自然に書いてください。続きの部分だけを出力してください。")
            case .proofread: return L("次の文章の誤字脱字・文法の誤り・表記ゆれを直してください。直した後の全文だけを出力し、説明は付けないでください。")
            case .summarize: return L("次の文章を要点がわかるように短く要約してください。")
            case .rewrite: return L("次の文章を、意味を変えずに、より読みやすく自然な文章に書き直してください。書き直した文章だけを出力してください。")
            case .translate: return L("次の文章が日本語なら英語に、それ以外なら日本語に翻訳してください。訳文だけを出力してください。")
            case .explain: return L("次の文章 (またはプログラム) が何を言っているか・何をしているかを、わかりやすく日本語で説明してください。")
            }
        }

        /// 校正・読みやすく・翻訳は置き換え、続きを書くは後ろに足す、要約・説明は読むだけ
        var apply: ApplyKind {
            switch self {
            case .proofread, .rewrite, .translate: return .replace
            case .continueWriting: return .insert
            case .summarize, .explain: return .none
            }
        }
    }

    /// 原稿用紙 (作文) を開いているときの、作文向けの定型の依頼
    struct EssayAction {
        let titleKey: String
        let instructionKey: String
        let apply: ApplyKind
        var title: String { L(titleKey) }
        var instruction: String { L(instructionKey) }

        static let all: [EssayAction] = [
            EssayAction(titleKey: "題名・名前・本文の形に整える", instructionKey: "次の作文を、原稿用紙の作文の形 (1 行目に題名、2 行目に名前、3 行目は空けて、4 行目から本文) に整えてください。題名や名前が分からなければ、題名は内容に合うものを考え、名前の行は「名前」としてください。本文は原稿用紙の決まりに合わせ、内容は変えないでください。整えた後の全文だけを出力してください。", apply: .replace),
            EssayAction(titleKey: "誤字・表記を直す (作文)", instructionKey: "次の作文の誤字脱字・送りがな・句読点・表記ゆれを直してください。原稿用紙の作文の決まりに合わせ、内容や言い回しは変えないでください。直した後の全文だけを出力してください。", apply: .replace),
            EssayAction(titleKey: "読みやすく (作文)", instructionKey: "次の作文を、書いた人らしさと内容を変えずに、読みやすい作文に整えてください。整えた後の全文だけを出力してください。", apply: .replace),
            EssayAction(titleKey: "続きを書く (作文)", instructionKey: "次の作文の続きを、同じ文体・同じ書き手の気持ちで自然に書いてください。続きの部分だけを出力してください。", apply: .insert),
            EssayAction(titleKey: "400 字にまとめる", instructionKey: "次の作文を、原稿用紙 1 枚 (400 字) ほどにまとめてください。題名と名前の行は残し、まとめた後の全文だけを出力してください。", apply: .replace),
            EssayAction(titleKey: "800 字にふくらませる", instructionKey: "次の作文を、内容を変えずに、くわしい様子や気持ちを足して原稿用紙 2 枚 (800 字) ほどにしてください。題名と名前の行は残し、ふくらませた後の全文だけを出力してください。", apply: .replace),
            EssayAction(titleKey: "先生のように講評", instructionKey: "次の作文を読んで、先生のように講評してください。よいところを 3 つ、もっとよくなるところを 3 つ、書いた人に伝わるやさしい言葉で書いてください。", apply: .none),
            EssayAction(titleKey: "題名を考える", instructionKey: "次の作文に合う題名の案を 5 つ考えてください。", apply: .none),
        ]
    }

    /// 原稿用紙 (作文) を開いているか。定型の依頼が作文向けになる
    var essayMode = false

    /// 文章の書き換えを AI にどこまで任せるか (設定 "aiApply" の値と、画面に出す名前)
    static let applyModes: [(id: String, label: String)] = [
        ("auto", L("自動で書き換える")),
        ("confirm", L("確認してから書き換える")),
        ("never", L("書き換えない (読むだけ)")),
    ]

    /// (AI への指示, 答えの使い方, やりとりに出す言葉)
    var onRun: ((String, ApplyKind, String) -> Void)?
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let badge = NSTextField(labelWithString: "")
    private let providerLabel = NSTextField(labelWithString: "")
    private let setupNotice = NSTextField(wrappingLabelWithString: L("まだ使えません。\nAI の設定をして「接続テスト」で確認してください。"))
    private let setupButton = NSButton(title: L("設定を開く"), target: nil, action: nil)
    private var setupRow = NSStackView()
    private let logScroll = NSScrollView()
    private let logContent = FlippedView()
    private let logStack = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: L("頼みたいことを書いて送るか、入力欄の「…」から定型の依頼を選びます。範囲を選んでいればその部分、選んでいなければ文書全体が対象です。"))
    private var actionButtons: [NSButton] = []
    private let composer = ComposerView()
    private let input = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    private let inputScroll = NSScrollView()
    private let placeholder = PassThroughLabel(labelWithString: L("AI に頼みたいことを書く"))
    private let sendButton = NSButton(title: "↑", target: nil, action: nil)
    /// 入力欄の中の「…」: 定型の依頼 (校正・要約・続きを書く など) を選ぶ
    private let templateButton = NSButton(title: "…", target: nil, action: nil)
    private var inputHeight: NSLayoutConstraint!
    private let applyPopup = NSPopUpButton()
    private var answers: [AIAnswerView] = []
    private var ready = true
    private(set) var running = false

    /// 欄の幅 (左の端をドラッグして変えられる。次からもこの幅)
    static var panelWidth: CGFloat {
        get {
            let w = UserDefaults.standard.double(forKey: "aiPanelWidth")
            return w > 0 ? CGFloat(w) : 300
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "aiPanelWidth") }
    }
    static let minWidth: CGFloat = 260
    static let maxWidth: CGFloat = 900

    /// 吹き出しの中の文字の幅 (欄の幅に合わせる)
    static var bubbleTextWidth: CGFloat { (detachedWidth ?? panelWidth) - 78 }
    /// 別のウインドウに取り出しているあいだの、欄の幅 (ウインドウの大きさで変わる)
    static var detachedWidth: CGFloat?

    /// 別のウインドウに取り出す / 元に戻す
    var onToggleDetach: (() -> Void)?
    private(set) var isDetached = false
    private weak var resizeHandle: NSView?
    private weak var sideLine: NSView?
    private weak var detachButton: NSButton?
    private var lastLaidOutWidth: CGFloat = 0

    /// 取り出したとき: 幅は固定せずウインドウに合わせる。左のつまみと線は要らない
    func setDetached(_ on: Bool) {
        isDetached = on
        widthConstraint?.isActive = !on
        resizeHandle?.isHidden = on
        sideLine?.isHidden = on
        detachButton?.title = on ? "⇤" : "⧉"
        detachButton?.toolTip = on ? L("エディタの横に戻す") : L("別のウインドウに取り出す")
        if !on {
            Self.detachedWidth = nil
            rewrapBubbles()
        }
    }

    override func layout() {
        super.layout()
        fitInputWidth()
        // 取り出したウインドウの大きさを変えたら、吹き出しの折り返しも合わせる
        guard isDetached, abs(bounds.width - lastLaidOutWidth) > 1 else { return }
        lastLaidOutWidth = bounds.width
        Self.detachedWidth = bounds.width
        rewrapBubbles()
    }

    /// 吹き出しの文字の折り返し幅を、いまの欄の幅に合わせる
    private func rewrapBubbles() {
        func walk(_ v: NSView) {
            if let f = v as? NSTextField, f.preferredMaxLayoutWidth > 0, f.preferredMaxLayoutWidth != 190 {
                // 中身の枠 (等幅の字) は、枠の余白のぶん狭く
                f.preferredMaxLayoutWidth = Self.bubbleTextWidth - (f.font?.isFixedPitch == true ? 18 : 0)
            }
            v.subviews.forEach(walk)
        }
        walk(logStack)
    }

    private var widthConstraint: NSLayoutConstraint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func iconButton(_ title: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .inline
        b.isBordered = false
        b.font = .systemFont(ofSize: 13)
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return b
    }

    private func build() {
        let title = NSTextField(labelWithString: L("AI アシスタント"))
        title.font = .boldSystemFont(ofSize: 13)
        badge.font = .boldSystemFont(ofSize: 10)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 7
        badge.alignment = .center
        badge.setContentHuggingPriority(.required, for: .horizontal)
        // よく使う依頼・やりとりを消す・利用状況・設定は「≡」の中にまとめる
        let titleRow = NSStackView(views: [title, badge, NSView(),
                                           { let b = iconButton("⧉", L("別のウインドウに取り出す"), #selector(detachPressed(_:))); detachButton = b; return b }(),
                                           iconButton("≡", L("メニュー (設定など)"), #selector(menuPressed(_:))),
                                           iconButton("✕", L("閉じる"), #selector(close(_:)))])
        titleRow.spacing = 4
        providerLabel.font = .systemFont(ofSize: 10)
        providerLabel.textColor = .secondaryLabelColor
        providerLabel.lineBreakMode = .byTruncatingTail

        setupNotice.font = .boldSystemFont(ofSize: 11)
        setupNotice.textColor = .systemOrange
        setupNotice.preferredMaxLayoutWidth = 190
        setupButton.bezelStyle = .rounded
        setupButton.controlSize = .small
        setupButton.target = self
        setupButton.action = #selector(openSettings(_:))
        setupRow = NSStackView(views: [setupNotice, setupButton])
        setupRow.alignment = .centerY
        setupRow.isHidden = true

        // やりとり (上から下へ積み上がり、コンソールのようにスクロールする)
        logStack.orientation = .vertical
        logStack.alignment = .leading
        logStack.spacing = 8
        logStack.edgeInsets = NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 14) // 右はスクロールバーのぶん空ける
        logStack.translatesAutoresizingMaskIntoConstraints = false
        logContent.translatesAutoresizingMaskIntoConstraints = false
        logContent.addSubview(logStack)
        logScroll.documentView = logContent
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.drawsBackground = false
        logScroll.setAccessibilityLabel(L("AI とのやりとり"))
        NSLayoutConstraint.activate([
            logContent.widthAnchor.constraint(equalTo: logScroll.contentView.widthAnchor),
            logStack.leadingAnchor.constraint(equalTo: logContent.leadingAnchor),
            logStack.trailingAnchor.constraint(equalTo: logContent.trailingAnchor),
            logStack.topAnchor.constraint(equalTo: logContent.topAnchor),
            logStack.bottomAnchor.constraint(equalTo: logContent.bottomAnchor),
        ])
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.preferredMaxLayoutWidth = 250
        logStack.addArrangedSubview(emptyLabel)

        // よく使う依頼のボタン (3 つ × 2 段、左に詰めて並べる)
        var chipRows: [NSStackView] = []
        var row: [NSView] = []
        for (i, a) in Action.allCases.enumerated() {
            let b = NSButton(title: a.title, target: self, action: #selector(actionPressed(_:)))
            b.bezelStyle = .roundRect
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.tag = i
            actionButtons.append(b)
            row.append(b)
            if row.count == 3 {
                let r = NSStackView(views: row)
                r.spacing = 4
                chipRows.append(r)
                row = []
            }
        }
        let grid = NSStackView(views: chipRows)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 4

        // 入力欄: 角の丸い枠の中に、書いた行数に合わせて伸びる欄と、丸い送信ボタン (答えを待つあいだは中止ボタン)
        composer.wantsLayer = true
        composer.layer?.cornerRadius = 14
        composer.layer?.borderWidth = 1
        composer.layer?.borderColor = NSColor.separatorColor.cgColor
        composer.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        composer.translatesAutoresizingMaskIntoConstraints = false
        input.isRichText = false
        input.isEditable = true
        input.isSelectable = true
        input.minSize = NSSize(width: 0, height: 24)
        input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.font = .systemFont(ofSize: 14) // 自分で書いている字が読みやすい大きさ
        input.drawsBackground = false
        input.delegate = self
        input.isVerticallyResizable = true
        input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]
        input.textContainer?.widthTracksTextView = true
        input.textContainerInset = NSSize(width: 2, height: 4)
        input.allowsUndo = true
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        input.setAccessibilityLabel(L("AI に頼みたいことを書く"))
        inputScroll.documentView = input
        inputScroll.drawsBackground = false
        inputScroll.borderType = .noBorder
        inputScroll.hasVerticalScroller = false
        inputScroll.translatesAutoresizingMaskIntoConstraints = false
        placeholder.font = .systemFont(ofSize: 14)
        placeholder.textColor = .placeholderTextColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        sendButton.isBordered = false
        sendButton.wantsLayer = true
        sendButton.layer?.cornerRadius = 13
        sendButton.target = self
        sendButton.action = #selector(sendPressed(_:))
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        // 枠のどこを押しても、入力欄に文字が打てるようにする (案内の文字の上を押したときも)
        input.onTyping = { [weak self] in self?.growInput() } // 変換中の文字が増えたときも伸ばす
        composer.onClick = { [weak self] in
            guard let self = self, self.input.isEditable else { return }
            self.window?.makeFirstResponder(self.input)
        }
        composer.addSubview(inputScroll)
        composer.addSubview(placeholder)
        composer.addSubview(sendButton)
        templateButton.isBordered = false
        templateButton.font = .boldSystemFont(ofSize: 15)
        templateButton.contentTintColor = .secondaryLabelColor
        templateButton.target = self
        templateButton.action = #selector(templatePressed(_:))
        templateButton.toolTip = L("定型の依頼 (校正・要約・続きを書く など) を選ぶ")
        templateButton.setAccessibilityLabel(L("定型の依頼を選ぶ"))
        templateButton.translatesAutoresizingMaskIntoConstraints = false
        composer.addSubview(templateButton)
        inputHeight = inputScroll.heightAnchor.constraint(equalToConstant: 26)
        NSLayoutConstraint.activate([
            inputScroll.leadingAnchor.constraint(equalTo: composer.leadingAnchor, constant: 8),
            inputScroll.trailingAnchor.constraint(equalTo: templateButton.leadingAnchor, constant: -2),
            templateButton.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -4),
            templateButton.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            templateButton.widthAnchor.constraint(equalToConstant: 24),
            inputScroll.topAnchor.constraint(equalTo: composer.topAnchor, constant: 5),
            inputScroll.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -5),
            inputHeight,
            placeholder.leadingAnchor.constraint(equalTo: inputScroll.leadingAnchor, constant: 7),
            placeholder.topAnchor.constraint(equalTo: inputScroll.topAnchor, constant: 4),
            sendButton.trailingAnchor.constraint(equalTo: composer.trailingAnchor, constant: -5),
            sendButton.bottomAnchor.constraint(equalTo: composer.bottomAnchor, constant: -4),
            sendButton.widthAnchor.constraint(equalToConstant: 26),
            sendButton.heightAnchor.constraint(equalToConstant: 26),
        ])

        // 文章の書き換えをどこまで AI に任せるか
        for m in Self.applyModes { applyPopup.addItem(withTitle: m.label) }
        applyPopup.controlSize = .small
        applyPopup.font = .systemFont(ofSize: 10)
        applyPopup.target = self
        applyPopup.action = #selector(applyModeChanged(_:))
        applyPopup.toolTip = L("AI による書き換え")
        applyPopup.setAccessibilityLabel(L("AI による書き換え"))
        let hint = NSTextField(labelWithString: L("Enter で送信 ・ Shift+Enter で改行"))
        hint.font = .systemFont(ofSize: 9)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let foot = NSStackView(views: [hint, NSView(), applyPopup])
        foot.spacing = 4

        grid.isHidden = true // よく使う依頼は「≡」のメニューへ移した
        let stack = NSStackView(views: [titleRow, providerLabel, setupRow, logScroll, grid, composer, foot])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for v in [titleRow, providerLabel, logScroll, composer, foot] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }
        logScroll.setContentHuggingPriority(.init(1), for: .vertical)
        logScroll.setContentCompressionResistancePriority(.init(1), for: .vertical)
        let wc = widthAnchor.constraint(equalToConstant: Self.panelWidth)
        wc.isActive = true
        widthConstraint = wc
        // 左の端: ドラッグで幅を変える
        let handle = PanelResizeHandle()
        handle.onDrag = { [weak self] dx in self?.resize(by: dx) }
        handle.onEnd = { [weak self] in
            guard let self = self, let w = self.widthConstraint?.constant else { return }
            Self.panelWidth = w
        }
        handle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(handle)
        resizeHandle = handle
        NSLayoutConstraint.activate([
            handle.leadingAnchor.constraint(equalTo: leadingAnchor),
            handle.topAnchor.constraint(equalTo: topAnchor),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.widthAnchor.constraint(equalToConstant: 6),
        ])

        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        sideLine = line
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),
        ])
        refreshProvider()
        refreshApplyMode()
        updateControls()
    }

    // MARK: 表示の更新

    func refreshProvider() {
        let p = AISettings.provider
        let m = AISettings.model(p)
        let name = p.label.components(separatedBy: " (").first ?? p.label
        providerLabel.stringValue = m.isEmpty ? "\(name) · " + L("(モデル未設定)") : "\(name) · \(m)"
    }

    /// 設定と接続の確認が済んでいないときは、送る操作をすべて止めて設定へ案内する
    func setReady(_ on: Bool) {
        ready = on
        setupRow.isHidden = on
        updateControls()
    }

    /// 答えを待っているあいだ (送信ボタンが中止ボタンになる)
    func setRunning(_ on: Bool) {
        running = on
        updateControls()
    }

    private func updateControls() {
        // 使えるときは緑の印だけ。使えないときは「未設定」
        badge.stringValue = ready ? "●" : " " + L("未設定") + " "
        badge.font = ready ? .systemFont(ofSize: 12) : .boldSystemFont(ofSize: 10)
        badge.textColor = ready ? .systemGreen : .secondaryLabelColor
        badge.layer?.backgroundColor = (ready ? NSColor.clear : NSColor.quaternaryLabelColor).cgColor
        badge.toolTip = ready ? L("接続を確認済みです。AI を使えます。") : L("まだ使えません。AI の設定をして「接続テスト」で確認してください。")
        actionButtons.forEach { $0.isEnabled = ready && !running }
        templateButton.isEnabled = ready && !running
        input.isEditable = ready
        placeholder.stringValue = ready ? L("AI に頼みたいことを書く") : L("未設定です (設定を開いてください)")
        updatePlaceholder()
        let active = running || ready
        sendButton.isEnabled = active
        sendButton.attributedTitle = NSAttributedString(string: running ? "■" : "↑", attributes: [
            .font: NSFont.boldSystemFont(ofSize: running ? 11 : 15), .foregroundColor: NSColor.white,
        ])
        sendButton.layer?.backgroundColor = (active ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).cgColor
        sendButton.toolTip = running ? L("中止") : L("送信 (Enter)")
        sendButton.setAccessibilityLabel(running ? L("中止") : L("送信"))
        refreshApplyMode()
    }

    /// 「書き換えない」のときは、挿入・置き換えを使えなくする (コピーだけ)
    func refreshApplyMode() {
        let mode = AISettings.applyMode
        applyPopup.selectItem(at: Self.applyModes.firstIndex { $0.id == mode } ?? 1)
        answers.forEach { $0.setApplyEnabled(mode != "never" && !running) }
    }

    /// 依頼 (右) と、これから答えが入る吹き出し (左) を足す
    /// 左の端を dx だけ動かした (左へ動かすと広がる)
    private func resize(by dx: CGFloat) {
        guard let wc = widthConstraint else { return }
        // 本文が狭くなりすぎないように (本文を 300 は残す)
        let windowLimit = (window?.contentView?.bounds.width ?? 2000) - 300
        let w = min(max(Self.minWidth, wc.constant - dx), min(Self.maxWidth, max(Self.minWidth, windowLimit)))
        guard w != wc.constant else { return }
        wc.constant = w
        Self.panelWidth = w
        rewrapBubbles()
    }

    @objc private func detachPressed(_ sender: Any?) { onToggleDetach?() }

    func addExchange(request: String, note: String) -> AIAnswerView {
        emptyLabel.isHidden = true
        let ask = AIRequestView(text: request, note: note)
        let askRow = NSStackView(views: [NSView(), ask])
        logStack.addArrangedSubview(askRow)
        askRow.widthAnchor.constraint(equalTo: logStack.widthAnchor, constant: -20).isActive = true
        let answer = AIAnswerView()
        answer.onGrow = { [weak self] in self?.scrollDownIfNearBottom() }
        answers.append(answer)
        logStack.addArrangedSubview(answer)
        answer.startWaiting()
        scrollDown()
        return answer
    }

    func clear() {
        for v in logStack.arrangedSubviews where v !== emptyLabel {
            logStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        answers = []
        emptyLabel.isHidden = false
    }

    private var nearBottom: Bool {
        let clip = logScroll.contentView
        return logContent.frame.height - clip.bounds.maxY < 40
    }

    private func scrollDownIfNearBottom() {
        // 読み返しているとき (上にスクロールしているとき) は動かさない
        if nearBottom { scrollDown() }
    }

    func scrollDown() {
        layoutSubtreeIfNeeded()
        let clip = logScroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: max(0, logContent.frame.height - clip.bounds.height)))
        logScroll.reflectScrolledClipView(clip)
    }

    // MARK: 入力欄

    /// 書いた行数に合わせて入力欄を伸ばす (欄の高さの 4 割まで。それ以上は中でスクロールし、書いているところを見せる)
    private func growInput() {
        updatePlaceholder()
        guard let lm = input.layoutManager, let tc = input.textContainer else { return }
        fitInputWidth()
        lm.ensureLayout(for: tc)
        let inset = input.textContainerInset.height * 2
        let oneLine = ceil(lm.defaultLineHeight(for: input.font ?? .systemFont(ofSize: 14))) + inset
        let limit = max(140, min(360, bounds.height * 0.4))
        let h = max(oneLine, ceil(lm.usedRect(for: tc).height) + inset)
        let newHeight = min(limit, h)
        if inputHeight.constant != newHeight {
            inputHeight.constant = newHeight
            layoutSubtreeIfNeeded()
        }
        inputScroll.hasVerticalScroller = h > limit
        input.scrollRangeToVisible(input.selectedRange())
    }

    func textDidChange(_ notification: Notification) { growInput() }

    /// 入力欄の幅を、見えている幅に合わせる (広すぎると、長い文が横にはみ出して左右が切れる)
    private func fitInputWidth() {
        let w = inputScroll.contentSize.width
        guard w > 0, abs(input.frame.width - w) > 0.5 else { return }
        input.setFrameSize(NSSize(width: w, height: input.frame.height))
        input.textContainer?.containerSize = NSSize(width: w, height: CGFloat.greatestFiniteMagnitude)
        DispatchQueue.main.async { [weak self] in self?.growInput() }
    }

    /// 動作確認用: 入力欄に文字を入れる (打ったのと同じように伸びるか)
    func fillInputForTest(_ text: String) {
        input.string = text
        growInput()
    }

    /// 案内の文字は、1 文字でも打ちはじめたら (日本語入力の変換中も) 消す
    private func updatePlaceholder() {
        placeholder.isHidden = !input.string.isEmpty || input.hasMarkedText()
    }

    /// Enter = 送信、Shift+Enter = 改行。日本語入力の変換中の Enter は確定に使われるので送らない
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if textView.hasMarkedText() { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        send()
        return true
    }

    private func send() {
        let t = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, !running, !t.isEmpty else { return }
        input.string = ""
        growInput()
        // 自分で書いた頼みごと。「自動で書き換える」のときは、答えで対象を置き換える
        onRun?(t, .ask, t)
    }

    /// 動作確認用: 入力欄に書いて送る
    func sendForTesting(_ text: String) {
        input.string = text
        growInput()
        send()
    }

    func focusInput() { window?.makeFirstResponder(input) }

    // MARK: 操作

    /// メニューやボタンから、決まった依頼を送る
    func run(_ action: Action) {
        guard ready, !running else { return }
        onRun?(action.instruction, action.apply, action.title)
    }

    @objc private func actionPressed(_ sender: NSButton) { run(Action.allCases[sender.tag]) }

    /// 「≡」: よく使う依頼と、やりとりを消す・利用状況・設定
    @objc private func menuPressed(_ sender: NSButton) {
        let m = NSMenu()
        m.autoenablesItems = false
        func add(_ title: String, _ action: Selector, tag: Int = 0, enabled: Bool = true) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.tag = tag
            i.isEnabled = enabled
            m.addItem(i)
        }
        add(L("やりとりを消す"), #selector(clearPressed(_:)))
        add(L("利用状況と料金…"), #selector(showUsage(_:)))
        add(L("AI の設定…"), #selector(openSettings(_:)))
        add(L("ローカルLLM簡単設定…"), #selector(openLocalAI(_:)))
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func openLocalAI(_ sender: Any?) { LocalAIWindowController.shared.show() }

    /// 入力欄の「…」: 定型の依頼の一覧。選ぶと、そのまま頼む
    @objc private func templatePressed(_ sender: NSButton) {
        let m = NSMenu()
        m.autoenablesItems = false
        if essayMode {
            // 原稿用紙のときは、作文向けの依頼
            m.addItem(MainMenu.sectionHeader("作文の定型の依頼"))
            for (i, a) in EssayAction.all.enumerated() {
                let item = NSMenuItem(title: a.title, action: #selector(essayMenuPicked(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                item.isEnabled = ready && !running
                m.addItem(item)
            }
        } else {
            m.addItem(MainMenu.sectionHeader("定型の依頼"))
            for (i, a) in Action.allCases.enumerated() {
                let item = NSMenuItem(title: a.title, action: #selector(actionMenuPicked(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                item.isEnabled = ready && !running
                m.addItem(item)
            }
        }
        // 見やすく: 大きめの字・広めの幅で、ボタンの上に出す (下の入力欄に重ならないよう)
        m.font = .systemFont(ofSize: 14)
        m.minimumWidth = 240
        let h = m.size.height
        let y = sender.isFlipped ? -h - 6 : sender.bounds.height + h + 6
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: sender)
    }

    @objc private func essayMenuPicked(_ sender: NSMenuItem) {
        guard EssayAction.all.indices.contains(sender.tag), ready, !running else { return }
        let a = EssayAction.all[sender.tag]
        onRun?(a.instruction, a.apply, a.title)
    }

    @objc private func actionMenuPicked(_ sender: NSMenuItem) {
        guard Action.allCases.indices.contains(sender.tag) else { return }
        run(Action.allCases[sender.tag])
    }

    @objc private func sendPressed(_ sender: Any?) {
        if running { onCancel?() } else { send() }
    }

    @objc private func applyModeChanged(_ sender: NSPopUpButton) {
        AISettings.applyMode = Self.applyModes[max(0, sender.indexOfSelectedItem)].id
        refreshApplyMode()
    }

    @objc private func clearPressed(_ sender: Any?) {
        if running { onCancel?() }
        clear()
    }

    @objc private func openSettings(_ sender: Any?) { onOpenSettings?() }
    @objc private func showUsage(_ sender: Any?) { AIUsageWindowController.shared.show() }
    @objc private func close(_ sender: Any?) { onClose?() }
}

/// 角の丸い吹き出し
/// 角の丸い吹き出し。色は明るい・暗い見た目に合わせて塗り直す (作ったときの色で固まらないように)
final class BubbleView: NSView {
    var fill: NSColor = .clear { didSet { needsDisplay = true } }
    var border: NSColor? { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = border?.cgColor
            layer?.borderWidth = border == nil ? 0 : 1
        }
    }
}

/// 中身 (コード・直した文章) の枠の色: 暗い見た目では黒っぽく、明るい見た目ではごく薄い灰色
private let contentFill = NSColor(name: nil) { a in
    a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0, alpha: 0.28) : NSColor(white: 0, alpha: 0.045)
}

private func makeBubble(_ content: NSView, color: NSColor) -> NSView {
    let bubble = BubbleView()
    bubble.wantsLayer = true
    bubble.layer?.cornerRadius = 10
    bubble.fill = color
    bubble.translatesAutoresizingMaskIntoConstraints = false
    content.translatesAutoresizingMaskIntoConstraints = false
    bubble.addSubview(content)
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 9),
        content.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -9),
        content.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 6),
        content.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -6),
    ])
    return bubble
}

private func wrappingLabel(_ s: String, size: CGFloat, color: NSColor = .labelColor) -> NSTextField {
    let f = NSTextField(wrappingLabelWithString: s)
    f.font = .systemFont(ofSize: size)
    f.textColor = color
    f.isSelectable = true
    f.preferredMaxLayoutWidth = AIPanel.bubbleTextWidth
    return f
}

/// 依頼の吹き出し (右寄せ)。下に小さく「ファイル名 ・ 対象」を出す
final class AIRequestView: NSView {
    init(text: String, note: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [wrappingLabel(text, size: 12), wrappingLabel(note, size: 9, color: .secondaryLabelColor)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        let bubble = makeBubble(stack, color: NSColor.controlAccentColor.withAlphaComponent(0.22))
        addSubview(bubble)
        NSLayoutConstraint.activate([
            bubble.leadingAnchor.constraint(equalTo: leadingAnchor),
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubble.topAnchor.constraint(equalTo: topAnchor),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 答えの吹き出し (左寄せ)。答えは少しずつ届く。答えごとに 挿入 / 置き換え / コピー と使った量が付く
final class AIAnswerView: NSView {
    /// 答えの本文
    private(set) var text = ""
    /// true = 置き換え、false = 対象のあとに足す
    var onApply: ((Bool) -> Void)?
    /// 「⋮ > 反映」: 本文をまるごとこの答えに置き換える
    var onReflect: (() -> Void)?
    var onGrow: (() -> Void)?

    private let body = wrappingLabel("…", size: 12)
    private let errorLabel = wrappingLabel("", size: 11, color: .systemRed)
    private let confirmLabel = wrappingLabel("", size: 11)
    private let confirmYes = NSButton(title: "", target: nil, action: nil)
    private let confirmNo = NSButton(title: L("書き換えない"), target: nil, action: nil)
    private var confirmBox = NSStackView()
    private var applyButtons: [NSButton] = []
    private let usageLabel = wrappingLabel("", size: 9, color: .secondaryLabelColor)
    private let moreButton = NSButton(title: "…", target: nil, action: nil)
    /// 使った量 (「…」の中に出す)
    private var usageText = ""
    private var confirmAction: (() -> Void)?
    private var applyAllowed = true
    private var finished = false
    /// 文章に入れる中身 (コンパクトに、等幅の小さな字で)
    private let contentLabel = wrappingLabel("", size: 10.5)
    private var contentBox = NSView()
    private let toggleButton = NSButton(title: "", target: nil, action: nil)
    /// 長い答えを畳んでいるか
    private var collapsed = true
    private static let collapsedMessageLines = 4
    private static let collapsedContentLines = 4

    /// 文章に入れるもの: <result> の中身。囲みがなければ答え全体
    var applyText: String { AIAnswerParts.split(text).content ?? text }
    /// 文章に入れる中身があるか (質問への答えなら false)
    var hasContent: Bool { AIAnswerParts.split(text).content != nil }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        func small(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 10)
            return b
        }
        // 答えの右下の角: 「⋮」(挿入・置き換え・コピー・使った量) だけ
        let copyIcon = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: L("コピー"))!,
                                target: self, action: #selector(copyPressed(_:)))
        copyIcon.isBordered = false
        copyIcon.contentTintColor = .secondaryLabelColor
        copyIcon.toolTip = L("コピー")
        moreButton.title = "⋮"
        moreButton.isBordered = false
        moreButton.font = .boldSystemFont(ofSize: 13)
        moreButton.contentTintColor = .secondaryLabelColor
        moreButton.target = self
        moreButton.action = #selector(morePressed(_:))
        moreButton.toolTip = L("反映・コピー・使った量")
        let insert = small(L("挿入"), #selector(insertPressed(_:)))
        insert.toolTip = L("頼んだときの対象のあとに足す")
        let replace = small(L("置き換え"), #selector(replacePressed(_:)))
        replace.toolTip = L("頼んだときの対象 (選んでいた範囲、なければ文書全体) をこの答えに置き換える")
        applyButtons = [insert, replace]
        _ = copyIcon // コピーは「⋮」の中だけ

        for b in [confirmYes, confirmNo] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 10)
            b.target = self
        }
        confirmYes.action = #selector(confirmYesPressed(_:))
        confirmYes.keyEquivalent = ""
        confirmNo.action = #selector(confirmNoPressed(_:))
        let confirmButtons = NSStackView(views: [confirmYes, confirmNo])
        confirmButtons.spacing = 4
        confirmBox = NSStackView(views: [confirmLabel, confirmButtons])
        confirmBox.orientation = .vertical
        confirmBox.alignment = .leading
        confirmBox.spacing = 4
        confirmBox.isHidden = true
        errorLabel.isHidden = true
        usageLabel.isHidden = true

        contentLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        contentLabel.preferredMaxLayoutWidth = AIPanel.bubbleTextWidth - 18
        contentLabel.cell?.truncatesLastVisibleLine = true
        body.cell?.truncatesLastVisibleLine = true
        contentBox = makeBubble(contentLabel, color: contentFill)
        contentBox.layer?.cornerRadius = 6
        (contentBox as? BubbleView)?.border = .separatorColor
        contentBox.isHidden = true
        toggleButton.bezelStyle = .inline
        toggleButton.controlSize = .small
        toggleButton.font = .systemFont(ofSize: 10)
        toggleButton.target = self
        toggleButton.action = #selector(togglePressed(_:))
        toggleButton.isHidden = true
        applyCollapse()

        // 「⋮」は行を取らず、吹き出しの右下の角に置く (本文の右を少し空けて、重ならないように)
        let stack = NSStackView(views: [body, contentBox, toggleButton, errorLabel, confirmBox, usageLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 10)
        let bubble = makeBubble(stack, color: NSColor.labelColor.withAlphaComponent(0.07))
        addSubview(bubble)
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.isHidden = true
        bubble.addSubview(moreButton)
        NSLayoutConstraint.activate([
            bubble.leadingAnchor.constraint(equalTo: leadingAnchor),
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubble.topAnchor.constraint(equalTo: topAnchor),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
            moreButton.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -2),
            moreButton.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -2),
            moreButton.widthAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: 打ち込むように見せる

    /// 届いた文字 (表示はこれを少しずつ追いかける)
    private var received: [Character] = []
    private var shownCount = 0
    private var ticker: Timer?
    private var tick = 0
    /// 動きを減らす設定 (アクセシビリティ) のときは、届いた分をそのまま出す
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private static let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    /// 答えを待ちはじめる (まだ 1 文字も届いていないあいだは、くるくる回る印と「考え中」を出す)
    func startWaiting() {
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        step()
    }

    private func step() {
        tick += 1
        if received.isEmpty {
            if finished { stopTicker(); return }
            let dots = reduceMotion ? "…" : String(repeating: ".", count: (tick / 8) % 4)
            body.textColor = .secondaryLabelColor
            body.stringValue = (reduceMotion ? "⏳" : Self.spinner[(tick / 2) % Self.spinner.count]) + " " + L("考え中") + dots
            return
        }
        body.textColor = .labelColor
        // 遅れがたまったら速く打つ (いつまでも追いつかない、ということがないように)
        let backlog = received.count - shownCount
        if backlog > 0 {
            shownCount += max(4, backlog / 4)   // 速めに打つ
            shownCount = min(shownCount, received.count)
        }
        let caretOn = (tick / 8) % 2 == 0
        let done = finished && shownCount >= received.count
        render(String(received[0..<shownCount]), caret: done ? "" : (caretOn ? "▍" : " "))
        onGrow?()
        if done { stopTicker() }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        if !received.isEmpty { render(text, caret: "") }
        moreButton.isHidden = text.isEmpty || !finished
        onGrow?()
    }

    /// 届いた分を足す
    func append(_ piece: String) {
        text += piece
        received.append(contentsOf: piece)
        if reduceMotion {
            shownCount = received.count
            body.textColor = .labelColor
            render(text, caret: "")
            onGrow?()
            return
        }
        startWaiting()
    }

    /// 答えが終わった (error = うまくいかなかった理由、cancelled = 途中でやめた)
    func finish(error: String?, cancelled: Bool, usage: String) {
        finished = true
        // 途中でやめたり失敗したりしたら、残りは打たずにすぐ出す
        if error != nil || cancelled || reduceMotion { shownCount = received.count }
        if text.isEmpty {
            ticker?.invalidate()
            ticker = nil
            body.textColor = .labelColor
            body.stringValue = error != nil || cancelled ? "" : L("(答えが空でした)")
        } else if shownCount >= received.count {
            ticker?.invalidate()
            ticker = nil
            render(text, caret: "")
        }
        body.isHidden = body.stringValue.isEmpty
        if let e = error {
            errorLabel.stringValue = "⚠️ " + e
            errorLabel.isHidden = false
        }
        let note = cancelled ? L("中止しました") : usage
        usageText = note
        // 中止したことだけは見えるように残す。使った量は「…」の中へ
        usageLabel.stringValue = cancelled ? note : ""
        usageLabel.isHidden = !cancelled || note.isEmpty
        // 挿入・置き換えのボタンは、打ち終わってから出す
        moreButton.isHidden = text.isEmpty || ticker != nil
        setApplyEnabled(applyAllowed)
        onGrow?()
    }

    /// 「この答えで、対象の文章を置き換えますか？ [置き換える] [書き換えない]」を答えの下に出す
    func showConfirm(replace: Bool, action: @escaping () -> Void) {
        confirmLabel.stringValue = replace ? L("この答えで、対象の文章を置き換えますか？") : L("この答えを、対象の文章のあとに足しますか？")
        confirmYes.title = replace ? L("置き換える") : L("足す")
        confirmAction = action
        confirmBox.isHidden = false
        onGrow?()
    }

    func hideConfirm() { confirmBox.isHidden = true }

    var isConfirmShown: Bool { !confirmBox.isHidden }

    func setApplyEnabled(_ on: Bool) {
        applyAllowed = on
        applyButtons.forEach { $0.isEnabled = on && finished }
        confirmYes.isEnabled = on
    }

    /// 動作確認用: 確認の「置き換える / 足す」を押す
    func pressConfirmForTesting() { confirmYesPressed(nil) }

    /// 「⋮」: 反映 (本文をまるごと置き換える)・コピー と、使ったトークン・料金の目安
    @objc private func morePressed(_ sender: NSButton) {
        let m = NSMenu()
        m.autoenablesItems = false
        let reflect = NSMenuItem(title: L("反映"), action: #selector(reflectPressed(_:)), keyEquivalent: "")
        reflect.target = self
        reflect.isEnabled = applyAllowed && finished
        reflect.toolTip = L("本文をまるごと、この答えに置き換える (⌘Z で戻せます)")
        m.addItem(reflect)
        let copy = NSMenuItem(title: L("コピー"), action: #selector(copyPressed(_:)), keyEquivalent: "")
        copy.target = self
        m.addItem(copy)
        if !usageText.isEmpty {
            m.addItem(.separator())
            let u = NSMenuItem(title: usageText, action: nil, keyEquivalent: "")
            u.isEnabled = false
            m.addItem(u)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func insertPressed(_ sender: Any?) { onApply?(false) }
    @objc private func reflectPressed(_ sender: Any?) { onReflect?() }
    @objc private func replacePressed(_ sender: Any?) { onApply?(true) }

    @objc private func copyPressed(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(applyText, forType: .string)
    }

    // MARK: ひとこと と 中身 に分けて見せる

    /// s = いま見せる分の答え。ひとことは普通の字、中身は小さな等幅の枠に
    private func render(_ s: String, caret: String) {
        let p = AIAnswerParts.split(s)
        if let c = p.content {
            body.stringValue = p.message
            body.isHidden = p.message.isEmpty
            contentLabel.stringValue = c + (p.closed ? "" : caret)
            contentBox.isHidden = false
        } else {
            body.stringValue = p.message + caret
            body.isHidden = false
            contentBox.isHidden = true
        }
        updateToggle(p)
    }

    /// 長いときだけ「全部表示 / たたむ」を出す
    private func updateToggle(_ p: AIAnswerParts.Parts) {
        let perLine = max(20, Int(AIPanel.bubbleTextWidth / 7))
        func lines(_ s: String, _ width: Int) -> Int {
            s.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { $0 + max(1, ($1.count + width - 1) / width) }
        }
        let long = lines(p.message, perLine) > Self.collapsedMessageLines
            || lines(p.content ?? "", Int(Double(perLine) * 1.1)) > Self.collapsedContentLines
        toggleButton.isHidden = !long
        let n = (p.content ?? p.message).split(separator: "\n", omittingEmptySubsequences: false).count
        toggleButton.title = collapsed ? L("▼ 全部表示 ({0} 行)", n) : L("▲ たたむ")
    }

    private func applyCollapse() {
        body.maximumNumberOfLines = collapsed ? Self.collapsedMessageLines : 0
        contentLabel.maximumNumberOfLines = collapsed ? Self.collapsedContentLines : 0
    }

    @objc private func togglePressed(_ sender: Any?) {
        collapsed.toggle()
        applyCollapse()
        render(String(received[0..<min(shownCount, received.count)]), caret: "")
        if received.isEmpty { render(text, caret: "") }
        onGrow?()
    }

    @objc private func confirmYesPressed(_ sender: Any?) {
        hideConfirm()
        confirmAction?()
    }

    @objc private func confirmNoPressed(_ sender: Any?) { hideConfirm() }
}

/// 案内の文字: 押しても下の入力欄に届くように、自分ではクリックを受けない
final class PassThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// AI の入力欄の枠: 枠の余白を押しても入力欄に移る
final class ComposerView: NSView {
    var onClick: (() -> Void)?
    // 枠と背景の色は、明るい・暗い見た目に合わせて塗り直す
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// AI の入力欄: 変換中の文字 (未確定) が出たときも知らせる
final class ComposerTextView: NSTextView {
    var onTyping: (() -> Void)?
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onTyping?()
    }
    override func unmarkText() {
        super.unmarkText()
        onTyping?()
    }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        onTyping?()
    }
    override func didChangeText() {
        super.didChangeText()
        onTyping?()
    }
}

/// 横の欄の端: ドラッグで幅を変える (カーソルは左右の矢印)
final class PanelResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var last: CGFloat = 0

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) { last = event.locationInWindow.x }

    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        onDrag?(x - last)
        last = x
    }

    override func mouseUp(with event: NSEvent) { onEnd?() }
}
