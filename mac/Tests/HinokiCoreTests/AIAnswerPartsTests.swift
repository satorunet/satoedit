import XCTest
@testable import HinokiCore

final class AIAnswerPartsTests: XCTestCase {
    func testSplit() {
        let p = AIAnswerParts.split("誤字を 2 か所直しました。\n<result>\n  本文です。\n次の行\n</result>")
        XCTAssertEqual(p.message, "誤字を 2 か所直しました。")
        XCTAssertEqual(p.content, "  本文です。\n次の行")
        XCTAssertTrue(p.closed)
    }

    func testNoTags() {
        let p = AIAnswerParts.split("ただの答えです")
        XCTAssertEqual(p.message, "ただの答えです")
        XCTAssertNil(p.content)
    }

    func testStreaming() {
        XCTAssertEqual(AIAnswerParts.split("直しました。<res").message, "直しました。")
        let p = AIAnswerParts.split("直しました。<result>本文</re")
        XCTAssertEqual(p.content, "本文")
        XCTAssertFalse(p.closed)
    }

    func testFencedCode() {
        let p = AIAnswerParts.split("関数を書きました。\n```swift\nfunc a() {}\nlet b = 1\n```\n使ってみてください。")
        XCTAssertEqual(p.message, "関数を書きました。\n使ってみてください。")
        XCTAssertEqual(p.content, "func a() {}\nlet b = 1")
        XCTAssertTrue(p.closed)
        let s = AIAnswerParts.split("書きます\n```js\nconst x = 1;\n``")
        XCTAssertEqual(s.content, "const x = 1;\n")
        XCTAssertFalse(s.closed)
        // <result> があればそちらが先
        XCTAssertEqual(AIAnswerParts.split("x<result>```a```</result>").content, "```a```")
    }

    func testMessageAfter() {
        let p = AIAnswerParts.split("前<result>x</result>後のひとこと")
        XCTAssertEqual(p.message, "前\n後のひとこと")
        XCTAssertEqual(p.content, "x")
    }
}
