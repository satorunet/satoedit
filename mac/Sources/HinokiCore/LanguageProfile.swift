import Foundation

/// 言語ごとの設定 (秀丸の「ファイルタイプ別の設定」に相当)
public struct LanguageProfile: Codable, Equatable {
    public var name: String
    /// 小文字の拡張子 ("swift", "py" …)
    public var extensions: [String] = []
    /// 拡張子で判別できないファイル名 ("Makefile", ".zshrc" …)
    public var fileNames: [String] = []
    public var keywords: [String] = []
    public var types: [String] = []
    public var lineComments: [String] = []
    /// [[開始, 終了], …]
    public var blockComments: [[String]] = []
    /// 1 行で閉じる文字列の区切り
    public var stringDelimiters: [String] = []
    /// 改行をまたげる文字列の区切り (""" や `)
    public var multilineStrings: [String] = []
    public var caseInsensitive = false
    /// 大文字で始まる識別子を型として色付けする
    public var capitalizedIsType = false
    /// <tag> を色付けする (HTML/XML)
    public var markupTags = false
    public var tabWidth = 4
    /// Tab キーでスペースを入れる
    public var useSpaces = false
}

extension LanguageProfile {
    // JSON では name 以外を省略できるようにする
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        extensions = try c.decodeIfPresent([String].self, forKey: .extensions)?.map { $0.lowercased() } ?? []
        fileNames = try c.decodeIfPresent([String].self, forKey: .fileNames) ?? []
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        types = try c.decodeIfPresent([String].self, forKey: .types) ?? []
        lineComments = try c.decodeIfPresent([String].self, forKey: .lineComments) ?? []
        blockComments = try c.decodeIfPresent([[String]].self, forKey: .blockComments) ?? []
        stringDelimiters = try c.decodeIfPresent([String].self, forKey: .stringDelimiters) ?? []
        multilineStrings = try c.decodeIfPresent([String].self, forKey: .multilineStrings) ?? []
        caseInsensitive = try c.decodeIfPresent(Bool.self, forKey: .caseInsensitive) ?? false
        capitalizedIsType = try c.decodeIfPresent(Bool.self, forKey: .capitalizedIsType) ?? false
        markupTags = try c.decodeIfPresent(Bool.self, forKey: .markupTags) ?? false
        tabWidth = max(1, try c.decodeIfPresent(Int.self, forKey: .tabWidth) ?? 4)
        useSpaces = try c.decodeIfPresent(Bool.self, forKey: .useSpaces) ?? false
    }
}

public struct ProfileStore {
    public static var userFileURL: URL {
        AppPaths.file("profiles.json")
    }

    public private(set) var profiles: [LanguageProfile]
    public private(set) var loadError: String?

    /// 組み込みのプロファイルに、ユーザー設定ファイルの内容を名前単位で上書き・追加する
    public init(userFile: URL? = ProfileStore.userFileURL) {
        var list = BuiltInProfiles.all
        if let url = userFile, let data = try? Data(contentsOf: url) {
            do {
                for p in try JSONDecoder().decode([LanguageProfile].self, from: data) {
                    if let i = list.firstIndex(where: { $0.name == p.name }) {
                        list[i] = p
                    } else {
                        list.append(p)
                    }
                }
            } catch {
                loadError = L("{0} を読み込めませんでした: {1}", url.path, error.localizedDescription)
            }
        }
        profiles = list
    }

    public func profile(forFileName fileName: String) -> LanguageProfile? {
        let lower = fileName.lowercased()
        if let p = profiles.first(where: { $0.fileNames.contains { $0.lowercased() == lower } }) {
            return p
        }
        let ext = (lower as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return profiles.first { $0.extensions.contains(ext) }
    }

    public func profile(named name: String) -> LanguageProfile? {
        profiles.first { $0.name == name }
    }

    public static func builtInJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(BuiltInProfiles.all)
    }
}
