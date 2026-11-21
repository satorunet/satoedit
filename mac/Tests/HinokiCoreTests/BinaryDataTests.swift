import XCTest
@testable import HinokiCore

final class BinaryDataTests: XCTestCase {
    func testTextIsNotBinary() {
        XCTAssertFalse(BinaryData.looksBinary(Data("こんにちは\nhello\tworld\r\n".utf8)))
        XCTAssertFalse(BinaryData.looksBinary(Data()))
        // ESC を含むログ (色付き) もテキスト
        XCTAssertFalse(BinaryData.looksBinary(Data("\u{1B}[31mred\u{1B}[0m\n".utf8)))
    }

    func testUTF16IsNotBinary() {
        let s = "Hello, world. テキスト\n"
        XCTAssertFalse(BinaryData.looksBinary(s.data(using: .utf16LittleEndian)!))
        XCTAssertFalse(BinaryData.looksBinary(s.data(using: .utf16BigEndian)!))
        XCTAssertFalse(BinaryData.looksBinary(s.data(using: .utf16)!)) // BOM 付き
        // 英字だけの BOM なし UTF-16 (1 バイトおきに 0)
        XCTAssertFalse(BinaryData.looksBinary("plain ascii text in utf16".data(using: .utf16LittleEndian)!))
    }

    func testBinary() {
        // PNG の先頭
        XCTAssertTrue(BinaryData.looksBinary(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52])))
        // NUL はないが制御文字だらけ
        XCTAssertTrue(BinaryData.looksBinary(Data((0..<200).map { UInt8(1 + $0 % 8) })))
        // ランダムなバイト
        var g = SystemRandomNumberGenerator()
        XCTAssertTrue(BinaryData.looksBinary(Data((0..<4096).map { _ in UInt8.random(in: 0...255, using: &g) })))
    }

    func testHexLine() {
        let d = Data("Hello, world!\n\u{0}\u{1}ABC".utf8)
        let l0 = BinaryData.line(d, at: 0)
        XCTAssertEqual(l0.offset, "00000000")
        XCTAssertEqual(l0.hex, "48 65 6C 6C 6F 2C 20 77  6F 72 6C 64 21 0A 00 01")
        XCTAssertEqual(l0.ascii, "Hello, world!...")
        let l1 = BinaryData.line(d, at: 16)
        XCTAssertEqual(l1.offset, "00000010")
        XCTAssertTrue(l1.hex.hasPrefix("41 42 43 "))
        XCTAssertEqual(l1.ascii, "ABC")
        XCTAssertEqual(l0.hex.count, l1.hex.count)
        XCTAssertEqual(BinaryData.lineCount(d.count), 2)
        XCTAssertEqual(BinaryData.lineCount(0), 0)
        XCTAssertEqual(BinaryData.lineCount(16), 1)
    }

    func testSliceIndices() {
        // Data のスライス (startIndex が 0 でない) でも正しく読む
        let base = Data((0..<64).map { UInt8($0) })
        let slice = base[10..<40]
        XCTAssertTrue(BinaryData.line(slice, at: 0).hex.hasPrefix("0A 0B"))
    }
}
