import Foundation
import Security

/// 登録したサーバ (パスワード・鍵のパスフレーズはキーチェーンに入れる)
struct RemoteServer: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case sftp, ftp, ftps
        var label: String {
            switch self {
            case .sftp: return "SFTP (SSH)"
            case .ftp: return "FTP"
            case .ftps: return "FTPS (FTP + TLS)"
            }
        }
        var defaultPort: Int { self == .sftp ? 22 : 21 }
    }

    enum Auth: String, Codable {
        case password, key
    }

    var id = UUID().uuidString
    var name = ""
    var kind: Kind = .sftp
    var host = ""
    var port = 22
    var user = ""
    var auth: Auth = .password
    /// 鍵ファイル (SFTP のみ)
    var keyPath = ""
    /// 接続したとき最初に開くフォルダ (空ならログインしたところ)
    var initialPath = ""

    var displayName: String { name.isEmpty ? "\(user)@\(host)" : name }

    /// パスワード、または鍵のパスフレーズ
    var secret: String? {
        get { Keychain.get(id) }
        nonmutating set {
            if let v = newValue, !v.isEmpty { Keychain.set(v, for: id) } else { Keychain.delete(id) }
        }
    }
}

/// サーバ一覧の保存場所
enum RemoteServerStore {
    private static let key = "remoteServers"

    static var servers: [RemoteServer] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let list = try? JSONDecoder().decode([RemoteServer].self, from: data) else { return [] }
            return list
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
        }
    }
}

/// パスワードをキーチェーン (macOS の鍵束) にしまう
enum Keychain {
    /// 動作確認用: 本物の保存先に触れないよう、別の名前に切り替える (アプリ本体では使わない)
    static var serviceOverrideForTesting: String?
    private static var service: String { serviceOverrideForTesting ?? "さとるエディタ サーバ" }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// 一度読んだ値は、アプリを終えるまでおぼえておく (読むたびに macOS の確認が出ないように)
    private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    static func get(_ account: String) -> String? {
        let key = service + "\u{1}" + account
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let value = read(account)
        lock.lock(); cache[key] = value; lock.unlock()
        return value
    }

    private static func remember(_ account: String, _ value: String?) {
        lock.lock(); cache[service + "\u{1}" + account] = value; lock.unlock()
    }

    private static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        remember(account, value)
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    static func delete(_ account: String) {
        remember(account, nil)
        SecItemDelete(query(account) as CFDictionary)
    }
}
