import AppKit
import UniformTypeIdentifiers

private var panelWidthKey = 0
private var panelHandleKey = 0
private var panelLinkKey = 0
import HinokiCore

// テキスト一覧 (メモ帳のように、これまで書いた・開いたテキストをまとめて扱う)。
// ・新しく書いた文書は、名前を付けなくても「書類/さとるエディタ」に自動で保存し、一覧に入る (書き続けても自動で保存)
// ・開いたり保存したりしたファイルも一覧に入る
// ・ウインドウの左に一覧 (全体の件数つき)。ボタンで、本文の見本つきのカード (サムネ) を並べた画面に切り替えられる

// MARK: - 一覧の中身

enum TextLibrary {
    struct Item {
        let url: URL
        let title: String
        let snippet: String
        let modified: Date
        let inFolder: Bool
        let encrypted: Bool
        /// ピン固定 (いちばん上に出す)・ロック (書き換えできない)
        var pinned = false
        var locked = false
        /// 公開中のリンク (なければ nil)
        var sharedURL: String?
        /// どのフォルダのものか: "" = さとるエディタ (いちばん上)、名前 = その中のフォルダ、nil = ほかの場所のファイル
        let group: String?
        /// 最後に開いていたときの表示: "genko" (原稿用紙・縦書き) / "genkoH" (原稿用紙・横書き) / "a4" / nil (標準エディタ)
        let mode: String?
        var isGenko: Bool { mode == "genko" || mode == "genkoH" }
    }

    // MARK: 文書ごとの表示 (作文かどうか)

    private static let modesKey = "libraryModes"

    // ファイルの見えない場所 (拡張属性) に、表示 (作文の縦・横、A4) を書いておく。中身の文字は変えない。
    // 名前の最後の「#S」は、iCloud Drive で同期した先にも引き継いでもらうための印
    static let modeAttribute = "net.satoru.satoruEditor.mode#S"

