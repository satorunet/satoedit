import AppKit

/// 改行 (↓)・タブ (›)・全角スペース (□) を薄く描く
final class InvisiblesLayoutManager: NSLayoutManager {
    var showsInvisibles = true {
        didSet { if oldValue != showsInvisibles { invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0)) } }
    }

    /// 作文用紙では選択の塗りを自前で描くので、標準の塗り (枠線を隠してしまう) を止める
    var suppressesSelectionFill = false

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        if suppressesSelectionFill { return }
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

/// 作文用紙モード: 半角スペースとタブも「1 マスの空き」として並べる。
/// そのままだと列の終わりのスペースが用紙の外にぶら下がったり、タブが 2 マス分進んだりするので、
/// 画面に出す字形だけを全角スペースの字形に替える (文章そのものは変えない)。
final class GenkoGlyphDelegate: NSObject, NSLayoutManagerDelegate {
    static let shared = GenkoGlyphDelegate()

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = layoutManager.textStorage else { return 0 }
        let ns = storage.string as NSString
        let n = glyphRange.length
        var needs = false
        for i in 0..<n {
            let ci = charIndexes[i]
            if ci < ns.length, ns.character(at: ci) == 0x20 || ns.character(at: ci) == 0x09 { needs = true; break }
        }
        guard needs else { return 0 }
        var ideo: unichar = 0x3000
        var blank: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(aFont as CTFont, &ideo, &blank, 1) else { return 0 }
        var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: n))
        var newProps = Array(UnsafeBufferPointer(start: props, count: n))
        for i in 0..<n {
            let ci = charIndexes[i]
            guard ci < ns.length else { continue }
            let c = ns.character(at: ci)
            if c == 0x20 || c == 0x09 {
                newGlyphs[i] = blank
                // 空白・制御文字としての扱いをやめて、普通の 1 文字として並べる
                newProps[i].remove(.elastic)
                newProps[i].remove(.controlCharacter)
            }
        }
        layoutManager.setGlyphs(newGlyphs, properties: newProps, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        return n
    }
}
