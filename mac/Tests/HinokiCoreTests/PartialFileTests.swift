import XCTest
@testable import HinokiCore

final class PartialFileTests: XCTestCase {
    private func temp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("partial-\(UUID().uuidString)-\(name)")
    }

    func testAlignReadAndWriteBack() throws {
        // 1 行 10 バイト (9 文字 + LF) を 1000 行
        var text = ""
        for i in 0..<1000 { text += String(format: "line%05d\n", i) }
        let url = temp("a.txt")
        try Data(text.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // 行の途中から、行の途中まで → 行の切れ目に合う
        let part = try PartialFile.align(url, offset: 1003, length: 2000)
        XCTAssertEqual(part.offset, 1010)
        XCTAssertEqual(part.end, 3010)
        XCTAssertEqual(part.fileSize, 10000)
        let chunk = String(decoding: try PartialFile.read(url, part), as: UTF8.self)
        XCTAssertTrue(chunk.hasPrefix("line00101\n"))
        XCTAssertTrue(chunk.hasSuffix("line00300\n"))

        // ちょうど行頭・行末ならそのまま
        XCTAssertEqual(try PartialFile.align(url, offset: 1000, length: 1000), .init(offset: 1000, length: 1000, fileSize: 10000))
        // 末尾をこえる指定は、ファイルの終わりまで
        XCTAssertEqual(try PartialFile.align(url, offset: 9995, length: 99999).end, 10000)

        // 一部分を書き換えて保存 → 前後はそのまま
        let dest = temp("b.txt")
        defer { try? FileManager.default.removeItem(at: dest) }
        try PartialFile.write(original: url, part: part, replacement: Data("CHANGED\n".utf8), to: dest)
        let result = String(decoding: try Data(contentsOf: dest), as: UTF8.self)
        let lines = text.components(separatedBy: "\n")
        let expected = lines[0...100].joined(separator: "\n") + "\nCHANGED\n" + lines[301...].joined(separator: "\n")
        XCTAssertEqual(result, expected)
    }

    func testLineIndexIncrementalEdit() {
        var rng = SystemRandomNumberGenerator()
        let s = NSMutableString(string: "ab\ncd\n\nef")
        var index = LineIndex(s)
        let pieces = ["", "x", "\n", "xy\nz", "\n\n", "long text without newline", "a\nb\nc\n"]
        for _ in 0..<500 {
            let loc = Int.random(in: 0...s.length, using: &rng)
            let len = Int.random(in: 0...min(6, s.length - loc), using: &rng)
            let ins = pieces.randomElement(using: &rng)!
            s.replaceCharacters(in: NSRange(location: loc, length: len), with: ins)
            let n = (ins as NSString).length
            index.edit(s, editedRange: NSRange(location: loc, length: n), delta: n - len)
            XCTAssertEqual(index.lineStarts, LineIndex(s).lineStarts)
        }
    }
}
