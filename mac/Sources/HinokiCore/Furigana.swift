import Foundation

/// 自動ふりがな: 文章の漢字に読みを付ける。
/// 言葉の区切りと読みは macOS に入っている日本語の辞書 (CFStringTokenizer) まかせなので、人名などは外れることがある。
/// 送りがなには付けない (「食べる」なら「食」に「た」だけ)。Windows 版の core/furigana.js と同じ決まり。
public enum Furigana {
    /// 漢字 (々 〆 ヵ ヶ も漢字と同じ扱い)
    static func isKanji(_ c: unichar) -> Bool {
        (0x3400...0x4DBF).contains(c) || (0x4E00...0x9FFF).contains(c) || (0xF900...0xFAFF).contains(c)
            || c == 0x3005 || c == 0x3006 || c == 0x30F5 || c == 0x30F6
    }

    static func containsKanji(_ s: NSString) -> Bool {
        for i in 0..<s.length where isKanji(s.character(at: i)) { return true }
        return false
    }

    /// カタカナ → ひらがな
    public static func toHiragana(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if (0x30A1...0x30F6).contains(u.value), let h = Unicode.Scalar(u.value - 0x60) {
                out.append(h)
            } else {
                out.append(u)
            }
        }
        return String(out)
    }

    /// 1 つの単語 (表記と読み) → 漢字のかたまりごとの読み (from / to は単語の中の位置)。送りがなには付けない。
    /// かなの部分を手がかりに読みを切り分ける。切り分けられないときは単語全体に読みを付ける
    public static func splitWord(surface: String, reading: String) -> [Genko.Ruby] {
        let yomi = toHiragana(reading)
        let ns = surface as NSString
        // 表記を「漢字のかたまり」と「かなのかたまり」に分ける
        var parts: [(kanji: Bool, from: Int, to: Int)] = []
        for i in 0..<ns.length {
            let kanji = isKanji(ns.character(at: i))
            if let last = parts.last, last.kanji == kanji {
                parts[parts.count - 1].to = i + 1
            } else {
                parts.append((kanji, i, i + 1))
            }
        }
        guard parts.contains(where: { $0.kanji }) else { return [] }
        let whole = [Genko.Ruby(from: 0, to: ns.length, reading: yomi)]
        var pattern = "^"
        for p in parts {
            pattern += p.kanji ? "(.+?)"
                : NSRegularExpression.escapedPattern(for: toHiragana(ns.substring(with: NSRange(location: p.from, length: p.to - p.from))))
        }
        pattern += "$"
        let y = yomi as NSString
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: yomi, range: NSRange(location: 0, length: y.length)) else { return whole }
        var out: [Genko.Ruby] = []
        var group = 1
        for p in parts where p.kanji {
            let r = m.range(at: group)
            group += 1
            guard r.location != NSNotFound else { return whole }
            out.append(Genko.Ruby(from: p.from, to: p.to, reading: y.substring(with: r)))
        }
        return out
    }

    /// 言葉の読み (ひらがな)。辞書が読みを持っていなければ nil
    private static func reading(of tokenizer: CFStringTokenizer) -> String? {
        // 辞書からはローマ字の読みが取れるので、ひらがなに直す
        guard let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String,
              !latin.isEmpty else { return nil }
        let kana = NSMutableString(string: latin)
        guard CFStringTransform(kana, nil, kCFStringTransformLatinHiragana, false) else { return nil }
        // ひらがなに直しきれなかったもの (英字が残ったもの) は使わない
        for u in (kana as String).unicodeScalars where !((0x3041...0x3096).contains(u.value) || u.value == 0x30FC) { return nil }
        return kana as String
    }

    /// 文章 → ふりがなの一覧 (位置は文章の先頭から、UTF-16 単位)
    public static func ruby(for text: String) -> [Genko.Ruby] {
        var out: [Genko.Ruby] = []
        let locale = Locale(identifier: "ja") as CFLocale
        var base = 0
        for line in text.components(separatedBy: "\n") {
            let ns = line as NSString
            defer { base += ns.length + 1 }
            guard ns.length <= 20000, containsKanji(ns),
                  let tokenizer = CFStringTokenizerCreate(nil, ns, CFRange(location: 0, length: ns.length),
                                                          kCFStringTokenizerUnitWordBoundary, locale) else { continue }
            while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
                let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                guard r.location >= 0, r.length > 0, r.location + r.length <= ns.length else { continue }
                let surface = ns.substring(with: NSRange(location: r.location, length: r.length))
                guard containsKanji(surface as NSString), let yomi = reading(of: tokenizer) else { continue }
                for part in splitWord(surface: surface, reading: yomi) {
                    // 熟語は 1 字ずつのマスに合うように、読みを字ごとに分ける (分けられなければ熟語全体に)
                    for each in perKanji(part, surface: surface as NSString) {
                        out.append(Genko.Ruby(from: base + r.location + each.from, to: base + r.location + each.to, reading: each.reading))
                    }
                }
            }
        }
        return out
    }

    // MARK: 1 字ずつの読み

    /// 1 字ずつ読みを分けない言葉 (熟字訓: 字ごとの読みがない)
    static let wholeWords: Set<String> = [
        "今日", "明日", "昨日", "今朝", "今年", "去年", "一昨日", "明後日", "大人", "一人", "二人", "一日", "二日", "二十日",
        "上手", "下手", "部屋", "景色", "土産", "時計", "眼鏡", "果物", "七夕", "梅雨", "紅葉", "竹刀", "相撲", "田舎",
        "息子", "素人", "玄人", "仲人", "海女", "乙女", "八百屋", "真面目", "風邪", "吹雪", "雪崩", "五月雨", "時雨", "日和",
        "芝生", "清水", "足袋", "木綿", "浴衣", "為替", "迷子", "河原", "川原", "母屋", "最寄", "博士", "眼鏡", "太刀", "老舗",
        "百足", "蜜柑", "欠伸", "心地", "神楽", "白髪", "息吹", "笑顔", "野良", "小豆", "大和", "今宵",
    ]

    /// 漢字 1 字だけを引いたときの読み (手がかりに使う。外れていることも多い)
    private static var singleCache: [String: String] = [:]
    private static let singleLock = NSLock()
    static func singleReading(_ ch: String) -> String? {
        singleLock.lock()
        if let r = singleCache[ch] { singleLock.unlock(); return r.isEmpty ? nil : r }
        singleLock.unlock()
        var found = ""
        let ns = ch as NSString
        if let tok = CFStringTokenizerCreate(nil, ns, CFRange(location: 0, length: ns.length), kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale),
           CFStringTokenizerAdvanceToNextToken(tok) != [], CFStringTokenizerGetCurrentTokenRange(tok).length == ns.length {
            found = reading(of: tok) ?? ""
        }
        singleLock.lock()
        singleCache[ch] = found
        singleLock.unlock()
        return found.isEmpty ? nil : found
    }

    /// 漢字だけのかたまりに付いた読み → 1 字ごとの読み。分けられないときはそのまま返す
    static func perKanji(_ part: Genko.Ruby, surface: NSString) -> [Genko.Ruby] {
        guard part.to - part.from >= 2, part.from >= 0, part.to <= surface.length else { return [part] }
        let word = surface.substring(with: NSRange(location: part.from, length: part.to - part.from))
        let chars = word.map { String($0) }
        guard chars.count >= 2, !wholeWords.contains(word),
              chars.allSatisfy({ c in (c as NSString).length >= 1 && isKanji((c as NSString).character(at: 0)) }) else { return [part] }
        var known: [String?] = []
        for c in chars { known.append(c == "々" ? known.last ?? nil : singleReading(c)) }
        guard let pieces = splitReading(part.reading, count: chars.count, known: known) else { return [part] }
        var out: [Genko.Ruby] = []
        var at = part.from
        for (c, p) in zip(chars, pieces) {
            let len = (c as NSString).length
            out.append(Genko.Ruby(from: at, to: at + len, reading: p))
            at += len
        }
        return out
    }

    /// 読みを count 個に分ける。known は字ごとの手がかりの読み (なければ nil)。
    /// 小さい字 (ゃ・っ など)・ん・ー は前の字と離さない。手がかりと合う分け方を選び、同じなら字数がそろう分け方にする
    public static func splitReading(_ reading: String, count: Int, known: [String?]) -> [String]? {
        var units: [String] = []
        for ch in reading {
            if let last = units.last, "ゃゅょぁぃぅぇぉゎっんー".contains(ch) {
                units[units.count - 1] = last + String(ch)
            } else {
                units.append(String(ch))
            }
        }
        guard count >= 2, units.count >= count, units.count <= 16 else { return nil }
        var best: (score: Double, pieces: [String])?
        func search(_ start: Int, _ left: Int, _ acc: [String]) {
            if left == 1 {
                let pieces = acc + [units[start...].joined()]
                let s = score(pieces, known: known)
                if best == nil || s > best!.score { best = (s, pieces) }
                return
            }
            // 残りの字それぞれに 1 つは残す
            guard start + left <= units.count else { return }
            for end in (start + 1)...(units.count - left + 1) {
                search(end, left - 1, acc + [units[start..<end].joined()])
            }
        }
        search(0, count, [])
        return best?.pieces
    }

    private static func score(_ pieces: [String], known: [String?]) -> Double {
        var s = 0.0
        for (i, p) in pieces.enumerated() {
            guard i < known.count, let k = known[i] else { continue }
            if sameReading(p, k, last: i == pieces.count - 1) { s += 10 }
        }
        // 字数のばらつきが小さいほどよい (同じなら前の字を長く)
        let lens = pieces.map { Double($0.count) }
        let mean = lens.reduce(0, +) / Double(lens.count)
        s -= lens.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        if let first = lens.first, let last = lens.last, first > last { s += 0.01 }
        return s
    }

    /// 連濁 (か→が) と促音 (つ→っ) を許して、読みが同じか
    static func sameReading(_ piece: String, _ known: String, last: Bool) -> Bool {
        func plain(_ s: String) -> [Character] {
            Array((s.decomposedStringWithCanonicalMapping.unicodeScalars.filter { $0.value != 0x3099 && $0.value != 0x309A })
                .map { Character($0) })
        }
        var a = plain(piece), b = plain(known)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if !last, a.count == b.count, a.last == "っ", let e = b.last, "つくちき".contains(e) { a.removeLast(); b.removeLast() }
        return a == b
    }
}
