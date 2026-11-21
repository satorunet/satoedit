import UIKit
import Security

/// 設定 (UserDefaults)。名前は Mac 版とそろえてある
enum Prefs {
    static let didChange = Notification.Name("PrefsDidChange")
    private static var d: UserDefaults { .standard }

    static func registerDefaults() {
        d.register(defaults: [
            "lineNumbers": false, "fontStyle": "gothic", "fontSize": 17.0, "genkoFurigana": true, "genkoAutoFormat": true,
            "shareVisibility": "unlisted", "shareDays": 30, "shareKeepHistory": true, "language": "auto",
        ])
    }

    static func changed() { NotificationCenter.default.post(name: didChange, object: nil) }

    static var lineNumbers: Bool {
        get { d.bool(forKey: "lineNumbers") }
        set { d.set(newValue, forKey: "lineNumbers"); changed() }
    }
    /// "mincho" / "gothic" / "mono"
    static var fontStyle: String {
        get { d.string(forKey: "fontStyle") ?? "gothic" }
        set { d.set(newValue, forKey: "fontStyle"); changed() }
    }
    static var fontSize: CGFloat {
        get { CGFloat(d.double(forKey: "fontSize")) }
        set { d.set(Double(newValue), forKey: "fontSize"); changed() }
    }
    static var furigana: Bool {
        get { d.bool(forKey: "genkoFurigana") }
        set { d.set(newValue, forKey: "genkoFurigana"); changed() }
    }
    static var genkoAutoFormat: Bool {
        get { d.bool(forKey: "genkoAutoFormat") }
        set { d.set(newValue, forKey: "genkoAutoFormat"); changed() }
    }
    static var privacyCheckOff: Bool {
        get { d.bool(forKey: "sharePrivacyCheckOff") }
        set { d.set(newValue, forKey: "sharePrivacyCheckOff") }
    }

    static func editorFont(size: CGFloat? = nil) -> UIFont {
        let s = size ?? fontSize
        switch fontStyle {
        case "mincho": return UIFont(name: "HiraMinProN-W3", size: s) ?? .systemFont(ofSize: s)
        case "mono":
            // 英数字は等幅 (Menlo)、日本語はヒラギノ角ゴ
            let base = UIFont(name: "Menlo-Regular", size: s) ?? .monospacedSystemFont(ofSize: s, weight: .regular)
            let desc = base.fontDescriptor.addingAttributes([.cascadeList: [UIFontDescriptor(name: "HiraginoSans-W3", size: s)]])
            return UIFont(descriptor: desc, size: s)
        default: return UIFont(name: "HiraginoSans-W3", size: s) ?? .systemFont(ofSize: s)
        }
    }
}

/// API キーの保管 (iOS のキーチェーン)
enum Keychain {
    static let service = "net.satoru.satoruEditor.ios"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        delete(account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

extension UIColor {
    /// "#RRGGBB" / "#RRGGBBAA"
    convenience init(hex: String) {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 6 { s += "FF" }
        let v = UInt64(s, radix: 16) ?? 0
        self.init(red: CGFloat((v >> 24) & 0xFF) / 255, green: CGFloat((v >> 16) & 0xFF) / 255,
                  blue: CGFloat((v >> 8) & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
    }
}

extension UIViewController {
    func showMessage(_ title: String, _ message: String? = nil) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("OK"), style: .default))
        present(a, animated: true)
    }

    /// 1 行の入力を求める
    func askText(title: String, message: String? = nil, initial: String = "", placeholder: String = "", ok: String = L("OK"),
                 done: @escaping (String) -> Void) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addTextField { f in
            f.text = initial
            f.placeholder = placeholder
            f.clearButtonMode = .whileEditing
        }
        a.addAction(UIAlertAction(title: L("キャンセル"), style: .cancel))
        a.addAction(UIAlertAction(title: ok, style: .default) { _ in done(a.textFields?.first?.text ?? "") })
        present(a, animated: true)
    }

    /// 画面の下に、すぐ消えるひとこと
    func toast(_ text: String) {
        guard let host = view.window ?? view else { return }
        let label = PaddedLabel()
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -60),
        ])
        UIView.animate(withDuration: 0.3, delay: 1.6, options: []) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
    }
}

final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 14, dy: 8)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + 28, height: s.height + 16)
    }
}
