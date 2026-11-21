import Foundation

/// JS 拡張機能の manifest.json
///
/// ```json
/// { "id": "date-stamp", "name": "日付を入れる", "version": "1.0.0",
///   "author": "satoru", "description": "…", "main": "main.js",
///   "permissions": ["network", "clipboard"], "homepage": "https://…" }
/// ```
public struct PluginManifest: Codable, Equatable {
    public var id: String
    public var name: String
    public var version: String
    public var author: String
    public var description: String
    public var main: String
    public var permissions: [String]
    public var homepage: String?
    /// 一覧に出す絵。絵文字 1 つ ("📅") か、フォルダの中の画像 ("icon.png")
    public var icon: String?

    /// 使える権限
    public enum Permission: String, CaseIterable {
        /// satoru.fetch でネットにつなぐ
        case network
        /// クリップボードを読み書きする
        case clipboard
    }

    public enum Problem: Error, Equatable {
        case badJSON(String)
        case badID(String)
        case missing(String)
        case unknownPermission(String)
        case badMain(String)
    }

    public init(id: String, name: String, version: String = "1.0.0", author: String = "", description: String = "",
                main: String = "main.js", permissions: [String] = [], homepage: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.description = description
        self.main = main
        self.permissions = permissions
        self.homepage = homepage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        main = try c.decodeIfPresent(String.self, forKey: .main) ?? "main.js"
        permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
        homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
    }

    /// 読んで、中身が正しいか確かめる
    public static func parse(_ data: Data) throws -> PluginManifest {
        let m: PluginManifest
        do {
            m = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch DecodingError.keyNotFound(let key, _) {
            throw Problem.missing(key.stringValue)
        } catch {
            throw Problem.badJSON(error.localizedDescription)
        }
        try m.validate()
        return m
    }

    public func validate() throws {
        // フォルダ名にも使うので、英小文字・数字・- . _ だけ
        guard id.range(of: #"^[a-z0-9][a-z0-9._-]{0,63}$"#, options: .regularExpression) != nil else { throw Problem.badID(id) }
        for p in permissions where Permission(rawValue: p) == nil { throw Problem.unknownPermission(p) }
        // フォルダの外のファイルは読ませない
        guard !main.isEmpty, !main.hasPrefix("/"), !main.split(separator: "/").contains(".."), main.hasSuffix(".js") else {
            throw Problem.badMain(main)
        }
    }

    public func has(_ p: Permission) -> Bool { permissions.contains(p.rawValue) }
}

public enum PluginVersion {
    /// "1.2.10" と "1.2.9" のように数字ごとに比べる。a が新しければ 1
    public static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] {
            s.split(whereSeparator: { $0 == "." || $0 == "-" }).map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q ? 1 : -1 }
        }
        return 0
    }
}

public enum PluginSource {
    /// 貼られた URL を、zip を取りに行く URL にする。
    /// GitHub のリポジトリ (https://github.com/user/repo) は既定のブランチの zip にする
    public static func downloadURL(for text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("github.com/") { s = "https://" + s }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return nil }
        if host == "github.com" || host == "www.github.com" {
            let comps = url.path.split(separator: "/").map(String.init)
            if comps.count >= 2 {
                let user = comps[0]
                var repo = comps[1]
                if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
                // .../tree/branch はそのブランチ
                if comps.count >= 4, comps[2] == "tree" {
                    let branch = comps[3...].joined(separator: "/")
                    return URL(string: "https://github.com/\(user)/\(repo)/archive/refs/heads/\(branch).zip")
                }
                if comps.count == 2 || (comps.count >= 3 && comps[2] != "archive" && comps[2] != "releases") {
                    return URL(string: "https://github.com/\(user)/\(repo)/archive/HEAD.zip")
                }
            }
        }
        return url
    }
}

/// メニューのショートカット "cmd+shift+d" を分ける
public struct PluginShortcut: Equatable {
    public var key: String
    public var command = false, shift = false, option = false, control = false

    public static func parse(_ text: String) -> PluginShortcut? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, last.count == 1 else { return nil }
        var s = PluginShortcut(key: last)
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command", "meta", "ctrlorcmd", "cmdorctrl": s.command = true
            case "shift": s.shift = true
            case "alt", "option", "opt": s.option = true
            case "ctrl", "control": s.control = true
            default: return nil
            }
        }
        // 修飾キーなしの 1 文字は、普通の入力とぶつかるので使わせない
        guard s.command || s.control || s.option else { return nil }
        return s
    }
}
