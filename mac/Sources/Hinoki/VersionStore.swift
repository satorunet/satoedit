import AppKit
import HinokiCore

/// テキストごとの版の記録 (この Mac の中の git)。
///
/// 置き場所: ~/.satoruEditor/history/<履歴の番号>/ に、テキスト 1 つにつき 1 つの小さな git のリポジトリを作る
///   (content = そのテキストの中身、meta.json = いまの場所)。あなたのフォルダには .git を作らない。
/// どのテキストの履歴かは、テキストのファイルの見えない所 (拡張属性) に書いた「履歴の番号」で見分ける。
///   Finder で動かしても・名前を変えても、番号はファイルについていくので、履歴も追いかけられる。
///   Finder で複製したもの (番号も写る) は、そこまでの履歴を写して、別の番号にする。
/// テキストを削除したら、そのリポジトリごと消す (履歴も残さない)。
/// 暗号化した文書・一部分だけ開いた文書・サーバの一時ファイルは入れない。
enum VersionStore {
    static let prefKey = "versionHistory"
    /// テキストごとに残す版の数 (設定で選ぶ)。それより古い版は消す
    static let maxKey = "versionHistoryMax"
    static let maxChoices = [10, 20, 50, 100, 200, 500, 1000]
    static var maxVersions: Int {
        let v = UserDefaults.standard.integer(forKey: maxKey)
        return v > 0 ? v : 20
    }
    /// テキスト管理 (追加機能) がオンで、設定 > バックアップ の「版を残す」もオンのとき
    static var isOn: Bool { EditorExtension.library.isOn && (UserDefaults.standard.object(forKey: prefKey) as? Bool ?? true) }
    static var repo: URL {
        // 確かめ用に、別の場所を使える (SATORU_VERSIONS_DIR)
        if let d = ProcessInfo.processInfo.environment["SATORU_VERSIONS_DIR"] { return URL(fileURLWithPath: d, isDirectory: true) }
        return AppPaths.file("history", isDirectory: true)
    }
    private static let queue = DispatchQueue(label: "satoru.versions")
    private static let git = "/usr/bin/git"
    static let idAttribute = "net.satoru.satoruEditor.history#S"

    /// git が使えるか (Mac の「コマンドライン・デベロッパ・ツール」が入っているか)
    static let gitAvailable: Bool = {
        guard FileManager.default.isExecutableFile(atPath: git) else { return false }
        return runGit(["--version"], in: nil).status == 0
    }()

    struct Version {
        let commit: String
        let date: Date
        let message: String
    }

    // MARK: git を動かす

    @discardableResult
    private static func runGit(_ args: [String], in dir: URL?, env extra: [String: String] = [:]) -> (status: Int32, out: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = args
        if let d = dir { p.currentDirectoryURL = d }
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        env.merge(extra) { $1 }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        // waitUntilExit は待つあいだに画面の処理を回すので、文書の復元などが割り込んで落ちることがある。合図で待つ
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return (-1, Data()) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        return (p.terminationStatus, data)
    }

    // MARK: 履歴の番号 (ファイルの拡張属性)

