import AppKit

/// テキストビュー上側の桁ルーラー (秀丸の「ルーラー」)。
/// 半角 1 文字ごとに目盛り、5 桁ごとに中目盛り、10 桁ごとに数字。カーソルの桁を強調する。
final class ColumnRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)

    override var isFlipped: Bool { true }

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .horizontalRuler)
        clientView = textView
        ruleThickness = 18
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(redraw), name: NSTextView.didChangeSelectionNotification, object: textView)
        nc.addObserver(self, selector: #selector(redraw), name: NSText.didChangeNotification, object: textView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        nc.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        textView.postsFrameChangedNotifications = true
        nc.addObserver(self, selector: #selector(redraw), name: NSView.frameDidChangeNotification, object: textView)
    }

    required init(coder: NSCoder) { fatalError() }

    @objc func redraw() { needsDisplay = true }

    // テキストビューが書式ルーラーの部品を載せようとしても受け付けない
    override var accessoryView: NSView? {
        get { nil }
        set { }
    }
    override func addMarker(_ marker: NSRulerMarker) {}
    override var reservedThicknessForAccessoryView: CGFloat {
        get { 0 }
        set { }
    }
    override var reservedThicknessForMarkers: CGFloat {
        get { 0 }
        set { }
    }
    override var markers: [NSRulerMarker]? {
        get { nil }
        set { }
    }

    override var requiredThickness: CGFloat { ruleThickness }

    /// 半角 1 桁の幅
    private var columnWidth: CGFloat {
        let font = textView?.font ?? Theme.font
        let w = ("0" as NSString).size(withAttributes: [.font: font]).width
        return w > 0 ? w : 8
    }

    /// カーソル位置の x (テキストビュー座標)
    private func caretX(in tv: NSTextView) -> CGFloat? {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        let ns = tv.string as NSString
        let loc = tv.selectedRange().location
        let x: CGFloat
        if loc < ns.length {
            let g = lm.glyphIndexForCharacter(at: loc)
            let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            x = frag.minX + lm.location(forGlyphAt: g).x
        } else if ns.length == 0 || ns.character(at: ns.length - 1) == 0x0A {
            x = lm.extraLineFragmentRect.minX + tc.lineFragmentPadding
        } else {
            let g = lm.glyphIndexForCharacter(at: ns.length - 1)
            x = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc).maxX
        }
        return x + tv.textContainerOrigin.x
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        Theme.gutterBackground.setFill()
        bounds.fill()
        Theme.gutterSeparator.setFill()
        NSRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()

        guard let tv = textView, let tc = tv.textContainer else { return }
        let cw = columnWidth
        // 0 桁目の左端 (ルーラー座標)
        let zeroX = convert(NSPoint(x: tv.textContainerOrigin.x + tc.lineFragmentPadding, y: 0), from: tv).x
        let bottom = bounds.maxY - 1

        // カーソルの桁
        if let cx = caretX(in: tv) {
            let x = convert(NSPoint(x: cx, y: 0), from: tv).x
            Theme.selection.setFill()
            NSRect(x: x, y: bounds.minY, width: cw, height: bottom - bounds.minY).fill()
        }

        // 折り返し位置
        if tc.widthTracksTextView {
            let wrapX = convert(NSPoint(x: tv.textContainerOrigin.x + tc.containerSize.width - tc.lineFragmentPadding, y: 0), from: tv).x
            Theme.newlineMark.setFill()
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: wrapX - 4, y: bounds.minY + 2))
            tri.line(to: NSPoint(x: wrapX + 4, y: bounds.minY + 2))
            tri.line(to: NSPoint(x: wrapX, y: bounds.minY + 8))
            tri.close()
            tri.fill()
        }

        let first = max(0, Int(floor((rect.minX - zeroX) / cw)))
        let last = Int(ceil((rect.maxX - zeroX) / cw))
        guard last >= first else { return }
        let tick = NSBezierPath()
        tick.lineWidth = 1
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: Theme.gutterText]
        for col in first...last {
            let x = floor(zeroX + CGFloat(col) * cw) + 0.5
            let h: CGFloat = col % 10 == 0 ? 9 : (col % 5 == 0 ? 6 : 3)
            tick.move(to: NSPoint(x: x, y: bottom))
            tick.line(to: NSPoint(x: x, y: bottom - h))
            if col % 10 == 0 && col > 0 {
                ("\(col)" as NSString).draw(at: NSPoint(x: x + 2, y: bounds.minY), withAttributes: labelAttrs)
            }
        }
        Theme.gutterText.withAlphaComponent(0.7).setStroke()
        tick.stroke()
    }
}
