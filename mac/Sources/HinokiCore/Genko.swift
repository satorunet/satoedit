import Foundation

/// 原稿用紙 (原稿用紙) の決まり。
/// A4 横、1 列 20 マス × 20 列 (400 字)。中央に余白 (魚尾)、各列の右にふりがなの枠がある標準的な形。
/// 自動整形では 題名は 3 マス下げ、名前は下寄せ (下を 1 マス空ける)、本文の段落は 1 マス下げ。
/// 文章の位置はすべて UTF-16 単位 (NSString と同じ)。Windows 版の shared/genko.js と同じ決まり。
public enum Genko {
    public static let rows = 20
    public static let columnsPerSheet = 20

    /// 用紙の寸法 (mm)。A4 横 297 × 210
    public enum Sheet {
        public static let width = 297.0
        public static let height = 210.0
        /// 1 マス
        public static let cell = 9.0
        /// ふりがなの枠の幅
        public static let ruby = 3.0
        /// 1 列ぶん (マス + ふりがな)
        public static let pitch = 12.0
        /// 中央の余白
        public static let center = 12.0
        public static let left = 22.5
        public static let top = 15.0
        public static let gridWidth = pitch * Double(Genko.columnsPerSheet) + center
        public static let gridHeight = cell * Double(Genko.rows)
    }

    /// 用紙の中の列 k (0 = いちばん右) の、マスの左端の x (mm)
    public static func columnX(_ k: Int) -> Double {
        let right = Sheet.left + Sheet.gridWidth - Double(k) * Sheet.pitch - (k >= columnsPerSheet / 2 ? Sheet.center : 0)
        return right - Sheet.pitch
    }

    /// 1 列ぶん
    public struct Column: Equatable {
        /// 20 個 (文字か nil)
        public var cells: [String?]
        /// 20 個 (その文字の位置。なければ -1)
        public var offs: [Int]
        /// 段落番号
        public var paragraph: Int
        /// この列が受け持つ文章の位置の範囲 (to はこの列の最後の文字の次)
        public var from: Int
        public var to: Int
        /// 最初の文字の行
        public var first: Int
        /// 段落の最後の列 (ここの to が改行の位置)
        public var last: Bool

        /// 文字が入っているいちばん下のマスの次 (何も無ければ first)
        public var end: Int {
            var n = first
            for r in 0..<cells.count where cells[r] != nil { n = r + 1 }
            return n
        }
    }

    /// 段落の最初の字が空白やかぎかっこなら、字下げはしない
    public static func startsIndented(_ text: String) -> Bool {
        guard let f = text.first else { return false }
        return f.isWhitespace || "「『（(〈《【".contains(f)
    }

    /// 段落 (0 始まり) の書き出しを何マス下げるか
    public static func indentFor(index: Int, text: String, autoFormat: Bool) -> Int {
        guard autoFormat else { return 0 }
        let count = text.count
        if count == 0 { return index == 0 ? 3 : (index == 1 ? 0 : 1) } // まだ何も書いていない列の書き始め
        if index == 0 { return count <= rows - 3 ? 3 : 0 }
        if index == 1 { return count < rows ? rows - count - 1 : 0 }
        return startsIndented(text) ? 0 : 1
    }

    /// 文章 → 列の並び
    public static func layout(_ text: String, autoFormat: Bool = true) -> [Column] {
        var columns: [Column] = []
        var offset = 0
        func newColumn(_ index: Int, _ first: Int) {
            columns.append(Column(cells: Array(repeating: nil, count: rows), offs: Array(repeating: -1, count: rows),
                                  paragraph: index, from: offset, to: offset, first: first, last: false))
        }
        for (index, para) in text.components(separatedBy: "\n").enumerated() {
            var row = indentFor(index: index, text: para, autoFormat: autoFormat)
            newColumn(index, row)
            for ch in para {
                if row >= rows {
                    newColumn(index, 0)
                    row = 0
                }
                let i = columns.count - 1
                columns[i].cells[row] = String(ch)
                columns[i].offs[row] = offset
                offset += ch.utf16.count
                columns[i].to = offset
                row += 1
            }
            columns[columns.count - 1].last = true
            offset += 1 // 改行
        }
        return columns
    }

