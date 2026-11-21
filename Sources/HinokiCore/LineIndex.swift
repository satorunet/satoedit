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
