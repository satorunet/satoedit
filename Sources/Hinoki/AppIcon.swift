import AppKit

/// アプリのアイコンの色ちがい。設定で選ぶと、Dock と Finder のアイコンが変わる。
/// 絵は scripts/make_icons.sh が作って、アプリの中 (Resources/Icons) に入れている。
enum AppIcon {
    /// (ファイル名, 画面に出す名前)。先頭が既定
    static let variants: [(id: String, name: String)] = [
        ("ai", "藍"), ("shu", "朱"), ("hinoki", "ひのき緑"), ("sumi", "墨"),
        ("yamabuki", "山吹"), ("murasaki", "紫"), ("asagi", "浅葱"), ("kinari", "生成り"),
    ]
    private static let prefKey = "appIconColor"

    static var currentID: String {
        let saved = UserDefaults.standard.string(forKey: prefKey)
        return variants.contains { $0.id == saved } ? saved! : variants[0].id
    }

    static func image(_ id: String) -> NSImage? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Icons/\(id).png") else { return nil }
        return NSImage(contentsOf: url)
    }

    /// 色ちがいの絵が入っているか (ビルドしただけでアプリの形にしていないときは無い)
    static var isAvailable: Bool { image(variants[0].id) != nil }

    static func select(_ id: String) {
        guard variants.contains(where: { $0.id == id }) else { return }
        UserDefaults.standard.set(id, forKey: prefKey)
        apply(updateFinder: true)
    }

    /// 起動時と、選び直したときに呼ぶ。
    /// Dock (起動中) はすぐ変わる。Finder と、終了後の Dock のためにアプリ本体にも印を付ける
    static func apply(updateFinder: Bool) {
        let id = currentID
        let isDefault = id == variants[0].id
        if isDefault {
            NSApp.applicationIconImage = nil // アプリに入っている元のアイコンに戻す
        } else if let img = image(id) {
            NSApp.applicationIconImage = img
        }
        guard updateFinder, Bundle.main.bundleURL.pathExtension == "app" else { return }
        // 書き込めない場所 (読み取り専用のディスクなど) にあるときは変えられないが、起動中の Dock は変わる
        NSWorkspace.shared.setIcon(isDefault ? nil : image(id), forFile: Bundle.main.bundlePath, options: [])
    }
}

/// アイコンの色を選ぶ並び (設定画面用)
final class AppIconChooserView: NSStackView {
    private var buttons: [NSButton] = []

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        for (i, v) in AppIcon.variants.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(chosen(_:)))
            b.tag = i
            b.isBordered = false
            b.image = AppIcon.image(v.id)
            b.imageScaling = .scaleProportionallyUpOrDown
            b.toolTip = v.name
            b.setAccessibilityLabel("アイコンの色 \(v.name)")
            b.wantsLayer = true
            b.layer?.cornerRadius = 10
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 52).isActive = true
            b.heightAnchor.constraint(equalToConstant: 52).isActive = true
            buttons.append(b)
            addArrangedSubview(b)
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let current = AppIcon.currentID
        for (i, b) in buttons.enumerated() {
            let on = AppIcon.variants[i].id == current
            b.layer?.borderWidth = on ? 3 : 0
            b.layer?.borderColor = NSColor.controlAccentColor.cgColor
            b.layer?.backgroundColor = on ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor : nil
        }
    }

    @objc private func chosen(_ sender: NSButton) {
        AppIcon.select(AppIcon.variants[sender.tag].id)
        refresh()
    }
}