    /// ファイルの拡張属性から表示を読む ("genko" / "genkoH" / "a4")。標準エディタなら nil
    static func fileMode(_ url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path = path else { return nil }
            var buf = [UInt8](repeating: 0, count: 32)
            let n = getxattr(path, modeAttribute, &buf, buf.count, 0, 0)
            guard n > 0 else { return nil }
            let v = String(decoding: buf.prefix(n), as: UTF8.self)
            return ["genko", "genkoH", "a4"].contains(v) ? v : nil
        }
    }

    /// 拡張属性に書く (nil = 標準エディタなので消す)。書けないファイル (ロック中など) は何もしない
    static func writeFileMode(_ mode: String?, to url: URL) {
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

    /// その文書をどの表示で使っていたかを覚える (ファイルの拡張属性と、念のためアプリの中にも)
    static func setMode(_ mode: String?, for url: URL?) {
        guard let url = url, url.isFileURL else { return }
        if FileManager.default.fileExists(atPath: url.path), fileMode(url) != mode { writeFileMode(mode, to: url) }
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        var all = UserDefaults.standard.dictionary(forKey: modesKey) as? [String: String] ?? [:]
        guard all[p] != mode else { return }
        all[p] = mode
        // 覚えるのは多くても 1000 件まで
        if all.count > 1000, let first = all.keys.first { all.removeValue(forKey: first) }
        UserDefaults.standard.set(all, forKey: modesKey)
        changed()
    }

    /// 表示を読む: まずファイルの拡張属性、なければアプリの中に覚えたもの (前の版) を使い、拡張属性に移しておく
    static func mode(for path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        if let m = fileMode(url) { return m }
        guard let m = (UserDefaults.standard.dictionary(forKey: modesKey) as? [String: String])?[path] else { return nil }
        if FileManager.default.fileExists(atPath: path) { writeFileMode(m, to: url) }
        return m
    }

    static let didChange = Notification.Name("satoru.textLibraryDidChange")
    private static let knownKey = "libraryFiles"
    private static let visibleKey = "libraryVisible"
    private static let maxKnown = 500

    /// 自動で保存する場所 (書類/さとるエディタ。iCloud に置く設定なら iCloud Drive/さとるエディタ)
    static var folder: URL {
        // 動作確認用: 本物の書類フォルダに触れないよう、別の場所に差し替える (アプリ本体では使わない)
        if let o = ProcessInfo.processInfo.environment["SATORU_LIBRARY_DIR"] { return URL(fileURLWithPath: o, isDirectory: true) }
        if !usesICloud, let c = customFolder { return c }   // 任意フォルダを選んでいるときは、そこが基準
        if usesICloud, iCloudDriveRoot != nil {
            // iCloud に置いているときは、写した先 (覚えておいた場所)。覚えていなければ、いま使える iCloud の場所
            if let p = UserDefaults.standard.string(forKey: iCloudPathKey) { return URL(fileURLWithPath: p, isDirectory: true) }
            if let u = iCloudFolder { return u }
        }
        return localFolder
    }

    /// この Mac の中の置き場所 (書類/さとるエディタ)。表示の言語を変えても同じ場所を使うよう、名前は訳さない
    static var localFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("さとるエディタ", isDirectory: true)
    }

    // MARK: iCloud Drive に置く (iPhone 版と同じテキストを見るため)

    static let iCloudKey = "libraryInICloud"
    /// ▾ ボタンの「任意フォルダ」で選んだ、この Mac の中のフォルダ (フォルダの欄はここを基準にする)
    static let customKey = "libraryCustomFolder"
    static var customRecent: [String] {
        get { UserDefaults.standard.stringArray(forKey: "libraryCustomRecent") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "libraryCustomRecent") }
    }
    static var customFolder: URL? {
        guard let p = UserDefaults.standard.string(forKey: customKey) else { return nil }
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &dir) && dir.boolValue ? URL(fileURLWithPath: p, isDirectory: true) : nil
    }
    /// いちばん上の階層の名前 (ふだんは「メモ」、任意フォルダのときはそのフォルダの名前)
    static var rootName: String { !usesICloud ? customFolder?.lastPathComponent ?? L("メモ") : L("メモ") }
    /// 任意フォルダを基準にして見る
    static func showCustom(_ url: URL) {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        UserDefaults.standard.set(false, forKey: iCloudKey)
        UserDefaults.standard.set(path, forKey: customKey)
        // 開いたことのある任意フォルダ (新しい順に 8 つまで。▾ ボタンの「任意フォルダ…」の下に出す)
        customRecent = Array(([path] + customRecent.filter { $0 != path }).prefix(8))
        selectedGroup = "all"
        changed()
    }
    /// iCloud Drive に置く設定か
    static var usesICloud: Bool { UserDefaults.standard.bool(forKey: iCloudKey) }
    /// iCloud Drive のいちばん上 (この Mac で iCloud Drive を使っていなければ nil)
    static var iCloudDriveRoot: URL? {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) && dir.boolValue ? u : nil
    }
    /// iPhone 版と同じ iCloud の入れ物 (iPhone 版を一度使うと、この Mac にもできる)。
    /// iCloud Drive では「さとるエディタ」という名前のフォルダに見える
    static var iCloudContainerDocuments: URL? {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~net~satoru~satoruEditor/Documents", isDirectory: true)
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &dir) && dir.boolValue ? u : nil
    }
    /// iCloud の置き場所: iPhone 版と同じ入れ物があればそこ、なければ iCloud Drive の「さとるエディタ」フォルダ
    static var iCloudFolder: URL? {
        if let c = iCloudContainerDocuments { return c }
        return iCloudDriveRoot?.appendingPathComponent("さとるエディタ", isDirectory: true)
    }
    private static let iCloudPathKey = "libraryICloudPath"

    /// 起動したとき: iCloud Drive が使えるなら、何も選ばなくても最初から iCloud に置く (今のテキストは写す)。
    /// iPhone 版と同じ入れ物がこの Mac にできたら、そちらへ写して使う
    static func autoICloud() {
        guard ProcessInfo.processInfo.environment["SATORU_LIBRARY_DIR"] == nil, iCloudDriveRoot != nil else { return }
        let d = UserDefaults.standard
        // はじめはローカル (この Mac)。iCloud は ▾ ボタンから選ぶ
        if d.object(forKey: iCloudKey) == nil {
            showStorage(iCloud: false)
            return
        }
        guard usesICloud, let target = iCloudContainerDocuments,
              folder.standardizedFileURL.path != target.standardizedFileURL.path else { return }
        _ = try? switchStorage(toICloud: true)
    }

    /// フォルダの欄のタブ: どちらの置き場所 (iCloud / この Mac) のテキストを見るか。ファイルは写さない
    static func showStorage(iCloud: Bool) {
        guard iCloud != usesICloud || customFolder != nil || UserDefaults.standard.object(forKey: iCloudKey) == nil else { return }
        UserDefaults.standard.removeObject(forKey: customKey)
        if iCloud, let to = iCloudFolder {
            try? FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
            UserDefaults.standard.set(to.path, forKey: iCloudPathKey)
        }
        UserDefaults.standard.set(iCloud, forKey: iCloudKey)
        selectedGroup = "all"
        changed()
    }

    /// 置き場所を変える。前の場所のテキストを新しい場所へ写す (前の場所のファイルは消さない)。
    /// 同じ名前で中身がちがうものは「(Mac)」を付けて別に置く。写した数を返す
    @discardableResult
    static func switchStorage(toICloud: Bool) throws -> Int {
        let fm = FileManager.default
        let from = folder
        guard let to = toICloud ? iCloudFolder : localFolder else { throw CocoaError(.fileNoSuchFile) }
        defer {
            if toICloud { UserDefaults.standard.set(to.path, forKey: iCloudPathKey) }
            else { UserDefaults.standard.removeObject(forKey: iCloudPathKey) }
        }
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        var copied = 0
        if from.standardizedFileURL.path != to.standardizedFileURL.path,
           let walker = fm.enumerator(at: from, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let u as URL in walker {
                let rel = String(u.standardizedFileURL.path.dropFirst(from.standardizedFileURL.path.count + 1))
                var dest = to.appendingPathComponent(rel)
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
                    continue
                }
                if fm.fileExists(atPath: dest.path) {
                    if fm.contentsEqual(atPath: u.path, andPath: dest.path) { continue }
                    let base = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
                    dest = dest.deletingLastPathComponent().appendingPathComponent(base + " (Mac)" + (ext.isEmpty ? "" : "." + ext))
                    if fm.fileExists(atPath: dest.path) { continue }
                }
                // 写すと、表示 (作文など) の印 (拡張属性) もいっしょに付いていく
                try fm.copyItem(at: u, to: dest)
                copied += 1
            }
        }
        UserDefaults.standard.set(toICloud, forKey: iCloudKey)
        changed()
        return copied
    }

    /// iCloud から、まだこの Mac に落ちてきていないファイル (「.名前.icloud」) を落としてくる
    private static func downloadPlaceholders(in dir: URL) {
        let fm = FileManager.default
        guard usesICloud, let list = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in list where name.hasPrefix(".") && name.hasSuffix(".icloud") {
            let real = dir.appendingPathComponent(String(name.dropFirst().dropLast(".icloud".count)))
            try? fm.startDownloadingUbiquitousItem(at: real)
        }
    }

    static func isInFolder(_ url: URL?) -> Bool { group(of: url) != nil }

    // MARK: 開いた (足した) フォルダ: さとるエディタのフォルダの外の、好きなフォルダを一覧に出す

    private static let externalKey = "libraryExternalFolders"
    static var externalFolders: [String] {
        // 道すじは、ほかの所と同じ形 (シンボリックリンクをたどった形) にそろえる
        get { (UserDefaults.standard.stringArray(forKey: externalKey) ?? []).map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path } }
        set { UserDefaults.standard.set(newValue, forKey: externalKey); changed() }
    }
    static func addExternalFolder(_ url: URL) {
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        let lib = folder.standardizedFileURL.resolvingSymlinksInPath().path
        // さとるエディタのフォルダ (とその中) は、もう出ているので足さない
        guard p != lib, !p.hasPrefix(lib + "/"), !externalFolders.contains(p) else { return }
        externalFolders = externalFolders + [p]
        dropKnownInsideExternal()
    }

    /// 「ほかの場所」の記録から、開いたフォルダの中のものを外す (そちらで出るので、二重に出さない)
    static func dropKnownInsideExternal() {
        let keep = known.filter { externalRoot(of: URL(fileURLWithPath: $0)) == nil }
        if keep.count != known.count { known = keep }
    }
    static func removeExternalFolder(_ path: String) {
        externalFolders = externalFolders.filter { $0 != path }
    }
    /// そのファイルが入っている、開いたフォルダ (なければ nil)
    static func externalRoot(of url: URL?) -> String? {
        guard let p = url?.standardizedFileURL.resolvingSymlinksInPath().path else { return nil }
        return externalFolders.filter { p.hasPrefix($0 + "/") }.max { $0.count < $1.count }
    }
    /// 自動で保存してよい場所か (さとるエディタのフォルダか、開いたフォルダ)
    static func isManaged(_ url: URL?) -> Bool { isInFolder(url) || externalRoot(of: url) != nil }

    /// その文書がどのフォルダのものか: "" = さとるエディタ直下、"旅行/京都" のような中のフォルダの道すじ、nil = ほかの場所
    static func group(of url: URL?) -> String? {
        guard let u = url?.standardizedFileURL.resolvingSymlinksInPath() else { return nil }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let parent = u.deletingLastPathComponent().path
        if parent == root { return "" }
        guard parent.hasPrefix(root + "/") else { return nil }
        return String(parent.dropFirst(root.count + 1))
    }

    // MARK: フォルダ (メモ帳のように、左の欄で分ける。フォルダの中にフォルダも作れる)

    /// フォルダの道すじ ("旅行/京都") → 場所
    static func folderURL(_ rel: String) -> URL {
        rel.isEmpty ? folder : folder.appendingPathComponent(rel, isDirectory: true)
    }

    /// あるフォルダのすぐ下のフォルダ (道すじ)。ドラッグで並べ替えた順 (まだ並べていないものは名前の順で後ろ)
    static func childFolders(of rel: String) -> [String] {
        let dir = folderURL(rel)
        let list = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let order = folderOrder
        let names = list.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.map { $0.lastPathComponent }
        let paths = names.map { rel.isEmpty ? $0 : rel + "/" + $0 }
        func rank(_ p: String) -> Int { order.firstIndex(of: p) ?? Int.max }
        return paths.sorted {
            let a = rank($0), b = rank($1)
            return a != b ? a < b : $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    /// さとるエディタの中のフォルダすべて (道すじ。上から順に、親のすぐあとに子)。深さは 8 まで
    static func subfolders() -> [String] {
        var out: [String] = []
        func walk(_ rel: String, _ depth: Int) {
            guard depth < 8 else { return }
            for c in childFolders(of: rel) { out.append(c); walk(c, depth + 1) }
        }
        walk("", 0)
        return out
    }

    // MARK: フォルダごとのアイコン (絵と色)

    /// 選べる絵 (SF Symbols の名前, 画面に出す名前)
    static let folderSymbols: [(String, String)] = [
        ("folder", "フォルダ"), ("star", "星"), ("heart", "ハート"), ("book", "本"), ("pencil", "えんぴつ"),
        ("graduationcap", "学校"), ("briefcase", "仕事"), ("house", "家"), ("airplane", "旅行"), ("camera", "写真"),
        ("music.note", "音楽"), ("leaf", "葉っぱ"), ("lightbulb", "アイデア"), ("flag", "旗"), ("bookmark", "しおり"),
        ("tray", "トレイ"), ("person", "人"), ("calendar", "予定"), ("cart", "買い物"), ("gamecontroller", "あそび"),
    ]
    /// 選べる色 (名前, 画面に出す名前)
    static let folderColors: [(String, String)] = [
        ("accent", "標準"), ("red", "赤"), ("orange", "オレンジ"), ("yellow", "黄"), ("green", "緑"),
        ("teal", "青緑"), ("blue", "青"), ("purple", "紫"), ("pink", "ピンク"), ("brown", "茶"), ("gray", "グレー"),
    ]
    static func color(named n: String?) -> NSColor {
        switch n {
        case "red": return .systemRed
        case "orange": return .systemOrange
        case "yellow": return .systemYellow
        case "green": return .systemGreen
        case "teal": return .systemTeal
        case "blue": return .systemBlue
        case "purple": return .systemPurple
        case "pink": return .systemPink
        case "brown": return .systemBrown
        case "gray": return .systemGray
        default: return .controlAccentColor
        }
    }

    private static let iconsKey = "libraryFolderIcons"
    /// フォルダのアイコン (絵, 色の名前)。決めていなければ (folder, nil)
    static func folderIcon(_ rel: String) -> (symbol: String, color: String?) {
        let v = (UserDefaults.standard.dictionary(forKey: iconsKey) as? [String: String])?[rel] ?? ""
        let parts = v.components(separatedBy: "|")
        let sym = parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? "folder"
        let col = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        return (sym, col)
    }
    static func setFolderIcon(_ rel: String, symbol: String? = nil, color: String? = nil, reset: Bool = false) {
        var all = UserDefaults.standard.dictionary(forKey: iconsKey) as? [String: String] ?? [:]
        if reset {
            all.removeValue(forKey: rel)
        } else {
            let cur = folderIcon(rel)
            let sym = symbol ?? cur.symbol
            let col = color ?? cur.color ?? ""
            all[rel] = sym + "|" + (col == "accent" ? "" : col)
        }
        UserDefaults.standard.set(all, forKey: iconsKey)
        changed()
    }

    /// フォルダの並び (道すじの順)
    static var folderOrder: [String] {
        get { UserDefaults.standard.stringArray(forKey: "libraryFolderOrder") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "libraryFolderOrder"); changed() }
    }

    /// 左の欄で選んでいるもの: "all" = すべて / "root" = さとるエディタ直下 / "other" = ほかの場所 / "sub:道すじ"
    static var selectedGroup: String {
        get { UserDefaults.standard.string(forKey: "librarySelectedGroup") ?? "all" }
        set {
            UserDefaults.standard.set(newValue, forKey: "librarySelectedGroup")
            NotificationCenter.default.post(name: selectionDidChange, object: nil)
        }
    }
    static let selectionDidChange = Notification.Name("satoru.textLibrarySelectionDidChange")

    /// いくつも選んだフォルダ: "multi:" + 選んだものを改行でつないだもの
    static func multiKeys(_ sel: String) -> [String]? {
        sel.hasPrefix("multi:") ? sel.dropFirst(6).split(separator: "\n").map(String.init) : nil
    }

    static func matches(_ item: Item, _ sel: String) -> Bool {
        if let keys = multiKeys(sel) { return keys.contains { matches(item, $0) } }
        switch sel {
        case "all": return true
        case "root": return item.group == ""
        case "other": return item.group == nil && externalRoot(of: item.url) == nil
        case "shared": return item.sharedURL != nil   // リンクで公開共有しているもの
        case let k where k.hasPrefix("ext:"):
            let root = URL(fileURLWithPath: String(k.dropFirst(4))).standardizedFileURL.resolvingSymlinksInPath().path
            return item.url.path.hasPrefix(root + "/")
        default: return sel.hasPrefix("sub:") && item.group == String(sel.dropFirst(4))
        }
    }

    /// 新しい文書を自動で保存するフォルダ (左の欄で選んでいるフォルダ。ほかはさとるエディタ直下)
    static var targetFolder: URL {
        var sel = selectedGroup
        if let keys = multiKeys(sel) { sel = keys.first { $0.hasPrefix("sub:") || $0.hasPrefix("ext:") } ?? "root" }
        if sel.hasPrefix("ext:") {
            let u = URL(fileURLWithPath: String(sel.dropFirst(4)), isDirectory: true)
            var dir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &dir), dir.boolValue { return u }
        }
        if sel.hasPrefix("sub:") {
            let u = folderURL(String(sel.dropFirst(4)))
            var dir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &dir), dir.boolValue { return u }
        }
        return folder
    }

    /// 使えないフォルダ名なら nil
    static func cleanFolderName(_ s: String) -> String? {
        let n = String(s.unicodeScalars.filter { !"/\\:*?\"<>|".unicodeScalars.contains($0) && $0.value >= 0x20 }).trimmingCharacters(in: .whitespaces)
        return n.isEmpty || n.hasPrefix(".") ? nil : n
    }

    /// parent ("" = さとるエディタ直下) の中に新しいフォルダを作る。できたら道すじを返す
    @discardableResult
    static func createFolder(_ name: String, in parent: String = "") -> String? {
        guard let n = cleanFolderName(name) else { return nil }
        let rel = parent.isEmpty ? n : parent + "/" + n
        let u = folderURL(rel)
        guard !FileManager.default.fileExists(atPath: u.path) else { return nil }
        do { try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) } catch { return nil }
        changed()
        return rel
    }

    /// フォルダの場所が変わったとき: 覚えていること (作文か・ピン・並び・選択) と、開いている文書の場所を付け替える
    private static func relocate(from oldRel: String, to newRel: String) {
        ShareLink.repath(from: folderURL(oldRel), to: folderURL(newRel))
        VersionStore.repath(from: folderURL(oldRel), to: folderURL(newRel))
        let oldPath = folderURL(oldRel).standardizedFileURL.resolvingSymlinksInPath().path
        let newPath = folderURL(newRel).standardizedFileURL.resolvingSymlinksInPath().path
        func swap(_ p: String) -> String { p == oldPath || p.hasPrefix(oldPath + "/") ? newPath + p.dropFirst(oldPath.count) : p }
        func swapRel(_ r: String) -> String { r == oldRel || r.hasPrefix(oldRel + "/") ? newRel + r.dropFirst(oldRel.count) : r }
        let d = UserDefaults.standard
        if let modes = d.dictionary(forKey: modesKey) as? [String: String] {
            d.set(Dictionary(modes.map { (swap($0.key), $0.value) }, uniquingKeysWith: { a, _ in a }), forKey: modesKey)
        }
        d.set((d.stringArray(forKey: pinnedKey) ?? []).map(swap), forKey: pinnedKey)
        d.set(folderOrder.map(swapRel), forKey: "libraryFolderOrder")
        if let icons = d.dictionary(forKey: iconsKey) as? [String: String] {
            d.set(Dictionary(icons.map { (swapRel($0.key), $0.value) }, uniquingKeysWith: { a, _ in a }), forKey: iconsKey)
        }
        let sel = selectedGroup
        if sel.hasPrefix("sub:") { selectedGroup = "sub:" + swapRel(String(sel.dropFirst(4))) }
        for doc in NSDocumentController.shared.documents {
            guard let u = doc.fileURL else { continue }
            let p = u.standardizedFileURL.resolvingSymlinksInPath().path
            let q = swap(p)
            if q != p { doc.fileURL = URL(fileURLWithPath: q) }
        }
        changed()
    }

    /// フォルダの名前を変える (同じ親の中で)
    static func renameFolder(_ rel: String, to new: String) -> Bool {
        guard let n = cleanFolderName(new) else { return false }
        let parent = (rel as NSString).deletingLastPathComponent
        let newRel = parent.isEmpty ? n : parent + "/" + n
        guard newRel != rel, !FileManager.default.fileExists(atPath: folderURL(newRel).path) else { return false }
        do { try FileManager.default.moveItem(at: folderURL(rel), to: folderURL(newRel)) } catch { return false }
        relocate(from: rel, to: newRel)
        return true
    }

    /// フォルダを別のフォルダの中へ移す (parent: "" = さとるエディタ直下)。自分の中へは移せない
    @discardableResult
    static func moveFolder(_ rel: String, into parent: String) -> String? {
        let name = (rel as NSString).lastPathComponent
        let newRel = parent.isEmpty ? name : parent + "/" + name
        guard newRel != rel, parent != rel, !parent.hasPrefix(rel + "/"),
              !FileManager.default.fileExists(atPath: folderURL(newRel).path) else { return nil }
        do { try FileManager.default.moveItem(at: folderURL(rel), to: folderURL(newRel)) } catch { return nil }
        relocate(from: rel, to: newRel)
        return newRel
    }

    /// 確認の窓に出す、左寄せの名前の並び (多いときは 8 件まで + …)
    static func leftList(_ names: [String]) -> NSView {
        let text = names.prefix(8).map { "・" + $0 }.joined(separator: "\n") + (names.count > 8 ? "\n…" : "")
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = .systemFont(ofSize: 11)
        f.alignment = .left
        f.lineBreakMode = .byTruncatingMiddle
        f.maximumNumberOfLines = 9
        let w: CGFloat = 230
        f.preferredMaxLayoutWidth = w
        let h = ceil(f.sizeThatFits(NSSize(width: w, height: 1000)).height)
        f.frame = NSRect(x: 0, y: 0, width: w, height: h)
        return f
    }

    /// 文書を別のフォルダへ移す (group: "" = さとるエディタ直下、"旅行/京都" = その中のフォルダ)
    static func move(_ url: URL, toGroup g: String) {
        move(url, toDirectory: folderURL(g))
    }

    /// 左の一覧を出しているか (はじめは出さない: 起動したら左の欄のない、ふつうのエディタ)
    static var isVisible: Bool {
        EditorExtension.library.isOn && (UserDefaults.standard.object(forKey: visibleKey) as? Bool ?? false)
    }
    static func setVisible(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: visibleKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    // MARK: 開いた・保存したファイル

    private static var known: [String] {
        get { UserDefaults.standard.stringArray(forKey: knownKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(maxKnown)), forKey: knownKey) }
    }

    /// 開いた・保存したファイルを覚える (サーバの一時ファイルなどは呼ぶ側で外す)
    static func remember(_ url: URL) {
        guard url.isFileURL else { return }
        if isTemporary(url) || isNonTextType(url) { return }
        if externalRoot(of: url) != nil { changed(); return }   // 開いたフォルダの中のものは、もう一覧に出る (「ほかの場所」に足さない)
        let p = url.standardizedFileURL.path
        known = [p] + known.filter { $0 != p }
        changed()
    }

    /// 一時フォルダのファイル (ほかのアプリが渡したもの・動作確認) は一覧に入れない
    static func isTemporary(_ url: URL) -> Bool {
        let p = url.resolvingSymlinksInPath().path
        return ["/private/tmp/", "/tmp/", "/private/var/folders/", "/var/folders/"].contains { p.hasPrefix($0) }
    }

    /// はじめて使うとき: いままでの「最近使ったファイル」を一覧に入れておく
    static func seedFromRecents() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "librarySeeded") else { return }
        d.set(true, forKey: "librarySeeded")
        let recents = NSDocumentController.shared.recentDocumentURLs.filter { $0.isFileURL && !isTemporary($0) }.map { $0.standardizedFileURL.path }
        known = known + recents.filter { !known.contains($0) }
        changed()
    }

    /// 一覧から外す (ファイルは消さない)
    static func forget(_ url: URL) {
        let p = url.standardizedFileURL.path
        known = known.filter { $0 != p }
        changed()
    }

    private static var pending = false
    /// 一覧が変わったことを、少しまとめて知らせる
    static func changed() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pending = false
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    // MARK: 読み出し

    /// 一覧 (新しく書き換えたものが上)。重いので裏で呼ぶ
    /// 一覧に出すファイルの場所だけを集める (中身は読まない。速い)
    static func fileURLs() -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = []
        var seen = Set<String>()
        func add(_ u: URL) {
            let p = u.standardizedFileURL.resolvingSymlinksInPath().path
            guard !seen.contains(p) else { return }
            var dir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &dir), !dir.boolValue else { return }
            seen.insert(p)
            urls.append(URL(fileURLWithPath: p))
        }
        // さとるエディタのフォルダの中: 道すじはそろえてあるので、1 件ずつたどり直さない (ファイルが多くても速いように)
        let base = folder.standardizedFileURL.resolvingSymlinksInPath()
        for rel in [""] + subfolders() {
            let dir = rel.isEmpty ? base : base.appendingPathComponent(rel, isDirectory: true)
            downloadPlaceholders(in: dir)
            guard let list = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                         options: [.skipsHiddenFiles]) else { continue }
            for u in list {
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if v?.isSymbolicLink == true { add(u); continue }   // リンクは、たどった先で見る
                guard v?.isDirectory != true else { continue }
                let p = dir.path + "/" + u.lastPathComponent
                guard seen.insert(p).inserted else { continue }
                urls.append(URL(fileURLWithPath: p, isDirectory: false))
            }
        }
        known.forEach { add(URL(fileURLWithPath: $0)) }
        // 開いたフォルダの中 (中のフォルダも、3 段まで。多すぎるときは 2000 件まで)
        for root in externalFolders {
            guard let walker = fm.enumerator(at: URL(fileURLWithPath: root, isDirectory: true), includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var n = 0
            for case let u as URL in walker {
                if walker.level > 3 { walker.skipDescendants(); continue }
                guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                add(u)
                n += 1
                if n >= 2000 { break }
            }
        }
        return urls.filter { !isNonTextType($0) }
    }

    /// 一覧の中身。sel を渡すと、そのフォルダに入るものだけ読む (ほかのフォルダの中身は読まない)。
    /// 中身 (題名・本文のはじめ) を読むのは新しい順に contentLimit 件まで。それより古いものはファイル名だけで出す
    static func items(matching sel: String? = nil, contentLimit: Int = .max) -> [Item] {
        var urls = fileURLs()
        let ctx = ScanContext()
        if let sel = sel, sel != "all" { urls = urls.filter { ctx.matches($0.path, sel) } }
        let dated = urls.map { u in (u, (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        var items: [Item] = []
        items.reserveCapacity(dated.count)
        for (i, (u, date)) in dated.enumerated() {
            var it: Item
            if i < contentLimit {
                guard let x = item(for: u, group: ctx.group(u.path), modified: date) else { continue } // PDF・画像などテキストでないものは出さない
                it = x
            } else {
                let g = ctx.group(u.path)
                it = Item(url: u, title: g != nil ? u.deletingPathExtension().lastPathComponent : u.lastPathComponent, snippet: "",
                          modified: date, inFolder: g != nil, encrypted: false, group: g, mode: nil)
            }
            it.pinned = ctx.pinned.contains(u.path)
            it.locked = isLocked(u)
            it.sharedURL = ctx.shared[u.path]
            items.append(it)
        }
        return items.sorted { $0.pinned != $1.pinned ? $0.pinned : $0.modified > $1.modified }
    }

    /// たくさんのファイルを続けて見るときに、毎回読み直さないよう 1 回だけ読んでおく設定
    struct ScanContext {
        let root: String
        let rootSlash: String
        let externals: [String]
        let pinned: Set<String>
        let shared: [String: String]   // 道すじ → 公開中のリンク
        init() {
            root = TextLibrary.folder.standardizedFileURL.resolvingSymlinksInPath().path
            rootSlash = root + "/"
            externals = TextLibrary.externalFolders
            pinned = Set(UserDefaults.standard.stringArray(forKey: TextLibrary.pinnedKey) ?? [])
            var sh: [String: String] = [:]
            for r in ShareLink.records where r.isAlive { if let p = r.path, sh[p] == nil { sh[p] = r.url } }
            shared = sh
        }
        /// fileURLs() が返す道すじ (シンボリックリンクをたどった形) のフォルダ ("" = 直下、nil = 外)
        func group(_ path: String) -> String? {
            let parent = (path as NSString).deletingLastPathComponent
            if parent == root { return "" }
            guard parent.hasPrefix(rootSlash) else { return nil }
            return String(parent.dropFirst(rootSlash.count))
        }
        func externalRoot(_ path: String) -> String? { externals.filter { path.hasPrefix($0 + "/") }.max { $0.count < $1.count } }
        func matches(_ path: String, _ sel: String) -> Bool {
            if let keys = TextLibrary.multiKeys(sel) { return keys.contains { matches(path, $0) } }
            switch sel {
            case "all": return true
            case "root": return group(path) == ""
            case "other": return group(path) == nil && externalRoot(path) == nil
            case "shared": return shared[path] != nil
            case let k where k.hasPrefix("ext:"):
                let r = URL(fileURLWithPath: String(k.dropFirst(4))).standardizedFileURL.resolvingSymlinksInPath().path
                return path.hasPrefix(r + "/")
            default: return sel.hasPrefix("sub:") && group(path) == String(sel.dropFirst(4))
            }
        }
    }

    /// テキストとして扱わないファイル (PDF・画像・音・動画・圧縮ファイル・Office 文書など) か。拡張子で見る
    /// 拡張子ごとの答えを覚えておく (同じ拡張子のファイルがたくさんあっても、調べるのは 1 回)
    private static var nonTextCache: [String: Bool] = [:]
    private static let nonTextLock = NSLock()
    static func isNonTextType(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        nonTextLock.lock()
        if let hit = nonTextCache[ext] { nonTextLock.unlock(); return hit }
        nonTextLock.unlock()
        let r = computeNonTextType(ext)
        nonTextLock.lock(); nonTextCache[ext] = r; nonTextLock.unlock()
        return r
    }
    private static func computeNonTextType(_ ext: String) -> Bool {
        if ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "odt", "ods", "odp",
            "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "pkg", "app", "exe", "dll", "so", "dylib", "o", "class", "jar",
            "sqlite", "db", "bin", "dat", "iso", "psd", "ai", "sketch", "fig"].contains(ext) { return true }
        guard let t = UTType(filenameExtension: ext) else { return false }
        if t.conforms(to: .svg) { return false } // SVG は中身が文字
        return t.conforms(to: .image) || t.conforms(to: .audiovisualContent) || t.conforms(to: .archive)
            || t.conforms(to: .executable) || t.conforms(to: .font)
    }

    /// 一覧の 1 件。テキストでないもの (拡張子か中身がバイナリ) は nil
    private static func item(for url: URL, group g: String??  = .none, modified m: Date? = nil) -> Item? {
        if isNonTextType(url) { return nil }
        let modified = m ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let grp: String? = g ?? group(of: url)
        let head = (try? FileHandle(forReadingFrom: url)).map { h -> Data in
            defer { try? h.close() }
            return h.readData(ofLength: 6000)
        } ?? Data()
        let inFolder = grp != nil
        if !FileCrypto.isEncrypted(head) && BinaryData.looksBinary(head) { return nil }
        if FileCrypto.isEncrypted(head) {
            return Item(url: url, title: url.deletingPathExtension().lastPathComponent, snippet: "🔒 " + L("暗号化された文書"),
                        modified: modified, inFolder: inFolder, encrypted: true, group: grp, mode: nil)
        }
        // 先頭だけ切り出したので、最後の字が途中で切れていると UTF-8 と見分けられず、遅い判定に回ってしまう。
        // 切れた字のかけらを落としてから読む
        var sample = head
        if sample.count >= 6000 {
            var cut = 0
            while cut < 3, let last = sample.last, last & 0xC0 == 0x80 { sample.removeLast(); cut += 1 }
            if let last = sample.last, last >= 0xC0 { sample.removeLast() }
        }
        var text = (try? TextCodec.decode(sample))?.text ?? ""
        // 途中で切ったので、最後の 1 文字が壊れていることがある
        if text.hasSuffix("\u{FFFD}") { text.removeLast() }
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let firstLine = lines.first { !$0.isEmpty } ?? ""
        let title = inFolder ? (firstLine.isEmpty ? url.deletingPathExtension().lastPathComponent : String(firstLine.prefix(60))) : url.lastPathComponent
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = mode(for: url.standardizedFileURL.resolvingSymlinksInPath().path)
        // 作文は原稿用紙 1 枚ぶん (400 字と改行) を描けるよう、少し長めに持つ
        let isGenko = mode == "genko" || mode == "genkoH"
        let snippet = isGenko ? String(text.prefix(700)) : String(body.prefix(400))
        return Item(url: url, title: title, snippet: snippet, modified: modified, inFolder: inFolder, encrypted: false, group: grp, mode: mode)
    }

    /// 新しい文書を自動で保存するときのファイル名: 1 行目 (なければ日時) から作る。同じ名前があれば番号を付ける
    static func newFileURL(for text: String, in directory: URL? = nil) -> URL {
        let first = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        var base = String(first.unicodeScalars.filter { !"/\\:*?\"<>|".unicodeScalars.contains($0) && $0.value >= 0x20 }.prefix(30))
            .trimmingCharacters(in: .whitespaces)
        if base.isEmpty || base.hasPrefix(".") {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HHmm"
            base = L("メモ {0}", f.string(from: Date()))
        }
        let dir = directory ?? targetFolder
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent(base + ".txt")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n).txt")
            n += 1
        }
        return url
    }

    /// 題名の前の印 (ピン固定・ロック・公開中) を、字と同じ大きさの記号で付ける (絵文字だと大きく見えるため)
    static func markedTitle(_ item: Item, font: NSFont, name: String? = nil) -> NSAttributedString {
        let out = NSMutableAttributedString()
        // 公開中かどうかは、表示のしるし (原稿用紙・A4・エディタ) の右下に小さなリンクのバッジで出す
        let marks: [(Bool, String, NSColor)] = [(item.pinned, "pin.fill", .systemOrange), (item.locked, "lock.fill", .secondaryLabelColor)]
        for (on, sym, color) in marks where on {
            guard let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: font.pointSize * 0.85, weight: .semibold)) else { continue }
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r)
                color.set()
                r.fill(using: .sourceAtop)
                return true
            }
            let a = NSTextAttachment()
            a.image = tinted
            // 字の高さの真ん中にそろえる
            a.bounds = NSRect(x: 0, y: (font.capHeight - img.size.height) / 2, width: img.size.width, height: img.size.height)
            out.append(NSAttributedString(attachment: a))
            out.append(NSAttributedString(string: " "))
        }
        // 原稿用紙の文書: 小さな原稿用紙のしるし (縦書きは朱、横書きは緑)
        if item.mode == "genko" || item.mode == "genkoH" {
            let img = withShareBadge(genkoMark(size: round(font.pointSize * 0.95), horizontal: item.mode == "genkoH"), item.sharedURL != nil && EditorExtension.publish.isOn)
            let a = NSTextAttachment()
            a.image = img
            a.bounds = NSRect(x: 0, y: (font.capHeight - img.size.height) / 2, width: img.size.width, height: img.size.height)
            out.append(NSAttributedString(attachment: a))
            out.append(NSAttributedString(string: " "))
        } else {
            // A4用紙の文書は紙のしるし、標準エディタの文書はエディタのしるし (行番号の欄と行)
            let img = withShareBadge(pageMark(size: round(font.pointSize * 0.95), lines: item.mode != "a4"),
                                     item.sharedURL != nil && EditorExtension.publish.isOn)
            let a = NSTextAttachment()
            a.image = img
            a.bounds = NSRect(x: 0, y: (font.capHeight - img.size.height) / 2, width: img.size.width, height: img.size.height)
            out.append(NSAttributedString(attachment: a))
            out.append(NSAttributedString(string: " "))
        }
        out.append(NSAttributedString(string: name ?? item.title))
        out.addAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: NSRange(location: 0, length: out.length))
        return out
    }

    /// 公開中のしるし: アイコンの右下に、丸い小さなリンクのバッジを重ねる (少し外にはみ出すので、そのぶん絵を広げる)
    static func withShareBadge(_ base: NSImage, _ shared: Bool) -> NSImage {
        guard shared else { return base }
        let s = base.size
        let b = round(s.width * 0.62)
        let out = NSSize(width: s.width + b * 0.3, height: s.height + b * 0.25)
        return NSImage(size: out, flipped: false) { _ in
            base.draw(in: NSRect(x: 0, y: out.height - s.height, width: s.width, height: s.height))
            let circle = NSRect(x: out.width - b, y: 0, width: b, height: b)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: circle).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.4, dy: 0.4))
            ring.lineWidth = 0.8
            ring.stroke()
            if let sym = NSImage(systemSymbolName: "link", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: b * 0.55, weight: .bold)) {
                let r = NSRect(x: circle.midX - sym.size.width / 2, y: circle.midY - sym.size.height / 2, width: sym.size.width, height: sym.size.height)
                let white = NSImage(size: sym.size, flipped: false) { rr in
                    sym.draw(in: rr)
                    NSColor.white.set()
                    rr.fill(using: .sourceAtop)
                    return true
                }
                white.draw(in: r)
            }
            return true
        }
    }

    /// 紙のしるし: 縦長の白い紙 (右上を折ったかたち)。lines = 横書きの行を 3 本 (標準エディタ)、なし = A4用紙
    static func pageMark(size: CGFloat, lines withLines: Bool) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { r in
            let color = NSColor(srgbRed: 0.33, green: 0.42, blue: 0.62, alpha: 1)
            let w = r.height * 0.74
            let page = NSRect(x: r.midX - w / 2, y: r.minY + 0.6, width: w, height: r.height - 1.2)
            let fold = page.width * 0.32
            let path = NSBezierPath()
            path.move(to: NSPoint(x: page.minX, y: page.minY))
            path.line(to: NSPoint(x: page.maxX - fold, y: page.minY))
            path.line(to: NSPoint(x: page.maxX, y: page.minY + fold))
            path.line(to: NSPoint(x: page.maxX, y: page.maxY))
            path.line(to: NSPoint(x: page.minX, y: page.maxY))
            path.close()
            NSColor.white.setFill()
            path.fill()
            color.setStroke()
            path.lineWidth = 1.1
            path.stroke()
            guard withLines else { return true }
            let lines = NSBezierPath()
            lines.lineWidth = 0.9
            for k in 0..<3 {
                let y = page.minY + page.height * (0.42 + CGFloat(k) * 0.18)
                lines.move(to: NSPoint(x: page.minX + 2, y: y))
                lines.line(to: NSPoint(x: page.maxX - (k == 2 ? page.width * 0.4 : 2), y: y))
            }
            lines.stroke()
            return true
        }
    }

    /// 原稿用紙のしるし: 枠と 3×3 のマス (縦書きは列のすき間、横書きは行のすき間つき)
    static func genkoMark(size: CGFloat, horizontal: Bool) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { r in
            let color = GenkoRenderer.lineColor(horizontal: horizontal)
            let box = r.insetBy(dx: 0.75, dy: 0.75)
            GenkoRenderer.paperColor.setFill()
            NSBezierPath(rect: box).fill()
            color.setStroke()
            let frame = NSBezierPath(rect: box)
            frame.lineWidth = 1.1
            frame.stroke()
            let grid = NSBezierPath()
            grid.lineWidth = 0.7
            for i in 1..<3 {
                let t = CGFloat(i) / 3
                if horizontal {
                    // 横書き: 行 (横線は 2 本ずつ = 行のすき間)、縦はマス
                    let y = box.minY + box.height * t
                    grid.move(to: NSPoint(x: box.minX, y: y - 0.8)); grid.line(to: NSPoint(x: box.maxX, y: y - 0.8))
                    grid.move(to: NSPoint(x: box.minX, y: y + 0.8)); grid.line(to: NSPoint(x: box.maxX, y: y + 0.8))
                    let x = box.minX + box.width * t
                    grid.move(to: NSPoint(x: x, y: box.minY)); grid.line(to: NSPoint(x: x, y: box.maxY))
                } else {
                    // 縦書き: 列 (縦線は 2 本ずつ = 列のすき間)、横はマス
                    let x = box.minX + box.width * t
                    grid.move(to: NSPoint(x: x - 0.8, y: box.minY)); grid.line(to: NSPoint(x: x - 0.8, y: box.maxY))
                    grid.move(to: NSPoint(x: x + 0.8, y: box.minY)); grid.line(to: NSPoint(x: x + 0.8, y: box.maxY))
                    let y = box.minY + box.height * t
                    grid.move(to: NSPoint(x: box.minX, y: y)); grid.line(to: NSPoint(x: box.maxX, y: y))
                }
            }
            grid.stroke()
            return true
        }
    }

    /// まだ何も書いていない新規テキストのファイル名 (書き始めたら 1 行目の名前に付け替える)
    static let blankBaseName = "新規テキスト"
    static func isBlankPlaceholder(_ url: URL?) -> Bool {
        guard let u = url, isManaged(u) else { return false }
        let name = u.deletingPathExtension().lastPathComponent
        return name == blankBaseName || name.hasPrefix(blankBaseName + " ")
    }

    /// 空のテキストを作って一覧に入れ、開く (メモ帳の「新規メモ」と同じ)
    static func createBlankText() {
        let dir = targetFolder
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent(blankBaseName + ".txt")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(blankBaseName) \(n).txt")
            n += 1
        }
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else { NSSound.beep(); return }
        // 新しい文書は、そのとき使っていた表示 (原稿用紙など) で始める
        if let last = UserDefaults.standard.string(forKey: "lastPaperMode"), last == "genko" {
            setMode(UserDefaults.standard.bool(forKey: "genkoHorizontal") ? "genkoH" : "genko", for: url)
        }
        changed()
        open(url)
    }

    /// 日時の表示: 「たった今」「5 分前」「3 時間前」「昨日」「4 日前」、それより前は月日 (去年より前は年月日)
    static func dateText(_ d: Date) -> String {
        let cal = Calendar.current
        let sec = Date().timeIntervalSince(d)
        if sec < 60 { return L("たった今") }
        if sec < 3600 { return L("{0} 分前", Int(sec / 60)) }
        if sec < 86400 { return L("{0} 時間前", Int(sec / 3600)) }
        if cal.isDateInYesterday(d) { return L("昨日") }
        if sec < 7 * 86400 { return L("{0} 日前", max(2, Int(sec / 86400))) }
        let f = DateFormatter()
        f.locale = Locale.current
        if cal.component(.year, from: d) == cal.component(.year, from: Date()) {
            f.setLocalizedDateFormatFromTemplate("MMMd")
        } else {
            f.setLocalizedDateFormatFromTemplate("yMMMd")
        }
        return f.string(from: d)
    }

    /// 一覧から開く。いま前にあるタブが「見ただけ」(開いてから書き換えていない) なら、
    /// タブを増やさずにそのタブを次の文書に切り替える (ザッピングでタブが増えないように)
    static func open(_ url: URL) {
        let dc = NSDocumentController.shared
        let front = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.orderedWindows.first { $0.windowController is EditorWindowController }
        if dc.document(for: url) == nil, let ed = front?.frontEditor,
           let old = ed.hdoc, old.canBeReplacedByBrowsing, let oldWindow = ed.presentingWindow {
            // タブはそのまま、中身だけ入れ替える
            if old.switchContents(to: url) {
                oldWindow.makeKeyAndOrderFront(nil)
                // 一覧は読み直さない (選んでいる行は、ウインドウが文書の入れ替えを受けて付け直す)
                return
            }
        }
        dc.openDocument(withContentsOf: url, display: true) { _, _, err in
            if let e = err as NSError?, e.code != NSUserCancelledError { NSApp.presentError(e) }
        }
    }

    // MARK: 欄の幅 (右の端をドラッグして変える)

    /// 欄の幅を、覚えた値で決め、右の端にドラッグでつかめる細い帯を付ける
    static func makeResizable(_ view: NSView, key: String, width: CGFloat, min: CGFloat, max: CGFloat) {
        let saved = CGFloat(UserDefaults.standard.double(forKey: key))
        let wc = view.widthAnchor.constraint(equalToConstant: saved >= min && saved <= max ? saved : width)
        wc.isActive = true
        objc_setAssociatedObject(view, &panelWidthKey, wc, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let handle = PanelResizeHandle()
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.toolTip = L("ドラッグで幅を変える")
        // 中身を並べ終えてから、いちばん上に置く (下に隠れるとつかめない)
        DispatchQueue.main.async {
            view.addSubview(handle, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                handle.topAnchor.constraint(equalTo: view.topAnchor),
                handle.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                handle.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                handle.widthAnchor.constraint(equalToConstant: 5),
            ])
        }
        // 上下 2 段のときのフォルダの欄は、自分の幅を持たない (下のテキスト一覧に合わせる): そのときは一覧の幅を動かす
        handle.onDrag = { [weak view] dx in
            if !wc.isActive, let v = view, let other = resizeLink(of: v) { resizeHandle(of: other)?.onDrag?(dx); return }
            wc.constant = Swift.min(max, Swift.max(min, wc.constant + dx))
        }
        handle.onEnd = { [weak view] in
            if !wc.isActive, let v = view, let other = resizeLink(of: v) { resizeHandle(of: other)?.onEnd?(); return }
            UserDefaults.standard.set(Double(wc.constant), forKey: key)
        }
        objc_setAssociatedObject(view, &panelHandleKey, handle, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// 幅を動かすつまみ
    static func resizeHandle(of view: NSView) -> PanelResizeHandle? {
        objc_getAssociatedObject(view, &panelHandleKey) as? PanelResizeHandle
    }
    /// 自分の幅の決まりを外しているとき、代わりに幅を動かす欄 (弱く覚える)
    private final class WeakBox { weak var view: NSView?; init(_ v: NSView?) { view = v } }
    static func setResizeLink(_ view: NSView, to other: NSView?) {
        objc_setAssociatedObject(view, &panelLinkKey, WeakBox(other), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    static func resizeLink(of view: NSView) -> NSView? {
        (objc_getAssociatedObject(view, &panelLinkKey) as? WeakBox)?.view
    }

    /// 欄の幅の決まり (1 列にするとき、フォルダの欄の幅を外すため)
    static func widthConstraint(of view: NSView) -> NSLayoutConstraint? {
        objc_getAssociatedObject(view, &panelWidthKey) as? NSLayoutConstraint
    }

    /// 1 列にする (フォルダの欄を一覧の上に重ねる)。2 列 = 横に並べる
    static let oneColumnKey = "libraryOneColumn"
    static var oneColumn: Bool {
        // はじめは上下 (上にテキストの一覧、下にフォルダの欄)
        get { UserDefaults.standard.object(forKey: oneColumnKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: oneColumnKey); NotificationCenter.default.post(name: layoutDidChange, object: nil) }
    }
    static let layoutDidChange = Notification.Name("satoru.textLibraryLayoutDidChange")

    /// いくつも選んだときの右クリックのメニュー (まとめて削除・ピン・ロック・移動)
    static func multiMenu(for urls: [URL], target: AnyObject) -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ action: Selector?, _ symbol: String?, object: Any?, to menu: NSMenu? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = target
            i.representedObject = object
            if let sym = symbol { i.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil) }
            (menu ?? m).addItem(i)
            return i
        }
        let head = add(L("{0} 件を選んでいます", urls.count), nil, "checkmark.circle", object: nil)
        head.isEnabled = false
        m.addItem(.separator())
        let pinned = urls.allSatisfy { isPinned($0) }, locked = urls.allSatisfy { isLocked($0) }
        _ = add(pinned ? L("ピン固定を外す") : L("ピン固定 (いちばん上に)"), #selector(TextLibraryActions.pinMany(_:)), pinned ? "pin.slash" : "pin", object: urls)
        _ = add(locked ? L("ロックを外す") : L("ロック (書き換え・削除を防ぐ)"), #selector(TextLibraryActions.lockMany(_:)), locked ? "lock.open" : "lock", object: urls)
        let sub = NSMenu()
        let folders = subfolders().map { rel -> (String, String) in
            let depth = rel.components(separatedBy: "/").count - 1
            return (String(repeating: "\u{3000}", count: depth) + (rel as NSString).lastPathComponent, rel)
        }
        for (name, g) in [(rootName, "")] + folders {
            _ = add(name, #selector(TextLibraryActions.moveMany(_:)), "folder", object: [urls, g] as [Any], to: sub)
        }
        let mv = add(L("移動"), nil, "folder", object: nil)
        mv.submenu = sub
        m.addItem(.separator())
        _ = add(L("{0} 件を削除…", urls.count), #selector(TextLibraryActions.trashMany(_:)), "trash", object: urls)
        return m
    }

    // MARK: ピン固定・ロック・複製・移動・削除

    private static let pinnedKey = "libraryPinned"
    static func isPinned(_ url: URL) -> Bool {
        (UserDefaults.standard.stringArray(forKey: pinnedKey) ?? []).contains(url.standardizedFileURL.resolvingSymlinksInPath().path)
    }
    static func setPinned(_ on: Bool, _ url: URL) {
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        var list = (UserDefaults.standard.stringArray(forKey: pinnedKey) ?? []).filter { $0 != p }
        if on { list.insert(p, at: 0) }
        UserDefaults.standard.set(list, forKey: pinnedKey)
        changed()
    }

    /// ロック (Finder の「ロック」と同じ。書き換え・削除ができなくなる)
    static func isLocked(_ url: URL) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.immutable] as? Bool) ?? false
    }
    static func setLocked(_ on: Bool, _ url: URL) {
        try? FileManager.default.setAttributes([.immutable: on], ofItemAtPath: url.path)
        changed()
    }

    /// 同じフォルダに「〜 のコピー」を作る
    @discardableResult
    static func duplicate(_ url: URL) -> URL? {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        func name(_ n: Int) -> String { (n == 1 ? L("{0} のコピー", base) : L("{0} のコピー {1}", base, n)) + (ext.isEmpty ? "" : "." + ext) }
        var n = 1
        var to = dir.appendingPathComponent(name(n))
        while FileManager.default.fileExists(atPath: to.path) { n += 1; to = dir.appendingPathComponent(name(n)) }
        do { try FileManager.default.copyItem(at: url, to: to) } catch { NSApp.presentError(error); return nil }
        // コピーはロックしない
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: to.path)
        if !isInFolder(to) { remember(to) }
        if let m = mode(for: url.standardizedFileURL.resolvingSymlinksInPath().path) { setMode(m, for: to) }
        changed()
        return to
    }

    /// ファイルの名前を変える (同じ場所のまま。別名で保存ではなく、元のファイルそのものの名前を変える)。
    /// 拡張子を書かなければ、今の拡張子のまま。開いている文書は、そのまま新しい名前で編集を続けられる
    @discardableResult
    static func rename(_ url: URL, to newName: String, window: NSWindow? = nil) -> Bool {
        var name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        name = String(name.unicodeScalars.filter { !"/:".unicodeScalars.contains($0) && $0.value >= 0x20 })
        guard !name.isEmpty, !name.hasPrefix(".") else { NSSound.beep(); return false }
        if (name as NSString).pathExtension.isEmpty, !url.pathExtension.isEmpty { name += "." + url.pathExtension }
        let to = url.deletingLastPathComponent().appendingPathComponent(name)
        guard to.lastPathComponent != url.lastPathComponent else { return true }
        if FileManager.default.fileExists(atPath: to.path), to.path.lowercased() != url.path.lowercased() {
            let a = NSAlert()
            a.messageText = L("「{0}」はもうあります", name)
            a.informativeText = L("ほかの名前にしてください。")
            if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
            return false
        }
        if isLocked(url) {
            let a = NSAlert()
            a.messageText = L("ロックしているので名前を変えられません")
            if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
            return false
        }
        let pinned = isPinned(url), m = mode(for: url.standardizedFileURL.resolvingSymlinksInPath().path)
        let finish = {
            ShareLink.repath(from: url, to: to)
            VersionStore.repath(from: url, to: to)
            forget(url)
            if !isInFolder(to) { remember(to) }
            if pinned { setPinned(false, url); setPinned(true, to) }
            if let m = m { setMode(m, for: to) }
            changed()
        }
        if let doc = NSDocumentController.shared.document(for: url) {
            doc.move(to: to) { err in
                if let e = err { NSApp.presentError(e) } else { finish() }
            }
        } else {
            do { try FileManager.default.moveItem(at: url, to: to); finish() } catch { NSApp.presentError(error); return false }
        }
        return true
    }

    /// 名前を聞いて変える (ファイル > 名前を変更…・一覧の右クリック)
    static func askRename(_ url: URL, window: NSWindow?) {
        let a = NSAlert()
        a.messageText = L("ファイルの名前を変更")
        a.informativeText = L("元のファイルの名前を変えます (中身はそのまま)。")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        f.stringValue = url.lastPathComponent
        a.accessoryView = f
        a.addButton(withTitle: L("変更"))
        a.addButton(withTitle: L("キャンセル"))
        a.window.initialFirstResponder = f
        // 拡張子の前までを選んでおく (すぐ打ち直せるように)
        DispatchQueue.main.async {
            let base = (url.lastPathComponent as NSString).deletingPathExtension as NSString
            f.currentEditor()?.selectedRange = NSRange(location: 0, length: base.length)
        }
        let handle: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .alertFirstButtonReturn else { return }
            rename(url, to: f.stringValue, window: window)
        }
        if let w = window { a.beginSheetModal(for: w, completionHandler: handle) } else { handle(a.runModal()) }
    }

    /// 好きな場所 (フォルダ) へ移す。開いている文書は、そのまま新しい場所で編集を続けられる
    static func move(_ url: URL, toDirectory dir: URL) {
        var to = dir.appendingPathComponent(url.lastPathComponent)
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: to.path) {
            to = dir.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : "." + ext))
            n += 1
        }
        let pinned = isPinned(url), m = mode(for: url.standardizedFileURL.resolvingSymlinksInPath().path)
        let finish = {
            ShareLink.repath(from: url, to: to)
            VersionStore.repath(from: url, to: to)
            forget(url)
            if !isInFolder(to) { remember(to) }
            if pinned { setPinned(false, url); setPinned(true, to) }
            if let m = m { setMode(m, for: to) }
            changed()
        }
        if let doc = NSDocumentController.shared.document(for: url) {
            doc.move(to: to) { err in if err == nil { finish() } }
        } else {
            do { try FileManager.default.moveItem(at: url, to: to); finish() } catch { NSApp.presentError(error) }
        }
    }

    /// ファイルの種類の説明: 「テキスト (.txt)・原稿用紙 (縦書き)」のように
    static func kindText(_ item: Item) -> String {
        let ext = item.url.pathExtension.lowercased()
        let type = ext.isEmpty ? L("テキスト") : (ext == "txt" ? L("テキスト") : L("{0} ファイル", ext.uppercased())) + " (." + ext + ")"
        var parts = [item.encrypted ? L("暗号化された文書") : type]
        switch item.mode {
        case "genko": parts.append(L("原稿用紙 (縦書き)"))
        case "genkoH": parts.append(L("原稿用紙 (横書き)"))
        case "a4": parts.append(L("A4用紙"))
        default: break
        }
        return parts.joined(separator: L("・"))
    }

    /// 右クリックのメニュー (左の一覧とカードで同じもの)
    static func contextMenu(for item: Item, target: AnyObject) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        @discardableResult
        func add(_ title: String, _ action: Selector, _ symbol: String? = nil, to menu: NSMenu? = nil, object: Any? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = target
            i.representedObject = object ?? item.url
            if let sym = symbol { i.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil) }
            (menu ?? m).addItem(i)
            return i
        }
        let locked = isLocked(item.url)
        // いちばん上に、更新日時とファイルの種類をすぐ見えるように出す (押せない見出し)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy/MM/dd HH:mm"
        for (sym, text) in [("clock", L("更新：{0}", dateText(item.modified) + "  (" + df.string(from: item.modified) + ")")), ("doc", L("種類：{0}", kindText(item)))] {
            let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            i.isEnabled = false
            i.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
            m.addItem(i)
        }
        // 履歴: 数と最新の日時を出し、押すと履歴の推移 (版の一覧) の窓を開く
        if VersionStore.isOn && VersionStore.gitAvailable && !item.encrypted {
            let versions = VersionStore.history(item.url)
            let h = NSMenuItem(title: versions.isEmpty ? L("履歴：まだありません") : L("履歴：{0} 個 (最新 {1})", versions.count, dateText(versions[0].date)),
                               action: #selector(TextLibraryActions.showVersions(_:)), keyEquivalent: "")
            h.target = target
            h.representedObject = item.url
            h.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
            if versions.isEmpty { h.action = nil }   // まだ無いときは押せない
            m.addItem(h)
        }
        if EditorExtension.publish.isOn, let r = ShareLink.record(for: item.url) {
            // 公開中: リンクを押すとブラウザで開く。コピー・公開をやめる
            add(L("公開中ページ表示（id:{0}）", r.id), #selector(TextLibraryActions.openShareLink(_:)), "safari", object: r.url)
            add(L("リンクをコピー"), #selector(TextLibraryActions.copyShareLink(_:)), "doc.on.doc", object: r.url)
            // 公開してから書き換えたときだけ押せる
            let up = add(L("公開中のページを更新（変更を反映）"), #selector(TextLibraryActions.updateShare(_:)), "arrow.triangle.2.circlepath")
            if let (text, _, mode) = TextLibraryActions.shareContent(item.url), !ShareLink.needsUpdate(r, text: text, mode: mode) { up.action = nil }
            add(L("公開の設定…"), #selector(TextLibraryActions.publishSettings(_:)), "slider.horizontal.3")
            add(L("公開をやめる"), #selector(TextLibraryActions.unpublishItem(_:)), "link.badge.plus")
        }
        m.addItem(.separator())
        add(L("開く"), #selector(TextLibraryActions.openItem(_:)), "doc.text")
        add(L("Finder で表示"), #selector(TextLibraryActions.revealItem(_:)), "folder")
        add(L("ファイルの情報…"), #selector(TextLibraryActions.showInfo(_:)), "info.circle")
        add(L("名前を変更…"), #selector(TextLibraryActions.renameItem(_:)), "pencil")
        if !item.encrypted && EditorExtension.publish.isOn { add(L("リンクで公開共有…"), #selector(TextLibraryActions.shareItem(_:)), "link") }
        m.addItem(.separator())
        add(item.pinned ? L("ピン固定を外す") : L("ピン固定 (いちばん上に)"), #selector(TextLibraryActions.togglePin(_:)), item.pinned ? "pin.slash" : "pin")
        add(locked ? L("ロックを外す") : L("ロック (書き換え・削除を防ぐ)"), #selector(TextLibraryActions.toggleLock(_:)), locked ? "lock.open" : "lock")
        add(L("複製"), #selector(TextLibraryActions.duplicateItem(_:)), "plus.square.on.square")
        // 移動: さとるエディタのフォルダ、または好きな場所
        let sub = NSMenu()
        // 中のフォルダは字下げして、木の形がわかるように
        let folders = subfolders().map { rel -> (String, String) in
            let depth = rel.components(separatedBy: "/").count - 1
            return (String(repeating: "　", count: depth) + (rel as NSString).lastPathComponent, rel)
        }
        for (name, g) in [(rootName, "")] + folders where g != item.group {
            add(name, #selector(TextLibraryActions.moveItem(_:)), "folder", to: sub, object: [item.url, g] as [Any])
        }
        if !sub.items.isEmpty { sub.addItem(.separator()) }
        add(L("ほかの場所を選ぶ…"), #selector(TextLibraryActions.moveElsewhere(_:)), "folder.badge.plus", to: sub)
        let holder = NSMenuItem(title: L("移動"), action: nil, keyEquivalent: "")
        holder.image = NSImage(systemSymbolName: "arrow.right.doc.on.clipboard", accessibilityDescription: nil)
        holder.submenu = sub
        holder.isEnabled = !locked
        m.addItem(holder)
        m.addItem(.separator())
        if !item.inFolder {
            add(L("一覧から外す (ファイルは残す)"), #selector(TextLibraryActions.forgetItem(_:)), "minus.circle")
        }
        add(L("削除 (ゴミ箱に入れる)"), #selector(TextLibraryActions.trashItem(_:)), "trash").isEnabled = !locked
        return m
    }
}

/// 右クリックのメニューの動作
final class TextLibraryActions: NSObject {
    static let shared = TextLibraryActions()

    @objc func openItem(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { TextLibrary.open(u) }
    }
    @objc func revealItem(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }
    /// ファイルの情報: 名前・場所・大きさ・字数・行数・文字コード・改行・作った日・変えた日・表示 (作文か)・ピン・ロック
    @objc func showInfo(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL else { return }
        let fm = FileManager.default
        let attrs = (try? fm.attributesOfItem(atPath: u.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy/MM/dd HH:mm"
        func date(_ k: FileAttributeKey) -> String { (attrs[k] as? Date).map { df.string(from: $0) } ?? "—" }
        var lines: [(String, String)] = [
            (L("場所"), (u.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath),
            (L("大きさ"), ByteCountFormatter.string(fromByteCount: size, countStyle: .file)),
        ]
        let data = size <= 50 * 1_048_576 ? (try? Data(contentsOf: u)) : nil
        if let data = data, FileCrypto.isEncrypted(data) {
            lines.append((L("中身"), "🔒 " + L("暗号化された文書")))
        } else if let data = data, let d = try? TextCodec.decode(data) {
            let text = d.text
            let lineCount = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
            lines.append((L("字数"), L("{0} 字", Genko.characterCount(text))))
            lines.append((L("行数"), L("{0} 行", lineCount)))
            lines.append((L("文字コード"), d.encoding.displayName))
            lines.append((L("改行コード"), d.lineEnding.displayName))
            let mode = TextLibrary.mode(for: u.standardizedFileURL.resolvingSymlinksInPath().path)
            if mode == "genko" || mode == "genkoH" {
                let cols = Genko.layout(text, autoFormat: mode == "genko" && UserDefaults.standard.bool(forKey: "genkoAutoFormat"))
                lines.append((L("表示"), (mode == "genkoH" ? L("原稿用紙 (横書き)") : L("原稿用紙 (縦書き)")) + "  " + L("{0} 枚", Genko.sheetCount(cols))))
            } else {
                lines.append((L("表示"), mode == "a4" ? L("A4用紙") : L("標準エディタ")))
            }
        }
        lines.append((L("作成日時"), date(.creationDate)))
        lines.append((L("更新日時"), date(.modificationDate)))
        if let r = ShareLink.record(for: u) {
            lines.append((L("共有リンク"), r.url + "\n" + ShareLink.visibilityName(r.visibility)
                + (r.expires.map { "  " + L("期限 {0}", df.string(from: $0)) } ?? "")))
        }
        var marks: [String] = []
        if TextLibrary.isPinned(u) { marks.append("📌 " + L("ピン固定")) }
        if TextLibrary.isLocked(u) { marks.append("🔒 " + L("ロック")) }
        if !marks.isEmpty { lines.append((L("印"), marks.joined(separator: "  "))) }
        let a = NSAlert()
        a.messageText = u.lastPathComponent
        // 項目を左寄せで並べる (ふつうの説明文は真ん中寄せになるので、表を別に作る)
        let grid = NSGridView(views: lines.map { pair -> [NSView] in
            let k = NSTextField(labelWithString: pair.0)
            k.textColor = .secondaryLabelColor
            k.font = .systemFont(ofSize: 12)
            let v = NSTextField(wrappingLabelWithString: pair.1)
            v.font = .systemFont(ofSize: 12)
            v.isSelectable = true
            v.preferredMaxLayoutWidth = 280
            return [k, v]
        })
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading
        grid.rowSpacing = 4
        grid.columnSpacing = 10
        grid.setFrameSize(grid.fittingSize)
        a.accessoryView = grid
        a.icon = NSWorkspace.shared.icon(forFile: u.path)
        a.addButton(withTitle: L("閉じる"))
        a.addButton(withTitle: L("Finder で表示"))
        if a.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([u]) }
    }

    /// リンクで公開 (開いていなくても、ファイルの中身を読んで公開する)
    @objc func shareItem(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL, let (text, title, mode) = Self.shareContent(u) else { NSSound.beep(); return }
        ShareLink.share(text: text, suggestedTitle: title, mode: mode, file: u, from: NSApp.keyWindow)
    }

    /// 公開の設定 (公開のしかた・パスワード・期限・題名) を変える
    @objc func publishSettings(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL, let r = ShareLink.record(for: u) else { return }
        ShareLink.editSettings(r, window: NSApp.keyWindow)
    }

    /// 公開中のページを、今の内容に更新する
    @objc func updateShare(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL, let r = ShareLink.record(for: u),
              let (text, _, mode) = Self.shareContent(u) else { NSSound.beep(); return }
        let w = NSApp.keyWindow
        ShareLink.confirmPrivacy(text, window: w, file: u) { ShareLink.update(r, text: text, mode: mode, window: w) }
    }

    /// 公開する中身: 開いていれば画面の文章、なければファイル。題名の候補と、表示 (作文・エディタなど)
    static func shareContent(_ u: URL) -> (String, String, String)? {
        let text: String
        if let doc = NSDocumentController.shared.document(for: u) as? Document, let tv = doc.editor?.textView {
            text = tv.string
        } else if let data = try? Data(contentsOf: u), !FileCrypto.isEncrypted(data), let d = try? TextCodec.decode(data) {
            text = d.text
        } else {
            return nil
        }
        let m = TextLibrary.mode(for: u.standardizedFileURL.resolvingSymlinksInPath().path)
        let mode = m == "genko" || m == "genkoH" ? m! : m == "a4" ? "text" : "editor"
        let first = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return (text, String((first.isEmpty ? u.deletingPathExtension().lastPathComponent : first).prefix(60)), mode)
    }

    @objc func openShareLink(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let u = URL(string: s) else { return }
        NSWorkspace.shared.open(u)
    }
    @objc func copyShareLink(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
    @objc func unpublishItem(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL, let r = ShareLink.record(for: u) else { return }
        let a = NSAlert()
        a.messageText = L("「{0}」の公開をやめますか？", r.title.isEmpty ? r.url : r.title)
        a.informativeText = L("リンクを開いても読めなくなります。")
        a.addButton(withTitle: L("公開をやめる"))
        a.addButton(withTitle: L("キャンセル"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        ShareLink.unpublish(r) { _ in SharedLinksWindow.shared.reload() }  // 失敗したときは unpublish が知らせる
    }

    /// 右クリックに出した版を押した: 履歴の窓で、その版を選んで見せる
    @objc func showVersion(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? [Any], let u = a.first as? URL, let c = a.last as? String else { return }
        VersionHistoryWindowController.show(for: u, select: c)
    }

    @objc func showVersions(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL else { return }
        guard VersionStore.gitAvailable else { return VersionStore.explainMissingGit(NSApp.keyWindow) }
        VersionHistoryWindowController.show(for: u)
    }

    @objc func togglePin(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { TextLibrary.setPinned(!TextLibrary.isPinned(u), u) }
    }
    @objc func toggleLock(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL else { return }
        let lock = !TextLibrary.isLocked(u)
        // 書きかけがあれば、ロックする前に保存しておく
        if lock, let doc = NSDocumentController.shared.document(for: u), doc.isDocumentEdited {
            doc.save(nil)
        }
        TextLibrary.setLocked(lock, u)
    }
    @objc func renameItem(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { TextLibrary.askRename(u, window: NSApp.keyWindow) }
    }
    @objc func duplicateItem(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { TextLibrary.duplicate(u) }
    }
    @objc func moveItem(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? [Any], let u = a.first as? URL, let g = a.last as? String else { return }
        TextLibrary.move(u, toGroup: g)
    }
    @objc func moveElsewhere(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("ここに移動")
        panel.message = L("「{0}」を移す場所を選んでください", u.lastPathComponent)
        panel.directoryURL = u.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        TextLibrary.move(u, toDirectory: dir)
    }
    @objc func forgetItem(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { TextLibrary.forget(u) }
    }
    @objc func trashItem(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { trash([u]) }
    }

    /// ゴミ箱に入れる (いくつでも。聞くのは 1 回。ロックしたものは入れない)
    func trash(_ urls: [URL]) {
        let locked = urls.filter { TextLibrary.isLocked($0) }
        let targets = urls.filter { !TextLibrary.isLocked($0) }
        guard !targets.isEmpty else {
            let a = NSAlert()
            a.messageText = L("ロックしているので削除できません")
            a.informativeText = L("右クリックの「ロックを外す」で外してから削除してください。")
            a.runModal()
            return
        }
        let a = NSAlert()
        a.messageText = targets.count == 1 ? L("「{0}」を削除しますか？", targets[0].lastPathComponent) : L("{0} 件のテキストを削除しますか？", targets.count)
        a.informativeText = L("ゴミ箱に入れます。ゴミ箱から戻すこともできます。")
            + (locked.isEmpty ? "" : "\n\n" + L("ロックしている {0} 件は削除しません。", locked.count))
        // いくつもあるときは、名前の並びを左寄せで出す
        if targets.count > 1 { a.accessoryView = TextLibrary.leftList(targets.map(\.lastPathComponent)) }
        a.addButton(withTitle: L("削除"))
        a.addButton(withTitle: L("キャンセル"))
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        // 開いている文書なら先に閉じる
        // 開いている文書は、タブを閉じずに空の新しいテキストにする (ウインドウが消えないように)
        for u in targets {
            guard let d = NSDocumentController.shared.document(for: u) else { continue }
            if let doc = d as? Document, doc.remote == nil { doc.becomeBlank() } else { d.close() }
        }
        VersionStore.forget(targets)   // 版の履歴も消す
        NSWorkspace.shared.recycle(targets) { done, _ in
            for u in done.keys {
                TextLibrary.forget(u)
                TextLibrary.setPinned(false, u)
            }
            TextLibrary.changed()
        }
    }

    // いくつも選んだときの操作 (representedObject は [URL]、移動は [[URL], フォルダ])
    @objc func trashMany(_ sender: NSMenuItem) {
        if let us = sender.representedObject as? [URL] { trash(us) }
    }
    @objc func pinMany(_ sender: NSMenuItem) {
        guard let us = sender.representedObject as? [URL] else { return }
        let on = !us.allSatisfy { TextLibrary.isPinned($0) }
        for u in us { TextLibrary.setPinned(on, u) }
    }
    @objc func lockMany(_ sender: NSMenuItem) {
        guard let us = sender.representedObject as? [URL] else { return }
        let on = !us.allSatisfy { TextLibrary.isLocked($0) }
        if on { for u in us { if let d = NSDocumentController.shared.document(for: u), d.isDocumentEdited { d.save(nil) } } }
        for u in us { TextLibrary.setLocked(on, u) }
    }
    @objc func moveMany(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? [Any], let us = a.first as? [URL], let g = a.last as? String else { return }
        for u in us { TextLibrary.move(u, toGroup: g) }
    }
}

// MARK: - 自動保存 (メモ帳のように)

extension Document {
    /// 書き換えたら少し待って保存する: 名前のない文書は「書類/さとるエディタ」に新しく、そこにある文書は上書きで。
    /// 暗号化・サーバ・一部だけ読み込んだ文書と、流出防止をオンにしているときは、今までどおり自分で保存する
    func scheduleLibrarySave() {
        guard remote == nil, partial == nil, !isEncrypted, !Prefs.bool("encryptAlways"), !EditorExtension.encryption.isOn,
              fileURL == nil || TextLibrary.isManaged(fileURL) else { return }
        if let u = fileURL, TextLibrary.isLocked(u) { return } // ロックした文書は書き換えない
        librarySaveTimer?.invalidate()
        librarySaveTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in self?.librarySave() }
    }

    private func librarySave() {
        let current = editor?.textView.string ?? text
        // 書き換えたときだけ呼ばれる (textDidChange・updateChangeCount から) ので、編集済みの印は見ない
        guard !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let type = fileType ?? DocumentController.textType
        // ファイル名は勝手に付けない: 「新規テキスト」はその名前のまま書き留めておき、名前は保存 (⌘S) のときに聞く。
        // 名前のない文書 (⌘N) は、ここでは保存しない
        if let url = fileURL {
            save(to: url, ofType: type, for: .saveOperation) { _ in TextLibrary.changed() }
        }
    }
}

private var librarySaveTimerKey = 0
extension Document {
    var librarySaveTimer: Timer? {
        get { objc_getAssociatedObject(self, &librarySaveTimerKey) as? Timer }
        set { objc_setAssociatedObject(self, &librarySaveTimerKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

// MARK: - 左の一覧

/// テキスト一覧・フォルダの欄の行: 選んだ行は青ではなく、落ち着いた灰色の帯にする (メモ帳と同じ)。文字の色は変えない
final class LibrarySelectionRowView: NSTableRowView {
    static let selectionColor = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.13)
    }
    override var isEmphasized: Bool { get { false } set {} }
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        Self.selectionColor.setFill()
        // 帯は行いっぱい (文字は帯の内側に 6pt 以上あけて置く)
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

final class TextLibraryPanel: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    private let table = LibraryTableView()
    private let scroll = NSScrollView()
    private let countLabel = NSTextField(labelWithString: "")
    private let search = NSSearchField()
    private var all: [TextLibrary.Item] = []
    private var rows: [TextLibrary.Item] = []
    private var generation = 0
    /// フォルダにまだテキストが無いときの案内 (一覧のまん中に)
    private let emptyLabel = EmptyStateView()
    /// 左上の「新しいテキスト」ボタン (空のときの案内にマウスを乗せると、ぴょんぴょん跳ねて場所を知らせる)
    private weak var newTextButton: NSButton?
    /// 読み込み中のしるし
    private let loading = LoadingOverlay()
    /// サムネの画面を出す (ウインドウが受け持つ)
    var onShowGrid: (() -> Void)?
    /// 中身にちょうどよい高さが変わった (上下 2 段のとき、少ないならフォルダの欄を上へ寄せる)
    var onContentHeightChange: ((CGFloat) -> Void)?
    /// 一覧を全部見せるのにちょうどよい高さ (見出し・検索欄 + 行の数ぶん)
    var contentHeight: CGFloat {
        let chrome = max(0, bounds.height - scroll.frame.height)
        return (chrome > 0 ? chrome : 34) + CGFloat(rows.count) * table.rowHeight + 8
    }
    /// いま編集している文書 (一覧で選んでおく)
    var currentFile: URL? { didSet { selectCurrent() } }

    static let width: CGFloat = 200

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        TextLibrary.makeResizable(self, key: "libraryListWidth", width: Self.width, min: 100, max: 640)

        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        let title = NSTextField(labelWithString: "")
        title.font = .boldSystemFont(ofSize: 11)
        title.textColor = .secondaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        let newButton = iconButton("doc.badge.plus", L("新しいテキスト"), #selector(newText(_:)))
        newTextButton = newButton // ツールバーの「新規作成」と同じ形
        let searchButton = iconButton("magnifyingglass", L("検索"), #selector(toggleSearch(_:)))
        // 1 列 (フォルダを上に) ⇔ 2 列 (フォルダを左に) の切り替え
        layoutButton = iconButton(TextLibrary.oneColumn ? "rectangle.split.2x1" : "rectangle.split.1x2",
                                  L("上下 / 左右に並べ替える"), #selector(toggleColumns(_:)))
        let gridButton = iconButton("square.grid.2x2", L("サムネで一覧 (カードで見渡す)"), #selector(showGrid(_:)))
        let closeButton = iconButton("xmark", L("テキスト一覧を閉じる"), #selector(closePanel(_:)))
        // ゴミ箱: 押すと選んだテキストを削除。ファイルやフォルダをつかんで置いても削除できる
        let trashButton = TrashDropButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: L("削除")) ?? NSImage(),
                                          target: self, action: #selector(trashClicked(_:)))
        trashButton.isBordered = false
        trashButton.toolTip = L("ゴミ箱 (選んだテキストを削除。ファイルやフォルダをここに置いても削除できます)")
        trashButton.contentTintColor = .secondaryLabelColor
        trashButton.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        // 件数はフォルダの欄に出ているので、ここには出さない
        // 新規はいちばん左。サムネの一覧はツールバーと「表示」メニューから出す
        _ = gridButton
        // 「…」: 履歴にかかわる操作 (クリア・版の履歴・バックアップなど) をまとめたメニュー
        let moreButton = iconButton("ellipsis.circle", L("履歴の操作"), #selector(showMore(_:)))
        // 見出しの文字は出さない (ボタンだけ)
        _ = title
        let header = NSStackView(views: [newButton, NSView(), searchButton, layoutButton, moreButton, trashButton, closeButton])
        header.orientation = .horizontal
        header.spacing = 2

        search.placeholderString = L("題名・本文で絞り込み")
        search.delegate = self
        search.target = self
        search.action = #selector(searchChanged(_:))
        search.sendsSearchStringImmediately = true
        search.controlSize = .regular   // 小さすぎないように (ふつうの高さ)
        search.font = .systemFont(ofSize: 12)
        search.isHidden = true // 虫めがねのボタンを押したときだけ出す

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = 34
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        // ⇧ (続けて) ・⌘ (飛び飛び) を押しながら押すと、いくつも選べる。選んだものは右クリック・⌫ でまとめて扱う
        table.allowsMultipleSelection = true
        table.onDelete = { [weak self] in self?.deleteSelected() }
        // 行をなぞると、そのファイルをつかんで動かせる (上のフォルダに置くと、そのフォルダへ移る)
        table.verticalMotionCanBeginDrag = true
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setAccessibilityLabel(L("テキスト一覧"))
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        emptyLabel.isHidden = true
        // 案内の「左上のボタン」を押しても、新しいテキストを作る
        emptyLabel.onHintClick = { [weak self] in self?.newText(nil) }
        emptyLabel.onHintHover = { [weak self] on in hopButton(self?.newTextButton, on) }
        let stack = NSStackView(views: [header, search, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 4, bottom: 0, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // ボタンの並び (見出し) は、ほんの少し濃い地にして一覧と区別する
        let headerBG = TintBackgroundView()
        headerBG.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerBG)
        addSubview(stack)
        addSubview(emptyLabel, positioned: .above, relativeTo: nil)
        addSubview(loading, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            loading.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 14),
            loading.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
        ])
        NSLayoutConstraint.activate([
            headerBG.topAnchor.constraint(equalTo: topAnchor),
            headerBG.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerBG.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            headerBG.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
        ])
        NSLayoutConstraint.activate([
            emptyLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 24),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
        ])
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor), background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor), background.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: line.leadingAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -6),
            line.topAnchor.constraint(equalTo: topAnchor), line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor), line.widthAnchor.constraint(equalToConstant: 1),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(reload(_:)), name: TextLibrary.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(groupChanged(_:)), name: TextLibrary.selectionDidChange, object: nil)
        reload(nil)
        // 「5 分前」などの表示を、1 分ごとに描き直す
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            if self.window != nil && !self.isHidden { self.table.reloadData(); self.selectCurrent() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    /// 選ぶフォルダが変わった: そのフォルダの分を読み直す
    @objc private func groupChanged(_ note: Notification) { reload(nil) }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: self, action: action)
        b.isBordered = false
        b.toolTip = tip
        b.contentTintColor = .secondaryLabelColor
        b.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        return b
    }

    /// 一覧を読み直す (ファイルを読むので裏で)
    @objc func reload(_ note: Notification?) {
        generation += 1
        let gen = generation
        // 時間がかかるときは、前の中身を消してから「読み込み中…」を出す
        loading.begin { [weak self] in
            guard let self = self else { return }
            self.emptyLabel.isHidden = true
            self.rows = []
            self.table.reloadData()
        }
        let sel = TextLibrary.selectedGroup
        DispatchQueue.global(qos: .userInitiated).async {
            // 選んでいるフォルダの分だけ読む。「すべて」のときも、中身を読むのは新しい 120 件まで
            let list = TextLibrary.items(matching: sel, contentLimit: 120)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, gen == self.generation else { return }
                self.loading.end()
                self.all = list
                self.applyFilter()
            }
        }
    }

    private func applyFilter() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let sel = TextLibrary.selectedGroup
        let inGroup = all.filter { TextLibrary.matches($0, sel) }
        let full = q.isEmpty ? inGroup : inGroup.filter { $0.title.lowercased().contains(q) || $0.snippet.lowercased().contains(q) }
        countLabel.stringValue = q.isEmpty ? L("全 {0} 件", inGroup.count) : L("{0} / {1} 件", full.count, inGroup.count)
        emptyLabel.isHidden = !full.isEmpty || !loading.isHidden
        // 空のときは、文ではなくアイコンで (検索で見つからないときは虫めがね)
        if q.isEmpty { emptyLabel.show(symbol: "tray", caption: "NO DATA", hint: L("「左上のボタン」で新規ファイル")) }
        else { emptyLabel.show(symbol: "magnifyingglass", caption: "NO MATCH") }
        // 新しく作ったファイルは、上からすべり込んで入る (はじめて出るときだけ)
        let fresh = IndexSet(full.indices.filter { !slid.contains(full[$0].url.path) && NewMark.remaining(full[$0].url) != nil })
        fresh.forEach { slid.insert(full[$0].url.path) }
        if !fresh.isEmpty, window != nil {
            rows = full.enumerated().filter { !fresh.contains($0.offset) }.map(\.element)
            table.reloadData()
            rows = full
            table.insertRows(at: fresh, withAnimation: [.slideDown, .effectFade])
        } else {
            rows = full
            table.reloadData()
        }
        onContentHeightChange?(contentHeight)
        selectCurrent()
    }

    private func selectCurrent() {
        // いくつも選んでいるあいだは、その選び方を残す (一覧が作り直されても)
        if multiKeep.count > 1 {
            let idx = IndexSet(rows.indices.filter { multiKeep.contains(rows[$0].url.path) })
            if idx.count > 1 { table.selectRowIndexes(idx, byExtendingSelection: false); return }
            multiKeep = []
        }
        guard let cur = currentFile?.standardizedFileURL.resolvingSymlinksInPath().path,
              let i = rows.firstIndex(where: { $0.url.path == cur }) else { table.deselectAll(nil); return }
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    @objc private func searchChanged(_ sender: Any?) { applyFilter() }

    /// 虫めがね: 検索欄を出す / しまう (しまうときは絞り込みもやめる)
    @objc private func toggleSearch(_ sender: Any?) {
        search.isHidden.toggle()
        if search.isHidden {
            search.stringValue = ""
            applyFilter()
        } else {
            window?.makeFirstResponder(search)
        }
    }

    /// 検索欄で Esc: 検索欄をしまう
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), control === search {
            toggleSearch(nil)
            return true
        }
        return false
    }
    @objc private func showGrid(_ sender: Any?) { onShowGrid?() }

    private var layoutButton = NSButton()
    @objc private func toggleColumns(_ sender: NSButton) {
        TextLibrary.oneColumn.toggle()
        sender.image = NSImage(systemSymbolName: TextLibrary.oneColumn ? "rectangle.split.2x1" : "rectangle.split.1x2",
                               accessibilityDescription: L("上下 / 左右に並べ替える"))
    }

    /// 「…」のメニュー: 履歴にかかわる操作をまとめて出す
    @objc private func showMore(_ sender: NSButton) {
        let m = NSMenu()
        func add(_ title: String, _ symbol: String, _ action: @escaping () -> Void, enabled: Bool = true) {
            let i = ClosureMenuItem(title: title, action: action)
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            i.isEnabled = enabled
            m.addItem(i)
        }
        add(L("新しいテキスト"), "doc.badge.plus") { TextLibrary.createBlankText() }
        // フォルダの欄の操作 (同じウインドウのフォルダの欄が受け持つ)
        add(L("新規フォルダ…"), "folder.badge.plus") { [weak self] in
            NotificationCenter.default.post(name: TextFolderPanel.newFolderRequest, object: self?.window)
        }
        add(L("ほかの場所のフォルダを開く…"), "folder") { [weak self] in
            NotificationCenter.default.post(name: TextFolderPanel.openFolderRequest, object: self?.window)
        }
        m.addItem(.separator())
        add(L("サムネで一覧"), "square.grid.2x2") { [weak self] in self?.onShowGrid?() }
        add(L("保存フォルダを Finder で開く"), "folder") {
            try? FileManager.default.createDirectory(at: TextLibrary.folder, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([TextLibrary.folder])
        }
        m.addItem(.separator())
        add(L("「ほかの場所」の履歴をクリア…"), "clear") { [weak self] in self?.clearOtherPlaces() }
        add(L("版の履歴をすべて消す…"), "clock.badge.xmark", { [weak self] in self?.clearAllVersions() }, enabled: VersionStore.gitAvailable)
        m.addItem(.separator())
        add(L("版の履歴・バックアップの設定…"), "gearshape") { SettingsWindowController.shared.show(.backup) }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// 「ほかの場所」(さとるエディタのフォルダの外) のテキストを、一覧から外す (ファイルは消さない)
    private func clearOtherPlaces() {
        let others = TextLibrary.items().filter { $0.group == nil }
        guard !others.isEmpty else { NSSound.beep(); return }
        let a = NSAlert()
        a.messageText = L("「ほかの場所」の履歴をクリアしますか？")
        a.informativeText = L("一覧から {0} 件を外します。ファイルそのものは消しません。さとるエディタのフォルダの中のテキストはそのままです。", others.count)
        a.addButton(withTitle: L("クリア"))
        a.addButton(withTitle: L("キャンセル"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        others.forEach { TextLibrary.forget($0.url) }
    }

    /// 版の履歴をすべて消す (テキストそのものは消さない)
    private func clearAllVersions() {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = L("版の履歴をすべて消しますか？")
        a.informativeText = L("すべてのテキストの、前の版の記録を消します。テキストそのものは消しません。元に戻せません。")
        a.addButton(withTitle: L("すべて消す"))
        a.addButton(withTitle: L("キャンセル"))
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        VersionStore.clearAll()
        TextLibrary.changed()
    }
    @objc private func closePanel(_ sender: Any?) { TextLibrary.setVisible(false) }
    /// 新規: その場で空のテキストを (選んでいるフォルダに) 作って一覧に入れ、開く
    @objc private func newText(_ sender: Any?) { TextLibrary.createBlankText() }

    @objc private func rowClicked(_ sender: Any?) {
        let r = table.clickedRow
        guard r >= 0, r < rows.count else { return }
        // ⇧・⌘ を押しながら選んでいるとき (いくつも選んでいるとき) は、開かずに選ぶだけ
        let mods = NSEvent.modifierFlags.intersection([.shift, .command])
        if !mods.isEmpty || table.selectedRowIndexes.count > 1 { return }
        TextLibrary.open(rows[r].url)
    }

    /// いくつも選んでいるときの、選んだもの (一覧を作り直しても選び直すため)
    private var multiKeep = Set<String>()

    func tableViewSelectionDidChange(_ notification: Notification) {
        multiKeep = table.selectedRowIndexes.count > 1 ? Set(selectedURLs.map(\.path)) : []
    }

    /// 選んでいるテキスト (いくつでも)
    private var selectedURLs: [URL] {
        table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].url : nil }
    }

    @objc private func trashClicked(_ sender: Any?) {
        if selectedURLs.isEmpty { NSSound.beep(); return }
        deleteSelected()
    }

    private func deleteSelected() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        TextLibraryActions.shared.trash(urls)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row >= 0, row < rows.count else { return nil }
        return rows[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { LibrarySelectionRowView() }

    /// 上からすべり込ませたファイル (同じものは 2 回すべらせない)
    private var slid = Set<String>()

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("libraryRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? LibraryRowView) ?? LibraryRowView()
        cell.identifier = id
        cell.show(rows[row], showFolder: TextLibrary.selectedGroup == "all" || TextLibrary.selectedGroup == "other" || TextLibrary.selectedGroup == "shared"
                                        || TextLibrary.selectedGroup.hasPrefix("multi:"))
        return cell
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let r = table.clickedRow
        guard r >= 0, r < rows.count else { return }
        // いくつも選んでいる中で右クリックしたら、まとめて扱うメニュー
        if table.selectedRowIndexes.count > 1 && table.selectedRowIndexes.contains(r) {
            for i in TextLibrary.multiMenu(for: selectedURLs, target: TextLibraryActions.shared).items {
                i.menu?.removeItem(i)
                menu.addItem(i)
            }
            return
        }
        for i in TextLibrary.contextMenu(for: rows[r], target: TextLibraryActions.shared).items {
            i.menu?.removeItem(i)
            menu.addItem(i)
        }
    }
}

/// 一覧の 1 行: 題名 (太字) と、日時・本文のはじめ (小さく)
private final class LibraryRowView: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    /// 拡張子 (txt / html など)。1 行目の右はしに、別の小さな字で
    private let extLabel = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    /// 時間 (「5 分前」など)。狭くても切らない
    private let time = NSTextField(labelWithString: "")
    /// 「すべて」を見ているときだけ、どのフォルダのものかを右下 (時間と同じ行) に出す
    private let folderTag = NSTextField(labelWithString: "")
    /// 新しく作ったファイルの小さな点 (アイコンの左の余白に)
    private let newBadge = NewMark.makeBadge()

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 11.5, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1 // 長い題名は 1 行で切る (下の行に重ならない)
        title.usesSingleLineMode = true
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 1
        time.font = .systemFont(ofSize: 10)
        time.textColor = .secondaryLabelColor
        folderTag.font = .systemFont(ofSize: 9.5)
        folderTag.textColor = .secondaryLabelColor
        folderTag.lineBreakMode = .byTruncatingTail
        folderTag.alignment = .right
        extLabel.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        extLabel.textColor = .secondaryLabelColor
        extLabel.wantsLayer = true
        extLabel.drawsBackground = false
        for v in [title, time, detail, folderTag, extLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(v)
        }
        folderTag.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        // 狭いときは、本文 → フォルダ名 の順に縮め、時間は最後まで残す
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        time.setContentHuggingPriority(.required, for: .horizontal)
        extLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        extLabel.setContentHuggingPriority(.required, for: .horizontal)
        folderTag.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(newBadge)
        NSLayoutConstraint.activate([
            newBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            newBadge.centerYAnchor.constraint(equalTo: title.centerYAnchor),
        ])
        // 行と行の間の区切り線 (下の辺)
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            // 1 行目: 左にしるしとファイルの名前、右はしに拡張子
            extLabel.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            extLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: extLabel.leadingAnchor, constant: -6),
            // 2 行目: 左にフォルダ名、まん中に本文のはじめ、右に時間
            folderTag.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 0),
            folderTag.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            folderTag.trailingAnchor.constraint(lessThanOrEqualTo: time.leadingAnchor, constant: -8),
            time.firstBaselineAnchor.constraint(equalTo: folderTag.firstBaselineAnchor),
            time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detail.firstBaselineAnchor.constraint(equalTo: folderTag.firstBaselineAnchor),
            detail.leadingAnchor.constraint(equalTo: folderTag.trailingAnchor, constant: 6),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: time.leadingAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// フォルダ名: 親からの道すじ (うんち/うう) と、自分の名前だけ (うう)。入らないときは自分の名前だけにする
    private var fullTag: NSAttributedString?
    private var shortTag: NSAttributedString?

    /// 本文の場所が狭すぎるときは、字の切れはしが出ないよう本文を隠す
    override func layout() {
        super.layout()
        if let full = fullTag, let short = shortTag {
            // 道すじのままで入るか (入らなければ自分の名前だけ)
            let room = max(0, bounds.width - 8 - time.intrinsicContentSize.width - 8 - 8)
            let want: NSAttributedString = ceil(full.size().width) + 4 <= room ? full : short
            if !folderTag.attributedStringValue.isEqual(to: want) {
                folderTag.attributedStringValue = want
                needsLayout = true
            }
        }
        detail.isHidden = true
    }

    func show(_ item: TextLibrary.Item, showFolder: Bool) {
        // 飾り付きの文字列は、切り方 (…) を文字列の側にも付けないと、枠の端でぶつ切りになる
        let tail = NSMutableParagraphStyle()
        tail.lineBreakMode = .byTruncatingTail
        // ファイルの名前 (拡張子は右はしに別に出す)
        let ext = item.url.pathExtension
        let fileName = ext.isEmpty ? item.url.lastPathComponent : item.url.deletingPathExtension().lastPathComponent
        extLabel.stringValue = ext.lowercased()
        extLabel.isHidden = ext.isEmpty
        NewMark.show(newBadge, for: item.url)
        let t = NSMutableAttributedString(attributedString: TextLibrary.markedTitle(item, font: title.font ?? .systemFont(ofSize: 11.5, weight: .semibold), name: fileName))
        t.addAttribute(.paragraphStyle, value: tail, range: NSRange(location: 0, length: t.length))
        title.attributedStringValue = t
        folderTag.isHidden = !showFolder
        if !showFolder { folderTag.stringValue = " "; fullTag = nil; shortTag = nil } // 出さないときは幅を取らない (時間と本文を右端まで)
        if showFolder {
            func make(_ name: String) -> NSAttributedString {
            let tag = NSMutableAttributedString()
            let sym = item.group.map { $0.isEmpty ? "folder" : TextLibrary.folderIcon($0).symbol } ?? "folder"   // ほかの場所・開いたフォルダも、同じフォルダのアイコン (色も同じ)
            if let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil) {
                let a = NSTextAttachment()
                a.image = img.withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
                tag.append(NSAttributedString(attachment: a))
                tag.append(NSAttributedString(string: " "))
            }
            tag.append(NSAttributedString(string: name))
            tag.addAttributes([.font: NSFont.systemFont(ofSize: 9.5), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: tail],
                              range: NSRange(location: 0, length: tag.length))
            return tag
            }
            // 開いたフォルダのテキストは「ほかの場所」ではなく、そのフォルダの名前 (と中のフォルダ) を出す
            var extName: String?
            if item.group == nil, let root = TextLibrary.externalRoot(of: item.url) {
                let dir = item.url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
                extName = (root as NSString).lastPathComponent + (dir.count > root.count ? String(dir.dropFirst(root.count)) : "")
            }
            // ほかの場所のテキストは、入っているフォルダの場所を出す (広ければ ~/… の道すじ、狭ければフォルダの名前)
            let parent = item.url.deletingLastPathComponent()
            let otherFull = (parent.path as NSString).abbreviatingWithTildeInPath
            let name = item.group.map { $0.isEmpty ? TextLibrary.rootName : $0 } ?? extName ?? otherFull
            fullTag = make(name)
            shortTag = make(item.group == nil && extName == nil ? parent.lastPathComponent : (name as NSString).lastPathComponent)
            folderTag.attributedStringValue = fullTag!
            needsLayout = true
        }
        time.stringValue = TextLibrary.dateText(item.modified)
        detail.stringValue = ""   // 中身 (本文のはじめ) は一覧に出さない: 2 行目はフォルダと時間だけ
        toolTip = item.url.path + (item.sharedURL.map { "\n" + L("公開中: {0}", $0) } ?? "")
    }
}

// MARK: - サムネで一覧 (カードを並べて見渡す)

final class TextLibraryGrid: NSView {
    private let scroll = NSScrollView()
    private let content = FlippedView()
    private let countLabel = NSTextField(labelWithString: "")
    private var items: [TextLibrary.Item] = []
    private var cards: [LibraryCardView] = []
    var onClose: (() -> Void)?

    static let cardSize = NSSize(width: 180, height: 230)
    static let gap: CGFloat = 18

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = NSTextField(labelWithString: L("テキスト一覧"))
        title.font = .boldSystemFont(ofSize: 15)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        let close = NSButton(title: L("閉じる"), target: self, action: #selector(closePressed(_:)))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        let header = NSStackView(views: [title, countLabel, NSView(), close])
        header.orientation = .horizontal
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 6, right: 16)
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: TextLibrary.didChange, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = TextLibrary.items()
            DispatchQueue.main.async { [weak self] in self?.show(list) }
        }
    }

    private func show(_ all: [TextLibrary.Item]) {
        let list = all.filter { TextLibrary.matches($0, TextLibrary.selectedGroup) }
        items = list
        countLabel.stringValue = L("全 {0} 件", list.count)
        cards.forEach { $0.removeFromSuperview() }
        cards = list.map { item in
            let c = LibraryCardView(item: item)
            c.onOpen = { [weak self] in
                TextLibrary.open(item.url)
                self?.onClose?()
            }
            content.addSubview(c)
            return c
        }
        layoutCards()
    }

    override func layout() {
        super.layout()
        layoutCards()
    }

    /// 幅に合わせて、カードを左上から並べる
    private func layoutCards() {
        let width = max(scroll.contentSize.width, Self.cardSize.width + Self.gap * 2)
        let perRow = max(1, Int((width - Self.gap) / (Self.cardSize.width + Self.gap)))
        let used = CGFloat(perRow) * Self.cardSize.width + CGFloat(perRow - 1) * Self.gap
        let left = max(Self.gap, (width - used) / 2)
        for (i, c) in cards.enumerated() {
            let row = i / perRow, col = i % perRow
            c.frame = NSRect(x: left + CGFloat(col) * (Self.cardSize.width + Self.gap),
                             y: Self.gap + CGFloat(row) * (Self.cardSize.height + Self.gap),
                             width: Self.cardSize.width, height: Self.cardSize.height)
        }
        let rows = (cards.count + perRow - 1) / perRow
        let height = max(scroll.contentSize.height, Self.gap + CGFloat(rows) * (Self.cardSize.height + Self.gap))
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    @objc private func closePressed(_ sender: Any?) { onClose?() }

    override func cancelOperation(_ sender: Any?) { onClose?() }
}

/// カード 1 枚: 紙のような見本 (本文のはじめ) と、その下に題名・日時
private final class LibraryCardView: NSView {
    let item: TextLibrary.Item
    var onOpen: (() -> Void)?
    private var hovering = false

    init(item: TextLibrary.Item) {
        self.item = item
        super.init(frame: .zero)
        toolTip = item.url.path
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
        let menu = TextLibrary.contextMenu(for: item, target: TextLibraryActions.shared)
        self.menu = menu
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let paperRect = NSRect(x: 4, y: 4, width: bounds.width - 8, height: bounds.height - 58)
        // 紙 (影つき)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(hovering ? 0.35 : 0.2)
        shadow.shadowBlurRadius = hovering ? 8 : 4
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSColor(srgbRed: 1.0, green: 0.992, blue: 0.97, alpha: 1).setFill()
        NSBezierPath(roundedRect: paperRect, xRadius: 6, yRadius: 6).fill()
        NSGraphicsContext.restoreGraphicsState()
        if hovering {
            NSColor.controlAccentColor.setStroke()
            let p = NSBezierPath(roundedRect: paperRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            p.lineWidth = 2
            p.stroke()
        }
        if item.isGenko, let ctx = NSGraphicsContext.current?.cgContext {
            drawGenko(in: paperRect.insetBy(dx: 6, dy: 6), ctx: ctx)
        } else {
            drawText(in: paperRect)
        }
        drawCaption(below: paperRect)
    }

    /// 作文: 原稿用紙 1 枚目を小さく描く (縦書き・横書きは書いていたときのまま)
    private func drawGenko(in area: NSRect, ctx: CGContext) {
        let horizontal = item.mode == "genkoH"
        let columns = Genko.layout(item.snippet, autoFormat: !horizontal && UserDefaults.standard.bool(forKey: "genkoAutoFormat"))
        let unit = GenkoRenderer.sheetSize(u: 1, horizontal: horizontal)
        let u = min(area.width / unit.width, area.height / unit.height)
        let size = GenkoRenderer.sheetSize(u: u, horizontal: horizontal)
        let origin = CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2)
        GenkoRenderer.drawSheet(0, of: max(1, Genko.sheetCount(columns)), columns: columns, ruby: [:], at: origin, u: u,
                                paper: GenkoRenderer.paperColor, horizontal: horizontal, in: ctx)
    }

    /// テキスト: 本文のはじめを小さな字で
    private func drawText(in paperRect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byCharWrapping
        style.lineSpacing = 1
        let body = NSAttributedString(string: item.snippet, attributes: [
            .font: NSFont(name: "HiraMinProN-W3", size: 9) ?? NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor(white: 0.15, alpha: 1), .paragraphStyle: style,
        ])
        body.draw(with: paperRect.insetBy(dx: 10, dy: 10), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// 題名と日時 (作文には「原稿用紙」と添える)
    private func drawCaption(below paperRect: NSRect) {
        let title = NSMutableAttributedString(attributedString: TextLibrary.markedTitle(item, font: .systemFont(ofSize: 12, weight: .semibold)))
        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = .byTruncatingTail
        title.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: title.length))
        title.draw(with: NSRect(x: 4, y: paperRect.maxY + 8, width: bounds.width - 8, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let kind = item.isGenko ? "  " + (item.mode == "genkoH" ? L("原稿用紙 (横書き)") : L("原稿用紙 (縦書き)")) : ""
        let date = NSAttributedString(string: TextLibrary.dateText(item.modified) + kind, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        date.draw(at: NSPoint(x: 4, y: paperRect.maxY + 28))
    }
}

// MARK: - いちばん左のフォルダの欄 (ツリー)

/// フォルダの欄の 1 行
final class FolderNode: NSObject {
    let key: String          // "all" / "root" / "other" / "sub:道すじ"
    let name: String
    let symbol: String
    var count = 0
    var tint: NSColor = .controlAccentColor
    var children: [FolderNode] = []
    init(key: String, name: String, symbol: String) {
        self.key = key
        self.name = name
        self.symbol = symbol
    }
    /// 自分で作ったフォルダの道すじ ("root" は "")。「すべて」「ほかの場所」は nil
    var rel: String? { key == "root" ? "" : key.hasPrefix("sub:") ? String(key.dropFirst(4)) : nil }
}

final class TextFolderPanel: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private let outline = FolderOutlineView()
    /// 自分で作ったフォルダがまだ無いときの案内 (フォルダの並びのすぐ下)
    private let folderHint = HoverLabel(wrappingLabelWithString: "")
    private var folderHintTop: NSLayoutConstraint?
    private weak var newFolderButton: NSButton?
    /// 読み込み中のしるし (フォルダの中を読むのに時間がかかるとき)
    private let loading = LoadingOverlay()
    private var top: [FolderNode] = []
    private var generation = 0
    private var restoring = false

    static let width: CGFloat = 128
    /// 中身にちょうどよい高さが変わった (上下 2 段のとき、フォルダの数に合わせる)
    var onContentHeightChange: ((CGFloat) -> Void)?
    /// フォルダを全部見せるのにちょうどよい高さ (見出し・下のボタン + 行の数ぶん)
    var contentHeight: CGFloat {
        let sv = outline.enclosingScrollView
        let chrome = bounds.height > 0 ? max(0, bounds.height - (sv?.frame.height ?? 0)) : 56
        return chrome + CGFloat(outline.numberOfRows) * (outline.rowHeight + outline.intercellSpacing.height) + 6
            + (folderHint.isHidden ? 0 : 40)   // 作り方の案内のぶん
    }
    /// 置き場所の切り替え: 「iCloud ▾」「ローカル ▾」のボタンから選ぶ
    private let storageTabs = NSPopUpButton(frame: .zero, pullsDown: true)
    private func refreshStorageTabs() {
        let can = TextLibrary.iCloudDriveRoot != nil
        let cloud = TextLibrary.usesICloud && can
        // ▾ ボタン: いちばん上の項目がボタンの字 (いまの置き場所)。下の 2 つから選ぶ
        storageTabs.autoenablesItems = false
        guard storageTabs.numberOfItems >= 3 else { return }
        let custom = cloud ? nil : TextLibrary.customFolder
        storageTabs.item(at: 0)?.title = cloud ? "iCloud" : custom?.lastPathComponent ?? L("ローカル")
        storageTabs.item(at: 0)?.image = storageTabs.item(at: cloud ? 2 : custom != nil ? 4 : 1)?.image
        storageTabs.item(at: 1)?.state = !cloud && custom == nil ? .on : .off
        storageTabs.item(at: 2)?.isEnabled = can
        storageTabs.item(at: 2)?.state = cloud ? .on : .off
        storageTabs.item(at: 4)?.state = .off
        // 開いたことのある任意フォルダを、「任意フォルダ…」の下に並べる
        while storageTabs.numberOfItems > 5 { storageTabs.removeItem(at: 5) }
        let fm = FileManager.default
        var recent = TextLibrary.customRecent
        if let c = custom?.path, !recent.contains(c) { recent.insert(c, at: 0) }
        for p in recent where fm.fileExists(atPath: p) {
            storageTabs.addItem(withTitle: "")   // 同じ名前があっても足せるよう、空で足してから名前を付ける
            guard let it = storageTabs.lastItem else { continue }
            it.title = (p as NSString).lastPathComponent
            it.toolTip = p
            it.representedObject = p
            // 名前の右に ✕ (この履歴を消す)。押した行のフォルダに切り替える
            it.view = RecentFolderMenuView(path: p, current: custom?.path == p, pick: { [weak self] in
                TextLibrary.showCustom(URL(fileURLWithPath: p, isDirectory: true))
                self?.refreshStorageTabs()
            }, remove: { [weak self, weak it] in
                TextLibrary.customRecent = TextLibrary.customRecent.filter { $0 != p }
                if let it = it { it.menu?.removeItem(it) }
                // 今見ているフォルダを消したときは、ローカルに戻す
                if TextLibrary.customFolder?.path == p { TextLibrary.showStorage(iCloud: false) }
                DispatchQueue.main.async { self?.refreshStorageTabs() }
            })
        }
    }
    @objc private func storageTabChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        if i >= 5, let p = sender.selectedItem?.representedObject as? String {
            TextLibrary.showCustom(URL(fileURLWithPath: p, isDirectory: true))
            refreshStorageTabs()
            return
        }
        // 任意フォルダ: 好きな場所のフォルダを選んで、その中のテキストを一覧に出す
        if i == 4 {
            refreshStorageTabs()
            DispatchQueue.main.async {
                if let u = self.pickLocalFolders(multiple: false, message: L("フォルダの欄の基準にする、この Mac の中のフォルダを選んでください")).first {
                    TextLibrary.showCustom(u)
                }
                self.refreshStorageTabs()
            }
            return
        }
        TextLibrary.showStorage(iCloud: i == 2)
        refreshStorageTabs()
    }

    static let dragType = NSPasteboard.PasteboardType("net.satoru.satoruEditor.folderRow")
    /// テキスト一覧の「…」から: 新規フォルダ・ほかの場所のフォルダを開く (object = ウインドウ)
    static let newFolderRequest = Notification.Name("satoruEditor.newFolderRequest")
    static let openFolderRequest = Notification.Name("satoruEditor.openFolderRequest")
    private static let expandedKey = "libraryFolderExpanded"

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        TextLibrary.makeResizable(self, key: "libraryFolderWidth", width: Self.width, min: 50, max: 420)
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        let title = NSTextField(labelWithString: L("フォルダ"))
        title.font = .boldSystemFont(ofSize: 11)
        title.textColor = .secondaryLabelColor
        // 「フォルダ」の横: 好きな場所のフォルダを開くボタン
        // 左上: 新規フォルダ (選んでいるフォルダの中に作る)。好きな場所のフォルダを開くのは右クリックから
        let openButton = NSButton(image: NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: L("新規フォルダ")) ?? NSImage(),
                                  target: self, action: #selector(newFolder(_:)))
        openButton.isBordered = false
        openButton.contentTintColor = .secondaryLabelColor
        openButton.toolTip = L("新規フォルダ (選んでいるフォルダの中に作る)")
        newFolderButton = openButton
        // 見出しの文字は出さない (フォルダを開くボタンだけ)
        _ = title
        // 置き場所のタブ: iCloud / この Mac
        storageTabs.removeAllItems()
        storageTabs.addItem(withTitle: "")   // ボタンの字 (いまの置き場所)
        for (title, sym) in [(L("ローカル"), "laptopcomputer"), ("iCloud", "icloud")] {
            storageTabs.addItem(withTitle: title)
            storageTabs.lastItem?.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        }
        storageTabs.menu?.addItem(.separator())
        storageTabs.addItem(withTitle: L("任意フォルダ…"))
        storageTabs.lastItem?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        storageTabs.isBordered = false
        storageTabs.controlSize = .small
        storageTabs.font = .systemFont(ofSize: 11)
        storageTabs.target = self
        storageTabs.action = #selector(storageTabChanged(_:))
        storageTabs.toolTip = L("見るテキストの置き場所: iCloud (iPhone 版と同じ)・この Mac・好きなフォルダ")
        refreshStorageTabs()
        let header = NSStackView(views: [openButton, NSView(), storageTabs])
        header.orientation = .horizontal
        header.spacing = 4

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        // 列の幅を欄の幅に合わせる (右の件数が切れないように)
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.headerView = nil
        outline.style = .plain
        outline.allowsMultipleSelection = true   // ⇧・⌘ を押しながら、フォルダもいくつも選べる
        outline.backgroundColor = .clear
        outline.rowHeight = 20
        outline.indentationPerLevel = 10
        outline.intercellSpacing = NSSize(width: 0, height: 1)
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(folderClicked(_:))
        outline.autosaveExpandedItems = false
        outline.setAccessibilityLabel(L("フォルダ"))
        outline.onDelete = { [weak self] in
            guard let self = self else { return }
            let rels = self.outline.selectedRowIndexes.compactMap { (self.outline.item(atRow: $0) as? FolderNode) }
                .filter { $0.key.hasPrefix("sub:") }.compactMap(\.rel)
            if rels.isEmpty { NSSound.beep(); return }   // 「すべて」「メモ」などは消せない
            Self.trashFolders(rels)
        }
        // ドラッグで並べ替え・ほかのフォルダの中へ (置く場所に線、フォルダの上に置くとその中へ)
        outline.registerForDraggedTypes([Self.dragType, .fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .regular
        outline.verticalMotionCanBeginDrag = true
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let add = NSButton(title: L("フォルダ"), image: NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil) ?? NSImage(),
                           target: self, action: #selector(newFolder(_:)))
        add.isBordered = false
        add.imagePosition = .imageLeading
        add.contentTintColor = .secondaryLabelColor
        add.font = .systemFont(ofSize: 11)
        add.toolTip = L("新規フォルダ (選んでいるフォルダの中に作る)")

        // 下の「＋ フォルダ」は、左上のボタンと同じなので出さない
        _ = add
        let stack = NSStackView(views: [header, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 4, bottom: 6, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(loading, positioned: .above, relativeTo: nil)
        // 「左上のボタン」で新規フォルダ: 押すと作る、マウスを乗せると左上のボタンが跳ねる
        folderHint.attributedStringValue = EmptyStateView.hintText(L("「左上のボタン」で新規フォルダ"))
        folderHint.translatesAutoresizingMaskIntoConstraints = false
        folderHint.isHidden = true
        folderHint.onClick = { [weak self] in self?.newFolder(nil) }
        folderHint.onHover = { [weak self] on in hopButton(self?.newFolderButton, on) }
        addSubview(folderHint, positioned: .above, relativeTo: nil)
        let hintTop = folderHint.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 70)
        folderHintTop = hintTop
        NSLayoutConstraint.activate([
            hintTop,
            folderHint.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 8),
            folderHint.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -8),
        ])
        NSLayoutConstraint.activate([
            loading.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 10),
            loading.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
        ])
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: topAnchor), background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor), background.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: line.leadingAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -10),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -6),
            line.topAnchor.constraint(equalTo: topAnchor), line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor), line.widthAnchor.constraint(equalToConstant: 1),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: TextLibrary.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(followSelection), name: TextLibrary.selectionDidChange, object: nil)
        NotificationCenter.default.addObserver(forName: Self.newFolderRequest, object: nil, queue: .main) { [weak self] n in
            guard let self = self, n.object as? NSWindow === self.window else { return }
            self.newFolder(nil)
        }
        NotificationCenter.default.addObserver(forName: Self.openFolderRequest, object: nil, queue: .main) { [weak self] n in
            guard let self = self, n.object as? NSWindow === self.window else { return }
            self.openFolder(nil)
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func layout() {
        super.layout()
        outline.sizeLastColumnToFit()
    }

    // MARK: 中身

    /// フォルダの木と件数を作り直す (ファイルを読むので裏で)
    @objc func reload() {
        refreshStorageTabs()   // ほかのウインドウで切り替えたときも合わせる
        generation += 1
        let gen = generation
        // 時間がかかるときは、前のフォルダの並びを消してから「読み込み中…」を出す
        loading.begin { [weak self] in
            guard let self = self else { return }
            self.restoring = true
            self.top = []
            self.outline.reloadData()
            self.restoring = false
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // 数えるだけなので、ファイルの中身は読まない
            struct Lite { let url: URL; let group: String?; let sharedURL: String? }
            let ctx = TextLibrary.ScanContext()
            let items = TextLibrary.fileURLs().map { Lite(url: $0, group: ctx.group($0.path), sharedURL: ctx.shared[$0.path]) }
            var counts: [String: Int] = [:]
            for it in items { if let g = it.group { counts[g, default: 0] += 1 } }
            func build(_ rel: String) -> [FolderNode] {
                TextLibrary.childFolders(of: rel).map { r in
                    let icon = TextLibrary.folderIcon(r)
                    let n = FolderNode(key: "sub:" + r, name: (r as NSString).lastPathComponent, symbol: icon.symbol)
                    n.tint = TextLibrary.color(named: icon.color)
                    n.count = counts[r] ?? 0
                    n.children = build(r)
                    return n
                }
            }
            let all = FolderNode(key: "all", name: L("すべて"), symbol: "tray.full")
            all.count = items.count
            let root = FolderNode(key: "root", name: TextLibrary.rootName, symbol: "folder")
            root.count = counts[""] ?? 0
            let other = FolderNode(key: "other", name: L("ほかの場所"), symbol: "folder")
            other.count = items.filter { $0.group == nil && ctx.externalRoot($0.url.path) == nil }.count
            // 開いたフォルダ (さとるエディタのフォルダの外)
            // 中のフォルダもツリーでたどれるように (3 段まで。隠しフォルダ・パッケージは出さない)
            func extTree(_ path: String, depth: Int, top: Bool) -> FolderNode {
                let n = FolderNode(key: "ext:" + path, name: (path as NSString).lastPathComponent, symbol: "folder")
                n.count = items.filter { $0.url.path.hasPrefix(path + "/") }.count
                guard depth < 3 else { return n }
                let subs = ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path, isDirectory: true),
                                                                          includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                                          options: [.skipsHiddenFiles])) ?? [])
                    .filter { u in
                        let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                        return v?.isDirectory == true && v?.isPackage != true
                    }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                n.children = subs.prefix(200).map { extTree($0.standardizedFileURL.resolvingSymlinksInPath().path, depth: depth + 1, top: false) }
                return n
            }
            let externals = TextLibrary.externalFolders.map { extTree($0, depth: 0, top: true) }
            // リンクで公開共有しているテキスト (あるときだけ出す)
            let shared = FolderNode(key: "shared", name: L("公開共有中"), symbol: "folder")
            shared.count = items.filter { $0.sharedURL != nil }.count
            let list = [all, root] + build("") + externals + [other] + (shared.count > 0 ? [shared] : [])
            DispatchQueue.main.async { [weak self] in
                guard let self = self, gen == self.generation else { return }
                self.loading.end()
                // 新しく作ったフォルダは、いったん外して読み直し、あとから上から差し込むように入れる
                var fresh: [(parent: FolderNode?, index: Int, node: FolderNode)] = []
                func pull(_ nodes: inout [FolderNode], parent: FolderNode?) {
                    var i = 0
                    while i < nodes.count {
                        let n = nodes[i]
                        if n.key.hasPrefix("sub:"), let rel = n.rel, !self.slid.contains(rel),
                           NewMark.remaining(TextLibrary.folderURL(rel)) != nil {
                            self.slid.insert(rel)
                            fresh.append((parent, i, n))
                            nodes.remove(at: i)
                            continue
                        }
                        pull(&nodes[i].children, parent: nodes[i])
                        i += 1
                    }
                }
                var list = list
                let animate = self.window != nil && !self.top.isEmpty
                if animate { pull(&list, parent: nil) }
                self.top = list
                self.restoring = true
                self.outline.reloadData()
                let expanded = Set(UserDefaults.standard.stringArray(forKey: Self.expandedKey) ?? [])
                func expand(_ nodes: [FolderNode]) {
                    for n in nodes where expanded.contains(n.key) { self.outline.expandItem(n); expand(n.children) }
                }
                expand(list)
                // 前から順に戻す (同じ親の中では、外したときの位置の小さい順)
                for f in fresh.reversed() {
                    if let p = f.parent {
                        p.children.insert(f.node, at: min(f.index, p.children.count))
                        if expanded.contains(p.key) || p.key == "root" {
                            if self.outline.isItemExpanded(p) && p.children.count > 1 {
                                self.outline.insertItems(at: IndexSet(integer: min(f.index, p.children.count - 1)), inParent: p, withAnimation: [.slideDown, .effectFade])
                            } else {
                                self.outline.reloadItem(p, reloadChildren: true)
                                self.outline.expandItem(p)
                            }
                        } else {
                            self.outline.reloadItem(p, reloadChildren: true)
                        }
                    } else {
                        self.top.insert(f.node, at: min(f.index, self.top.count))
                        self.outline.insertItems(at: IndexSet(integer: min(f.index, self.top.count - 1)), inParent: nil, withAnimation: [.slideDown, .effectFade])
                    }
                }
                if !fresh.isEmpty { expand(self.top) }
                // 消えたフォルダを選んでいたら「すべて」に戻す
                if !self.selectRows(for: TextLibrary.selectedGroup, in: self.top) {
                    TextLibrary.selectedGroup = "all"
                }
                self.restoring = false
                // 自分で作ったフォルダがまだ無いときは、並びのすぐ下に作り方の案内を出す
                let noFolders = !self.top.contains { $0.key.hasPrefix("sub:") }
                self.folderHint.isHidden = !noFolders
                self.folderHintTop?.constant = CGFloat(self.outline.numberOfRows) * (self.outline.rowHeight + self.outline.intercellSpacing.height) + 10
                self.onContentHeightChange?(self.contentHeight)
            }
        }
    }

    /// 選んでいるフォルダがほかから変わったとき (タブの切り替えなど)、欄の選択を合わせる
    @objc private func followSelection() {
        restoring = true
        _ = selectRows(for: TextLibrary.selectedGroup, in: top)
        restoring = false
    }

    private func find(_ key: String, in nodes: [FolderNode]) -> FolderNode? {
        for n in nodes {
            if n.key == key { return n }
            if let c = find(key, in: n.children) { return c }
        }
        return nil
    }

    /// 選んだフォルダが見えるように、親を開く
    private func reveal(_ node: FolderNode) {
        guard let rel = node.rel, rel.contains("/") else { return }
        var parts = rel.components(separatedBy: "/")
        parts.removeLast()
        var path = ""
        for p in parts {
            path = path.isEmpty ? p : path + "/" + p
            if let n = find("sub:" + path, in: top) { outline.expandItem(n) }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FolderNode)?.children.count ?? top.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? FolderNode)?.children[index] ?? top[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? FolderNode)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let r = item as? FolderNode else { return nil }
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSImage(systemSymbolName: r.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = r.tint
        icon.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        let name = NSTextField(labelWithString: r.name)
        name.font = .systemFont(ofSize: 11.5)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let count = NSTextField(labelWithString: r.count > 0 ? String(r.count) : "")   // 0 件は出さない
        count.textColor = .secondaryLabelColor
        count.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [icon, name, NSView(), count])
        row.spacing = 3
        row.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        // 新しく作ったフォルダ: 名前のすぐ右に小さな点 (少しのあいだだけ)
        if r.key.hasPrefix("sub:"), let rel = r.rel {
            let badge = NewMark.makeBadge()
            cell.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 3),
                badge.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            ])
            NewMark.show(badge, for: TextLibrary.folderURL(rel))
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { LibrarySelectionRowView() }

    /// 上から差し込んだフォルダ (同じものは 2 回動かさない)
    private var slid = Set<String>()

    /// フォルダを押した: 選んであったフォルダなら開く・閉じるを切り替え、新しく選んだ閉じたフォルダは開く
    private var pickedByMouse = false
    @objc private func folderClicked(_ sender: Any?) {
        let r = outline.clickedRow
        let justPicked = pickedByMouse
        pickedByMouse = false
        guard r >= 0, let n = outline.item(atRow: r) as? FolderNode, !n.children.isEmpty,
              NSEvent.modifierFlags.intersection([.shift, .command]).isEmpty, outline.selectedRowIndexes.count == 1 else { return }
        if outline.isItemExpanded(n) {
            if !justPicked { outline.collapseItem(n) }
        } else {
            outline.expandItem(n)
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if let t = NSApp.currentEvent?.type, t == .leftMouseDown || t == .leftMouseUp { pickedByMouse = true }
        guard !restoring else { return }
        let nodes = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FolderNode }
        guard let first = nodes.first else { return }
        // いくつも選んだら、そのどれかに入っているテキストを一覧に出す (「すべて」が入っていれば、すべて)
        let key = nodes.count > 1 && !nodes.contains(where: { $0.key == "all" }) ? "multi:" + nodes.map(\.key).joined(separator: "\n") : first.key
        if TextLibrary.selectedGroup != key { TextLibrary.selectedGroup = key }
    }

    /// 選んでいるフォルダ (いくつも選んでいるときは全部) の行を選び直す
    private func selectRows(for sel: String, in list: [FolderNode]) -> Bool {
        let keys = TextLibrary.multiKeys(sel) ?? [sel]
        let nodes = keys.compactMap { find($0, in: list) }
        guard !nodes.isEmpty else { return false }
        nodes.forEach { reveal($0) }
        let idx = IndexSet(nodes.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        if idx != outline.selectedRowIndexes { outline.selectRowIndexes(idx, byExtendingSelection: false) }
        return true
    }

    private func saveExpanded() {
        guard !restoring else { return }
        var keys: [String] = []
        func walk(_ nodes: [FolderNode]) {
            for n in nodes where outline.isItemExpanded(n) { keys.append(n.key); walk(n.children) }
        }
        walk(top)
        UserDefaults.standard.set(keys, forKey: Self.expandedKey)
    }
    func outlineViewItemDidExpand(_ notification: Notification) { saveExpanded(); onContentHeightChange?(contentHeight) }
    func outlineViewItemDidCollapse(_ notification: Notification) { saveExpanded(); onContentHeightChange?(contentHeight) }

    // MARK: ドラッグ (自分で作ったフォルダだけ): 線の位置に置くと並べ替え、フォルダの上に置くとその中へ

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let n = item as? FolderNode, n.key.hasPrefix("sub:"), let rel = n.rel else { return nil }
        let p = NSPasteboardItem()
        p.setString(rel, forType: Self.dragType)
        return p
    }

    /// 置いたあとの親 (""= さとるエディタ直下) と、親の中の何番目か (nil = 最後)
    private func target(_ item: Any?, _ index: Int) -> (parent: String, index: Int?)? {
        if let n = item as? FolderNode {
            if n.key == "root" { return ("", index >= 0 ? 0 : nil) } // 「メモ」の上 = いちばん上の階層へ
            guard let rel = n.rel else { return nil }
            return (rel, index >= 0 ? index : nil)
        }
        // いちばん上の階層: 「すべて」「メモ」と「ほかの場所」の間だけ
        let otherIndex = top.firstIndex { $0.key == "other" } ?? top.count
        guard index >= 2, index <= otherIndex else { return nil }
        return ("", index - 2)
    }

    /// 一覧からつかんできたファイル
    private func draggedFiles(_ info: NSDraggingInfo) -> [URL] {
        guard info.draggingSource is LibraryTableView else { return [] }
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    /// ファイルを置く先のフォルダ (マウスの下の行。「すべて」「ほかの場所」には置けない)
    private func fileTarget(_ outlineView: NSOutlineView, _ info: NSDraggingInfo) -> (node: FolderNode, rel: String)? {
        let r = outlineView.row(at: outlineView.convert(info.draggingLocation, from: nil))
        guard r >= 0, let n = outlineView.item(atRow: r) as? FolderNode, let rel = n.rel else { return nil }
        return (n, rel)
    }
    private func isIn(_ u: URL, _ rel: String) -> Bool {
        u.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
            == TextLibrary.folderURL(rel).standardizedFileURL.resolvingSymlinksInPath().path
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let files = draggedFiles(info)
        if !files.isEmpty {
            guard let t = fileTarget(outlineView, info), files.contains(where: { !isIn($0, t.rel) }) else { return [] }
            outlineView.setDropItem(t.node, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }
        guard let dragged = info.draggingPasteboard.string(forType: Self.dragType), let t = target(item, index) else { return [] }
        if t.parent == dragged || t.parent.hasPrefix(dragged + "/") { return [] } // 自分の中へは入れない
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let files = draggedFiles(info)
        if !files.isEmpty {
            guard let n = item as? FolderNode, let rel = n.rel else { return false }
            var moved = false
            for u in files where !isIn(u, rel) {
                if TextLibrary.isLocked(u) { NSSound.beep(); continue } // ロックしたものは動かさない
                TextLibrary.move(u, toGroup: rel)
                moved = true
            }
            return moved
        }
        guard let dragged = info.draggingPasteboard.string(forType: Self.dragType), let t = target(item, index) else { return false }
        let oldParent = (dragged as NSString).deletingLastPathComponent
        var rel = dragged
        if oldParent != t.parent {
            guard let moved = TextLibrary.moveFolder(dragged, into: t.parent) else { NSSound.beep(); return false }
            rel = moved
            // 入れた先のフォルダは開いて見せる
            var keys = Set(UserDefaults.standard.stringArray(forKey: Self.expandedKey) ?? [])
            keys.insert(t.parent.isEmpty ? "root" : "sub:" + t.parent)
            UserDefaults.standard.set(Array(keys), forKey: Self.expandedKey)
        }
        // 同じ親の中での並び
        var siblings = TextLibrary.childFolders(of: t.parent).filter { $0 != rel }
        var at = t.index ?? siblings.count
        if oldParent == t.parent, let from = TextLibrary.childFolders(of: t.parent).firstIndex(of: rel), from < at { at -= 1 }
        siblings.insert(rel, at: max(0, min(siblings.count, at)))
        TextLibrary.folderOrder = siblings + TextLibrary.folderOrder.filter { !siblings.contains($0) }
        return true
    }

    // MARK: フォルダを作る・名前を変える・ゴミ箱へ

    /// 「＋ フォルダ」: 選んでいるフォルダの中に作る (「すべて」「ほかの場所」のときはいちばん上に)
    @objc private func newFolder(_ sender: Any?) {
        var parent = ""
        if let m = sender as? NSMenuItem, let p = m.representedObject as? String { parent = p }
        else if let n = outline.item(atRow: outline.selectedRow) as? FolderNode, let rel = n.rel { parent = rel }
        let fromMenu = (sender as? NSMenuItem)?.representedObject is String
        var name: String
        if !fromMenu, !parent.isEmpty {
            // 自分で作ったフォルダを選んでいるとき: その中に作るか、いちばん上に別のフォルダとして作るかを選べる
            guard let r = askPlace(parent) else { return }
            name = r.name
            if !r.inside { parent = "" }
        } else {
            guard let n = ask(L("新しいフォルダ"), parent.isEmpty ? L("フォルダの名前") : L("「{0}」の中に作るフォルダの名前", (parent as NSString).lastPathComponent), "") else { return }
            name = n
        }
        if let rel = TextLibrary.createFolder(name, in: parent) {
            if !parent.isEmpty {
                var keys = Set(UserDefaults.standard.stringArray(forKey: Self.expandedKey) ?? [])
                keys.insert("sub:" + parent)
                UserDefaults.standard.set(Array(keys), forKey: Self.expandedKey)
            }
            TextLibrary.selectedGroup = "sub:" + rel
        } else {
            NSSound.beep()
        }
    }

    /// 新規フォルダの名前と、作る場所 (選んでいるフォルダの中 / いちばん上に別のフォルダとして)
    private func askPlace(_ parent: String) -> (name: String, inside: Bool)? {
        let a = NSAlert()
        a.messageText = L("新しいフォルダ")
        a.informativeText = L("フォルダの名前")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let inside = NSButton(radioButtonWithTitle: L("「{0}」の中に作る", (parent as NSString).lastPathComponent), target: self, action: #selector(placePicked(_:)))
        let top = NSButton(radioButtonWithTitle: L("別のフォルダとして、いちばん上に作る"), target: self, action: #selector(placePicked(_:)))
        inside.state = .on
        let stack = NSStackView(views: [field, inside, top])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 74)
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        a.accessoryView = stack
        a.addButton(withTitle: L("OK"))
        a.addButton(withTitle: L("キャンセル"))
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return (field.stringValue, inside.state == .on)
    }
    /// ラジオボタン: 同じ欄のほかのボタンを外す
    @objc private func placePicked(_ sender: NSButton) {
        sender.superview?.subviews.compactMap { $0 as? NSButton }.filter { $0 !== sender && $0.title != "" }.forEach { $0.state = .off }
        sender.state = .on
    }

    private func ask(_ title: String, _ message: String, _ value: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = value
        a.accessoryView = field
        a.addButton(withTitle: L("OK"))
        a.addButton(withTitle: L("キャンセル"))
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    // 右クリック: この中に新規フォルダ・Finder で表示、自分で作ったフォルダは名前の変更・ゴミ箱へ
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let n = outline.item(atRow: outline.clickedRow) as? FolderNode else { return }
        // いくつも選んだフォルダの中で右クリック: まとめて扱う
        let picked = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? FolderNode }
        if picked.count > 1, picked.contains(where: { $0 === n }) {
            let rels = picked.filter { $0.key.hasPrefix("sub:") }.compactMap(\.rel)
            let head = NSMenuItem(title: L("{0} 個のフォルダを選んでいます", picked.count), action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            guard !rels.isEmpty else { return }
            menu.addItem(.separator())
            let nested = rels.filter { $0.contains("/") }
            if !nested.isEmpty {
                let m = NSMenuItem(title: L("いちばん上の階層へ出す ({0} 個)", nested.count), action: #selector(moveManyToTop(_:)), keyEquivalent: "")
                m.target = self
                m.representedObject = nested
                menu.addItem(m)
            }
            let t = NSMenuItem(title: L("{0} 個のフォルダをゴミ箱に入れる…", rels.count), action: #selector(trashFolders(_:)), keyEquivalent: "")
            t.target = self
            t.representedObject = rels
            menu.addItem(t)
            return
        }
        func add(_ title: String, _ sel: Selector, _ obj: Any?) {
            let m = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            m.target = self
            m.representedObject = obj
            menu.addItem(m)
        }
        if n.key.hasPrefix("ext:") {
            let path = String(n.key.dropFirst(4))
            add(L("Finder で表示"), #selector(revealExternal(_:)), path)
            // 開いたフォルダそのもの (いちばん上) だけ、一覧から外せる
            if TextLibrary.externalFolders.contains(path) { add(L("一覧から外す (フォルダは消さない)"), #selector(removeExternal(_:)), path) }
            return
        }
        if let rel = n.rel {
            add(rel.isEmpty ? L("新規フォルダ…") : L("この中に新規フォルダ…"), #selector(newFolder(_:)), rel)
            add(L("Finder で表示"), #selector(revealFolder(_:)), rel)
        } else {
            add(L("新規フォルダ…"), #selector(newFolder(_:)), "")
        }
        add(L("ほかの場所のフォルダを開く…"), #selector(openFolder(_:)), nil)
        if n.key.hasPrefix("sub:"), let rel = n.rel {
            menu.addItem(.separator())
            add(L("名前を変更…"), #selector(renameFolder(_:)), rel)
            // アイコン: 絵と色を選ぶ
            let iconMenu = NSMenu()
            let cur = TextLibrary.folderIcon(rel)
            for (sym, label) in TextLibrary.folderSymbols {
                let m = NSMenuItem(title: L(label), action: #selector(setSymbol(_:)), keyEquivalent: "")
                m.target = self
                m.representedObject = [rel, sym]
                m.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
                m.state = cur.symbol == sym ? .on : .off
                iconMenu.addItem(m)
            }
            iconMenu.addItem(.separator())
            for (col, label) in TextLibrary.folderColors {
                let m = NSMenuItem(title: L(label), action: #selector(setColor(_:)), keyEquivalent: "")
                m.target = self
                m.representedObject = [rel, col]
                m.image = Self.swatch(TextLibrary.color(named: col))
                m.state = (cur.color ?? "accent") == col ? .on : .off
                iconMenu.addItem(m)
            }
            iconMenu.addItem(.separator())
            let reset = NSMenuItem(title: L("元に戻す"), action: #selector(resetIcon(_:)), keyEquivalent: "")
            reset.target = self
            reset.representedObject = rel
            iconMenu.addItem(reset)
            let holder = NSMenuItem(title: L("アイコン"), action: nil, keyEquivalent: "")
            holder.image = NSImage(systemSymbolName: cur.symbol, accessibilityDescription: nil)
            holder.submenu = iconMenu
            menu.addItem(holder)
            if rel.contains("/") { add(L("いちばん上の階層へ出す"), #selector(moveToTop(_:)), rel) }
            add(L("ゴミ箱に入れる"), #selector(trashFolder(_:)), rel)
        }
    }

    /// 色を選ぶメニューの見本 (丸)
    private static func swatch(_ color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 12, height: 12))
        img.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 10, height: 10)).fill()
        img.unlockFocus()
        return img
    }

    @objc private func setSymbol(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? [String], a.count == 2 else { return }
        TextLibrary.setFolderIcon(a[0], symbol: a[1])
    }
    @objc private func setColor(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? [String], a.count == 2 else { return }
        TextLibrary.setFolderIcon(a[0], color: a[1])
    }
    @objc private func resetIcon(_ sender: NSMenuItem) {
        guard let rel = sender.representedObject as? String else { return }
        TextLibrary.setFolderIcon(rel, reset: true)
    }

    /// 好きなフォルダを開いて、一覧に足す (中のテキストが出る。さとるエディタのフォルダには写さない)
    @objc private func openFolder(_ sender: Any?) {
        let picked = pickLocalFolders(multiple: true, message: L("一覧に出す、この Mac の中のフォルダを選んでください (中のテキストが出ます)"))
        picked.forEach { TextLibrary.addExternalFolder($0) }
        if let first = picked.first {
            TextLibrary.selectedGroup = "ext:" + first.standardizedFileURL.resolvingSymlinksInPath().path
        }
    }
    /// この Mac の中のフォルダを選ぶ (ホームから始める。iCloud Drive の中は選ばせない)
    private func pickLocalFolders(multiple: Bool, message: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = multiple
        panel.prompt = L("開く")
        panel.message = message
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK else { return [] }
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents").standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let picked = panel.urls.filter { !($0.standardizedFileURL.resolvingSymlinksInPath().path + "/").hasPrefix(cloud) }
        if picked.count < panel.urls.count {
            let a = NSAlert()
            a.messageText = L("iCloud Drive の中のフォルダは選べません")
            a.informativeText = L("この Mac の中のフォルダを選んでください。iCloud のテキストは、▾ ボタンの「iCloud」で見られます。")
            a.runModal()
        }
        return picked
    }
    @objc private func revealExternal(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }
    @objc private func removeExternal(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        let sel = TextLibrary.selectedGroup
        if sel == "ext:" + p || sel.hasPrefix("ext:" + p + "/") { TextLibrary.selectedGroup = "all" }
        TextLibrary.removeExternalFolder(p)
    }

    @objc private func revealFolder(_ sender: NSMenuItem) {
        guard let rel = sender.representedObject as? String else { return }
        let u = TextLibrary.folderURL(rel)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }

    @objc private func renameFolder(_ sender: NSMenuItem) {
        guard let rel = sender.representedObject as? String else { return }
        let old = (rel as NSString).lastPathComponent
        guard let name = ask(L("フォルダの名前を変更"), L("新しい名前"), old), name != old else { return }
        if !TextLibrary.renameFolder(rel, to: name) { NSSound.beep() }
    }

    @objc private func moveToTop(_ sender: NSMenuItem) {
        guard let rel = sender.representedObject as? String else { return }
        if TextLibrary.moveFolder(rel, into: "") == nil { NSSound.beep() }
    }

    @objc private func trashFolder(_ sender: NSMenuItem) {
        guard let rel = sender.representedObject as? String else { return }
        Self.trashFolders([rel])
    }
    @objc private func trashFolders(_ sender: NSMenuItem) {
        guard let rels = sender.representedObject as? [String] else { return }
        Self.trashFolders(rels)
    }
    @objc private func moveManyToTop(_ sender: NSMenuItem) {
        guard let rels = sender.representedObject as? [String] else { return }
        // 深いものから出す (親を先に動かすと、子の道すじが変わるため)
        for rel in rels.sorted(by: { $0.count > $1.count }) where TextLibrary.moveFolder(rel, into: "") == nil { NSSound.beep() }
    }

    /// フォルダをゴミ箱に入れる (いくつでも。聞くのは 1 回。中のテキストも一緒に)
    static func trashFolders(_ rels: [String]) {
        // 選んだフォルダの中のフォルダは、親と一緒に入るので外す
        let tops = rels.filter { r in !rels.contains { r != $0 && r.hasPrefix($0 + "/") } }
        guard !tops.isEmpty else { return }
        let a = NSAlert()
        a.messageText = tops.count == 1 ? L("フォルダ「{0}」をゴミ箱に入れますか？", (tops[0] as NSString).lastPathComponent)
            : L("{0} 個のフォルダをゴミ箱に入れますか？", tops.count)
        a.informativeText = L("中のテキストとフォルダも一緒にゴミ箱に入ります。")
        if tops.count > 1 { a.accessoryView = TextLibrary.leftList(tops) }
        a.addButton(withTitle: L("ゴミ箱に入れる"))
        a.addButton(withTitle: L("キャンセル"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for d in NSDocumentController.shared.documents {
            if let g = TextLibrary.group(of: d.fileURL), tops.contains(where: { g == $0 || g.hasPrefix($0 + "/") }) {
                if let doc = d as? Document, doc.remote == nil { doc.becomeBlank() } else { d.close() }   // タブは閉じない
            }
        }
        VersionStore.forget(tops.map { TextLibrary.folderURL($0) })   // 中のテキストの版の履歴も消す
        NSWorkspace.shared.recycle(tops.map { TextLibrary.folderURL($0) }) { _, _ in
            let sel = TextLibrary.selectedGroup
            let keys = TextLibrary.multiKeys(sel) ?? [sel]
            if keys.contains(where: { k in tops.contains { k == "sub:" + $0 || k.hasPrefix("sub:" + $0 + "/") } }) { TextLibrary.selectedGroup = "all" }
            TextLibrary.changed()
        }
    }
}

extension Document {
    /// 一覧から次の文書を開くとき、このタブを使い回してよいか: 書き換えていない・共有やサーバの文書でない
    var canBeReplacedByBrowsing: Bool {
        guard !isDocumentEdited, !touched, remote == nil, partial == nil, editor?.collabSession == nil else { return false }
        // 名前のない文書は、何も書いていないときだけ
        if fileURL == nil { return (editor?.textView.string ?? "").isEmpty }
        return true
    }
}

/// テキスト一覧の表: ⌫ (と fn+⌫) で、選んでいるものを削除する
/// 新しく作ったファイル・フォルダの目じるし: 入るときに横からすべり込み、少しのあいだ小さな「NEW」が付く
/// ボタンをぴょんぴょん跳ねさせて場所を知らせる (on = false で止める)
func hopButton(_ b: NSButton?, _ on: Bool) {
    guard let b = b else { return }
    b.wantsLayer = true
    if on {
        let a = CAKeyframeAnimation(keyPath: "transform.translation.y")
        a.values = [0, 5, 0, 2.5, 0, 0]
        a.keyTimes = [0, 0.18, 0.36, 0.5, 0.64, 1]
        a.duration = 0.75
        a.repeatCount = .infinity
        b.layer?.add(a, forKey: "hop")
        b.contentTintColor = .controlAccentColor
    } else {
        b.layer?.removeAnimation(forKey: "hop")
        b.contentTintColor = .secondaryLabelColor
    }
}

/// マウスが乗ったことを知らせるラベル
final class HoverLabel: NSTextField {
    var onHover: ((Bool) -> Void)?
    /// 押した (押せるときだけ指のカーソルにする)
    var onClick: (() -> Void)?
    override func resetCursorRects() { if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) } }
    override func mouseDown(with event: NSEvent) { if onClick == nil { super.mouseDown(with: event) } }
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// 空のときのしるし: 大きめのアイコンと、小さな英字 (NO DATA など)
final class EmptyStateView: NSStackView {
    private let icon = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let hint = HoverLabel(wrappingLabelWithString: "")
    /// 案内の文にマウスが乗った / 外れた
    var onHintHover: ((Bool) -> Void)? {
        get { hint.onHover }
        set { hint.onHover = newValue }
    }
    /// 案内の文を押した
    var onHintClick: (() -> Void)? {
        get { hint.onClick }
        set { hint.onClick = newValue; hint.window?.invalidateCursorRects(for: hint) }
    }
    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 4
        icon.contentTintColor = .tertiaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 26, weight: .light)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        setViews([icon, caption, hint], in: .center)
        setCustomSpacing(10, after: caption)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    /// hint の中の「」で囲んだところは、強調色の下線付きで見せる (マウスを乗せると、そのボタンが跳ねる)
    func show(symbol: String, caption text: String, hint h: String? = nil) {
        hint.isHidden = h == nil
        hint.attributedStringValue = Self.hintText(h ?? "")
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        // 字の間を少しあけて、記号のように見せる
        caption.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.tertiaryLabelColor, .kern: 1.2])
        setAccessibilityLabel(text)
    }
    /// 「」で囲んだところを強調色の下線付きにした案内の文 (「」は出さない)
    static func hintText(_ h: String) -> NSAttributedString {
        let a = NSMutableAttributedString()
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        for (i, part) in h.components(separatedBy: "「").enumerated() {
            if i > 0, let end = part.range(of: "」") {
                // 「」は出さず、その中を強調色の下線付きで
                a.append(NSAttributedString(string: String(part[..<end.lowerBound]), attributes: [
                    .foregroundColor: NSColor.controlAccentColor, .underlineStyle: NSUnderlineStyle.single.rawValue]))
                a.append(NSAttributedString(string: String(part[end.upperBound...]), attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            } else {
                a.append(NSAttributedString(string: part, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            }
        }
        a.addAttributes([.font: NSFont.systemFont(ofSize: 11), .paragraphStyle: p], range: NSRange(location: 0, length: a.length))
        return a
    }
}

/// 読み込み中のしるし: ぐるぐると「読み込み中…」(時間がかかるときだけ出す)
final class LoadingOverlay: NSStackView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: L("読み込み中…"))
    private var pending: DispatchWorkItem?
    init() {
        super.init(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        setViews([spinner, label], in: .center)
        orientation = .horizontal
        spacing = 6
        isHidden = true
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    /// 読み始めた: 少し待っても終わらなければ出す
    func begin(_ onShow: (() -> Void)? = nil) {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.isHidden = false
            self?.spinner.startAnimation(nil)
            onShow?()
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }
    func end() {
        pending?.cancel()
        pending = nil
        spinner.stopAnimation(nil)
        isHidden = true
    }
}

/// ▾ ボタンの、開いたことのある任意フォルダの行: フォルダの名前 (押すと切り替え) と、右はしの ✕ (履歴から消す)
final class RecentFolderMenuView: NSView {
    private let pick: () -> Void
    private let remove: () -> Void
    private var hover = false { didSet { needsDisplay = true; name.textColor = hover ? .selectedMenuItemTextColor : .labelColor } }
    private let name = NSTextField(labelWithString: "")
    init(path: String, current: Bool, pick: @escaping () -> Void, remove: @escaping () -> Void) {
        self.pick = pick
        self.remove = remove
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 22))
        toolTip = path
        let check = NSTextField(labelWithString: current ? "✓" : "")
        check.font = .menuFont(ofSize: 13)
        check.frame = NSRect(x: 8, y: 3, width: 14, height: 16)
        let icon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage())
        icon.frame = NSRect(x: 24, y: 3, width: 16, height: 16)
        icon.contentTintColor = .secondaryLabelColor
        name.stringValue = (path as NSString).lastPathComponent
        name.font = .menuFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingMiddle
        name.frame = NSRect(x: 44, y: 3, width: 150, height: 17)
        let x = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("履歴から消す")) ?? NSImage(),
                         target: nil, action: nil)
        x.isBordered = false
        x.contentTintColor = .tertiaryLabelColor
        x.toolTip = L("この履歴を消す (フォルダそのものは消しません)")
        x.frame = NSRect(x: 202, y: 2, width: 20, height: 18)
        x.target = self
        x.action = #selector(removeClicked)
        for v in [check, icon, name, x] { addSubview(v) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func removeClicked() { remove() }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func mouseUp(with event: NSEvent) {
        enclosingMenuItem?.menu?.cancelTracking()
        DispatchQueue.main.async { self.pick() }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard hover else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
    }
}

/// 小さな丸い点 (強調色)
final class DotView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

enum NewMark {
    /// NEW を付けておく長さ (秒)
    static let seconds: TimeInterval = 20
    /// 作ってからの残り時間 (新しくなければ nil)
    static func remaining(_ url: URL) -> TimeInterval? {
        guard let c = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate else { return nil }
        let age = Date().timeIntervalSince(c)
        return age >= -5 && age < seconds ? seconds - max(0, age) : nil
    }
    /// 小さな NEW の札 (場所を取らないよう、アイコンの角に重ねる)
    static func makeBadge() -> NSView {
        let b = DotView()
        b.toolTip = L("新しく作りました")
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 7).isActive = true
        b.heightAnchor.constraint(equalToConstant: 7).isActive = true
        b.isHidden = true
        return b
    }
    /// 札を出し、時間が来たら消す (行が使い回されたときは、その行の札に任せる)
    static func show(_ badge: NSView, for url: URL?) {
        let left = url.flatMap { remaining($0) }
        badge.isHidden = left == nil
        badge.identifier = NSUserInterfaceItemIdentifier(url?.path ?? "")
        guard let left = left, let path = url?.path else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + left) { [weak badge] in
            if let b = badge, b.identifier?.rawValue == path { b.isHidden = true }
        }
    }
}

/// テキスト一覧の上のゴミ箱。一覧のファイル・フォルダの欄のフォルダをつかんで置くと削除する (聞いてから)
final class TrashDropButton: NSButton {
    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }
    private func setup() { registerForDraggedTypes([.fileURL, TextFolderPanel.dragType]) }

    private func files(_ info: NSDraggingInfo) -> [URL] {
        guard info.draggingSource is LibraryTableView else { return [] }
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    private func folders(_ info: NSDraggingInfo) -> [String] {
        guard info.draggingSource is NSOutlineView else { return [] }
        return (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: TextFolderPanel.dragType) }
    }
    private func lit(_ on: Bool) { contentTintColor = on ? .systemRed : .secondaryLabelColor }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = !files(sender).isEmpty || !folders(sender).isEmpty
        lit(ok)
        return ok ? .move : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        !files(sender).isEmpty || !folders(sender).isEmpty ? .move : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { lit(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { lit(false) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let fs = files(sender), ds = folders(sender)
        lit(false)
        guard !fs.isEmpty || !ds.isEmpty else { return false }
        // ドラッグが終わってから聞く
        DispatchQueue.main.async {
            if !fs.isEmpty { TextLibraryActions.shared.trash(fs) }
            if !ds.isEmpty { TextFolderPanel.trashFolders(ds) }
        }
        return true
    }
}

/// フォルダの欄: ふつうになぞるとフォルダをつかむ (⇧・⌘ を押しながらなぞったときだけ、続けて選ぶ)
final class FolderOutlineView: NSOutlineView {
    var onDelete: (() -> Void)?
    /// Delete (⌫ / ⌦) で、選んでいるフォルダを削除する (聞いてから)
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, event.modifierFlags.intersection([.option, .control]).isEmpty {
            onDelete?()
            return
        }
        super.keyDown(with: event)
    }
    /// ふつうに押してなぞる: つかめるフォルダならつかむ、つかめない行ならなぞっても選び広げない。
    /// ⇧・⌘ を押しているときだけ、なぞって続けて選ぶ (いつもの動き)
    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        let row = self.row(at: start)
        guard event.modifierFlags.intersection([.shift, .command]).isEmpty, row >= 0, let win = window else {
            super.mouseDown(with: event); return
        }
        var writer: NSPasteboardWriting?
        if let item = item(atRow: row) {
            writer = (dataSource as? NSOutlineViewDataSource)?.outlineView?(self, pasteboardWriterForItem: item)
        }
        // 離すまでの動きを先に見る。離すだけならふつうのクリック (super に任せる)
        while let next = win.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: false) {
            if next.type == .leftMouseUp { break }
            _ = win.nextEvent(matching: [.leftMouseDragged])
            let p = convert(next.locationInWindow, from: nil)
            guard let w = writer, hypot(p.x - start.x, p.y - start.y) > 4 else { continue }
            let d = NSDraggingItem(pasteboardWriter: w)
            var image: NSImage?
            if let rv = rowView(atRow: row, makeIfNecessary: false), let rep = rv.bitmapImageRepForCachingDisplay(in: rv.bounds) {
                rv.cacheDisplay(in: rv.bounds, to: rep)
                let im = NSImage(size: rv.bounds.size); im.addRepresentation(rep); image = im
            }
            d.setDraggingFrame(rect(ofRow: row), contents: image)
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            beginDraggingSession(with: [d], event: event, source: self)
            return
        }
        // 離した: 押した行を選ぶふつうのクリックとして扱う
        super.mouseDown(with: event)
    }
}

/// 薄く色を重ねた地 (下に細い線)。明るい・暗い画面のどちらでも合う色で描く
final class TintBackgroundView: NSView {
    var alpha: CGFloat = 0.075
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        bounds.fill()
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

final class LibraryTableView: NSTableView {
    var onDelete: (() -> Void)?
    /// ふつうになぞるとファイルをつかむ。⇧ を押しながらなぞったときだけ、続けて選ぶ
    override func mouseDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        verticalMotionCanBeginDrag = !shift
        super.mouseDown(with: event)
        verticalMotionCanBeginDrag = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, event.modifierFlags.intersection([.command, .option, .control]).isEmpty || event.modifierFlags.contains(.command) {
            onDelete?()
            return
        }
        super.keyDown(with: event)
    }
}

/// 押したときに、渡した処理をするメニュー項目
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, action run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire(_ sender: Any?) { run() }
}
