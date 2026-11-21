import XCTest
@testable import HinokiCore

final class CollabCipherTests: XCTestCase {
    func testRoundTripBothDirections() throws {
        let code = CollabCipher.newCode()
        let host = CollabCipher(code: code, isHost: true)
        let guest = CollabCipher(code: code.lowercased().replacingOccurrences(of: "-", with: " "), isHost: false)
        for i in 0..<5 {
            let m = Data("ゲストから \(i)".utf8)
            XCTAssertEqual(host.open(try guest.seal(m)), m)
            let r = Data("ホストから \(i)".utf8)
            XCTAssertEqual(guest.open(try host.seal(r)), r)
        }
    }

    func testWrongCodeCannotRead() throws {
        let host = CollabCipher(code: CollabCipher.newCode(), isHost: true)
        let intruder = CollabCipher(code: CollabCipher.newCode(), isHost: false)
        XCTAssertNil(host.open(try intruder.seal(Data("hello".utf8))))
    }

    func testReplayAndReflectionRejected() throws {
        let code = CollabCipher.newCode()
        let host = CollabCipher(code: code, isHost: true)
        let guest = CollabCipher(code: code, isHost: false)
        let line = try guest.seal(Data("op".utf8))
        XCTAssertNotNil(host.open(line))
        XCTAssertNil(host.open(line), "同じものをもう一度送られても受け付けない")
        // ホストが送ったものをホストに送り返しても読めない
        let own = try host.seal(Data("x".utf8))
        XCTAssertNil(CollabCipher(code: code, isHost: true).open(own))
    }

    func testTamperedRejected() throws {
        let code = CollabCipher.newCode()
        var line = try CollabCipher(code: code, isHost: false).seal(Data("secret text".utf8))
        line[line.count / 2] = line[line.count / 2] == UInt8(ascii: "A") ? UInt8(ascii: "B") : UInt8(ascii: "A")
        XCTAssertNil(CollabCipher(code: code, isHost: true).open(line))
    }

    func testCodeFormat() {
        let c = CollabCipher.newCode()
        XCTAssertEqual(c.count, 19)
        XCTAssertEqual(CollabCipher.normalize(c).count, 16)
    }
}
