import AppKit
import HinokiCore

extension NSAttributedString.Key {
    /// A4 用紙モードで手で決めた段落の寄せ ("left" / "center" / "right")
    static let paperAlign = NSAttributedString.Key("SatoruPaperAlign")
}

/// エディタ本体。カーソル行のハイライト、[EOF]、自動インデント、行操作など。
final class EditorTextView: NSTextView, NSLayoutManagerDelegate {
    var currentLineColor: NSColor = Theme.currentLine
    /// カーソル行の文字の色 (nil なら変えない)
    var currentLineTextColor: NSColor? { didSet { updateCurrentTextLine(force: true) } }
    /// いま色を変えている行の範囲 (改行は含めない)
    private var currentTextLine: NSRange?
    /// nil ならタブ文字、数値ならその幅までスペースを入れる
    var softTabWidth: Int?
    /// 1 タブ分のインデントに使う幅 (softTabWidth が nil のときはタブ文字 1 つ)
    var indentWidth = 4
    /// 行コメントの記号 (⌘/ で使う)
    var lineCommentPrefix: String?
    var showsEOF = true { didSet { needsDisplay = true } }
    var highlightsCurrentLine = true { didSet { needsDisplay = true; updateCurrentTextLine(force: true) } }

    // MARK: 用紙モード

    enum PaperMode: Int { case normal, genko, a4 }
    var paperMode: PaperMode = .normal {
        didSet { needsDisplay = true; updateCurrentTextLine(force: true) }
    }
    /// このタブの原稿用紙が横書きか (タブごと。新しいタブは最後に使った向きで始める)
    var genkoHorizontal = UserDefaults.standard.bool(forKey: "genkoHorizontal")
    /// このタブで作文の自動整形を使うか (横書きでは使わない)
    var genkoAutoFormat: Bool { GenkoRenderer.autoFormat(horizontal: genkoHorizontal) }
    /// PDF に書き出している間は、カーソル・選択・相手のカーソルを描かない
    var isExportingPDF = false

