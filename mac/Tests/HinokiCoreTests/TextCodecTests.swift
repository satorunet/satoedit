import XCTest
@testable import HinokiCore

final class TextCodecTests: XCTestCase {
    let sample = "日本語のテキスト。ｶﾀｶﾅも①入り\nABC\n"

    func roundTrip(_ e: TextEncoding, _ le: LineEnding, file: StaticString = #file, line: UInt = #line) throws {
        let data = try TextCodec.encode(sample, encoding: e, lineEnding: le)
        let decoded = try TextCodec.decode(data)
        XCTAssertEqual(decoded.encoding, e, file: file, line: line)
        XCTAssertEqual(decoded.lineEnding, le, file: file, line: line)
        XCTAssertEqual(decoded.text, sample, file: file, line: line)
        XCTAssertEqual(try TextCodec.encode(decoded.text, encoding: decoded.encoding, lineEnding: decoded.lineEnding), data, file: file, line: line)
    }

    func testDetectsAndRoundTrips() throws {
        try roundTrip(.utf8, .lf)
        try roundTrip(.utf8BOM, .crlf)
        try roundTrip(.shiftJIS, .crlf)
        try roundTrip(.utf16LE, .crlf)
        try roundTrip(.utf16BE, .lf)
    }

    func testEUCJP() throws {
        // ①はEUC-JPに無いので除いた文で確認
        let s = "日本語のテキスト。カタカナ\nABC"
        let data = try TextCodec.encode(s, encoding: .eucJP, lineEnding: .cr)
        let d = try TextCodec.decode(data)
        XCTAssertEqual(d.encoding, .eucJP)
        XCTAssertEqual(d.lineEnding, .cr)
        XCTAssertEqual(d.text, s)
    }

    func testJIS() throws {
        let data = try TextCodec.encode("日本語\nです", encoding: .iso2022JP, lineEnding: .lf)
        XCTAssertEqual(try TextCodec.decode(data), DecodedText(text: "日本語\nです", encoding: .iso2022JP, lineEnding: .lf))
    }

    func testShortShiftJIS() throws {
        let data = try TextCodec.encode("あ", encoding: .shiftJIS, lineEnding: .lf)
        XCTAssertEqual(TextCodec.detectEncoding(data), .shiftJIS)
    }

    func testCannotEncode() {
        XCTAssertThrowsError(try TextCodec.encode("🍣", encoding: .shiftJIS, lineEnding: .lf))
    }

    func testForcedEncoding() throws {
        let data = try TextCodec.encode("abc", encoding: .utf8, lineEnding: .lf)
        XCTAssertEqual(try TextCodec.decode(data, as: .shiftJIS).encoding, .shiftJIS)
    }

    func testLineIndex() {
        let li = LineIndex("ab\ncd\n\nef" as NSString)
        XCTAssertEqual(li.lineStarts, [0, 3, 6, 7])
        XCTAssertEqual(li.lineNumber(at: 0), 0)
        XCTAssertEqual(li.lineNumber(at: 2), 0)
        XCTAssertEqual(li.lineNumber(at: 3), 1)
        XCTAssertEqual(li.lineNumber(at: 6), 2)
        XCTAssertEqual(li.lineNumber(at: 9), 3)
        XCTAssertEqual(LineIndex("" as NSString).lineCount, 1)
    }

    func testDisplayWidth() {
        XCTAssertEqual(TextMetrics.displayWidth(of: "aあｱ"), 4)
    }
}
