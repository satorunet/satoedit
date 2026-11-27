import AppKit
import HinokiCore

/// 原稿用紙 1 枚を描く。画面・PDF・画像のどれも同じこの描き方を使うので、必ず同じマスに同じ字が入る。
/// 座標は左上が原点で y が下向き。長さは mm で考えて、u (1 mm の長さ) を掛ける。
enum GenkoRenderer {
    /// 罫線の色: 縦書きは朱、横書きは緑 (よくある横書きの原稿用紙の色)
    static let lineColor = NSColor(srgbRed: 0.80, green: 0.45, blue: 0.35, alpha: 1)
    static let horizontalLineColor = NSColor(srgbRed: 0.22, green: 0.55, blue: 0.36, alpha: 1)
    static func lineColor(horizontal: Bool) -> NSColor { horizontal ? horizontalLineColor : lineColor }

    /// 作文の自動整形 (題名 3 マス下げ・名前 下寄せ・段落 1 マス下げ) を使うか。縦書きの決まりなので、横書きの原稿用紙では使わない
    static func autoFormat(horizontal: Bool) -> Bool {
        UserDefaults.standard.bool(forKey: "genkoAutoFormat") && !horizontal
    }
    static let paperColor = NSColor(srgbRed: 1.0, green: 0.992, blue: 0.97, alpha: 1)
    static let ink = NSColor(white: 0.07, alpha: 1)
    static let rubyInk = NSColor(white: 0.2, alpha: 1)
    static let selectionColor = NSColor(srgbRed: 0.25, green: 0.55, blue: 1.0, alpha: 0.28)

    /// 文字のほかに重ねて描くもの (文章の位置で指定)
    struct Marks {
        /// 選択
        var selection: NSRange?
        /// 日本語入力の変換中の範囲と、その中で選ばれている文節
        var marked: NSRange?
        var markedClause: NSRange?
        /// 共同編集の相手の選択
        var remote: [(range: NSRange, color: NSColor)] = []
        /// まだ見せていない文字 (AI の答えを 1 字ずつ見せている間)
        var hidden: NSRange?
    }

    static func font(_ size: CGFloat) -> NSFont {
        NSFont(name: "HiraMinProN-W3", size: size) ?? .systemFont(ofSize: size)
    }

    /// 字の形 (CTLine) と幅を覚えておく。用紙 1 枚 400 字を描くたびに作り直すと遅い (1 枚 17 ms → 2 ms)
    private struct GlyphKey: Hashable {
        var text: String
        var font: String
        var size: CGFloat
        var vertical: Bool
        var color: ObjectIdentifier
    }
    private static var glyphs: [GlyphKey: (line: CTLine, width: CGFloat)] = [:]
    private static let glyphLock = NSLock()
    private static var fonts: [CGFloat: NSFont] = [:]

