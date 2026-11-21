import Foundation

/// AI の答えを「ユーザーへのひとこと」と「文章に入れる中身」に分ける。
/// 中身は <result> … </result> で囲んで返してもらう
public enum AIAnswerParts {
    public static let open = "<result>"
    public static let close = "</result>"

    public struct Parts: Equatable {
        /// ユーザーへの返事 (中身の前後の文)
        public var message: String
        /// 文章に入れる中身。囲みがなければ nil
        public var content: String?
        /// 中身の囲みが閉じているか (届いている途中なら false)
        public var closed: Bool
    }

    /// 届いている途中の文でも分けられる (閉じていない <result> の後ろは中身として扱う)
    public static func split(_ text: String) -> Parts {
        guard let o = text.range(of: open) else {
            // 囲みがなくても、``` のコードの塊があれば、それを中身にする
            if let fenced = splitFenced(text) { return fenced }
            // 開きの途中 ("<res") が末尾にあるあいだは、まだ見せない
            var msg = text
            for k in stride(from: open.count - 1, through: 1, by: -1) where msg.hasSuffix(String(open.prefix(k))) {
                msg.removeLast(k)
                break
            }
            return Parts(message: trim(msg), content: nil, closed: false)
        }
        let before = String(text[..<o.lowerBound])
        let rest = text[o.upperBound...]
        if let c = rest.range(of: close) {
            let content = String(rest[..<c.lowerBound])
            let after = String(rest[c.upperBound...])
            let message = [trim(before), trim(after)].filter { !$0.isEmpty }.joined(separator: "\n")
            return Parts(message: message, content: trimNewlines(content), closed: true)
        }
        var content = String(rest)
        for k in stride(from: close.count - 1, through: 1, by: -1) where content.hasSuffix(String(close.prefix(k))) {
            content.removeLast(k)
            break
        }
        return Parts(message: trim(before), content: trimNewlines(content), closed: false)
    }

    /// "説明\n```js\nコード\n```\n説明" → 説明 と コード (閉じていない塊も、届いている途中として扱う)
    static func splitFenced(_ text: String) -> Parts? {
        guard let start = text.range(of: "```") else { return nil }
        let before = String(text[..<start.lowerBound])
        // ``` のあとの言語名 (js など) の行は飛ばす
        let afterFence = text[start.upperBound...]
        guard let nl = afterFence.firstIndex(of: "\n") else {
            return Parts(message: trim(before), content: "", closed: false)
        }
        let body = afterFence[afterFence.index(after: nl)...]
        if let end = body.range(of: "```") {
            var code = String(body[..<end.lowerBound])
            if code.hasSuffix("\n") { code.removeLast() }
            let after = String(body[end.upperBound...])
            let message = [trim(before), trim(after)].filter { !$0.isEmpty }.joined(separator: "\n")
            return Parts(message: message, content: code, closed: true)
        }
        var code = String(body)
        for k in [2, 1] where code.hasSuffix(String(repeating: "`", count: k)) { code.removeLast(k); break }
        return Parts(message: trim(before), content: code, closed: false)
    }

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 中身は前後の改行 1 つずつだけ落とす (行頭の空白などは中身なので残す)
    private static func trimNewlines(_ s: String) -> String {
        var t = s
        if t.hasPrefix("\r\n") { t.removeFirst(2) } else if t.hasPrefix("\n") { t.removeFirst() }
        if t.hasSuffix("\r\n") { t.removeLast(2) } else if t.hasSuffix("\n") { t.removeLast() }
        return t
    }
}
