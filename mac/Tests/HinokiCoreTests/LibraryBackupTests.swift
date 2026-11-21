import XCTest
@testable import HinokiCore

final class LibraryBackupTests: XCTestCase {
    func testRoundTripWithPassword() throws {
        let a = LibraryBackup.Archive(
            entries: [.init(path: "folder/作文/春の遠足.txt", data: Data("春の遠足\n".utf8), mode: "genko", pinned: true, locked: false,
                            created: Date(timeIntervalSince1970: 1_700_000_000), modified: Date(timeIntervalSince1970: 1_700_000_100)),
                      .init(path: "other/メモ.txt", data: Data("メモ".utf8))],
            folders: ["作文", "空のフォルダ"], folderIcons: ["作文": "pencil|red"], folderOrder: ["作文"], sharedLinks: Data("[]".utf8))
        let sealed = try LibraryBackup.seal(a, password: "correct horse")
        XCTAssertTrue(FileCrypto.isEncrypted(sealed))
        XCTAssertNil(String(data: sealed, encoding: .utf8).flatMap { $0.contains("春の遠足") ? $0 : nil }, "中身が平文で見えてはいけない")
        let b = try LibraryBackup.open(sealed, password: "correct horse")
        XCTAssertEqual(b.entries, a.entries)
        XCTAssertEqual(b.folders, a.folders)
        XCTAssertEqual(b.folderIcons, a.folderIcons)
        XCTAssertEqual(b.sharedLinks, a.sharedLinks)
        XCTAssertThrowsError(try LibraryBackup.open(sealed, password: "wrong"))
    }

    func testRejectsOtherFiles() {
        XCTAssertThrowsError(try LibraryBackup.open(Data("hello".utf8), password: "x"))
    }

    func testSafeRelative() {
        XCTAssertEqual(LibraryBackup.safeRelative("folder/a/b.txt", prefix: "folder"), "a/b.txt")
        XCTAssertNil(LibraryBackup.safeRelative("folder/../etc/passwd", prefix: "folder"))
        XCTAssertNil(LibraryBackup.safeRelative("folder//x", prefix: "folder"))
        XCTAssertNil(LibraryBackup.safeRelative("other/x.txt", prefix: "folder"))
        XCTAssertNil(LibraryBackup.safeRelative("folder/", prefix: "folder"))
    }
}
