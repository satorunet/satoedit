import Foundation

/// 巨大なファイルの「一部分だけ」を読み書きする。
/// 読むときは行の切れ目に合わせ、保存するときは「前の部分 + 書き換えた部分 + 後ろの部分」をつないで書き出す。
public enum PartialFile {
    public struct Part: Equatable {
        /// ファイルの先頭からのバイト位置
        public var offset: UInt64
        /// 読み込んだバイト数
        public var length: UInt64
        /// 読んだときのファイル全体の大きさ
        public var fileSize: UInt64

        public init(offset: UInt64, length: UInt64, fileSize: UInt64) {
            self.offset = offset
            self.length = length
            self.fileSize = fileSize
        }

        public var end: UInt64 { offset + length }
        public var isWholeFile: Bool { offset == 0 && length >= fileSize }
    }

    private static let window = 1 << 20
    /// 行の切れ目を探すのをあきらめる長さ (これより長い 1 行は途中で切る)
    private static let maxSeek: UInt64 = 16 << 20

    public static func fileSize(of url: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// from から先で最初の改行 (LF) の次の位置。見つからなければ nil
    private static func afterNewline(_ h: FileHandle, from: UInt64, size: UInt64) -> UInt64? {
        var pos = from
        while pos < size, pos - from < maxSeek {
            h.seek(toFileOffset: pos)
            let chunk = h.readData(ofLength: window)
            if chunk.isEmpty { break }
            if let i = chunk.firstIndex(of: 0x0A) { return pos + UInt64(i - chunk.startIndex) + 1 }
            pos += UInt64(chunk.count)
        }
        return nil
    }

    /// 希望の範囲を、行の切れ目に合わせる (先頭は次の行頭へ、末尾はその行の終わりまで)
    public static func align(_ url: URL, offset: UInt64, length: UInt64) throws -> Part {
        let size = try fileSize(of: url)
        let h = try FileHandle(forReadingFrom: url)
        defer { h.closeFile() }
        var start = min(offset, size)
        if start > 0 {
            // ちょうど行頭ならそのまま (1 つ前が改行)
            h.seek(toFileOffset: start - 1)
            if h.readData(ofLength: 1).first != 0x0A {
                start = afterNewline(h, from: start, size: size) ?? start
            }
        }
        var end = min(size, max(start, offset) + max(length, 1))
        if end < size {
            h.seek(toFileOffset: end - 1)
            if h.readData(ofLength: 1).first != 0x0A {
                end = afterNewline(h, from: end, size: size) ?? (end + maxSeek >= size ? size : end)
            }
        }
        return Part(offset: start, length: end - start, fileSize: size)
    }

    public static func read(_ url: URL, _ part: Part) throws -> Data {
        let h = try FileHandle(forReadingFrom: url)
        defer { h.closeFile() }
        h.seek(toFileOffset: part.offset)
        return h.readData(ofLength: Int(part.length))
    }

    /// original の part の所を replacement に差し替えたものを dest に書く (original は変えない)
    public static func write(original: URL, part: Part, replacement: Data, to dest: URL) throws {
        let src = try FileHandle(forReadingFrom: original)
        defer { src.closeFile() }
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let out = try FileHandle(forWritingTo: dest)
        defer { out.closeFile() }
        func copy(from: UInt64, to: UInt64) {
            var pos = from
            src.seek(toFileOffset: pos)
            while pos < to {
                let chunk = autoreleasepool { src.readData(ofLength: Int(min(UInt64(4 << 20), to - pos))) }
                if chunk.isEmpty { break }
                out.write(chunk)
                pos += UInt64(chunk.count)
            }
        }
        let size = try fileSize(of: original)
        copy(from: 0, to: min(part.offset, size))
        out.write(replacement)
        copy(from: min(part.end, size), to: size)
    }
}
