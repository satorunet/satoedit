import XCTest
@testable import HinokiCore

final class GenkoTests: XCTestCase {
    func testColumnXHasCentreGap() {
        // 右端の列は枠の右端にぴったり、10 列目と 11 列目の間に中央の余白が入る
        XCTAssertEqual(Genko.columnX(0) + Genko.Sheet.pitch, Genko.Sheet.left + Genko.Sheet.gridWidth, accuracy: 1e-9)
        XCTAssertEqual(Genko.columnX(9) - Genko.columnX(10), Genko.Sheet.pitch + Genko.Sheet.center, accuracy: 1e-9)
        XCTAssertEqual(Genko.columnX(19), Genko.Sheet.left, accuracy: 1e-9)
        // 用紙の左右の余白は同じ
        XCTAssertEqual(Genko.Sheet.left * 2 + Genko.Sheet.gridWidth, Genko.Sheet.width, accuracy: 1e-9)
    }

    func testAutoFormatIndents() {
        let cols = Genko.layout("題名\n山田太郎\n\n本文です。\n「かぎ」", autoFormat: true)
        XCTAssertEqual(cols.count, 5)
        // 題名は 3 マス下げ
        XCTAssertEqual(cols[0].first, 3)
        XCTAssertEqual(cols[0].cells[3], "題")
        // 名前は下寄せで下を 1 マス空ける (4 文字 → 15〜18 マス目)
        XCTAssertEqual(cols[1].first, 15)
        XCTAssertEqual(cols[1].cells[18], "郎")
        XCTAssertNil(cols[1].cells[19])
        // 本文は 1 マス下げ、かぎかっこは下げない
        XCTAssertEqual(cols[3].first, 1)
        XCTAssertEqual(cols[4].first, 0)
        // 自動整形なしならどれも下げない
        XCTAssertTrue(Genko.layout("題名\n山田", autoFormat: false).allSatisfy { $0.first == 0 })
    }

    func testEmptyParagraphStart() {
        XCTAssertEqual(Genko.indentFor(index: 0, text: "", autoFormat: true), 3)
        XCTAssertEqual(Genko.indentFor(index: 1, text: "", autoFormat: true), 0)
        XCTAssertEqual(Genko.indentFor(index: 2, text: "", autoFormat: true), 1)
        XCTAssertEqual(Genko.indentFor(index: 2, text: "", autoFormat: false), 0)
    }

    func testWrapAndOffsets() {
        // 3 段落目: 1 マス下げて 19 字で 1 列、残りは次の列の頭から
        let body = String(repeating: "あ", count: 25)
        let cols = Genko.layout("a\nb\n" + body, autoFormat: true)
        XCTAssertEqual(cols.count, 4)
        XCTAssertEqual(cols[2].from, 4)
        XCTAssertEqual(cols[2].to, 4 + 19)
        XCTAssertFalse(cols[2].last)
        XCTAssertEqual(cols[3].first, 0)
        XCTAssertEqual(cols[3].to, 4 + 25)
        XCTAssertTrue(cols[3].last)
        // 折り返した位置のカーソルは次の列の頭
        let c = Genko.caretCell(cols, offset: 4 + 19)
        XCTAssertEqual(c.column, 3)
        XCTAssertEqual(c.row, 0)
        // 文章の終わりは最後の文字の次のマス
        let e = Genko.caretCell(cols, offset: 4 + 25)
        XCTAssertEqual(e.column, 3)
        XCTAssertEqual(e.row, 6)
    }

    func testCaretAndOffsetRoundTrip() {
        let text = "題名\n名前\n\nこんにちは。\n終わり"
        let cols = Genko.layout(text, autoFormat: true)
        for off in 0...(text as NSString).length {
            let c = Genko.caretCell(cols, offset: off)
            XCTAssertEqual(Genko.offsetAt(cols, column: c.column, row: c.row), off, "offset \(off)")
        }
        // 空の列 (3 段落目) のカーソルは 1 マス下げた位置
        let empty = Genko.caretCell(cols, offset: 6)
        XCTAssertEqual(empty.column, 2)
        XCTAssertEqual(empty.row, 1)
    }

    func testSurrogatePairTakesOneCell() {
        let cols = Genko.layout("😀あ", autoFormat: false)
        XCTAssertEqual(cols[0].cells[0], "😀")
        XCTAssertEqual(cols[0].offs[1], 2)
        XCTAssertEqual(cols[0].to, 3)
        XCTAssertEqual(Genko.caretCell(cols, offset: 1).row, 0)
        XCTAssertEqual(Genko.characterCount("😀あ\nい"), 3)
    }

    func testSheetCount() {
        XCTAssertEqual(Genko.sheetCount(Genko.layout("", autoFormat: true)), 1)
        let twenty = Array(repeating: "あ", count: 20).joined(separator: "\n")
        XCTAssertEqual(Genko.sheetCount(Genko.layout(twenty, autoFormat: false)), 1)
        XCTAssertEqual(Genko.sheetCount(Genko.layout(twenty + "\nい", autoFormat: false)), 2)
    }

    func testFullWidth() {
        XCTAssertEqual(Genko.toFullWidth("A1 b!"), "Ａ１\u{3000}ｂ！")
        XCTAssertEqual(Genko.toFullWidth("漢字"), "漢字")
    }

    func testPlaceRuby() {
        let cols = Genko.layout("漢字を書く", autoFormat: false)
        let placed = Genko.placeRuby(cols, [Genko.Ruby(from: 0, to: 2, reading: "かんじ"), Genko.Ruby(from: 3, to: 4, reading: "か")])
        XCTAssertEqual(placed[0], [Genko.RubyPlacement(row: 0, rows: 2, text: "かんじ"), Genko.RubyPlacement(row: 3, rows: 1, text: "か")])
    }

    func testPlaceRubyAcrossColumns() {
        // 19 マス目と次の列の頭にまたがる 2 文字の言葉は、読みを半分ずつに分ける
        let text = String(repeating: "あ", count: 19) + "漢字"
        let cols = Genko.layout(text, autoFormat: false)
        let placed = Genko.placeRuby(cols, [Genko.Ruby(from: 19, to: 21, reading: "かんじ")])
        XCTAssertEqual(placed[0], [Genko.RubyPlacement(row: 19, rows: 1, text: "かん")])
        XCTAssertEqual(placed[1], [Genko.RubyPlacement(row: 0, rows: 1, text: "じ")])
    }
}
