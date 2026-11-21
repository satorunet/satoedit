import AppKit

/// フッター右側の項目の並び。項目ごとに区切り線があり、クリックするとその場で変更できる。
final class StatusCellsView: NSStackView {
    struct Item {
        let id: String
        let title: String
        let tip: String
    }

    /// (項目の id, クリックされた項目のビュー)
    var onClick: ((String, NSView) -> Void)?
    var textColor: NSColor = .labelColor { didSet { buttons.values.forEach { style($0) } } }
    var separatorColor: NSColor = .separatorColor { didSet { separators.forEach { $0.layer?.backgroundColor = separatorColor.cgColor } } }

    private var buttons: [String: NSButton] = [:]
    private var separators: [NSView] = []
    private var order: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .horizontal
        spacing = 0
        alignment = .centerY
    }

    required init?(coder: NSCoder) { fatalError() }

    private func style(_ b: NSButton) {
        b.attributedTitle = NSAttributedString(string: b.title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: textColor,
        ])
    }

    /// 項目を並べ直す (同じ並びなら文字だけ更新)
    func set(_ items: [Item]) {
        if items.map({ $0.id }) != order {
            arrangedSubviews.forEach { removeArrangedSubview($0); $0.removeFromSuperview() }
            buttons = [:]
            separators = []
            order = items.map { $0.id }
            for item in items {
                let line = NSView()
                line.wantsLayer = true
                line.layer?.backgroundColor = separatorColor.cgColor
                line.translatesAutoresizingMaskIntoConstraints = false
                line.widthAnchor.constraint(equalToConstant: 1).isActive = true
                line.heightAnchor.constraint(equalToConstant: 16).isActive = true
                separators.append(line)
                let b = NSButton(title: "", target: self, action: #selector(clicked(_:)))
                b.isBordered = false
                b.identifier = NSUserInterfaceItemIdentifier(item.id)
                b.setContentHuggingPriority(.required, for: .horizontal)
                // 文字の左右に余白を取る
                let holder = NSView()
                holder.translatesAutoresizingMaskIntoConstraints = false
                b.translatesAutoresizingMaskIntoConstraints = false
                holder.addSubview(b)
                NSLayoutConstraint.activate([
                    b.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 9),
                    b.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -9),
                    b.topAnchor.constraint(equalTo: holder.topAnchor),
                    b.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
                ])
                buttons[item.id] = b
                addArrangedSubview(line)
                addArrangedSubview(holder)
            }
        }
        for item in items {
            guard let b = buttons[item.id] else { continue }
            if b.title != item.title {
                b.title = item.title
                style(b)
            }
            b.toolTip = item.tip
        }
    }

    @objc private func clicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        onClick?(id, sender)
    }
}