    // 画像や PDF に描いているあいだは、カーソル (点滅する縦線) を描かない
    override var shouldDrawInsertionPoint: Bool { isExportingPDF ? false : super.shouldDrawInsertionPoint }
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        if isExportingPDF { return }
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
    }
    /// 原稿用紙のあいだ、このビューの代わりに画面に出ているマス目のビュー (GenkoView)。
    /// 文章と選択はこのビューが持ち続け、フォーカスだけをそちらへ回す
    weak var genkoProxy: NSView?
    /// カーソルを置く先 (原稿用紙のあいだはマス目のビュー)
    var focusTarget: NSView { (paperMode == .genko ? genkoProxy : nil) ?? self }

    /// loc が何番目の段落にあるか (0 始まり)
    func genkoParagraphIndex(at loc: Int) -> Int {
        var count = 0
        var i = 0
        let end = min(loc, ns.length)
        while i < end {
            if ns.character(at: i) == 0x0A { count += 1 }
            i += 1
        }
        return count
    }

    /// A4 用紙の寸法 (pt, 倍率をかけた画面上の大きさ)
    struct A4Layout {
        var scale: CGFloat = 1
        var pageX: CGFloat = 24
        static let gap: CGFloat = 24
        // A4 = 210 × 297 mm = 595 × 842 pt。余白は上 35 mm・下 30 mm・左右 30 mm
        var pageW: CGFloat { 595 * scale }
        var pageH: CGFloat { 842 * scale }
        var marginLeft: CGFloat { 85 * scale }
        var marginTop: CGFloat { 99 * scale }
        var marginBottom: CGFloat { 85 * scale }
        var textHeight: CGFloat { pageH - marginTop - marginBottom }
        var stride: CGFloat { pageH + Self.gap }
        func pageRect(_ k: Int) -> NSRect {
            NSRect(x: pageX, y: Self.gap + CGFloat(k) * stride, width: pageW, height: pageH)
        }
    }
    var a4Layout = A4Layout()

    /// 文章が何ページ目まであるか
    var a4PageCount: Int {
        guard let lm = layoutManager, let tc = textContainer else { return 1 }
        let used = lm.usedRect(for: tc)
        return max(1, Int(floor(max(0, used.maxY - 1) / a4Layout.stride)) + 1)
    }

    private func drawA4(in rect: NSRect) {
        NSColor(white: 0.55, alpha: 1).setFill()
        rect.fill()
        let L = a4Layout
        let first = max(0, Int(floor((rect.minY - A4Layout.gap) / L.stride)))
        let last = min(a4PageCount - 1, Int(ceil((rect.maxY - A4Layout.gap) / L.stride)))
        guard first <= last else { return }
        for k in first...last {
            let page = L.pageRect(k)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.set()
            NSColor.white.setFill()
            page.fill()
            NSGraphicsContext.restoreGraphicsState()
            // ページ番号 (下の余白のまん中)
            let center = NSMutableParagraphStyle()
            center.alignment = .center
            ("- \(k + 1) -" as NSString).draw(in: NSRect(x: page.minX, y: page.maxY - L.marginBottom / 2 - 7, width: page.width, height: 14), withAttributes: [
                .font: NSFont.systemFont(ofSize: max(8, 9 * L.scale)), .foregroundColor: NSColor(white: 0.45, alpha: 1), .paragraphStyle: center,
            ])
        }
    }
    /// 上下分割で、どちらの面にカーソルがあるかを知らせる
    var onBecomeFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onBecomeFirstResponder?() }
        return ok
    }

    private var ns: NSString { string as NSString }
    private var indentUnit: String {
        softTabWidth.map { String(repeating: " ", count: $0) } ?? "\t"
    }

    // MARK: 右クリックメニュー

    /// クリックした位置の文字
    private func characterIndex(for event: NSEvent) -> Int? {
        guard let lm = layoutManager, let tc = textContainer else { return nil }
        var p = convert(event.locationInWindow, from: nil)
        p.x -= textContainerOrigin.x
        p.y -= textContainerOrigin.y
        var fraction: CGFloat = 0
        let g = lm.glyphIndex(for: p, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        guard lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc).contains(p) else { return nil }
        return lm.characterIndexForGlyph(at: g)
    }

    private func link(for event: NSEvent) -> URL? {
        guard UserDefaults.standard.bool(forKey: "linkURLs"), let i = characterIndex(for: event) else { return nil }
        return LinkFinder.url(at: i, in: ns)
    }

    /// ⌘ を押しながら URL をクリックすると開く
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), paperMode == .normal, let url = link(for: event) {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
    }

    @objc private func openClickedLink(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    @objc private func copyClickedLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString.replacingOccurrences(of: "mailto:", with: ""), forType: .string)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if let url = link(for: event) {
            let open = NSMenuItem(title: L("リンクを開く"), action: #selector(openClickedLink(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = url
            let copy = NSMenuItem(title: L("リンクをコピー"), action: #selector(copyClickedLink(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = url
            menu.insertItem(open, at: 0)
            menu.insertItem(copy, at: 1)
            menu.insertItem(.separator(), at: 2)
        }
        menu.addItem(.separator())
        let split = NSMenuItem(title: L("ウインドウ上下分割"), action: #selector(EditorWindowController.toggleSplitHM(_:)), keyEquivalent: "")
        let other = NSMenuItem(title: L("分割したもう一方へ移動"), action: #selector(EditorWindowController.switchSplitPaneHM(_:)), keyEquivalent: "")
        menu.addItem(split)
        menu.addItem(NSMenuItem(title: L("ウインドウ左右分割"), action: #selector(EditorWindowController.toggleSplitSideHM(_:)), keyEquivalent: ""))
        menu.addItem(other)
        return menu
    }

    // MARK: ルーラー

    /// 標準の書式ルーラー (スタイル・揃え・間隔のボタン) を上の桁ルーラーに載せない
    override func updateRuler() {
        if let ruler = enclosingScrollView?.horizontalRulerView, ruler.accessoryView != nil || !(ruler.markers ?? []).isEmpty {
            ruler.accessoryView = nil
            ruler.markers = nil
        }
    }

    // MARK: 描画

    override func drawBackground(in rect: NSRect) {
        switch paperMode {
        case .genko: break // 原稿用紙は GenkoView が描く
        case .a4: drawA4(in: rect); return
        case .normal: break
        }
        super.drawBackground(in: rect)
        guard highlightsCurrentLine, selectedRange().length == 0, let r = currentLineRect() else { return }
        currentLineColor.setFill()
        NSRect(x: bounds.minX, y: r.minY, width: bounds.width, height: r.height).intersection(rect).fill(using: .sourceOver)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if showsEOF { drawEOF() }
        if isExportingPDF { return }
        drawRemoteCursors()
    }

    // MARK: 共同編集の相手のカーソル

    struct RemoteCursor {
        var loc: Int
        var len: Int
        var name: String
        var color: NSColor
    }

    var remoteCursors: [RemoteCursor] = [] {
        didSet {
            setNeedsDisplay(visibleRect)
            genkoProxy?.needsDisplay = true
        }
    }

    /// 文字位置 loc のカーソルの四角 (このビューの座標)
    private func caretRect(at loc: Int) -> NSRect? {
        guard let lm = layoutManager, let tc = textContainer else { return nil }
        let length = ns.length
        let l = max(0, min(loc, length))
        var r: NSRect
        if l < length {
            let g = lm.glyphIndexForCharacter(at: l)
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            r = NSRect(x: frag.minX + lm.location(forGlyphAt: g).x, y: frag.minY, width: 2, height: frag.height)
        } else if length == 0 || ns.character(at: length - 1) == 0x0A {
            let frag = lm.extraLineFragmentRect
            r = NSRect(x: frag.minX + tc.lineFragmentPadding, y: frag.minY, width: 2, height: frag.height)
        } else {
            let g = lm.glyphIndexForCharacter(at: length - 1)
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let glyph = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
            r = NSRect(x: glyph.maxX, y: frag.minY, width: 2, height: frag.height)
        }
        if r.height <= 0 { r.size.height = font?.boundingRectForFont.height ?? 16 }
        return r.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    private func drawRemoteCursors() {
        guard !remoteCursors.isEmpty, let lm = layoutManager, let tc = textContainer else { return }
        let length = ns.length
        for c in remoteCursors {
            let loc = max(0, min(c.loc, length))
            let len = max(0, min(c.len, length - loc))
            // 選択範囲
            if len > 0 {
                let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: loc, length: len), actualCharacterRange: nil)
                c.color.withAlphaComponent(0.25).setFill()
                lm.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc) { rect, _ in
                    rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y).fill(using: .sourceOver)
                }
            }
            // カーソルと名札
            guard let caret = caretRect(at: loc + len) else { continue }
            c.color.setFill()
            caret.fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 10),
                .foregroundColor: NSColor.white,
            ]
            let label = c.name as NSString
            let size = label.size(withAttributes: attrs)
            var tag = NSRect(x: caret.minX, y: caret.minY - size.height - 2, width: size.width + 8, height: size.height + 2)
            if tag.minY < visibleRect.minY { tag.origin.y = caret.maxY }
            NSBezierPath(roundedRect: tag, xRadius: 3, yRadius: 3).fill()
            label.draw(at: NSPoint(x: tag.minX + 4, y: tag.minY + 1), withAttributes: attrs)
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        invalidateCurrentLineBackground()
        updateCurrentTextLine()
        // 打った文字以外でカーソルが動いたら候補を消す (引数ヒントは場所に合わせる)
        if !typingForCompletion && !stillSelecting, completionIfCreated != nil {
            completion.hideList()
            completion.updateHint()
        }
    }

    /// カーソル行の背景を描き直す。前の行と今の行だけ (画面全体を描き直すと、大きな文書で打つたびに引っかかる)
    private var lastCurrentLineRect: NSRect?
    private func invalidateCurrentLineBackground() {
        guard paperMode == .normal else { setNeedsDisplay(visibleRect); return }
        if let old = lastCurrentLineRect { setNeedsDisplay(old) }
        let now = highlightsCurrentLine ? currentLineRect().map { NSRect(x: bounds.minX, y: $0.minY, width: bounds.width, height: $0.height) } : nil
        if let now = now { setNeedsDisplay(now) }
        lastCurrentLineRect = now
    }

    private func currentLineRect() -> NSRect? {
        guard let lm = layoutManager else { return nil }
        let length = ns.length
        let loc = selectedRange().location
        var r: NSRect
        if length == 0 || (loc >= length && ns.character(at: length - 1) == 0x0A) {
            r = lm.extraLineFragmentRect
            if r.isEmpty { return nil }
        } else {
            r = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: min(loc, length - 1)), effectiveRange: nil)
        }
        r.origin.y += textContainerOrigin.y
        return r
    }

    private func drawEOF() {
        guard let lm = layoutManager, let tc = textContainer else { return }
        let length = ns.length
        let origin = textContainerOrigin
        // 文末が見えていないときは描かない。描くには文末まで組む必要があり、
        // 大きな文書では打つたびにカーソルより後ろを全部組み直すことになって引っかかる
        if length > 0 {
            let visible = visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
            let glyphs = lm.glyphRange(forBoundingRectWithoutAdditionalLayout: visible, in: tc)
            let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            if NSMaxRange(chars) < length - 1 { return }
        }
        var point: NSPoint
        // 最後の字のあたりは、組み終わっていないことがある (サーバへ送るときなど、表示を更新した直後)。先に組んでおく
        if length > 0 { lm.ensureLayout(forCharacterRange: NSRange(location: length - 1, length: 1)) }
        if length == 0 || ns.character(at: length - 1) == 0x0A {
            var r = lm.extraLineFragmentRect
            if r.isEmpty && r.origin == .zero && length > 0 {
                // 最後の空の行の場所がまだ無い: 最後の行のすぐ下にする (左上の隅に出てしまわないように)
                let line = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: length - 1), effectiveRange: nil)
                r = NSRect(x: line.minX, y: line.maxY, width: 0, height: line.height)
            }
            point = NSPoint(x: r.minX + tc.lineFragmentPadding, y: r.minY)
        } else {
            let g = lm.glyphIndexForCharacter(at: length - 1)
            let line = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let glyph = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
            point = NSPoint(x: glyph.maxX + 2, y: line.minY)
        }
        point.x += origin.x
        point.y += origin.y
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.eof]
        ("[EOF]" as NSString).draw(at: point, withAttributes: attrs)
    }

    // MARK: 入力

    // MARK: カーソル行の文字の色

    /// カーソルのある行を覚え直して、色を塗り直す
    func updateCurrentTextLine(force: Bool = false) {
        guard let lm = layoutManager else { return }
        var newRange: NSRange?
        let sel = selectedRange()
        if currentLineTextColor != nil, highlightsCurrentLine, paperMode == .normal, sel.length == 0 {
            let line = ns.lineRange(for: NSRange(location: min(sel.location, ns.length), length: 0))
            var len = line.length
            while len > 0, [0x0A, 0x0D].contains(ns.character(at: line.location + len - 1)) { len -= 1 }
            newRange = NSRange(location: line.location, length: len)
        }
        guard force || newRange != currentTextLine else { return }
        let length = ns.length
        func clamp(_ r: NSRange) -> NSRange {
            let s = min(r.location, length)
            return NSRange(location: s, length: min(r.length, length - s))
        }
        if let old = currentTextLine { lm.invalidateDisplay(forCharacterRange: clamp(old)) }
        currentTextLine = newRange
        if let r = newRange { lm.invalidateDisplay(forCharacterRange: clamp(r)) }
    }

    /// AI の答えを 1 字ずつ見せている間、まだ見せていない範囲 (文字は入っているが、透明にして描く)
    var revealHidden: NSRange? {
        didSet {
            guard let lm = layoutManager, let storage = textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            for r in [oldValue, revealHidden].compactMap({ $0 }) {
                let c = NSIntersectionRange(r, full)
                if c.length > 0 { lm.invalidateDisplay(forCharacterRange: c) }
            }
        }
    }

    /// 描くときに、カーソル行の文字だけ色を差し替える (構文の色分けは崩さない)
    func layoutManager(_ layoutManager: NSLayoutManager, shouldUseTemporaryAttributes attrs: [NSAttributedString.Key: Any] = [:],
                       forDrawingToScreen toScreen: Bool, atCharacterIndex charIndex: Int,
                       effectiveRange effectiveCharRange: NSRangePointer?) -> [NSAttributedString.Key: Any]? {
        // まだ見せていない AI の答えは透明にする
        if toScreen, let h = revealHidden, h.length > 0 {
            var eff = effectiveCharRange?.pointee ?? NSRange(location: charIndex, length: 1)
            if NSLocationInRange(charIndex, h) {
                var a = attrs
                a[.foregroundColor] = NSColor.clear
                let cut = NSIntersectionRange(eff, h)
                effectiveCharRange?.pointee = cut.length > 0 ? cut : NSRange(location: charIndex, length: 1)
                return a
            }
            if charIndex < h.location, NSMaxRange(eff) > h.location {
                eff.length = h.location - eff.location
                effectiveCharRange?.pointee = eff
            }
        }
        guard toScreen, let color = currentLineTextColor, let r = currentTextLine, r.length > 0 else { return attrs }
        var eff = effectiveCharRange?.pointee ?? NSRange(location: charIndex, length: 1)
        if NSLocationInRange(charIndex, r) {
            var a = attrs
            a[.foregroundColor] = color
            effectiveCharRange?.pointee = NSIntersectionRange(eff, r)
            return a
        }
        // 色を変える行にはみ出さないように、効く範囲を切る
        if charIndex < r.location, NSMaxRange(eff) > r.location {
            eff.length = r.location - eff.location
        } else if charIndex >= NSMaxRange(r), eff.location < NSMaxRange(r) {
            let end = NSMaxRange(eff)
            eff.location = NSMaxRange(r)
            eff.length = end - eff.location
        }
        effectiveCharRange?.pointee = eff
        return attrs
    }

    // MARK: 入力補完

    private var completionIfCreated: CompletionController?
    /// 候補のリストと引数ヒント (使うときに作る)
    var completion: CompletionController {
        if let c = completionIfCreated { return c }
        let c = CompletionController(textView: self)
        completionIfCreated = c
        return c
    }
    /// 文字を打っている最中 (この間のカーソル移動では候補を消さない)
    private var typingForCompletion = false
    private var resignObserver: NSObjectProtocol?

    override func doCommand(by selector: Selector) {
        if let c = completionIfCreated, c.handle(selector) { return }
        super.doCommand(by: selector)
    }

    /// Esc / ⌥Esc (標準の「補完」) で候補を出す
    override func complete(_ sender: Any?) {
        guard paperMode == .normal else { return super.complete(sender) }
        completion.update(manual: true)
    }

    override func keyDown(with event: NSEvent) {
        // ⌃Space でも候補を出す
        if event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control, paperMode == .normal {
            completion.update(manual: true)
            return
        }
        super.keyDown(with: event)
    }

    override func deleteBackward(_ sender: Any?) {
        typingForCompletion = true
        super.deleteBackward(sender)
        typingForCompletion = false
        if let c = completionIfCreated {
            if c.isShowing { c.update() }
            c.updateHint()
        }
    }

    /// これから入る文字の範囲 (変更後の位置)。didChangeText で目印を付ける
    private var pendingAdded: [NSRange] = []

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        let ok = super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        if ok, let strings = replacementStrings, strings.count == affectedRanges.count {
            // 範囲は前から順に並んでいる。前の置き換えで後ろの位置がずれる分を足していく
            var delta = 0
            for (v, s) in zip(affectedRanges, strings) {
                let r = v.rangeValue
                let n = (s as NSString).length
                if n > 0 { pendingAdded.append(NSRange(location: r.location + delta, length: n)) }
                delta += n - r.length
            }
        }
        return ok
    }

    override func didChangeText() {
        // 足した文字に目印を付けて太字にする (保存すると戻る)
        if !pendingAdded.isEmpty, let storage = textStorage {
            let bold = font.map { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) }
            for r in pendingAdded where NSMaxRange(r) <= storage.length {
                storage.addAttribute(.addedText, value: true, range: r)
                if paperMode == .normal, let b = bold { storage.addAttribute(.font, value: b, range: r) }
            }
            pendingAdded = []
        }
        super.didChangeText()
        completionIfCreated?.textVersion += 1
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { completionIfCreated?.hide() }
        return ok
    }

    override func scrollWheel(with event: NSEvent) {
        completionIfCreated?.hide()
        super.scrollWheel(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        resignObserver = nil
        guard let w = window else { completionIfCreated?.hide(); return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in
            self?.completionIfCreated?.hide()
        }
    }

    /// 打った文字に合わせて候補・引数ヒントを出し直す
    private func afterTyping(_ text: String) {
        guard paperMode == .normal, !hasMarkedText(), completionIfCreated?.accepting != true else { return }
        let u = Array(text.utf16)
        if !u.isEmpty, u.count <= 2, u.allSatisfy({ Completion.isWordChar($0) || $0 == 0x2D }) {
            completion.update()
        } else if u == [0x3C] || (u == [0x2E] && completionIfCreated?.isShowing != true) {
            completion.update() // < や . の直後は、次の文字で出す
        } else {
            completionIfCreated?.hideList()
        }
        completion.updateHint()
    }

    // MARK: ファイルを放り込んだら開く

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        FileDrop.handles(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        FileDrop.handles(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        FileDrop.handles(sender) ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard FileDrop.handles(sender) else { return super.performDragOperation(sender) }
        let urls = FileDrop.fileURLs(sender)
        // ドラッグが終わってから開く (開くときの確認などがドラッグ中に出ないように)
        let target = owningEditor
        DispatchQueue.main.async { FileDrop.open(urls, into: target) }
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if let s = sender, FileDrop.handles(s) { return }
        super.concludeDragOperation(sender)
    }

    // MARK: 範囲を選んで Tab / Shift+Tab

    override func insertBacktab(_ sender: Any?) {
        guard paperMode == .normal else { return super.insertBacktab(sender) }
        outdentHM(sender)
    }

    override func insertTab(_ sender: Any?) {
        // 範囲を選んでいたら、その行をまとめて右へずらす
        if paperMode == .normal, selectedRange().length > 0 {
            indentHM(sender)
            return
        }
        guard let width = softTabWidth else {
            super.insertTab(sender)
            return
        }
        let sel = selectedRange()
        let column = sel.location - ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
        insertText(String(repeating: " ", count: width - column % width), replacementRange: sel)
    }

    /// 改行したら前の行のインデントを引き継ぐ
    // MARK: 作文アシスト

    override func insertText(_ string: Any, replacementRange: NSRange) {
        var text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        guard paperMode == .genko, !text.isEmpty else {
            typingForCompletion = true
            super.insertText(string, replacementRange: replacementRange)
            typingForCompletion = false
            afterTyping(text)
            return
        }
        let d = UserDefaults.standard
        if d.bool(forKey: "genkoFullWidth") { text = Genko.toFullWidth(text) }
        // 何も書いていない文書の書き出しも 1 マス下げる (かぎかっこで始めるときは下げない)
        // (日本語入力の変換中の文字しか無いときも「何も書いていない」とみなす)
        let marked = markedRange()
        let isEmptyDocument = ns.length == 0 || (hasMarkedText() && marked.location == 0 && marked.length == ns.length)
        if d.bool(forKey: "genkoAutoIndent"), !genkoAutoFormat, isEmptyDocument, let first = text.first,
           !first.isWhitespace, !first.isNewline, !"「『（(".contains(first) {
            text = "\u{3000}" + text
        }
        super.insertText(text, replacementRange: replacementRange)
    }

    override func insertNewline(_ sender: Any?) {
        if paperMode == .genko {
            let d = UserDefaults.standard
            let caret = selectedRange().location
            // 自動整形: 名前 (2 列目) を書き終えて改行したら、1 列空けて 4 列目から本文を始める
            if genkoAutoFormat, selectedRange().length == 0, caret == ns.length,
               genkoParagraphIndex(at: caret) == 1, caret > 0, ns.character(at: caret - 1) != 0x0A {
                super.insertText("\n\n", replacementRange: selectedRange())
                return
            }
            super.insertNewline(sender)
            // 段落を変えたら次は 1 マス下げて始める
            if UserDefaults.standard.bool(forKey: "genkoAutoIndent"), !genkoAutoFormat {
                super.insertText("\u{3000}", replacementRange: selectedRange())
            }
            return
        }
        guard UserDefaults.standard.bool(forKey: "autoIndent") else {
            super.insertNewline(sender)
            return
        }
        let loc = selectedRange().location
        let lineStart = ns.lineRange(for: NSRange(location: loc, length: 0)).location
        var end = lineStart
        while end < loc, ns.character(at: end) == 0x20 || ns.character(at: end) == 0x09 { end += 1 }
        let indent = ns.substring(with: NSRange(location: lineStart, length: end - lineStart))
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(indent, replacementRange: selectedRange()) }
    }

    // MARK: 編集の土台

    /// Undo 可能な置換
    @discardableResult
    func replace(_ range: NSRange, with text: String, select newSelection: NSRange? = nil) -> Bool {
        guard shouldChangeText(in: range, replacementString: text), let storage = textStorage else { return false }
        storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: typingAttributes))
        didChangeText()
        if let s = newSelection {
            setSelectedRange(s)
            scrollRangeToVisible(s)
        }
        return true
    }

    /// 選択範囲を含む行全体 (末尾の改行を含む)
    private var selectedLinesRange: NSRange {
        var sel = selectedRange()
        // 行頭で終わる複数行選択は、その行を含めない
        if sel.length > 0 && sel.location + sel.length <= ns.length && sel.location + sel.length > 0
            && ns.character(at: sel.location + sel.length - 1) == 0x0A {
            sel.length -= 1
        }
        return ns.lineRange(for: sel)
    }

    private func linesText(_ range: NSRange) -> (lines: [String], trailingNewline: Bool) {
        var text = ns.substring(with: range)
        let trailing = text.hasSuffix("\n")
        if trailing { text.removeLast() }
        return (text.components(separatedBy: "\n"), trailing)
    }

    /// 選択された各行を変換する
    private func transformLines(_ transform: ([String]) -> [String]) {
        let range = selectedLinesRange
        let (lines, trailing) = linesText(range)
        let result = transform(lines).joined(separator: "\n") + (trailing ? "\n" : "")
        replace(range, with: result, select: NSRange(location: range.location, length: (result as NSString).length - (trailing ? 1 : 0)))
    }

    // MARK: 行操作

    @objc func duplicateLineHM(_ sender: Any?) {
        let range = selectedLinesRange
        var text = ns.substring(with: range)
        if !text.hasSuffix("\n") { text = "\n" + text }
        let insertAt = NSMaxRange(range)
        let caret = selectedRange().location + (text as NSString).length
        replace(NSRange(location: insertAt, length: 0), with: text, select: NSRange(location: min(caret, ns.length + (text as NSString).length), length: 0))
    }

    @objc func deleteLineHM(_ sender: Any?) {
        let range = selectedLinesRange
        replace(range, with: "", select: NSRange(location: range.location, length: 0))
    }

    @objc func moveLineUpHM(_ sender: Any?) { moveLines(up: true) }
    @objc func moveLineDownHM(_ sender: Any?) { moveLines(up: false) }

    private func moveLines(up: Bool) {
        let range = selectedLinesRange
        if up {
            guard range.location > 0 else { NSSound.beep(); return }
            let prev = ns.lineRange(for: NSRange(location: range.location - 1, length: 0))
            var block = ns.substring(with: range)
            var prevText = ns.substring(with: prev)
            if !block.hasSuffix("\n") { block += "\n"; prevText.removeLast() }
            let whole = NSRange(location: prev.location, length: prev.length + range.length)
            replace(whole, with: block + prevText,
                    select: NSRange(location: prev.location, length: (block as NSString).length - 1))
        } else {
            let end = NSMaxRange(range)
            guard end < ns.length else { NSSound.beep(); return }
            let next = ns.lineRange(for: NSRange(location: end, length: 0))
            var block = ns.substring(with: range)
            var nextText = ns.substring(with: next)
            if !nextText.hasSuffix("\n") { nextText += "\n"; block.removeLast() }
            let whole = NSRange(location: range.location, length: range.length + next.length)
            let newStart = range.location + (nextText as NSString).length
            replace(whole, with: nextText + block,
                    select: NSRange(location: newStart, length: max(0, (block as NSString).length - (block.hasSuffix("\n") ? 1 : 0))))
        }
    }

    @objc func indentHM(_ sender: Any?) {
        let unit = indentUnit
        transformLines { $0.map { $0.isEmpty ? $0 : unit + $0 } }
    }

    @objc func outdentHM(_ sender: Any?) {
        let width = softTabWidth ?? indentWidth
        transformLines { lines in
            lines.map { line in
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                let spaces = line.prefix(while: { $0 == " " }).count
                return String(line.dropFirst(min(spaces, width)))
            }
        }
    }

    @objc func toggleCommentHM(_ sender: Any?) {
        guard let prefix = lineCommentPrefix else { NSSound.beep(); return }
        transformLines { lines in
            let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let allCommented = !content.isEmpty && content.allSatisfy {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
            }
            if allCommented {
                return lines.map { line in
                    guard let r = line.range(of: prefix) else { return line }
                    var out = line
                    out.removeSubrange(r)
                    if out[r.lowerBound...].hasPrefix(" ") { out.remove(at: r.lowerBound) }
                    return out
                }
            }
            let indent = content.map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }.min() ?? 0
            return lines.map { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                let i = line.index(line.startIndex, offsetBy: indent)
                return String(line[..<i]) + prefix + " " + String(line[i...])
            }
        }
    }

    @objc func sortLinesHM(_ sender: Any?) {
        transformLines { $0.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    }

    @objc func uniqueLinesHM(_ sender: Any?) {
        transformLines { lines in
            var seen = Set<String>()
            return lines.filter { seen.insert($0).inserted }
        }
    }

    @objc func trimTrailingSpacesHM(_ sender: Any?) {
        let all = NSRange(location: 0, length: ns.length)
        let sel = selectedRange()
        let result = string.components(separatedBy: "\n").map { line -> String in
            var l = line
            while let last = l.last, last == " " || last == "\t" { l.removeLast() }
            return l
        }.joined(separator: "\n")
        guard result != string else { return }
        replace(all, with: result, select: NSRange(location: min(sel.location, (result as NSString).length), length: 0))
    }

    // MARK: 括弧

    @objc func jumpToMatchingBracketHM(_ sender: Any?) {
        let pairs: [unichar: (unichar, Bool)] = [
            0x28: (0x29, true), 0x5B: (0x5D, true), 0x7B: (0x7D, true),
            0x29: (0x28, false), 0x5D: (0x5B, false), 0x7D: (0x7B, false),
        ]
        let length = ns.length
        let loc = selectedRange().location
        // カーソルの直後、なければ直前の括弧を対象にする
        var pos = -1
        if loc < length, pairs[ns.character(at: loc)] != nil { pos = loc }
        else if loc > 0, pairs[ns.character(at: loc - 1)] != nil { pos = loc - 1 }
        guard pos >= 0, let (match, forward) = pairs[ns.character(at: pos)] else { NSSound.beep(); return }

        let open = ns.character(at: pos)
        var depth = 0
        var i = pos
        while i >= 0 && i < length {
            let c = ns.character(at: i)
            if c == open { depth += 1 } else if c == match { depth -= 1 }
            if depth == 0 {
                let r = NSRange(location: i, length: 0)
                setSelectedRange(r)
                scrollRangeToVisible(r)
                showFindIndicator(for: NSRange(location: i, length: 1))
                return
            }
            i += forward ? 1 : -1
        }
        NSSound.beep()
    }

    // MARK: 移動

    /// 指定位置の行へ移動して行を光らせる
    func goTo(location: Int) {
        let length = ns.length
        let r = NSRange(location: min(max(0, location), length), length: 0)
        setSelectedRange(r)
        scrollRangeToVisible(r)
        focusTarget.window?.makeFirstResponder(focusTarget)
        if r.location < length {
            showFindIndicator(for: ns.lineRange(for: r))
        }
    }

    func goTo(line: Int) {
        let target = max(1, line)
        var current = 1
        var loc = 0
        let length = ns.length
        while current < target && loc < length {
            let r = ns.lineRange(for: NSRange(location: loc, length: 0))
            loc = NSMaxRange(r)
            current += 1
        }
        let r = NSRange(location: min(loc, length), length: 0)
        setSelectedRange(r)
        scrollRangeToVisible(r)
        focusTarget.window?.makeFirstResponder(focusTarget)
        if r.location < length {
            showFindIndicator(for: ns.lineRange(for: r))
        }
    }
}