    static func historyID(of url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path = path else { return nil }
            var buf = [UInt8](repeating: 0, count: 64)
            let n = getxattr(path, idAttribute, &buf, buf.count, 0, 0)
            guard n > 0 else { return nil }
            let v = String(decoding: buf.prefix(n), as: UTF8.self)
            return v.range(of: "^[0-9a-f]{16,32}$", options: .regularExpression) != nil ? v : nil
        }
    }

    static func setHistoryID(_ id: String, on url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path = path else { return }
            let bytes = Array(id.utf8)
            _ = setxattr(path, idAttribute, bytes, bytes.count, 0, 0)
        }
    }

    private static func normalized(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
    private static func dir(_ id: String) -> URL { repo.appendingPathComponent(id, isDirectory: true) }
    private static func newID() -> String { (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }

    private struct Meta: Codable { var path: String }
    private static func meta(_ id: String) -> Meta? {
        try? JSONDecoder().decode(Meta.self, from: Data(contentsOf: dir(id).appendingPathComponent("meta.json")))
    }
    private static func writeMeta(_ id: String, path: String) {
        try? JSONEncoder().encode(Meta(path: path)).write(to: dir(id).appendingPathComponent("meta.json"), options: .atomic)
    }

    private static func newRepo() -> String? {
        let id = newID()
        let d = dir(id)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        guard runGit(["init", "-q"], in: d).status == 0 else { return nil }
        runGit(["config", "user.name", "SatoruEditor"], in: d)
        runGit(["config", "user.email", "versions@satoru-editor.local"], in: d)
        runGit(["config", "commit.gpgsign", "false"], in: d)
        runGit(["config", "core.autocrlf", "false"], in: d)
        return id
    }

    private static func hasCommits(_ id: String) -> Bool {
        runGit(["rev-parse", "-q", "--verify", "HEAD"], in: dir(id)).status == 0
    }

    /// そのテキストの履歴の番号を決める (queue の上で)。create = なければ作る
    /// - 番号が付いていて、その履歴の「いまの場所」と同じ → そのまま
    /// - 番号が付いているが、履歴の場所が別 → その場所にまだ同じ番号のファイルがあれば「複製」(履歴を写して別の番号に)、なければ「移動」(場所を付け替える)
    /// - 番号がない → 同じ場所の履歴があれば使う (拡張属性が消えたとき)、なければ新しく作る
    private static func resolve(_ url: URL, create: Bool) -> String? {
        let p = normalized(url)
        let fm = FileManager.default
        if let id = historyID(of: url), fm.fileExists(atPath: dir(id).appendingPathComponent(".git").path) {
            let m = meta(id)
            if m?.path == p { return id }
            if let old = m?.path, old != p, fm.fileExists(atPath: old), historyID(of: URL(fileURLWithPath: old)) == id {
                // 複製: そこまでの履歴を写した、別の番号にする
                guard create else { return id }
                let nid = newID()
                guard (try? fm.copyItem(at: dir(id), to: dir(nid))) != nil else { return nil }
                writeMeta(nid, path: p)
                setHistoryID(nid, on: url)
                return nid
            }
            writeMeta(id, path: p)   // 移動・名前の変更 (Finder でも)
            return id
        }
        // 番号がない: 同じ場所の履歴を探す
        if let names = try? fm.contentsOfDirectory(atPath: repo.path) {
            for id in names where meta(id)?.path == p {
                setHistoryID(id, on: url)
                return id
            }
        }
        guard create, let id = newRepo() else { return nil }
        writeMeta(id, path: p)
        setHistoryID(id, on: url)
        return id
    }

    // MARK: 記録する

    private static var pending: [String: (URL, DispatchWorkItem)] = [:]
    private static var lastCommit: [String: Date] = [:]
    /// 自動保存が続くときに、版を作る間隔 (秒)。⌘S・閉じたときは、すぐ作る
    static let interval: TimeInterval = 20

    /// 保存したら: 前の版から interval 秒たっていれば、すぐ版を作る。
    /// たっていなければ、その時刻になったら (そのあいだの保存をまとめて) 1 つ作る。どの保存も、あとで必ずどれかの版に入る
    static func noteSaved(_ url: URL, now: Bool = false) {
        guard isOn, gitAvailable, url.isFileURL, !isExcluded(url) else { return }
        let k = normalized(url)
        // 保存で拡張属性が消えることがあるので、番号を付け直しておく
        queue.async { _ = resolve(url, create: false) }   // 履歴があるものだけ (無いものは、ここでは作らない)
        let since = Date().timeIntervalSince(lastCommit[k] ?? .distantPast)
        if !now, since < interval, pending[k] != nil { return }   // もう予約してある (そのときの中身で作る)
        pending[k]?.1.cancel()
        let work = DispatchWorkItem {
            commit(url, message: L("保存: {0}", url.lastPathComponent))
            DispatchQueue.main.async {
                lastCommit[k] = Date()
                if pending[k]?.0 == url { pending.removeValue(forKey: k) }
            }
        }
        pending[k] = (url, work)
        let wait = now || since >= interval ? 0 : interval - since
        queue.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// 開いたときの中身 (まだ履歴がないテキストだけ)。開いただけでは記録せず、はじめて書き換えて保存したときに、
    /// その前の版としていっしょに残す (書き換える前に戻れるように)
    private static var openedContent: [String: Data] = [:]
    static func noteOpened(_ url: URL) {
        guard isOn, gitAvailable, url.isFileURL, !isExcluded(url) else { return }
        let k = normalized(url)
        queue.async {
            // 履歴がもうあるものは覚えなくてよい (番号も、ここでは付けない)
            if let id = historyID(of: url), FileManager.default.fileExists(atPath: dir(id).appendingPathComponent(".git").path), hasCommits(id) { return }
            if let d = try? Data(contentsOf: url), d.count <= 20_000_000 { openedContent[k] = d }
        }
    }

    private static func isExcluded(_ url: URL) -> Bool {
        let p = url.resolvingSymlinksInPath().path
        if p.hasPrefix(RemoteDocuments.tempRoot.resolvingSymlinksInPath().path + "/") { return true }
        if p.hasPrefix(repo.resolvingSymlinksInPath().path + "/") { return true }
        guard let h = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? h.close() }
        return FileCrypto.isEncrypted(h.readData(ofLength: 16))   // 暗号化した文書は入れない (中身の流出を防ぐため)
    }

    /// 今のファイルの中身を記録する (前と同じなら何もしない)。queue の上で呼ぶ
    private static func commit(_ url: URL, message: String) {
        guard let data = try? Data(contentsOf: url), data.count <= 20_000_000 else { return }
        let k = normalized(url)
        // 中身が開いたときのままなら、何も残さない (開いただけ・保存しただけでは履歴を作らない)
        if let orig = openedContent[k], orig == data, resolve(url, create: false).map({ !hasCommits($0) }) ?? true { return }
        guard let id = resolve(url, create: true) else { return }
        // はじめての記録: 開いたときの中身を、その前の版として先に残す
        if let orig = openedContent.removeValue(forKey: k), !hasCommits(id), orig != data {
            commitData(orig, id: id, message: L("開いたときの中身: {0}", url.lastPathComponent), date: nil)
        }
        commitData(data, id: id, message: message, date: nil)
    }

    private static func commitData(_ data: Data, id: String, message: String, date: Date?) {
        let d = dir(id)
        let file = d.appendingPathComponent("content")
        if (try? Data(contentsOf: file)) == data, hasCommits(id) { return }
        guard (try? data.write(to: file, options: .atomic)) != nil else { return }
        runGit(["add", "content", "meta.json"], in: d)
        var env: [String: String] = [:]
        if let t = date {
            let s = "\(Int(t.timeIntervalSince1970)) +0000"
            env = ["GIT_AUTHOR_DATE": s, "GIT_COMMITTER_DATE": s]
        }
        runGit(["commit", "-q", "--no-verify", "--allow-empty", "-m", message], in: d, env: env)
        // 自動の記録 (日時を指定しないとき) は、数が上限を少し超えたら古いものを消す (毎回作り直さないよう、10 個ぶんまとめて)
        if date == nil { prune(id, keep: maxVersions, slack: 10) }
    }

    /// 新しい版を keep 個だけ残して、それより古い版を消す (keep + slack 個を超えたときだけ)。
    /// 古い版が git の中にも残らないよう、残す版だけでリポジトリを作り直す
    private static func prune(_ id: String, keep: Int, slack: Int) {
        let d = dir(id)
        let log = String(decoding: runGit(["log", "--format=%H%x09%ct%x09%s", "--", "content"], in: d).out, as: UTF8.self)
            .split(separator: "\n").map { $0.split(separator: "\t", maxSplits: 2).map(String.init) }.filter { $0.count == 3 }
        guard log.count > keep + slack else { return }
        // 残す版 (古い順) の中身を取り出す
        var kept: [(Date, String, Data)] = []
        for f in log.prefix(keep).reversed() {
            let r = runGit(["show", f[0] + ":content"], in: d)
            guard r.status == 0, let t = Double(f[1]) else { return }   // 取り出せなければ、消さない
            kept.append((Date(timeIntervalSince1970: t), f[2], r.out))
        }
        let path = meta(id)?.path ?? ""
        let fm = FileManager.default
        // 作り直す (古い版は git の中からも消える)
        let tmp = repo.appendingPathComponent(id + ".rebuild", isDirectory: true)
        try? fm.removeItem(at: tmp)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        guard runGit(["init", "-q"], in: tmp).status == 0 else { return }
        for (k, v) in [("user.name", "SatoruEditor"), ("user.email", "versions@satoru-editor.local"), ("commit.gpgsign", "false"), ("core.autocrlf", "false")] {
            runGit(["config", k, v], in: tmp)
        }
        try? JSONEncoder().encode(Meta(path: path)).write(to: tmp.appendingPathComponent("meta.json"))
        for (date, msg, data) in kept {
            guard (try? data.write(to: tmp.appendingPathComponent("content"), options: .atomic)) != nil else { return }
            runGit(["add", "content", "meta.json"], in: tmp)
            let s = "\(Int(date.timeIntervalSince1970)) +0000"
            runGit(["commit", "-q", "--no-verify", "--allow-empty", "-m", msg], in: tmp, env: ["GIT_AUTHOR_DATE": s, "GIT_COMMITTER_DATE": s])
        }
        guard (try? fm.removeItem(at: d)) != nil, (try? fm.moveItem(at: tmp, to: d)) != nil else { return }
    }

    /// 上限を変えたとき: すべてのテキストの履歴を、新しい上限まで減らす
    static func pruneAll() {
        guard gitAvailable else { return }
        let keep = maxVersions
        queue.async {
            for id in (try? FileManager.default.contentsOfDirectory(atPath: repo.path)) ?? [] where !id.contains(".") {
                prune(id, keep: keep, slack: 0)
            }
        }
    }

    /// アプリの中で名前や場所を変えた: 履歴の場所を付け替える (フォルダなら中のテキストすべて)
    static func repath(from old: URL, to new: URL) {
        guard gitAvailable else { return }
        queue.async {
            let o = normalized(old), n = normalized(new)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: repo.path) else { return }
            for id in names {
                guard let p = meta(id)?.path, p == o || p.hasPrefix(o + "/") else { continue }
                writeMeta(id, path: n + p.dropFirst(o.count))
            }
        }
    }

    /// テキストを削除する: その履歴も消す (フォルダなら中のテキストすべて)。消す前に呼ぶ (番号を読むため)
    static func forget(_ urls: [URL]) {
        guard gitAvailable else { return }
        var ids: [String] = []
        var paths: [String] = []
        for u in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                if let walker = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil) {
                    for case let f as URL in walker { if let id = historyID(of: f) { ids.append(id) } }
                }
                paths.append(normalized(u) + "/")
            } else {
                if let id = historyID(of: u) { ids.append(id) }
                paths.append(normalized(u))
            }
        }
        queue.async {
            let fm = FileManager.default
            var all = Set(ids)
            // 番号が読めなかったものも、場所で探す
            for id in (try? fm.contentsOfDirectory(atPath: repo.path)) ?? [] {
                guard let p = meta(id)?.path else { continue }
                if paths.contains(where: { $0.hasSuffix("/") ? p.hasPrefix($0) : p == $0 }) { all.insert(id) }
            }
            for id in all where !id.isEmpty && !id.contains("/") && !id.contains(".") { try? fm.removeItem(at: dir(id)) }
        }
    }

    // MARK: 見る

    /// そのテキストの版 (新しい順)
    static func history(_ url: URL) -> [Version] {
        guard gitAvailable else { return [] }
        let r = queue.sync { () -> Data in
            guard let id = resolve(url, create: false), hasCommits(id) else { return Data() }
            return runGit(["log", "--format=%H%x09%ct%x09%s", "--", "content"], in: dir(id)).out
        }
        return String(decoding: r, as: UTF8.self).split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard f.count == 3, let t = Double(f[1]) else { return nil }
            return Version(commit: f[0], date: Date(timeIntervalSince1970: t), message: f[2])
        }
    }

    /// その版の中身
    static func content(_ v: Version, of url: URL) -> Data? {
        queue.sync { () -> Data? in
            guard let id = resolve(url, create: false) else { return nil }
            let res = runGit(["show", v.commit + ":content"], in: dir(id))
            return res.status == 0 ? res.out : nil
        }
    }

    // MARK: バックアップ

    /// バックアップに入れる: そのテキストの版すべて (古い順)
    static func export(_ url: URL) -> [LibraryBackup.HistoryVersion] {
        history(url).reversed().compactMap { v in
            content(v, of: url).map { LibraryBackup.HistoryVersion(date: v.date, message: v.message, data: $0) }
        }
    }

    /// バックアップから戻した: 版を古い順に入れ直す (日時もそのまま)。戻したファイルは新しい番号にする
    static func importHistory(_ versions: [LibraryBackup.HistoryVersion], for url: URL) {
        guard gitAvailable, !versions.isEmpty else { return }
        queue.sync {
            guard let id = newRepo() else { return }
            writeMeta(id, path: normalized(url))
            setHistoryID(id, on: url)
            for v in versions { commitData(v.data, id: id, message: v.message, date: v.date) }
            prune(id, keep: maxVersions, slack: 0)   // 戻した履歴も、上限まで
        }
    }

    // MARK: 前の形 (1 つの大きなリポジトリ) からの引っ越し

    /// ~/.satoruEditor/versions (前の形) があれば、テキストごとの履歴に移して、前のものは versions.migrated に名前を変える
    static func migrateOld() {
        guard gitAvailable, ProcessInfo.processInfo.environment["SATORU_VERSIONS_DIR"] == nil else { return }
        let old = AppPaths.file("versions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: old.appendingPathComponent(".git").path) else { return }
        queue.async {
            let paths = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: old.appendingPathComponent("paths.json")))) ?? [:]
            for (k, p) in paths {
                let url = URL(fileURLWithPath: p)
                guard FileManager.default.fileExists(atPath: p), let id = resolve(url, create: true), !hasCommits(id) else { continue }
                let log = runGit(["log", "--reverse", "--format=%H%x09%ct%x09%s", "--", "files/" + k], in: old).out
                for line in String(decoding: log, as: UTF8.self).split(separator: "\n") {
                    let f = line.split(separator: "\t", maxSplits: 2).map(String.init)
                    guard f.count == 3, let t = Double(f[1]) else { continue }
                    let r = runGit(["show", f[0] + ":files/" + k], in: old)
                    if r.status == 0 { commitData(r.out, id: id, message: f[2], date: Date(timeIntervalSince1970: t)) }
                }
            }
            try? FileManager.default.moveItem(at: old, to: old.deletingLastPathComponent().appendingPathComponent("versions.migrated"))
        }
    }

    /// すべてのテキストの版の履歴を消す (テキストそのものは消さない)
    static func clearAll() {
        pending.values.forEach { $0.1.cancel() }
        pending.removeAll()
        lastCommit.removeAll()
        queue.sync {
            let fm = FileManager.default
            for id in (try? fm.contentsOfDirectory(atPath: repo.path)) ?? [] where !id.hasPrefix(".") {
                try? fm.removeItem(at: dir(id))
            }
        }
    }

    /// 待っている記録を、いますぐ済ませる (アプリを終えるとき)
    static func flushAll() {
        let list = pending.values
        pending.removeAll()
        guard !list.isEmpty else { return }
        queue.sync {
            for (u, w) in list {
                w.cancel()
                commit(u, message: L("保存: {0}", u.lastPathComponent))
            }
        }
    }
}
