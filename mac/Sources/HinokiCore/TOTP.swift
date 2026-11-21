import Foundation
import CryptoKit

/// スマホの認証アプリ (Google Authenticator など) と同じ 6 桁コードを計算する (RFC 6238, HMAC-SHA1, 30 秒ごと)
public enum TOTP {
    public static let period: TimeInterval = 30
    public static let digits = 6

    /// 認証アプリに登録する秘密 (20 バイトの乱数)
    public static func newSecret() -> Data {
        FileCrypto.randomBytes(20)
    }

    /// ある時刻のコード
    public static func code(secret: Data, at time: Date = Date(), digits: Int = digits) -> String {
        code(secret: secret, counter: UInt64(max(0, time.timeIntervalSince1970) / period), digits: digits)
    }

    static func code(secret: Data, counter: UInt64, digits: Int) -> String {
        var c = counter.bigEndian
        let message = Data(bytes: &c, count: 8)
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let value = (UInt32(mac[offset] & 0x7F) << 24) | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        var mod: UInt32 = 1
        for _ in 0..<digits { mod *= 10 }
        let s = String(value % mod)
        return String(repeating: "0", count: max(0, digits - s.count)) + s
    }

    /// 入力されたコードが合っているか。時計のずれに備えて前後 1 つ (±30 秒) まで認める
    public static func verify(_ input: String, secret: Data, at time: Date = Date(), window: Int = 1) -> Bool {
        let entered = input.filter { !$0.isWhitespace }
        guard entered.count == digits, entered.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        let counter = Int64(max(0, time.timeIntervalSince1970) / period)
        var ok = false
        for d in -window...window where counter + Int64(d) >= 0 {
            // 途中で抜けず、毎回すべて比べる
            if code(secret: secret, counter: UInt64(counter + Int64(d)), digits: digits) == entered { ok = true }
        }
        return ok
    }

    /// 認証アプリに手で打ち込むための表記 (Base32、= の詰め物なし)
    public static func base32(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = ""
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[Int((buffer >> UInt32(bits - 5)) & 0x1F)])
                bits -= 5
            }
            buffer &= (1 << UInt32(bits)) - 1
        }
        if bits > 0 { out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 0x1F)]) }
        return out
    }

    /// QR コードにする登録用の URL
    public static func uri(secret: Data, account: String, issuer: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return "otpauth://totp/\(enc(issuer)):\(enc(account))?secret=\(base32(secret))&issuer=\(enc(issuer))&algorithm=SHA1&digits=\(digits)&period=\(Int(period))"
    }
}
