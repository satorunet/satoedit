import Foundation
import CryptoKit

/// AI アシスタントの接続先
enum AIProvider: String, CaseIterable {
    case openai, claude, gemini, custom // 一覧の並び順 (最初が既定の ChatGPT)

    var label: String {
        switch self {
        case .claude: return "Claude (Anthropic)"
        case .openai: return "ChatGPT (OpenAI)"
        case .gemini: return "Gemini (Google)"
        case .custom: return "カスタム (OpenAI 互換 API: Ollama・LM Studio など)"
        }
    }

    /// 最初から入れておくモデル (分からないものは空にして「一覧を取得」で選んでもらう)
    var defaultModel: String {
        switch self {
        case .claude: return "claude-opus-5-5"
        case .openai, .gemini, .custom: return ""
        }
    }

    var keyPageURL: URL? {
        switch self {
        case .claude: return URL(string: "https://platform.claude.com/")
        case .openai: return URL(string: "https://platform.openai.com/api-keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .custom: return nil
        }
    }

    /// 設定のしかた (画面に出す)
    var guide: String {
        switch self {
        case .claude:
            return "1. 「キーを取りに行く」でキーを作る\n2. 下に貼って「接続テスト」"
        case .openai:
            return "1. 「キーを取りに行く」でキーを作る\n2. 下に貼り、「一覧を取得」でモデルを選ぶ\n3. 「接続テスト」"
        case .gemini:
            return "1. 「キーを取りに行く」でキーを作る\n2. 下に貼り、「一覧を取得」でモデルを選ぶ\n3. 「接続テスト」"
        case .custom:
            return "Ollama などに接続します (例: http://localhost:11434/v1)。\nキーは空でも OK。「一覧を取得」→「接続テスト」"
        }
    }
}

/// AI アシスタントの設定 (API キーはキーチェーン)
enum AISettings {
    static var provider: AIProvider {
        get { AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "") ?? .openai }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "aiProvider") }
    }

    static func model(_ p: AIProvider) -> String {
        UserDefaults.standard.string(forKey: "aiModel.\(p.rawValue)") ?? p.defaultModel
    }

    static func setModel(_ m: String, _ p: AIProvider) {
        UserDefaults.standard.set(m, forKey: "aiModel.\(p.rawValue)")
    }

    /// 動作確認用 (アプリ本体では使わない)
    static var baseURLOverrideForTesting: [AIProvider: String] = [:]

    static func baseURL(_ p: AIProvider) -> String {
        if let o = baseURLOverrideForTesting[p] { return o }
        switch p {
        case .claude: return "https://api.anthropic.com"
        case .openai: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .custom: return UserDefaults.standard.string(forKey: "aiBaseURL.custom") ?? "http://localhost:11434/v1"
        }
    }

    static func setCustomBaseURL(_ s: String) {
        UserDefaults.standard.set(s, forKey: "aiBaseURL.custom")
    }

    static func apiKey(_ p: AIProvider) -> String { Keychain.get("ai.\(p.rawValue)") ?? "" }

    static func setAPIKey(_ k: String, _ p: AIProvider) {
        let t = k.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { Keychain.delete("ai.\(p.rawValue)") } else { Keychain.set(t, for: "ai.\(p.rawValue)") }
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "aiEnabled") }

    // MARK: 接続の確認

    /// いまの設定 (アドレス・モデル・キー) を表す文字列。どれかを変えると変わる
    private static func fingerprint(_ p: AIProvider) -> String {
        let raw = baseURL(p) + "|" + model(p) + "|" + apiKey(p)
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 「接続テスト」に成功した設定のままかどうか
    static func isVerified(_ p: AIProvider) -> Bool {
        guard !model(p).isEmpty, p == .custom || !apiKey(p).isEmpty else { return false }
        return UserDefaults.standard.string(forKey: "aiVerified.\(p.rawValue)") == fingerprint(p)
    }

    static func markVerified(_ p: AIProvider) {
        UserDefaults.standard.set(fingerprint(p), forKey: "aiVerified.\(p.rawValue)")
    }

    /// 使える状態か (追加機能がオンで、接続の確認も済んでいる)
    static var isReady: Bool { isEnabled && isVerified(provider) }
}

