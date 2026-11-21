import UIKit
import HinokiCore

/// 標準エディタの文字の面。行番号 (折り返しても 1 行は 1 つの番号) を左に出せる。
final class EditorTextView: UITextView {
    private let gutter = LineGutterView()
    private var lineIndex = LineIndex("" as NSString)
    private var indexedText = ""

    var showsLineNumbers = false {
        didSet { updateGutter() }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        gutter.owner = self
        gutter.isUserInteractionEnabled = false
        addSubview(gutter)
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        smartQuotesType = .no
        smartDashesType = .no
        autocorrectionType = .default
        textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 40, right: 10)
        backgroundColor = UIColor(hex: EditorTheme.light["background"]!)
        textColor = UIColor(hex: EditorTheme.light["text"]!)
        tintColor = .systemBlue
    }

    required init?(coder: NSCoder) { fatalError() }

    var gutterWidth: CGFloat {
        let digits = max(2, String(lineIndex.lineCount).count)
        return CGFloat(digits) * ((font?.pointSize ?? 17) * 0.62) + 14
    }

    func textDidChange() {
        if indexedText != text {
            lineIndex = LineIndex(text as NSString)
            indexedText = text
        }
        updateGutter()
    }

    private func updateGutter() {
        if indexedText != text { lineIndex = LineIndex(text as NSString); indexedText = text }
        gutter.isHidden = !showsLineNumbers
        let left: CGFloat = showsLineNumbers ? gutterWidth + 6 : 10
        if textContainerInset.left != left {
            textContainerInset = UIEdgeInsets(top: 12, left: left, bottom: 40, right: 10)
        }
        setNeedsLayout()
        gutter.setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard showsLineNumbers else { return }
        let f = CGRect(x: contentOffset.x, y: contentOffset.y, width: gutterWidth, height: bounds.height)
        if gutter.frame != f { gutter.frame = f }
        bringSubviewToFront(gutter)
        gutter.setNeedsDisplay()
    }

    /// 見えている行の番号を描く (gutter の座標で)
    fileprivate func drawLineNumbers(in ctx: CGContext, rect: CGRect) {
        ctx.setFillColor(UIColor(hex: EditorTheme.light["gutterBackground"]!).cgColor)
        ctx.fill(rect)
        ctx.setFillColor(UIColor(hex: EditorTheme.light["gutterSeparator"]!).cgColor)
        ctx.fill(CGRect(x: rect.maxX - 0.5, y: 0, width: 0.5, height: rect.height))
        let lm = layoutManager
        let ns = text as NSString
        let visible = CGRect(x: 0, y: contentOffset.y - textContainerInset.top, width: bounds.width, height: bounds.height)
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: textContainer)
        let numberFont = UIFont.monospacedDigitSystemFont(ofSize: max(10, (font?.pointSize ?? 17) * 0.72), weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: UIColor(hex: EditorTheme.light["gutterText"]!)]
        let caretLine = lineIndex.lineNumber(at: selectedRange.location)
        let currentAttrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: UIColor(hex: EditorTheme.light["gutterCurrentText"]!)]
        func draw(_ n: Int, lineRect: CGRect) {
            let s = String(n + 1) as NSString
            let a = n == caretLine ? currentAttrs : attrs
            let size = s.size(withAttributes: a)
            let y = lineRect.minY + textContainerInset.top - contentOffset.y + (lineRect.height - size.height) / 2
            s.draw(at: CGPoint(x: rect.width - size.width - 6, y: y), withAttributes: a)
        }
        lm.enumerateLineFragments(forGlyphRange: glyphs) { r, _, _, g, _ in
            let ci = lm.characterIndexForGlyph(at: g.location)
            guard ci == 0 || (ci <= ns.length && ns.character(at: ci - 1) == 0x0A) else { return }
            draw(self.lineIndex.lineNumber(at: ci), lineRect: r)
        }
        // 最後の空の行 (改行で終わっているとき)
        if ns.length == 0 || ns.character(at: ns.length - 1) == 0x0A {
            let r = lm.extraLineFragmentRect
            if r.height > 0 { draw(lineIndex.lineCount - 1, lineRect: r) }
        }
    }
}

private final class LineGutterView: UIView {
    weak var owner: EditorTextView?
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        owner?.drawLineNumbers(in: ctx, rect: bounds)
    }
}
