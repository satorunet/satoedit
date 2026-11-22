import Foundation
import HinokiCore

/// テキスト一覧の中身: アプリの「書類」フォルダ (ファイル App の「このiPhone内 > さとるエディタ」) に、ふつうの .txt で置く。
/// フォルダは 1 段だけ (Mac 版の一覧と同じ: いちばん上 = さとるエディタ、その中のフォルダ)。
enum Library {
    /// 表示: "genko" (原稿用紙・縦書き) / "genkoH" (原稿用紙・横書き) / nil (標準エディタ)
    struct Item: Equatable {
        /// 本当のファイルの場所 (iCloud からまだ落としていないときも、落としたあとの場所)
        let url: URL
        let name: String
        let ext: String
        /// nil = いちばん上、名前 = その中のフォルダ
        let folder: String?
        let modified: Date
        let mode: String?
        let snippet: String
        /// iCloud にだけあって、まだこの端末に落としていない
        let isPlaceholder: Bool
        var isGenko: Bool { mode == "genko" || mode == "genkoH" }
    }

    static let textExtensions: Set<String> = ["txt", "text", "md", "markdown", "csv", "tsv", "log", "json", "xml", "html", "htm",
                                              "css", "js", "ts", "swift", "py", "rb", "c", "h", "cpp", "java", "ini", "yml", "yaml"]
    static let blankBaseName = "新規テキスト"
    static let didChange = Notification.Name("LibraryDidChange")

    /// いまの置き場所: iCloud Drive の「さとるエディタ」(使えれば自動で) か、この iPhone の中
    static var root: URL {
        if let o = ProcessInfo.processInfo.environment["SATORU_LIBRARY_DIR"] { return URL(fileURLWithPath: o, isDirectory: true) }
        return LibraryLocation.iCloudRoot ?? localRoot
    }

    /// この iPhone の中 (アプリの書類フォルダ。ファイル App の「このiPhone内 > さとるエディタ」)
    static var localRoot: URL { LibraryLocation.localRoot }

    static func changed() { NotificationCenter.default.post(name: didChange, object: nil) }

    // MARK: 一覧

    static func folders(in base: URL? = nil) -> [String] {
        let fm = FileManager.default
        let list = (try? fm.contentsOfDirectory(at: base ?? root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return list.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && $0.lastPathComponent != "Inbox" }
            .map { $0.lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// iCloud にまだ落としていないファイルは、「.名前.txt.icloud」という隠しファイルになっている
    static func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
    }

    /// まだこの端末に落としていないか (隠しファイルだけある / iCloud の状態が「落としていない」)
    static func needsDownload(_ url: URL) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { return fm.fileExists(atPath: placeholderURL(for: url).path) }
        var u = url
        u.removeAllCachedResourceValues()
        return (try? u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus == .notDownloaded
    }

    /// iCloud から落とし始める (iCloud でないフォルダなら何もしない)
    static func requestDownload(_ url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    private static var snippetCache: [String: (Date, String)] = [:]

    /// 全部のテキスト (新しく書き換えた順)
    static func items(in base: URL? = nil) -> [Item] {
        let base = base ?? root
        var out: [Item] = []
        let fm = FileManager.default
        func scan(_ dir: URL, folder: String?) {
            let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey]
            // 隠しファイルも見る (iCloud の「.名前.txt.icloud」)
            for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [])) ?? [] {
                let v = try? u.resourceValues(forKeys: Set(keys))
                if v?.isDirectory == true { continue }
                var file = u
                var placeholder = false
                let fileName = u.lastPathComponent
                if fileName.hasPrefix(".") {
                    guard fileName.hasSuffix(".icloud"), fileName.count > 8 else { continue }
                    file = dir.appendingPathComponent(String(fileName.dropFirst().dropLast(7)))
                    if fm.fileExists(atPath: file.path) || file.lastPathComponent.hasPrefix(".") { continue }
                    placeholder = true
                } else if v?.ubiquitousItemDownloadingStatus == .notDownloaded {
                    placeholder = true
                }
                let ext = file.pathExtension.lowercased()
                guard textExtensions.contains(ext) || ext.isEmpty else { continue }
                let modified = v?.contentModificationDate ?? .distantPast
                var snip = ""
                if !placeholder {
                    if let c = snippetCache[file.path], c.0 == modified { snip = c.1 } else {
                        snip = snippet(file)
                        snippetCache[file.path] = (modified, snip)
                    }
                }
                out.append(Item(url: file, name: file.deletingPathExtension().lastPathComponent, ext: file.pathExtension, folder: folder,
                                modified: modified, mode: placeholder ? nil : mode(of: file), snippet: snip, isPlaceholder: placeholder))
            }
        }
        scan(base, folder: nil)
        for f in folders(in: base) { scan(base.appendingPathComponent(f, isDirectory: true), folder: f) }
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

    /// Mac 版の拡張属性 (net.satoru.…: 表示・変更履歴の id) をまとめて読む。書き直すと消えるので、保存のときに戻す
    static func appAttributes(of url: URL) -> [String: [UInt8]] {
        url.withUnsafeFileSystemRepresentation { path -> [String: [UInt8]] in
            guard let path = path else { return [:] }
            let size = listxattr(path, nil, 0, 0)
            guard size > 0 else { return [:] }
            var names = [CChar](repeating: 0, count: size)
            guard listxattr(path, &names, size, 0) > 0 else { return [:] }
            var out: [String: [UInt8]] = [:]
            for raw in names.split(separator: 0) {
                let name = String(cString: Array(raw) + [0])
                guard name.hasPrefix("net.satoru.") else { continue }
                let n = getxattr(path, name, nil, 0, 0, 0)
                guard n >= 0 else { continue }
                var buf = [UInt8](repeating: 0, count: max(n, 1))
                let r = getxattr(path, name, &buf, buf.count, 0, 0)
                if r >= 0 { out[name] = Array(buf.prefix(r)) }
            }
            return out
        }
    }

    static func setAppAttributes(_ attrs: [String: [UInt8]], for url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path = path else { return }
            for (k, v) in attrs { _ = setxattr(path, k, v, v.count, 0, 0) }
        }
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: ほかの端末 (iCloud) と取り合わないように、読み書きは NSFileCoordinator を通す

    static func coordinatedRead(_ url: URL) throws -> Data {
        var err: NSError?
        var result: Result<Data, Error> = .failure(LibraryError(L("開けませんでした")))
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &err) { u in
            result = Result { try Data(contentsOf: u) }
        }
        if let e = err { throw e }
        return try result.get()
    }

