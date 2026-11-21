import AppKit

extension NSAttributedString.Key {
    /// A4 用紙モードで手で決めた段落の寄せ ("left" / "center" / "right")
    static let paperAlign = NSAttributedString.Key("SatoruPaperAlign")
}

/// エディタ本体。カーソル行のハイライト、[EOF]、自動インデント、行操作など。
final class EditorTextView: NSTextView {
    var currentLineColor: NSColor = Theme.currentLine
    /// nil ならタブ文字、数値ならその幅までスペースを入れる
    var softTabWidth: Int?
    /// 1 タブ分のインデントに使う幅 (softTabWidth が nil のときはタブ文字 1 つ)
    var indentWidth = 4
    /// 行コメントの記号 (⌘/ で使う)
    var lineCommentPrefix: String?
    var showsEOF = true { didSet { needsDisplay = true } }
    var highlightsCurrentLine = true { didSet { needsDisplay = true } }

    // MARK: 用紙モード

    enum PaperMode: Int { case normal, genko, a4 }
    var paperMode: PaperMode = .normal {
        didSet {
            needsDisplay = true
            genkoBlink?.invalidate()
            genkoBlink = nil
            if paperMode == .genko {
                // 作文用紙では、マスの区切りに合わせた自前のカーソルを点滅させる
                genkoBlink = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.genkoCaretOn.toggle()
                    if let r = self.genkoCaretRect() { self.setNeedsDisplay(r.insetBy(dx: -3, dy: -3)) }
                }
            }
        }
    }
    /// PDF に書き出している間は、カーソル・選択・相手のカーソルを描かない
    var isExportingPDF = false
    private var genkoBlink: Timer?
    /// 動作確認用 (アプリ本体では使わない)
    static var drawsCaretForTesting = false
    private var genkoCaretOn = true

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

    /// まだ何も書いていない列で、書き始めの位置 (自動整形: 題名は 3 マス下げ、本文は 1 マス下げ)
    private func genkoEmptyLineIndent(at loc: Int) -> Int {
        guard UserDefaults.standard.bool(forKey: "genkoAutoFormat") else { return 0 }
        let index = genkoParagraphIndex(at: loc)
        if index == 0 { return 3 }
        if index == 1 { return 0 }
        return 1
    }

    /// 作文用紙のカーソル: 今の文字のマスの頭に、列の幅いっぱいの細い線 (描画座標は縦書きで回っている)
    func genkoCaretRect() -> NSRect? {
        guard paperMode == .genko, selectedRange().length == 0, let lm = layoutManager else { return nil }
        let cell = genkoCell
        let n = ns.length
        let loc = selectedRange().location
        func column(ofGlyph g: Int) -> Int { Int(floor(lm.location(forGlyphAt: g).x / cell)) }
        var lineY: CGFloat
        var col: Int
        let atLineEnd = loc >= n || ns.character(at: loc) == 0x0A
        if !atLineEnd {
            let g = lm.glyphIndexForCharacter(at: loc)
            lineY = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minY
            col = column(ofGlyph: g)
        } else if loc > 0, ns.character(at: loc - 1) != 0x0A {
            // 行の終わり: 直前の文字のマスの次
            let g = lm.glyphIndexForCharacter(at: loc - 1)
            lineY = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minY
            col = column(ofGlyph: g) + 1
            if col >= Self.genkoRows, loc >= n {
                // 20 マス目まで埋まっていたら次の列の頭
                lineY += cell
                col = 0
            }
        } else if loc < n {
            // 空の行
            lineY = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: loc), effectiveRange: nil).minY
            col = genkoEmptyLineIndent(at: loc)
        } else {
            lineY = n == 0 ? 0 : lm.extraLineFragmentRect.minY
            col = genkoEmptyLineIndent(at: loc)
        }
        let o = textContainerOrigin
        return NSRect(x: o.x + CGFloat(min(col, Self.genkoRows)) * cell - 1, y: o.y + lineY + 3, width: 2.5, height: cell - 6)
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        // 作文用紙では標準のカーソルは描かず、draw(_:) で自前のものを描く
        guard paperMode != .genko else { return }
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
    }
    /// 作文用紙の 1 マスの大きさ
    var genkoCell: CGFloat = 28
    static let genkoRows = 20
    /// 字をマスの真ん中に置くための補正 (フォントサイズに対する割合。描画を測って決めた値)
    static var genkoCrossShift: CGFloat = 0.197
    static var genkoAlongShift: CGFloat = -0.02
    /// A4: 1 ページの行数と 1 行の高さ、用紙の幅

    static let paperColor = NSColor(srgbRed: 1.0, green: 0.992, blue: 0.96, alpha: 1)
    static let genkoLineColor = NSColor(srgbRed: 0.80, green: 0.45, blue: 0.35, alpha: 1)

    /// 縦書きのときは描画の座標が 90° 回っていて、「行」が画面上の縦の列になる。
    /// なので横書きと同じつもりで、1 行 20 マスの行を上から積むように描けば作文用紙になる。
    private func drawGenko(in rect: NSRect) {
        Self.paperColor.setFill()
        rect.fill()
        let cell = genkoCell
        let rows = Self.genkoRows
        // 文字が実際に置かれる位置 (余白どおりとは限らない) から描く
        let left = textContainerOrigin.x
        let top = textContainerOrigin.y
        let length = cell * CGFloat(rows)
        let lines = max(20, Int(ceil((bounds.maxY - top) / cell)))
        let pages = (lines + 19) / 20
        let bottom = top + CGFloat(pages * 20) * cell
        let grid = NSBezierPath()
        grid.lineWidth = 0.7
        for i in 0...rows {
            let x = floor(left + CGFloat(i) * cell) + 0.5
            grid.move(to: NSPoint(x: x, y: top))
            grid.line(to: NSPoint(x: x, y: bottom))
        }
        for j in 0...(pages * 20) {
            let y = floor(top + CGFloat(j) * cell) + 0.5
            grid.move(to: NSPoint(x: left, y: y))
            grid.line(to: NSPoint(x: left + length, y: y))
        }
        Self.genkoLineColor.withAlphaComponent(0.55).setStroke()
        grid.stroke()
        // 20 行 (= 400 字) ごとに太枠と枚数
        Self.genkoLineColor.setStroke()
        for p in 0..<pages {
            let frame = NSBezierPath(rect: NSRect(x: left, y: top + CGFloat(p * 20) * cell, width: length, height: cell * 20))
            frame.lineWidth = 1.6
            frame.stroke()
            ("\(p + 1) 枚目" as NSString).draw(at: NSPoint(x: left + length + 6, y: top + CGFloat(p * 20) * cell + 2), withAttributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: Self.genkoLineColor,
            ])
        }
        drawGenkoSelection(in: rect)
    }

    /// 作文用紙の選択表示: 枠線は見えたまま、選んだ文字のマスだけに薄い色を敷く
    private func drawGenkoSelection(in rect: NSRect) {
        guard !isExportingPDF, let lm = layoutManager, let tc = textContainer else { return }
        let o = textContainerOrigin
        let cell = genkoCell
        let visible = lm.glyphRange(forBoundingRect: rect.offsetBy(dx: -o.x, dy: -o.y), in: tc)
        let visibleChars = lm.characterRange(forGlyphRange: visible, actualGlyphRange: nil)
        NSColor(srgbRed: 0.25, green: 0.55, blue: 1.0, alpha: 0.28).setFill()
        for value in selectedRanges {
            let sel = NSIntersectionRange(value.rangeValue, visibleChars)
            guard sel.length > 0 else { continue }
            for i in sel.location..<NSMaxRange(sel) {
                let c = ns.character(at: i)
                if c == 0x0A || UTF16.isTrailSurrogate(c) { continue }
                let g = lm.glyphIndexForCharacter(at: i)
                let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                let col = floor(lm.location(forGlyphAt: g).x / cell)
                // マスの線にかからないよう 1.5 pt 内側
                NSRect(x: o.x + col * cell, y: o.y + frag.minY, width: cell, height: cell)
                    .insetBy(dx: 1.5, dy: 1.5).fill(using: .sourceOver)
            }
        }
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
            let open = NSMenuItem(title: "リンクを開く", action: #selector(openClickedLink(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = url
            let copy = NSMenuItem(title: "リンクをコピー", action: #selector(copyClickedLink(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = url
            menu.insertItem(open, at: 0)
            menu.insertItem(copy, at: 1)
            menu.insertItem(.separator(), at: 2)
        }
        menu.addItem(.separator())
        let split = NSMenuItem(title: "ウインドウ上下分割", action: #selector(EditorWindowController.toggleSplitHM(_:)), keyEquivalent: "")
        let other = NSMenuItem(title: "分割したもう一方へ移動", action: #selector(EditorWindowController.switchSplitPaneHM(_:)), keyEquivalent: "")
        menu.addItem(split)
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
        case .genko: drawGenko(in: rect); return
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
        if paperMode == .genko, genkoCaretOn,
           Self.drawsCaretForTesting || (window?.isKeyWindow == true && window?.firstResponder === self),
           let r = genkoCaretRect() {
            NSColor(white: 0.1, alpha: 1).setFill()
            r.fill()
        }
    }

    // MARK: 共同編集の相手のカーソル

    struct RemoteCursor {
        var loc: Int
        var len: Int
        var name: String
        var color: NSColor
    }

    var remoteCursors: [RemoteCursor] = [] {
        didSet { setNeedsDisplay(visibleRect) }
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
        genkoCaretOn = true
        setNeedsDisplay(visibleRect)
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
        var point: NSPoint
        if length == 0 || ns.character(at: length - 1) == 0x0A {
            let r = lm.extraLineFragmentRect
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

    override func insertTab(_ sender: Any?) {
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

    /// 半角の英数字・記号 → 全角 (作文用紙で 1 マスに正立で入るように)
    private func fullWidth(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if u.value == 0x20, let v = Unicode.Scalar(0x3000 as UInt32) {
                out.append(v)
            } else if (0x21...0x7E).contains(u.value), let v = Unicode.Scalar(u.value + 0xFEE0) {
                out.append(v)
            } else {
                out.append(u)
            }
        }
        return String(out)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        var text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        guard paperMode == .genko, !text.isEmpty else {
            return super.insertText(string, replacementRange: replacementRange)
        }
        let d = UserDefaults.standard
        if d.bool(forKey: "genkoFullWidth") { text = fullWidth(text) }
        // 何も書いていない文書の書き出しも 1 マス下げる (かぎかっこで始めるときは下げない)
        // (日本語入力の変換中の文字しか無いときも「何も書いていない」とみなす)
        let marked = markedRange()
        let isEmptyDocument = ns.length == 0 || (hasMarkedText() && marked.location == 0 && marked.length == ns.length)
        if d.bool(forKey: "genkoAutoIndent"), !d.bool(forKey: "genkoAutoFormat"), isEmptyDocument, let first = text.first,
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
            if d.bool(forKey: "genkoAutoFormat"), selectedRange().length == 0, caret == ns.length,
               genkoParagraphIndex(at: caret) == 1, caret > 0, ns.character(at: caret - 1) != 0x0A {
                super.insertText("\n\n", replacementRange: selectedRange())
                return
            }
            super.insertNewline(sender)
            // 段落を変えたら次は 1 マス下げて始める
            if UserDefaults.standard.bool(forKey: "genkoAutoIndent"), !UserDefaults.standard.bool(forKey: "genkoAutoFormat") {
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
        window?.makeFirstResponder(self)
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
        window?.makeFirstResponder(self)
        if r.location < length {
            showFindIndicator(for: ns.lineRange(for: r))
        }
    }
}
