import Foundation

/// 前の識別子 (net.satoru.sakubunEditor、net.satoru.satoedit、さらに前の local.satomaru.editor) の設定を、いまの識別子に引き継ぐ (最初に起動したとき 1 回だけ)
enum SettingsMigration {
    /// 新しいものから順に。最初に見つかった設定を引き継ぐ
    static let oldDomains = ["net.satoru.sakubunEditor", "net.satoru.satoedit", "local.satomaru.editor"]
    private static let doneKey = "migratedFromOldIdentifier"

    static func run() {
        let d = UserDefaults.standard
        guard let current = Bundle.main.bundleIdentifier, !oldDomains.contains(current), !d.bool(forKey: doneKey) else { return }
        defer { d.set(true, forKey: doneKey) }
        // いまの識別子の設定がまだほとんど無いときだけ (新しい版で設定したものを上書きしない)
        let now = d.persistentDomain(forName: current) ?? [:]
        guard now.count <= 2 else { return }
        for domain in oldDomains {
            guard let old = d.persistentDomain(forName: domain), !old.isEmpty else { continue }
            d.setPersistentDomain(old.merging(now) { _, new in new }, forName: current)
            return
        }
    }
}
