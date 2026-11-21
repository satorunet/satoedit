import Foundation

/// 2 つの文章の、行ごとの違い (差分表示用)
public enum TextDiff {
    public enum Kind: Equatable { case same, removed, added, gap }

    public struct Row: Equatable {
        public var kind: Kind
        /// 編集前の行番号 (1 始まり)。足した行は nil
        public var oldLine: Int?
        /// いまの行番号 (1 始まり)。消した行は nil
        public var newLine: Int?
        public var text: String
        /// gap のとき、省いた同じ行の数
        public var skipped = 0

        public init(kind: Kind, oldLine: Int?, newLine: Int?, text: String, skipped: Int = 0) {
            self.kind = kind
            self.oldLine = oldLine
            self.newLine = newLine
            self.text = text
            self.skipped = skipped
        }
    }

    public struct Result: Equatable {
        public var rows: [Row]
        public var added: Int
        public var removed: Int
        /// 大きすぎて比べなかった
        public var tooLarge = false
        public var hasChanges: Bool { added > 0 || removed > 0 }
    }

    public static func lines(_ s: String) -> [String] {
        var out = s.components(separatedBy: "\n")
        for i in out.indices where out[i].hasSuffix("\r") { out[i].removeLast() }
        return out
    }

    /// context: 変わった行の前後に残す同じ行の数
    public static func compare(old: String, new: String, context: Int = 3, maxLines: Int = 200_000) -> Result {
        if old == new { return Result(rows: [], added: 0, removed: 0) }
        let a = lines(old), b = lines(new)
        if a.count + b.count > maxLines { return Result(rows: [], added: 0, removed: 0, tooLarge: true) }

        let diff = b.difference(from: a)
        var removedSet = Set<Int>(), insertedSet = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removedSet.insert(offset)
            case .insert(let offset, _, _): insertedSet.insert(offset)
            }
        }
        // 全部の行を並べる (同じ位置では、消した行を先に)
        var all: [Row] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removedSet.contains(i) {
                all.append(Row(kind: .removed, oldLine: i + 1, newLine: nil, text: a[i])); i += 1
            } else if j < b.count, insertedSet.contains(j) {
                all.append(Row(kind: .added, oldLine: nil, newLine: j + 1, text: b[j])); j += 1
            } else if i < a.count, j < b.count {
                all.append(Row(kind: .same, oldLine: i + 1, newLine: j + 1, text: b[j])); i += 1; j += 1
            } else {
                break
            }
        }
        // 変わった行から遠い同じ行は「…」にまとめる
        var keep = [Bool](repeating: false, count: all.count)
        for (k, r) in all.enumerated() where r.kind != .same {
            for x in max(0, k - context)...min(all.count - 1, k + context) { keep[x] = true }
        }
        var rows: [Row] = []
        var k = 0
        while k < all.count {
            if keep[k] { rows.append(all[k]); k += 1; continue }
            var e = k
            while e < all.count, !keep[e] { e += 1 }
            rows.append(Row(kind: .gap, oldLine: all[k].oldLine, newLine: all[k].newLine, text: "", skipped: e - k))
            k = e
        }
        return Result(rows: rows, added: insertedSet.count, removed: removedSet.count)
    }
}

// MARK: - Word の変更履歴のような表示 (文書の中に、消した字・足した字を並べる)

extension TextDiff {
    public struct Segment: Equatable {
        public var kind: Kind
        public var text: String
        /// この部分が始まる、いまの文書での行番号 (1 始まり)。押したときの移り先
        public var newLine: Int
        /// gap のとき、省いた同じ行の数
        public var skipped = 0

        public init(kind: Kind, text: String, newLine: Int, skipped: Int = 0) {
            self.kind = kind
            self.text = text
            self.newLine = newLine
            self.skipped = skipped
        }
    }

    public struct InlineResult: Equatable {
        public var segments: [Segment]
        public var added: Int
        public var removed: Int
        public var tooLarge = false
        public var hasChanges: Bool { added > 0 || removed > 0 }
    }