    /// 書く (拡張属性 net.satoru.… は書く前のものを戻す)
    static func coordinatedWrite(_ data: Data, to url: URL, attributes: [String: [UInt8]]? = nil) throws {
        var err: NSError?
        var failure: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &err) { u in
            let attrs = attributes ?? appAttributes(of: u)
            do {
                try data.write(to: u, options: .atomic)
                setAppAttributes(attrs, for: u)
            } catch { failure = error }
        }
        if let e = err ?? failure { throw e }
    }

    static func coordinatedMove(_ src: URL, to dest: URL) throws {
        var err: NSError?
        var failure: Error?
        let c = NSFileCoordinator(filePresenter: nil)
        c.coordinate(writingItemAt: src, options: .forMoving, writingItemAt: dest, options: .forReplacing, error: &err) { a, b in
            do {
                try FileManager.default.moveItem(at: a, to: b)
                c.item(at: a, didMoveTo: b)
            } catch { failure = error }
        }
        if let e = err ?? failure { throw e }
    }

    static func coordinatedDelete(_ url: URL) throws {
        var err: NSError?
        var failure: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &err) { u in
            do { try FileManager.default.removeItem(at: u) } catch { failure = error }
        }
        if let e = err ?? failure { throw e }
    }

    /// 消す・移すときの本当の場所 (まだ落としていないなら隠しファイル)
    private static func onDisk(_ url: URL) -> URL {
        FileManager.default.fileExists(atPath: url.path) ? url : placeholderURL(for: url)
    }

    // MARK: iCloud ⇄ この端末 に移す (フォルダの名前はそのまま。表示などの拡張属性もついていく)

    /// 一覧に出している場所から、もう一方へ移す。終わったら新しい場所 (できなければエラー)
    static func moveToOtherPlace(_ url: URL, done: @escaping (Result<URL, Error>) -> Void) {
        guard let cloud = LibraryLocation.iCloudDocuments else { return done(.failure(LibraryError(L("iCloud が使えません")))) }
        let toCloud = !LibraryLocation.isICloud
        let from = root, to = toCloud ? cloud : localRoot
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let folder = parent.path == from.standardizedFileURL.path ? nil : parent.lastPathComponent
        let dir = folderURL(folder, in: to)
        let dest = uniqueURL(base: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension, in: dir)
        let attrs = appAttributes(of: url)
        let useUbiquity = LibraryLocation.overrideForTesting == nil
        // iCloud コンテナへの出し入れは setUbiquitous を使う (時間がかかることがあるので、メインスレッドでは呼ばない)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<URL, Error> {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if useUbiquity {
                    try FileManager.default.setUbiquitous(toCloud, itemAt: url, destinationURL: dest)
                } else {
                    try coordinatedMove(url, to: dest)
                }
                if FileManager.default.fileExists(atPath: dest.path) { setAppAttributes(attrs, for: dest) }
                return dest
            }
            DispatchQueue.main.async {
                changed()
                done(result)
            }
        }
    }

    // MARK: 作る・名前を変える・移す・消す

    static func folderURL(_ folder: String?, in base: URL? = nil) -> URL {
        let base = base ?? root
        return folder.map { base.appendingPathComponent($0, isDirectory: true) } ?? base
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: placeholderURL(for: url).path)
    }

    static func uniqueURL(base: String, ext: String, in dir: URL, excluding: URL? = nil) -> URL {
        var url = dir.appendingPathComponent(base + (ext.isEmpty ? "" : "." + ext))
        var n = 2
        while exists(url) && url.standardizedFileURL != excluding?.standardizedFileURL {
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
        guard (try? coordinatedWrite(Data(), to: url, attributes: [:])) != nil else { return nil }
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
        guard !exists(dest) else { throw LibraryError(L("その名前はもう使われています")) }
        try coordinatedMove(url, to: dest)
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
        try coordinatedMove(url, to: dest)
        ShareStore.repath(from: url, to: dest)
        changed()
        return dest
    }

    static func delete(_ url: URL) throws {
        try coordinatedDelete(onDisk(url))
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
        try coordinatedMove(src, to: dest)
        ShareStore.repath(from: src, to: dest)
        changed()
    }

    static func deleteFolder(_ name: String) throws {
        try coordinatedDelete(folderURL(name))
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

/// 開いている 1 つのテキスト。文字コード・改行はもとのまま保つ。
///
/// ほかの端末 (Mac・iCloud) で書き換えられたとき (checkDisk・保存の前に確かめる):
/// - こちらで書き換えていなければ、読み直す。
/// - こちらでも書き換えていたら、こちらの版をそのまま使い、ほかの端末の版は「名前 (別の端末).txt」として隣に残す。
final class TextDocument {
    private(set) var url: URL
    var text: String
    private(set) var encoding: TextEncoding
    private(set) var lineEnding: LineEnding
    private var savedText: String
    /// 最後に読んだ・書いたときのファイルの日時 (ほかの端末で書き換えられたかを見る)
    private var diskDate: Date?
    private var quiet = false
    var mode: String? {
        didSet { if !quiet { Library.setMode(mode, for: url); Library.changed() } }
    }
    /// ほかの端末の版を別のファイルに残したとき
    var onKeptOtherVersion: ((URL) -> Void)?

    enum DiskChange: Equatable { case none, reloaded, keptBoth(URL) }

    init(url: URL) throws {
        self.url = url
        let data = try Library.coordinatedRead(url)
        let decoded = data.isEmpty ? DecodedText(text: "", encoding: .utf8, lineEnding: .lf) : try TextCodec.decode(data)
        text = decoded.text
        encoding = decoded.encoding
        lineEnding = decoded.lineEnding
        savedText = decoded.text
        diskDate = Library.modificationDate(url)
        mode = Library.mode(of: url)
    }

    var isDirty: Bool { text != savedText }

    /// ほかの端末で書き換えられていないか確かめる
    @discardableResult
    func checkDisk() -> DiskChange {
        var result = DiskChange.none
        // iCloud が見つけた食い違い (同時に書き換えた) は、ほかの版を別のファイルに残して片づける
        if let others = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !others.isEmpty {
            for v in others {
                if let data = try? Data(contentsOf: v.url), let copy = keepOther(data) { result = .keptBoth(copy) }
                v.isResolved = true
            }
            try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        }
        if Library.needsDownload(url) { Library.requestDownload(url) }
        guard let d = Library.modificationDate(url), d != diskDate,
              let data = try? Library.coordinatedRead(url) else { return result }
        diskDate = d
        guard let decoded = data.isEmpty ? DecodedText(text: "", encoding: .utf8, lineEnding: .lf) : try? TextCodec.decode(data),
              decoded.text != savedText else { return result }
        if !isDirty {
            text = decoded.text
            savedText = decoded.text
            encoding = decoded.encoding
            lineEnding = decoded.lineEnding
            quiet = true
            mode = Library.mode(of: url)
            quiet = false
            return result == .none ? .reloaded : result
        }
        // 両方で書き換えた: こちらはそのまま、あちらは別のファイルに
        savedText = decoded.text
        if let copy = keepOther(data) { return .keptBoth(copy) }
        return result
    }

    /// ほかの端末の版を「名前 (別の端末).txt」として隣に置く
    private func keepOther(_ data: Data) -> URL? {
        let base = url.deletingPathExtension().lastPathComponent + " " + L("(別の端末)")
        let dest = Library.uniqueURL(base: base, ext: url.pathExtension, in: url.deletingLastPathComponent())
        guard (try? Library.coordinatedWrite(data, to: dest, attributes: Library.appAttributes(of: url))) != nil else { return nil }
        Library.changed()
        onKeptOtherVersion?(dest)
        return dest
    }

    func save() {
        guard isDirty else { return }
        // 書く前に、ほかの端末で書き換えられていないか (書き換えられていたら、あちらの版を残す)
        if Library.modificationDate(url) != diskDate { checkDisk() }
        guard isDirty else { return }
        do {
            let data = try TextCodec.encode(text, encoding: encoding, lineEnding: lineEnding)
            // 書き込むと拡張属性 (表示・Mac 版の変更履歴) が消えるので書き直す
            try Library.coordinatedWrite(data, to: url)
            savedText = text
            diskDate = Library.modificationDate(url)
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
        guard dest != url, (try? Library.coordinatedMove(url, to: dest)) != nil else { return }
        ShareStore.repath(from: url, to: dest)
        url = dest
        Library.changed()
    }

    func renamed(to u: URL) { url = u }
}
