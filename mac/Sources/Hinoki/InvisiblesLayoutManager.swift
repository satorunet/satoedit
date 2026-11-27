import AppKit

/// 改行 (↓)・タブ (›)・全角スペース (□) を薄く描く
final class InvisiblesLayoutManager: NSLayoutManager {
    var showsInvisibles = true {
        didSet { if oldValue != showsInvisibles { invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0)) } }
    }

    /// フォーカスがないとき (AI の入力欄などに移ったとき) の選択範囲の色。
    /// 決めておかないと macOS の薄い灰色で塗られ、暗いテーマでは真っ白に見える
    var inactiveSelectionColor: NSColor?

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard let tv = textContainers.first?.textView,
              tv.selectedRanges.contains(where: { NSIntersectionRange($0.rangeValue, charRange).length > 0 }) else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        // 選択範囲は、字のあるところだけを塗る (改行のぶんや、行の右端までの空きは塗らない)
        var rects = selectionRects(charRange, in: tv)
        // 色では見分けない (macOS が渡す色は、比べても一致しないことがある)。
        // 「選択範囲を塗っていて、エディタにフォーカスがない」ときに、テーマの選択色に替える
        var fill = color
        if let mine = inactiveSelectionColor, tv.window?.firstResponder !== tv, !(tv.window?.firstResponder is GenkoView) {
            mine.setFill()
            fill = mine
        }
        guard !rects.isEmpty else { return }
        super.fillBackgroundRectArray(&rects, count: rects.count, forCharacterRange: charRange, color: fill)
    }

    /// 選択の塗る四角: 行ごとに、最初の字の左から最後の字 (改行を除く) の右まで
    private func selectionRects(_ charRange: NSRange, in tv: NSTextView) -> [NSRect] {
        guard let container = textContainers.first, let storage = textStorage else { return [] }
        let ns = storage.string as NSString
        let origin = tv.textContainerOrigin
        let glyphs = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var out: [NSRect] = []
        enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, lineGlyphs, _ in
            var chars = self.characterRange(forGlyphRange: NSIntersectionRange(lineGlyphs, glyphs), actualGlyphRange: nil)
            chars = NSIntersectionRange(chars, charRange)
            while chars.length > 0 {
                let c = ns.character(at: NSMaxRange(chars) - 1)
                guard c == 0x0A || c == 0x0D || c == 0x2028 || c == 0x2029 else { break }
                chars.length -= 1
            }
            guard chars.length > 0 else { return }
            let g = self.glyphRange(forCharacterRange: chars, actualCharacterRange: nil)
            let r = self.boundingRect(forGlyphRange: g, in: container)
            out.append(NSRect(x: r.minX + origin.x, y: lineRect.minY + origin.y, width: r.width, height: lineRect.height))
        }
        return out
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard showsInvisibles, let storage = textStorage, let container = textContainers.first else { return }

        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        guard charRange.length > 0 else { return }
        var buffer = [unichar](repeating: 0, count: charRange.length)
        (storage.string as NSString).getCharacters(&buffer, range: charRange)

        // 行・字体は前の字と同じなら引き直さない。スペースの印は 1 本の線にまとめて最後に一度で描く
        // (字下げのスペースが多いソースコードで、1 字ずつ引くと描くのが重い)
        var lineGlyphs = NSRange(location: NSNotFound, length: 0)
        var lineRect = NSRect.zero
        var fontRange = NSRange(location: NSNotFound, length: 0)
        var font = NSFont.systemFont(ofSize: 12)
        let spaces = NSBezierPath()
        spaces.lineWidth = 0.8
        let wideSpaces = NSBezierPath()
        wideSpaces.lineWidth = 0.8
        wideSpaces.setLineDash([2, 2], count: 2, phase: 0)
        let ctx = NSGraphicsContext.current?.cgContext

        var offset = 0
        while offset < buffer.count {
            let c = buffer[offset]
            guard c == 0x0A || c == 0x09 || c == 0x3000 || c == 0x20 else { offset += 1; continue }
            let index = charRange.location + offset
            let glyph = glyphIndexForCharacter(at: index)
            if !NSLocationInRange(glyph, lineGlyphs) {
                lineRect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
            }
            if !NSLocationInRange(index, fontRange) {
                font = (storage.attribute(.font, at: index, effectiveRange: &fontRange) as? NSFont) ?? .systemFont(ofSize: 12)
            }
            // 字の左端は、行の中の位置から出す (字ごとに外枠を求めるより軽い)
            let x = origin.x + lineRect.minX + location(forGlyphAt: glyph).x
            let y = origin.y + lineRect.minY

            switch c {
            case 0x20, 0x3000:
                // 同じ空白が続くところ (字下げなど) は、まとめて 1 回で位置と幅を出し、等分する
                var n = 1
                while offset + n < buffer.count, buffer[offset + n] == c, glyph + n < NSMaxRange(lineGlyphs),
                      NSLocationInRange(index + n, fontRange) { n += 1 }
                let total = boundingRect(forGlyphRange: NSRange(location: glyph, length: n), in: container).width
                let w = total / CGFloat(n)
                for k in 0..<n {
                    let left = x + w * CGFloat(k)
                    if c == 0x20 {
                        // 半角スペース: 下に小さな受け皿の形 (␣)
                        let bottom = y + lineRect.height * 0.80
                        let tick = max(2, lineRect.height * 0.12)
                        spaces.move(to: NSPoint(x: left + w * 0.2, y: bottom - tick))
                        spaces.line(to: NSPoint(x: left + w * 0.2, y: bottom))
                        spaces.line(to: NSPoint(x: left + w * 0.8, y: bottom))
                        spaces.line(to: NSPoint(x: left + w * 0.8, y: bottom - tick))
                    } else {
                        wideSpaces.appendRect(NSRect(x: left, y: y, width: w, height: lineRect.height)
                            .insetBy(dx: 2, dy: lineRect.height * 0.22))
                    }
                }
                offset += n
                continue
            case 0x0A:
                // 改行は文字の幅を持たないので、置かれる位置 (直前の文字の右) に印を出す
                if let ctx = ctx { drawMark("↓", font: font, color: Theme.newlineMark, at: NSPoint(x: x + 1, y: y), in: ctx) }
            default:
                if let ctx = ctx { drawMark("›", font: font, color: Theme.invisible, at: NSPoint(x: x + 1, y: y), in: ctx) }
            }
            offset += 1
        }
        if !spaces.isEmpty {
            Theme.invisible.withAlphaComponent(0.7).setStroke()
            spaces.stroke()
        }
        if !wideSpaces.isEmpty {
            Theme.invisible.setStroke()
            wideSpaces.stroke()
        }
    }

    /// 改行・タブの印の字の形 (字体・色ごとに覚えておく。1 行ごとに組み直すと重い)
    private var marks: [String: (line: CTLine, ascent: CGFloat)] = [:]

    private func drawMark(_ mark: String, font: NSFont, color: NSColor, at p: NSPoint, in ctx: CGContext) {
        let key = "\(mark) \(font.fontName) \(font.pointSize) \(ObjectIdentifier(color).hashValue)"
        let m: (line: CTLine, ascent: CGFloat)
        if let c = marks[key] {
            m = c
        } else {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: mark, attributes: [.font: font, .foregroundColor: color]))
            m = (line, font.ascender)
            if marks.count > 200 { marks.removeAll() }
            marks[key] = m
        }
        ctx.saveGState()
        // 文字の面は上下を返しているので、字も返して描く (NSString.draw(at:) と同じ位置: p は字の箱の左上)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: p.x, y: p.y + m.ascent)
        CTLineDraw(m.line, ctx)
        ctx.restoreGState()
    }
}
