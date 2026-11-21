import AppKit
import HinokiCore

/// アプリのアイコンの色ちがい。設定で選ぶと、Dock と Finder のアイコンが変わる。
/// 絵は scripts/make_icons.sh が作って、アプリの中 (Resources/Icons) に入れている。
enum AppIcon {
    /// (ファイル名, 画面に出す名前)。先頭が既定
    static let variants: [(id: String, name: String)] = [
        ("ai", L("藍")), ("shu", L("朱")), ("hinoki", L("ひのき緑")), ("sumi", L("墨")),
        ("yamabuki", L("山吹")), ("murasaki", L("紫")), ("asagi", L("浅葱")), ("kinari", L("生成り")),
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

/// アイコンの色を選ぶところ (設定画面用)。
/// めったに変えないものなので、ふだんはいまのアイコン 1 つだけを見せて、押したときだけほかの色の候補を出す
final class AppIconChooserView: NSStackView {
    private let current = NSButton(title: "", target: nil, action: nil)
    private let hint = SettingsUI.label(L("押すと、ほかの色を選べます"), small: true)
    private let choices = NSStackView()
    private(set) var isOpen = false

    private func iconButton(size: CGFloat, action: Selector) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.isBordered = false
        b.imageScaling = .scaleProportionallyUpOrDown
        b.wantsLayer = true
        b.layer?.cornerRadius = 10
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: size).isActive = true
        b.heightAnchor.constraint(equalToConstant: size).isActive = true
        return b
    }

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        alignment = .centerY
        current.target = self
        current.action = #selector(toggle(_:))
        current.isBordered = false
        current.imageScaling = .scaleProportionallyUpOrDown
        current.wantsLayer = true
        current.layer?.cornerRadius = 10
        current.layer?.borderWidth = 3
        current.layer?.borderColor = NSColor.controlAccentColor.cgColor
        current.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        current.translatesAutoresizingMaskIntoConstraints = false
        current.widthAnchor.constraint(equalToConstant: 52).isActive = true
        current.heightAnchor.constraint(equalToConstant: 52).isActive = true
        current.toolTip = L("押すと、ほかの色を選べます")
        choices.orientation = .horizontal
        choices.spacing = 6
        addArrangedSubview(current)
        addArrangedSubview(choices)
        addArrangedSubview(hint)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let id = AppIcon.currentID
        let name = AppIcon.variants.first { $0.id == id }?.name ?? ""
        current.image = AppIcon.image(id)
        current.setAccessibilityLabel(L("アプリのアイコン: {0}", name))
        choices.arrangedSubviews.forEach { choices.removeArrangedSubview($0); $0.removeFromSuperview() }
        if isOpen {
            // いま選んでいる色のほかを並べる
            for (i, v) in AppIcon.variants.enumerated() where v.id != id {
                let b = iconButton(size: 44, action: #selector(chosen(_:)))
                b.tag = i
                b.image = AppIcon.image(v.id)
                b.toolTip = v.name
                b.setAccessibilityLabel(L("アイコンの色 {0}", v.name))
                choices.addArrangedSubview(b)
            }
        }
        choices.isHidden = !isOpen
        hint.isHidden = isOpen
    }

    /// いまのアイコンを押すと、候補を出す / しまう
    @objc func toggle(_ sender: Any?) {
        isOpen.toggle()
        refresh()
    }

    @objc private func chosen(_ sender: NSButton) {
        AppIcon.select(AppIcon.variants[sender.tag].id)
        isOpen = false
        refresh()
    }

    /// 動作確認用: 候補の n 番目を選ぶ
    func chooseForTesting(_ n: Int) {
        if let b = choices.arrangedSubviews[n] as? NSButton { chosen(b) }
    }
}
