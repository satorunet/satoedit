import AppKit
import HinokiCore

/// 1 回の AI 利用で使ったトークン数
struct AIUsage {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    /// サービスが数を返さず、文字数から見積もったとき true
    var estimated = false
}

/// 料金の目安 (US ドル / 100 万トークン)
enum AIPricing {
    /// 設定フォルダの ai-prices.json ({ "モデル名": [入力, 出力] })。あれば、アプリの中の一覧表より優先する
    static var overridesURLForTesting: URL?
    static var overridesURL: URL {
        overridesURLForTesting ?? AppPaths.file("ai-prices.json")
    }
    private static var overridesCache: (date: Date?, table: [String: [Double]])?

    /// ファイルが書き換わったら読み直す
    static var overrides: [String: [Double]] {
        let date = (try? FileManager.default.attributesOfItem(atPath: overridesURL.path))?[.modificationDate] as? Date
        if let c = overridesCache, c.date == date { return c.table }
        let table = (try? Data(contentsOf: overridesURL)).map(AIModels.parseOverrides) ?? [:]
        overridesCache = (date, table)
        return table
    }

    /// アプリの中の一覧表 (と ai-prices.json) にある料金
    static func master(_ model: String) -> AIModels.Price? {
        AIModels.price(of: model, overrides: overrides)
    }

    static func pricingPage(_ p: AIProvider) -> URL? {
        switch p {
        case .claude: return URL(string: "https://www.anthropic.com/pricing")
        case .openai: return URL(string: "https://openai.com/api/pricing/")
        case .gemini: return URL(string: "https://ai.google.dev/pricing")
        case .custom: return nil
        }
    }

    /// 自分で入れた単価 (なければ nil)
    static func custom(_ p: AIProvider) -> (input: Double, output: Double)? {
        let d = UserDefaults.standard
        let i = d.double(forKey: "aiPriceIn.\(p.rawValue)"), o = d.double(forKey: "aiPriceOut.\(p.rawValue)")
        return (i > 0 || o > 0) ? (i, o) : nil
    }

    static func setCustom(_ p: AIProvider, input: Double, output: Double) {
        UserDefaults.standard.set(input, forKey: "aiPriceIn.\(p.rawValue)")
        UserDefaults.standard.set(output, forKey: "aiPriceOut.\(p.rawValue)")
    }

    /// 使う単価: 一覧表にあるモデルはその料金 → 無ければ自分で入れた単価 → 手元の AI なら 0
    static func price(provider p: AIProvider, model: String) -> (input: Double, output: Double)? {
        if let m = master(model) { return (m.input, m.output) }
        if let c = custom(p) { return c }
        if p == .custom { return (0, 0) }
        return nil
    }

    private static func dollars(_ v: Double) -> String { String(format: "%g", v) }

    /// 「入力 $0.10 / 出力 $0.50 (100 万トークン) ・ 日本語 1,000 字の校正で 約 ¥0.1」のような料金の説明
    static func priceText(provider p: AIProvider, model: String) -> String {
        guard !model.isEmpty, let pr = price(provider: p, model: model) else { return L("料金不明 (下で単価を入れると計算します)") }
        if pr.input == 0 && pr.output == 0 { return L("無料 (手元の AI)") }
        let yen = AIModels.sampleCost(AIModels.Price(input: pr.input, output: pr.output)) * yenPerDollar
        let y = yen < 1 ? String(format: "%.2f", yen) : (yen < 10 ? String(format: "%.1f", yen) : String(Int(yen.rounded())))
        var text = L("入力 ${0} / 出力 ${1} (100 万トークン) ・ 日本語 1,000 字の校正で 約 ¥{2}", dollars(pr.input), dollars(pr.output), y)
        if master(model) != nil, overrides[model] == nil, let c = AIModels.upcomingChange(model) {
            text += L(" ({0} から 入力 ${1} / 出力 ${2})", c.from, dollars(c.price.input), dollars(c.price.output))
        }
        return text
    }

    static func cost(_ u: AIUsage, provider: AIProvider, model: String) -> Double? {
        guard let p = price(provider: provider, model: model) else { return nil }
        return (Double(u.inputTokens) * p.input + Double(u.outputTokens) * p.output) / 1_000_000
    }

    /// 1 ドル何円で見るか
    static var yenPerDollar: Double {
        let v = UserDefaults.standard.double(forKey: "aiYenPerDollar")
        return v > 0 ? v : 150
    }

    static func format(_ dollars: Double?) -> String {
        guard let d = dollars else { return L("料金不明") }
        if d == 0 { return "$0" }
        let usd = d < 0.01 ? String(format: "$%.4f", d) : String(format: "$%.2f", d)
        let yen = d * yenPerDollar
        let jp = yen < 10 ? String(format: L("約 ¥%.1f"), yen) : L("約 ¥") + NumberFormatter.localizedString(from: NSNumber(value: Int(yen.rounded())), number: .decimal)
        return "\(usd) (\(jp))"
    }
}

/// 利用の記録 (~/.satoruEditor/ai-usage.json)
struct AIUsageRecord: Codable {
    let date: Date
    let provider: String
    let model: String
    let input: Int
    let output: Int
    let cost: Double?
    let estimated: Bool
}

enum AIUsageLog {
    /// 動作確認用 (アプリ本体では使わない)
    static var fileURLOverrideForTesting: URL?

    static var fileURL: URL {
        fileURLOverrideForTesting ?? AppPaths.file("ai-usage.json")
    }

    static let didChange = Notification.Name("SatoruAIUsageDidChange")

    private static var cache: [AIUsageRecord]?

    static var records: [AIUsageRecord] {
        if let c = cache { return c }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let list = (try? Data(contentsOf: fileURL)).flatMap { try? d.decode([AIUsageRecord].self, from: $0) } ?? []
        cache = list
        return list
    }

    static func add(_ u: AIUsage, provider: AIProvider, model: String) {
        guard u.inputTokens > 0 || u.outputTokens > 0 else { return }
        var list = records
        list.append(AIUsageRecord(date: Date(), provider: provider.rawValue, model: model, input: u.inputTokens, output: u.outputTokens,
                                  cost: AIPricing.cost(u, provider: provider, model: model), estimated: u.estimated))
        cache = list
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted]
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? e.encode(list).write(to: fileURL, options: .atomic)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func clear() {
        cache = []
        try? FileManager.default.removeItem(at: fileURL)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    struct Summary {
        var count = 0, input = 0, output = 0
        var cost = 0.0
        var unknownCost = false
        mutating func add(_ r: AIUsageRecord) {
            count += 1; input += r.input; output += r.output
            if let c = r.cost { cost += c } else { unknownCost = true }
        }
        var costText: String { AIPricing.format(cost) + (unknownCost ? L(" + 料金不明の分") : "") }
    }

    static func summary(_ filter: (AIUsageRecord) -> Bool) -> Summary {
        var s = Summary()
        records.filter(filter).forEach { s.add($0) }
        return s
    }

    static func monthKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}