/// AI への問い合わせ (返事は少しずつ届く)。コールバックは main スレッド。
final class AIClient: NSObject, URLSessionDataDelegate {
    let provider: AIProvider
    let model: String
    private let apiKey: String
    private let base: String

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var errorBody = Data()
    private var statusCode = 200
    private var onDelta: ((String) -> Void)?
    private var onDone: ((Error?) -> Void)?
    private var finished = false
    private var streamError: String?
    /// 使ったトークン数 (終わったときに確定)
    private(set) var usage = AIUsage()
    private var promptLength = 0
    private var outputLength = 0

    init(provider: AIProvider = AISettings.provider) {
        self.provider = provider
        self.model = AISettings.model(provider)
        self.apiKey = AISettings.apiKey(provider)
        self.base = AISettings.baseURL(provider).trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    /// Claude でサーバ側の自動切り替え (安全上の理由で断られたときに別のモデルで答える) を使えるモデル
    private static let fallbackModels: Set<String> = [
        "claude-opus-5-5", "claude-sonnet-5-5", "claude-opus-5", "claude-fable-5-2", "claude-fable-5-1",
    ]

    // MARK: 送信

    func send(system: String, prompt: String, onDelta: @escaping (String) -> Void, onDone: @escaping (Error?) -> Void) {
        self.onDelta = onDelta
        self.onDone = onDone
        promptLength = (system as NSString).length + (prompt as NSString).length
        guard !model.isEmpty else {
            return fail("モデルを選んでください (設定 > AI アシスタント)。")
        }
        guard provider == .custom || !apiKey.isEmpty else {
            return fail("API キーを入れてください (設定 > AI アシスタント)。")
        }
        var req: URLRequest
        var body: [String: Any]
        switch provider {
        case .claude:
            guard let url = URL(string: base + "/v1/messages") else { return fail("アドレスが正しくありません") }
            req = URLRequest(url: url)
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": model, "max_tokens": 16000, "stream": true,
                "system": system,
                "messages": [["role": "user", "content": prompt]],
            ]
            if Self.fallbackModels.contains(model) {
                req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }
        case .openai, .custom:
            guard let url = URL(string: base + "/chat/completions") else { return fail("アドレスが正しくありません") }
            req = URLRequest(url: url)
            if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            body = [
                "model": model, "stream": true,
                "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
            ]
            // OpenAI は最後に使用量を返してもらう (互換サービスは受け付けないことがあるので付けない)
            if provider == .openai { body["stream_options"] = ["include_usage": true] }
        case .gemini:
            let m = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
            guard let enc = m.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: base + "/models/\(enc):streamGenerateContent?alt=sse") else {
                return fail("アドレスが正しくありません")
            }
            req = URLRequest(url: url)
            req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            body = [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": [["role": "user", "parts": [["text": prompt]]]],
            ]
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        task = session?.dataTask(with: req)
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        finish(nil)
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { self.finish(AIError(message: message)) }
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        // 使用量を返さないサービスは文字数から見積もる (日本語はだいたい 1 文字 ≒ 1 トークン)
        if usage.inputTokens == 0 && usage.outputTokens == 0 && (outputLength > 0) {
            usage = AIUsage(inputTokens: promptLength, outputTokens: outputLength, estimated: true)
        }
        AIUsageLog.add(usage, provider: provider, model: model)
        session?.finishTasksAndInvalidate()
        onDone?(error)
        onDelta = nil
        onDone = nil
    }

