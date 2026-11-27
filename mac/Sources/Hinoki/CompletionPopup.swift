import AppKit
import HinokiCore

/// 入力補完の候補リストと、関数の引数ヒント (VSCode の IntelliSense のようなもの)。
/// EditorTextView が 1 つずつ持つ
final class CompletionController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var textView: EditorTextView?
    /// 言語の名前 (LanguageProfile.name)。nil はただのテキスト
    var language: String?
    var keywords: [String] = []
    var types: [String] = []

    private var items: [Completion.Item] = []
    /// 書きかけの単語の範囲 (選んだらここを置き換える)
    private var replaceRange = NSRange(location: 0, length: 0)
    private var panel: CompletionPanel?
    private var table: NSTableView!
    private var hint: HintPanel?

    // 文書の単語・関数は文字が変わったときだけ数え直す
    private var symbolsVersion = -1
    private var cachedWords: [String] = []
    private var cachedFunctions: [Completion.Item] = []
    var textVersion = 0
    private var symbolsTime = Date.distantPast
    /// 候補を入れている最中
    private(set) var accepting = false

    init(textView: EditorTextView) {
        self.textView = textView
        super.init()
    }

    var isShowing: Bool { panel?.isVisible == true }

    static var enabled: Bool { Prefs.bool("codeCompletion") }

    // MARK: 候補を出す・絞る

    /// 文字を打ったあと。manual は ⌃Space / Esc で呼んだとき
    func update(manual: Bool = false) {
        guard let tv = textView, tv.paperMode == .normal, tv.window != nil else { return hide() }
        if !manual && !isShowing {
            // ただのテキストでは自分から出さない
            guard Self.enabled, language != nil else { return hideList() }
        }
        let sel = tv.selectedRange()
        guard sel.length == 0, !tv.hasMarkedText() else { return hideList() }
        let text = tv.string as NSString
        let css = language == "CSS"
        let range = Completion.prefixRange(in: text, caret: sel.location, allowDash: css)
        let typed = text.substring(with: range)
        let minimum = language == "HTML / XML" && Completion.isTagNameContext(text, prefixStart: range.location) ? 1 : 2
        if !manual && !isShowing && typed.count < minimum { return hideList() }
        if !manual && typed.isEmpty { return hideList() }

        let list = Completion.filter(candidates(text: text, prefixStart: range.location, typed: typed), typed: typed)
        // 打ち終わった単語しか候補がないときは出さない
        if list.isEmpty || (!manual && list.count == 1 && list[0].label == typed && list[0].kind != .function) {
            return hideList()
        }
        items = list
        replaceRange = range
        show(at: range)
    }

    private func candidates(text: NSString, prefixStart: Int, typed: String) -> [Completion.Item] {
        refreshSymbols()
        var out: [Completion.Item] = []
        let lib = CompletionLibrary.items(for: language)
        // "JSON.st" のように . のあとなら、"JSON." で始まる候補をその先だけにして出す
        var qualifier: String?
        if prefixStart > 0, text.character(at: prefixStart - 1) == 0x2E {
            let q = Completion.prefixRange(in: text, caret: prefixStart - 1)
            if q.length > 0 { qualifier = text.substring(with: q) }
        }
        if let q = qualifier {
            for it in lib where it.label.hasPrefix(q + ".") {
                var c = it
                c.label = String(it.label.dropFirst(q.count + 1))
                out.append(c)
            }
        }
        if language == "HTML / XML" {
            let tagContext = Completion.isTagNameContext(text, prefixStart: prefixStart)
            out += lib.filter { tagContext ? $0.kind == .tag : $0.kind != .tag }
            if tagContext { return out }
        } else {
            out += lib.filter { qualifier == nil || !$0.label.contains(".") }
        }
        out += cachedFunctions
        // 拡張機能 (JS) からの候補
        if let tv = textView {
            let sel = tv.selectedRange().location
            let lineRange = text.lineRange(for: NSRange(location: min(sel, text.length), length: 0))
            let line = text.substring(with: NSRange(location: lineRange.location, length: max(0, sel - lineRange.location)))
            out += PluginManager.shared.completions(word: typed, language: language, line: line,
                                                    editor: tv.owningEditor)
        }
        out += keywords.map { Completion.Item(label: $0, kind: .keyword) }
        out += types.map { Completion.Item(label: $0, kind: .type) }
        out += cachedWords.map { Completion.Item(label: $0, kind: .word) }
        return out
    }

    private func refreshSymbols() {
        guard symbolsVersion != textVersion, let tv = textView else { return }
        // 打つたびに数え直すと大きなファイルで重いので、少し古くても使う
        if symbolsVersion >= 0, Date().timeIntervalSince(symbolsTime) < 1.5 { return }
        symbolsVersion = textVersion
        symbolsTime = Date()
        // 大きな文書では、カーソルの前後だけから集める (全体をなめると打つたびに引っかかる)
        let all = tv.string as NSString
        let around = 100_000
        var s = tv.string
        if all.length > around * 2 {
            let caret = min(tv.selectedRange().location, all.length)
            let from = max(0, caret - around), to = min(all.length, caret + around)
            s = all.substring(with: all.rangeOfComposedCharacterSequences(for: NSRange(location: from, length: to - from)))
        }
        // Swift の文字列にしてから数える (NSString のままだと 1 字ずつたどるのが遅い)
        s.makeContiguousUTF8()
        cachedFunctions = language == nil ? [] : Completion.definedFunctions(in: s)
        cachedWords = Completion.words(in: s)
    }

    // MARK: 選ぶ

    /// 候補が出ているときのキー。処理したら true
    func handle(_ selector: Selector) -> Bool {
        guard isShowing else {
            if selector == #selector(NSResponder.cancelOperation(_:)), hint?.isVisible == true {
                hideHint()
                return true
            }
            return false
        }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): move(8)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): move(-8)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            let row = table.selectedRow
            guard row >= 0, row < items.count else { hideList(); return false }
            // 打ったとおりの単語を選んでいて Enter なら、普通に改行する
            let typed = (textView?.string as NSString?)?.substring(with: replaceRange) ?? ""
            if selector == #selector(NSResponder.insertNewline(_:)), items[row].label == typed, items[row].kind != .function {
                hideList()
                return false
            }
            accept(row)
        case #selector(NSResponder.cancelOperation(_:)): hideList()
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)),
             #selector(NSResponder.moveToBeginningOfLine(_:)), #selector(NSResponder.moveToEndOfLine(_:)):
            hideList()
            return false
        default: return false
        }
        return true
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        var row = table.selectedRow + delta
        if delta == 1 || delta == -1 {
            row = (row + items.count) % items.count // 端で反対側へ
        } else {
            row = max(0, min(items.count - 1, row))
        }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func tableDoubleClicked(_ sender: Any?) {
        if table.clickedRow >= 0 { accept(table.clickedRow) }
    }

    private func accept(_ row: Int) {
        guard let tv = textView, row < items.count else { return }
        let item = items[row]
        let text = tv.string as NSString
        let end = NSMaxRange(replaceRange)
        let next: unichar? = end < text.length ? text.character(at: end) : nil
        let ins = Completion.insertion(for: item, next: next, language: language)
        hideList()
        accepting = true
        tv.insertText(ins.text, replacementRange: replaceRange)
        accepting = false
        let caret = replaceRange.location + ins.caret
        tv.setSelectedRange(NSRange(location: caret, length: 0))
        updateHint()
    }

    // MARK: 表示

    private func makePanel() {
        let p = CompletionPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.hasShadow = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .popUpMenu
        let box = NSVisualEffectView()
        box.material = .menu
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        box.layer?.masksToBounds = true
        box.layer?.borderWidth = 0.5
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        let t = NSTableView()
        t.headerView = nil
        t.rowHeight = 20
        t.intercellSpacing = NSSize(width: 0, height: 0)
        t.backgroundColor = .clear
        t.style = .plain
        t.selectionHighlightStyle = .regular
        t.allowsEmptySelection = false
        let col = NSTableColumn(identifier: .init("c"))
        col.resizingMask = .autoresizingMask
        t.addTableColumn(col)
        t.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        t.dataSource = self
        t.delegate = self
        t.target = self
        t.doubleAction = #selector(tableDoubleClicked(_:))
        table = t
        let scroll = NSScrollView()
        scroll.documentView = t
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: box.topAnchor, constant: 3),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -3),
        ])
        p.contentView = box
        panel = p
    }

    private func show(at range: NSRange) {
        guard let tv = textView, let window = tv.window else { return }
        if panel == nil { makePanel() }
        guard let p = panel else { return }
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)
        table.scrollRowToVisible(0)
        let caret = tv.firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil)
        let rows = min(items.count, 10)
        let width = min(520, max(260, CGFloat(longest()) * 7.5 + 70))
        let height = CGFloat(rows) * table.rowHeight + 6
        var frame = NSRect(x: caret.minX - 26, y: caret.minY - height - 2, width: width, height: height)
        if let screen = window.screen?.visibleFrame {
            if frame.minY < screen.minY { frame.origin.y = caret.maxY + 2 } // 下に入らないときは上へ
            frame.origin.x = min(max(screen.minX, frame.minX), screen.maxX - width)
        }
        p.setFrame(frame, display: true)
        if p.parent == nil { window.addChildWindow(p, ordered: .above) }
        p.orderFront(nil)
        hideHint()
    }

    private func longest() -> Int {
        items.prefix(50).map { $0.label.count + $0.detail.count }.max() ?? 20
    }

    /// 候補のリストだけ消す
    func hideList() {
        guard let p = panel, p.isVisible else { return }
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
    }

    func hide() {
        hideList()
        hideHint()
    }

    // MARK: 表のセル

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? CompletionCell) ?? CompletionCell()
        cell.identifier = id
        let it = items[row]
        let typed = (textView?.string as NSString?)?.substring(with: replaceRange) ?? ""
        cell.set(item: it, typed: typed, font: textView?.font)
        return cell
    }

    // MARK: 引数ヒント

    /// カーソルが関数のかっこの中なら、引数の一覧を出す (いまの引数を太字)
    func updateHint() {
        guard Self.enabled, let tv = textView, tv.paperMode == .normal, language != nil, tv.window != nil,
              tv.selectedRange().length == 0 else { return hideHint() }
        let text = tv.string as NSString
        guard let ctx = Completion.callContext(in: text, caret: tv.selectedRange().location) else { return hideHint() }
        refreshSymbols()
        let all = cachedFunctions + CompletionLibrary.items(for: language)
        // "obj.method(" は method でも探す。"JSON.parse(" は JSON.parse で探す
        var qualified = ctx.name
        let nameStart = ctx.openParen - (ctx.name as NSString).length
        if nameStart > 1, text.character(at: nameStart - 1) == 0x2E {
            let q = Completion.prefixRange(in: text, caret: nameStart - 1)
            if q.length > 0 { qualified = text.substring(with: q) + "." + ctx.name }
        }
        guard let fn = all.first(where: { $0.kind == .function && $0.label == qualified })
                ?? all.first(where: { $0.kind == .function && $0.label == ctx.name }),
              !fn.params.isEmpty else { return hideHint() }
        if hint == nil { hint = HintPanel() }
        guard let h = hint, let window = tv.window else { return }
        h.set(name: fn.label, params: fn.params, current: ctx.argIndex, font: tv.font)
        let r = tv.firstRect(forCharacterRange: NSRange(location: nameStart, length: 0), actualRange: nil)
        var origin = NSPoint(x: r.minX - 6, y: r.maxY + 2)
        if let screen = window.screen?.visibleFrame, origin.y + h.frame.height > screen.maxY {
            origin.y = r.minY - h.frame.height - 2
        }
        h.setFrameOrigin(origin)
        if h.parent == nil { window.addChildWindow(h, ordered: .above) }
        h.orderFront(nil)
    }

    func hideHint() {
        guard let h = hint, h.isVisible else { return }
        h.parent?.removeChildWindow(h)
        h.orderOut(nil)
    }
}

