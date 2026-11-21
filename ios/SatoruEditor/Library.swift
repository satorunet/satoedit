import Foundation
import HinokiCore

/// テキスト一覧の中身: アプリの「書類」フォルダ (ファイル App の「このiPhone内 > さとるエディタ」) に、ふつうの .txt で置く。
/// フォルダは 1 段だけ (Mac 版の一覧と同じ: いちばん上 = さとるエディタ、その中のフォルダ)。
enum Library {
    /// 表示: "genko" (原稿用紙・縦書き) / "genkoH" (原稿用紙・横書き) / nil (標準エディタ)
    struct Item {
        let url: URL
        let name: String
        let ext: String
        /// nil = いちばん上、名前 = その中のフォルダ
        let folder: String?
        let modified: Date
        let mode: String?
        let snippet: String
        var isGenko: Bool { mode == "genko" || mode == "genkoH" }
    }

    static let textExtensions: Set<String> = ["txt", "text", "md", "markdown", "csv", "tsv", "log", "json", "xml", "html", "htm",
                                              "css", "js", "ts", "swift", "py", "rb", "c", "h", "cpp", "java", "ini", "yml", "yaml"]
    static let blankBaseName = "新規テキスト"
    static let didChange = Notification.Name("LibraryDidChange")

    static var root: URL {
        if let o = ProcessInfo.processInfo.environment["SATORU_LIBRARY_DIR"] { return URL(fileURLWithPath: o, isDirectory: true) }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func changed() { NotificationCenter.default.post(name: didChange, object: nil) }

    // MARK: 一覧

    static func folders() -> [String] {
        let fm = FileManager.default
        let list = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return list.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && $0.lastPathComponent != "Inbox" }
            .map { $0.lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 全部のテキスト (新しく書き換えた順)
    static func items() -> [Item] {
        var out: [Item] = []
        func scan(_ dir: URL, folder: String?) {
            let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
            for u in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [] {
                let v = try? u.resourceValues(forKeys: Set(keys))
                if v?.isDirectory == true { continue }
                let ext = u.pathExtension.lowercased()
                guard textExtensions.contains(ext) || ext.isEmpty else { continue }
                out.append(Item(url: u, name: u.deletingPathExtension().lastPathComponent, ext: u.pathExtension, folder: folder,
                                modified: v?.contentModificationDate ?? .distantPast, mode: mode(of: u), snippet: snippet(u)))
            }
        }
        scan(root, folder: nil)
        for f in folders() { scan(root.appendingPathComponent(f, isDirectory: true), folder: f) }
        return out.sorted { $0.modified > $1.modified }
    }

    /// 一覧に出す、はじめの部分
    static func snippet(_ url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let data = h.readData(ofLength: 600)
        var s = (try? TextCodec.decode(data))?.text ?? String(decoding: data, as: UTF8.self)
        if s.hasSuffix("\u{FFFD}") { s.removeLast() }
        return s.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .prefix(3).joined(separator: " ")
    }

    // MARK: 文書ごとの表示 (Mac 版と同じ拡張属性に書く。ファイルの中身は変えない)

    static let modeAttribute = "net.satoru.satoruEditor.mode#S"

    static func mode(of url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path = path else { return nil }
            var buf = [UInt8](repeating: 0, count: 32)
            let n = getxattr(path, modeAttribute, &buf, buf.count, 0, 0)
            guard n > 0 else { return nil }
            let v = String(decoding: buf.prefix(n), as: UTF8.self)
            return ["genko", "genkoH"].contains(v) ? v : nil
        }
    }

    static func setMode(_ mode: String?, for url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path = path else { return }
            if let m = mode {
                let bytes = Array(m.utf8)
                _ = setxattr(path, modeAttribute, bytes, bytes.count, 0, 0)
            } else {
                _ = removexattr(path, modeAttribute, 0)
            }
        }
    }

    // MARK: 作る・名前を変える・移す・消す

    static func folderURL(_ folder: String?) -> URL {
        folder.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
    }

