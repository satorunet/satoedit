import UIKit
import CoreText
import HinokiCore

/// 原稿用紙 1 枚を描く。Mac 版 GenkoView.swift の GenkoRenderer を UIKit に移したもの (寸法・色・字の置き方は同じ)。
/// 座標は左上が原点で y が下向き。長さは mm で考えて、u (1 mm の長さ) を掛ける。
enum GenkoRenderer {
    /// 罫線の色: 縦書きは朱、横書きは緑
    static let lineColor = UIColor(red: 0.80, green: 0.45, blue: 0.35, alpha: 1)
    static let horizontalLineColor = UIColor(red: 0.22, green: 0.55, blue: 0.36, alpha: 1)
    static func lineColor(horizontal: Bool) -> UIColor { horizontal ? horizontalLineColor : lineColor }
    static let paperColor = UIColor(red: 1.0, green: 0.992, blue: 0.97, alpha: 1)
    static let ink = UIColor(white: 0.07, alpha: 1)
    static let rubyInk = UIColor(white: 0.2, alpha: 1)
    static let selectionColor = UIColor(red: 0.25, green: 0.55, blue: 1.0, alpha: 0.28)
    static let deskColor = UIColor(white: 0.55, alpha: 1)

    /// 作文の自動整形は縦書きの決まりなので、横書きの原稿用紙では使わない
    static func autoFormat(horizontal: Bool) -> Bool { Prefs.genkoAutoFormat && !horizontal }

    struct Marks {
        var selection: NSRange?
        var marked: NSRange?
    }

    static func font(_ size: CGFloat) -> UIFont {
        UIFont(name: "HiraMinProN-W3", size: size) ?? .systemFont(ofSize: size)
    }