/// キー入力を奪わない浮き窓
final class CompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 候補 1 行: [種類] 名前 (打った部分を太字)  …… 引数など
final class CompletionCell: NSTableCellView {
    private let badge = NSTextField(labelWithString: "")
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        badge.alignment = .center
        badge.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 3
        label.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingTail
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        for v in [badge, label, detail] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 10),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var item: Completion.Item?
    private var typed = ""
    private var fontSize: CGFloat = 12

    func set(item: Completion.Item, typed: String, font: NSFont?) {
        self.item = item
        self.typed = typed
        fontSize = min(13, max(11, (font?.pointSize ?? 12) - 1))
        render()
    }

    /// 選ばれた行 (色の付いた背景) では文字を白にする
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { render() }
    }

    private func render() {
        guard let item = item else { return }
        let selected = backgroundStyle == .emphasized
        let size = fontSize
        let main: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
        let base = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let s = NSMutableAttributedString(string: item.label, attributes: [.font: base, .foregroundColor: main])
        if !typed.isEmpty, item.label.lowercased().hasPrefix(typed.lowercased()) {
            // 打った部分: 太字。選ばれていない行では強調色
            s.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: size, weight: .heavy),
                             .foregroundColor: selected ? NSColor.alternateSelectedControlTextColor : NSColor.controlAccentColor],
                            range: NSRange(location: 0, length: min((typed as NSString).length, (item.label as NSString).length)))
        }
        label.attributedStringValue = s
        detail.font = .monospacedSystemFont(ofSize: size - 1, weight: .regular)
        detail.stringValue = item.detail
        detail.textColor = selected ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        badge.stringValue = item.kind.badge
        let color: NSColor
        switch item.kind {
        case .function: color = .systemPurple
        case .keyword: color = .systemBlue
        case .type: color = .systemTeal
        case .property: color = .systemOrange
        case .tag: color = .systemRed
        case .snippet: color = .systemGreen
        case .word: color = .systemGray
        }
        badge.textColor = selected ? .white : color
        badge.layer?.backgroundColor = (selected ? NSColor.white.withAlphaComponent(0.25) : color.withAlphaComponent(0.15)).cgColor
    }
}

