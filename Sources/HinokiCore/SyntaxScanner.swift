import Foundation

public enum TokenKind: String {
    case keyword, type, string, comment, number, tag
}

public struct Token: Equatable {
    public let range: NSRange
    public let kind: TokenKind

    public init(range: NSRange, kind: TokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// 文書全体を先頭から 1 回なめて色付け用のトークンを切り出す簡易スキャナ。
/// 正規表現の積み重ねと違い、コメント中の文字列・文字列中のコメント記号を正しく扱える。
public struct SyntaxScanner {
    public let profile: LanguageProfile
    private let keywords: Set<String>
    private let types: Set<String>
    private let lineComments: [[unichar]]
    private let blockComments: [([unichar], [unichar])]
    private let strings: [[unichar]]
    private let multilineStrings: [[unichar]]

    public init(profile: LanguageProfile) {
        self.profile = profile
        let fold: (String) -> String = profile.caseInsensitive ? { $0.lowercased() } : { $0 }
        keywords = Set(profile.keywords.map(fold))
        types = Set(profile.types.map(fold))
        lineComments = profile.lineComments.filter { !$0.isEmpty }.map { Array($0.utf16) }
        blockComments = profile.blockComments.compactMap { pair in
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else { return nil }
            return (Array(pair[0].utf16), Array(pair[1].utf16))
        }
        strings = profile.stringDelimiters.filter { !$0.isEmpty }.map { Array($0.utf16) }
        // 長い区切りから試す (""" を " より先に)
        multilineStrings = profile.multilineStrings.filter { !$0.isEmpty }.map { Array($0.utf16) }.sorted { $0.count > $1.count }
    }

    public func tokens(in string: NSString) -> [Token] {
        let n = string.length
        guard n > 0 else { return [] }
        var buf = [unichar](repeating: 0, count: n)
        string.getCharacters(&buf, range: NSRange(location: 0, length: n))

        var out: [Token] = []
        var i = 0

        func matches(_ p: [unichar], at pos: Int) -> Bool {
            guard pos + p.count <= n else { return false }
            for k in 0..<p.count where buf[pos + k] != p[k] { return false }
            return true
        }
        func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }
        func isIdentStart(_ c: unichar) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c >= 0x80
        }
        func isIdentChar(_ c: unichar) -> Bool { isIdentStart(c) || isDigit(c) }
        func emit(_ start: Int, _ end: Int, _ kind: TokenKind) {
            out.append(Token(range: NSRange(location: start, length: min(end, n) - start), kind: kind))
        }

        scan: while i < n {
            let c = buf[i]

            for lc in lineComments where matches(lc, at: i) {
                var j = i + lc.count
                while j < n && buf[j] != 0x0A { j += 1 }
                emit(i, j, .comment)
                i = j
                continue scan
            }

            for (open, close) in blockComments where matches(open, at: i) {
                var j = i + open.count
                while j < n && !matches(close, at: j) { j += 1 }
                j = min(n, j + close.count)
                emit(i, j, .comment)
                i = j
                continue scan
            }

            for d in multilineStrings where matches(d, at: i) {
                var j = i + d.count
                while j < n {
                    if buf[j] == 0x5C { j += 2; continue }
                    if matches(d, at: j) { j += d.count; break }
                    j += 1
                }
                j = min(n, j)
                emit(i, j, .string)
                i = j
                continue scan
            }

            for d in strings where matches(d, at: i) {
                var j = i + d.count
                while j < n && buf[j] != 0x0A {
                    if buf[j] == 0x5C { j += 2; continue }
                    if matches(d, at: j) { j += d.count; break }
                    j += 1
                }
                j = min(n, j)
                emit(i, j, .string)
                i = j
                continue scan
            }

            if profile.markupTags && c == 0x3C { // <
                var j = i + 1
                if j < n && (buf[j] == 0x2F || buf[j] == 0x3F || buf[j] == 0x21) { j += 1 } // / ? !
                let nameStart = j
                while j < n && (isIdentChar(buf[j]) || buf[j] == 0x2D || buf[j] == 0x3A) { j += 1 } // - :
                if j > nameStart {
                    emit(i, j, .tag)
                    i = j
                    continue scan
                }
            }

            if isDigit(c) && (i == 0 || !isIdentChar(buf[i - 1])) {
                var j = i + 1
                while j < n && (isIdentChar(buf[j]) || buf[j] == 0x2E) { j += 1 }
                emit(i, j, .number)
                i = j
                continue scan
            }

            if isIdentStart(c) {
                var j = i + 1
                while j < n && isIdentChar(buf[j]) { j += 1 }
                if c < 0x80 {
                    let word = String(decoding: buf[i..<j], as: UTF16.self)
                    let key = profile.caseInsensitive ? word.lowercased() : word
                    if keywords.contains(key) {
                        emit(i, j, .keyword)
                    } else if types.contains(key) || (profile.capitalizedIsType && c >= 65 && c <= 90) {
                        emit(i, j, .type)
                    }
                }
                i = j
                continue scan
            }

            i += 1
        }
        return out
    }
}
