import XCTest
@testable import HinokiCore

final class LocalLLMTests: XCTestCase {
    func testParseTags() {
        let json = #"{"models":[{"name":"gemma3:1b","size":815319791},{"model":"qwen2.5:3b","size":1929912432}]}"#
        let list = LocalLLM.parseTags(Data(json.utf8))
        XCTAssertEqual(list.map { $0.name }, ["gemma3:1b", "qwen2.5:3b"])
        XCTAssertEqual(list[0].size, 815319791)
        XCTAssertTrue(LocalLLM.parseTags(Data("oops".utf8)).isEmpty)
    }

    func testProgress() {
        let p = LocalLLM.parseProgress(#"{"status":"pulling abc","total":1000,"completed":250}"#)
        XCTAssertEqual(p?.fraction, 0.25)
        XCTAssertEqual(p?.done, false)
        XCTAssertEqual(LocalLLM.parseProgress(#"{"status":"success"}"#)?.done, true)
        XCTAssertEqual(LocalLLM.parseProgress(#"{"error":"pull model manifest: file does not exist"}"#)?.error, "pull model manifest: file does not exist")
        XCTAssertNil(LocalLLM.parseProgress(#"{"status":"pulling manifest"}"#)?.fraction)
        XCTAssertNil(LocalLLM.parseProgress("not json"))
    }

    func testNames() {
        XCTAssertTrue(LocalLLM.sameModel("gemma3", "gemma3:latest"))
        XCTAssertTrue(LocalLLM.sameModel("Gemma3:1b", "gemma3:1b"))
        XCTAssertFalse(LocalLLM.sameModel("gemma3:1b", "gemma3:4b"))
        XCTAssertTrue(LocalLLM.isValidModelName("qwen2.5-coder:1.5b"))
        XCTAssertTrue(LocalLLM.isValidModelName("hf.co/user/model:Q4_K_M"))
        XCTAssertFalse(LocalLLM.isValidModelName("a b"))
        XCTAssertFalse(LocalLLM.isValidModelName("x; rm -rf /"))
        XCTAssertFalse(LocalLLM.isValidModelName(""))
        for r in LocalLLM.recommended { XCTAssertTrue(LocalLLM.isValidModelName(r.name)) }
    }

    func testRequirement() {
        XCTAssertEqual(LocalLLM.parseRequiredMacOS("## System Requirements\n\n* MacOS Sonoma (v14) or newer\n* Apple M series"), 14)
        XCTAssertEqual(LocalLLM.parseRequiredMacOS("- macOS Sequoia (v15) or later"), 15)
        XCTAssertNil(LocalLLM.parseRequiredMacOS("nothing here"))
        XCTAssertEqual(LocalLLM.compatibility(osMajor: 14, required: 14), .current)
        XCTAssertEqual(LocalLLM.compatibility(osMajor: 12, required: 14), .legacy)
        XCTAssertEqual(LocalLLM.compatibility(osMajor: 10, required: 14), .unsupported)
    }

    func testSizeText() {
        XCTAssertEqual(LocalLLM.sizeText(815319791), "0.8 GB")
        XCTAssertEqual(LocalLLM.sizeText(50_000_000), "50 MB")
    }
}