    private static func glyph(_ s: String, font: NSFont, vertical: Bool, color: NSColor) -> (line: CTLine, width: CGFloat) {
        let key = GlyphKey(text: s, font: font.fontName, size: font.pointSize, vertical: vertical, color: ObjectIdentifier(color))
        glyphLock.lock()
        defer { glyphLock.unlock() }
        if let g = glyphs[key] { return g }
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if vertical { attrs[.verticalGlyphForm] = true }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        let g = (line, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        // 大きさを変え続けたときに増え続けないように
        if glyphs.count > 20000 { glyphs.removeAll(keepingCapacity: true) }
        glyphs[key] = g
        return g
    }

    /// 明朝体 (大きさごとに覚えておく)
    private static func cachedFont(_ size: CGFloat) -> NSFont {
        glyphLock.lock()
        defer { glyphLock.unlock() }
        if let f = fonts[size] { return f }
        if fonts.count > 200 { fonts.removeAll() }
        let f = font(size)
        fonts[size] = f
        return f
    }

    /// 縦書きの 1 文字を、center がマスの真ん中に来るように描く。
    /// 縦書き用の字形 (句読点は右上、かっこ・長音は縦向き) を使うため、字を横に寝かせて並べる CoreText の縦組みで作り、90° 回して立てる。
    static func drawVertical(_ s: String, center: CGPoint, size: CGFloat, color: NSColor, in ctx: CGContext) {
        let (line, advance) = glyph(s, font: cachedFont(size), vertical: true, color: color)
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.rotate(by: -.pi / 2)
        ctx.textMatrix = .identity
        // 縦組みの基準線は字の左右の真ん中を通る
        ctx.textPosition = CGPoint(x: -advance / 2, y: 0)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// 横向きの文字 (半角の英数字、用紙の下の小さな表示) を描く。center は文字の箱の真ん中
    static func drawHorizontal(_ s: String, center: CGPoint, font: NSFont, color: NSColor, in ctx: CGContext) {
        let (line, width) = glyph(s, font: font, vertical: false, color: color)
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: -width / 2, y: -(font.ascender + font.descender) / 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func textWidth(_ s: String, _ font: NSFont) -> CGFloat {
        glyph(s, font: font, vertical: false, color: ink).width
    }

    /// 半角の英数字など、立てずに横向きのままマスに入れる文字か
    static func isHalfWidth(_ s: String) -> Bool {
        s.utf16.count == 1 && (s.utf16.first ?? 0) < 0x2000
    }

    /// 列 k (横書きでは行 k) のマスの左端 (縦書きの用紙の上の mm)。
    /// 横書きの原稿用紙には真ん中の余白 (魚尾) がないので、20 行を詰めて、そのぶん全体を真ん中に寄せる
    static func columnX(_ k: Int, horizontal: Bool) -> Double {
        guard horizontal else { return Genko.columnX(k) }
        return Genko.columnX(k) + (k >= Genko.columnsPerSheet / 2 ? Genko.Sheet.center : 0) - Genko.Sheet.center / 2
    }

    /// マス目全体の枠 (縦書きの用紙の上の mm): x, 幅
    static func gridSpan(horizontal: Bool) -> (x: Double, width: Double) {
        horizontal ? (Genko.Sheet.left + Genko.Sheet.center / 2, Genko.Sheet.gridWidth - Genko.Sheet.center)
                   : (Genko.Sheet.left, Genko.Sheet.gridWidth)
    }

    /// 用紙 1 枚の大きさ (pt)。縦書きは A4 横、横書きは A4 縦
    static func sheetSize(u: CGFloat, horizontal: Bool) -> CGSize {
        let w = CGFloat(Genko.Sheet.width) * u, h = CGFloat(Genko.Sheet.height) * u
        return horizontal ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// 縦書きの用紙の上の位置 (mm) → 描く位置。
    /// 横書きの原稿用紙は、縦書きの用紙を回して作る: 縦書きの「右の列から左へ」が「上の行から下へ」、
    /// 「列の上から下へ」が「行の左から右へ」になり、列の右のふりがなの枠は行の上に来る
    static func point(_ xv: Double, _ yv: Double, origin: CGPoint, u: CGFloat, horizontal: Bool) -> CGPoint {
        horizontal ? CGPoint(x: origin.x + CGFloat(yv) * u, y: origin.y + CGFloat(Genko.Sheet.width - xv) * u)
                   : CGPoint(x: origin.x + CGFloat(xv) * u, y: origin.y + CGFloat(yv) * u)
    }

    static func rect(_ xv: Double, _ yv: Double, _ w: Double, _ h: Double, origin: CGPoint, u: CGFloat, horizontal: Bool) -> CGRect {
        let a = point(xv, yv, origin: origin, u: u, horizontal: horizontal)
        let b = point(xv + w, yv + h, origin: origin, u: u, horizontal: horizontal)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// index 枚目 (0 始まり) を描く。origin は用紙の左上。horizontal = 横書きの原稿用紙
    static func drawSheet(_ index: Int, of total: Int, columns: [Genko.Column], ruby: [Int: [Genko.RubyPlacement]],
                          at origin: CGPoint, u: CGFloat, paper: NSColor, marks: Marks = Marks(), horizontal: Bool = false,
                          blank: Bool = true, in ctx: CGContext) {
        typealias S = Genko.Sheet
        func P(_ x: Double, _ y: Double) -> CGPoint { point(x, y, origin: origin, u: u, horizontal: horizontal) }
        func R(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { rect(x, y, w, h, origin: origin, u: u, horizontal: horizontal) }
        let cell = CGFloat(S.cell) * u
        let y0 = S.top
        let firstColumn = index * Genko.columnsPerSheet

        ctx.saveGState()
        // 描き直す範囲 (カーソルの点滅などでは小さい)。外の列は描かない
        let clip = ctx.boundingBoxOfClipPath
        func visible(_ k: Int) -> Bool {
            R(columnX(k, horizontal: horizontal), y0, S.pitch, S.gridHeight).insetBy(dx: -2, dy: -2).intersects(clip)
        }
        if blank {
            ctx.setFillColor(paper.cgColor)
            ctx.fill(CGRect(origin: origin, size: sheetSize(u: u, horizontal: horizontal)))
        }

        // 選択: 字の入っているマスだけ。線より先に薄い色を敷く。
        // 罫線を描いた用紙の上に重ねるとき (blank = false) は「乗算」で重ねて、線が隠れないようにする (紙の上では同じ色になる)
        func fillCells(_ range: NSRange, _ color: NSColor) {
            guard range.length > 0 else { return }
            ctx.setFillColor(color.cgColor)
            for k in 0..<Genko.columnsPerSheet where firstColumn + k < columns.count && visible(k) {
                let col = columns[firstColumn + k]
                let x = columnX(k, horizontal: horizontal)
                for r in 0..<Genko.rows where col.offs[r] >= 0 && NSLocationInRange(col.offs[r], range) {
                    ctx.fill(R(x, y0 + Double(r) * S.cell, S.cell, S.cell))
                }
            }
        }
        if !blank { ctx.setBlendMode(.multiply) }
        if let sel = marks.selection { fillCells(sel, selectionColor) }
        for r in marks.remote { fillCells(r.range, r.color.withAlphaComponent(0.25)) }
        ctx.setBlendMode(.normal)
        if blank { drawGrid(origin: origin, u: u, horizontal: horizontal, in: ctx) }

        // 文字とふりがな (横書きでは字を立てずにそのまま書く)
        let size = cell * 0.72
        let half = cachedFont(size)
        let full = half
        for k in 0..<Genko.columnsPerSheet where firstColumn + k < columns.count && visible(k) {
            let col = columns[firstColumn + k]
            let x = columnX(k, horizontal: horizontal)
            for rb in ruby[firstColumn + k] ?? [] {
                let chars = Array(rb.text)
                guard !chars.isEmpty else { continue }
                let height = Double(rb.rows) * S.cell
                // 読みが長いときは、枠に収まるまで字を小さくする
                let rsize = min(S.ruby * 0.8, (height - 0.4) / Double(chars.count))
                let top = y0 + Double(rb.row) * S.cell + (height - rsize * Double(chars.count)) / 2
                for (i, ch) in chars.enumerated() {
                    let c = P(x + S.cell + S.ruby / 2, top + (Double(i) + 0.5) * rsize)
                    if horizontal {
                        drawHorizontal(String(ch), center: c, font: cachedFont(CGFloat(rsize) * u), color: rubyInk, in: ctx)
                    } else {
                        drawVertical(String(ch), center: c, size: CGFloat(rsize) * u, color: rubyInk, in: ctx)
                    }
                }
            }
            for r in 0..<Genko.rows {
                guard let ch = col.cells[r], ch != " ", ch != "\t" else { continue }
                if let h = marks.hidden, col.offs[r] >= 0, NSLocationInRange(col.offs[r], h) { continue }
                let center = P(x + S.cell / 2, y0 + (Double(r) + 0.5) * S.cell)
                if isHalfWidth(ch) {
                    drawHorizontal(ch, center: center, font: half, color: ink, in: ctx)
                } else if horizontal {
                    drawHorizontal(ch, center: center, font: full, color: ink, in: ctx)
                } else {
                    drawVertical(ch, center: center, size: size, color: ink, in: ctx)
                }
            }
            // 変換中の文字には下線 (縦書きは字の右、横書きは字の下) を引く。選ばれている文節は太く
            if let m = marks.marked, m.length > 0 {
                for r in 0..<Genko.rows where col.offs[r] >= 0 && NSLocationInRange(col.offs[r], m) {
                    let thick = marks.markedClause.map { $0.length > 0 && NSLocationInRange(col.offs[r], $0) } ?? false
                    ctx.setStrokeColor(ink.cgColor)
                    ctx.setLineWidth((thick ? 0.5 : 0.22) * u)
                    let lx = horizontal ? x + 0.55 : x + S.cell - 0.55
                    ctx.move(to: P(lx, y0 + Double(r) * S.cell + 0.7))
                    ctx.addLine(to: P(lx, y0 + Double(r + 1) * S.cell - 0.7))
                    ctx.strokePath()
                }
            }
        }

        // 用紙の下の小さな表示 (枠の左下と右下)
        let small = NSFont.systemFont(ofSize: 2.6 * u)
        let lineColor = lineColor(horizontal: horizontal)
        let span = gridSpan(horizontal: horizontal)
        let frame = R(span.x, y0, span.width, S.gridHeight)
        let labelY = frame.maxY + (2 + 1.6) * u
        let left = "20 × 20", right = "No. \(index + 1) / \(total)"
        drawHorizontal(left, center: CGPoint(x: frame.minX + textWidth(left, small) / 2, y: labelY), font: small, color: lineColor, in: ctx)
        drawHorizontal(right, center: CGPoint(x: frame.maxX - textWidth(right, small) / 2, y: labelY), font: small, color: lineColor, in: ctx)
        ctx.restoreGState()
    }

    /// 罫線・魚尾・外枠 (どの用紙も同じ。画面では一度描いたものを使い回す)
    static func drawGrid(origin: CGPoint, u: CGFloat, horizontal: Bool, in ctx: CGContext) {
        typealias S = Genko.Sheet
        func P(_ x: Double, _ y: Double) -> CGPoint { point(x, y, origin: origin, u: u, horizontal: horizontal) }
        func R(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { rect(x, y, w, h, origin: origin, u: u, horizontal: horizontal) }
        let y0 = S.top, y1 = S.top + S.gridHeight
        // 細い線: マスの左端・マスとふりがな枠の境・ふりがな枠の右端、マスの区切り
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
        // 中央の余白の魚尾 (上下の小さな印)。横書きには真ん中の余白がないので描かない
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
    }
}

/// 原稿用紙の編集画面。
/// 文章そのものは (画面から外した) EditorTextView が持ち、ここはマス目に 1 文字ずつ置いて見せる。
/// 入力・削除・取り消しは EditorTextView に頼むので、保存・検索・共同編集・AI などはいつもと同じように動く。
final class GenkoView: NSView, NSTextInputClient {
    private unowned let textView: EditorTextView
    /// 文字の面がまだあるか (タブを閉じた後に、待っていた処理が消えた面に触れて落ちないように)
    private weak var textViewAlive: EditorTextView?
    private(set) var columns: [Genko.Column] = []
    private var rubyByColumn: [Int: [Genko.RubyPlacement]] = [:]
    /// 1 mm の長さ (pt)。ウインドウの幅に合わせて決める
    private(set) var u: CGFloat = 3
    /// 日本語入力の変換中の文字 (確定するまで文章には入れない) と、その中のカーソル
    private var marked = ""
    private var markedSelection = NSRange(location: 0, length: 0)
    /// 選択の動かないほうの端
    private var anchor: Int?
    private var caretOn = true
    private var blink: Timer?
    private var dragAnchor: Int?
    var onBecomeFirstResponder: (() -> Void)?
    /// 動作確認用 (アプリ本体では使わない)
    static var drawsCaretForTesting = false
    /// AI の答えを 1 字ずつ見せている間、まだ見せていない範囲
    var revealHidden: NSRange? { didSet { needsDisplay = true } }

    static let pad: CGFloat = 20
    static let gap: CGFloat = 16
    static let deskColor = NSColor(white: 0.55, alpha: 1)

    init(textView: EditorTextView) {
        self.textView = textView
        self.textViewAlive = textView
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(selectionDidChange(_:)), name: NSTextView.didChangeSelectionNotification, object: textView)
        if let storage = textView.textStorage {
            // 分割したもう一方や共同編集の相手が書き換えたときも届くよう、文字データそのものを見張る
            nc.addObserver(self, selector: #selector(storageDidChange(_:)), name: NSTextStorage.didProcessEditingNotification, object: storage)
        }
        reload()
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    // ファイルを放り込んだら開く (エディタ本体と同じ)
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { FileDrop.handles(sender) ? .copy : [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { FileDrop.handles(sender) ? .copy : [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard FileDrop.handles(sender) else { return false }
        let urls = FileDrop.fileURLs(sender)
        let target = owningEditor
        DispatchQueue.main.async { FileDrop.open(urls, into: target) }
        return true
    }

    deinit {
        blink?.invalidate()
        rubyWork?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: 文章と位置

    private var ns: NSString { textView.string as NSString }
    private var autoFormat: Bool { textView.genkoAutoFormat }
    /// 横書きの原稿用紙か (タブごと。メニュー「用紙」で切り替える)
    var horizontal: Bool { textView.genkoHorizontal }

    /// 縦書きの用紙の上の位置 (mm) → このビューの位置 (sheet 枚目)
    private func viewPoint(_ xv: Double, _ yv: Double, sheet: Int) -> NSPoint {
        GenkoRenderer.point(xv, yv, origin: sheetOrigin(sheet), u: u, horizontal: horizontal)
    }
    private func viewRect(_ xv: Double, _ yv: Double, _ w: Double, _ h: Double, sheet: Int) -> NSRect {
        GenkoRenderer.rect(xv, yv, w, h, origin: sheetOrigin(sheet), u: u, horizontal: horizontal)
    }

    /// マス目に並べる文章 (変換中の文字を、選択しているところへ入れたもの)
    private var displayText: String {
        guard !marked.isEmpty else { return textView.string }
        return ns.replacingCharacters(in: clampedSelection, with: marked)
    }

    private var clampedSelection: NSRange {
        let sel = textView.selectedRange()
        let loc = max(0, min(sel.location, ns.length))
        return NSRange(location: loc, length: max(0, min(sel.length, ns.length - loc)))
    }

    /// カーソル (選択の動くほうの端)
    private var head: Int {
        let sel = clampedSelection
        if let a = anchor, a == NSMaxRange(sel), sel.length > 0 { return sel.location }
        return NSMaxRange(sel)
    }

    private var anchorOffset: Int {
        let sel = clampedSelection
        if let a = anchor, a == NSMaxRange(sel) { return a }
        return sel.location
    }

    /// 画面でカーソルを出す位置 (変換中はその中のカーソル)
    private var caretOffset: Int {
        marked.isEmpty ? head : clampedSelection.location + NSMaxRange(markedSelection)
    }

    private func select(anchor a: Int, head h: Int) {
        let n = ns.length
        let a2 = max(0, min(n, a)), h2 = max(0, min(n, h))
        anchor = a2
        textView.setSelectedRange(NSRange(location: min(a2, h2), length: abs(a2 - h2)))
        // 同じ範囲のままだと知らせが来ないので、ここでも描き直す
        caretOn = true
        needsDisplay = true
        reveal()
    }

    // MARK: 並べ直し

    /// ふりがな (文章の位置つき)
    private(set) var ruby: [Genko.Ruby] = [] {
        didSet { if ruby != oldValue { reload() } }
    }
    /// ふりがなを取ったときの文章
    private var rubyText = ""
    private var rubyWork: DispatchWorkItem?

    /// ふりがなを取り直す (入力が止まってから少し待ち、辞書引きは裏で行う)
    func refreshRuby() {
        rubyWork?.cancel()
        guard UserDefaults.standard.bool(forKey: "genkoFurigana") else {
            if !ruby.isEmpty { ruby = [] }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.textViewAlive != nil else { return }
            let text = self.textView.string
            DispatchQueue.global(qos: .userInitiated).async {
                let list = Furigana.ruby(for: text)
                DispatchQueue.main.async { [weak self] in
                    // 待っている間に書き換わっていたら捨てる (次の取り直しが来る)
                    guard let self = self, self.textViewAlive != nil, self.textView.string == text,
                          UserDefaults.standard.bool(forKey: "genkoFurigana") else { return }
                    self.rubyText = text
                    self.ruby = list
                }
            }
        }
        rubyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// 書き換えたとき: 書き換えた所のふりがなだけ消し、後ろのものは字数の増減ぶんずらして残す
    /// (全部消して取り直すと、ほかの行のふりがなまで一瞬消えてちらつく)
    private func trimRuby() {
        guard !ruby.isEmpty else { return }
        let now = ns, old = rubyText as NSString
        guard !now.isEqual(to: rubyText) else { return }
        var same = 0
        let n = min(now.length, old.length)
        while same < n, now.character(at: same) == old.character(at: same) { same += 1 }
        var tail = 0
        while tail < n - same, now.character(at: now.length - 1 - tail) == old.character(at: old.length - 1 - tail) { tail += 1 }
        rubyText = now as String
        ruby = Self.shift(ruby, from: same, oldEnd: old.length - tail, delta: now.length - old.length)
    }

    /// 文章の [from, oldEnd) が書き換わって長さが delta 変わったときの、ふりがなの位置
    static func shift(_ list: [Genko.Ruby], from: Int, oldEnd: Int, delta: Int) -> [Genko.Ruby] {
        list.compactMap { r in
            if r.to <= from { return r }
            if r.from >= oldEnd { return Genko.Ruby(from: r.from + delta, to: r.to + delta, reading: r.reading) }
            return nil
        }
    }

    /// 設定 (自動整形・ふりがな) が変わったとき
    func settingsChanged() {
        reload()
        refreshRuby()
    }

    /// 文章・設定が変わったら並べ直す
    func reload() {
        // 同じ文章なら並べ直さない (打つたびに、入力の処理と文字データの知らせの 2 回呼ばれる)
        let text = displayText, format = autoFormat
        if laidOut?.text != text || laidOut?.autoFormat != format {
            columns = Genko.layout(text, autoFormat: format)
            laidOut = (text, format)
        }
        // 変換中は、変換中の文字の後ろのふりがなを、その字数ぶんずらして置く (消すとちらつく)
        if marked.isEmpty {
            rubyByColumn = Genko.placeRuby(columns, ruby)
        } else {
            let sel = clampedSelection
            rubyByColumn = Genko.placeRuby(columns, Self.shift(ruby, from: sel.location, oldEnd: NSMaxRange(sel),
                                                               delta: (marked as NSString).length - sel.length))
        }
        fit()
        needsDisplay = true
    }

    /// いま並べてある文章
    private var laidOut: (text: String, autoFormat: Bool)?

    /// 用紙の大きさをウインドウの幅に合わせ、枚数ぶんの高さにする
    func fit() {
        guard let clip = enclosingScrollView?.contentSize, clip.width > 0 else { return }
        u = max(2.2, min(4.6, (clip.width - 56) / CGFloat(horizontal ? Genko.Sheet.height : Genko.Sheet.width)))
        let n = CGFloat(Genko.sheetCount(columns))
        let size = NSSize(width: max(clip.width, sheetSize.width + Self.pad * 2),
                          height: max(clip.height, Self.pad * 2 + n * sheetSize.height + (n - 1) * Self.gap))
        if frame.size != size { setFrameSize(size) }
        needsDisplay = true
    }

    private var sheetSize: NSSize { GenkoRenderer.sheetSize(u: u, horizontal: horizontal) }

    /// 画像に撮っているあいだは、カーソルを描かない
    private var capturing = false

    /// スクリーンショット: いちばん多く見えている用紙 1 枚を、まわりに少し余白を付けて、ちょうど用紙が入る大きさで撮る
    /// (用紙の一部が画面の外にあっても、その 1 枚を丸ごと描く)
    func visibleSheetImage() -> NSBitmapImageRep? {
        let total = max(1, Genko.sheetCount(columns))
        let visible = visibleRect
        var best = 0, bestArea: CGFloat = -1
        for i in 0..<total {
            let r = NSRect(origin: sheetOrigin(i), size: sheetSize).intersection(visible)
            let area = r.isNull ? 0 : r.width * r.height
            if area > bestArea { best = i; bestArea = area }
        }
        let margin = Self.gap / 2
        let rect = NSRect(origin: sheetOrigin(best), size: sheetSize).insetBy(dx: -margin, dy: -margin).intersection(bounds)
        guard !rect.isEmpty, let rep = bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        capturing = true
        cacheDisplay(in: rect, to: rep)
        capturing = false
        return rep
    }

    private func sheetOrigin(_ i: Int) -> NSPoint {
        NSPoint(x: max(Self.pad, floor((bounds.width - sheetSize.width) / 2)),
                y: floor(Self.pad + CGFloat(i) * (sheetSize.height + Self.gap)))
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        if let clip = superview {
            clip.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipResized(_:)), name: NSView.frameDidChangeNotification, object: clip)
        }
        fit()
    }

    @objc private func clipResized(_ note: Notification) { fit() }

    @objc private func storageDidChange(_ note: Notification) {
        // 文字データの書き換えの途中で呼ばれるので、並べ直しは終わってから
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.textViewAlive != nil else { return }
            self.trimRuby()
            self.reload()
            self.refreshRuby()
        }
    }

    @objc private func selectionDidChange(_ note: Notification) {
        caretOn = true
        needsDisplay = true
        if window != nil { reveal() }
    }

    // MARK: 描画

    /// 文章の位置 → カーソルの線 (このビューの座標)
    private func caretRect(at offset: Int) -> NSRect {
        let cell = Genko.caretCell(columns, offset: offset)
        let x = GenkoRenderer.columnX(cell.column % Genko.columnsPerSheet, horizontal: horizontal)
        let y = Genko.Sheet.top + Double(min(cell.row, Genko.rows)) * Genko.Sheet.cell
        // マスの頭の細い線 (縦書きは上の辺、横書きは左の辺)
        let line = viewRect(x + 0.4, y, Genko.Sheet.cell - 0.8, 0, sheet: cell.column / Genko.columnsPerSheet)
        return horizontal ? NSRect(x: line.minX - 1, y: line.minY, width: 2, height: line.height)
                          : NSRect(x: line.minX, y: line.minY - 1, width: line.width, height: 2)
    }

    private var showsCaret: Bool {
        if capturing { return false }
        return Self.drawsCaretForTesting || (window?.isKeyWindow == true && window?.firstResponder === self)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Self.deskColor.setFill()
        dirtyRect.fill()
        let total = Genko.sheetCount(columns)
        var marks = GenkoRenderer.Marks()
        marks.hidden = revealHidden
        // まだ見せていない字のふりがなも出さない
        let shownRuby = revealHidden.map { h in Genko.placeRuby(columns, ruby.filter { $0.to <= h.location || $0.from >= NSMaxRange(h) }) } ?? rubyByColumn
        let sel = clampedSelection
        if marked.isEmpty {
            if sel.length > 0 { marks.selection = sel }
            marks.remote = textView.remoteCursors.filter { $0.len > 0 }.map { (NSRange(location: $0.loc, length: $0.len), $0.color) }
        } else {
            let length = (marked as NSString).length
            marks.marked = NSRange(location: sel.location, length: length)
            marks.markedClause = NSRange(location: sel.location + markedSelection.location, length: markedSelection.length)
        }
        for i in 0..<total {
            let rect = NSRect(origin: sheetOrigin(i), size: sheetSize)
            guard rect.insetBy(dx: -Self.shadowMargin, dy: -Self.shadowMargin).intersects(dirtyRect) else { continue }
            // 影・紙・罫線は、一度描いたものを貼る (毎回描くと 1 枚 10 ms ほどかかる)
            let blank = blankSheet(ctx)
            if let blank = blank {
                ctx.draw(blank, in: NSRect(origin: NSPoint(x: rect.minX - Self.shadowMargin, y: rect.minY - Self.shadowMargin), size: blankLayerSize))
            }
            GenkoRenderer.drawSheet(i, of: total, columns: columns, ruby: shownRuby, at: rect.origin, u: u,
                                    paper: GenkoRenderer.paperColor, marks: marks, horizontal: horizontal, blank: blank == nil, in: ctx)
        }
        // 共同編集の相手のカーソルと名札
        if marked.isEmpty {
            for c in textView.remoteCursors {
                let r = caretRect(at: max(0, min(c.loc + c.len, ns.length)))
                c.color.setFill()
                r.fill()
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.white]
                let size = (c.name as NSString).size(withAttributes: attrs)
                let tag = NSRect(x: r.minX, y: r.minY - size.height - 2, width: size.width + 8, height: size.height + 2)
                NSBezierPath(roundedRect: tag, xRadius: 3, yRadius: 3).fill()
                (c.name as NSString).draw(at: NSPoint(x: tag.minX + 4, y: tag.minY + 1), withAttributes: attrs)
            }
        }
        if caretOn, showsCaret, marked.isEmpty ? sel.length == 0 : true {
            GenkoRenderer.ink.setFill()
            caretRect(at: caretOffset).fill()
        }
    }

    /// 影・紙・罫線だけの用紙 (まわりに影のぶんの余白つき)。大きさ・向き・画面の解像度が変わったら描き直す
    private static let shadowMargin: CGFloat = 10
    private var blankCache: (key: String, layer: CGLayer)?

    private func blankSheet(_ ctx: CGContext) -> CGLayer? {
        let scale = window?.backingScaleFactor ?? 2
        let key = "\(u) \(horizontal) \(scale)"
        if let c = blankCache, c.key == key { return c.layer }
        let m = Self.shadowMargin
        let size = NSSize(width: ceil(sheetSize.width + m * 2), height: ceil(sheetSize.height + m * 2))
        // 画面の点の大きさで作り、描くときに縮める (Retina でぼやけないように)
        guard let layer = CGLayer(ctx, size: CGSize(width: size.width * scale, height: size.height * scale), auxiliaryInfo: nil),
              let lc = layer.context else { return nil }
        lc.scaleBy(x: scale, y: scale)
        // このレイヤーは上下を返した画面に貼るので、ここでは上が y = 0 の向きのまま描けばよい。
        // まわりは透明のまま (隣の用紙の影を消さないように)。影のずらしは上下を返さない座標で効くので、下へ落とすには + にする
        let paper = CGRect(origin: CGPoint(x: m, y: m), size: sheetSize)
        lc.saveGState()
        lc.setShadow(offset: CGSize(width: 0, height: 2 * scale), blur: 6 * scale, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        lc.setFillColor(GenkoRenderer.paperColor.cgColor)
        lc.fill(paper)
        lc.restoreGState()
        lc.saveGState()
        GenkoRenderer.drawGrid(origin: paper.origin, u: u, horizontal: horizontal, in: lc)
        lc.restoreGState()
        // レイヤーの大きさは画素で持っているので、貼るときの大きさ (点) を覚えておく
        blankCache = (key, layer)
        blankLayerSize = size
        return layer
    }
    private var blankLayerSize = NSSize.zero

    /// カーソルのあるマスが見えるようにスクロールする
    func reveal() {
        let r = caretRect(at: caretOffset)
        let cell = CGFloat(Genko.Sheet.cell) * u
        scrollToVisible(NSRect(x: r.minX, y: r.minY, width: r.width, height: cell).insetBy(dx: -cell, dy: -cell))
    }

    // MARK: フォーカス

    override func becomeFirstResponder() -> Bool {
        caretOn = true
        blink?.invalidate()
        // マスの頭に出す自前のカーソルを点滅させる
        blink = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] t in
            guard let self = self, self.textViewAlive != nil else { t.invalidate(); return }
            self.caretOn.toggle()
            self.setNeedsDisplay(self.caretRect(at: self.caretOffset).insetBy(dx: -3, dy: -3))
        }
        needsDisplay = true
        onBecomeFirstResponder?()
        return true
    }

    override func resignFirstResponder() -> Bool {
        commitMarked()
        blink?.invalidate()
        blink = nil
        needsDisplay = true
        return true
    }

    // MARK: マウス

    /// クリックした場所 → 文章の位置 (用紙の外なら nil)
    private func offset(at point: NSPoint) -> Int? {
        let total = Genko.sheetCount(columns)
        var sheet = -1
        for i in 0..<total {
            let o = sheetOrigin(i)
            if point.y >= o.y - Self.gap / 2 && point.y <= o.y + sheetSize.height + Self.gap / 2 { sheet = i; break }
        }
        guard sheet >= 0 else { return nil }
        let o = sheetOrigin(sheet)
        // このビューの位置 → 縦書きの用紙の上の位置 (mm)
        let px = Double((point.x - o.x) / u), py = Double((point.y - o.y) / u)
        let xmm = horizontal ? Genko.Sheet.width - py : px, ymm = horizontal ? px : py
        var k = 0
        var distance = Double.infinity
        for i in 0..<Genko.columnsPerSheet {
            let d = abs(GenkoRenderer.columnX(i, horizontal: horizontal) + Genko.Sheet.pitch / 2 - xmm)
            if d < distance { distance = d; k = i }
        }
        let column = sheet * Genko.columnsPerSheet + k
        if column >= columns.count { return ns.length }
        let row = max(0, min(Genko.rows, Int(floor((ymm - Genko.Sheet.top) / Genko.Sheet.cell + 0.35))))
        return Genko.offsetAt(columns, column: column, row: row)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitMarked()
        guard let off = offset(at: convert(event.locationInWindow, from: nil)) else { return }
        let a = event.modifierFlags.contains(.shift) ? anchorOffset : off
        dragAnchor = a
        select(anchor: a, head: off)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let a = dragAnchor else { return }
        autoscroll(with: event)
        if let off = offset(at: convert(event.locationInWindow, from: nil)) { select(anchor: a, head: off) }
    }

    override func mouseUp(with event: NSEvent) { dragAnchor = nil }

    /// 縦書きなので、マウスのカーソルも縦書き用の I (横向きの I) にする
    override func resetCursorRects() { addCursorRect(visibleRect, cursor: .iBeamCursorForVerticalLayout) }

    // マウスが入ってきたとき・動いたときも、念のため縦書きの I にし直す
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { (horizontal ? NSCursor.iBeam : NSCursor.iBeamCursorForVerticalLayout).set() }
    override func mouseEntered(with event: NSEvent) { (horizontal ? NSCursor.iBeam : NSCursor.iBeamCursorForVerticalLayout).set() }

    // MARK: キー

    override func keyDown(with event: NSEvent) {
        NSCursor.setHiddenUntilMouseMoves(true)
        interpretKeyEvents([event])
    }

    private enum Move { case up, down, left, right, columnStart, columnEnd, documentStart, documentEnd, sheetUp, sheetDown }

    private static let moves: [String: (Move, Bool)] = {
        var m: [String: (Move, Bool)] = [:]
        func add(_ names: [String], _ move: Move) {
            for n in names {
                m[n + ":"] = (move, false)
                m[n + "AndModifySelection:"] = (move, true)
            }
        }
        add(["moveUp", "moveBackward"], .up)
        add(["moveDown", "moveForward"], .down)
        add(["moveLeft"], .left)
        add(["moveRight"], .right)
        add(["moveToBeginningOfLine", "moveToBeginningOfParagraph", "moveToRightEndOfLine"], .columnStart)
        add(["moveToEndOfLine", "moveToEndOfParagraph", "moveToLeftEndOfLine"], .columnEnd)
        add(["moveToBeginningOfDocument"], .documentStart)
        add(["moveToEndOfDocument"], .documentEnd)
        add(["pageUp"], .sheetUp)
        add(["pageDown"], .sheetDown)
        m["scrollPageUp:"] = (.sheetUp, false)
        m["scrollPageDown:"] = (.sheetDown, false)
        m["scrollToBeginningOfDocument:"] = (.documentStart, false)
        m["scrollToEndOfDocument:"] = (.documentEnd, false)
        return m
    }()

    /// 文章を書き換える操作は、文章の持ち主 (EditorTextView) にそのまま頼む
    private static let editCommands: Set<String> = [
        "deleteBackward:", "deleteForward:", "deleteWordBackward:", "deleteWordForward:",
        "deleteToBeginningOfLine:", "deleteToEndOfLine:", "deleteToBeginningOfParagraph:", "deleteToEndOfParagraph:",
        "deleteBackwardByDecomposingPreviousCharacter:", "insertNewline:", "insertLineBreak:",
        "insertNewlineIgnoringFieldEditor:", "insertParagraphSeparator:", "insertTab:", "transpose:", "yank:",
    ]

    override func doCommand(by selector: Selector) {
        let name = NSStringFromSelector(selector)
        if let (move, extend) = Self.moves[name] {
            perform(move, extend: extend)
        } else if Self.editCommands.contains(name), textView.responds(to: selector) {
            commitMarked()
            textView.doCommand(by: selector)
            reveal()
        }
    }

    private func perform(_ move: Move, extend: Bool) {
        // 横書きでは、←→ が行の中、↑↓ が前後の行
        var move = move
        if horizontal {
            switch move {
            case .left: move = .up
            case .right: move = .down
            case .up: move = .right
            case .down: move = .left
            default: break
            }
        }
        let n = ns.length
        let h = head
        let cell = Genko.caretCell(columns, offset: h)
        // 絵文字などの 2 つ組の文字は 1 文字として動く
        func step(_ dir: Int) -> Int {
            var p = h + dir
            if p > 0, p < n, UTF16.isTrailSurrogate(ns.character(at: p)) { p += dir }
            return p
        }
        var target: Int
        switch move {
        case .up: target = step(-1)
        case .down: target = step(1)
        case .left: // 縦書きなので、左が次の列
            target = cell.column + 1 >= columns.count ? n : Genko.offsetAt(columns, column: cell.column + 1, row: cell.row)
        case .right:
            target = cell.column == 0 ? 0 : Genko.offsetAt(columns, column: cell.column - 1, row: cell.row)
        case .columnStart: target = columns.isEmpty ? 0 : columns[cell.column].from
        case .columnEnd: target = columns.isEmpty ? n : columns[cell.column].to
        case .documentStart: target = 0
        case .documentEnd: target = n
        case .sheetUp: target = Genko.offsetAt(columns, column: max(0, cell.column - Genko.columnsPerSheet), row: cell.row)
        case .sheetDown: target = Genko.offsetAt(columns, column: min(columns.count - 1, cell.column + Genko.columnsPerSheet), row: cell.row)
        }
        target = max(0, min(n, target))
        select(anchor: extend ? anchorOffset : target, head: target)
    }

    // MARK: 編集メニュー

    @objc func copy(_ sender: Any?) { textView.copy(sender) }
    @objc func cut(_ sender: Any?) { commitMarked(); textView.cut(sender) }
    @objc func paste(_ sender: Any?) { commitMarked(); textView.pasteAsPlainText(sender) }
    @objc func delete(_ sender: Any?) { commitMarked(); textView.delete(sender) }

    override func selectAll(_ sender: Any?) {
        commitMarked()
        select(anchor: 0, head: ns.length)
    }

    /// 行の複製・並べ替えなど、EditorTextView が持っている編集の動作はそちらへ回す
    private static let forwarded: Set<String> = [
        "duplicateLineHM:", "deleteLineHM:", "moveLineUpHM:", "moveLineDownHM:", "sortLinesHM:", "uniqueLinesHM:",
        "trimTrailingSpacesHM:", "uppercaseWord:", "lowercaseWord:", "capitalizeWord:",
    ]

    override func responds(to aSelector: Selector!) -> Bool {
        if let s = aSelector, Self.forwarded.contains(NSStringFromSelector(s)) { return true }
        return super.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let s = aSelector, Self.forwarded.contains(NSStringFromSelector(s)) { return textView }
        return super.forwardingTarget(for: aSelector)
    }

    // MARK: 日本語入力 (NSTextInputClient)

    /// 変換中の文字があれば、そのまま確定して文章に入れる
    private func commitMarked() {
        guard !marked.isEmpty else { return }
        let text = marked
        marked = ""
        markedSelection = NSRange(location: 0, length: 0)
        inputContext?.discardMarkedText()
        textView.insertText(text, replacementRange: clampedSelection)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        // 変換中の文字は文章に入れていないので、確定した文字で選択範囲を置き換えるだけでよい
        var range = clampedSelection
        if marked.isEmpty, replacementRange.location != NSNotFound, NSMaxRange(replacementRange) <= ns.length {
            range = replacementRange
        }
        marked = ""
        markedSelection = NSRange(location: 0, length: 0)
        anchor = nil
        // 全角にする・書き出しの字下げなどの作文の手伝いは EditorTextView.insertText が受け持つ
        textView.insertText(text, replacementRange: range)
        reload()
        reveal()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        let length = (marked as NSString).length
        let loc = max(0, min(selectedRange.location == NSNotFound ? length : selectedRange.location, length))
        markedSelection = NSRange(location: loc, length: max(0, min(selectedRange.length, length - loc)))
        caretOn = true
        reload()
        reveal()
    }

    func unmarkText() { commitMarked(); reload() }

    func selectedRange() -> NSRange {
        let sel = clampedSelection
        if marked.isEmpty { return sel }
        return NSRange(location: sel.location + markedSelection.location, length: markedSelection.length)
    }

    func markedRange() -> NSRange {
        marked.isEmpty ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: clampedSelection.location, length: (marked as NSString).length)
    }

    func hasMarkedText() -> Bool { !marked.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let text = displayText as NSString
        let loc = max(0, min(range.location, text.length))
        let r = NSRange(location: loc, length: max(0, min(range.length, text.length - loc)))
        actualRange?.pointee = r
        return NSAttributedString(string: text.substring(with: r))
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// 変換の候補の窓を出す場所: その文字のマス
    /// 日本語入力の候補 (予測変換) を出す目安の場所。日本語入力は、ここで返した四角の左下を起点に、すぐ下 (入らなければすぐ上) に候補を出す。
    /// 設定「予測変換の出る場所」(genkoCandidates):
    ///   "outside" (標準) … いま書いている列のマス目の上から下までを返し、候補を用紙のマス目の外 (下か上) に出す。字にかぶらない
    ///   "beside" … 列の左 (これから書く側) の、変換中の最初の字の高さに出す
    static let candidateWidth: CGFloat = 300
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let start = range.location == NSNotFound ? caretOffset : range.location
        let cell = Genko.caretCell(columns, offset: start)
        let sheet = cell.column / Genko.columnsPerSheet
        let colX = GenkoRenderer.columnX(cell.column % Genko.columnsPerSheet, horizontal: horizontal)
        let top = Genko.Sheet.top
        let visible = visibleRect
        var rect: NSRect
        if UserDefaults.standard.string(forKey: "genkoCandidates") == "beside" {
            if horizontal {
                // 横書き: 書いている字のすぐ下
                rect = viewRect(colX, top + Double(min(cell.row, Genko.rows)) * Genko.Sheet.cell, Genko.Sheet.cell, Genko.Sheet.cell, sheet: sheet)
            } else {
                let y = viewPoint(colX, top + Double(min(cell.row, Genko.rows)) * Genko.Sheet.cell, sheet: sheet).y
                let colLeft = viewPoint(colX, top, sheet: sheet).x
                let gap: CGFloat = 6
                var x = colLeft - gap - Self.candidateWidth
                // 左に場所がないときは、列の右 (ふりがなの欄の外) に出す
                if x < visible.minX { x = colLeft + CGFloat(Genko.Sheet.pitch) * u + gap }
                rect = NSRect(x: x, y: y - 1, width: Self.candidateWidth, height: 1)
            }
        } else {
            // 縦書きは列の、横書きは行の、マス目の端から端まで (候補はマス目の外に出る)
            rect = horizontal ? viewRect(colX, top, Genko.Sheet.pitch, Genko.Sheet.gridHeight, sheet: sheet)
                              : viewRect(colX, top, Genko.Sheet.cell, Genko.Sheet.gridHeight, sheet: sheet)
            if horizontal {
                // 横書きでは、マス目全体の下に出す
                let span = GenkoRenderer.gridSpan(horizontal: true)
                let grid = viewRect(span.x, top, span.width, Genko.Sheet.gridHeight, sheet: sheet)
                rect = NSRect(x: rect.minX, y: grid.minY, width: rect.width, height: grid.height)
            }
            if !visible.isEmpty {
                let clipped = rect.intersection(visible)
                if !clipped.isNull, clipped.height > 0 { rect = clipped }
            }
        }
        guard let w = window else { return rect }
        return w.convertToScreen(convert(rect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        guard let w = window else { return NSNotFound }
        let local = convert(w.convertFromScreen(NSRect(origin: point, size: .zero)).origin, from: nil)
        return offset(at: local) ?? NSNotFound
    }

    // MARK: 状態表示

    struct Info {
        var chars: Int
        var sheets: Int
        var sheet: Int
        var column: Int
        var row: Int
        var selected: Int
    }

    /// ステータスバーに出す情報 (文字数は改行を数えない)
    var info: Info {
        let cell = Genko.caretCell(columns, offset: caretOffset)
        let sel = clampedSelection
        return Info(chars: Genko.characterCount(textView.string),
                    sheets: Genko.sheetCount(columns),
                    sheet: cell.column / Genko.columnsPerSheet + 1,
                    column: cell.column % Genko.columnsPerSheet + 1,
                    row: min(Genko.rows, cell.row + 1),
                    selected: sel.length > 0 ? Genko.characterCount(ns.substring(with: sel)) : 0)
    }
}

/// 原稿用紙を PDF にする。1 枚 (400 字) を A4 横の 1 ページに、画面と同じ枠・同じマスで
enum GenkoPDF {
    /// A4 横 (pt)
    static let pageSize = CGSize(width: 841.89, height: 595.28)

    static func data(text: String, autoFormat: Bool, ruby: [Genko.Ruby], horizontal: Bool) -> Data? {
        let columns = Genko.layout(text, autoFormat: autoFormat)
        let placed = Genko.placeRuby(columns, ruby)
        let total = Genko.sheetCount(columns)
        let out = NSMutableData()
        // 横書きの原稿用紙は A4 縦
        let pageSize = horizontal ? CGSize(width: Self.pageSize.height, height: Self.pageSize.width) : Self.pageSize
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        let u = CGFloat(72 / 25.4)
        for i in 0..<total {
            ctx.beginPDFPage(nil)
            // PDF は左下が原点なので、上下を返して左上からの座標にする
            ctx.translateBy(x: 0, y: pageSize.height)
            ctx.scaleBy(x: 1, y: -1)
            GenkoRenderer.drawSheet(i, of: total, columns: columns, ruby: placed, at: .zero, u: u, paper: .white, horizontal: horizontal, in: ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return out as Data
    }

    static func write(text: String, autoFormat: Bool, ruby: [Genko.Ruby], horizontal: Bool, to url: URL) throws {
        guard let data = data(text: text, autoFormat: autoFormat, ruby: ruby, horizontal: horizontal) else {
            throw NSError(domain: "Satoru", code: 35, userInfo: [NSLocalizedDescriptionKey: L("PDF を作れませんでした")])
        }
        try data.write(to: url, options: .atomic)
    }
}
