import Foundation

/// テキスト一覧のバックアップ (1 つのファイル)。中身は JSON で、パスワードで暗号化する (FileCrypto と同じ AES-256-GCM・PBKDF2)。
/// ファイルの中身そのまま・表示 (作文など)・ピン・ロック・日時と、フォルダのアイコンや並び、公開したリンクの記録を入れる。
public enum LibraryBackup {
    public static let fileExtension = "satorubackup"
    static let format = "satoruEditor.libraryBackup"
    static let version = 1

    /// 版の履歴の 1 版 (古い順に入れる)
    public struct HistoryVersion: Codable, Equatable {
        public var date: Date
        public var message: String
        public var data: Data
        public init(date: Date, message: String, data: Data) { self.date = date; self.message = message; self.data = data }
    }

    public struct Entry: Codable, Equatable {
        /// バックアップの中での場所: "folder/…" (さとるエディタのフォルダの中) か "other/名前" (ほかの場所のファイル)
        public var path: String
        public var data: Data
        public var mode: String?
        public var pinned: Bool
        public var locked: Bool
        public var created: Date?
        public var modified: Date?
        /// 版の履歴 (入れたときだけ。前の版のバックアップには無い)
        public var history: [HistoryVersion]?
        public init(path: String, data: Data, mode: String? = nil, pinned: Bool = false, locked: Bool = false,
                    created: Date? = nil, modified: Date? = nil, history: [HistoryVersion]? = nil) {
            self.path = path; self.data = data; self.mode = mode; self.pinned = pinned; self.locked = locked
            self.created = created; self.modified = modified; self.history = history
        }
    }

    public struct Archive: Codable, Equatable {
        public var format = LibraryBackup.format
        public var version = LibraryBackup.version
        public var createdAt = Date()
        public var app = "さとるエディタ"
        public var entries: [Entry]
        /// 空のフォルダも戻せるように (道すじ)
        public var folders: [String]
        /// フォルダのアイコン・並び (設定に入っているもの)
        public var folderIcons: [String: String]
        public var folderOrder: [String]
        /// 公開したリンクの記録 (アプリの記録をそのまま。公開をやめる・更新するための合言葉も入る)
        public var sharedLinks: Data?
        public init(entries: [Entry], folders: [String] = [], folderIcons: [String: String] = [:], folderOrder: [String] = [], sharedLinks: Data? = nil) {
            self.entries = entries; self.folders = folders; self.folderIcons = folderIcons; self.folderOrder = folderOrder
            self.sharedLinks = sharedLinks
        }
    }

    public enum BackupError: LocalizedError {
        case notBackup
        case newerVersion
        public var errorDescription: String? {
            switch self {
            case .notBackup: return I18n.translate("さとるエディタのバックアップではありません")
            case .newerVersion: return I18n.translate("新しい版のさとるエディタで作ったバックアップです。アプリを新しくしてください")
            }
        }
    }

    /// まとめて暗号化する
    public static func seal(_ archive: Archive, password: String) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        let plain = try enc.encode(archive)
        let key = try FileCrypto.deriveKey(password: password)
        return try FileCrypto.seal(plain, with: key)
    }

    /// パスワードで開く (違えば FileCrypto のエラー)
    public static func open(_ data: Data, password: String) throws -> Archive {
        guard FileCrypto.isEncrypted(data) else { throw BackupError.notBackup }
        let plain = try FileCrypto.open(data, password: password).plain
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        guard let a = try? dec.decode(Archive.self, from: plain), a.format == format else { throw BackupError.notBackup }
        if a.version > version { throw BackupError.newerVersion }
        return a
    }

    /// 戻すときの場所の中身: "folder/a/b.txt" → "a/b.txt"。外へ出る道すじ (..) や絶対の道すじは受け付けない
    public static func safeRelative(_ path: String, prefix: String) -> String? {
        guard path.hasPrefix(prefix + "/") else { return nil }
        let rel = String(path.dropFirst(prefix.count + 1))
        let parts = rel.split(separator: "/", omittingEmptySubsequences: false)
        guard !rel.isEmpty, !rel.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return rel
    }
}
