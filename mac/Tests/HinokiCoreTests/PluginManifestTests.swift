import XCTest
@testable import HinokiCore

final class PluginManifestTests: XCTestCase {
    func testParse() throws {
        let m = try PluginManifest.parse(Data(#"{"id":"date-stamp","name":"日付","version":"1.2.0","permissions":["network"],"icon":"📅"}"#.utf8))
        XCTAssertEqual(m.name, "日付")
        XCTAssertEqual(m.main, "main.js")
        XCTAssertTrue(m.has(.network))
        XCTAssertFalse(m.has(.clipboard))
        XCTAssertEqual(m.icon, "📅")
    }

    func testRejects() {
        XCTAssertThrowsError(try PluginManifest.parse(Data(#"{"name":"x"}"#.utf8)))
        XCTAssertThrowsError(try PluginManifest.parse(Data(#"{"id":"../evil"}"#.utf8)))
        XCTAssertThrowsError(try PluginManifest.parse(Data(#"{"id":"Upper"}"#.utf8)))
        XCTAssertThrowsError(try PluginManifest.parse(Data(#"{"id":"ok","permissions":["files"]}"#.utf8)))
        XCTAssertThrowsError(try PluginManifest.parse(Data(#"{"id":"ok","main":"../../x.js"}"#.utf8)))
        XCTAssertThrowsError(try PluginManifest.parse(Data(#"{"id":"ok","main":"/etc/x.js"}"#.utf8)))
        XCTAssertThrowsError(try PluginManifest.parse(Data("not json".utf8)))
    }

    func testVersion() {
        XCTAssertEqual(PluginVersion.compare("1.2.10", "1.2.9"), 1)
        XCTAssertEqual(PluginVersion.compare("1.0", "1.0.0"), 0)
        XCTAssertEqual(PluginVersion.compare("0.9.1", "1.0.0"), -1)
    }

    func testSourceURL() {
        XCTAssertEqual(PluginSource.downloadURL(for: "https://github.com/u/r")?.absoluteString, "https://github.com/u/r/archive/HEAD.zip")
        XCTAssertEqual(PluginSource.downloadURL(for: "github.com/u/r.git")?.absoluteString, "https://github.com/u/r/archive/HEAD.zip")
        XCTAssertEqual(PluginSource.downloadURL(for: "https://github.com/u/r/tree/dev")?.absoluteString,
                       "https://github.com/u/r/archive/refs/heads/dev.zip")
        XCTAssertEqual(PluginSource.downloadURL(for: "https://example.com/p.zip")?.absoluteString, "https://example.com/p.zip")
        XCTAssertNil(PluginSource.downloadURL(for: "file:///etc/passwd"))
        XCTAssertNil(PluginSource.downloadURL(for: "hello"))
    }

    func testShortcut() {
        XCTAssertEqual(PluginShortcut.parse("cmd+shift+D"), PluginShortcut(key: "d", command: true, shift: true))
        XCTAssertNil(PluginShortcut.parse("d"))
        XCTAssertNil(PluginShortcut.parse("cmd+hyper+d"))
        XCTAssertNil(PluginShortcut.parse(""))
    }
}
