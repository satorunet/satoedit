import AppKit
import HinokiCore

/// 窓の右上に少しのあいだ出る知らせ (トースト)。
/// 同じ key のトーストは新しく出さずに中身を書き換える (「送信中…」→「保存しました」など)。
final class Toast: NSView {
    enum Kind {
        case progress, success, failure, info
        var symbol: String {
            switch self {
            case .progress: return "arrow.triangle.2.circlepath"
            case .success: return "checkmark.circle.fill"
            case .failure: return "exclamationmark.triangle.fill"
            case .info: return "info.circle.fill"
            }
        }
        var tint: NSColor {
            switch self {
            case .progress: return .secondaryLabelColor
            case .success: return .systemGreen
            case .failure: return .systemRed
            case .info: return .systemBlue
            }
        }
        /// 自動で消えるまでの秒数 (nil = 書き換えられるまで出したまま)
        var duration: TimeInterval? {
            switch self {
            case .progress: return nil
            case .success, .info: return 5
            case .failure: return 10
            }
        }
    }

    private static let width: CGFloat = 340
    private static let margin: CGFloat = 12
    private static let gap: CGFloat = 8

    /// 窓ごとに出ているトースト (上から順)
    private static var shown: [ObjectIdentifier: [Toast]] = [:]

    let key: String?
    private weak var hostWindow: NSWindow?
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private var hideWork: DispatchWorkItem?

    /// トーストを出す (同じ key があれば書き換える)
    @discardableResult
    static func show(in window: NSWindow?, key: String? = nil, kind: Kind, title: String, detail: String = "") -> Toast? {
        guard let window = window, let content = window.contentView else { return nil }
        let id = ObjectIdentifier(window)
        if let key = key, let existing = shown[id]?.first(where: { $0.key == key }) {
            existing.set(kind: kind, title: title, detail: detail)
            relayout(window)
            return existing
        }
        let t = Toast(key: key, window: window)
        t.set(kind: kind, title: title, detail: detail)
        content.addSubview(t, positioned: .above, relativeTo: nil)
        shown[id, default: []].append(t)
        relayout(window)
        t.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            t.animator().alphaValue = 1
        }
        NSAccessibility.post(element: t, notification: .announcementRequested,
                             userInfo: [.announcement: title + " " + detail, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        return t
    }

    private init(key: String?, window: NSWindow) {
        self.key = key
        self.hostWindow = window
        super.init(frame: NSRect(x: 0, y: 0, width: Toast.width, height: 60))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = false
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        autoresizingMask = [.minXMargin, .minYMargin]

        let fx = NSVisualEffectView(frame: bounds)
        fx.material = .popover
        fx.blendingMode = .withinWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 10
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 0.5
        fx.layer?.borderColor = NSColor.separatorColor.cgColor
        fx.autoresizingMask = [.width, .height]
        addSubview(fx)

        icon.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.isSelectable = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        [icon, spinner, titleLabel, detailLabel].forEach { addSubview($0) }
        toolTip = L("クリックで閉じる")
    }

    required init?(coder: NSCoder) { fatalError() }

    private func set(kind: Kind, title: String, detail: String) {
        icon.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
        icon.contentTintColor = kind.tint
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
        // 中身の高さに合わせる
        let textW = Toast.width - 14 - 22 - 10 - 14
        detailLabel.preferredMaxLayoutWidth = textW
        let detailH = detail.isEmpty ? 0 : ceil(detailLabel.sizeThatFits(NSSize(width: textW, height: 1000)).height)
        let h = 12 + 18 + (detail.isEmpty ? 0 : 4 + detailH) + 12
        setFrameSize(NSSize(width: Toast.width, height: h))
        icon.frame = NSRect(x: 14, y: h - 12 - 20, width: 20, height: 20)
        spinner.frame = NSRect(x: 16, y: h - 12 - 18, width: 16, height: 16)
        // 進行中はぐるぐる、終わったらアイコン
        icon.isHidden = kind == .progress
        kind == .progress ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        titleLabel.frame = NSRect(x: 14 + 22 + 10, y: h - 12 - 18, width: textW, height: 18)
        detailLabel.frame = NSRect(x: 14 + 22 + 10, y: 12, width: textW, height: detailH)

        hideWork?.cancel()
        if let d = kind.duration {
            let w = DispatchWorkItem { [weak self] in self?.dismiss() }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: w)
        }
    }

    override func mouseDown(with event: NSEvent) { dismiss() }

    func dismiss() {
        hideWork?.cancel()
        guard let window = hostWindow else { removeFromSuperview(); return }
        let id = ObjectIdentifier(window)
        Toast.shown[id]?.removeAll { $0 === self }
        if Toast.shown[id]?.isEmpty == true { Toast.shown[id] = nil }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.removeFromSuperview()
            Toast.relayout(window)
        })
    }

    /// 右上から下へ積む
    private static func relayout(_ window: NSWindow) {
        guard let content = window.contentView, let list = shown[ObjectIdentifier(window)] else { return }
        // タイトルバーの下 (全体を覆う窓でも、見えている範囲の上端から)
        var top = content.bounds.maxY - margin
        if window.styleMask.contains(.fullSizeContentView) {
            top = window.contentLayoutRect.maxY - margin
        }
        for t in list {
            t.setFrameOrigin(NSPoint(x: content.bounds.maxX - width - margin, y: top - t.frame.height))
            top -= t.frame.height + gap
        }
    }
}
