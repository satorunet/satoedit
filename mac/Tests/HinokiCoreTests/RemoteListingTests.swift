import XCTest
@testable import HinokiCore

final class RemoteListingTests: XCTestCase {
    let tz = TimeZone(identifier: "Asia/Tokyo")!
    var now: Date {
        var c = DateComponents(); c.year = 2028; c.month = 3; c.day = 1; c.hour = 12
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        return cal.date(from: c)!
    }

    func testClassicLS() {
        let text = """
        drwxr-xr-x    2 user group     4096 Feb  2 22:22 www
        -rw-r--r--    1 user group     1234 Feb  2 22:22 index.html
        -rw-r--r--    1 user group       10 Dec 31  2026 old file.txt
        lrwxrwxrwx    1 user group        7 Feb  1 09:05 link -> target
        drwxr-xr-x    2 user group     4096 Feb  2 22:22 .
        """
        let list = RemoteListing.parse(text, now: now, timeZone: tz)
        XCTAssertEqual(list.map(\.name), ["www", "index.html", "link", "old file.txt"])
        let index = list[1]
        XCTAssertEqual(index.size, 1234)
        XCTAssertEqual(index.displayDate(timeZone: tz), "2028/2/2 22:22")
        XCTAssertEqual(list[3].displayDate(timeZone: tz), "2026/12/31")
        XCTAssertTrue(list[2].isLink)
    }

    func testRecentDateInFutureMeansLastYear() {
        // 3 月 1 日に「Dec 25 10:00」なら去年の 12 月
        let list = RemoteListing.parse("-rw-r--r-- 1 u g 1 Dec 25 10:00 a.txt", now: now, timeZone: tz)
        XCTAssertEqual(list.first?.displayDate(timeZone: tz), "2027/12/25 10:00")
    }

    func testGNUEpochSeconds() {
        // 2028/2/2 22:22:22 (日本時間) = 1833110542
        let list = RemoteListing.parse("-rw-r--r-- 1 user group 55 1833110542 index.html", now: now, timeZone: tz)
        XCTAssertEqual(list.first?.name, "index.html")
        XCTAssertEqual(list.first?.size, 55)
        XCTAssertEqual(list.first?.displayDate(timeZone: tz), "2028/2/2 22:22:22")
    }

    func testBSDFullTime() {
        let list = RemoteListing.parse("-rw-r--r--  1 user  staff  55 Feb  2 22:22:22 2028 my file.html", now: now, timeZone: tz)
        XCTAssertEqual(list.first?.name, "my file.html")
        XCTAssertEqual(list.first?.displayDate(timeZone: tz), "2028/2/2 22:22:22")
    }

    func testMLSD() {
        let text = """
        type=cdir;modify=20280202132222; .
        type=dir;modify=20280202132222;perm=el; www
        type=file;size=1234;modify=20280202132222;perm=r; index.html
        """
        let list = RemoteListing.parse(text, now: now, timeZone: tz)
        XCTAssertEqual(list.map(\.name), ["www", "index.html"])
        XCTAssertTrue(list[0].isDirectory)
        XCTAssertEqual(list[1].size, 1234)
        // MLSD は UTC: 13:22:22 UTC = 22:22:22 日本時間
        XCTAssertEqual(list[1].displayDate(timeZone: tz), "2028/2/2 22:22:22")
    }
}
