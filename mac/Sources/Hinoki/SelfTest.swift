import AppKit
import HinokiCore

/// 開発用: 画面を絵に保存して確かめる。環境変数 SATORU_SNAPSHOT_DIFF=ファイル のときだけ動く。
/// ファイルを開き、少し書き換えて差分の欄を出し、ウインドウを ファイル.png に保存して終わる
enum SelfTest {
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["SATORU_SNAPSHOT_DIFF"] else { return }
        let url = URL(fileURLWithPath: path)
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, _ in
            guard let doc = doc as? Document, let ed = doc.editor else { NSApp.terminate(nil); return }
            // サイト用の画面: ほかのタブ (起動のときの空の文書) を閉じて、タブの帯を出さない
            if ProcessInfo.processInfo.environment["SATORU_SNAPSHOT_SINGLE"] != nil {
                for w in ed.window?.tabbedWindows ?? [] where w !== ed.window {
                    if let d = (w.windowController as? NSWindowController)?.document as? NSDocument, !d.isDocumentEdited { d.close() }
                }
                // タブの帯は、起動の引数 -NSWindowTabbingShoudShowTabBarKey-SatomaruEditor NO で隠す
                // (ここで切り替えると、ふだんの設定まで書き換わってしまう)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let tv = ed.textView
                let ns = tv.string as NSString
                // 2 行目を書き換え、途中に 1 行足す
                let line2 = ns.lineRange(for: NSRange(location: ns.lineRange(for: NSRange(location: 0, length: 0)).length, length: 0))
                let mode = ProcessInfo.processInfo.environment["SATORU_SNAPSHOT_MODE"] ?? "diff"
                // 窓の大きさ (サイトの画像用): SATORU_SNAPSHOT_SIZE=幅x高さ (pt)
                if let size = ProcessInfo.processInfo.environment["SATORU_SNAPSHOT_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
                    ed.window?.setContentSize(NSSize(width: size[0], height: size[1]))
                }
                // 選択の見え方の確認用: SATORU_SNAPSHOT_SELECT=位置,長さ
                if let sel = ProcessInfo.processInfo.environment["SATORU_SNAPSHOT_SELECT"]?.split(separator: ",").compactMap({ Int($0) }),
                   sel.count == 2, sel[0] + sel[1] <= ns.length {
                    tv.setSelectedRange(NSRange(location: sel[0], length: sel[1]))
                }
                if mode == "a4shot" || mode == "genkoshot" {
                    ed.applyPaperMode(mode == "a4shot" ? .a4 : .genko)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        if let s = ed.screenshot(scope: .visible), let data = Screenshot.png(s) {
                            try? data.write(to: url.appendingPathExtension("a4.png"))
                        }
                    }
                } else if mode == "selshot" {
                    // 選択の見え方の確認用: SATORU_SNAPSHOT_SELECT=位置,長さ (genkoshot でも効く)
                } else if mode == "shot" {
                    // スクリーンショットの「アプリ全体」で撮った画像を、そのまま書き出す
                    if let s = ed.screenshot(scope: .window), let data = Screenshot.png(s) {
                        try? data.write(to: url.appendingPathExtension("window.png"))
                    }
                } else if mode == "collab" {
                    // 共有を始めて、チャット欄 (ログ) とフッターの人数を撮る
                    try? ed.beginHosting(name: "selftest", port: 7651)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                        if let w = ed.window, let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                            v.cacheDisplay(in: v.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathExtension("collab.png"))
                        }
                        ed.stopShareHM(nil)
                    }
                } else if mode == "sharedialog" {
                    // リンクで公開の画面 (シート) を撮る
                    ed.shareLinkHM(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if let sheet = ed.window?.attachedSheet, let v = sheet.contentView?.superview ?? sheet.contentView,
                           let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                            v.cacheDisplay(in: v.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathExtension("sheet.png"))
                        }
                    }
                } else if mode == "multisel" {
                    // テキスト一覧で 1 行目と 3 行目をいっしょに選んだところを撮る
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        func find(_ v: NSView) -> LibraryTableView? {
                            if let t = v as? LibraryTableView { return t }
                            for s in v.subviews { if let t = find(s) { return t } }
                            return nil
                        }
                        if ProcessInfo.processInfo.environment["SATORU_TEST_FOLDERS"] != nil {
                            // フォルダの欄で 2 つ選ぶ (行 3 と 4)
                            func findOutline(_ v: NSView) -> NSOutlineView? {
                                if let o = v as? NSOutlineView { return o }
                                for s in v.subviews { if let o = findOutline(s) { return o } }
                                return nil
                            }
                            if let c = ed.window?.contentView, let o = findOutline(c) { o.selectRowIndexes([2, 3], byExtendingSelection: false) }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                FileHandle.standardError.write("FOLDERS sel=\(TextLibrary.selectedGroup.replacingOccurrences(of: "\n", with: "|"))\n".data(using: .utf8)!)
                            }
                        } else if let c = ed.window?.contentView, let t = find(c) { t.selectRowIndexes([0, 2], byExtendingSelection: false) }
                    }
                } else if mode == "versionsui" {
                    // ふつうの使い方: 本文を書き換える → 自動保存 → メニュー「版の履歴…」→ 窓を撮る
                    tv.insertText("書き足した行\n", replacementRange: NSRange(location: 0, length: 0))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        tv.insertText("もう一行\n", replacementRange: NSRange(location: 0, length: 0))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            ed.versionHistoryHM(nil)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                FileHandle.standardError.write("VUI count=\(VersionStore.history(url).count) windows=\(NSApp.windows.filter { $0.windowController is VersionHistoryWindowController }.count)\n".data(using: .utf8)!)
                                if let w = NSApp.windows.first(where: { $0.windowController is VersionHistoryWindowController }),
                                   let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                                    v.cacheDisplay(in: v.bounds, to: rep)
                                    try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathExtension("versions.png"))
                                }
                            }
                        }
                    }
                } else if mode == "prune" {
                    // 版の上限 (起動の引数 -versionHistoryMax 3): 15 回保存して、古い版が消えるかを見る
                    let f = url.deletingLastPathComponent().appendingPathComponent("p.txt")
                    var n = 0
                    func step() {
                        n += 1
                        try? "版 \(n)\n".write(to: f, atomically: false, encoding: .utf8)
                        VersionStore.noteSaved(f, now: true)
                        if n < 15 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: step); return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            let before = VersionStore.history(f).count
                            VersionStore.pruneAll()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                let h = VersionStore.history(f)
                                let oldest = h.last.flatMap { VersionStore.content($0, of: f) }.map { String(decoding: $0, as: UTF8.self) } ?? "nil"
                                let newest = h.first.flatMap { VersionStore.content($0, of: f) }.map { String(decoding: $0, as: UTF8.self) } ?? "nil"
                                FileHandle.standardError.write("PRUNE max=\(VersionStore.maxVersions) before=\(before) after=\(h.count) oldest=\(oldest.trimmingCharacters(in: .newlines)) newest=\(newest.trimmingCharacters(in: .newlines))\n".data(using: .utf8)!)
                            }
                        }
                    }
                    step()
                } else if mode == "ctxmenu" {
                    // テキスト一覧の右クリックのメニューの中身を書き出す (版の表示を確かめる)
                    tv.insertText("足した\n", replacementRange: NSRange(location: 0, length: 0))
                    ed.hdoc?.save(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        VersionStore.flushAll()
                        if let item = TextLibrary.items().first(where: { $0.url.lastPathComponent == url.lastPathComponent }) {
                            let titles = TextLibrary.contextMenu(for: item, target: TextLibraryActions.shared).items.prefix(8).map { $0.isSeparatorItem ? "---" : $0.title }
                            FileHandle.standardError.write(("MENU " + titles.joined(separator: " | ") + "\n").data(using: .utf8)!)
                        }
                    }
                } else if mode == "versions" {
                    // 版の記録: Finder で動かす・複製する・削除する・バックアップから戻す、を確かめる
                    let dir = url.deletingLastPathComponent()
                    let fm = FileManager.default
                    let a = dir.appendingPathComponent("v.txt"), b = dir.appendingPathComponent("sub/動かした.txt"), c = dir.appendingPathComponent("複製.txt")
                    try? fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
                    func save(_ u: URL, _ t: String) { try? t.write(to: u, atomically: false, encoding: .utf8); VersionStore.noteSaved(u, now: true) }
                    func log(_ s: String) { FileHandle.standardError.write(("VERSIONS " + s + "\n").data(using: .utf8)!) }
                    save(a, "一版目\n")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        // Finder で動かしたのと同じ (アプリには知らせない)
                        try? fm.moveItem(at: a, to: b)
                        save(b, "一版目\n動かしたあとに足した\n")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            log("afterFinderMove=\(VersionStore.history(b).count)")
                            // Finder で複製したのと同じ (拡張属性も写る)
                            try? fm.copyItem(at: b, to: c)
                            save(c, "複製に足した\n")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                let idB = VersionStore.historyID(of: b), idC = VersionStore.historyID(of: c)
                                log("copy=\(VersionStore.history(c).count) original=\(VersionStore.history(b).count) differentIDs=\(idB != idC)")
                                // バックアップ (履歴も) → 消す → 戻す
                                let arch = LibraryBackupUI.collect(withLinks: false, withHistory: true)
                                let withHist = arch.entries.filter { ($0.history?.count ?? 0) > 0 }.count
                                VersionStore.forget([c])
                                try? fm.removeItem(at: c)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                    let gone = idC.map { !fm.fileExists(atPath: VersionStore.repo.appendingPathComponent($0).path) } ?? false
                                    log("entriesWithHistory=\(withHist) deletedHistoryGone=\(gone)")
                                    let r = LibraryBackupUI.restore(arch)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                        let h = VersionStore.history(c)
                                        let oldest = h.last.flatMap { VersionStore.content($0, of: c) }.map { String(decoding: $0, as: UTF8.self) } ?? "nil"
                                        log("restored added=\(r.added) restoredHistory=\(h.count) oldest=\(oldest.replacingOccurrences(of: "\n", with: "/"))")
                                        VersionHistoryWindowController.show(for: c)
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                            if let w = NSApp.windows.first(where: { $0.windowController is VersionHistoryWindowController }),
                                               let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                                                v.cacheDisplay(in: v.bounds, to: rep)
                                                try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathExtension("versions.png"))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else if mode == "backup" {
                    // バックアップ: 書き出す → 1 つ消し・1 つ書き換え → 戻す。結果を出す
                    let root = TextLibrary.folder
                    let a = LibraryBackupUI.collect(withLinks: false)
                    let sealed = try? LibraryBackup.seal(a, password: "test-password")
                    let opened = sealed.flatMap { try? LibraryBackup.open($0, password: "test-password") }
                    let wrong = sealed.map { (try? LibraryBackup.open($0, password: "nope")) == nil } ?? false
                    let gone = root.appendingPathComponent("作文/春.txt"), changed = root.appendingPathComponent("メモ/買い物.txt")
                    try? FileManager.default.removeItem(at: gone)
                    try? "書き換えた".write(to: changed, atomically: true, encoding: .utf8)
                    let r = opened.map { LibraryBackupUI.restore($0) }
                    let backCopy = root.appendingPathComponent("メモ/買い物 " + L("(バックアップ)") + ".txt")
                    FileHandle.standardError.write(("BACKUP entries=\(a.entries.count) folders=\(a.folders.count) sealed=\(sealed?.count ?? 0) wrongRejected=\(wrong) "
                        + "added=\(r?.added ?? -1) renamed=\(r?.renamed ?? -1) skipped=\(r?.skipped ?? -1) failed=\(r?.failed ?? -1) "
                        + "restoredMode=\(TextLibrary.fileMode(gone) ?? "nil") restoredText=\((try? String(contentsOf: gone)) ?? "nil") "
                        + "backupCopy=\((try? String(contentsOf: backCopy)) ?? "nil") emptyFolder=\(FileManager.default.fileExists(atPath: root.appendingPathComponent("空").path))\n").data(using: .utf8)!)
                } else if mode == "libopen" {
                    // 履歴から、まだ開いていないファイルを開く: 元のタブの表示・フォルダの選択が変わらないか
                    let env = ProcessInfo.processInfo.environment
                    NSApp.activate(ignoringOtherApps: true)
                    ed.applyPaperMode(.genko)
                    if let g = env["SATORU_TEST_GROUP"] { TextLibrary.selectedGroup = g }
                    func log(_ tag: String) {
                        let docs = NSDocumentController.shared.documents.compactMap { $0 as? Document }
                            .map { "\($0.fileURL?.lastPathComponent ?? "nil")=\($0.editor?.paperMode.rawValue ?? -1)\($0.editor?.horizontalGenko == true ? "H" : "")/\($0.fileURL.flatMap { TextLibrary.fileMode($0) } ?? "-")[\($0.editor?.librarySelection ?? "")]" }
                        let other = env["SATORU_TEST_OPEN"].map { URL(fileURLWithPath: $0) }
                        FileHandle.standardError.write("\(tag) group=\(TextLibrary.selectedGroup) docs=\(docs) xattr=\(other.flatMap { TextLibrary.fileMode($0) } ?? "nil")\n".data(using: .utf8)!)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if env["SATORU_TEST_EDIT"] != nil { tv.insertText("追記", replacementRange: NSRange(location: 0, length: 0)) }
                        log("BEFORE")
                        if let o = env["SATORU_TEST_OPEN"] { TextLibrary.open(URL(fileURLWithPath: o)) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            log("AFTER")
                            // 新しいタブでフォルダを選び直してから、元のタブに戻る
                            FileHandle.standardError.write("NEWTAB front=\(NSApp.orderedWindows.first { $0.windowController is EditorWindowController }?.title ?? "none")\n".data(using: .utf8)!)
                            // 裏で動かしているので、新しいタブを前に出したことを手で伝える
                            if let nb = NSDocumentController.shared.documents.compactMap({ ($0 as? Document)?.editor }).first(where: { $0.hdoc?.fileURL?.path == env["SATORU_TEST_OPEN"] }) {
                                nb.window?.orderFront(nil)
                                nb.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
                            }
                            TextLibrary.selectedGroup = env["SATORU_TEST_GROUP2"] ?? "sub:メモ"
                            log("NEWTAB")
                            ed.window?.orderFront(nil)
                            ed.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification)) // 裏で動かしているので、タブの切り替えを手で伝える
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                FileHandle.standardError.write("BACK key=\(NSApp.keyWindow?.title ?? "none")\n".data(using: .utf8)!)
                                log("BACK")
                            }
                        }
                    }
                } else if mode == "newtext" {
                    // 新規テキスト: 空のカードができ、書くと 1 行目の名前に付け替わるか
                    TextLibrary.createBlankText()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        let docs = NSDocumentController.shared.documents.map { $0.fileURL?.path ?? "nil" }
                        FileHandle.standardError.write(("DOCS " + docs.joined(separator: ", ") + "\n").data(using: .utf8)!)
                        if let d = NSDocumentController.shared.documents.first(where: { TextLibrary.isBlankPlaceholder($0.fileURL) }) as? Document,
                           let tv = d.editor?.textView {
                            tv.insertText("夏の思い出\n海に行きました。", replacementRange: NSRange(location: 0, length: 0))
                            FileHandle.standardError.write("INSERTED edited=\(d.isDocumentEdited)\n".data(using: .utf8)!)
                        }
                    }
                } else if mode == "fileinfo" {
                    // ファイルの情報の窓を撮って閉じる
                    let shotTimer = Timer(timeInterval: 1.0, repeats: false) { _ in
                        if let w = NSApp.modalWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.className.contains("Alert") }),
                           let v = w.contentView?.superview ?? w.contentView,
                           let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                            v.cacheDisplay(in: v.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathExtension("info.png"))
                        }
                        NSApp.abortModal()
                    }
                    RunLoop.main.add(shotTimer, forMode: .common) // 窓が出ている間も動くように
                    let item = NSMenuItem()
                    item.representedObject = url
                    TextLibraryActions.shared.showInfo(item)
                } else if mode == "librarygrid" {
                    ed.showLibraryGrid()
                } else if mode == "settings" {
                    // 設定ウインドウの 1 つのタブ (SATORU_TEST_TAB) を撮る
                    let name = ProcessInfo.processInfo.environment["SATORU_TEST_TAB"] ?? "読み上げ・音声入力"
                    if let tab = SettingsWindowController.Tab(rawValue: name) { SettingsWindowController.shared.show(tab) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if let w = SettingsWindowController.shared.window, let v = w.contentView?.superview ?? w.contentView,
                           let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                            v.cacheDisplay(in: v.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathExtension("settings.png"))
                        }
                    }
                } else if mode == "aiflow" {
                    // 偽の AI (SATORU_TEST_AI の URL) に頼んで、答えが本文に入るかを見る。本物のキーと設定には触れない
                    Keychain.serviceOverrideForTesting = "satoru-selftest"
                    AISettings.baseURLOverrideForTesting[AISettings.provider] = ProcessInfo.processInfo.environment["SATORU_TEST_AI"] ?? ""
                    AISettings.readyOverrideForTesting = true
                    if ProcessInfo.processInfo.environment["SATORU_TEST_GENKO"] != nil { ed.applyPaperMode(.genko) }
                    tv.setSelectedRange(NSRange(location: 0, length: 0))
                    ed.runAI("校正して", kind: .ask, shown: "校正して")
                } else if mode == "publishsample" {
                    // サイト用: いま開いた作文を、原稿用紙のまま公開する (SATORU_PUBLISH_TITLE が題名)。答えは <file>.published.json
                    ed.applyPaperMode(.genko)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        ShareLink.publishForTest(text: tv.string, title: ProcessInfo.processInfo.environment["SATORU_PUBLISH_TITLE"] ?? "",
                                                 mode: "genko", visibility: "unlisted", file: url) { data in
                            try? (data ?? Data()).write(to: url.appendingPathExtension("published.json"))
                        }
                    }
                } else if mode == "aiessay" {
                    // サイト用: 原稿用紙で、偽の AI に作文を書いてもらう (本物のキーと設定には触れない)
                    Keychain.serviceOverrideForTesting = "satoru-selftest"
                    AISettings.baseURLOverrideForTesting[AISettings.provider] = ProcessInfo.processInfo.environment["SATORU_TEST_AI"] ?? ""
                    AISettings.readyOverrideForTesting = true
                    ed.applyPaperMode(.genko)
                    tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                    ed.revealAIPanel()
                    let ask = ProcessInfo.processInfo.environment["SATORU_TEST_AI_TEXT"] ?? "作文を書いて"
                    let kind: AIPanel.ApplyKind = ProcessInfo.processInfo.environment["SATORU_TEST_AI_KIND"] == "ask" ? .ask : .insert
                    if kind == .ask { tv.setSelectedRange(NSRange(location: 0, length: 0)) }
                    ed.runAI(ask, kind: kind, shown: ask)
                } else if mode == "typein" {
                    // AI の答えを入れたときの「打っている」演出: 途中 (0.4 秒) と終わったあと (撮るのは最後) を見る
                    ed.applyPaperMode(.genko)
                    let end = (tv.string as NSString).length
                    let add = "これはAIが書き足した文章です。打っているように一字ずつ出てきます。"
                    _ = tv.replace(NSRange(location: end, length: 0), with: add)
                    ed.typeIn(NSRange(location: end, length: (add as NSString).length))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        if let w = ed.window, let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                            v.cacheDisplay(in: v.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathExtension("mid.png"))
                        }
                    }
                } else if mode == "aigrow" {
                    ed.revealAIPanel()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        ed.fillAIInputForTest(ProcessInfo.processInfo.environment["SATORU_TEST_AI_TEXT"] ?? String(repeating: "この文章をもっとやさしい言い方に直して、子どもにもわかるようにしてください。", count: 3))
                    }
                } else if mode == "aiclose" {
                    // AI の欄を取り出してから赤いボタンで閉じる: 閉じずにエディタの横に戻るはず (あとで本体を撮る)
                    ed.revealAIPanel()
                    ed.toggleAIDetached()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible && $0.title.contains("AI") })?.performClose(nil)
                    }
                } else if mode == "ai" {
                    // AI の欄を出して、別のウインドウに取り出す (取り出したウインドウを撮る)
                    ed.revealAIPanel()
                    ed.toggleAIDetached()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if let w = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible && $0.title.contains("AI") }),
                           let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                            v.cacheDisplay(in: v.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathExtension("ai.png"))
                        }
                    }
                } else {
                    tv.replace(line2, with: "CHANGED LINE 2\nADDED LINE\n")
                    ed.showDiffPanel(true)
                    // カーソルを 6 行目へ (差分の欄の同じ行にも帯が出るはず)
                    tv.goTo(line: 6)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + (mode == "collab" ? 6.0 : mode == "a4shot" || mode == "genkoshot" || mode == "typein" ? 4.0 : mode == "newtext" || mode == "libopen" ? 5.0 : mode == "versions" || mode == "prune" ? 10.0 : mode == "versionsui" ? 9.0 : mode == "aiessay" || mode == "publishsample" ? 7.0 : 2.0)) {
                    if let w = ed.window, let v = w.contentView?.superview ?? w.contentView,
                       let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathExtension("png"))
                    }
                    doc.updateChangeCount(.changeCleared) // 保存の確認を出さずに終わる
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
