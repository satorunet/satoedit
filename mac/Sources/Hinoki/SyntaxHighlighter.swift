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
///
/// 大きな文書でも打つ手を止めないように (AOI: 見ている所の近くだけ処理する):
/// - 文書全体の字句の切り出しは裏のスレッドで行う (コメントや文字列が何行も続くことがあるので、切り出しは全体で)
/// - 色を塗るのは、画面に見えている範囲とその前後だけ。スクロールしたら、新しく見えた所を塗る
/// - URL を探すのも、塗る範囲の中だけ
final class SyntaxHighlighter {
    private weak var textView: NSTextView?
    private var scanner: SyntaxScanner?
    private var pending: DispatchWorkItem?
    /// これより大きい文書は色付けしない
    private let maxLength = 3_000_000
    private var colored = true
    private static let queue = DispatchQueue(label: "satoru.highlight", qos: .userInitiated)

    /// 文章の版 (書き換えるたびに増やす) と、いま持っている切り出し結果の版
    private var version = 0
    private var tokens: [Token] = []
    private var tokensVersion = -1
    /// 色を塗り終えた範囲 (面ごと。この範囲は今の切り出し結果で塗ってある)
    private var painted: [ObjectIdentifier: NSRange] = [:]
    private var scrollObserver: NSObjectProtocol?

