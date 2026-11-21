import Foundation
import CryptoKit

/// 共同編集の通信の暗号化。
/// ホストが共有のたびに作る「共有コード」から鍵を作り、1 通ずつ ChaCha20-Poly1305 で暗号化する。
/// - ホスト→ゲストとゲスト→ホストで別の鍵を使う (はね返し対策)
/// - 通し番号を暗号の中に入れて、順番の入れ替え・再送を受け付けない
/// - コードを知らない相手は 1 通目から復号できず、承認の確認すら出ない
public final class CollabCipher {
    public static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") // 紛らわしい 0 O 1 I は使わない

    /// 新しい共有コード (16 文字 = 80 ビット、4 文字ずつ区切る)
    public static func newCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let chars = bytes.map { alphabet[Int($0) % alphabet.count] }
        return stride(from: 0, to: 16, by: 4).map { String(chars[$0..<$0 + 4]) }.joined(separator: "-")
    }

    /// 入力されたコードの表記ゆれ (小文字・空白・ハイフン) をそろえる
    public static func normalize(_ code: String) -> String {
        code.uppercased().filter { alphabet.contains($0) }
    }

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    public init(code: String, isHost: Bool) {
        let ikm = SymmetricKey(data: Data(Self.normalize(code).utf8))
        let salt = Data("satoru-editor collab v1".utf8)
        func key(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data(label.utf8), outputByteCount: 32)
        }
        let h2g = key("host->guest"), g2h = key("guest->host")
        sendKey = isHost ? h2g : g2h
        receiveKey = isHost ? g2h : h2g
    }

    /// 平文 1 通 → 送る 1 行 (base64)
    public func seal(_ plain: Data) throws -> Data {
        var counter = sendCounter.bigEndian
        var payload = Data(bytes: &counter, count: 8)
        payload.append(plain)
        sendCounter += 1
        let box = try ChaChaPoly.seal(payload, using: sendKey)
        return box.combined.base64EncodedData()
    }

    /// 受け取った 1 行 → 平文。鍵違い・改ざん・順番違いなら nil
    public func open(_ line: Data) -> Data? {
        guard let raw = Data(base64Encoded: line),
              let box = try? ChaChaPoly.SealedBox(combined: raw),
              let payload = try? ChaChaPoly.open(box, using: receiveKey),
              payload.count >= 8 else { return nil }
        let counter = payload.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard counter == receiveCounter else { return nil }
        receiveCounter += 1
        return payload.dropFirst(8)
    }
}