    /// 文章の位置 → カーソルを出すマス (row = 20 は列のいちばん下の外)
    public static func caretCell(_ columns: [Column], offset: Int) -> (column: Int, row: Int) {
        for (i, c) in columns.enumerated() {
            if offset < c.from || offset > c.to { continue }
            if offset == c.to {
                // 列の最後の文字の次。段落の途中で折り返した位置は、次の列の頭に出す
                if !c.last && i + 1 < columns.count { continue }
                return (i, c.end)
            }
            // 2 つ組の文字の途中を指されたら、その文字のマス
            var found = -1
            for r in 0..<rows where c.offs[r] >= 0 && c.offs[r] <= offset { found = r }
            if found >= 0 { return (i, found) }
        }
        let lastIndex = max(0, columns.count - 1)
        return (lastIndex, columns.isEmpty ? 0 : columns[lastIndex].first)
    }

    /// マス → 文章の位置 (文字のないマスは、その列でいちばん近い位置)
    public static func offsetAt(_ columns: [Column], column: Int, row: Int) -> Int {
        guard !columns.isEmpty else { return 0 }
        let c = columns[max(0, min(column, columns.count - 1))]
        if row < c.first { return c.from }
        var r = min(row, rows - 1)
        while r >= 0 {
            if c.offs[r] >= 0 { return r == row ? c.offs[r] : c.to }
            r -= 1
        }
        return c.from
    }

    /// 用紙の枚数 (1 枚 20 列)
    public static func sheetCount(_ columns: [Column]) -> Int {
        max(1, (columns.count + columnsPerSheet - 1) / columnsPerSheet)
    }

    /// 文字数 (改行は数えない)
    public static func characterCount(_ text: String) -> Int {
        text.reduce(0) { $0 + ($1.isNewline ? 0 : 1) }
    }

    /// 半角の英数字・記号・空白を全角にする
    public static func toFullWidth(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if u.value == 0x20, let v = Unicode.Scalar(0x3000 as UInt32) {
                out.append(v)
            } else if (0x21...0x7E).contains(u.value), let v = Unicode.Scalar(u.value + 0xFEE0) {
                out.append(v)
            } else {
                out.append(u)
            }
        }
        return String(out)
    }

    // MARK: ふりがな

    /// 文章の [from, to) に付ける読み
    public struct Ruby: Equatable {
        public var from: Int
        public var to: Int
        public var reading: String
        public init(from: Int, to: Int, reading: String) {
            self.from = from
            self.to = to
            self.reading = reading
        }
    }

    /// 列の中の置き場所: row マス目から rows マスぶんの横に text を書く
    public struct RubyPlacement: Equatable {
        public var row: Int
        public var rows: Int
        public var text: String
    }

    /// ふりがなの一覧 → 列ごとの置き場所。列をまたぐ言葉は、字数に応じて読みを分ける
    public static func placeRuby(_ columns: [Column], _ ruby: [Ruby]) -> [Int: [RubyPlacement]] {
        var byColumn: [Int: [RubyPlacement]] = [:]
        guard !ruby.isEmpty else { return byColumn }
        var place: [Int: (Int, Int)] = [:]
        for (ci, col) in columns.enumerated() {
            for r in 0..<rows where col.offs[r] >= 0 { place[col.offs[r]] = (ci, r) }
        }
        for item in ruby where item.to > item.from {
            var cells: [(Int, Int)] = []
            for off in item.from..<item.to { if let w = place[off] { cells.append(w) } }
            if cells.isEmpty { continue }
            var segments: [(column: Int, row: Int, rows: Int)] = []
            for (ci, r) in cells {
                if let last = segments.last, last.column == ci {
                    segments[segments.count - 1].rows += 1
                } else {
                    segments.append((ci, r, 1))
                }
            }
            let chars = Array(item.reading)
            var used = 0
            for (i, seg) in segments.enumerated() {
                var take = i == segments.count - 1
                    ? chars.count - used
                    : Int((Double(chars.count) * Double(seg.rows) / Double(cells.count)).rounded())
                take = max(0, min(take, chars.count - used))
                let text = String(chars[used..<(used + take)])
                used += take
                if !text.isEmpty { byColumn[seg.column, default: []].append(RubyPlacement(row: seg.row, rows: seg.rows, text: text)) }
            }
        }
        return byColumn
    }
}