    // MARK: 受信 (Server-Sent Events)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if statusCode >= 400 {
            errorBody.append(data)
            return
        }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            buffer.removeSubrange(buffer.startIndex...nl)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let text = extractText(obj), !text.isEmpty {
                outputLength += (text as NSString).length
                onDelta?(text)
            }
        }
    }

    private func extractText(_ o: [String: Any]) -> String? {
        switch provider {
        case .claude:
            switch o["type"] as? String {
            case "message_start":
                if let u = (o["message"] as? [String: Any])?["usage"] as? [String: Any] {
                    usage.inputTokens = (u["input_tokens"] as? Int ?? 0)
                        + (u["cache_read_input_tokens"] as? Int ?? 0) + (u["cache_creation_input_tokens"] as? Int ?? 0)
                }
            case "content_block_delta":
                let d = o["delta"] as? [String: Any]
                return d?["type"] as? String == "text_delta" ? d?["text"] as? String : nil
            case "message_delta":
                if let n = (o["usage"] as? [String: Any])?["output_tokens"] as? Int { usage.outputTokens = n }
                if (o["delta"] as? [String: Any])?["stop_reason"] as? String == "refusal" {
                    streamError = "AI が回答を断りました。"
                }
            case "error":
                streamError = ((o["error"] as? [String: Any])?["message"] as? String) ?? "AI 側でエラーが起きました"
            default: break
            }
            return nil
        case .openai, .custom:
            if let e = o["error"] as? [String: Any] { streamError = e["message"] as? String ?? "エラー" }
            if let u = o["usage"] as? [String: Any] {
                usage.inputTokens = u["prompt_tokens"] as? Int ?? usage.inputTokens
                usage.outputTokens = u["completion_tokens"] as? Int ?? usage.outputTokens
            }
            let choices = o["choices"] as? [[String: Any]]
            return (choices?.first?["delta"] as? [String: Any])?["content"] as? String
        case .gemini:
            if let fb = o["promptFeedback"] as? [String: Any], let reason = fb["blockReason"] as? String {
                streamError = "安全上の理由で回答されませんでした (\(reason))"
            }
            if let u = o["usageMetadata"] as? [String: Any] {
                usage.inputTokens = u["promptTokenCount"] as? Int ?? usage.inputTokens
                usage.outputTokens = u["candidatesTokenCount"] as? Int ?? usage.outputTokens
            }
            let cands = o["candidates"] as? [[String: Any]]
            let parts = (cands?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
            return parts?.compactMap { $0["text"] as? String }.joined()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error as NSError?, e.code == NSURLErrorCancelled { return finish(nil) }
        if let error = error {
            return finish(AIError(message: "接続できませんでした: \(error.localizedDescription)"))
        }
        if statusCode >= 400 {
            return finish(AIError(message: Self.explain(status: statusCode, body: errorBody, provider: provider)))
        }
        finish(streamError.map { AIError(message: $0) })
    }

    static func explain(status: Int, body: Data, provider: AIProvider) -> String {
        var detail = String(decoding: body, as: UTF8.self)
        if let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let e = o["error"] as? [String: Any], let m = e["message"] as? String { detail = m }
            else if let m = o["message"] as? String { detail = m }
        }
        let head: String
        switch status {
        case 401, 403: head = "API キーが違います。"
        case 404: head = "モデルが見つかりません。"
        case 429: head = "上限に達したか、混んでいます。少し待ってください。"
        case 400: head = "受け付けられませんでした。"
        case 500...599: head = "AI 側のエラーです。少し待ってください。"
        default: head = "エラー (\(status))"
        }
        return head + "\n\n" + String(detail.prefix(600))
    }

    // MARK: モデル一覧

    static func listModels(provider p: AIProvider, apiKey: String, baseURL: String,
                           _ done: @escaping (Result<[String], Error>) -> Void) {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        var req: URLRequest
        switch p {
        case .claude:
            guard let u = URL(string: base + "/v1/models?limit=100") else { return }
            req = URLRequest(url: u)
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        case .openai, .custom:
            guard let u = URL(string: base + "/models") else { return }
            req = URLRequest(url: u)
            if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        case .gemini:
            guard let u = URL(string: base + "/models?pageSize=200") else { return }
            req = URLRequest(url: u)
            req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        req.timeoutInterval = 30
        URLSession.shared.dataTask(with: req) { data, resp, error in
            let result: Result<[String], Error>
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let error = error {
                result = .failure(AIError(message: "接続できませんでした: \(error.localizedDescription)"))
            } else if status >= 400 || data == nil {
                result = .failure(AIError(message: explain(status: status, body: data ?? Data(), provider: p)))
            } else {
                let o = (try? JSONSerialization.jsonObject(with: data!)) as? [String: Any] ?? [:]
                var ids: [String]
                if p == .gemini {
                    ids = (o["models"] as? [[String: Any]] ?? [])
                        .filter { ($0["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") }
                        .compactMap { ($0["name"] as? String).map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 } }
                } else {
                    ids = (o["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                }
                if p != .claude { ids.sort() } // Claude は新しい順のまま
                result = .success(ids)
            }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }
}

struct AIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
