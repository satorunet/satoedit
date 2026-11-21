import XCTest
@testable import HinokiCore

final class GrepTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try "foo\nbar Hello\nbaz".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try TextCodec.encode("日本語\nこんにちは hello", encoding: .shiftJIS, lineEnding: .crlf)
            .write(to: dir.appendingPathComponent("sub/b.txt"))
        try "hello".write(to: dir.appendingPathComponent("sub/c.swift"), atomically: true, encoding: .utf8)
        try "hello".write(to: dir.appendingPathComponent("node_modules/x.txt"), atomically: true, encoding: .utf8)
        try Data([0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x00]).write(to: dir.appendingPathComponent("bin.dat"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func run(_ o: GrepOptions) throws -> [String] {
        var out: [String] = []
        try Grep.search(root: dir, options: o) { m in
            let rel = String(m.url.standardizedFileURL.path.dropFirst(self.dir.standardizedFileURL.path.count + 1))
            out.append("\(rel):\(m.line):\(m.text)")
        }
        return out
    }

    func testPlainCaseInsensitive() throws {
        XCTAssertEqual(try run(GrepOptions(pattern: "hello")), [
            "a.txt:2:bar Hello", "sub/b.txt:2:こんにちは hello", "sub/c.swift:1:hello",
        ])
    }

    func testMaskAndCase() throws {
        XCTAssertEqual(try run(GrepOptions(pattern: "hello", caseSensitive: true, fileMask: "*.txt")),
                       ["sub/b.txt:2:こんにちは hello"])
    }

    func testRegexNonRecursive() throws {
        XCTAssertEqual(try run(GrepOptions(pattern: "^ba[rz]", useRegex: true, recursive: false)),
                       ["a.txt:2:bar Hello", "a.txt:3:baz"])
    }

    func testBadRegexThrows() {
        XCTAssertThrowsError(try run(GrepOptions(pattern: "(", useRegex: true)))
    }
}
