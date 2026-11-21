import Foundation

/// 自分のパソコンの中で動かす軽い LLM (Ollama 経由) のための、画面を持たない部分
public enum LocalLLM {
    public static let server = "http://127.0.0.1:11434"
    /// AI アシスタントの「カスタム」接続先に入れるアドレス (OpenAI 互換)
    public static let openAIBase = "http://127.0.0.1:11434/v1"
    public static let downloadPage = "https://ollama.com/download"
    /// 公式の Mac 用の配布ファイル (いまの版)
    public static let installerURL = "https://ollama.com/download/Ollama.dmg"
    /// 公式の説明書 (必要な macOS のバージョンが書いてある)
    public static let requirementsURL = "https://docs.ollama.com/macos.md"
    /// 説明書を読めなかったときに使う、いまの版に必要な macOS (メジャー番号)
    public static let fallbackRequiredMacOS = 14
    /// 古い macOS 用: 公式に残っている前の版
    public static let legacyVersion = "0.9.0"
    public static let legacyInstallerURL = "https://github.com/ollama/ollama/releases/download/v0.9.0/Ollama-darwin.zip"
    public static let legacyRequiredMacOS = 11

    /// 説明書の "MacOS Sonoma (v14) or newer" から 14 を読む
    public static func parseRequiredMacOS(_ text: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: #"mac\s?os[^\n]{0,40}?\(v(\d{2})\)"#, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Int(ns.substring(with: m.range(at: 1)))
    }

    public enum Compatibility: Equatable {
        /// いまの版が動く
        case current
        /// いまの版は動かないが、前の版なら動く
        case legacy
        /// どちらも動かない
        case unsupported
    }

    public static func compatibility(osMajor: Int, required: Int) -> Compatibility {
        if osMajor >= required { return .current }
        if osMajor >= legacyRequiredMacOS { return .legacy }
        return .unsupported
    }

    public struct Recommended: Equatable {
        public let name: String
        /// だいたいの大きさ (GB)
        public let sizeGB: Double
        /// 日本語の説明 (画面には L() を通して出す)
        public let note: String
    }

    /// おすすめの軽いモデル (大きさは目安)
    public static let recommended: [Recommended] = [
        Recommended(name: "gemma3:1b", sizeGB: 0.8, note: "いちばん軽い。短い文章の手直し向き"),
        Recommended(name: "qwen2.5:1.5b", sizeGB: 1.0, note: "軽い。日本語もそこそこ"),
        Recommended(name: "qwen2.5-coder:1.5b", sizeGB: 1.0, note: "軽い。プログラム向き"),
        Recommended(name: "llama3.2:1b", sizeGB: 1.3, note: "軽い。英語が得意"),
        Recommended(name: "qwen2.5:3b", sizeGB: 1.9, note: "速さと賢さのバランス型"),
        Recommended(name: "gemma3:4b", sizeGB: 3.3, note: "日本語がしっかり。メモリ 8 GB 以上で"),
    ]

    public struct Installed: Equatable {
        public let name: String
        public let size: Int64
    }

    /// GET /api/tags の返事 ({"models":[{"name":"gemma3:1b","size":815319791,…}]})
    public static func parseTags(_ data: Data) -> [Installed] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { m in
            guard let name = (m["name"] as? String) ?? (m["model"] as? String) else { return nil }
            return Installed(name: name, size: (m["size"] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// 入っているモデルの名前と、一覧の名前が同じものか ("gemma3" と "gemma3:latest" は同じ)
    public static func sameModel(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String { s.contains(":") ? s.lowercased() : s.lowercased() + ":latest" }
        return norm(a) == norm(b)
    }

    public struct Progress: Equatable {
        public var status: String
        public var completed: Int64
        public var total: Int64
        public var error: String?
        public var done: Bool
        /// 0…1。まだ分からなければ nil
        public var fraction: Double? { total > 0 ? min(1, Double(completed) / Double(total)) : nil }
    }

    /// POST /api/pull が 1 行ずつ返す JSON を読む
    public static func parseProgress(_ line: String) -> Progress? {
        guard let data = line.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let e = o["error"] as? String { return Progress(status: "", completed: 0, total: 0, error: e, done: true) }
        let status = (o["status"] as? String) ?? ""
        return Progress(status: status,
                        completed: (o["completed"] as? NSNumber)?.int64Value ?? 0,
                        total: (o["total"] as? NSNumber)?.int64Value ?? 0,
                        error: nil, done: status == "success")
    }

    /// 815319791 → "0.8 GB"
    public static func sizeText(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 0.1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_000_000)
    }

    /// モデル名に使える文字だけか (URL やコマンドに混ぜても安全なように)
    public static func isValidModelName(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/-]{0,80}(:[A-Za-z0-9._-]{1,40})?$"#, options: .regularExpression) != nil
    }
}