    /// context: 変わった所の前後に残す同じ行の数。それより離れた同じ行は「…」にまとめる
    public static func inline(old: String, new: String, context: Int = 2, maxLines: Int = 200_000) -> InlineResult {
        if old == new { return InlineResult(segments: [], added: 0, removed: 0) }
        let a = lines(old), b = lines(new)
        if a.count + b.count > maxLines { return InlineResult(segments: [], added: 0, removed: 0, tooLarge: true) }
        let diff = b.difference(from: a)
        var removedSet = Set<Int>(), insertedSet = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let o, _, _): removedSet.insert(o)
            case .insert(let o, _, _): insertedSet.insert(o)
            }
        }
        // 行を「同じ行」と「変わった塊 (消した行 + 足した行)」に分ける
        enum Piece { case same(String, Int), change([String], [String], Int) }
        var pieces: [Piece] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if (i < a.count && removedSet.contains(i)) || (j < b.count && insertedSet.contains(j)) {
                var olds: [String] = [], news: [String] = []
                let startLine = j + 1
                while i < a.count, removedSet.contains(i) { olds.append(a[i]); i += 1 }
                while j < b.count, insertedSet.contains(j) { news.append(b[j]); j += 1 }
                // 消した行と足した行が交互に来ることもあるので、続くかぎりまとめる
                while (i < a.count && removedSet.contains(i)) || (j < b.count && insertedSet.contains(j)) {
                    while i < a.count, removedSet.contains(i) { olds.append(a[i]); i += 1 }
                    while j < b.count, insertedSet.contains(j) { news.append(b[j]); j += 1 }
                }
                pieces.append(.change(olds, news, startLine))
            } else if i < a.count, j < b.count {
                pieces.append(.same(b[j], j + 1)); i += 1; j += 1
            } else { break }
        }
        // 変わった塊から離れた同じ行を省く
        var keep = [Bool](repeating: false, count: pieces.count)
        for (k, p) in pieces.enumerated() {
            if case .change = p { for x in max(0, k - context)...min(pieces.count - 1, k + context) { keep[x] = true } }
        }
        var out: [Segment] = []
        func emit(_ kind: Kind, _ text: String, _ line: Int) {
            guard !text.isEmpty else { return }
            if let last = out.last, last.kind == kind, kind != .gap {
                out[out.count - 1].text += text
            } else {
                out.append(Segment(kind: kind, text: text, newLine: line))
            }
        }
        var k = 0
        while k < pieces.count {
            if !keep[k] {
                var e = k
                while e < pieces.count, !keep[e] { e += 1 }
                var line = 1
                if case .same(_, let l) = pieces[k] { line = l }
                out.append(Segment(kind: .gap, text: "", newLine: line, skipped: e - k))
                k = e
                continue
            }
            switch pieces[k] {
            case .same(let text, let line):
                emit(.same, text + "\n", line)
            case .change(let olds, let news, let line):
                inlineChange(olds.joined(separator: "\n"), news.joined(separator: "\n"),
                             hasOld: !olds.isEmpty, hasNew: !news.isEmpty, line: line, emit: emit)
            }
            k += 1
        }
        // 最後の改行は見せない
        if let last = out.indices.last, out[last].kind == .same, out[last].text.hasSuffix("\n") {
            out[last].text.removeLast()
            if out[last].text.isEmpty { out.removeLast() }
        }
        return InlineResult(segments: out, added: insertedSet.count, removed: removedSet.count)
    }

    /// 変わった塊の中を、字ごとに比べる。似ていないときは「全部消して、全部足した」にする (細切れで読めなくならないように)
    private static func inlineChange(_ old: String, _ new: String, hasOld: Bool, hasNew: Bool, line: Int,
                                     emit: (Kind, String, Int) -> Void) {
        let x = Array(old), y = Array(new)
        let small = x.count + y.count <= 6000
        if hasOld, hasNew, small {
            let d = y.difference(from: x)
            var rem = Set<Int>(), ins = Set<Int>()
            for c in d {
                switch c {
                case .remove(let o, _, _): rem.insert(o)
                case .insert(let o, _, _): ins.insert(o)
                }
            }
            let common = x.count - rem.count
            // 同じ字が半分もなければ、行ごと入れ替えたものとして見せる
            if Double(common) >= 0.5 * Double(max(x.count, y.count)) {
                var i = 0, j = 0
                while i < x.count || j < y.count {
                    if i < x.count, rem.contains(i) { emit(.removed, String(x[i]), line); i += 1 }
                    else if j < y.count, ins.contains(j) { emit(.added, String(y[j]), line); j += 1 }
                    else if i < x.count, j < y.count { emit(.same, String(y[j]), line); i += 1; j += 1 }
                    else { break }
                }
                emit(.same, "\n", line)
                return
            }
        }
        if hasOld { emit(.removed, old + (hasNew ? "\n" : "\n"), line) }
        if hasNew { emit(.added, new + "\n", line) }
    }
}
