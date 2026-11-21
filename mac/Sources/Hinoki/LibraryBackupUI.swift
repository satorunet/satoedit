import AppKit
import HinokiCore
import UniformTypeIdentifiers

// テキスト一覧のバックアップ: 書き出す (パスワードで鍵をかけた 1 つのファイル) / 読み込む (戻す)。
// 入れるもの: さとるエディタのフォルダの中のファイルすべて (フォルダの形のまま)、一覧に出ている「ほかの場所」のテキスト、
// 表示 (作文など)・ピン・ロック・日時、フォルダのアイコンと並び、公開したリンクの記録。
enum LibraryBackupUI {
    private static let otherFolderName = "ほかの場所から戻したもの"

    // MARK: 書き出す

    static func export(from window: NSWindow?) {
        guard let (password, withLinks, withHistory) = askNewPassword(window: window) else { return }
        let panel = NSSavePanel()
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd-HHmm"
        panel.nameFieldStringValue = L("さとるエディタのバックアップ") + "-" + df.string(from: Date()) + "." + LibraryBackup.fileExtension
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let t = UTType(filenameExtension: LibraryBackup.fileExtension) { panel.allowedContentTypes = [t] }
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let out = panel.url else { return }
        // 書きかけは先に保存しておく (ファイルの中身を入れるため)
        for d in NSDocumentController.shared.documents where d.isDocumentEdited && d.fileURL != nil { d.save(nil) }
        VersionStore.flushAll()
        let archive = collect(withLinks: withLinks, withHistory: withHistory)
        let progress = ProgressSheet.show(L("バックアップを作っています…"), on: window)
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Int, Error> = Result {
                let data = try LibraryBackup.seal(archive, password: password)
                try data.write(to: out, options: .atomic)
                return data.count
            }
            DispatchQueue.main.async {
                progress?.close()
                let a = NSAlert()
                switch result {
                case .success(let size):
                    a.messageText = L("バックアップを書き出しました")
                    a.informativeText = L("{0} 件のテキストを、パスワードで鍵をかけて保存しました ({1})。", archive.entries.count,
                                          ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        + "\n" + out.path + "\n\n" + L("パスワードを忘れると、このバックアップは開けません。")
                    a.addButton(withTitle: L("閉じる"))
                    a.addButton(withTitle: L("Finder で表示"))
                case .failure(let e):
                    a.alertStyle = .warning
                    a.messageText = L("バックアップを書き出せませんでした")
                    a.informativeText = e.localizedDescription
                }
                let done: (NSApplication.ModalResponse) -> Void = { r in
                    if r == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                }
                if let w = window { a.beginSheetModal(for: w, completionHandler: done) } else { done(a.runModal()) }
            }
        }
    }

