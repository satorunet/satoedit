import AppKit
import HinokiCore

extension NSAttributedString.Key {
    /// 開いてから (保存してから) 書き換えた行の目印。ファイルには保存されない
    static let editedLine = NSAttributedString.Key("SatoruEditedLine")
    /// 開いてから (保存してから) 足した文字の目印。本文の中で色を付けて見せる
    static let addedText = NSAttributedString.Key("SatoruAddedText")
}

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
    private let editedFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .heavy)
    /// まだ目印を付けていない書き換えの範囲
    private var pendingEdit: NSRange?

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
        // 書き換わった所だけ直す (巨大な文書で、1 字打つたびに全体を数え直さないため)
        if var index = cachedIndex, cachedLength == storage.length - storage.changeInLength {
            index.edit(storage.string as NSString, editedRange: storage.editedRange, delta: storage.changeInLength)
            cachedIndex = index
            cachedLength = storage.length
        } else {
            cachedIndex = nil
        }
        visualCache = nil
        // 書き換えた所を覚えておく (編集処理の途中は文字データを触れないので、目印はあとで付ける)
        let r = storage.editedRange
        pendingEdit = pendingEdit.map { NSUnionRange(Self.shift($0, by: storage), r) } ?? r
        // 編集処理の途中なので、太さの計算と再描画は少しあとで
        DispatchQueue.main.async { [weak self] in
            self?.markEditedLines()
            self?.textChanged()
        }
    }

    /// まだ目印を付けていない範囲を、今回の書き換えに合わせてずらす
    private static func shift(_ r: NSRange, by storage: NSTextStorage) -> NSRange {
        let e = storage.editedRange
        let oldEnd = NSMaxRange(e) - storage.changeInLength
        guard r.location >= oldEnd else { return r }
        return NSRange(location: max(0, r.location + storage.changeInLength), length: r.length)
    }

    /// 書き換えた行に目印を付ける (ファイルを開いた直後など、まだ編集していないときは付けない)
    private func markEditedLines() {
        guard let r = pendingEdit else { return }
        pendingEdit = nil
        guard let tv = textView, let storage = tv.textStorage, storage.length > 0,
              tv.owningEditor?.hdoc?.isDocumentEdited == true else { return }
        let ns = storage.string as NSString
        let loc = min(r.location, ns.length)
        let range = ns.lineRange(for: NSRange(location: loc, length: min(r.length, ns.length - loc)))
        guard range.length > 0 else { return }
        storage.addAttribute(.editedLine, value: true, range: range)
    }

    /// n 行目の行頭の文字に、書き換えの目印があるか
    private func isEdited(at start: Int) -> Bool {
        guard let storage = textView?.textStorage, start < storage.length else { return false }
        return storage.attribute(.editedLine, at: start, effectiveRange: nil) != nil
    }

    /// 保存したら目印を消す
    func clearEditedMarks() {
        pendingEdit = nil
        guard let tv = textView, let storage = tv.textStorage, storage.length > 0 else { return }
        storage.beginEditing()
        // 太字にしていた足した文字を、元の太さに戻す
        if let regular = tv.font {
            storage.enumerateAttribute(.addedText, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
                if v != nil { storage.addAttribute(.font, value: regular, range: r) }
            }
            tv.typingAttributes[.font] = regular
        }
        storage.removeAttribute(.editedLine, range: NSRange(location: 0, length: storage.length))
        storage.removeAttribute(.addedText, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        tv.typingAttributes[.editedLine] = nil
        tv.typingAttributes[.addedText] = nil
        tv.needsDisplay = true
        needsDisplay = true
    }

    @objc func textChanged() {
        // 行の一覧は storageEdited が直している。長さが合わないときだけ作り直す
        if cachedLength != ((textView?.string as NSString?)?.length ?? -1) { cachedIndex = nil }
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

            // 描き直す範囲 (rect) にかからない行は描かない
            let top = yOffset + fragment.minY
            if top <= rect.maxY && top + max(fragment.height, 1) >= rect.minY {
                drawLabel(line + 1, current: line == currentLine, edited: isEdited(at: start), fragment: fragment, yOffset: yOffset)
            }
            line += 1
        }
    }

    /// 番号の字の形 (番号・太さ・色ごとに覚えておく。打つたびに全部の番号を組み直すと重い)
    private var labelCache: [String: (line: CTLine, width: CGFloat, ascent: CGFloat, height: CGFloat)] = [:]

    private func drawLabel(_ number: Int, current: Bool, edited: Bool = false, fragment: NSRect, yOffset: CGFloat) {
        let color = current ? Theme.gutterCurrentText : Theme.gutterText
        let key = "\(number) \(edited) \(ObjectIdentifier(color).hashValue)"
        let label: (line: CTLine, width: CGFloat, ascent: CGFloat, height: CGFloat)
        if let c = labelCache[key] {
            label = c
        } else {
            let attrs: [NSAttributedString.Key: Any] = [.font: edited ? editedFont : font, .foregroundColor: color]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "\(number)", attributes: attrs))
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            label = (line, width, ascent, ceil(ascent + descent + leading))
            if labelCache.count > 4000 { labelCache.removeAll() }
            labelCache[key] = label
        }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let lineHeight = fragment.height > 0 ? fragment.height : label.height
        let y = yOffset + fragment.minY + (lineHeight - label.height) / 2
        ctx.saveGState()
        // このビューは上下を返しているので、字も返して描く
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: ruleThickness - label.width - 8, y: y + label.ascent)
        CTLineDraw(label.line, ctx)
        ctx.restoreGState()
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
            self.drawLabel(n + 1, current: n == current, edited: self.isEdited(at: charStart), fragment: rect, yOffset: yOffset)
        }
        // 末尾の空行
        let extra = lm.extraLineFragmentRect
        if !extra.isEmpty, extra.intersects(visible) {
            let n = starts.count - 1
            drawLabel(n + 1, current: n == current, fragment: extra, yOffset: yOffset)
        }
    }
}
