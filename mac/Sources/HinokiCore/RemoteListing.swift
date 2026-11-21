import Foundation

/// サーバ上のファイル・フォルダ 1 つ
public struct RemoteEntry: Equatable {
    public let name: String
    public let isDirectory: Bool
    public let isLink: Bool
    public let size: Int64
    /// 一覧に出ていた日時の文字列そのまま (秒が分からないときの表示に使う)
    public let date: String
    /// 更新日時 (分かるとき)
    public let modified: Date?
    /// modified に秒まで入っているか
    public let hasSeconds: Bool

    public init(name: String, isDirectory: Bool, isLink: Bool, size: Int64, date: String,
                modified: Date? = nil, hasSeconds: Bool = false) {
        self.name = name
        self.isDirectory = isDirectory
        self.isLink = isLink
        self.size = size
        self.date = date
        self.modified = modified
        self.hasSeconds = hasSeconds
    }

    /// 「2028/2/2 22:22:22」の形 (秒が分からなければ「2028/2/2 22:22」、時刻も分からなければ「2028/2/2」)
    public func displayDate(timeZone: TimeZone = .current) -> String {
        guard let d = modified else { return date }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        if hasSeconds {
            f.dateFormat = "yyyy/M/d HH:mm:ss"
        } else if date.contains(":") {
            f.dateFormat = "yyyy/M/d HH:mm"
        } else {
            f.dateFormat = "yyyy/M/d"
        }
        return f.string(from: d)
    }
}

/// サーバの一覧 (ls -l・GNU ls の秒つき・BSD ls -T・FTP の MLSD) を読む
public enum RemoteListing {
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// 一覧を読む。フォルダが先、名前順
    public static func parse(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) -> [RemoteEntry] {
        var result: [RemoteEntry] = []
        for raw in text.split(separator: "\n") {
            let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if let e = parseMLSD(line) ?? parseLS(line, now: now, timeZone: timeZone) {
                if e.name == "." || e.name == ".." || e.name.isEmpty { continue }
                result.append(e)
            }
        }
        return result.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// FTP の MLSD: 「type=file;size=123;modify=20280202132222; index.html」(時刻は UTC)
    static func parseMLSD(_ line: String) -> RemoteEntry? {
        guard let sp = line.range(of: "; ") ?? line.range(of: " "), line[..<sp.lowerBound].contains("=") else { return nil }
        var facts: [String: String] = [:]
        for f in line[..<sp.lowerBound].split(separator: ";") {
            let kv = f.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { facts[kv[0].lowercased()] = String(kv[1]) }
        }
        guard let type = facts["type"]?.lowercased() else { return nil }
        if type == "cdir" || type == "pdir" { return nil }
        let name = String(line[sp.upperBound...])
        var modified: Date?
        if let m = facts["modify"], m.count >= 14 {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMddHHmmss"
            modified = f.date(from: String(m.prefix(14)))
        }
        return RemoteEntry(name: name, isDirectory: type == "dir", isLink: type.contains("slink"),
                           size: Int64(facts["size"] ?? "") ?? 0, date: facts["modify"] ?? "",
                           modified: modified, hasSeconds: modified != nil)
    }

    /// ls -l の 1 行。日時の部分は 3 通り:
    ///   ふつう      「Nov 19 10:32」「Nov 19 2025」
    ///   GNU 秒つき  「1771234567」 (--time-style=+%s)
    ///   BSD -T     「Nov 19 10:32:15 2026」
    static func parseLS(_ line: String, now: Date, timeZone: TimeZone) -> RemoteEntry? {
        guard let first = line.first, "-dlcbps".contains(first) else { return nil }
        // 権限 リンク数 所有者 グループ サイズ まで
        var fields: [String] = []
        var rest = Substring(line)
        func next() -> String? {
            rest = rest.drop(while: { $0 == " " })
            guard let end = rest.firstIndex(of: " ") else { return nil }
            let f = String(rest[..<end])
            rest = rest[end...]
            return f
        }
        for _ in 0..<5 { guard let f = next() else { return nil }; fields.append(f) }
        guard let size = Int64(fields[4]) else { return nil }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var modified: Date?
        var hasSeconds = false
        var dateText = ""
        guard let a = next() else { return nil }
        if a.count >= 9, let epoch = TimeInterval(a), !a.contains(".") {
            // GNU 秒つき
            modified = Date(timeIntervalSince1970: epoch)
            hasSeconds = true
            dateText = a
        } else {
            guard let mi = months.firstIndex(of: a.lowercased()), let dayText = next(), let day = Int(dayText),
                  let third = next() else { return nil }
            var comps = DateComponents()
            comps.month = mi + 1
            comps.day = day
            dateText = "\(a) \(dayText) \(third)"
            let hms = third.split(separator: ":").compactMap { Int($0) }
            if hms.count == 3 {
                // BSD -T: 次が年
                let save = rest
                if let y = next(), let year = Int(y) {
                    comps.year = year
                    comps.hour = hms[0]; comps.minute = hms[1]; comps.second = hms[2]
                    hasSeconds = true
                    dateText += " \(y)"
                } else {
                    rest = save
                }
            } else if hms.count == 2 {
                // 年なし: 今年。ただし未来になるなら去年 (ls は半年以内のものを時刻で出す)
                comps.hour = hms[0]; comps.minute = hms[1]
                comps.year = cal.component(.year, from: now)
                if let d = cal.date(from: comps), d.timeIntervalSince(now) > 86_400 * 2 {
                    comps.year = comps.year! - 1
                }
            } else if let year = Int(third) {
                comps.year = year
            }
            modified = cal.date(from: comps)
        }
        var name = String(rest.drop(while: { $0 == " " }))
        let isLink = first == "l"
        if isLink, let r = name.range(of: " -> ") { name = String(name[..<r.lowerBound]) }
        return RemoteEntry(name: name, isDirectory: first == "d", isLink: isLink, size: size,
                           date: dateText, modified: modified, hasSeconds: hasSeconds)
    }
}
