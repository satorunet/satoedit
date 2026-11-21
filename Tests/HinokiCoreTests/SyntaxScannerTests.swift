import XCTest
@testable import HinokiCore

final class SyntaxScannerTests: XCTestCase {
    func kinds(_ text: String, _ profileName: String) -> [String] {
        let store = ProfileStore(userFile: nil)
        let scanner = SyntaxScanner(profile: store.profile(named: profileName)!)
        let ns = text as NSString
        return scanner.tokens(in: ns).map { "\($0.kind.rawValue):\(ns.substring(with: $0.range))" }
    }

    func testSwift() {
        XCTAssertEqual(kinds("let x: Int = 42 // 答え\nlet s = \"a // b\"", "Swift"), [
            "keyword:let", "type:Int", "number:42", "comment:// 答え",
            "keyword:let", "string:\"a // b\"",
        ])
    }

    func testBlockCommentAndEscapes() {
        XCTAssertEqual(kinds("/* \"x\" */ \"a\\\"b\" x1", "C / C++ / Objective-C"), [
            "comment:/* \"x\" */", "string:\"a\\\"b\"",
        ])
    }

    func testPythonTripleQuote() {
        XCTAssertEqual(kinds("def f():\n    \"\"\"doc\n# not comment\"\"\"\n    return None", "Python"), [
            "keyword:def", "string:\"\"\"doc\n# not comment\"\"\"", "keyword:return", "keyword:None",
        ])
    }

    func testCaseInsensitiveSQL() {
        XCTAssertEqual(kinds("SELECT * FROM t -- c", "SQL"), ["keyword:SELECT", "keyword:FROM", "comment:-- c"])
    }

    func testMarkup() {
        XCTAssertEqual(kinds("<a href=\"x\">hi</a><!-- c -->", "HTML / XML"), [
            "tag:<a", "string:\"x\"", "tag:</a", "comment:<!-- c -->",
        ])
    }

    func testUnterminatedStringStopsAtLineEnd() {
        XCTAssertEqual(kinds("\"abc\nlet", "Swift"), ["string:\"abc", "keyword:let"])
    }

    func testProfileLookup() {
        let store = ProfileStore(userFile: nil)
        XCTAssertEqual(store.profile(forFileName: "main.SWIFT")?.name, "Swift")
        XCTAssertEqual(store.profile(forFileName: "Makefile")?.name, "Makefile")
        XCTAssertEqual(store.profile(forFileName: ".zshrc")?.name, "シェル")
        XCTAssertNil(store.profile(forFileName: "memo.txt"))
    }

    func testUserOverride() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("profiles.json")
        try #"[{"name":"Swift","extensions":["swift"],"tabWidth":2},{"name":"Lua","extensions":["lua"],"lineComments":["--"]}]"#
            .write(to: url, atomically: true, encoding: .utf8)
        let store = ProfileStore(userFile: url)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.profile(named: "Swift")?.tabWidth, 2)
        XCTAssertEqual(store.profile(forFileName: "a.lua")?.lineComments, ["--"])
    }

    func testBuiltInJSONRoundTrips() throws {
        let decoded = try JSONDecoder().decode([LanguageProfile].self, from: ProfileStore.builtInJSON())
        XCTAssertEqual(decoded, BuiltInProfiles.all)
    }
}
