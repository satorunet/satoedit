import XCTest
@testable import HinokiCore

final class FileCryptoTests: XCTestCase {
    // テストでは回数を減らして速くする
    private func key(_ pw: String) throws -> FileCrypto.Key {
        try FileCrypto.deriveKey(password: pw, iterations: 10_000)
    }

    func testRoundTrip() throws {
        let plain = Data("社外秘: 顧客リスト\nパスワード=hunter2\n".utf8)
        let k = try key("正しいパスワード")
        let file = try FileCrypto.seal(plain, with: k)
        XCTAssertTrue(FileCrypto.isEncrypted(file))
        XCTAssertNil(file.range(of: Data("顧客".utf8)), "中身がそのまま見えてはいけない")
        let opened = try FileCrypto.open(file, password: "正しいパスワード")
        XCTAssertEqual(opened.plain, plain)
        // 開いたときの鍵で保存し直しても読める
        let again = try FileCrypto.seal(plain, with: opened.key)
        XCTAssertNotEqual(again, file, "保存のたびに別の暗号文になる")
        XCTAssertEqual(try FileCrypto.open(again, password: "正しいパスワード").plain, plain)
    }

    func testWrongPassword() throws {
        let file = try FileCrypto.seal(Data("secret".utf8), with: try key("abcdefgh"))
        XCTAssertThrowsError(try FileCrypto.open(file, password: "abcdefgX"))
    }

    func testTamperDetected() throws {
        var file = try FileCrypto.seal(Data("secret".utf8), with: try key("abcdefgh"))
        file[file.count - 3] ^= 0x01
        XCTAssertThrowsError(try FileCrypto.open(file, password: "abcdefgh"))
    }

    func testHeaderTamperDetected() throws {
        var file = try FileCrypto.seal(Data("secret".utf8), with: try key("abcdefgh"))
        file[FileCrypto.magic.count + 10] ^= 0x01 // ソルトを書き換え
        XCTAssertThrowsError(try FileCrypto.open(file, password: "abcdefgh"))
    }

    func testPlainFileIsNotEncrypted() {
        XCTAssertFalse(FileCrypto.isEncrypted(Data("hello".utf8)))
    }

    func testPasscodeKind() throws {
        let k = try FileCrypto.deriveKey(password: "123456", iterations: 10_000, kind: .passcode)
        let file = try FileCrypto.seal(Data("pin".utf8), with: k)
        XCTAssertEqual(try FileCrypto.header(of: file).kind, .passcode)
        XCTAssertEqual(try FileCrypto.open(file, password: "123456").plain, Data("pin".utf8))
        XCTAssertThrowsError(try FileCrypto.open(file, password: "123457"))
    }

    func testDeviceKind() throws {
        let (key, raw) = FileCrypto.newDeviceKey()
        let file = try FileCrypto.seal(Data("mac only".utf8), with: key)
        let h = try FileCrypto.header(of: file)
        XCTAssertEqual(h.kind, .device)
        XCTAssertNil(file.range(of: raw), "鍵そのものはファイルに入らない")
        XCTAssertEqual(try FileCrypto.open(file, with: FileCrypto.deviceKey(raw: raw, id: h.salt)), Data("mac only".utf8))
        XCTAssertThrowsError(try FileCrypto.open(file, password: "anything"))
        XCTAssertThrowsError(try FileCrypto.open(file, with: FileCrypto.newDeviceKey().key))
    }

    func testVersion1StillReadable() throws {
        let k = try key("old-password")
        let v1 = try FileCrypto.seal(Data("old".utf8), with: k, version: 1)
        XCTAssertEqual(try FileCrypto.header(of: v1).version, 1)
        let opened = try FileCrypto.open(v1, password: "old-password")
        XCTAssertEqual(opened.plain, Data("old".utf8))
        // 開いた鍵で保存し直すと版 2 になり、また開ける
        let v2 = try FileCrypto.seal(opened.plain, with: opened.key)
        XCTAssertEqual(try FileCrypto.header(of: v2).version, 2)
        XCTAssertEqual(try FileCrypto.open(v2, password: "old-password").plain, Data("old".utf8))
    }

