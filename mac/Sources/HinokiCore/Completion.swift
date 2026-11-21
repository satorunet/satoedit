import Foundation

/// 入力補完 (VSCode の IntelliSense のような候補) の中身。画面は持たない
public enum Completion {
    public enum Kind: Int, Comparable {
        case function, snippet, keyword, type, property, tag, word
        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
        /// 候補の左に出す 1 文字
        public var badge: String {
            switch self {
            case .function: return "f"
            case .snippet: return "s"
            case .keyword: return "k"
            case .type: return "T"
            case .property: return "p"
            case .tag: return "<>"
            case .word: return "w"
            }
        }
    }

    public struct Item: Equatable {
        public var label: String
        public var kind: Kind
        /// 右側に薄く出す説明 (関数なら引数)
        public var detail: String
        /// 関数の引数 (detail のかっこの中)。引数ヒントで使う
        public var params: [String]
        public init(label: String, kind: Kind, detail: String = "", params: [String] = []) {
            self.label = label
            self.kind = kind
            self.detail = detail
            self.params = params
        }

        /// "name(a, b)" から関数の候補を作る
        public static func function(_ signature: String) -> Item {
            guard let open = signature.firstIndex(of: "("), signature.hasSuffix(")") else {
                return Item(label: signature, kind: .function)
            }
            let name = String(signature[..<open]).trimmingCharacters(in: .whitespaces)
            let inner = String(signature[signature.index(after: open)..<signature.index(before: signature.endIndex)])
            return Item(label: name, kind: .function, detail: "(" + inner + ")", params: splitParams(inner))
        }
    }

    /// 入れる文字と、入れたあとのカーソル位置 (文字の先頭から UTF-16 で何文字目か)
    public struct Insertion: Equatable {
        public var text: String
        public var caret: Int
    }

    // MARK: 単語

