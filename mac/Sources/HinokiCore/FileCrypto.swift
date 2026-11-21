import Foundation
import CryptoKit
import CommonCrypto

/// 流出防止のためのファイル暗号化 (AES-256-GCM)。鍵の作り方は 6 通りから選べる:
/// - password: パスワード → PBKDF2-HMAC-SHA256 (60 万回)
/// - passcode: 数字のパスコード → PBKDF2 (200 万回。短いぶん遅くして総当たりに備える)
/// - device:   この Mac のキーチェーンに置いた乱数の鍵 (ファイルには鍵の番号だけ)
/// - totp:     device と同じ置き方の鍵。開くときにスマホの認証アプリの 6 桁コードで本人確認する
/// - twoStep:  パスワード (PBKDF2) に、スマホの認証アプリと共有している秘密 (この Mac のキーチェーン) を混ぜた鍵。
///             パスワードとこの Mac の両方が要り、開くときは 6 桁コードでも本人確認する
/// - keyfile:  鍵ファイル (USB メモリなどに置く乱数) から文書ごとの鍵を作る。回数の欄には鍵ファイルの指紋を入れる
///
/// ファイルの形 (版 2):
///   "SATORU-ENC\\n" | 版=2 | 種類 (1) | 繰り返し回数 (4) | ソルト または 鍵の番号 (16) | AES-GCM (nonce + 暗号文 + タグ)
/// 版 1 (種類なし = パスワード) のファイルも読める。先頭部分も改ざん検出の対象。
public enum FileCrypto {
    public static let magic = Data("SATORU-ENC\n".utf8)
    public static let version: UInt8 = 2
    public static let defaultIterations: UInt32 = 600_000
    public static let passcodeIterations: UInt32 = 2_000_000

    public enum Kind: UInt8 {
        case password = 0, passcode = 1, device = 2, totp = 3, keyfile = 4, twoStep = 5
    }

    public struct Key {
        public let key: SymmetricKey
        /// パスワード系ではソルト、device では鍵の番号
        public let salt: Data
        public let iterations: UInt32
        public let kind: Kind

        public init(key: SymmetricKey, salt: Data, iterations: UInt32, kind: Kind) {
            self.key = key
            self.salt = salt
            self.iterations = iterations
            self.kind = kind
        }
    }

    public struct Header {
        public let version: UInt8
        public let kind: Kind
        public let iterations: UInt32
        public let salt: Data
        public let length: Int
    }

    public enum CryptoError: LocalizedError {
        case notEncrypted, unsupportedVersion, wrongPasswordOrDamaged, keyDerivationFailed, keyNotOnThisMac, wrongKeyFile

        public var errorDescription: String? {
            switch self {
            case .notEncrypted: return L("暗号化されたファイルではありません")
            case .unsupportedVersion: return L("このアプリでは読めない新しい形式の暗号化ファイルです")
            case .wrongPasswordOrDamaged: return L("パスワード (パスコード) が違うか、ファイルが壊れています")
            case .keyDerivationFailed: return L("鍵を作れませんでした")
            case .wrongKeyFile: return L("この文書を暗号化したときの鍵ファイルではありません")
            case .keyNotOnThisMac: return L("このファイルの鍵はこの Mac にありません。暗号化した Mac でしか開けません。")
            }
        }
    }

    public static func isEncrypted(_ data: Data) -> Bool {
        data.count > magic.count && data.prefix(magic.count) == magic
    }

    static func randomBytes(_ n: Int) -> Data {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return Data(b)
    }