    // MARK: 鍵ファイル

    func testKeyFileRoundTrip() throws {
        let contents = FileCrypto.newKeyFileContents()
        let secret = try XCTUnwrap(FileCrypto.keyFileSecret(contents))
        XCTAssertEqual(secret.count, 32)
        let plain = Data("社外秘\n".utf8)
        let key = FileCrypto.keyFileKey(secret: secret)
        let file = try FileCrypto.seal(plain, with: key)
        XCTAssertEqual(try FileCrypto.header(of: file).kind, .keyfile)
        // 鍵ファイルを読み直しても開ける
        let again = try XCTUnwrap(FileCrypto.keyFileSecret(contents))
        let opened = try FileCrypto.open(file, keyFileSecret: again)
        XCTAssertEqual(opened.plain, plain)
        // 開いたときの鍵で保存し直しても、同じ鍵ファイルで読める
        let resaved = try FileCrypto.seal(Data("追記".utf8), with: opened.key)
        XCTAssertEqual(try FileCrypto.open(resaved, keyFileSecret: secret).plain, Data("追記".utf8))
    }

    func testKeyFileGivesDifferentKeyPerDocument() throws {
        let secret = try XCTUnwrap(FileCrypto.keyFileSecret(FileCrypto.newKeyFileContents()))
        let a = FileCrypto.keyFileKey(secret: secret), b = FileCrypto.keyFileKey(secret: secret)
        XCTAssertNotEqual(a.salt, b.salt)
        let fa = try FileCrypto.seal(Data("a".utf8), with: a)
        XCTAssertThrowsError(try FileCrypto.open(fa, with: b), "別の文書の鍵では開けない")
    }

    func testWrongKeyFile() throws {
        let s1 = try XCTUnwrap(FileCrypto.keyFileSecret(FileCrypto.newKeyFileContents()))
        let s2 = try XCTUnwrap(FileCrypto.keyFileSecret(FileCrypto.newKeyFileContents()))
        let file = try FileCrypto.seal(Data("secret".utf8), with: FileCrypto.keyFileKey(secret: s1))
        XCTAssertThrowsError(try FileCrypto.open(file, keyFileSecret: s2)) { e in
            guard case FileCrypto.CryptoError.wrongKeyFile = e else { return XCTFail("wrongKeyFile のはず: \(e)") }
        }
        XCTAssertThrowsError(try FileCrypto.open(file, password: "password"))
    }

    func testKeyFileParsing() {
        XCTAssertNil(FileCrypto.keyFileSecret(Data("ただのテキスト\n".utf8)))
        XCTAssertNil(FileCrypto.keyFileSecret(Data("SATORU-KEYFILE-1\nAAAA\n".utf8)), "長さが足りない")
        let b64 = Data(repeating: 7, count: 32).base64EncodedString()
        XCTAssertEqual(FileCrypto.keyFileSecret(Data("SATORU-KEYFILE-1\r\n# メモ\r\n\(b64)\r\n".utf8)), Data(repeating: 7, count: 32),
                       "改行コードが変わっても読める")
    }

    // MARK: 二段階

    func testTwoStepNeedsBothPasswordAndSecret() throws {
        let secret = TOTP.newSecret()
        let key = try FileCrypto.twoStepKey(password: "正しいパスワード", totpSecret: secret, iterations: 10_000)
        let file = try FileCrypto.seal(Data("secret".utf8), with: key)
        XCTAssertEqual(try FileCrypto.header(of: file).kind, .twoStep)
        XCTAssertEqual(try FileCrypto.open(file, password: "正しいパスワード", totpSecret: secret).plain, Data("secret".utf8))
        XCTAssertThrowsError(try FileCrypto.open(file, password: "違うパスワード", totpSecret: secret))
        XCTAssertThrowsError(try FileCrypto.open(file, password: "正しいパスワード", totpSecret: TOTP.newSecret()), "秘密が違えば開けない")
        XCTAssertThrowsError(try FileCrypto.open(file, password: "正しいパスワード"), "パスワードだけでは開けない")
    }
}
