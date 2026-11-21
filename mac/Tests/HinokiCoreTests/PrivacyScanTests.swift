import XCTest
@testable import HinokiCore

final class PrivacyScanTests: XCTestCase {
    private func kinds(_ text: String, names: [String] = []) -> Set<String> {
        Set(PrivacyScan.scan(text, names: names).map(\.kind))
    }

    func testFindsPersonalInfo() {
        XCTAssertTrue(kinds("連絡先 090-1234-5678 まで").contains("電話番号"))
        XCTAssertTrue(kinds("TEL 03(1234)5678").contains("電話番号"))
        XCTAssertTrue(kinds("mail: taro@example.com").contains("メールアドレス"))
        XCTAssertTrue(kinds("〒150-0001 東京都渋谷区神宮前1-2-3").isSuperset(of: ["郵便番号", "住所"]))
        XCTAssertTrue(kinds("パスワード: hunter22").contains("パスワード"))
        XCTAssertTrue(kinds("password=abc12345").contains("パスワード"))
        XCTAssertTrue(kinds("4111 1111 1111 1111").contains("カード番号"))
        XCTAssertTrue(kinds("氏名：山田太郎").contains("名前"))
        XCTAssertTrue(kinds("春の遠足\n山田花子\n").contains("名前"))
        XCTAssertTrue(kinds("きょうは矢野さんと会った", names: ["矢野悟"]).contains("名前"))
        XCTAssertTrue(kinds("矢野悟 より", names: ["矢野悟"]).contains("名前"))
    }

    func testIgnoresOrdinaryText() {
        XCTAssertTrue(kinds("先週の金曜日、学校の遠足で動物園に行きました。天気はとても良くて、朝から楽しみでした。").isEmpty)
        XCTAssertTrue(kinds("2026年11月21日 10:00〜11:00 の会議").isEmpty)
        XCTAssertTrue(kinds("1 + 2 = 3、林檎を 3 個").isEmpty)
    }

    func testPhoneIsNotPostalCode() {
        XCTAssertEqual(kinds("電話は 090-1234-5678"), ["電話番号"])
    }

    func testMasksMiddle() {
        let f = PrivacyScan.scan("090-1234-5678").first
        XCTAssertEqual(f?.kind, "電話番号")
        XCTAssertNotEqual(f?.sample, "090-1234-5678")
        XCTAssertTrue(f?.sample.hasPrefix("09") == true)
    }
}