    /// 入れるものを集める
    static func collect(withLinks: Bool, withHistory: Bool = true) -> LibraryBackup.Archive {
        let fm = FileManager.default
        let root = TextLibrary.folder.standardizedFileURL.resolvingSymlinksInPath()
        var entries: [LibraryBackup.Entry] = []
        var folders: [String] = []
        func entry(_ url: URL, path: String) -> LibraryBackup.Entry? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let hist = withHistory ? VersionStore.export(url) : []
            return LibraryBackup.Entry(path: path, data: data, mode: TextLibrary.fileMode(url), pinned: TextLibrary.isPinned(url),
                                       locked: TextLibrary.isLocked(url), created: attrs?[.creationDate] as? Date,
                                       modified: attrs?[.modificationDate] as? Date, history: hist.isEmpty ? nil : hist)
        }
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in walker {
                let u = url.standardizedFileURL.resolvingSymlinksInPath()
                let rel = String(u.path.dropFirst(root.path.count + 1))
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if v?.isDirectory == true { folders.append(rel); continue }
                guard v?.isRegularFile == true, u.pathExtension != LibraryBackup.fileExtension,
                      let e = entry(u, path: "folder/" + rel) else { continue }
                entries.append(e)
            }
        }
        // 一覧に出ている「ほかの場所」のテキスト (同じ名前があれば番号を付ける)
        var used = Set<String>()
        for item in TextLibrary.items() where item.group == nil {
            var name = item.url.lastPathComponent, n = 2
            while used.contains(name) {
                name = item.url.deletingPathExtension().lastPathComponent + " \(n)" + (item.url.pathExtension.isEmpty ? "" : "." + item.url.pathExtension)
                n += 1
            }
            used.insert(name)
            if let e = entry(item.url, path: "other/" + name) { entries.append(e) }
        }
        let icons = UserDefaults.standard.dictionary(forKey: "libraryFolderIcons") as? [String: String] ?? [:]
        let links = withLinks ? UserDefaults.standard.data(forKey: "sharedLinks") : nil
        return LibraryBackup.Archive(entries: entries, folders: folders, folderIcons: icons, folderOrder: TextLibrary.folderOrder, sharedLinks: links)
    }

    // MARK: 読み込む (戻す)

    static func importBackup(from window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let t = UTType(filenameExtension: LibraryBackup.fileExtension) { panel.allowedContentTypes = [t] }
        panel.message = L("読み込むバックアップ (.satorubackup) を選んでください")
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        var archive: LibraryBackup.Archive?
        while archive == nil {
            guard let pw = askPassword(title: L("バックアップのパスワード"), info: url.lastPathComponent) else { return }
            do {
                archive = try LibraryBackup.open(data, password: pw)
            } catch LibraryBackup.BackupError.notBackup {
                return alert(L("読み込めませんでした"), LibraryBackup.BackupError.notBackup.localizedDescription, window)
            } catch LibraryBackup.BackupError.newerVersion {
                return alert(L("読み込めませんでした"), LibraryBackup.BackupError.newerVersion.localizedDescription, window)
            } catch {
                let a = NSAlert()
                a.messageText = L("パスワードが違います")
                a.addButton(withTitle: L("もう一度"))
                a.addButton(withTitle: L("キャンセル"))
                if a.runModal() != .alertFirstButtonReturn { return }
            }
        }
        guard let a = archive else { return }
        let df = DateFormatter()
        df.locale = Locale.current
        df.setLocalizedDateFormatFromTemplate("yMMMdHm")
        let confirm = NSAlert()
        confirm.messageText = L("バックアップから戻しますか？")
        confirm.informativeText = L("{0} に作ったバックアップ: テキスト {1} 件・フォルダ {2} 個", df.string(from: a.createdAt), a.entries.count, a.folders.count)
            + "\n\n" + L("さとるエディタのフォルダに戻します。今あるファイルは消しません。同じ名前で中身が違うものは「(バックアップ)」を付けて別に置きます。")
        confirm.addButton(withTitle: L("戻す"))
        confirm.addButton(withTitle: L("キャンセル"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        let r = restore(a)
        TextLibrary.changed()
        alert(L("バックアップから戻しました"),
              L("新しく戻したもの {0} 件 ・ 同じだったので飛ばしたもの {1} 件 ・ 名前を変えて戻したもの {2} 件", r.added, r.skipped, r.renamed)
                + (r.failed > 0 ? "\n" + L("戻せなかったもの {0} 件", r.failed) : ""), window)
    }

    struct RestoreResult { var added = 0, skipped = 0, renamed = 0, failed = 0 }

    static func restore(_ a: LibraryBackup.Archive) -> RestoreResult {
        let fm = FileManager.default
        let root = TextLibrary.folder
        var r = RestoreResult()
        for f in a.folders {
            guard let rel = LibraryBackup.safeRelative("folder/" + f, prefix: "folder") else { continue }
            try? fm.createDirectory(at: root.appendingPathComponent(rel), withIntermediateDirectories: true)
        }
        for e in a.entries {
            var target: URL
            if let rel = LibraryBackup.safeRelative(e.path, prefix: "folder") {
                target = root.appendingPathComponent(rel)
            } else if let rel = LibraryBackup.safeRelative(e.path, prefix: "other"), !rel.contains("/") {
                target = root.appendingPathComponent(L(otherFolderName)).appendingPathComponent(rel)
            } else {
                r.failed += 1
                continue
            }
            if fm.fileExists(atPath: target.path) {
                if (try? Data(contentsOf: target)) == e.data { r.skipped += 1; continue }
                // 中身が違う: 「(バックアップ)」を付けた名前で置く
                let base = target.deletingPathExtension().lastPathComponent, ext = target.pathExtension
                var n = 1
                repeat {
                    let name = base + " " + (n == 1 ? L("(バックアップ)") : L("(バックアップ {0})", n)) + (ext.isEmpty ? "" : "." + ext)
                    target = target.deletingLastPathComponent().appendingPathComponent(name)
                    n += 1
                } while fm.fileExists(atPath: target.path)
                r.renamed += 1
            } else {
                r.added += 1
            }
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try e.data.write(to: target)
            } catch {
                r.failed += 1
                continue
            }
            var attrs: [FileAttributeKey: Any] = [:]
            if let c = e.created { attrs[.creationDate] = c }
            if let m = e.modified { attrs[.modificationDate] = m }
            if !attrs.isEmpty { try? fm.setAttributes(attrs, ofItemAtPath: target.path) }
            if let m = e.mode { TextLibrary.writeFileMode(m, to: target) }
            if let h = e.history, !h.isEmpty { VersionStore.importHistory(h, for: target) }   // 版の履歴も戻す
            if e.pinned { TextLibrary.setPinned(true, target) }
            if e.locked { TextLibrary.setLocked(true, target) }
        }
        // フォルダのアイコン (決めていないものだけ)・並び (ないものを後ろに)
        var icons = UserDefaults.standard.dictionary(forKey: "libraryFolderIcons") as? [String: String] ?? [:]
        for (k, v) in a.folderIcons where icons[k] == nil { icons[k] = v }
        UserDefaults.standard.set(icons, forKey: "libraryFolderIcons")
        let order = TextLibrary.folderOrder
        TextLibrary.folderOrder = order + a.folderOrder.filter { !order.contains($0) }
        // 公開したリンクの記録 (同じものは足さない)
        if let d = a.sharedLinks, let list = try? JSONDecoder().decode([ShareLink.Record].self, from: d) {
            let have = Set(ShareLink.records.map(\.id))
            ShareLink.records = ShareLink.records + list.filter { !have.contains($0.id) }
        }
        return r
    }

    // MARK: 画面の部品

    /// 新しいパスワード (2 回) と、公開したリンクの記録を入れるか
    private static func askNewPassword(window: NSWindow?) -> (String, Bool, Bool)? {
        let a = NSAlert()
        a.messageText = L("テキストをバックアップ")
        a.informativeText = L("テキスト一覧のファイルを、パスワードで鍵をかけた 1 つのファイルに書き出します。読み込むと、別の Mac にも戻せます。")
        let p1 = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        p1.placeholderString = L("パスワード (8 文字以上)")
        let p2 = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        p2.placeholderString = L("もう一度")
        let links = NSButton(checkboxWithTitle: L("公開したリンクの記録も入れる (更新・公開をやめるための合言葉も)"), target: nil, action: nil)
        links.state = .on
        let history = NSButton(checkboxWithTitle: L("版の履歴も入れる"), target: nil, action: nil)
        history.state = VersionStore.gitAvailable ? .on : .off
        history.isEnabled = VersionStore.gitAvailable
        let stack = NSStackView(views: [p1, p2, links, history])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: stack.fittingSize.height)
        a.accessoryView = stack
        a.addButton(withTitle: L("書き出す…"))
        a.addButton(withTitle: L("キャンセル"))
        a.window.initialFirstResponder = p1
        while true {
            guard a.runModal() == .alertFirstButtonReturn else { return nil }
            if p1.stringValue.count < 8 {
                alert(L("パスワードは 8 文字以上にしてください"), "", nil)
            } else if p1.stringValue != p2.stringValue {
                alert(L("2 つのパスワードが違います"), "", nil)
            } else {
                return (p1.stringValue, links.state == .on, history.state == .on)
            }
        }
    }

    private static func askPassword(title: String, info: String) -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: L("開く"))
        a.addButton(withTitle: L("キャンセル"))
        a.window.initialFirstResponder = f
        return a.runModal() == .alertFirstButtonReturn ? f.stringValue : nil
    }

    private static func alert(_ title: String, _ info: String, _ window: NSWindow?) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
    }
}