    /// 識別子に使える文字か (日本語は含めない。PHP の $ は頭だけ)
    public static func isWordChar(_ c: unichar) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24
    }

    /// CSS のプロパティ名のように - もつなぐか
    static func isWordChar(_ c: unichar, dash: Bool) -> Bool { isWordChar(c) || (dash && c == 0x2D) }

    /// caret の直前にある、書きかけの単語の範囲
    public static func prefixRange(in text: NSString, caret: Int, allowDash: Bool = false) -> NSRange {
        var s = min(caret, text.length)
        while s > 0, isWordChar(text.character(at: s - 1), dash: allowDash) { s -= 1 }
        // $ は単語の頭にだけ ($foo)。途中の $ (foo$bar) は区切り扱いにはしない
        return NSRange(location: s, length: caret - s)
    }

    /// 文書の中の単語 (3 文字以上)。多いときは先頭から max 個まで
    public static func words(in text: String, excluding: String? = nil, max: Int = 5000) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let u = Array(text.utf16.prefix(2_000_000))
        var i = 0
        while i < u.count && out.count < max {
            if isWordChar(u[i]) && !(u[i] >= 0x30 && u[i] <= 0x39) {
                var j = i + 1
                while j < u.count, isWordChar(u[j]) { j += 1 }
                if j - i >= 3, j - i <= 60 {
                    let w = String(decoding: u[i..<j], as: UTF16.self)
                    if w != excluding, seen.insert(w).inserted { out.append(w) }
                }
                i = j
            } else if isWordChar(u[i]) {
                // 数字で始まる並び (123abc) は飛ばす
                while i < u.count, isWordChar(u[i]) { i += 1 }
            } else {
                i += 1
            }
        }
        return out
    }

    /// 文書の中で定義されている関数 (function foo(a, b) / def foo(a): / func foo(...) など)
    public static func definedFunctions(in text: String) -> [Item] {
        let src = String(text.prefix(2_000_000))
        let patterns = [
            #"\bfunction\s*&?\s*([A-Za-z_$][\w$]*)\s*\(([^)]*)\)"#,                 // JS / PHP
            #"\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?function\s*\(([^)]*)\)"#,
            #"\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?\(([^)]*)\)\s*=>"#,
            #"\bdef\s+([A-Za-z_]\w*[?!]?)\s*\(([^)]*)\)"#,                          // Python / Ruby
            #"\bfunc\s+(?:\([^)]*\)\s*)?([A-Za-z_]\w*)\s*(?:<[^>]*>)?\s*\(([^)]*)\)"#, // Swift / Go
            #"\bfn\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\s*\(([^)]*)\)"#,                 // Rust
            #"\bsub\s+([A-Za-z_]\w*)\s*\(([^)]*)\)"#,
        ]
        var seen = Set<String>()
        var out: [Item] = []
        let ns = src as NSString
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            for m in re.matches(in: src, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1))
                guard seen.insert(name).inserted else { continue }
                let params = ns.substring(with: m.range(at: 2))
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                out.append(.function(name + "(" + params + ")"))
            }
        }
        return out
    }

    // MARK: 候補の絞り込み

    /// どれくらい合っているか。nil は合わない。小さいほど上に出す
    static func score(_ label: String, _ typed: String) -> Int? {
        if typed.isEmpty { return 1000 }
        if label.hasPrefix(typed) { return label == typed ? 1 : 0 }
        let l = label.lowercased(), t = typed.lowercased()
        if l.hasPrefix(t) { return 100 }
        // 頭文字が合っていて、残りの文字が順番どおりに含まれる (gEBI → getElementById)
        guard l.first == t.first else { return nil }
        var li = l.startIndex
        var gaps = 0
        for ch in t {
            guard let f = l[li...].firstIndex(of: ch) else { return nil }
            if f != li { gaps += 1 }
            li = l.index(after: f)
        }
        return 200 + gaps * 10
    }

    /// typed に合う候補を、合い方・種類・長さの順に並べる
    public static func filter(_ items: [Item], typed: String, limit: Int = 200) -> [Item] {
        var index: [String: Int] = [:]
        var scored: [(Int, Item)] = []
        for it in items {
            guard let s = score(it.label, typed) else { continue }
            // 同じ名前は、種類の上のもの (関数 > キーワード > 単語) を残す
            if let i = index[it.label] {
                if it.kind < scored[i].1.kind { scored[i].1 = it }
                continue
            }
            index[it.label] = scored.count
            scored.append((s, it))
        }
        scored.sort { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1.kind != b.1.kind { return a.1.kind < b.1.kind }
            if a.1.label.count != b.1.label.count { return a.1.label.count < b.1.label.count }
            return a.1.label < b.1.label
        }
        return scored.prefix(limit).map { $0.1 }
    }

    // MARK: 入れる文字

    /// 候補を選んだときに入れる文字。next はカーソルの直後の文字
    public static func insertion(for item: Item, next: unichar?, language: String?) -> Insertion {
        switch item.kind {
        case .function:
            // 直後にもう ( があれば名前だけ
            if next == 0x28 { return Insertion(text: item.label, caret: item.label.utf16.count) }
            let text = item.label + "()"
            let inside = !item.params.isEmpty
            return Insertion(text: text, caret: item.label.utf16.count + (inside ? 1 : 2))
        case .property where language == "CSS":
            if next == 0x3A { return Insertion(text: item.label, caret: item.label.utf16.count) }
            let text = item.label + ": ;"
            return Insertion(text: text, caret: item.label.utf16.count + 2)
        case .tag:
            if CompletionLibrary.voidTags.contains(item.label) {
                return Insertion(text: item.label + ">", caret: item.label.utf16.count + 1)
            }
            let text = item.label + "></" + item.label + ">"
            return Insertion(text: text, caret: item.label.utf16.count + 1)
        default:
            return Insertion(text: item.label, caret: item.label.utf16.count)
        }
    }

    // MARK: 引数ヒント

    /// "a, b = (1, 2), c" → ["a", "b = (1, 2)", "c"]
    public static func splitParams(_ inner: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var depth = 0
        for ch in inner {
            switch ch {
            case "(", "[", "{", "<": depth += 1; cur.append(ch)
            case ")", "]", "}", ">": depth = max(0, depth - 1); cur.append(ch)
            case "," where depth == 0:
                out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            default: cur.append(ch)
            }
        }
        let last = cur.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || !out.isEmpty { out.append(last) }
        return out.filter { !$0.isEmpty }
    }

    /// カーソルがどの関数呼び出しのかっこの中にいて、何番目の引数か
    public struct CallContext: Equatable {
        public var name: String
        public var argIndex: Int
        /// ( の位置
        public var openParen: Int
    }

    public static func callContext(in text: NSString, caret: Int) -> CallContext? {
        var depth = 0
        var commas = 0
        var i = min(caret, text.length) - 1
        let stop = max(0, caret - 3000)
        var quote: unichar? = nil
        while i >= stop {
            let c = text.character(at: i)
            if let q = quote {
                if c == q, i == 0 || text.character(at: i - 1) != 0x5C { quote = nil }
                i -= 1
                continue
            }
            switch c {
            case 0x22, 0x27, 0x60: quote = c
            case 0x29, 0x5D, 0x7D: depth += 1 // ) ] }
            case 0x5B, 0x7B: // [ {
                if depth == 0 { return nil }
                depth -= 1
            case 0x28: // (
                if depth > 0 { depth -= 1; break }
                var e = i
                while e > 0, text.character(at: e - 1) == 0x20 { e -= 1 }
                var s = e
                while s > 0, isWordChar(text.character(at: s - 1)) { s -= 1 }
                guard s < e else { return nil }
                let name = text.substring(with: NSRange(location: s, length: e - s))
                if ["if", "for", "while", "switch", "catch", "return", "elseif", "foreach", "function", "def", "func"].contains(name) { return nil }
                return CallContext(name: name, argIndex: commas, openParen: i)
            case 0x2C where depth == 0: commas += 1
            case 0x3B where depth == 0: return nil // ;
            default: break
            }
            i -= 1
        }
        return nil
    }

    /// HTML で、カーソルの直前が "<di" のようにタグ名を書きかけているか
    public static func isTagNameContext(_ text: NSString, prefixStart: Int) -> Bool {
        prefixStart > 0 && text.character(at: prefixStart - 1) == 0x3C
    }
}
