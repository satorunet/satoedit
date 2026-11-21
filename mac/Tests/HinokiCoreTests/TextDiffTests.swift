import XCTest
@testable import HinokiCore

final class TextDiffTests: XCTestCase {
    func testSame() {
        let r = TextDiff.compare(old: "a\nb\n", new: "a\nb\n")
        XCTAssertFalse(r.hasChanges)
        XCTAssertTrue(r.rows.isEmpty)
    }

    func testChangeLine() {
        let r = TextDiff.compare(old: "a\nb\nc", new: "a\nB\nc")
        XCTAssertEqual(r.added, 1)
        XCTAssertEqual(r.removed, 1)
        XCTAssertEqual(r.rows.map { $0.kind }, [.same, .removed, .added, .same])
        XCTAssertEqual(r.rows[1].oldLine, 2)
        XCTAssertEqual(r.rows[2].newLine, 2)
        XCTAssertEqual(r.rows[2].text, "B")
    }

    func testInsertAndGap() {
        let old = (1...20).map { "l\($0)" }.joined(separator: "\n")
        var lines = (1...20).map { "l\($0)" }
        lines.insert("NEW", at: 10)
        let r = TextDiff.compare(old: old, new: lines.joined(separator: "\n"), context: 2)
        XCTAssertEqual(r.added, 1)
        XCTAssertEqual(r.removed, 0)
        XCTAssertEqual(r.rows.first?.kind, .gap)
        XCTAssertEqual(r.rows.first?.skipped, 8)
        let added = r.rows.first { $0.kind == .added }
        XCTAssertEqual(added?.newLine, 11)
        XCTAssertEqual(r.rows.last?.kind, .gap)
        XCTAssertEqual(r.rows.filter { $0.kind == .same }.count, 4)
    }

    func testCRLF() {
        let r = TextDiff.compare(old: "a\r\nb", new: "a\r\nc")
        XCTAssertEqual(r.rows.first { $0.kind == .removed }?.text, "b")
    }

    func testTooLarge() {
        let big = String(repeating: "x\n", count: 100)
        XCTAssertTrue(TextDiff.compare(old: big, new: big + "y", maxLines: 50).tooLarge)
    }
}

final class TextDiffInlineTests: XCTestCase {
    func testInlineWordLike() {
        let r = TextDiff.inline(old: "今日は晴れです。\n明日も", new: "今日は雨です。\n明日も")
        XCTAssertEqual(r.added, 1)
        XCTAssertEqual(r.removed, 1)
        let kinds = r.segments.map { $0.kind }
        XCTAssertTrue(kinds.contains(.removed) && kinds.contains(.added))
        XCTAssertEqual(r.segments.first { $0.kind == .removed }?.text, "晴れ")
        XCTAssertEqual(r.segments.first { $0.kind == .added }?.text, "雨")
        // つなげると、消した字を除けばいまの文書になる
        let now = r.segments.filter { $0.kind != .removed && $0.kind != .gap }.map { $0.text }.joined()
        XCTAssertEqual(now, "今日は雨です。\n明日も")
    }

    func testInlineAddedLine() {
        let r = TextDiff.inline(old: "a\nb", new: "a\nNEW\nb")
        XCTAssertEqual(r.segments.first { $0.kind == .added }?.text, "NEW\n")
        XCTAssertEqual(r.segments.first { $0.kind == .added }?.newLine, 2)
    }

    func testInlineDissimilarReplacesWhole() {
        let r = TextDiff.inline(old: "abcdef", new: "xyz")
        XCTAssertEqual(r.segments.map { $0.kind }, [.removed, .added])
    }

    func testInlineGap() {
        let old = (1...30).map { "l\($0)" }.joined(separator: "\n")
        var l = (1...30).map { "l\($0)" }
        l[15] = "CHANGED"
        let r = TextDiff.inline(old: old, new: l.joined(separator: "\n"), context: 2)
        XCTAssertEqual(r.segments.first?.kind, .gap)
        XCTAssertEqual(r.segments.last?.kind, .gap)
    }
}
