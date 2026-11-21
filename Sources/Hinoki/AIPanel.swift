import AppKit

/// エディタ右側の AI アシスタント欄
final class AIPanel: NSView {
    /// 依頼の種類
    enum Action: CaseIterable {
        case continueWriting, proofread, summarize, rewrite, translate, explain

        var title: String {
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
            case .continueWriting: return "次の文章の続きを、同じ文体・言語で自然に書いてください。続きの部分だけを出力してください。"
            case .proofread: return "次の文章の誤字脱字・文法の誤り・表記ゆれを直してください。直した後の全文だけを出力し、説明は付けないでください。"
            case .summarize: return "次の文章を要点がわかるように短く要約してください。"
            case .rewrite: return "次の文章を、意味を変えずに、より読みやすく自然な文章に書き直してください。書き直した文章だけを出力してください。"
            case .translate: return "次の文章が日本語なら英語に、それ以外なら日本語に翻訳してください。訳文だけを出力してください。"
            case .explain: return "次の文章 (またはプログラム) が何を言っているか・何をしているかを、わかりやすく日本語で説明してください。"
            }
        }
    }

    /// (指示, 選択範囲だけか) → 送る文章を返してもらう
    var onRun: ((String) -> Void)?
    var onInsert: ((String) -> Void)?
    var onReplace: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?

    private let targetLabel = NSTextField(labelWithString: "")
    private let providerLabel = NSTextField(labelWithString: "")
    private let output = NSTextView()
    private let promptField = NSTextField()
    private let stopButton = NSButton(title: "中止", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let usageLabel = NSTextField(wrappingLabelWithString: "")
    private let setupNotice = NSTextField(wrappingLabelWithString: "まだ使えません。\nAI の設定をして「接続テスト」で確認してください。")
    private let setupButton = NSButton(title: "設定を開く", target: nil, action: nil)
    private var setupRow = NSStackView()
    private var sendButton: NSButton?
    private var ready = true
    var onOpenSettings: (() -> Void)?
    private var actionButtons: [NSButton] = []
    private var resultButtons: [NSButton] = []
    private(set) var running = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let title = NSTextField(labelWithString: "AI アシスタント")
        title.font = .boldSystemFont(ofSize: 13)
        let close = NSButton(title: "✕", target: self, action: #selector(close(_:)))
        close.bezelStyle = .inline
        providerLabel.font = .systemFont(ofSize: 10)
        providerLabel.textColor = .secondaryLabelColor
        providerLabel.lineBreakMode = .byTruncatingTail
        targetLabel.font = .systemFont(ofSize: 11)
        targetLabel.textColor = .secondaryLabelColor

        // よく使う依頼のボタン (3 列 × 2 行)
        let grid = NSGridView()
        grid.rowSpacing = 4
        grid.columnSpacing = 4
        var row: [NSView] = []
        for (i, a) in Action.allCases.enumerated() {
            let b = NSButton(title: a.title, target: self, action: #selector(actionPressed(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.tag = i
            actionButtons.append(b)
            row.append(b)
            if row.count == 3 { grid.addRow(with: row); row = [] }
        }

        promptField.placeholderString = "自由に指示 (例: 敬語にして) → return"
        promptField.target = self
        promptField.action = #selector(freePrompt(_:))
        let send = NSButton(title: "送る", target: self, action: #selector(freePrompt(_:)))
        send.bezelStyle = .rounded
        send.controlSize = .small
        sendButton = send
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
        let promptRow = NSStackView(views: [promptField, send])
        promptRow.spacing = 4

        output.isEditable = false
        output.isRichText = false
        output.font = .systemFont(ofSize: 12)
        output.textContainerInset = NSSize(width: 4, height: 4)
        output.isVerticallyResizable = true
        output.autoresizingMask = [.width]
        output.textContainer?.widthTracksTextView = true
        output.drawsBackground = false
        let scroll = NSScrollView()
        scroll.documentView = output
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .small
        stopButton.target = self
        stopButton.action = #selector(stop(_:))
        stopButton.isHidden = true
        for (t, sel) in [("挿入", #selector(insert(_:))), ("置き換え", #selector(replace(_:))), ("コピー", #selector(copyResult(_:)))] {
            let b = NSButton(title: t, target: self, action: sel)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.isEnabled = false
            resultButtons.append(b)
        }
        resultButtons[0].toolTip = "カーソルの位置に入れる"
        resultButtons[1].toolTip = "選んでいる範囲をこの答えに置き換える"
        let resultRow = NSStackView(views: resultButtons + [NSView(), spinner, stopButton])
        resultRow.spacing = 4

        usageLabel.font = .systemFont(ofSize: 10)
        usageLabel.textColor = .secondaryLabelColor
        let usageButton = NSButton(title: "📊 利用状況", target: self, action: #selector(showUsage(_:)))
        usageButton.bezelStyle = .inline
        usageButton.controlSize = .small
        let titleRow = NSStackView(views: [title, NSView(), close])
        let usageRow = NSStackView(views: [usageLabel, NSView(), usageButton])
        usageRow.alignment = .top
        let stack = NSStackView(views: [titleRow, providerLabel, setupRow, targetLabel, grid, promptRow, scroll, resultRow, usageRow])
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
        usageLabel.preferredMaxLayoutWidth = 200
        for v in [titleRow, providerLabel, promptRow, scroll, resultRow, usageRow] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        widthAnchor.constraint(equalToConstant: 300).isActive = true

        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),
        ])
        refreshProvider()
    }

    func refreshProvider() {
        let p = AISettings.provider
        let m = AISettings.model(p)
        providerLabel.stringValue = "\(p.label)  \(m.isEmpty ? "(モデル未設定)" : m)"
    }

    func setTarget(_ s: String) { targetLabel.stringValue = s }

    func setUsage(_ s: String) { usageLabel.stringValue = s }

    /// 設定と接続の確認が済んでいないときは、送る操作をすべて止めて設定へ案内する
    func setReady(_ on: Bool) {
        ready = on
        setupRow.isHidden = on
        guard !running else { return }
        actionButtons.forEach { $0.isEnabled = on }
        promptField.isEnabled = on
        sendButton?.isEnabled = on
        promptField.placeholderString = on ? "自由に指示 (例: 敬語にして) → return" : "未設定です (設定を開いてください)"
    }

    @objc private func openSettings(_ sender: Any?) { onOpenSettings?() }

    @objc private func showUsage(_ sender: Any?) { AIUsageWindowController.shared.show() }

    // MARK: 表示の更新

    func begin(_ heading: String) {
        running = true
        output.string = ""
        output.textColor = .labelColor
        setRunning(true)
        refreshProvider()
        targetLabel.stringValue = heading
    }

    func append(_ text: String) {
        output.textStorage?.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
        ]))
        output.scrollToEndOfDocument(nil)
    }

    func end(error: Error?) {
        running = false
        setRunning(false)
        if let e = error {
            output.textStorage?.append(NSAttributedString(string: (output.string.isEmpty ? "" : "\n\n") + "⚠️ " + e.localizedDescription, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemRed,
            ]))
        }
        let has = !result.isEmpty
        resultButtons.forEach { $0.isEnabled = has }
    }

    /// 答えの本文 (エラー表示は除く)
    var result: String {
        let s = output.string
        if let r = s.range(of: "⚠️ ") { return String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func setRunning(_ on: Bool) {
        on ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        stopButton.isHidden = !on
        actionButtons.forEach { $0.isEnabled = !on && ready }
        promptField.isEnabled = !on && ready
        sendButton?.isEnabled = !on && ready
        if on { resultButtons.forEach { $0.isEnabled = false } }
    }

    // MARK: 操作

    @objc private func actionPressed(_ sender: NSButton) {
        guard ready else { return }
        onRun?(Action.allCases[sender.tag].instruction)
    }

    @objc private func freePrompt(_ sender: Any?) {
        let t = promptField.stringValue.trimmingCharacters(in: .whitespaces)
        guard ready, !t.isEmpty, !running else { return }
        onRun?(t)
    }

    @objc private func stop(_ sender: Any?) { onCancel?() }
    @objc private func insert(_ sender: Any?) { onInsert?(result) }
    @objc private func replace(_ sender: Any?) { onReplace?(result) }
    @objc private func close(_ sender: Any?) { onClose?() }

    @objc private func copyResult(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
    }
}