/// 時間のかかる処理のあいだに出す小さな知らせ
final class ProgressSheet {
    private let panel: NSPanel
    private weak var parent: NSWindow?

    static func show(_ text: String, on window: NSWindow?) -> ProgressSheet? { ProgressSheet(text, window) }

    private init(_ text: String, _ window: NSWindow?) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 70), styleMask: [.titled], backing: .buffered, defer: false)
        let spin = NSProgressIndicator()
        spin.style = .spinning
        spin.controlSize = .small
        spin.startAnimation(nil)
        let label = NSTextField(labelWithString: text)
        let row = NSStackView(views: [spin, label])
        row.spacing = 10
        row.frame = NSRect(x: 20, y: 22, width: 260, height: 24)
        panel.contentView?.addSubview(row)
        parent = window
        if let w = window { w.beginSheet(panel) } else { panel.center(); panel.makeKeyAndOrderFront(nil) }
    }

    func close() {
        if let w = parent { w.endSheet(panel) } else { panel.orderOut(nil) }
    }
}

/// 設定 > バックアップ: テキスト一覧を書き出す・戻す
final class BackupSettingsPane: NSObject, SettingsPane {
    let title = L("バックアップ")
    let view = NSView()

    override init() {
        super.init()
        let col = NSStackView(views: [
            SettingsUI.label(L("テキスト一覧のファイルを、パスワードで鍵をかけた 1 つのファイルに書き出します。読み込むと、別の Mac にも戻せます。")),
            SettingsUI.row([SettingsUI.button(L("テキストをバックアップ (書き出す)…"), self, #selector(exportBackup(_:))),
                            SettingsUI.button(L("バックアップから戻す (読み込む)…"), self, #selector(importBackup(_:)))]),
            SettingsUI.note(L("入るもの: さとるエディタのフォルダのファイルすべて (フォルダの形のまま)、一覧に出ている「ほかの場所」のテキスト、表示 (作文など)・ピン・ロック・日時、版の履歴、フォルダのアイコンと並び、公開したリンクの記録。")),
            SettingsUI.note(L("戻すときは、今あるファイルは消しません。同じ名前で中身が違うものは「(バックアップ)」を付けて別に置きます。パスワードを忘れると、このバックアップは開けません。")),
        ])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 8
        // 版の記録 (git)
        versions.target = self
        versions.action = #selector(versionsChanged(_:))
        let vcol = NSStackView(views: [
            versions,
            SettingsUI.note(L("保存するたびに、そのテキストの中身を記録します (自動保存が続くあいだは 20 秒ごとに 1 つにまとめます。⌘S で保存したときは、すぐ記録します)。ファイル > 版の履歴… や、テキスト一覧の右クリックから、前の版を見たり、今との違いを見たり、戻したりできます。")),
            SettingsUI.note(L("記録はこの Mac の中 (~/.satoruEditor/history) に、テキストごとの git で置きます。あなたのフォルダには何も作りません。Finder で動かしたり名前を変えたりしても履歴はついていき、テキストを削除すると履歴も消えます。暗号化した文書は記録しません。")),
            SettingsUI.row([SettingsUI.label(L("テキストごとに残す版の数")), maxPopup,
                            SettingsUI.label(L("(それより古い版は消えます)"), small: true)]),
            SettingsUI.row([SettingsUI.button(L("記録の場所を Finder で開く"), self, #selector(revealVersions(_:)))]),
        ])
        if !VersionStore.gitAvailable {
            vcol.addArrangedSubview(SettingsUI.note(L("git が見つかりません。Mac の「コマンドライン・デベロッパ・ツール」を入れると使えます。")))
        }
        vcol.orientation = .vertical
        vcol.alignment = .leading
        vcol.spacing = 8
        _ = SettingsUI.fill(view, with: [SettingsUI.box(L("テキストのバックアップ"), col), SettingsUI.box(L("版の記録 (git)"), vcol), NSView()])
        willShow()
    }

    private let versions = NSButton(checkboxWithTitle: L("保存のたびに、テキストごとの版を残す"), target: nil, action: nil)
    private lazy var maxPopup: NSPopUpButton = {
        let p = NSPopUpButton()
        VersionStore.maxChoices.forEach { p.addItem(withTitle: L("{0} 個まで", $0)) }
        p.target = self
        p.action = #selector(maxChanged(_:))
        return p
    }()

    func willShow() {
        versions.state = VersionStore.isOn ? .on : .off
        versions.isEnabled = VersionStore.gitAvailable
        maxPopup.selectItem(at: VersionStore.maxChoices.firstIndex(of: VersionStore.maxVersions) ?? 1)
        maxPopup.isEnabled = VersionStore.gitAvailable
    }

    /// 残す版の数を変えた: 減らしたときは、今ある履歴もその数まで消す (消す前に確かめる)
    @objc private func maxChanged(_ sender: NSPopUpButton) {
        let n = VersionStore.maxChoices[max(0, sender.indexOfSelectedItem)]
        if n < VersionStore.maxVersions {
            let a = NSAlert()
            a.messageText = L("残す版を {0} 個までにしますか？", n)
            a.informativeText = L("今ある履歴も、テキストごとに新しい {0} 個だけ残して、それより古い版は消します。元に戻せません。", n)
            a.addButton(withTitle: L("減らす"))
            a.addButton(withTitle: L("キャンセル"))
            guard a.runModal() == .alertFirstButtonReturn else { return willShow() }
        }
        UserDefaults.standard.set(n, forKey: VersionStore.maxKey)
        VersionStore.pruneAll()
    }

    @objc private func versionsChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: VersionStore.prefKey)
    }

    @objc private func revealVersions(_ sender: Any?) {
        try? FileManager.default.createDirectory(at: VersionStore.repo, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([VersionStore.repo])
    }

    @objc private func exportBackup(_ sender: Any?) { LibraryBackupUI.export(from: view.window) }
    @objc private func importBackup(_ sender: Any?) { LibraryBackupUI.importBackup(from: view.window) }
}