/// 引数ヒントの小さな浮き窓: name(a, **b**, c)
final class HintPanel: NSPanel {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 22),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        level = .popUpMenu
        let box = NSVisualEffectView()
        box.material = .toolTip
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 5
        box.layer?.masksToBounds = true
        box.layer?.borderWidth = 0.5
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        contentView = box
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func set(name: String, params: [String], current: Int, font: NSFont?) {
        let size = min(13, max(11, (font?.pointSize ?? 12) - 1))
        let regular: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
                                                      .foregroundColor: NSColor.secondaryLabelColor]
        let s = NSMutableAttributedString(string: name + "(", attributes: regular)
        // ...rest のような最後の可変長引数は、それ以降ずっと太字にする
        let active = params.last?.hasPrefix("...") == true || params.last?.hasPrefix("*") == true
            ? min(current, params.count - 1) : current
        for (i, p) in params.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: ", ", attributes: regular)) }
            var a = regular
            if i == active {
                a[.font] = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
                a[.foregroundColor] = NSColor.labelColor
                a[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            s.append(NSAttributedString(string: p, attributes: a))
        }
        s.append(NSAttributedString(string: ")", attributes: regular))
        label.attributedStringValue = s
        let w = ceil(s.size().width) + 18
        setContentSize(NSSize(width: w, height: ceil(s.size().height) + 8))
    }
}
