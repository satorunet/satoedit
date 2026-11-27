import AppKit
import HinokiCore

/// 検索・置換ウインドウ。検索の条件はここで決め、⌘G / ⇧⌘G もこの条件で探す。
/// 置換文字列では (正規表現のとき) \1 \n \t も使える。
final class FindPanelController: NSWindowController, NSWindowDelegate {
    static let shared = FindPanelController()

    private let findField = NSComboBox()
    private let replaceField = NSComboBox()
    private let caseCheck = NSButton(checkboxWithTitle: L("大文字と小文字を区別する"), target: nil, action: nil)
    private let wordCheck = NSButton(checkboxWithTitle: L("単語単位で探す"), target: nil, action: nil)
    private let regexCheck = NSButton(checkboxWithTitle: L("正規表現"), target: nil, action: nil)
    private let wrapCheck = NSButton(checkboxWithTitle: L("一周する (端まで行ったら反対の端から)"), target: nil, action: nil)
    private let selectionCheck = NSButton(checkboxWithTitle: L("選択範囲の中だけ置換する"), target: nil, action: nil)
    private let highlightCheck = NSButton(checkboxWithTitle: L("見つかった所をすべて強調する"), target: nil, action: nil)
    private let messageLabel = NSTextField(labelWithString: "")

    /// 条件の保存先 (チェックボックス → 設定の名前)
    private var options: [(NSButton, String)] {
        [(caseCheck, "findCase"), (wordCheck, "findWord"), (regexCheck, "findRegex"),
         (wrapCheck, "findWrap"), (highlightCheck, "findHighlight")]
    }

    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 250),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: true)
        panel.title = L("検索・置換")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        super.init(window: panel)
        panel.delegate = self
        UserDefaults.standard.register(defaults: ["findWrap": true])
        buildUI(in: panel)
        for (b, key) in options { b.state = UserDefaults.standard.bool(forKey: key) ? .on : .off }
        findField.addItems(withObjectValues: UserDefaults.standard.stringArray(forKey: "findHistory") ?? [])
        replaceField.addItems(withObjectValues: UserDefaults.standard.stringArray(forKey: "replaceHistory") ?? [])
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI(in panel: NSPanel) {
        findField.placeholderString = L("検索する文字列")
        replaceField.placeholderString = L("置換後の文字列 (正規表現では \\1 で後方参照)")
        for f in [findField, replaceField] {
            f.completes = false
            f.numberOfVisibleItems = 12
        }
        findField.target = self
        findField.action = #selector(findNext)
        for (b, _) in options {
            b.target = self
            b.action = #selector(optionChanged(_:))
        }

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: L("検索:")), findField],
            [NSTextField(labelWithString: L("置換:")), replaceField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 430).isActive = true

        // 条件 (2 列)
        let left = NSStackView(views: [caseCheck, wordCheck, regexCheck])
        let right = NSStackView(views: [wrapCheck, highlightCheck, selectionCheck])
        for s in [left, right] {
            s.orientation = .vertical
            s.alignment = .leading
            s.spacing = 6
        }
        let conditions = NSStackView(views: [left, right])
        conditions.alignment = .top
        conditions.spacing = 24
        let conditionBox = SettingsUI.box(L("検索の条件"), conditions, fillWidth: true)

        let next = NSButton(title: L("下検索"), target: self, action: #selector(findNext))
        next.keyEquivalent = "\r"
        let close = NSButton(title: L("閉じる"), target: self, action: #selector(closePanel(_:)))
        close.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [
            NSButton(title: L("上検索"), target: self, action: #selector(findPrevious)),
            next,
            NSButton(title: L("置換"), target: self, action: #selector(replaceOne)),
            NSButton(title: L("すべて置換"), target: self, action: #selector(replaceAll)),
            NSButton(title: L("数える"), target: self, action: #selector(countMatches)),
            NSView(),
            close,
        ])
        for case let b as NSButton in buttons.views { b.bezelStyle = .rounded }
        messageLabel.textColor = .secondaryLabelColor

        let root = NSStackView(views: [grid, conditionBox, buttons, messageLabel])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        let content = panel.contentView!
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            conditionBox.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
        ])
    }

    // MARK: 公開

    /// ウインドウを出す (選んでいる文字があれば検索語に入れる)
    func show(focusReplace: Bool = false) {
        if let tv = target {
            let sel = tv.selectedRange()
            let text = (tv.string as NSString).substring(with: sel)
            if sel.length > 0 && !text.contains("\n") {
                findField.stringValue = text
                selectionCheck.state = .off
            } else {
                selectionCheck.state = sel.length > 0 ? .on : .off
            }
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(focusReplace ? replaceField : findField)
    }

    /// ⌘E: 選んでいる文字を検索語にする
    func useSelection() {
        guard let tv = target else { return }
        let sel = tv.selectedRange()
        guard sel.length > 0 else { NSSound.beep(); return }
        findField.stringValue = (tv.string as NSString).substring(with: sel)
        if regexCheck.state == .on { findField.stringValue = NSRegularExpression.escapedPattern(for: findField.stringValue) }
    }

    @objc func findNext() { find(forward: true) }
    @objc func findPrevious() { find(forward: false) }

    @objc private func closePanel(_ sender: Any?) { window?.close() }

    @objc private func optionChanged(_ sender: NSButton) {
        guard let key = options.first(where: { $0.0 === sender })?.1 else { return }
        UserDefaults.standard.set(sender.state == .on, forKey: key)
        if sender === highlightCheck { updateHighlights() }
    }

    func windowWillClose(_ notification: Notification) {
        clearHighlights()
    }

    // MARK: 本体

    private var target: EditorTextView? {
        let editors = NSApp.orderedWindows.compactMap { $0.frontEditor }
        return (NSApp.mainWindow?.frontEditor ?? editors.first)?.textView
    }

    private func message(_ s: String) { messageLabel.stringValue = s }

    private func remember(_ box: NSComboBox, key: String) {
        let v = box.stringValue
        guard !v.isEmpty else { return }
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == v }
        list.insert(v, at: 0)
        list = Array(list.prefix(20))
        UserDefaults.standard.set(list, forKey: key)
        box.removeAllItems()
        box.addItems(withObjectValues: list)
    }

    private func makeRegex() -> NSRegularExpression? {
        let pattern = findField.stringValue
        guard !pattern.isEmpty else { show(); return nil }
        remember(findField, key: "findHistory")
        var opts: NSRegularExpression.Options = [.anchorsMatchLines]
        if caseCheck.state == .off { opts.insert(.caseInsensitive) }
        var source = regexCheck.state == .on ? pattern : NSRegularExpression.escapedPattern(for: pattern)
        if wordCheck.state == .on {
            // 前後が文字・数字・_ でないところだけ
            source = "(?<![\\p{L}\\p{N}_])(?:" + source + ")(?![\\p{L}\\p{N}_])"
        }
        do {
            return try NSRegularExpression(pattern: source, options: opts)
        } catch {
            NSSound.beep()
            message(L("正規表現が正しくありません"))
            return nil
        }
    }

    /// 秀丸流の置換文字列 (\1, \n, \t, \\) を NSRegularExpression のテンプレートに変換
    private var template: String {
        let raw = replaceField.stringValue
        guard regexCheck.state == .on else { return NSRegularExpression.escapedTemplate(for: raw) }
        var out = ""
        var it = raw.makeIterator()
        while let c = it.next() {
            guard c == "\\", let n = it.next() else { out.append(c); continue }
            switch n {
            case "0"..."9": out += "$\(n)"
            case "n": out += "\n"
            case "t": out += "\t"
            case "\\": out += "\\\\"
            case "$": out += "\\$"
            default: out += "\\\(n)"
            }
        }
        return out
    }

    @discardableResult
    private func find(forward: Bool) -> Bool {
        guard let tv = target else { NSSound.beep(); return false }
        guard let regex = makeRegex() else { return false }
        let text = tv.string
        let length = (text as NSString).length
        let sel = tv.selectedRange()
        let wraps = wrapCheck.state == .on

        func first(from start: Int) -> NSRange? {
            guard start <= length else { return nil }
            var r = regex.firstMatch(in: text, options: [.withTransparentBounds],
                                     range: NSRange(location: start, length: length - start))?.range
            // 空マッチで止まらないように
            if let m = r, m.length == 0, m == sel, start < length {
                r = regex.firstMatch(in: text, options: [.withTransparentBounds],
                                     range: NSRange(location: start + 1, length: length - start - 1))?.range
            }
            return r
        }
        func last(before end: Int) -> NSRange? {
            regex.matches(in: text, options: [.withTransparentBounds], range: NSRange(location: 0, length: end))
                .map(\.range).last { $0 != sel }
        }

        var match: NSRange?
        var wrapped = false
        if forward {
            match = first(from: NSMaxRange(sel))
            if match == nil, wraps, let m = first(from: 0) { match = m; wrapped = true }
        } else {
            match = last(before: sel.location)
            if match == nil, wraps, let m = last(before: length) { match = m; wrapped = true }
        }
        updateHighlights()
        guard let r = match else {
            NSSound.beep()
            message(wraps ? L("見つかりません") : (forward ? L("ここから下には見つかりません") : L("ここから上には見つかりません")))
            return false
        }
        tv.setSelectedRange(r)
        tv.scrollRangeToVisible(r)
        tv.showFindIndicator(for: r)
        message(wrapped ? (forward ? L("末尾まで検索したので先頭から検索しました") : L("先頭まで検索したので末尾から検索しました")) : "")
        return true
    }

    @objc private func replaceOne() {
        guard let tv = target, let regex = makeRegex() else { return }
        remember(replaceField, key: "replaceHistory")
        let sel = tv.selectedRange()
        if let m = regex.firstMatch(in: tv.string, options: [.anchored, .withTransparentBounds], range: sel), m.range == sel {
            let replacement = regex.replacementString(for: m, in: tv.string, offset: 0, template: template)
            tv.replace(sel, with: replacement, select: NSRange(location: sel.location + (replacement as NSString).length, length: 0))
        }
        find(forward: true)
    }

    @objc private func replaceAll() {
        guard let tv = target, let regex = makeRegex() else { return }
        remember(replaceField, key: "replaceHistory")
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        let range = selectionCheck.state == .on && sel.length > 0 ? sel : NSRange(location: 0, length: ns.length)
        let sub = ns.substring(with: range)
        let subRange = NSRange(location: 0, length: (sub as NSString).length)
        let count = regex.numberOfMatches(in: sub, options: [], range: subRange)
        guard count > 0 else {
            NSSound.beep()
            message(L("見つかりません"))
            return
        }
        let result = regex.stringByReplacingMatches(in: sub, options: [], range: subRange, withTemplate: template)
        let newSel = selectionCheck.state == .on
            ? NSRange(location: range.location, length: (result as NSString).length)
            : NSRange(location: min(sel.location, ns.length - range.length + (result as NSString).length), length: 0)
        tv.replace(range, with: result, select: newSel)
        message(L("{0} 個置換しました", count))
        updateHighlights()
    }

    @objc private func countMatches() {
        guard let tv = target, let regex = makeRegex() else { return }
        let n = regex.numberOfMatches(in: tv.string, options: [], range: NSRange(location: 0, length: (tv.string as NSString).length))
        message(L("{0} 個見つかりました", n))
        updateHighlights()
    }

    // MARK: すべて強調

    private weak var highlighted: NSTextView?
    private static let highlightColor = NSColor.systemYellow.withAlphaComponent(0.35)

    private func clearHighlights() {
        guard let tv = highlighted, let storage = tv.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.layoutManagers.forEach { $0.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full) }
        highlighted = nil
    }

    private func updateHighlights() {
        clearHighlights()
        guard highlightCheck.state == .on, let tv = target, let storage = tv.textStorage,
              !findField.stringValue.isEmpty, storage.length <= 2_000_000 else { return }
        var opts: NSRegularExpression.Options = [.anchorsMatchLines]
        if caseCheck.state == .off { opts.insert(.caseInsensitive) }
        var source = regexCheck.state == .on ? findField.stringValue : NSRegularExpression.escapedPattern(for: findField.stringValue)
        if wordCheck.state == .on { source = "(?<![\\p{L}\\p{N}_])(?:" + source + ")(?![\\p{L}\\p{N}_])" }
        guard let regex = try? NSRegularExpression(pattern: source, options: opts) else { return }
        let matches = regex.matches(in: tv.string, options: [], range: NSRange(location: 0, length: storage.length))
        guard matches.count <= 5000 else { return }
        for lm in storage.layoutManagers {
            for m in matches where m.range.length > 0 {
                lm.addTemporaryAttribute(.backgroundColor, value: Self.highlightColor, forCharacterRange: m.range)
            }
        }
        highlighted = tv
    }
}
