import XCTest
@testable import HinokiCore

final class TOTPTests: XCTestCase {
    private let secret = Data("12345678901234567890".utf8)

    /// RFC 6238 付録 B の値 (SHA1、8 桁) と、その下 6 桁
    func testRFC6238Vectors() {
        let cases: [(TimeInterval, String)] = [
            (59, "94287082"), (1111111109, "07081804"), (1111111111, "14050471"),
            (1234567890, "89005924"), (2000000000, "69279037"), (20000000000, "65353130"),
        ]
        for (t, expected) in cases {
            let date = Date(timeIntervalSince1970: t)
            XCTAssertEqual(TOTP.code(secret: secret, at: date, digits: 8), expected)
            XCTAssertEqual(TOTP.code(secret: secret, at: date), String(expected.suffix(6)))
        }
    }

    func testVerifyWindow() {
        let now = Date(timeIntervalSince1970: 1234567890)
        let code = TOTP.code(secret: secret, at: now)
        XCTAssertTrue(TOTP.verify(code, secret: secret, at: now))
        XCTAssertTrue(TOTP.verify(" \(code.prefix(3)) \(code.suffix(3)) ", secret: secret, at: now), "空白は無視")
        XCTAssertTrue(TOTP.verify(code, secret: secret, at: now.addingTimeInterval(30)), "1 つ前のコードは認める")
        XCTAssertFalse(TOTP.verify(code, secret: secret, at: now.addingTimeInterval(90)), "古いコードは認めない")
        XCTAssertFalse(TOTP.verify("12345", secret: secret, at: now))
        XCTAssertFalse(TOTP.verify("abcdef", secret: secret, at: now))
        XCTAssertFalse(TOTP.verify(code, secret: Data("another-secret-000000".utf8), at: now))
    }

    func testBase32() {
        XCTAssertEqual(TOTP.base32(Data("foobar".utf8)), "MZXW6YTBOI")
        XCTAssertEqual(TOTP.base32(Data("fo".utf8)), "MZXQ")
        XCTAssertEqual(TOTP.base32(secret), "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
    }

    func testURI() {
        let uri = TOTP.uri(secret: secret, account: "taro", issuer: "さとるエディタ")
        XCTAssertTrue(uri.hasPrefix("otpauth://totp/"))
        XCTAssertTrue(uri.contains("secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"))
        XCTAssertNotNil(URL(string: uri), "URL として正しい")
    }

    /// 認証アプリ方式の鍵でも暗号化して読める (パスワードでは開けない)
    func testTOTPKindRoundTrip() throws {
        let (key, raw) = FileCrypto.newDeviceKey(kind: .totp)
        let file = try FileCrypto.seal(Data("secret".utf8), with: key)
        let h = try FileCrypto.header(of: file)
        XCTAssertEqual(h.kind, .totp)
        XCTAssertEqual(try FileCrypto.open(file, with: FileCrypto.deviceKey(raw: raw, id: h.salt, kind: .totp)), Data("secret".utf8))
        XCTAssertThrowsError(try FileCrypto.open(file, with: FileCrypto.deviceKey(raw: raw, id: h.salt)), "種類が違う鍵では開けない")
        XCTAssertThrowsError(try FileCrypto.open(file, password: "password"))
    }
}
