import XCTest
@testable import HinokiCore

/// 表示する言葉の洗い出し。
/// プログラムの中の日本語の文字列を集めて、英語の対応表 (I18nEnglish.swift) にまだ無いものがあれば知らせる。
/// Windows 版の scripts/i18n-check.js と同じ考え方。
final class I18nTests: XCTestCase {
    /// 画面に出す言葉ではないもの (文字の集まり、設定ファイルの目印、見本の文章、両方の言葉で書いてある案内)
    private static let ignored: Set<String> = [
        "「『（(", "「『（(〈《【",
        "さとるエディタ サーバ", "さとるエディタ設定", "さと丸エディタ設定", "_形式", "_版", "隠したメニュー", "秀丸ダーク",
        "// テーマの見本", "\"こんにちは\"", "UTF-8  LF  挿入",
        "表示の言語は、次に起動したときから変わります。\nThe display language changes the next time you start the app.",
        "今すぐ起動し直す (Restart Now)", "あとで (Later)",
    ]

    /// theme.json の中に書く説明の行
    private static func isIgnored(_ s: String) -> Bool {
        ignored.contains(s) || s.hasPrefix("  \"_")
    }

    /// 言葉を組み立てる \( ) を使ってよい文字列 (画面には出ない、または訳さないもの)。ほかは L("…{0}…", x) の形にする
    private static let allowedInterpolation = ["preset \\(name) の色の数が違う", "の鍵ファイルです。なくすと"]

    private static func hasJapanese(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }

    private struct Literal {
        var value: String
        var raw: String
        var interpolated: Bool
        var file: String
        var line: Int
    }

    /// Swift のソースから文字列を取り出す (コメントは飛ばす。\( ) の中の入れ子の文字列も取り出す)
    private static func literals(in code: String, file: String) -> [Literal] {
        let c = Array(code.utf16)
        let n = c.count
        var out: [Literal] = []
        var line = 1
        var i = 0
        func ch(_ k: Int) -> UInt16 { k < n ? c[k] : 0 }
        let quote: UInt16 = 0x22, backslash: UInt16 = 0x5C, slash: UInt16 = 0x2F, star: UInt16 = 0x2A, newline: UInt16 = 0x0A

        /// i が開きの " のとき、文字列を読んで閉じの次の位置を返す
        func readString(_ start: Int) -> Int {
            var j = start + 1
            var value: [UInt16] = []
            var interpolated = false
            let startLine = line
            while j < n {
                let x = c[j]
                if x == backslash {
                    let e = ch(j + 1)
                    if e == 0x28 { // \(
                        interpolated = true
                        var depth = 1
                        j += 2
                        while j < n, depth > 0 {
                            if c[j] == quote { j = readString(j); continue }
                            if c[j] == 0x28 { depth += 1 } else if c[j] == 0x29 { depth -= 1 }
                            j += 1
                        }
                        continue
                    }
                    if e == 0x6E { value.append(newline) } // \n
                    else if e == 0x74 { value.append(0x09) } // \t
                    else if e == 0x75 { // \u{…}
                        var k = j + 3
                        var hex = ""
                        while k < n, c[k] != 0x7D { hex.append(Character(UnicodeScalar(c[k])!)); k += 1 }
                        if let v = UInt32(hex, radix: 16), let u = UnicodeScalar(v) { value.append(contentsOf: String(u).utf16) }
                        j = k + 1
                        continue
                    } else { value.append(e) }
                    j += 2
                    continue
                }
                if x == quote { j += 1; break }
                if x == newline { line += 1 }
                value.append(x)
                j += 1
            }
            out.append(Literal(value: String(utf16CodeUnits: value, count: value.count),
                               raw: String(utf16CodeUnits: Array(c[start..<min(j, n)]), count: min(j, n) - start),
                               interpolated: interpolated, file: file, line: startLine))
            return j
        }

        while i < n {
            let x = c[i]
            if x == newline { line += 1; i += 1; continue }
            if x == slash, ch(i + 1) == slash {
                while i < n, c[i] != newline { i += 1 }
                continue
            }
            if x == slash, ch(i + 1) == star {
                i += 2
                while i < n, !(c[i] == star && ch(i + 1) == slash) {
                    if c[i] == newline { line += 1 }
                    i += 1
                }
                i += 2
                continue
            }
            if x == quote, ch(i + 1) == quote, ch(i + 2) == quote {
                // 複数行の文字列: 画面に出す言葉には使わない決まり (日本語が入っていたら下で知らせる)
                var j = i + 3
                while j < n, !(c[j] == quote && ch(j + 1) == quote && ch(j + 2) == quote) {
                    if c[j] == newline { line += 1 }
                    j += 1
                }
                let body = String(utf16CodeUnits: Array(c[i..<min(j + 3, n)]), count: min(j + 3, n) - i)
                out.append(Literal(value: body, raw: body, interpolated: true, file: file, line: line))
                i = j + 3
                continue
            }
            if x == quote { i = readString(i); continue }
            i += 1
        }
        return out
    }

