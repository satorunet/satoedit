import XCTest
@testable import HinokiCore

final class AIModelsTests: XCTestCase {
    func testPresetsHavePrices() {
        // かんたん選択に出すモデルは、必ず料金が分かる
        for (provider, set) in AIModels.presets {
            XCTAssertNotNil(AIModels.price(of: set.fast), "\(provider) fast")
            XCTAssertNotNil(AIModels.price(of: set.quality), "\(provider) quality")
        }
        XCTAssertEqual(AIModels.price(of: "claude-haiku-5-5"), AIModels.Price(input: 0.10, output: 0.50))
        XCTAssertEqual(AIModels.price(of: "claude-opus-5-5"), AIModels.Price(input: 4, output: 20))
        XCTAssertEqual(AIModels.price(of: "gpt-6-luna"), AIModels.Price(input: 0.10, output: 0.50))
        XCTAssertNil(AIModels.price(of: "no-such-model"))
    }

    func testDatedPriceChange() {
        // 2026-12-01 から値上げ
        XCTAssertEqual(AIModels.price(of: "gemini-4-carbon", today: "2026-11-30"), AIModels.Price(input: 2, output: 10))
        XCTAssertEqual(AIModels.price(of: "gemini-4-carbon", today: "2026-12-01"), AIModels.Price(input: 4, output: 20))
        XCTAssertEqual(AIModels.upcomingChange("gemini-4-carbon", today: "2026-11-18")?.from, "2026-12-01")
        XCTAssertNil(AIModels.upcomingChange("gemini-4-carbon", today: "2026-12-01"))
        XCTAssertNil(AIModels.upcomingChange("claude-opus-5-5", today: "2026-11-18"))
        // Gemini の一覧は "models/" 付きで返ることがある
        XCTAssertEqual(AIModels.price(of: "models/gemini-3.1-flash-lite"), AIModels.Price(input: 0.25, output: 1.50))
    }

    func testOverridesWin() {
        let overrides = AIModels.parseOverrides(Data(#"{"gpt-6-luna": [1, 2], "my-model": [0.5, 0], "bad": [1], "worse": "x", "neg": [-1, 2]}"#.utf8))
        XCTAssertEqual(overrides.keys.sorted(), ["gpt-6-luna", "my-model"])
        XCTAssertEqual(AIModels.price(of: "gpt-6-luna", overrides: overrides), AIModels.Price(input: 1, output: 2))
        XCTAssertEqual(AIModels.price(of: "my-model", overrides: overrides), AIModels.Price(input: 0.5, output: 0))
        XCTAssertEqual(AIModels.parseOverrides(Data("not json".utf8)), [:])
    }

    func testSampleCost() {
        // 入力 1,500 + 出力 1,500 トークン
        XCTAssertEqual(AIModels.sampleCost(AIModels.Price(input: 4, output: 20)), 0.036, accuracy: 1e-12)
    }

    func testDayIsUTC() {
        XCTAssertEqual(AIModels.day(Date(timeIntervalSince1970: 0)), "1970-01-01")
    }

    func testLocateKeepsOriginalRange() {
        let r = AIApply.locate(in: "あいうえお", from: 1, to: 3, original: "いう")
        XCTAssertEqual(r, NSRange(location: 1, length: 2))
        // 何も選んでいなかった (文書全体が対象) とき
        XCTAssertEqual(AIApply.locate(in: "全部", from: 0, to: 2, original: "全部"), NSRange(location: 0, length: 2))
    }

    func testLocateFindsMovedTarget() {
        // 待っているあいだに前へ文字が足されても、もとの文章を探し直す
        XCTAssertEqual(AIApply.locate(in: "前置き。あいうえお", from: 1, to: 3, original: "いう"), NSRange(location: 5, length: 2))
    }

    func testLocateFailsWhenAmbiguousOrGone() {
        // 同じ文章が 2 か所にあると決められない
        XCTAssertNil(AIApply.locate(in: "いう と いう", from: 5, to: 9, original: "いう。"))
        XCTAssertNil(AIApply.locate(in: "xいうyいうz", from: 0, to: 2, original: "いう"))
        // もとの文章が消えた
        XCTAssertNil(AIApply.locate(in: "かきくけこ", from: 1, to: 3, original: "いう"))
        // 空の文書を対象にしたあとで書き足された
        XCTAssertNil(AIApply.locate(in: "あ", from: 0, to: 0, original: "x"))
        XCTAssertEqual(AIApply.locate(in: "あ", from: 0, to: 0, original: ""), NSRange(location: 0, length: 0))
    }

    func testInsertionAddsLineBreakWhenNeeded() {
        XCTAssertEqual(AIApply.insertion(after: 3, in: "あいう", text: "続き"), "\n続き")
        XCTAssertEqual(AIApply.insertion(after: 4, in: "あいう\n", text: "続き"), "続き")
        XCTAssertEqual(AIApply.insertion(after: 0, in: "", text: "続き"), "続き")
    }
}