    static func uniqueURL(base: String, ext: String, in dir: URL, excluding: URL? = nil) -> URL {
        var url = dir.appendingPathComponent(base + (ext.isEmpty ? "" : "." + ext))
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) && url.standardizedFileURL != excluding?.standardizedFileURL {
            url = dir.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : "." + ext))
            n += 1
        }
        return url
    }

    /// 空のテキストを作る (Mac 版と同じく「新規テキスト」。書き始めたら 1 行目の名前に付け替える)
    static func createBlank(in folder: String?, mode: String?) -> URL? {
        let dir = folderURL(folder)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = uniqueURL(base: blankBaseName, ext: "txt", in: dir)
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else { return nil }
        setMode(mode, for: url)
        changed()
        return url
    }

    static func isBlankPlaceholder(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        return name == blankBaseName || name.hasPrefix(blankBaseName + " ")
    }

    /// 1 行目から作るファイル名 (使えない字は落とす)
    static func baseName(for text: String) -> String? {
        let first = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let base = String(first.unicodeScalars.filter { !"/\\:*?\"<>|".unicodeScalars.contains($0) && $0.value >= 0x20 }.prefix(30))
            .trimmingCharacters(in: .whitespaces)
        return base.isEmpty || base.hasPrefix(".") ? nil : base
    }

    static func cleanName(_ s: String) -> String {
        String(s.unicodeScalars.filter { !"/\\:".unicodeScalars.contains($0) && $0.value >= 0x20 }).trimmingCharacters(in: .whitespaces)
    }

    /// 名前を変える (拡張子は変えない)。新しい場所を返す
    @discardableResult
    static func rename(_ url: URL, to newName: String) throws -> URL {
        let name = cleanName(newName)
        guard !name.isEmpty, !name.hasPrefix(".") else { throw LibraryError(L("名前を入れてください")) }
        let dest = url.deletingLastPathComponent().appendingPathComponent(name + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension))
        if dest.standardizedFileURL == url.standardizedFileURL { return url }
        guard !FileManager.default.fileExists(atPath: dest.path) else { throw LibraryError(L("その名前はもう使われています")) }
        try FileManager.default.moveItem(at: url, to: dest)
        ShareStore.repath(from: url, to: dest)
        changed()
        return dest
    }

    @discardableResult
    static func move(_ url: URL, toFolder folder: String?) throws -> URL {
        let dir = folderURL(folder)
        if dir.standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL { return url }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = uniqueURL(base: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension, in: dir)
        try FileManager.default.moveItem(at: url, to: dest)
        ShareStore.repath(from: url, to: dest)
        changed()
        return dest
    }

    static func delete(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
        changed()
    }

    static func createFolder(_ name: String) throws {
        let n = cleanName(name)
        guard !n.isEmpty, !n.hasPrefix(".") else { throw LibraryError(L("名前を入れてください")) }
        let u = root.appendingPathComponent(n, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: u.path) else { throw LibraryError(L("その名前はもう使われています")) }
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        changed()
    }

    static func renameFolder(_ old: String, to name: String) throws {
        let n = cleanName(name)
        guard !n.isEmpty, !n.hasPrefix(".") else { throw LibraryError(L("名前を入れてください")) }
        if n == old { return }
        let src = folderURL(old), dest = root.appendingPathComponent(n, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: dest.path) else { throw LibraryError(L("その名前はもう使われています")) }
        try FileManager.default.moveItem(at: src, to: dest)
        ShareStore.repath(from: src, to: dest)
        changed()
    }

    static func deleteFolder(_ name: String) throws {
        try FileManager.default.removeItem(at: folderURL(name))
        changed()
    }

    // MARK: 日時の表示 (Mac 版の一覧と同じ)

    static func dateText(_ d: Date) -> String {
        let cal = Calendar.current
        let sec = Date().timeIntervalSince(d)
        if sec < 60 { return L("たった今") }
        if sec < 3600 { return L("{0} 分前", Int(sec / 60)) }
        if sec < 86400 { return L("{0} 時間前", Int(sec / 3600)) }
        if cal.isDateInYesterday(d) { return L("昨日") }
        if sec < 7 * 86400 { return L("{0} 日前", max(2, Int(sec / 86400))) }
        let f = DateFormatter()
        f.locale = I18n.language == "en" ? Locale(identifier: "en_US") : Locale(identifier: "ja_JP")
        f.setLocalizedDateFormatFromTemplate(cal.component(.year, from: d) == cal.component(.year, from: Date()) ? "MMMd" : "yMMMd")
        return f.string(from: d)
    }
}

struct LibraryError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// 開いている 1 つのテキスト。文字コード・改行はもとのまま保つ
final class TextDocument {
    private(set) var url: URL
    var text: String
    private(set) var encoding: TextEncoding
    private(set) var lineEnding: LineEnding
    private var savedText: String
    var mode: String? {
        didSet { Library.setMode(mode, for: url); Library.changed() }
    }

    init(url: URL) throws {
        self.url = url
        let data = try Data(contentsOf: url)
        let decoded = data.isEmpty ? DecodedText(text: "", encoding: .utf8, lineEnding: .lf) : try TextCodec.decode(data)
        text = decoded.text
        encoding = decoded.encoding
        lineEnding = decoded.lineEnding
        savedText = decoded.text
        mode = Library.mode(of: url)
    }

    var isDirty: Bool { text != savedText }

    func save() {
        guard isDirty else { return }
        do {
            let data = try TextCodec.encode(text, encoding: encoding, lineEnding: lineEnding)
            try data.write(to: url, options: .atomic)
            savedText = text
            // 書き込むと拡張属性が消えることがあるので書き直す
            Library.setMode(mode, for: url)
            Library.changed()
        } catch {
            // 書けない文字があるときは UTF-8 で書く
            if encoding != .utf8 {
                encoding = .utf8
                save()
            }
        }
    }

    /// 「新規テキスト」のまま書き始めたら、1 行目の名前に付け替える
    func renameFromFirstLineIfNeeded() {
        guard Library.isBlankPlaceholder(url), let base = Library.baseName(for: text) else { return }
        let dest = Library.uniqueURL(base: base, ext: url.pathExtension, in: url.deletingLastPathComponent(), excluding: url)
        guard dest != url, (try? FileManager.default.moveItem(at: url, to: dest)) != nil else { return }
        ShareStore.repath(from: url, to: dest)
        url = dest
        Library.changed()
    }

    func renamed(to u: URL) { url = u }
}