    /// 縦書きの 1 文字 (縦書き用の字形を使うため、CoreText の縦組みで作って 90° 回す)
    static func drawVertical(_ s: String, center: CGPoint, size: CGFloat, color: UIColor, in ctx: CGContext) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
            .font: font(size), .foregroundColor: color, .verticalGlyphForm: true,
        ]))
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.rotate(by: -.pi / 2)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: -advance / 2, y: 0)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    static func drawHorizontal(_ s: String, center: CGPoint, font: UIFont, color: UIColor, in ctx: CGContext) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: -width / 2, y: -(font.ascender + font.descender) / 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func textWidth(_ s: String, _ font: UIFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font])), nil, nil, nil))
    }

    static func isHalfWidth(_ s: String) -> Bool { s.utf16.count == 1 && (s.utf16.first ?? 0) < 0x2000 }

    static func columnX(_ k: Int, horizontal: Bool) -> Double {
        guard horizontal else { return Genko.columnX(k) }
        return Genko.columnX(k) + (k >= Genko.columnsPerSheet / 2 ? Genko.Sheet.center : 0) - Genko.Sheet.center / 2
    }

    static func gridSpan(horizontal: Bool) -> (x: Double, width: Double) {
        horizontal ? (Genko.Sheet.left + Genko.Sheet.center / 2, Genko.Sheet.gridWidth - Genko.Sheet.center)
                   : (Genko.Sheet.left, Genko.Sheet.gridWidth)
    }

    /// 用紙 1 枚の大きさ (pt)。縦書きは A4 横、横書きは A4 縦
    static func sheetSize(u: CGFloat, horizontal: Bool) -> CGSize {
        let w = CGFloat(Genko.Sheet.width) * u, h = CGFloat(Genko.Sheet.height) * u
        return horizontal ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// 縦書きの用紙の上の位置 (mm) → 描く位置。横書きは縦書きの用紙を回して作る
    static func point(_ xv: Double, _ yv: Double, origin: CGPoint, u: CGFloat, horizontal: Bool) -> CGPoint {
        horizontal ? CGPoint(x: origin.x + CGFloat(yv) * u, y: origin.y + CGFloat(Genko.Sheet.width - xv) * u)
                   : CGPoint(x: origin.x + CGFloat(xv) * u, y: origin.y + CGFloat(yv) * u)
    }

    static func rect(_ xv: Double, _ yv: Double, _ w: Double, _ h: Double, origin: CGPoint, u: CGFloat, horizontal: Bool) -> CGRect {
        let a = point(xv, yv, origin: origin, u: u, horizontal: horizontal)
        let b = point(xv + w, yv + h, origin: origin, u: u, horizontal: horizontal)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// index 枚目 (0 始まり) を描く
    static func drawSheet(_ index: Int, of total: Int, columns: [Genko.Column], ruby: [Int: [Genko.RubyPlacement]],
                          at origin: CGPoint, u: CGFloat, paper: UIColor, marks: Marks = Marks(), horizontal: Bool = false, in ctx: CGContext) {
        typealias S = Genko.Sheet
        func P(_ x: Double, _ y: Double) -> CGPoint { point(x, y, origin: origin, u: u, horizontal: horizontal) }
        func R(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { rect(x, y, w, h, origin: origin, u: u, horizontal: horizontal) }
        let cell = CGFloat(S.cell) * u
        let y0 = S.top, y1 = S.top + S.gridHeight
        let firstColumn = index * Genko.columnsPerSheet

        ctx.saveGState()
        ctx.setFillColor(paper.cgColor)
        ctx.fill(CGRect(origin: origin, size: sheetSize(u: u, horizontal: horizontal)))

        if let range = marks.selection, range.length > 0 {
            ctx.setFillColor(selectionColor.cgColor)
            for k in 0..<Genko.columnsPerSheet where firstColumn + k < columns.count {
                let col = columns[firstColumn + k]
                let x = columnX(k, horizontal: horizontal)
                for r in 0..<Genko.rows where col.offs[r] >= 0 && NSLocationInRange(col.offs[r], range) {
                    ctx.fill(R(x, y0 + Double(r) * S.cell, S.cell, S.cell))
                }
                if col.last, NSLocationInRange(col.to, range), col.end < Genko.rows {
                    ctx.fill(R(x, y0 + Double(col.end) * S.cell, S.cell, S.cell))
                }
            }
        }

        // 細い線
        let lineColor = lineColor(horizontal: horizontal)
        ctx.setStrokeColor(lineColor.cgColor)
        ctx.setLineWidth(max(0.4, 0.18 * u))
        for k in 0..<Genko.columnsPerSheet {
            let x = columnX(k, horizontal: horizontal)
            for vx in [x, x + S.cell, x + S.pitch] {
                ctx.move(to: P(vx, y0))
                ctx.addLine(to: P(vx, y1))
            }
            for r in 1..<Genko.rows {
                let y = y0 + Double(r) * S.cell
                ctx.move(to: P(x, y))
                ctx.addLine(to: P(x + S.cell, y))
            }
        }
        ctx.strokePath()
        // 中央の魚尾 (縦書きだけ)
        let cx = Genko.columnX(Genko.columnsPerSheet / 2 - 1) - S.center / 2
        ctx.setLineWidth(max(0.5, 0.3 * u))
        for fy in horizontal ? [] : [y0 + S.gridHeight * 0.25, y0 + S.gridHeight * 0.7] {
            ctx.move(to: P(cx - 3.2, fy))
            ctx.addLine(to: P(cx + 3.2, fy))
            ctx.move(to: P(cx - 3.2, fy + 5))
            ctx.addLine(to: P(cx, fy + 2.6))
            ctx.addLine(to: P(cx + 3.2, fy + 5))
        }
        ctx.strokePath()
        // 外枠
        ctx.setLineWidth(max(1, 0.6 * u))
        let span = gridSpan(horizontal: horizontal)
        ctx.stroke(R(span.x, y0, span.width, S.gridHeight))

        // 文字とふりがな
        let size = cell * 0.72
        let full = font(size)
        for k in 0..<Genko.columnsPerSheet where firstColumn + k < columns.count {
            let col = columns[firstColumn + k]
            let x = columnX(k, horizontal: horizontal)
            for rb in ruby[firstColumn + k] ?? [] {
                let chars = Array(rb.text)
                guard !chars.isEmpty else { continue }
                let height = Double(rb.rows) * S.cell
                let rsize = min(S.ruby * 0.8, (height - 0.4) / Double(chars.count))
                let top = y0 + Double(rb.row) * S.cell + (height - rsize * Double(chars.count)) / 2
                for (i, ch) in chars.enumerated() {
                    let c = P(x + S.cell + S.ruby / 2, top + (Double(i) + 0.5) * rsize)
                    if horizontal {
                        drawHorizontal(String(ch), center: c, font: font(CGFloat(rsize) * u), color: rubyInk, in: ctx)
                    } else {
                        drawVertical(String(ch), center: c, size: CGFloat(rsize) * u, color: rubyInk, in: ctx)
                    }
                }
            }
            for r in 0..<Genko.rows {
                guard let ch = col.cells[r], ch != " ", ch != "\t" else { continue }
                let center = P(x + S.cell / 2, y0 + (Double(r) + 0.5) * S.cell)
                if isHalfWidth(ch) || horizontal {
                    drawHorizontal(ch, center: center, font: full, color: ink, in: ctx)
                } else {
                    drawVertical(ch, center: center, size: size, color: ink, in: ctx)
                }
            }
            // 変換中の文字には下線 (縦書きは字の右、横書きは字の下)
            if let m = marks.marked, m.length > 0 {
                for r in 0..<Genko.rows where col.offs[r] >= 0 && NSLocationInRange(col.offs[r], m) {
                    ctx.setStrokeColor(ink.cgColor)
                    ctx.setLineWidth(0.3 * u)
                    let lx = horizontal ? x + 0.55 : x + S.cell - 0.55
                    ctx.move(to: P(lx, y0 + Double(r) * S.cell + 0.7))
                    ctx.addLine(to: P(lx, y0 + Double(r + 1) * S.cell - 0.7))
                    ctx.strokePath()
                }
            }
        }

        // 用紙の下の小さな表示
        let small = UIFont.systemFont(ofSize: 2.6 * u)
        let frame = R(span.x, y0, span.width, S.gridHeight)
        let labelY = frame.maxY + (2 + 1.6) * u
        let left = "20 × 20", right = "No. \(index + 1) / \(total)"
        drawHorizontal(left, center: CGPoint(x: frame.minX + textWidth(left, small) / 2, y: labelY), font: small, color: lineColor, in: ctx)
        drawHorizontal(right, center: CGPoint(x: frame.maxX - textWidth(right, small) / 2, y: labelY), font: small, color: lineColor, in: ctx)
        ctx.restoreGState()
    }
}

/// 原稿用紙の画面: 用紙を縦に並べてスクロールする。ピンチで拡大・縮小、マスをタップするとそこにカーソル。
/// 文章そのものは持たず、エディタ (UITextView) の文章・選択をそのまま映す。
final class GenkoPaperView: UIScrollView {
    private(set) var columns: [Genko.Column] = []
    private var rubyByColumn: [Int: [Genko.RubyPlacement]] = [:]
    private var sheets: [GenkoSheetView] = []
    private(set) var u: CGFloat = 1.2
    /// ピンチで決める拡大率 (1 = 幅いっぱい)
    private var zoom: CGFloat = 1
    private var pinchStart: CGFloat = 1

    var text = "" { didSet { if text != oldValue { reload() } } }
    var selection = NSRange(location: 0, length: 0) { didSet { if selection != oldValue { redrawMarks() } } }
    var marked: NSRange? { didSet { if marked != oldValue { redrawMarks() } } }
    var horizontal = false { didSet { if horizontal != oldValue { reload() } } }
    var showsCaret = false { didSet { if showsCaret != oldValue { redrawMarks() } } }
    var ruby: [Genko.Ruby] = [] { didSet { if ruby != oldValue { reload() } } }
    /// マスをタップしたとき (文章の位置)
    var onTap: ((Int) -> Void)?

    static let pad: CGFloat = 12
    static let gap: CGFloat = 14

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = GenkoRenderer.deskColor
        alwaysBounceVertical = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        accessibilityIdentifier = "genko"
    }

    required init?(coder: NSCoder) { fatalError() }

    private var autoFormat: Bool { GenkoRenderer.autoFormat(horizontal: horizontal) }

    func reload() {
        columns = Genko.layout(text, autoFormat: autoFormat)
        rubyByColumn = Genko.placeRuby(columns, ruby)
        layoutSheets()
        for s in sheets { s.setNeedsDisplay() }
    }

    private var lastWidth: CGFloat = 0
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width != lastWidth {
            lastWidth = bounds.width
            layoutSheets()
        }
    }

    private var sheetSize: CGSize { GenkoRenderer.sheetSize(u: u, horizontal: horizontal) }

    /// 幅いっぱいに合わせたとき、用紙 1 枚がちょうど入る高さ
    func fittedHeight(width: CGFloat) -> CGFloat {
        let fitU = (width - Self.pad * 2) / CGFloat(horizontal ? Genko.Sheet.height : Genko.Sheet.width)
        return GenkoRenderer.sheetSize(u: max(0.8, min(6, fitU)), horizontal: horizontal).height + Self.pad * 2
    }

    private func layoutSheets() {
        guard bounds.width > 0 else { return }
        let fitU = (bounds.width - Self.pad * 2) / CGFloat(horizontal ? Genko.Sheet.height : Genko.Sheet.width)
        let newU = max(0.8, min(6, fitU * zoom))
        let uChanged = newU != u
        u = newU
        let n = Genko.sheetCount(columns)
        while sheets.count < n {
            let s = GenkoSheetView()
            s.owner = self
            addSubview(s)
            sheets.append(s)
        }
        while sheets.count > n { sheets.removeLast().removeFromSuperview() }
        let size = sheetSize
        let x = max(Self.pad, floor((bounds.width - size.width) / 2))
        for (i, s) in sheets.enumerated() {
            s.index = i
            let f = CGRect(x: x, y: Self.pad + CGFloat(i) * (size.height + Self.gap), width: size.width, height: size.height)
            if s.frame != f { s.frame = f; s.setNeedsDisplay() }
            if uChanged { s.setNeedsDisplay() }
        }
        contentSize = CGSize(width: max(bounds.width, size.width + Self.pad * 2), height: Self.pad * 2 + CGFloat(n) * size.height + CGFloat(max(0, n - 1)) * Self.gap)
    }

    private func redrawMarks() { for s in sheets { s.setNeedsDisplay() } }

    // MARK: 描く (1 枚ずつ)

    fileprivate func draw(sheet index: Int, in ctx: CGContext) {
        var marks = GenkoRenderer.Marks()
        if selection.length > 0 { marks.selection = selection }
        marks.marked = marked
        GenkoRenderer.drawSheet(index, of: sheets.count, columns: columns, ruby: rubyByColumn, at: .zero, u: u,
                                paper: GenkoRenderer.paperColor, marks: marks, horizontal: horizontal, in: ctx)
        if showsCaret, selection.length == 0 || marked != nil {
            let head = marked.map { NSMaxRange($0) } ?? selection.location
            let (sheet, r) = caretRect(at: head)
            if sheet == index {
                ctx.setFillColor(UIColor.systemBlue.cgColor)
                ctx.fill(r)
            }
        }
    }

    /// 文章の位置 → カーソルの線 (その用紙の中の座標)
    private func caretRect(at offset: Int) -> (Int, CGRect) {
        let cell = Genko.caretCell(columns, offset: offset)
        let x = GenkoRenderer.columnX(cell.column % Genko.columnsPerSheet, horizontal: horizontal)
        let y = Genko.Sheet.top + Double(min(cell.row, Genko.rows)) * Genko.Sheet.cell
        let line = GenkoRenderer.rect(x + 0.4, y, Genko.Sheet.cell - 0.8, 0, origin: .zero, u: u, horizontal: horizontal)
        let w = max(2, u * 0.6)
        let r = horizontal ? CGRect(x: line.minX - w / 2, y: line.minY, width: w, height: line.height)
                           : CGRect(x: line.minX, y: line.minY - w / 2, width: line.width, height: w)
        return (cell.column / Genko.columnsPerSheet, r)
    }

    /// カーソルのマスが見えるようにスクロールする
    func revealCaret(animated: Bool = true) {
        let head = marked.map { NSMaxRange($0) } ?? selection.location
        let (sheet, r) = caretRect(at: head)
        guard sheet < sheets.count else { return }
        let cell = CGFloat(Genko.Sheet.cell) * u
        let rr = sheets[sheet].convert(r, to: self).insetBy(dx: -cell * 1.5, dy: -cell * 1.5)
        scrollRectToVisible(rr, animated: animated)
    }

    // MARK: タップ・ピンチ

    /// 用紙の上の位置 → 文章の位置 (Mac 版と同じ決め方)
    func offset(at point: CGPoint) -> Int? {
        guard let sheet = sheets.firstIndex(where: { $0.frame.insetBy(dx: -Self.gap / 2, dy: -Self.gap / 2).contains(point) }) else { return nil }
        let o = sheets[sheet].frame.origin
        let px = Double((point.x - o.x) / u), py = Double((point.y - o.y) / u)
        let xmm = horizontal ? Genko.Sheet.width - py : px, ymm = horizontal ? px : py
        var k = 0
        var distance = Double.infinity
        for i in 0..<Genko.columnsPerSheet {
            let d = abs(GenkoRenderer.columnX(i, horizontal: horizontal) + Genko.Sheet.pitch / 2 - xmm)
            if d < distance { distance = d; k = i }
        }
        let column = sheet * Genko.columnsPerSheet + k
        if column >= columns.count { return (text as NSString).length }
        let row = max(0, min(Genko.rows, Int(floor((ymm - Genko.Sheet.top) / Genko.Sheet.cell + 0.35))))
        return Genko.offsetAt(columns, column: column, row: row)
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        if let off = offset(at: g.location(in: self)) { onTap?(off) }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchStart = zoom
        case .changed, .ended:
            let anchor = g.location(in: self)
            let rel = CGPoint(x: anchor.x / max(1, contentSize.width), y: anchor.y / max(1, contentSize.height))
            let inView = CGPoint(x: anchor.x - contentOffset.x, y: anchor.y - contentOffset.y)
            zoom = max(0.6, min(4, pinchStart * g.scale))
            layoutSheets()
            // 指のところが動かないように
            let nx = rel.x * contentSize.width - inView.x, ny = rel.y * contentSize.height - inView.y
            contentOffset = CGPoint(x: max(0, min(nx, contentSize.width - bounds.width)), y: max(-adjustedContentInset.top, min(ny, max(0, contentSize.height - bounds.height + adjustedContentInset.bottom))))
        default: break
        }
    }

    /// いちばん多く見えている用紙の画像 (スクリーンショット・動作確認用)
    func visibleSheetIndex() -> Int {
        let visible = CGRect(origin: contentOffset, size: bounds.size)
        var best = 0, bestArea: CGFloat = -1
        for (i, s) in sheets.enumerated() {
            let r = s.frame.intersection(visible)
            let a = r.isNull ? 0 : r.width * r.height
            if a > bestArea { best = i; bestArea = a }
        }
        return best
    }
}

