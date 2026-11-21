import AppKit
import HinokiCore

/// エディタの右に出す差分の欄。開いたとき (保存したとき) の内容と、いまの内容の違いを行ごとに見せる。
/// 行を押すと、エディタのその行へ移る
final class DiffPanel: NSView {
    var onClose: (() -> Void)?
    /// いまの行番号 (1 始まり) へ移る
    var onJump: ((Int) -> Void)?

    private let textView = DiffTextView()
    private let empty = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
        translatesAutoresizingMaskIntoConstraints = false

        // 文字の表記は出さない。✕ だけを右上の角に小さく重ねる
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L("閉じる"))!, target: self, action: #selector(closeClicked))
        close.isBordered = false
        close.toolTip = L("閉じる")
        close.contentTintColor = .tertiaryLabelColor
        close.translatesAutoresizingMaskIntoConstraints = false
        closeButton = close

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 0)
        // 折り返さない (エディタと 1 行ずつ対応させる。長い行は横にスクロール)
        // 大きさ 0 のままだと、文字を入れても組まれず何も出ないので、はじめから大きさを持たせる
        textView.frame = NSRect(x: 0, y: 0, width: 360, height: 400)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.onJump = { [weak self] n in self?.onJump?(n) }
        scroll.documentView = textView
        scroll.hasVerticalScroller = false // エディタと一緒に動くので、自分のスクロールバーは要らない
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(empty)
        addSubview(close)
        // エディタとの間のバー: ドラッグで幅を変える
        let line = PanelResizeHandle()
        line.wantsLayer = true
        line.toolTip = L("ドラッグで幅を変える")
        line.onDrag = { [weak self] dx in self?.resize(by: dx) }
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        bar = line
        // 本文の上の端は、エディタの本文の上の端 (桁ルーラーの下) にそろえる
        let top = scroll.topAnchor.constraint(equalTo: topAnchor)
        topInset = top
        NSLayoutConstraint.activate([
            top,
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.barWidth),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            empty.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -20),
            close.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            close.widthAnchor.constraint(equalToConstant: 16),
            close.heightAnchor.constraint(equalToConstant: 16),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.widthAnchor.constraint(equalToConstant: Self.barWidth),
        ])
        let wc = widthAnchor.constraint(equalToConstant: Self.panelWidth)
        wc.isActive = true
        widthConstraint = wc
    }

    private static let barWidth: CGFloat = 6
    private weak var bar: NSView?
    private var widthConstraint: NSLayoutConstraint?

    /// 欄の幅 (バーをドラッグして変えられる。次からもこの幅)
    static var panelWidth: CGFloat {
        get {
            let w = UserDefaults.standard.double(forKey: "diffPanelWidth")
            return w > 0 ? CGFloat(w) : 360
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "diffPanelWidth") }
    }

    /// バーを dx だけ動かした (左へ動かすと広がる)。本文は 300 は残す
    private func resize(by dx: CGFloat) {
        guard let wc = widthConstraint else { return }
        let limit = max(200, (window?.contentView?.bounds.width ?? 2000) - 300)
        let w = min(max(200, wc.constant - dx), limit)
        guard w != wc.constant else { return }
        wc.constant = w
        Self.panelWidth = w
    }

    private let scroll = NSScrollView()
    private var topInset: NSLayoutConstraint?
    private weak var closeButton: NSButton?

    /// エディタに合わせる: 本文の上の端の位置 (桁ルーラーの高さ) と、文字の上の余白
    func alignWithEditor(top: CGFloat, containerInset: NSSize) {
        if topInset?.constant != top { topInset?.constant = top }
        if textView.textContainerInset.height != containerInset.height {
            textView.textContainerInset = NSSize(width: 4, height: containerInset.height)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// いまの文書の行番号 → 表示の中の位置
    private var lineStarts: [Int: Int] = [:]

    func show(_ result: TextDiff.InlineResult, font: NSFont, lineSpacing: CGFloat, colors: Colors) {
        // 背景はエディタの本文と同じ色
        wantsLayer = true
        layer?.backgroundColor = colors.background.cgColor
        bar?.layer?.backgroundColor = colors.bar.cgColor
        empty.textColor = colors.text
        closeButton?.contentTintColor = colors.number
        if result.tooLarge {
            empty.stringValue = L("大きすぎるので比べていません")
        } else if !result.hasChanges {
            empty.stringValue = L("変更はありません")
        } else {
            empty.stringValue = ""
        }
        empty.isHidden = empty.stringValue.isEmpty
        var starts: [Int: Int] = [:]
        textView.textStorage?.setAttributedString(Self.render(result, font: font, lineSpacing: lineSpacing, colors: colors, lineStarts: &starts))
        lineStarts = starts
        // 文字を組んで、中身の大きさに広げる (これをしないと、見えている範囲が空のままになる)
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc)
            let clip = scroll.contentView.bounds.size
            let inset = textView.textContainerInset
            textView.setFrameSize(NSSize(width: max(clip.width, ceil(used.width) + inset.width * 2 + 10),
                                         height: max(clip.height, ceil(used.height) + inset.height * 2)))
        }
        textView.needsDisplay = true
    }

    /// エディタのカーソル行と同じ行に、同じ色の帯を引き、文字も同じ色にする (line は 1 始まり。nil なら消す)
    func setCurrentLine(_ line: Int?, band: NSColor, text: NSColor?) {
        guard let lm = textView.layoutManager, let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        textView.currentLineRect = nil
        defer { textView.needsDisplay = true }
        guard let line = line, let loc = lineStarts[line], loc < storage.length else { return }
        let range = (storage.string as NSString).lineRange(for: NSRange(location: loc, length: 0))
        let g = lm.glyphIndexForCharacter(at: loc)
        let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        textView.currentLineRect = NSRect(x: 0, y: frag.minY + textView.textContainerOrigin.y, width: 100_000, height: frag.height)
        textView.currentLineColor = band
        if let t = text { lm.addTemporaryAttribute(.foregroundColor, value: t, forCharacterRange: range) }
    }

    /// いまの文書の line 行目 (1 始まり) が、欄のいちばん上から offset の位置に来るようにスクロールする
    /// (offset はエディタでのその行の見えている位置。行の途中までスクロールしていれば負になる)
    func scroll(toLine line: Int, offset: CGFloat = 0) {
        guard !lineStarts.isEmpty, let lm = textView.layoutManager, let tc = textView.textContainer,
              let scroll = textView.enclosingScrollView else { return }
        // その行が表示にない (消した行のあたり) ときは、手前のいちばん近い行
        var n = line
        while n > 0, lineStarts[n] == nil { n -= 1 }
        guard let loc = lineStarts[n] ?? lineStarts.values.min(), loc < (textView.textStorage?.length ?? 0) else { return }
        let g = lm.glyphIndexForCharacter(at: loc)
        let rect = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let y = rect.minY + textView.textContainerOrigin.y - offset
        let maxY = max(0, textView.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: min(max(-offset, y), maxY)))
        scroll.reflectScrolledClipView(scroll.contentView)
        _ = tc
    }

    /// Word の変更履歴のように: 消した字は赤の取り消し線、足した字は色付きの下線。
    /// 行の頭には、いまの文書での行番号 (消した行だけの行は「−」)
    /// font・lineSpacing はエディタと同じにする (横に並べて見比べられるように、行の高さをそろえる)。
    /// lineStarts には、いまの文書の行番号 → この表示の中での位置 を入れる (一緒にスクロールするため)
    static func render(_ r: TextDiff.InlineResult, font: NSFont, lineSpacing: CGFloat, colors: Colors, lineStarts: inout [Int: Int]) -> NSAttributedString {
        // 行番号も本文と同じ字にする (別の字だと行の高さが変わって、エディタとずれる)
        let numFont = font
        // 行番号ぶん下げて折り返す (折り返した続きも、番号の右にそろう)
        let digits = max(3, String((r.segments.map { $0.newLine + $0.skipped }.max() ?? 1) + 50).count)
        let numWidth = ("0" as NSString).size(withAttributes: [.font: numFont]).width * CGFloat(digits + 2)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = lineSpacing
        para.headIndent = numWidth
        para.tabStops = [NSTextTab(textAlignment: .left, location: numWidth)]

        // 1 行ずつに分ける: (種類, 字) の並び。gap は 1 行まるごと
        struct Line { var parts: [(TextDiff.Kind, String)] = []; var gap: TextDiff.Segment?; var newline: TextDiff.Kind? }
        var lines: [Line] = [Line()]
        for seg in r.segments {
            if seg.kind == .gap {
                if !(lines.last?.parts.isEmpty ?? true) { lines.append(Line()) }
                lines[lines.count - 1].gap = seg
                lines.append(Line())
                continue
            }
            var rest = Substring(seg.text)
            while let nl = rest.firstIndex(of: "\n") {
                let piece = String(rest[..<nl])
                if !piece.isEmpty { lines[lines.count - 1].parts.append((seg.kind, piece)) }
                lines[lines.count - 1].newline = seg.kind
                lines.append(Line())
                rest = rest[rest.index(after: nl)...]
            }
            if !rest.isEmpty { lines[lines.count - 1].parts.append((seg.kind, String(rest))) }
        }
        if let last = lines.last, last.parts.isEmpty, last.gap == nil { lines.removeLast() }

        let out = NSMutableAttributedString()
        var lineNo = r.segments.first?.newLine ?? 1
        for (idx, line) in lines.enumerated() {
            if let g = line.gap {
                let center = NSMutableParagraphStyle()
                center.alignment = .center
                center.paragraphSpacing = 4
                center.paragraphSpacingBefore = 4
                out.append(NSAttributedString(string: "⋯ " + L("同じ行 {0} 行", g.skipped) + " ⋯\n", attributes: [
                    .font: font, .foregroundColor: colors.number,
                    .paragraphStyle: center, .diffLine: g.newLine,
                ]))
                lineNo = g.newLine + g.skipped
                continue
            }
            // いまの文書にある行か (消した字だけの行は、いまの文書にはない)
            let removedOnly = !line.parts.isEmpty && line.parts.allSatisfy { $0.0 == .removed } && (line.newline == nil || line.newline == .removed)
                || (line.parts.isEmpty && line.newline == .removed)
            let target = lineNo
            if !removedOnly, lineStarts[lineNo] == nil { lineStarts[lineNo] = out.length }
            let label = removedOnly ? "−" : String(lineNo)
            let pad = String(repeating: " ", count: max(0, digits - label.count))
            out.append(NSAttributedString(string: pad + label + "\t", attributes: [
                .font: numFont, .foregroundColor: removedOnly ? colors.removedText : colors.number,
                .paragraphStyle: para, .diffLine: target,
            ]))
            for (kind, text) in line.parts {
                out.append(NSAttributedString(string: text, attributes: style(kind, font: font, para: para, line: target, colors: colors)))
            }
            if line.parts.isEmpty { out.append(NSAttributedString(string: " ", attributes: style(line.newline ?? .same, font: font, para: para, line: target, colors: colors))) }
            if idx < lines.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: para, .diffLine: target]))
            }
            if !removedOnly { lineNo += 1 }
        }
        return out
    }

    private static func style(_ kind: TextDiff.Kind, font: NSFont, para: NSParagraphStyle, line: Int, colors: Colors) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para, .diffLine: line]
        switch kind {
        case .removed:
            a[.foregroundColor] = colors.removedText
            a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            a[.strikethroughColor] = colors.removedText
            a[.backgroundColor] = colors.removedBack
        case .added:
            a[.foregroundColor] = colors.addedText
            a[.underlineStyle] = NSUnderlineStyle.single.rawValue
            a[.underlineColor] = colors.addedText
            a[.backgroundColor] = colors.addedBack
        default:
            a[.foregroundColor] = colors.text
        }
        return a
    }

    /// 差分の欄の色。エディタのテーマ (背景と字の色) から作る
    struct Colors {
        var background: NSColor
        /// エディタとの間のバーの色
        var bar: NSColor
        var text: NSColor
        var number: NSColor
        var addedText: NSColor
        var removedText: NSColor
        var addedBack: NSColor
        var removedBack: NSColor

        init(background: NSColor, text: NSColor, dark: Bool) {
            // 背景はエディタの色から少しだけ変える (暗いテーマは少し明るく、明るいテーマは少し暗く)
            let tint: NSColor = dark ? .white : .black
            self.background = background.blended(withFraction: dark ? 0.06 : 0.04, of: tint) ?? background
            bar = background.blended(withFraction: dark ? 0.22 : 0.16, of: tint) ?? background
            self.text = text.withAlphaComponent(0.75) // 変わっていない字は少し控えめに
            number = text.withAlphaComponent(0.4)
            addedText = dark ? NSColor(srgbRed: 0.45, green: 0.80, blue: 1.0, alpha: 1) : NSColor(srgbRed: 0.0, green: 0.36, blue: 0.75, alpha: 1)
            removedText = dark ? NSColor(srgbRed: 1.0, green: 0.50, blue: 0.50, alpha: 1) : NSColor(srgbRed: 0.78, green: 0.10, blue: 0.10, alpha: 1)
            addedBack = dark ? NSColor(srgbRed: 0.25, green: 0.55, blue: 0.95, alpha: 0.22) : NSColor(srgbRed: 0.25, green: 0.55, blue: 0.95, alpha: 0.14)
            removedBack = dark ? NSColor(srgbRed: 0.90, green: 0.25, blue: 0.25, alpha: 0.22) : NSColor(srgbRed: 0.90, green: 0.25, blue: 0.25, alpha: 0.12)
        }
    }

    @objc private func closeClicked() { onClose?() }
}

extension NSAttributedString.Key {
    /// 差分の欄で、その字がいまの文書の何行目にあたるか (押したときの移り先)
    static let diffLine = NSAttributedString.Key("SatoruDiffLine")
}

/// 差分の本文: 押した場所の行へ移る (範囲を選んだときは移らない)
final class DiffTextView: NSTextView {
    var onJump: ((Int) -> Void)?
    /// エディタのカーソル行にあたる行の帯
    var currentLineRect: NSRect?
    var currentLineColor: NSColor = .clear

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let r = currentLineRect else { return }
        currentLineColor.setFill()
        r.intersection(rect).fill(using: .sourceOver)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard selectedRange().length == 0, let storage = textStorage, storage.length > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let i = min(characterIndexForInsertion(at: p), storage.length - 1)
        if let n = storage.attribute(.diffLine, at: max(0, i), effectiveRange: nil) as? Int { onJump?(n) }
    }

    override func resetCursorRects() { addCursorRect(visibleRect, cursor: .pointingHand) }
}