    /// パスワード (またはパスコード) から鍵を作る (少し時間がかかる)。salt が nil なら新しく作る
    public static func deriveKey(password: String, salt: Data? = nil, iterations: UInt32 = defaultIterations,
                                 kind: Kind = .password) throws -> Key {
        let salt = salt ?? randomBytes(16)
        let pw = Array(password.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { s in
            pw.withUnsafeBufferPointer { p -> Int32 in
                let base = p.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self) }
                return CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), base, pw.count,
                                            s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                            &out, out.count)
            }
        }
        guard status == kCCSuccess else { throw CryptoError.keyDerivationFailed }
        return Key(key: SymmetricKey(data: out), salt: salt, iterations: iterations, kind: kind)
    }

    /// この Mac 用の乱数の鍵を作る (保存はアプリ側でキーチェーンへ)
    public static func newDeviceKey(kind: Kind = .device) -> (key: Key, raw: Data) {
        let raw = randomBytes(32)
        return (Key(key: SymmetricKey(data: raw), salt: randomBytes(16), iterations: 0, kind: kind), raw)
    }

    public static func deviceKey(raw: Data, id: Data, kind: Kind = .device) -> Key {
        Key(key: SymmetricKey(data: raw), salt: id, iterations: 0, kind: kind)
    }

    // MARK: 二段階 (パスワード + ワンタイム認証)

    /// パスワードから作った鍵に、認証アプリと共有している秘密を混ぜる。salt が nil なら新しく作る
    public static func twoStepKey(password: String, totpSecret: Data, salt: Data? = nil,
                                  iterations: UInt32 = defaultIterations) throws -> Key {
        let base = try deriveKey(password: password, salt: salt, iterations: iterations)
        let mixed = HKDF<SHA256>.deriveKey(inputKeyMaterial: base.key, salt: totpSecret,
                                           info: Data("satoru-two-step".utf8), outputByteCount: 32)
        return Key(key: mixed, salt: base.salt, iterations: iterations, kind: .twoStep)
    }

    public static func open(_ data: Data, password: String, totpSecret: Data) throws -> (plain: Data, key: Key) {
        let h = try header(of: data)
        guard h.kind == .twoStep, h.iterations >= 10_000, h.iterations <= 50_000_000 else { throw CryptoError.wrongPasswordOrDamaged }
        let key = try twoStepKey(password: password, totpSecret: totpSecret, salt: h.salt, iterations: h.iterations)
        return (try open(data, with: key), key)
    }

    // MARK: 鍵ファイル

    public static let keyFileHeader = "SATORU-KEYFILE-1"
    public static let keyFileExtension = "satorukey"

    /// 新しい鍵ファイルの中身 (説明の行 + 乱数 32 バイトを Base64 にしたもの)
    public static func newKeyFileContents() -> Data {
        let text = "\(keyFileHeader)\n# さとるエディタの鍵ファイルです。なくすと、これで暗号化した文書は開けなくなります。\n"
            + randomBytes(32).base64EncodedString() + "\n"
        return Data(text.utf8)
    }

    /// 鍵ファイルの中身から元の乱数を取り出す。鍵ファイルでなければ nil
    public static func keyFileSecret(_ contents: Data) -> Data? {
        guard contents.count < 4096, let text = String(data: contents, encoding: .utf8) else { return nil }
        // "\r\n" は 1 文字として来るので isNewline で切る
        let lines = text.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == keyFileHeader,
              let line = lines.dropFirst().first(where: { !$0.hasPrefix("#") && !$0.isEmpty }),
              let secret = Data(base64Encoded: line), secret.count == 32 else { return nil }
        return secret
    }

    /// 鍵ファイルの指紋 (暗号化ファイルの先頭に入れて、違う鍵ファイルをすぐ見分ける)
    public static func keyFileFingerprint(_ secret: Data) -> UInt32 {
        let digest = SHA256.hash(data: Data("satoru-keyfile-id".utf8) + secret)
        return digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    /// 鍵ファイルから、文書 1 つぶんの鍵を作る (文書ごとにソルトが違うので鍵も違う)。salt が nil なら新しく作る
    public static func keyFileKey(secret: Data, salt: Data? = nil) -> Key {
        let salt = salt ?? randomBytes(16)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt,
                                         info: Data("satoru-file-key".utf8), outputByteCount: 32)
        return Key(key: key, salt: salt, iterations: keyFileFingerprint(secret), kind: .keyfile)
    }

    /// 鍵ファイルで開く。違う鍵ファイルなら wrongKeyFile
    public static func open(_ data: Data, keyFileSecret secret: Data) throws -> (plain: Data, key: Key) {
        let h = try header(of: data)
        guard h.kind == .keyfile else { throw CryptoError.wrongPasswordOrDamaged }
        guard h.iterations == keyFileFingerprint(secret) else { throw CryptoError.wrongKeyFile }
        let key = keyFileKey(secret: secret, salt: h.salt)
        return (try open(data, with: key), key)
    }

    static func headerData(_ key: Key, version: UInt8 = version) -> Data {
        var h = magic
        h.append(version)
        if version >= 2 { h.append(key.kind.rawValue) }
        var it = key.iterations.bigEndian
        h.append(Data(bytes: &it, count: 4))
        h.append(key.salt)
        return h
    }

    /// 平文 → 暗号化ファイルの中身 (保存のたびに nonce は新しくなる)
    public static func seal(_ plain: Data, with key: Key) throws -> Data {
        try seal(plain, with: key, version: version)
    }

    static func seal(_ plain: Data, with key: Key, version v: UInt8) throws -> Data {
        let h = headerData(key, version: v)
        let box = try AES.GCM.seal(plain, using: key.key, authenticating: h)
        guard let combined = box.combined else { throw CryptoError.keyDerivationFailed }
        return h + combined
    }

    /// ファイルの先頭を読む
    public static func header(of data: Data) throws -> Header {
        guard isEncrypted(data) else { throw CryptoError.notEncrypted }
        let bytes = [UInt8](data.prefix(magic.count + 22))
        guard bytes.count > magic.count else { throw CryptoError.wrongPasswordOrDamaged }
        let v = bytes[magic.count]
        var i = magic.count + 1
        let kind: Kind
        switch v {
        case 1:
            kind = .password
        case 2:
            guard bytes.count > i, let k = Kind(rawValue: bytes[i]) else { throw CryptoError.unsupportedVersion }
            kind = k
            i += 1
        default:
            throw CryptoError.unsupportedVersion
        }
        guard bytes.count >= i + 20 else { throw CryptoError.wrongPasswordOrDamaged }
        let it = bytes[i..<(i + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let salt = Data(bytes[(i + 4)..<(i + 20)])
        return Header(version: v, kind: kind, iterations: it, salt: salt, length: i + 20)
    }

    /// 暗号化ファイル → 平文
    public static func open(_ data: Data, with key: Key) throws -> Data {
        let h = try header(of: data)
        guard data.count > h.length, h.salt == key.salt, h.kind == key.kind else { throw CryptoError.wrongPasswordOrDamaged }
        let aad = data.prefix(h.length)
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(h.length))
            return try AES.GCM.open(box, using: key.key, authenticating: aad)
        } catch {
            throw CryptoError.wrongPasswordOrDamaged
        }
    }

    /// パスワード・パスコードで開く (鍵も返すので、保存のときに使い回せる)
    public static func open(_ data: Data, password: String) throws -> (plain: Data, key: Key) {
        let h = try header(of: data)
        guard h.kind == .password || h.kind == .passcode else { throw CryptoError.wrongPasswordOrDamaged }
        // 極端な回数を書き込まれたファイルで固まらないように
        guard h.iterations >= 10_000, h.iterations <= 50_000_000 else { throw CryptoError.wrongPasswordOrDamaged }
        let key = try deriveKey(password: password, salt: h.salt, iterations: h.iterations, kind: h.kind)
        return (try open(data, with: key), key)
    }
}
