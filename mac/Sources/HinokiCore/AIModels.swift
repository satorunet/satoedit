import Foundation

/// AI のモデルと料金のマスタ (アプリの中に持っておく一覧表)。
/// 料金は各社の一覧 API では取れないので、公式の料金ページの値をここに写してある (US ドル / 100 万トークン、標準の料金)。
/// 値段は変わるので目安として使い、正しい金額は各社の請求で確かめる。
/// 自分で直したいときは、設定フォルダに ai-prices.json を置く ({ "モデル名": [入力, 出力] } の形。ここの値より優先される)。
/// Windows 版の shared/aimodels.js と同じ表。
public enum AIModels {
    /// 料金を確認した日
    public static let updated = "2026-11-18"

    public struct Price: Equatable {
        public var input: Double
        public var output: Double
        public init(input: Double, output: Double) {
            self.input = input
            self.output = output
        }
    }

    /// 値上げ・値下げの予定 (from の日から、その料金になる)
    public struct Change: Equatable {
        public var from: String
        public var price: Price
    }

    struct Entry {
        var price: Price
        var changes: [Change] = []
    }

    private static func p(_ i: Double, _ o: Double) -> Entry { Entry(price: Price(input: i, output: o)) }
    private static func p(_ i: Double, _ o: Double, from: String, _ ni: Double, _ no: Double) -> Entry {
        Entry(price: Price(input: i, output: o), changes: [Change(from: from, price: Price(input: ni, output: no))])
    }

    static let prices: [String: Entry] = [
        // OpenAI
        "gpt-6.2-astra": p(8, 40), "gpt-6.2-sol": p(2, 10), "gpt-6-astra": p(10, 50), "gpt-6.1-sol": p(2, 10), "gpt-6.1-terra": p(1, 5),
        "gpt-6-luna": p(0.10, 0.50), "gpt-6-sol": p(2, 10), "gpt-5.6-sol": p(4, 20), "gpt-5.6-terra": p(2, 12), "gpt-5.6-luna": p(0.20, 1.20),
        "gpt-5.5": p(5, 30), "gpt-5.5-pro": p(30, 180), "gpt-5.4": p(2.5, 15), "gpt-5.4-pro": p(30, 180), "gpt-5.4-mini": p(0.75, 4.5),
        "gpt-5.4-nano": p(0.20, 1.25), "gpt-5.2": p(1.75, 14), "gpt-5.2-pro": p(21, 168), "gpt-5.1": p(1.25, 10), "gpt-5": p(1.25, 10),
        "gpt-5-mini": p(0.25, 2), "gpt-5-nano": p(0.05, 0.40), "gpt-5-pro": p(15, 120),
        "gpt-4.1": p(2, 8), "gpt-4.1-mini": p(0.40, 1.60), "gpt-4o": p(2.5, 10), "gpt-4o-mini": p(0.15, 0.60), "o3-pro": p(20, 80), "o3": p(2, 8),
        // Claude
        "claude-fable-5-2": p(8, 40), "claude-fable-5-1": p(10, 50), "claude-fable-5": p(10, 50),
        "claude-opus-5-5": p(4, 20), "claude-opus-5": p(5, 25), "claude-opus-4-8": p(5, 25), "claude-opus-4-7": p(5, 25), "claude-opus-4-6": p(5, 25),
        "claude-sonnet-5-5": p(2, 10), "claude-sonnet-5": p(2, 10), "claude-sonnet-4-6": p(3, 15),
        "claude-haiku-5-5": p(0.10, 0.50), "claude-haiku-4-5": p(1, 5),
        // Gemini
        "gemini-4-carbon": p(2, 10, from: "2026-12-01", 4, 20),
        "gemini-4-argon": p(2, 10, from: "2026-12-01", 4, 20),
        "gemini-4-hydrogen": p(1.5, 7.5),
        "gemini-3.8-flash": p(0.75, 3.75, from: "2027-01-01", 1.5, 7.5),
        "gemini-3.6-flash": p(0.75, 3.75, from: "2027-01-01", 1.5, 7.5),
        "gemini-3.5-flash-lite": p(0.30, 2.50), "gemini-3.1-flash-lite": p(0.25, 1.50), "gemini-3.1-pro-preview": p(2, 12),
        "gemini-3-flash-preview": p(0.50, 3), "gemini-2.5-flash-lite": p(0.10, 0.40),
    ]

