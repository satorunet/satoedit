import AppKit
import HinokiCore

extension Notification.Name {
    static let profilesDidChange = Notification.Name("SatomaruProfilesDidChange")
    static let viewSettingsDidChange = Notification.Name("SatomaruViewSettingsDidChange")
}

/// 言語プロファイルの読み込みと共有
enum Profiles {
    private(set) static var store = ProfileStore()

    static func reload() {
        store = ProfileStore()
        if let err = store.loadError {
            let alert = NSAlert()
            alert.messageText = L("言語プロファイルの読み込みに失敗しました")
            alert.informativeText = err
            alert.runModal()
        }
        NotificationCenter.default.post(name: .profilesDidChange, object: nil)
    }

    /// ~/.satoruEditor/profiles.json を (無ければ組み込み設定で作って) 開く
    static func openUserFile() {
        let url = ProfileStore.userFileURL
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try ProfileStore.builtInJSON().write(to: url)
            }
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error = error { NSApp.presentError(error) }
            }
        } catch {
            NSApp.presentError(error)
        }
    }
}

/// レイアウトマネージャの一時属性で色を付ける (テキスト本体は変更しないので Undo や変更フラグに影響しない)
final class SyntaxHighlighter {
    private weak var textView: NSTextView?
    private var scanner: SyntaxScanner?
    private var pending: DispatchWorkItem?
    /// これより大きい文書は色付けしない
    private let maxLength = 3_000_000
    private var colored = true

    init(textView: NSTextView) {
        self.textView = textView
    }

    func setProfile(_ profile: LanguageProfile?) {
        scanner = profile.map { SyntaxScanner(profile: $0) }
        highlightNow()
    }

    func textDidChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.highlightNow() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func highlightNow() {
        pending?.cancel()
        pending = nil
        guard let tv = textView, let storage = tv.textStorage else { return }
        // 上下分割しているときは両方の面に色を付ける
        let managers = storage.layoutManagers
        let ns = tv.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        // 大きすぎて色を付けていない文書では、消す作業 (全文をなめる) もしない
        if ns.length > maxLength && !colored { return }
        colored = ns.length <= maxLength
        managers.forEach {
            $0.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            $0.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
            $0.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
        }
        guard ns.length <= maxLength else { return }
        if let scanner = scanner {
            let tokens = scanner.tokens(in: ns)
            for lm in managers {
                for token in tokens {
                    lm.addTemporaryAttribute(.foregroundColor, value: Theme.color(for: token.kind), forCharacterRange: token.range)
                }
            }
        }
        // URL・メールアドレスは色と下線を付ける (⌘ クリックで開ける)
        guard linksEnabled, UserDefaults.standard.bool(forKey: "linkURLs") else { return }
        let links = LinkFinder.ranges(in: ns)
        for lm in managers {
            for r in links {
                lm.addTemporaryAttributes([
                    .foregroundColor: Theme.link,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: Theme.link,
                ], forCharacterRange: r)
            }
        }
    }

    /// 用紙モードではリンクの色付けをしない
    var linksEnabled = true {
        didSet { if oldValue != linksEnabled { highlightNow() } }
    }
}

/// 文章の中の URL・メールアドレスを探す
enum LinkFinder {
    // 日本語の文に続けて書かれた URL でも、かっこや句読点の手前で止める
    private static let regex = try? NSRegularExpression(
        pattern: "(?:https?|ftp)://[A-Za-z0-9\\-._~:/?#\\[\\]@!$&'*+,;=%]+|[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}",
        options: [])

    static func ranges(in ns: NSString, range: NSRange? = nil) -> [NSRange] {
        guard let regex = regex else { return [] }
        let r = range ?? NSRange(location: 0, length: ns.length)
        return regex.matches(in: ns as String, options: [], range: r).map { m -> NSRange in
            // 末尾の . , ) などは URL に含めない
            var range = m.range
            while range.length > 1 {
                let c = ns.character(at: NSMaxRange(range) - 1)
                if c == 0x2E || c == 0x2C || c == 0x29 || c == 0x3B || c == 0x3A || c == 0x27 || c == 0x21 || c == 0x3F {
                    range.length -= 1
                } else {
                    break
                }
            }
            return range
        }
    }

    /// 文字位置 index にあるリンク
    static func url(at index: Int, in ns: NSString) -> URL? {
        guard index >= 0, index < ns.length else { return nil }
        let line = ns.lineRange(for: NSRange(location: index, length: 0))
        for r in ranges(in: ns, range: line) where NSLocationInRange(index, r) {
            let text = ns.substring(with: r)
            if text.contains("://") { return URL(string: text) }
            return URL(string: "mailto:" + text)
        }
        return nil
    }
}
