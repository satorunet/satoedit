import Foundation

/// 名前 (拡張子) のない文書の中身から、言語の見当をつける。
/// 返すのは LanguageProfile の名前。分からなければ nil
public enum LanguageGuess {
    public static func guess(_ text: String) -> String? {
        let head = String(text.prefix(4000))
        let t = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let lower = t.lowercased()
        let ns = head as NSString
        func has(_ pattern: String) -> Bool {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return false }
            return re.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)) != nil
        }
        // 最初の行の印
        if t.hasPrefix("#!") {
            let first = t.prefix(while: { $0 != "\n" })
            if first.contains("python") { return "Python" }
            if first.contains("node") { return "JavaScript / TypeScript" }
            if first.contains("ruby") { return "Ruby" }
            if first.contains("php") { return "PHP" }
            return "シェル"
        }
        if t.hasPrefix("<?php") || head.contains("<?php") { return "PHP" }
        if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") || has(#"^\s*<(div|head|body|p|span|ul|section|table|form|script|style)[\s>]"#) {
            return "HTML / XML"
        }
        if t.hasPrefix("<?xml") { return "HTML / XML" }
        if (t.hasPrefix("{") || t.hasPrefix("[")), (try? JSONSerialization.jsonObject(with: Data(t.utf8))) != nil { return "JSON" }
        if has(#"^package\s+main\b"#) || has(#"^func\s+\w+\(.*\)\s*\{"#) && has(#":="#) { return "Go" }
        if has(#"^\s*fn\s+\w+"#) && (has(#"\blet\s+mut\b"#) || has(#"->"#) || has(#"println!"#)) { return "Rust" }
        if has(#"^\s*import\s+(SwiftUI|UIKit|AppKit|Foundation)\b"#) || (has(#"^\s*func\s+\w+"#) && has(#"\b(let|var)\s+\w+"#)) { return "Swift" }
        if has(#"^\s*#include\s*[<"]"#) || has(#"\bint\s+main\s*\("#) { return "C / C++ / Objective-C" }
        if has(#"^\s*(public\s+)?(class|interface)\s+\w+"#) && has(#"\b(public|private)\s+(static\s+)?\w+\s+\w+\s*\("#) { return "Java / Kotlin" }
        if has(#"^\s*def\s+\w+\s*\(.*\)\s*:"#) || has(#"^\s*(from\s+\S+\s+)?import\s+\w+"#) && !has(#"[;{}]\s*$"#) || has(#"^\s*class\s+\w+(\(.*\))?\s*:"#) {
            return "Python"
        }
        if has(#"^\s*def\s+\w+"#) && has(#"^\s*end\s*$"#) { return "Ruby" }
        if has(#"\b(function\s+\w*\s*\(|const\s+\w+\s*=|let\s+\w+\s*=|=>|console\.log|document\.|addEventListener)"#) { return "JavaScript / TypeScript" }
        if has(#"(?i)^\s*(select\s+.+\s+from|insert\s+into|create\s+table|delete\s+from)\b"#) {
            return "SQL"
        }
        if has(#"^[\w\.\#\-\[\]=:\s,>*]+\{\s*$"#) && has(#"^\s*[\w-]+\s*:\s*[^;]+;\s*$"#) { return "CSS" }
        if has(#"^(echo|cd|export|if \[|for \w+ in)\b"#) { return "シェル" }
        if has(#"^#{1,6}\s+\S"#) || has(#"^\s*[-*]\s+\S"#) && has(#"\[.+\]\(.+\)"#) { return "Markdown" }
        if has(#"^[\w-]+:\s*\S"#) && has(#"^\s+-\s+\S"#) && !has(#"[;{}]"#) { return "YAML" }
        return nil
    }
}
