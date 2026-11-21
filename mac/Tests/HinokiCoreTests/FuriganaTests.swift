import XCTest
@testable import HinokiCore

final class FuriganaTests: XCTestCase {
    private func R(_ from: Int, _ to: Int, _ reading: String) -> Genko.Ruby { Genko.Ruby(from: from, to: to, reading: reading) }

    func testToHiragana() {
        XCTAssertEqual(Furigana.toHiragana("カンジとヨミ"), "かんじとよみ")
    }

    func testSplitWordStripsOkurigana() {
        // 送りがなには付けない
        XCTAssertEqual(Furigana.splitWord(surface: "食べる", reading: "タベル"), [R(0, 1, "た")])
        XCTAssertEqual(Furigana.splitWord(surface: "考える", reading: "かんがえる"), [R(0, 1, "かんが")])
        // 漢字だけの言葉はまとめて
        XCTAssertEqual(Furigana.splitWord(surface: "東京", reading: "とうきょう"), [R(0, 2, "とうきょう")])
    }

    func testSplitWordWithKanaInside() {
        // かなをはさんだ漢字は、それぞれに読みを分ける
        XCTAssertEqual(Furigana.splitWord(surface: "食べ物", reading: "たべもの"), [R(0, 1, "た"), R(2, 3, "もの")])
        XCTAssertEqual(Furigana.splitWord(surface: "お茶", reading: "おちゃ"), [R(1, 2, "ちゃ")])
        XCTAssertEqual(Furigana.splitWord(surface: "買い物", reading: "かいもの"), [R(0, 1, "か"), R(2, 3, "もの")])
    }

    func testSplitWordFallsBackToWholeWord() {
        // かなが読みと合わないときは、言葉全体に読みを付ける
        XCTAssertEqual(Furigana.splitWord(surface: "一ヶ月", reading: "いっかげつ"), [R(0, 3, "いっかげつ")])
        XCTAssertEqual(Furigana.splitWord(surface: "今日は", reading: "きょうわ"), [R(0, 3, "きょうわ")])
    }

    func testSplitReadingPerKanji() {
        func S(_ r: String, _ known: [String?]) -> [String]? { Furigana.splitReading(r, count: known.count, known: known) }
        XCTAssertEqual(S("せんしゅう", ["さき", "しゅう"]), ["せん", "しゅう"])
        XCTAssertEqual(S("たろう", ["ふとし", "ろう"]), ["た", "ろう"])
        XCTAssertEqual(S("きりん", [nil, "りん"]), ["き", "りん"])
        XCTAssertEqual(S("やまだ", ["やま", "た"]), ["やま", "だ"])   // 連濁
        XCTAssertEqual(S("どうぶつえん", ["どう", "もの", "その"]), ["どう", "ぶつ", "えん"])
        XCTAssertEqual(S("がっこう", ["がく", "こう"]), ["がっ", "こう"]) // 促音
        XCTAssertEqual(S("えんそく", ["とお", "あし"]), ["えん", "そく"])
        XCTAssertNil(S("あ", [nil, nil]))
    }

    func testPerKanjiKeepsJukujikunWhole() {
        let part = R(0, 2, "きょう")
        XCTAssertEqual(Furigana.perKanji(part, surface: "今日"), [part])
    }

    func testSplitWordWithoutKanji() {
        XCTAssertEqual(Furigana.splitWord(surface: "メロス", reading: "めろす"), [])
    }

    func testRubyUsesSystemDictionary() {
        // 2 行目の位置は、1 行目の長さ + 改行ぶん進む
        let text = "学校\nお茶を飲む。"
        let ruby = Furigana.ruby(for: text)
        XCTAssertTrue(ruby.contains(R(0, 1, "がっ")) && ruby.contains(R(1, 2, "こう")), "\(ruby)")
        XCTAssertTrue(ruby.contains(R(4, 5, "ちゃ")), "\(ruby)")
        XCTAssertTrue(ruby.contains(R(6, 7, "の")), "\(ruby)")
        // かなと記号には付かない
        XCTAssertFalse(ruby.contains { $0.from == 3 || $0.from == 5 || $0.from == 8 })
        XCTAssertEqual(Furigana.ruby(for: "ひらがな だけ abc"), [])
    }
}
