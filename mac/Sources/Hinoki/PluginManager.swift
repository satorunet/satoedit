import AppKit
import HinokiCore

/// JS 拡張機能をまとめて扱う: 読み込み・入れる・消す・メニュー・イベント
final class PluginManager: NSObject {
    static let shared = PluginManager()

    static var folder: URL {
        AppPaths.file("plugins", isDirectory: true)
    }

    private(set) var plugins: [Plugin] = []

    // MARK: どの文書に効かせるか

    /// イベントの最中はその文書。ふだんは手前のエディタ
    private var eventEditor: EditorWindowController?
    var targetEditor: EditorWindowController? {
        if let e = eventEditor { return e }
        if let e = NSApp.mainWindow?.frontEditor { return e }
        return NSApp.orderedWindows.lazy.compactMap { $0.frontEditor }.first
    }
    var targetText: EditorTextView? { targetEditor?.textView }

    // MARK: 使う・使わない

    private var disabled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "pluginsDisabled") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "pluginsDisabled") }
    }

    func isEnabled(_ p: Plugin) -> Bool { !disabled.contains(p.manifest.id) }

    func setEnabled(_ p: Plugin, _ on: Bool) {
        var d = disabled
        if on { d.remove(p.manifest.id) } else { d.insert(p.manifest.id) }
        disabled = d
        if on { p.start() } else { p.stop() }
        changed()
    }

    /// どこから入れたか (更新に使う)
    private var sources: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: "pluginSources") as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "pluginSources") }
    }

    func source(of p: Plugin) -> String? { sources[p.manifest.id] }

    // MARK: 読み込み

    /// フォルダの中を読み直して、使うものを動かす
    func loadAll() {
        plugins.forEach { $0.stop() }
        plugins = []
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let dirs = (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? []
        var seen = Set<String>()
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) else { continue }
            guard let m = try? PluginManifest.parse(data), seen.insert(m.id).inserted else {
                NSLog("plugin skipped: \(dir.path)")
                continue
            }
            let p = Plugin(manifest: m, folder: dir)
            plugins.append(p)
            if isEnabled(p) { p.start() }
        }
        changed()
    }

    func reload(_ p: Plugin) {
        if isEnabled(p) { p.start() }
        changed()
    }

    func commandsChanged() {
        rebuildMenu()
    }

    private func changed() {
        rebuildMenu()
        NotificationCenter.default.post(name: .pluginsDidChange, object: nil)
    }

    // MARK: イベント

    func emit(_ event: String, editor: EditorWindowController?) {
        let running = plugins.filter { $0.isRunning && $0.hasHandlers(event) }
        guard !running.isEmpty else { return }
        let doc = editor?.hdoc
        let info: [String: Any] = [
            "fileName": doc?.displayName ?? "",
            "path": doc?.remote?.path ?? doc?.fileURL?.path ?? "",
            "language": editor?.profile?.name ?? "",
            "remote": doc?.remote != nil,
        ]
        let saved = eventEditor
        eventEditor = editor
        defer { eventEditor = saved }
        running.forEach { $0.emit(event, info) }
    }

    /// 入力補完に、拡張機能からの候補を足す
    func completions(word: String, language: String?, line: String, editor: EditorWindowController?) -> [Completion.Item] {
        let running = plugins.filter { $0.isRunning }
        guard !running.isEmpty else { return [] }
        let info: [String: Any] = ["word": word, "language": language ?? "", "line": line]
        let saved = eventEditor
        eventEditor = editor
        defer { eventEditor = saved }
        return running.flatMap { $0.completions(info) }
    }

    /// 拡張機能のフォルダの中のファイルを保存したら、その拡張機能を読み直す (作りながら試せるように)
    func fileSaved(_ url: URL) {
        let path = url.resolvingSymlinksInPath().path
        guard path.hasPrefix(Self.folder.resolvingSymlinksInPath().path + "/") else { return }
        if let p = plugins.first(where: { path.hasPrefix($0.folder.resolvingSymlinksInPath().path + "/") }),
           url.lastPathComponent != "manifest.json" {
            reload(p)
            _ = Toast.show(in: targetEditor?.window, kind: .info, title: L("「{0}」を読み直しました", p.manifest.name),
                           detail: p.log.last?.text ?? "")
        } else {
            loadAll()
        }
    }

    // MARK: メニュー (「追加機能」の中に並べる)

    private static let menuTag = 7301

    func rebuildMenu() {
        guard let main = NSApp.mainMenu,
              let holder = main.items.first(where: { $0.identifier?.rawValue == "追加機能" }), let menu = holder.submenu else { return }
        for item in menu.items where item.tag == Self.menuTag { menu.removeItem(item) }
        let running = plugins.filter { $0.isRunning && !$0.commands.isEmpty }
        guard !running.isEmpty else { return }
        // 「追加機能の説明と設定…」の前の区切りの、さらに前に入れる
        var at = menu.items.lastIndex(where: { $0.isSeparatorItem }) ?? menu.items.count
        func add(_ item: NSMenuItem) {
            item.tag = Self.menuTag
            menu.insertItem(item, at: at)
            at += 1
        }
        let sep = NSMenuItem.separator()
        add(sep)
        for p in running {
            let sub = NSMenu(title: p.manifest.name)
            for c in p.commands {
                let i = NSMenuItem(title: c.title, action: #selector(runCommand(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = [p.manifest.id, c.id]
                if let k = c.key {
                    i.keyEquivalent = k.key
                    var mods: NSEvent.ModifierFlags = []
                    if k.command { mods.insert(.command) }
                    if k.shift { mods.insert(.shift) }
                    if k.option { mods.insert(.option) }
                    if k.control { mods.insert(.control) }
                    i.keyEquivalentModifierMask = mods
                }
                sub.addItem(i)
            }
            let h = NSMenuItem(title: "\(iconText(p)) \(p.manifest.name)", action: nil, keyEquivalent: "")
            h.submenu = sub
            add(h)
        }
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [String], ids.count == 2,
              let p = plugins.first(where: { $0.manifest.id == ids[0] }) else { return }
        p.run(command: ids[1])
    }

    func iconText(_ p: Plugin) -> String {
        if let i = p.manifest.icon, !i.isEmpty, !i.contains(".") { return i }
        return "🧩"
    }

    func iconImage(_ p: Plugin) -> NSImage? {
        guard let i = p.manifest.icon, i.contains("."), !i.contains("..") else { return nil }
        return NSImage(contentsOf: p.folder.appendingPathComponent(i))
    }

    // MARK: 入れる

    enum InstallError: LocalizedError {
        case noManifest, badManifest(String), noMain(String), unsafeArchive, tooBig, download(String)
        var errorDescription: String? {
            switch self {
            case .noManifest: return L("manifest.json が見つかりません")
            case .badManifest(let s): return L("manifest.json に問題があります: {0}", s)
            case .noMain(let s): return L("{0} が見つかりません", s)
            case .unsafeArchive: return L("zip の中に、フォルダの外へ書き出すファイルがあります")
            case .tooBig: return L("大きすぎます (20 MB まで)")
            case .download(let s): return L("ダウンロードできませんでした: {0}", s)
            }
        }
    }

    /// URL (GitHub のリポジトリや zip) から入れる
    func install(fromURLText text: String, window: NSWindow?, done: @escaping (Bool) -> Void) {
        guard let url = PluginSource.downloadURL(for: text) else {
            showError(L("URL が正しくありません: {0}", text), window: window)
            return done(false)
        }
        let toast = Toast.show(in: window, key: "plugin-download", kind: .progress, title: L("ダウンロードしています…"), detail: url.absoluteString)
        _ = toast
        URLSession.shared.downloadTask(with: url) { tmp, resp, error in
            var local: URL?
            var problem: String?
            if let error = error {
                problem = error.localizedDescription
            } else if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                problem = "HTTP \(http.statusCode)"
            } else if let tmp = tmp {
                let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 20 * 1024 * 1024 {
                    problem = InstallError.tooBig.localizedDescription
                } else {
                    let keep = FileManager.default.temporaryDirectory.appendingPathComponent("satoru-plugin-\(UUID().uuidString).zip")
                    try? FileManager.default.moveItem(at: tmp, to: keep)
                    local = keep
                }
            }
            DispatchQueue.main.async {
                _ = Toast.show(in: window, key: "plugin-download", kind: problem == nil ? .success : .failure,
                               title: problem == nil ? L("ダウンロードしました") : L("ダウンロードできませんでした"), detail: problem ?? "")
                guard let zip = local else {
                    self.showError(InstallError.download(problem ?? "").localizedDescription, window: window)
                    return done(false)
                }
                defer { try? FileManager.default.removeItem(at: zip) }
                done(self.install(from: zip, source: text.trimmingCharacters(in: .whitespacesAndNewlines), window: window))
            }
        }.resume()
    }

    /// フォルダか zip から入れる。入れたら true
    @discardableResult
    func install(from url: URL, source: String?, window: NSWindow?) -> Bool {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("satoru-plugin-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        do {
            var root = url
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            if !isDir.boolValue {
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                try unzip(url, to: work)
                root = work
            }
            let folder = try findPluginFolder(in: root)
            let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
            let m: PluginManifest
            do { m = try PluginManifest.parse(data) } catch { throw InstallError.badManifest("\(error)") }
            guard fm.fileExists(atPath: folder.appendingPathComponent(m.main).path) else { throw InstallError.noMain(m.main) }
            let existing = plugins.first { $0.manifest.id == m.id }
            guard confirmInstall(m, replacing: existing?.manifest, window: window) else { return false }

            let dest = Self.folder.appendingPathComponent(m.id, isDirectory: true)
            try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            if let old = existing?.folder, fm.fileExists(atPath: old.path) {
                existing?.stop()
                try fm.trashItem(at: old, resultingItemURL: nil)
            }
            if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
            try fm.copyItem(at: folder, to: dest)
            var s = sources
            s[m.id] = source ?? url.path
            sources = s
            var d = disabled
            d.remove(m.id)
            disabled = d
            loadAll()
            let p = plugins.first { $0.manifest.id == m.id }
            _ = Toast.show(in: window, kind: p?.loadError == nil ? .success : .failure,
                           title: L("「{0}」を入れました", m.name),
                           detail: p?.loadError ?? L("メニュー「追加機能」から使えます"))
            return true
        } catch {
            showError(error.localizedDescription, window: window)
            return false
        }
    }

    private func unzip(_ zip: URL, to dir: URL) throws {
        // フォルダの外へ書き出す名前 (../ や /) が入っていないか先に見る
        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        list.arguments = ["-1", zip.path]
        let pipe = Pipe()
        list.standardOutput = pipe
        list.standardError = Pipe()
        try list.run()
        let names = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        list.waitUntilExit()
        guard list.terminationStatus == 0 else { throw InstallError.noManifest }
        for name in names.split(separator: "\n") where name.hasPrefix("/") || name.split(separator: "/").contains("..") {
            throw InstallError.unsafeArchive
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dir.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw InstallError.noManifest }
    }

    /// manifest.json のあるフォルダ (そのもの、または 1 段下。GitHub の zip は repo-main/ の下に入っている)
    private func findPluginFolder(in root: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("manifest.json").path) { return root }
        let subs = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.lastPathComponent != "__MACOSX" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        for s in subs where fm.fileExists(atPath: s.appendingPathComponent("manifest.json").path) { return s }
        throw InstallError.noManifest
    }

    private func confirmInstall(_ m: PluginManifest, replacing old: PluginManifest?, window: NSWindow?) -> Bool {
        let a = NSAlert()
        if let old = old {
            a.messageText = L("「{0}」を {1} から {2} に入れ替えますか？", m.name, old.version, m.version)
        } else {
            a.messageText = L("「{0}」を入れますか？", m.name)
        }
        var lines: [String] = []
        if !m.description.isEmpty { lines.append(m.description) }
        lines.append(L("作者: {0}   版: {1}", m.author.isEmpty ? "?" : m.author, m.version))
        let perms = m.permissions.compactMap { PluginManifest.Permission(rawValue: $0) }.map { Self.permissionText($0) }
        lines.append(perms.isEmpty ? L("特別な権限は使いません (文書の読み書きだけ)") : L("使う権限: {0}", perms.joined(separator: "、")))
        lines.append("")
        lines.append(L("ほかの人が作ったプログラムです。信頼できる作者のものだけ入れてください。"))
        a.informativeText = lines.joined(separator: "\n")
        a.addButton(withTitle: old == nil ? L("入れる") : L("入れ替える"))
        a.addButton(withTitle: L("やめる"))
        return a.runModal() == .alertFirstButtonReturn
    }

    static func permissionText(_ p: PluginManifest.Permission) -> String {
        switch p {
        case .network: return L("ネットにつなぐ")
        case .clipboard: return L("クリップボードを読み書きする")
        }
    }

    private func showError(_ message: String, window: NSWindow?) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = L("拡張機能を入れられませんでした")
        a.informativeText = message
        a.runModal()
    }

    // MARK: 消す・更新

    func uninstall(_ p: Plugin) -> Bool {
        let a = NSAlert()
        a.messageText = L("「{0}」を外しますか？", p.manifest.name)
        a.informativeText = L("フォルダはゴミ箱に移します。")
        a.addButton(withTitle: L("外す"))
        a.addButton(withTitle: L("やめる"))
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        p.stop()
        try? FileManager.default.trashItem(at: p.folder, resultingItemURL: nil)
        var s = sources
        s[p.manifest.id] = nil
        sources = s
        loadAll()
        return true
    }

    /// 入れた元 (URL) からもう一度取ってくる
    func update(_ p: Plugin, window: NSWindow?) {
        guard let src = source(of: p), src.hasPrefix("http") || src.hasPrefix("github.com") else {
            showError(L("URL から入れたものではないので、更新できません"), window: window)
            return
        }
        install(fromURLText: src, window: window) { _ in }
    }

    // MARK: 自分で作る

    /// ひな形を作って、main.js をエディタで開く
    func createTemplate(window: NSWindow?) {
        let a = NSAlert()
        a.messageText = L("新しい拡張機能を作る")
        a.informativeText = L("名前 (英小文字・数字・-) を入れてください。~/.satoruEditor/plugins の中にひな形を作ります。")
        let field = NSTextField(string: "my-plugin")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: L("作る"))
        a.addButton(withTitle: L("やめる"))
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let id = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let m = PluginManifest(id: id, name: id, author: NSFullUserName(), description: L("説明をここに"))
        do { try m.validate() } catch { showError(L("名前に使えない文字があります: {0}", id), window: window); return }
        let dir = Self.folder.appendingPathComponent(id, isDirectory: true)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dir.path) else { showError(L("同じ名前のフォルダがもうあります"), window: window); return }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let manifest = """
            {
              "id": "\(id)",
              "name": "\(id)",
              "version": "1.0.0",
              "author": "",
              "description": "",
              "icon": "🧩",
              "main": "main.js",
              "permissions": []
            }

            """
            try manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            try PluginDocs.template.write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
            try PluginDocs.readme.write(to: Self.folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        } catch {
            showError(error.localizedDescription, window: window)
            return
        }
        loadAll()
        NSDocumentController.shared.openDocument(withContentsOf: dir.appendingPathComponent("main.js"), display: true) { _, _, _ in }
        _ = Toast.show(in: window, kind: .success, title: L("ひな形を作りました"),
                       detail: L("main.js を書き換えて保存すると、すぐ読み直します"))
    }

    /// 作り方 (API の説明) をエディタで開く
    func openDocs() {
        let url = Self.folder.appendingPathComponent("README.md")
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? PluginDocs.readme.write(to: url, atomically: true, encoding: .utf8)
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }

    func revealFolder(_ p: Plugin? = nil) {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if let p = p {
            NSWorkspace.shared.activateFileViewerSelecting([p.folder])
        } else {
            NSWorkspace.shared.open(Self.folder)
        }
    }
}
