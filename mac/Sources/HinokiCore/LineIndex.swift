import Foundation

/// 各行の先頭位置 (UTF-16 オフセット) の表。行番号の計算を二分探索で行う。
public struct LineIndex {
    public private(set) var lineStarts: [Int]

    public init(_ string: NSString) {
        var starts = [0]
        let length = string.length
        let chunk = 65536
        var buffer = [unichar](repeating: 0, count: chunk)
        var pos = 0
        while pos < length {
            let n = min(chunk, length - pos)
            string.getCharacters(&buffer, range: NSRange(location: pos, length: n))
            for i in 0..<n where buffer[i] == 0x0A {
                starts.append(pos + i + 1)
            }
            pos += n
        }
        lineStarts = starts
    }

    /// 文字が書き換わったあと、全体を数え直さずに直す。
    /// editedRange: 書き換わったあとの範囲、delta: 増えた文字数 (減ったら負)。string は書き換わったあとの文字列
    public mutating func edit(_ string: NSString, editedRange: NSRange, delta: Int) {
        let oldEnd = editedRange.location + editedRange.length - delta
        // 行頭は「改行の次の位置」。消えた範囲の改行が作っていた行頭は (location, oldEnd] にある
        var lo = 0, hi = lineStarts.count
        while lo < hi { let m = (lo + hi) / 2; if lineStarts[m] <= editedRange.location { lo = m + 1 } else { hi = m } }
        let first = lo
        hi = lineStarts.count
        while lo < hi { let m = (lo + hi) / 2; if lineStarts[m] <= oldEnd { lo = m + 1 } else { hi = m } }
        let last = lo
        var added: [Int] = []
        let chunk = 65536
        var buffer = [unichar](repeating: 0, count: min(chunk, max(1, editedRange.length)))
        var pos = editedRange.location
        let end = min(NSMaxRange(editedRange), string.length)
        while pos < end {
            let n = min(buffer.count, end - pos)
            string.getCharacters(&buffer, range: NSRange(location: pos, length: n))
            for i in 0..<n where buffer[i] == 0x0A { added.append(pos + i + 1) }
            pos += n
        }
        if delta != 0 { for i in last..<lineStarts.count { lineStarts[i] += delta } }
        lineStarts.replaceSubrange(first..<last, with: added)
    }

    public var lineCount: Int { lineStarts.count }

    /// 0 始まりの行番号
    public func lineNumber(at index: Int) -> Int {
        var lo = 0
        var hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= index { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    public func startOfLine(_ line: Int) -> Int {
        lineStarts[max(0, min(line, lineStarts.count - 1))]
    }
}

public enum TextMetrics {
    /// 半角を 1、全角を 2 として数えた表示幅。
    public static func displayWidth(of s: String) -> Int {
        var w = 0
        for u in s.unicodeScalars {
            let v = u.value
            if v < 0x1100 || (0xFF61...0xFF9F).contains(v) {
                w += 1
            } else {
                w += 2
            }
        }
        return w
    }
}
