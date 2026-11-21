import AppKit
import HinokiCore

/// テキストビュー左側の行番号。
/// 数え方は 2 通り: エディタ的 (改行ごとに 1 行) / ワープロ的 (折り返した行も 1 行)。
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var cachedIndex: LineIndex?
    private var cachedLength = -1
    /// true ならワープロ的 (折り返しも 1 行) に数える
    var countsVisualLines = false {
        didSet { if oldValue != countsVisualLines { textChanged() } }
    }
    /// 巨大なファイルでは折り返しの数え上げが重いのでエディタ的に戻す
    private var useVisual: Bool {
        countsVisualLines && ((textView?.string as NSString?)?.length ?? 0) <= 2_000_000
    }
    private var visualCache: (starts: [Int], key: String)?
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    override var isFlipped: Bool { true }

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: textView)
        // 日本語入力の変換中 (未確定文字) は didChange が来ないことがあるので、文字の保存側の変化も見る
        if let storage = textView.textStorage {
            nc.addObserver(self, selector: #selector(storageEdited(_:)), name: NSTextStorage.didProcessEditingNotification, object: storage)
        }
        nc.addObserver(self, selector: #selector(redraw), name: NSTextView.didChangeSelectionNotification, object: textView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        nc.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        textView.postsFrameChangedNotifications = true
        nc.addObserver(self, selector: #selector(redraw), name: NSView.frameDidChangeNotification, object: textView)
    }

    required init(coder: NSCoder) { fatalError() }

    var lineIndex: LineIndex {
        let ns = (textView?.string ?? "") as NSString
        if let c = cachedIndex, cachedLength == ns.length { return c }
        let li = LineIndex(ns)
        cachedIndex = li
        cachedLength = ns.length
        return li
    }

    @objc private func storageEdited(_ note: Notification) {
        guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
        cachedIndex = nil
        visualCache = nil
        // 編集処理の途中なので、太さの計算と再描画は少しあとで
        DispatchQueue.main.async { [weak self] in self?.textChanged() }
    }

    @objc func textChanged() {
        cachedIndex = nil
        visualCache = nil
        updateThickness()
        needsDisplay = true
    }

    @objc private func redraw() { needsDisplay = true }

    // MARK: 行の数え方

    /// 折り返しを数えるときの各行の先頭位置 (文字位置)
    private var visualStarts: [Int] {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return [0] }
        let ns = tv.string as NSString
        let key = "\(ns.length)/\(tc.containerSize.width)/\(tv.font?.fontName ?? "")/\(tv.font?.pointSize ?? 0)"
        if let c = visualCache, c.key == key { return c.starts }
        lm.ensureLayout(for: tc)
        var starts: [Int] = []
        let glyphCount = lm.numberOfGlyphs
        var g = 0
        while g < glyphCount {
            var r = NSRange(location: 0, length: 0)
            lm.lineFragmentRect(forGlyphAt: g, effectiveRange: &r)
            starts.append(lm.characterIndexForGlyph(at: r.location))
            g = max(NSMaxRange(r), g + 1)
        }
        if ns.length == 0 || ns.character(at: ns.length - 1) == 0x0A { starts.append(ns.length) }
        visualCache = (starts, key)
        return starts
    }

    private func lastIndex(in starts: [Int], notAfter loc: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= loc { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// 今の数え方での行数
    var lineCount: Int {
        useVisual ? visualStarts.count : lineIndex.lineCount
    }

    /// loc を含む行 (0 始まり) とその行頭
    func line(at loc: Int) -> (line: Int, start: Int) {
        if useVisual {
            let starts = visualStarts
            let i = lastIndex(in: starts, notAfter: loc)
            return (i, starts[i])
        }
        let li = lineIndex
        let n = li.lineNumber(at: loc)
        return (n, li.startOfLine(n))
    }

    /// n 行目 (0 始まり) の行頭
    func startOfLine(_ n: Int) -> Int {
        if useVisual {
            let starts = visualStarts
            return starts[max(0, min(n, starts.count - 1))]
        }
        let li = lineIndex
        return li.startOfLine(max(0, min(n, li.lineCount - 1)))
    }

    private func updateThickness() {
        let digits = max(3, String(lineCount).count)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        let t = ceil(digitWidth * CGFloat(digits) + 16)
        if t != ruleThickness { ruleThickness = t }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        Theme.gutterBackground.setFill()
        rect.fill()
        Theme.gutterSeparator.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let length = (tv.string as NSString).length
        let origin = tv.textContainerOrigin
        if useVisual {
            drawVisualNumbers(tv: tv, lm: lm, tc: tc, length: length, origin: origin)
            return
        }
        let li = lineIndex

        let visible = tv.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
        let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let yOffset = convert(NSPoint(x: 0, y: origin.y), from: tv).y
        let currentLine = li.lineNumber(at: tv.selectedRange().location)

        var line = li.lineNumber(at: charRange.location)
        while line < li.lineCount {
            let start = li.startOfLine(line)
            if start > NSMaxRange(charRange) { break }

            let fragment: NSRect
            if start >= length {
                // 最終行が空 (末尾が改行) のとき
                fragment = lm.extraLineFragmentRect
                if fragment.isEmpty && length > 0 { break }
            } else {
                fragment = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: start), effectiveRange: nil)
            }

            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: line == currentLine ? Theme.gutterCurrentText : Theme.gutterText,
            ]
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attrs)
            let lineHeight = fragment.height > 0 ? fragment.height : size.height
            let y = yOffset + fragment.minY + (lineHeight - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attrs)
            line += 1
        }
    }

    private func drawLabel(_ number: Int, current: Bool, fragment: NSRect, yOffset: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: current ? Theme.gutterCurrentText : Theme.gutterText,
        ]
        let label = "\(number)" as NSString
        let size = label.size(withAttributes: attrs)
        let lineHeight = fragment.height > 0 ? fragment.height : size.height
        let y = yOffset + fragment.minY + (lineHeight - size.height) / 2
        label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attrs)
    }

    /// ワープロ的: 見えている行 (折り返し含む) すべてに番号を付ける
    private func drawVisualNumbers(tv: NSTextView, lm: NSLayoutManager, tc: NSTextContainer, length: Int, origin: NSPoint) {
        let starts = visualStarts
        let yOffset = convert(NSPoint(x: 0, y: origin.y), from: tv).y
        let current = line(at: tv.selectedRange().location).line
        let visible = tv.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
        lm.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, range, _ in
            let charStart = lm.characterIndexForGlyph(at: range.location)
            let n = self.lastIndex(in: starts, notAfter: charStart)
            self.drawLabel(n + 1, current: n == current, fragment: rect, yOffset: yOffset)
        }
        // 末尾の空行
        let extra = lm.extraLineFragmentRect
        if !extra.isEmpty, extra.intersects(visible) {
            let n = starts.count - 1
            drawLabel(n + 1, current: n == current, fragment: extra, yOffset: yOffset)
        }
    }
}
