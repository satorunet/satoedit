import Foundation

/// 表示する言葉の切り替え (日本語 / 英語)。
/// プログラムの中は日本語で書き、英語のときは I18nEnglish.swift の対応表で置き換える。対応がなければ日本語のまま出す。
/// Windows 版の shared/i18n.js と同じ考え方。
public enum I18n {
    /// 設定 "language" に入れられる値
    public static let settings = ["auto", "ja", "en"]

    /// いま使っている言語 ("ja" か "en")
    public private(set) static var language = "ja"

    /// 設定の値 ("auto" | "ja" | "en") と OS の言語の並び ("ja-JP" など) から、実際に使う言語を決める。
    /// 自動のときは、OS が日本語なら日本語、それ以外は英語
    public static func resolve(setting: String?, systemLanguages: [String]) -> String {
        if setting == "ja" || setting == "en" { return setting! }
        return (systemLanguages.first ?? "").lowercased().hasPrefix("ja") ? "ja" : "en"
    }

    public static func setLanguage(_ lang: String) {
        language = lang == "en" ? "en" : "ja"
    }

    /// 日本語 → 英語 の対応表
    public static let english: [String: String] = parse(I18nEnglish.text)

    /// 対応表の文章を読む。1 つの言葉は「日本語の行・英語の行」の 2 行で、言葉と言葉の間は空行。
    /// 言葉の中の改行は \n と書く。# で始まる行は見出し (読み飛ばす)
    static func parse(_ text: String) -> [String: String] {
        var table: [String: String] = [:]
        var pending: String?
        func unescape(_ s: String) -> String { s.replacingOccurrences(of: "\\n", with: "\n") }
        for raw in text.components(separatedBy: "\n") {
            if raw.isEmpty || (pending == nil && raw.hasPrefix("#")) {
                pending = nil
                continue
            }
            if let ja = pending {
                table[unescape(ja)] = unescape(raw)
                pending = nil
            } else {
                pending = raw
            }
        }
        return table
    }

    /// {0} {1} … を引数で置き換える
    static func fill(_ s: String, _ args: [Any]) -> String {
        guard !args.isEmpty else { return s }
        var out = s
        for (i, a) in args.enumerated() {
            out = out.replacingOccurrences(of: "{\(i)}", with: "\(a)")
        }
        return out
    }

    public static func translate(_ key: String, _ args: [Any] = []) -> String {
        let s = language == "en" ? (english[key] ?? key) : key
        return fill(s, args)
    }
}

/// 画面に出す言葉はこれを通す。L("{0} 件見つかりました", 3)
public func L(_ key: String, _ args: Any...) -> String {
    I18n.translate(key, args)
}