    /// かんたん選択: 接続先 (openai / claude / gemini) ごとの「最安 & 最速」と「内容重視」
    public static let presets: [String: (fast: String, quality: String)] = [
        "openai": ("gpt-6-luna", "gpt-6.2-sol"),
        "claude": ("claude-haiku-5-5", "claude-opus-5-5"),
        "gemini": ("gemini-3.1-flash-lite", "gemini-4-carbon"),
    ]

    /// 日付を "YYYY-MM-DD" に (料金の切り替わりは UTC の日付で見る)
    public static func day(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func normalized(_ model: String) -> String {
        model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
    }

    /// モデルの料金 (その日の値)。マスタに無ければ nil。overrides は ai-prices.json の中身
    public static func price(of model: String, overrides: [String: [Double]] = [:], today: String = day()) -> Price? {
        if let o = overrides[model], o.count == 2, o.allSatisfy({ $0 >= 0 }) { return Price(input: o[0], output: o[1]) }
        guard let e = prices[normalized(model)] else { return nil }
        var out = e.price
        for c in e.changes where today >= c.from { out = c.price }
        return out
    }

    /// これから料金が変わる予定 (なければ nil)
    public static func upcomingChange(_ model: String, today: String = day()) -> Change? {
        prices[normalized(model)]?.changes.first { $0.from > today }
    }

    /// 日本語 1,000 字の校正 1 回ぶんの目安 (入力 1,500・出力 1,500 トークンとして)。ドル
    public static func sampleCost(_ price: Price) -> Double {
        (1500 * price.input + 1500 * price.output) / 1_000_000
    }

    /// ai-prices.json の中身 ({ "モデル名": [入力, 出力] }) を読む。形が違う項目は捨てる
    public static func parseOverrides(_ data: Data) -> [String: [Double]] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var out: [String: [Double]] = [:]
        for (model, value) in root {
            guard let list = value as? [Any], list.count == 2 else { continue }
            let numbers = list.compactMap { ($0 as? NSNumber)?.doubleValue }
            if numbers.count == 2, numbers.allSatisfy({ $0 >= 0 }) { out[model] = numbers }
        }
        return out
    }
}

/// AI の答えを文章に入れる場所を決める。
/// 頼んだときの対象 (from..<to にあった original) を覚えておき、待っているあいだに文章が変わっていたら探し直す
public enum AIApply {
    /// 対象がいまどこにあるか (UTF-16 の位置)。分からなくなっていたら nil
    /// (もとの文章が見つからない、または同じ文章が 2 か所以上にあって決められない)
    public static func locate(in now: String, from: Int, to: Int, original: String) -> NSRange? {
        let ns = now as NSString
        let length = (original as NSString).length
        if from >= 0, to >= from, to <= ns.length, to - from == length,
           ns.substring(with: NSRange(location: from, length: length)) == original {
            return NSRange(location: from, length: length)
        }
        guard length > 0 else { return nil }
        let first = ns.range(of: original, options: .literal)
        guard first.location != NSNotFound else { return nil }
        let rest = NSRange(location: first.location + 1, length: ns.length - first.location - 1)
        if ns.range(of: original, options: .literal, range: rest).location != NSNotFound { return nil }
        return first
    }

    /// 対象のあとに足すときの文字列 (対象が改行で終わっていなければ、行を改めてから足す)
    public static func insertion(after to: Int, in now: String, text: String) -> String {
        let ns = now as NSString
        if to <= 0 || to > ns.length || ns.character(at: to - 1) == 0x0A { return text }
        return "\n" + text
    }
}
