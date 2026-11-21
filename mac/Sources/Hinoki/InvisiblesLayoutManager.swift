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
        // 色では見分けない (macOS が渡す色は、比べても一致しないことがある)。
        // 「選択範囲を塗っていて、エディタにフォーカスがない」ときに、テーマの選択色に替える
        if let mine = inactiveSelectionColor, let tv = textContainers.first?.textView,
           tv.window?.firstResponder !== tv, !(tv.window?.firstResponder is GenkoView),
           tv.selectedRanges.contains(where: { NSIntersectionRange($0.rangeValue, charRange).length > 0 }) {
            mine.setFill()
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: mine)
            return
        }
        super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard showsInvisibles, let storage = textStorage, let container = textContainers.first else { return }

        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        guard charRange.length > 0 else { return }
        var buffer = [unichar](repeating: 0, count: charRange.length)
        (storage.string as NSString).getCharacters(&buffer, range: charRange)

        for (offset, c) in buffer.enumerated() where c == 0x0A || c == 0x09 || c == 0x3000 || c == 0x20 {
            let index = charRange.location + offset
            let glyph = glyphIndexForCharacter(at: index)
            let lineRect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let glyphRect = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            let font = (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont) ?? .systemFont(ofSize: 12)
            // 改行は文字の幅を持たないので、置かれる位置 (直前の文字の右) から測る
            let x = c == 0x0A
                ? origin.x + lineRect.minX + location(forGlyphAt: glyph).x
                : origin.x + glyphRect.minX
            let y = origin.y + lineRect.minY

            switch c {
            case 0x20:
                // 半角スペース: 下に小さな受け皿の形 (␣)
                let w = glyphRect.width
                let bottom = y + lineRect.height * 0.80
                let tick = max(2, lineRect.height * 0.12)
                let path = NSBezierPath()
                path.lineWidth = 0.8
                path.move(to: NSPoint(x: x + w * 0.2, y: bottom - tick))
                path.line(to: NSPoint(x: x + w * 0.2, y: bottom))
                path.line(to: NSPoint(x: x + w * 0.8, y: bottom))
                path.line(to: NSPoint(x: x + w * 0.8, y: bottom - tick))
                Theme.invisible.withAlphaComponent(0.7).setStroke()
                path.stroke()
            case 0x3000:
                let r = NSRect(x: x, y: y, width: glyphRect.width, height: lineRect.height)
                    .insetBy(dx: 2, dy: lineRect.height * 0.22)
                let path = NSBezierPath(rect: r)
                path.lineWidth = 0.8
                path.setLineDash([2, 2], count: 2, phase: 0)
                Theme.invisible.setStroke()
                path.stroke()
            default:
                let mark = (c == 0x0A ? "↓" : "›") as NSString
                let color = c == 0x0A ? Theme.newlineMark : Theme.invisible
                mark.draw(at: NSPoint(x: x + 1, y: y), withAttributes: [.font: font, .foregroundColor: color])
            }
        }
    }
}
