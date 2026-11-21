import AppKit

/// テーマ 1 つ分の見本。小さなエディタ画面をそのテーマの色で描き、クリックで切り替える。
/// いま使っているテーマの見本は、個別に変えた色も反映する。
final class ThemeCardView: NSView {
    let preset: Theme.Preset
    var onSelect: ((String) -> Void)?

    private var hovering = false
    private var trackingArea: NSTrackingArea?

    static let height: CGFloat = 112
    private let labelHeight: CGFloat = 20

    init(preset: Theme.Preset) {
        self.preset = preset
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        toolTip = "クリックで「\(preset.name)」に切り替え"
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("テーマ \(preset.name)")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var isCurrent: Bool { preset.name == Theme.presetName }

    override func accessibilityValue() -> Any? { isCurrent ? 1 : 0 }

    override func accessibilityPerformPress() -> Bool {
        onSelect?(preset.name)
        return true
    }

    private func color(_ key: String) -> NSColor {
        if isCurrent { return Theme.color(forKey: key) }
        return preset.colors[key].flatMap { Theme.parse(hex: $0) } ?? .magenta
    }

    // MARK: マウス

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onSelect?(preset.name) }
    }

    // MARK: 描画

    /// 見本の 1 行 = (文字, 色のキー, 選択中か) の並び
    private typealias Segment = (text: String, key: String, selected: Bool)
    private static let sample: [[Segment]] = [
        [("// テーマの見本", "comment", false)],
        [("func", "keyword", false), (" ", "text", false), ("hello", "text", true), ("(n: ", "text", false),
         ("Int", "type", false), (") {", "text", false)],
        [("    print(", "text", false), ("\"こんにちは\"", "string", false), (")", "text", false)],
        [("    ", "text", false), ("return", "keyword", false), (" n + ", "text", false), ("42", "number", false)],
        [("}", "text", false)],
    ]
    private static let currentLineIndex = 2

    override func draw(_ dirtyRect: NSRect) {
        let current = isCurrent
        let frame = NSRect(x: 2, y: 2, width: bounds.width - 4, height: bounds.height - labelHeight - 4)
        let shape = NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7)

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        drawEditor(in: frame)
        NSGraphicsContext.restoreGraphicsState()

        // 枠: 使用中はアクセントカラーで太く
        if current {
            NSColor.controlAccentColor.setStroke()
            shape.lineWidth = 3
        } else {
            (hovering ? NSColor.controlAccentColor.withAlphaComponent(0.55) : NSColor.gray.withAlphaComponent(0.45)).setStroke()
            shape.lineWidth = hovering ? 2 : 1
        }
        shape.stroke()

        // 名前
        var name = preset.name
        if current { name = "✓ " + name + (Theme.overrides.isEmpty ? "" : " (変更あり)") }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: current ? NSFont.boldSystemFont(ofSize: 11) : NSFont.systemFont(ofSize: 11),
            .foregroundColor: current ? NSColor.controlAccentColor : NSColor.labelColor,
            .paragraphStyle: style,
        ]
        (name as NSString).draw(in: NSRect(x: 0, y: bounds.height - labelHeight + 3, width: bounds.width, height: labelHeight - 3),
                                withAttributes: attrs)
    }

    private func drawEditor(in frame: NSRect) {
        let font = NSFont(descriptor: Theme.font.fontDescriptor, size: 9.5) ?? .monospacedSystemFont(ofSize: 9.5, weight: .regular)
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .regular)
        let lineH: CGFloat = 14
        let gutterW: CGFloat = 20
        let top = frame.minY + 5
        let textX = frame.minX + gutterW + 5

        color("background").setFill()
        frame.fill()
        color("gutterBackground").setFill()
        NSRect(x: frame.minX, y: frame.minY, width: gutterW, height: frame.height).fill()
        color("gutterSeparator").setFill()
        NSRect(x: frame.minX + gutterW, y: frame.minY, width: 1, height: frame.height).fill()

        for (i, line) in Self.sample.enumerated() {
            let y = top + CGFloat(i) * lineH
            let isCurrentLine = i == Self.currentLineIndex
            if isCurrentLine {
                color("currentLine").setFill()
                NSRect(x: frame.minX + gutterW + 1, y: y, width: frame.width, height: lineH).fill(using: .sourceOver)
            }
            // 行番号
            let num = "\(i + 1)" as NSString
            let numAttrs: [NSAttributedString.Key: Any] = [
                .font: numberFont, .foregroundColor: color(isCurrentLine ? "gutterCurrentText" : "gutterText"),
            ]
            let numSize = num.size(withAttributes: numAttrs)
            num.draw(at: NSPoint(x: frame.minX + gutterW - 4 - numSize.width, y: y + (lineH - numSize.height) / 2), withAttributes: numAttrs)

            // 本文
            var x = textX
            for seg in line {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(seg.key)]
                let s = seg.text as NSString
                let size = s.size(withAttributes: attrs)
                if seg.selected {
                    color("selection").setFill()
                    NSRect(x: x, y: y, width: size.width, height: lineH).fill(using: .sourceOver)
                }
                s.draw(at: NSPoint(x: x, y: y + (lineH - size.height) / 2), withAttributes: attrs)
                x += size.width
            }
            if isCurrentLine {
                color("caret").setFill()
                NSRect(x: x + 0.5, y: y + 1, width: 1.5, height: lineH - 2).fill()
                x += 3
            }
            // 行末: 改行マーク。最後の行は [EOF]
            let last = i == Self.sample.count - 1
            let endAttrs: [NSAttributedString.Key: Any] = [
                .font: last ? font : NSFont.systemFont(ofSize: 8),
                .foregroundColor: color(last ? "eof" : "newlineMark"),
            ]
            let end = (last ? "[EOF]" : "↓") as NSString
            let endSize = end.size(withAttributes: endAttrs)
            end.draw(at: NSPoint(x: x + 1, y: y + (lineH - endSize.height) / 2), withAttributes: endAttrs)
        }

        // ステータスバー (ウインドウ枠をテーマに合わせているときだけテーマの色になる)
        if Theme.windowStyle == "theme" {
            let barH: CGFloat = 12
            let bar = NSRect(x: frame.minX, y: frame.maxY - barH, width: frame.width, height: barH)
            color("statusBackground").setFill()
            bar.fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 7.5), .foregroundColor: color("statusText")]
            let s = "UTF-8  LF  挿入" as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: bar.maxX - size.width - 6, y: bar.minY + (barH - size.height) / 2), withAttributes: attrs)
        }
    }
}

/// テーマの見本を 4 列に並べた一覧
final class ThemeGalleryView: NSStackView {
    private var cards: [ThemeCardView] = []

    init(onSelect: @escaping (String) -> Void) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        let perRow = 4
        var index = 0
        while index < Theme.presets.count {
            var rowViews: [NSView] = []
            for col in 0..<perRow {
                if index + col < Theme.presets.count {
                    let card = ThemeCardView(preset: Theme.presets[index + col])
                    card.onSelect = onSelect
                    cards.append(card)
                    rowViews.append(card)
                } else {
                    // 端数の行も同じ幅で並ぶように空きを入れる
                    let spacer = NSView()
                    spacer.translatesAutoresizingMaskIntoConstraints = false
                    rowViews.append(spacer)
                }
            }
            let row = NSStackView(views: rowViews)
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 10
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            index += perRow
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        cards.forEach { $0.needsDisplay = true }
    }
}
