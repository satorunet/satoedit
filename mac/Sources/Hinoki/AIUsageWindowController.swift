import AppKit
import HinokiCore

/// 棒グラフ (下にラベル、上に値)
final class BarChartView: NSView {
    var bars: [(label: String, value: Double)] = [] { didSet { needsDisplay = true } }
    var valueText: (Double) -> String = { String(format: "%.2f", $0) }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard !bars.isEmpty else { return }
        let left: CGFloat = 8, right: CGFloat = 8, top: CGFloat = 22, bottom: CGFloat = 22
        let area = NSRect(x: left, y: top, width: bounds.width - left - right, height: bounds.height - top - bottom)
        let maxV = max(bars.map { $0.value }.max() ?? 0, 0.000001)
        let slot = area.width / CGFloat(bars.count)
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
        // 目盛り線
        NSColor.separatorColor.setStroke()
        let base = NSBezierPath()
        base.move(to: NSPoint(x: area.minX, y: area.maxY + 0.5))
        base.line(to: NSPoint(x: area.maxX, y: area.maxY + 0.5))
        base.stroke()
        (L("最大 ") + valueText(maxV) as NSString).draw(at: NSPoint(x: area.minX, y: 4), withAttributes: small)
        let every = max(1, bars.count / 10)
        for (i, b) in bars.enumerated() {
            let h = CGFloat(b.value / maxV) * area.height
            let r = NSRect(x: area.minX + CGFloat(i) * slot + slot * 0.15, y: area.maxY - h, width: slot * 0.7, height: h)
            (b.value > 0 ? NSColor.controlAccentColor : NSColor.clear).setFill()
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
            if i % every == 0 || i == bars.count - 1 {
                (b.label as NSString).draw(at: NSPoint(x: area.minX + CGFloat(i) * slot, y: area.maxY + 4), withAttributes: small)
            }
        }
    }
}

/// 「AI の利用状況と料金」ウインドウ
final class AIUsageWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = AIUsageWindowController()

    private let todayLabel = NSTextField(labelWithString: "")
    private let monthLabel = NSTextField(labelWithString: "")
    private let totalLabel = NSTextField(labelWithString: "")
    private let modePicker = NSSegmentedControl(labels: [L("日別 (30 日)"), L("月別 (12 か月)")], trackingMode: .selectOne, target: nil, action: nil)
    private let metricPicker = NSSegmentedControl(labels: [L("料金"), L("トークン")], trackingMode: .selectOne, target: nil, action: nil)
    private let chart = BarChartView()
    private let table = NSTableView()
    private var months: [(key: String, s: AIUsageLog.Summary)] = []

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        w.title = L("AI の利用状況と料金")
        w.tabbingMode = .disallowed
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 600, height: 480)
        super.init(window: w)
        build(in: w)
        w.center()
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: AIUsageLog.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func card(_ title: String, _ value: NSTextField) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = .boldSystemFont(ofSize: 12)
        value.font = .systemFont(ofSize: 12)
        value.lineBreakMode = .byWordWrapping
        value.maximumNumberOfLines = 3
        let s = NSStackView(views: [t, value])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 2
        return SettingsUI.box("", s, fillWidth: true)
    }

    private func build(in w: NSWindow) {
        let cards = NSStackView(views: [card(L("今日"), todayLabel), card(L("今月"), monthLabel), card(L("これまでの合計"), totalLabel)])
        cards.distribution = .fillEqually
        cards.spacing = 10

        modePicker.selectedSegment = 0
        metricPicker.selectedSegment = 0
        for c in [modePicker, metricPicker] { c.target = self; c.action = #selector(reload) }
        let controls = SettingsUI.row([modePicker, metricPicker, NSView(),
                                       SettingsUI.button(L("記録を消す…"), self, #selector(clearLog(_:)))])
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: 180).isActive = true
        chart.wantsLayer = true
        chart.layer?.cornerRadius = 6

        for (id, title, width) in [("month", L("月"), 90.0), ("count", L("回数"), 70.0), ("input", L("入力トークン"), 110.0),
                                   ("output", L("出力トークン"), 110.0), ("cost", L("目安の料金"), 220.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = CGFloat(width)
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        let list = SettingsUI.scrolled(table)

        let note = SettingsUI.label(L("料金は目安です (1 ドル = {0} 円で計算)。正確な金額は各社の請求画面で確認してください。", Int(AIPricing.yenPerDollar)), small: true)
        let stack = SettingsUI.fill(w.contentView ?? NSView(), with: [cards, controls, chart, list, note], spacing: 10)
        for v in [cards, controls, chart, list] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        list.setContentHuggingPriority(.init(1), for: .vertical)
    }

    private func line(_ s: AIUsageLog.Summary) -> String {
        L("{0} 回・{1} トークン\n{2}", s.count, fmt(s.input + s.output), s.costText)
    }

    private func fmt(_ n: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }

    @objc private func reload() {
        let cal = Calendar.current
        let now = Date()
        todayLabel.stringValue = line(AIUsageLog.summary { cal.isDate($0.date, inSameDayAs: now) })
        monthLabel.stringValue = line(AIUsageLog.summary { cal.isDate($0.date, equalTo: now, toGranularity: .month) })
        totalLabel.stringValue = line(AIUsageLog.summary { _ in true })

        // 月別の表 (新しい月が上)
        var byMonth: [String: AIUsageLog.Summary] = [:]
        for r in AIUsageLog.records { byMonth[AIUsageLog.monthKey(r.date), default: AIUsageLog.Summary()].add(r) }
        months = byMonth.keys.sorted(by: >).map { ($0, byMonth[$0]!) }
        table.reloadData()

        // グラフ
        let useCost = metricPicker.selectedSegment == 0
        func value(_ s: AIUsageLog.Summary) -> Double { useCost ? s.cost : Double(s.input + s.output) }
        var bars: [(String, Double)] = []
        if modePicker.selectedSegment == 0 {
            for back in (0..<30).reversed() {
                guard let day = cal.date(byAdding: .day, value: -back, to: now) else { continue }
                let s = AIUsageLog.summary { cal.isDate($0.date, inSameDayAs: day) }
                let c = cal.dateComponents([.month, .day], from: day)
                bars.append(("\(c.month ?? 0)/\(c.day ?? 0)", value(s)))
            }
        } else {
            for back in (0..<12).reversed() {
                guard let m = cal.date(byAdding: .month, value: -back, to: now) else { continue }
                let s = byMonth[AIUsageLog.monthKey(m)] ?? AIUsageLog.Summary()
                bars.append((L("{0}月", cal.component(.month, from: m)), value(s)))
            }
        }
        chart.valueText = useCost ? { AIPricing.format($0) } : { L("{0} トークン", Int($0)) }
        chart.bars = bars
    }

    func numberOfRows(in tableView: NSTableView) -> Int { months.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let m = months[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "month": text = m.key
        case "count": text = "\(m.s.count)"
        case "input": text = fmt(m.s.input)
        case "output": text = fmt(m.s.output)
        default: text = m.s.costText
        }
        return NSTextField(labelWithString: text)
    }

    @objc private func clearLog(_ sender: Any?) {
        guard let w = window else { return }
        let a = NSAlert()
        a.messageText = L("利用の記録を消しますか？")
        a.informativeText = L("グラフと履歴が空になります (各社への支払いには関係ありません)。")
        a.addButton(withTitle: L("消す"))
        a.addButton(withTitle: L("やめる"))
        a.beginSheetModal(for: w) { r in if r == .alertFirstButtonReturn { AIUsageLog.clear() } }
    }
}