    private static func sourceLiterals() throws -> [Literal] {
        let root = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var out: [Literal] = []
        for dir in ["Sources/Hinoki", "Sources/HinokiCore"] {
            let folder = root.appendingPathComponent(dir)
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() where name.hasSuffix(".swift") {
                // PluginDocs.swift は拡張機能を作る人向けの説明とひな形 (日本語のまま)。Furigana.swift の日本語は読みを調べるための言葉の一覧、SelfTest.swift は開発用の確かめ。PrivacyScan.swift は探す決まり (正規表現・名字の一覧)。種類の名前は画面に出すとき L() で訳す
                if name == "I18nEnglish.swift" || name == "PluginDocs.swift" || name == "Furigana.swift" || name == "SelfTest.swift" || name == "PrivacyScan.swift" { continue }
                let code = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
                out += literals(in: code, file: name)
            }
        }
        return out
    }

    func testEveryJapaneseStringHasEnglish() throws {
        let all = try Self.sourceLiterals()
        XCTAssertGreaterThan(all.count, 1000, "ソースを読めていない")
        var missing: [String] = []
        var seen = Set<String>()
        for l in all where Self.hasJapanese(l.value) && !l.interpolated {
            if Self.isIgnored(l.value) || I18n.english[l.value] != nil || !seen.insert(l.value).inserted { continue }
            missing.append("\(l.file):\(l.line): \(l.raw)")
        }
        XCTAssertTrue(missing.isEmpty, "英語がまだ無い言葉 (I18nEnglish.swift に足す):\n" + missing.joined(separator: "\n"))
    }

    func testNoInterpolatedJapaneseStrings() throws {
        // "…\(x)…" の形のままだと対応表を引けないので、L("…{0}…", x) の形で書く
        var bad: [String] = []
        for l in try Self.sourceLiterals() where l.interpolated && Self.hasJapanese(l.raw) {
            if Self.allowedInterpolation.contains(where: { l.raw.contains($0) }) { continue }
            bad.append("\(l.file):\(l.line): \(l.raw.prefix(80))")
        }
        XCTAssertTrue(bad.isEmpty, "L(\"…{0}…\", x) の形に直す:\n" + bad.joined(separator: "\n"))
    }

    func testPlaceholdersMatch() {
        // {0} {1} … は、日本語と英語で同じものが出てくる
        func holes(_ s: String) -> [String] {
            var found = Set<String>()
            for i in 0..<10 where s.contains("{\(i)}") { found.insert("{\(i)}") }
            return found.sorted()
        }
        XCTAssertGreaterThan(I18n.english.count, 500)
        for (ja, en) in I18n.english {
            XCTAssertEqual(holes(ja), holes(en), ja)
            XCTAssertFalse(en.isEmpty, ja)
        }
    }

    func testResolve() {
        XCTAssertEqual(I18n.resolve(setting: "ja", systemLanguages: ["en-US"]), "ja")
        XCTAssertEqual(I18n.resolve(setting: "en", systemLanguages: ["ja-JP"]), "en")
        XCTAssertEqual(I18n.resolve(setting: "auto", systemLanguages: ["ja-JP", "en-US"]), "ja")
        XCTAssertEqual(I18n.resolve(setting: "auto", systemLanguages: ["fr-FR", "ja-JP"]), "en")
        XCTAssertEqual(I18n.resolve(setting: nil, systemLanguages: []), "en")
        XCTAssertEqual(I18n.resolve(setting: "xx", systemLanguages: ["ja"]), "ja")
    }

    func testTranslate() {
        defer { I18n.setLanguage("ja") }
        I18n.setLanguage("ja")
        XCTAssertEqual(L("{0} 行  {1} 列", 3, 5), "3 行  5 列")
        XCTAssertEqual(L("開く…"), "開く…")
        I18n.setLanguage("en")
        XCTAssertEqual(L("{0} 行  {1} 列", 3, 5), I18n.english["{0} 行  {1} 列"]!.replacingOccurrences(of: "{0}", with: "3").replacingOccurrences(of: "{1}", with: "5"))
        XCTAssertNotEqual(L("開く…"), "開く…")
        // 対応が無い言葉は日本語のまま出す
        XCTAssertEqual(L("対応表に無い言葉"), "対応表に無い言葉")
    }

    func testParse() {
        let t = I18n.parse("# 見出し\nあ\nA\n\nい\\nう\nI\\nU\n\n  前後の空白 \n  spaces \n")
        XCTAssertEqual(t["あ"], "A")
        XCTAssertEqual(t["い\nう"], "I\nU")
        XCTAssertEqual(t["  前後の空白 "], "  spaces ")
        XCTAssertEqual(t.count, 3)
    }
}
