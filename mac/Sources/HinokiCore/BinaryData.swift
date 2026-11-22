import Foundation

/// テキストではないデータ (バイナリ) の見分けと、16 進数での表示
public enum BinaryData {
    /// 先頭の一部を見て、バイナリらしいか。
    /// NUL (0x00) が入っていればバイナリ。ただし UTF-16 / UTF-32 のテキスト (BOM あり、または 1 バイトおきに 0) は除く。
    /// NUL がなくても、改行・タブなど以外の制御文字が多ければバイナリ
    public static func looksBinary(_ sample: Data) -> Bool {
        if sample.isEmpty { return false }
        // 1 バイトずつ見るので、配列を作らず生のバイトをそのまま数える (たくさんのファイルを続けて見ても速いように)
        return sample.prefix(8192).withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            let n = raw.count
            guard n > 0, let p = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            // BOM 付きの UTF-16 / UTF-32 / UTF-8 はテキスト
            if n >= 2 && ((p[0] == 0xFF && p[1] == 0xFE) || (p[0] == 0xFE && p[1] == 0xFF)) { return false }
            if n >= 3 && p[0] == 0xEF && p[1] == 0xBB && p[2] == 0xBF { return false }
            var even = 0, odd = 0, controls = 0
            var i = 0
            while i < n {
                let v = p[i]
                if v == 0 {
                    if i & 1 == 0 { even += 1 } else { odd += 1 }
                } else if v < 0x20 {
                    // 改行・タブ・改ページ・ESC・BS 以外の制御文字
                    if v != 0x09 && v != 0x0A && v != 0x0D && v != 0x0C && v != 0x1B && v != 0x08 { controls += 1 }
                } else if v == 0x7F {
                    controls += 1
                }
                i += 1
            }
            if even + odd > 0 {
                // BOM なしの UTF-16: 偶数か奇数の片方の位置にだけ 0 が並ぶ
                let half = n / 2
                if half > 0, (Double(even) > Double(half) * 0.4 && odd == 0) || (Double(odd) > Double(half) * 0.4 && even == 0) {
                    return false
                }
                return true
            }
            return Double(controls) / Double(n) > 0.1
        }
    }

    /// 16 バイト 1 行の表示: 「00000010  48 65 6C 6C 6F 0A 00 …  |Hello..|」の 3 つの部分
    public struct Line: Equatable {
        public let offset: String
        public let hex: String
        public let ascii: String
    }

    public static let bytesPerLine = 16

    /// offset から 1 行分
    public static func line(_ data: Data, at offset: Int, offsetDigits: Int = 8) -> Line {
        let start = data.startIndex + offset
        let end = min(start + bytesPerLine, data.endIndex)
        let bytes = start < end ? [UInt8](data[start..<end]) : []
        var hex = ""
        for i in 0..<bytesPerLine {
            if i == 8 { hex += " " }
            hex += i < bytes.count ? String(format: "%02X", bytes[i]) : "  "
            if i < bytesPerLine - 1 { hex += " " }
        }
        let ascii = String(bytes.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
        return Line(offset: String(format: "%0\(offsetDigits)X", offset), hex: hex, ascii: ascii)
    }

    /// 行の数
    public static func lineCount(_ size: Int) -> Int { (size + bytesPerLine - 1) / bytesPerLine }
}