    init(textView: NSTextView) {
        self.textView = textView
        // 分割したもう一方の面も含め、この文書の面がスクロールしたら、新しく見えた所を塗る
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self = self, let clip = note.object as? NSClipView, let tv = clip.documentView as? NSTextView,
                  let mine = self.textView?.textStorage, tv.textStorage === mine else { return }
            self.paintVisible()
        }
    }

    deinit {
        if let o = scrollObserver { NotificationCenter.default.removeObserver(o) }
    }

    func setProfile(_ profile: LanguageProfile?) {
        scanner = profile.map { SyntaxScanner(profile: $0) }
        highlightNow()
    }

    func textDidChange() {
        version += 1
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scanInBackground() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// 今の文章を写して、裏で切り出す。終わったときに文章が変わっていなければ、見えている所を塗る
    private func scanInBackground() {
        pending = nil
        guard let tv = textView else { return }
        let ns = (tv.string as NSString).copy() as! NSString
        if !prepare(length: ns.length) { return }
        let v = version, scanner = scanner
        Self.queue.async { [weak self] in
            let list = scanner?.tokens(in: ns) ?? []
            DispatchQueue.main.async {
                guard let self = self, self.version == v else { return }
                self.tokens = list
                self.tokensVersion = v
                self.painted.removeAll()
                self.paintVisible()
            }
        }
    }

    /// すぐに色を付け直す (言語を変えたときなど)
    func highlightNow() {
        pending?.cancel()
        pending = nil
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        if !prepare(length: ns.length) { return }
        tokens = scanner?.tokens(in: ns) ?? []
        tokensVersion = version
        painted.removeAll()
        paintVisible()
    }

    /// 大きすぎる文書では色を消して false (消す作業 = 全文をなめるのは 1 回だけ)
    private func prepare(length: Int) -> Bool {
        guard length > maxLength else { colored = true; return true }
        if colored, let storage = textView?.textStorage {
            let full = NSRange(location: 0, length: storage.length)
            storage.layoutManagers.forEach { Self.clear($0, full) }
        }
        colored = false
        tokens = []
        painted.removeAll()
        return false
    }

    private static func clear(_ lm: NSLayoutManager, _ range: NSRange) {
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
        lm.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
    }

    /// 見えている範囲 (と前後に 1 画面ぶんずつ) を、まだ塗っていなければ塗る
    func paintVisible() {
        guard colored, tokensVersion == version, let storage = textView?.textStorage else { return }
        let ns = storage.string as NSString
        for lm in storage.layoutManagers {
            guard let tv = lm.firstTextView, let tc = tv.textContainer else { continue }
            var visible = tv.visibleRect
            visible.origin.x -= tv.textContainerOrigin.x
            visible.origin.y -= tv.textContainerOrigin.y
            let glyphs = lm.glyphRange(forBoundingRectWithoutAdditionalLayout: visible, in: tc)
            let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            // 前後に見えている量ぶん (少なくとも 2000 字) 広げ、行の頭・終わりにそろえる
            let margin = max(2000, chars.length)
            let from = max(0, chars.location - margin), to = min(ns.length, NSMaxRange(chars) + margin)
            let target = ns.lineRange(for: NSRange(location: from, length: to - from))
            if let done = painted[ObjectIdentifier(lm)], NSIntersectionRange(done, chars) == chars, done.length > 0 || chars.length == 0 {
                continue
            }
            paint(lm, target, ns)
            painted[ObjectIdentifier(lm)] = target
        }
    }

    /// range を塗る。いま付いている色と違う所だけ書き換える
    /// (全部消して付け直すと、見えている所がまるごと描き直しになり、打つたびに画面が引っかかる)
    private func paint(_ lm: NSLayoutManager, _ range: NSRange, _ ns: NSString) {
        // 付けたい色の並び (前から順・重ならない)
        var colors: [(range: NSRange, color: NSColor)] = []
        var lo = 0, hi = tokens.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(tokens[mid].range) <= range.location { lo = mid + 1 } else { hi = mid }
        }
        var i = lo
        while i < tokens.count, tokens[i].range.location < NSMaxRange(range) {
            let r = NSIntersectionRange(tokens[i].range, range)
            if r.length > 0 { colors.append((r, Theme.color(for: tokens[i].kind))) }
            i += 1
        }
        // URL・メールアドレスは色と下線を付ける (⌘ クリックで開ける)。字句の色の上に重ねる
        let links = linksEnabled && UserDefaults.standard.bool(forKey: "linkURLs") ? LinkFinder.ranges(in: ns, range: range) : []
        for link in links { colors = Self.overlay(colors, link, Theme.link) }
        Self.apply(lm, .foregroundColor, colors.map { ($0.range, $0.color as Any) }, in: range)
        let underline = NSUnderlineStyle.single.rawValue as Any
        Self.apply(lm, .underlineStyle, links.map { ($0, underline) }, in: range)
        Self.apply(lm, .underlineColor, links.map { ($0, Theme.link as Any) }, in: range)
    }

    /// 並び runs の上に、range を color で上書きする
    private static func overlay(_ runs: [(range: NSRange, color: NSColor)], _ range: NSRange, _ color: NSColor) -> [(range: NSRange, color: NSColor)] {
        var out: [(range: NSRange, color: NSColor)] = []
        var placed = false
        for run in runs {
            let end = NSMaxRange(run.range)
            if end <= range.location || run.range.location >= NSMaxRange(range) {
                if !placed && run.range.location >= NSMaxRange(range) { out.append((range, color)); placed = true }
                out.append(run)
                continue
            }
            // 重なる: 前と後ろの残りだけ残す
            if run.range.location < range.location {
                out.append((NSRange(location: run.range.location, length: range.location - run.range.location), run.color))
            }
            if !placed { out.append((range, color)); placed = true }
            if end > NSMaxRange(range) {
                out.append((NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range)), run.color))
            }
        }
        if !placed { out.append((range, color)) }
        return out
    }

    /// 一時属性 key を、range の中で want (前から順・重ならない) のとおりにする。もう同じ所は触らない
    private static func apply(_ lm: NSLayoutManager, _ key: NSAttributedString.Key, _ want: [(NSRange, Any)], in range: NSRange) {
        // want の切れ目のあいだ (何も付けない所) も含めて、前から順に見ていく
        var segments: [(NSRange, Any?)] = []
        var pos = range.location
        for (r, v) in want {
            if r.location > pos { segments.append((NSRange(location: pos, length: r.location - pos), nil)) }
            segments.append((r, v))
            pos = NSMaxRange(r)
        }
        if pos < NSMaxRange(range) { segments.append((NSRange(location: pos, length: NSMaxRange(range) - pos), nil)) }
        for (seg, v) in segments where seg.length > 0 {
            var j = seg.location
            while j < NSMaxRange(seg) {
                var eff = NSRange(location: 0, length: 0)
                let now = lm.temporaryAttribute(key, atCharacterIndex: j, longestEffectiveRange: &eff, in: seg)
                let part = NSIntersectionRange(eff, seg).length > 0 ? NSIntersectionRange(eff, seg) : NSRange(location: j, length: NSMaxRange(seg) - j)
                let same: Bool
                switch (now, v) {
                case (nil, nil): same = true
                case let (a?, b?): same = (a as AnyObject).isEqual(b)
                default: same = false
                }
                if !same {
                    if let v = v { lm.addTemporaryAttribute(key, value: v, forCharacterRange: part) }
                    else { lm.removeTemporaryAttribute(key, forCharacterRange: part) }
                }
                j = max(NSMaxRange(part), j + 1)
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