final class GenkoSheetView: UIView {
    weak var owner: GenkoPaperView?
    var index = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 5
        layer.shadowOffset = CGSize(width: 0, height: 2)
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        owner?.draw(sheet: index, in: ctx)
    }
}

/// 一覧の印: 原稿用紙 (縦書きは朱、横書きは緑) とエディタの紙。Mac 版 TextLibrary の genkoMark / pageMark と同じ形
enum ModeIcon {
    static func image(mode: String?, size: CGFloat, shared: Bool = false) -> UIImage {
        let r = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return r.image { c in
            let ctx = c.cgContext
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            if mode == "genko" || mode == "genkoH" {
                let horizontal = mode == "genkoH"
                let color = GenkoRenderer.lineColor(horizontal: horizontal)
                let box = rect.insetBy(dx: 1, dy: 1)
                ctx.setFillColor(GenkoRenderer.paperColor.cgColor)
                ctx.fill(box)
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(1.4)
                ctx.stroke(box)
                ctx.setLineWidth(0.9)
                for i in 1..<3 {
                    let t = CGFloat(i) / 3
                    if horizontal {
                        let y = box.minY + box.height * t
                        for dy in [-1.0, 1.0] { ctx.move(to: CGPoint(x: box.minX, y: y + CGFloat(dy))); ctx.addLine(to: CGPoint(x: box.maxX, y: y + CGFloat(dy))) }
                        let x = box.minX + box.width * t
                        ctx.move(to: CGPoint(x: x, y: box.minY)); ctx.addLine(to: CGPoint(x: x, y: box.maxY))
                    } else {
                        let x = box.minX + box.width * t
                        for dx in [-1.0, 1.0] { ctx.move(to: CGPoint(x: x + CGFloat(dx), y: box.minY)); ctx.addLine(to: CGPoint(x: x + CGFloat(dx), y: box.maxY)) }
                        let y = box.minY + box.height * t
                        ctx.move(to: CGPoint(x: box.minX, y: y)); ctx.addLine(to: CGPoint(x: box.maxX, y: y))
                    }
                }
                ctx.strokePath()
            } else {
                let color = UIColor(red: 0.33, green: 0.42, blue: 0.62, alpha: 1)
                let w = size * 0.74
                let page = CGRect(x: rect.midX - w / 2, y: 1, width: w, height: size - 2)
                let fold = page.width * 0.32
                let p = UIBezierPath()
                p.move(to: CGPoint(x: page.minX, y: page.minY))
                p.addLine(to: CGPoint(x: page.maxX - fold, y: page.minY))
                p.addLine(to: CGPoint(x: page.maxX, y: page.minY + fold))
                p.addLine(to: CGPoint(x: page.maxX, y: page.maxY))
                p.addLine(to: CGPoint(x: page.minX, y: page.maxY))
                p.close()
                UIColor.white.setFill()
                p.fill()
                color.setStroke()
                p.lineWidth = 1.3
                p.stroke()
                let lines = UIBezierPath()
                lines.lineWidth = 1.1
                for k in 0..<3 {
                    let y = page.minY + page.height * (0.42 + CGFloat(k) * 0.18)
                    lines.move(to: CGPoint(x: page.minX + 3, y: y))
                    lines.addLine(to: CGPoint(x: page.maxX - (k == 2 ? page.width * 0.4 : 3), y: y))
                }
                lines.stroke()
            }
            if shared {
                let b = size * 0.5
                let circle = CGRect(x: size - b, y: size - b, width: b, height: b)
                ctx.setFillColor(UIColor.systemBlue.cgColor)
                ctx.fillEllipse(in: circle)
                if let sym = UIImage(systemName: "link", withConfiguration: UIImage.SymbolConfiguration(pointSize: b * 0.5, weight: .bold))?
                    .withTintColor(.white, renderingMode: .alwaysOriginal) {
                    sym.draw(in: CGRect(x: circle.midX - sym.size.width / 2, y: circle.midY - sym.size.height / 2, width: sym.size.width, height: sym.size.height))
                }
            }
        }
    }
}
