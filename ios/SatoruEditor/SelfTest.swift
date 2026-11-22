import UIKit
import HinokiCore

/// 動作確認 (シミュレータで画面を自動で動かして画像に撮る)。アプリ本体の動きには関わらない。
///
/// 環境変数 (simctl launch では SIMCTL_CHILD_ を前に付ける):
///   SATORU_SELFTEST     = library | editor | genko | genkoH | ai | share | links  (どれを確かめるか)
///   SATORU_SEED         = 1 なら、見本のテキストを作り直してから始める
///   SATORU_AI_BASE_URL  = 偽の AI (OpenAI 互換) のアドレス。例 http://127.0.0.1:8765/v1
///   SATORU_SHARE_PUBLISH= 1 なら、本当に docs.satoru.net に 1 件公開し、すぐ公開をやめる (id を記録に書く)
///   SATORU_LANG         = ja | en  (言語を決めて始める)
///   SATORU_CLOUD_DIR    = cloud のとき、このフォルダを iCloud コンテナの Documents の代わりにする
/// 画像はアプリの「書類/.selftest/」に書く (scripts/selftest.sh が取り出す)。結果は .selftest/log.txt
enum SelfTest {
    static var mode: String? { ProcessInfo.processInfo.environment["SATORU_SELFTEST"] }
    static var isRunning: Bool { mode != nil }
    static var aiFinished: (() -> Void)?
    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    static var outDir: URL { Library.localRoot.appendingPathComponent(".selftest", isDirectory: true) }

    /// 起動の最初 (画面を作る前)
    static func prepare() {
        if let lang = env["SATORU_LANG"] {
            UserDefaults.standard.set(lang, forKey: "language")
            IOSStrings.applyLanguage()
        }
        if let base = env["SATORU_AI_BASE_URL"] {
            AISettings.baseURLOverrideForTesting[.custom] = base
            AISettings.provider = .custom
            if AISettings.model(.custom).isEmpty { AISettings.setModel("gpt-6-luna", .custom) }
            AISettings.markVerified(.custom)
        }
        guard isRunning else { return }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try? "".write(to: outDir.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        if env["SATORU_SEED"] == "1" { seed() }
        if mode == "cloud", let dir = env["SATORU_CLOUD_DIR"], !dir.isEmpty {
            LibraryLocation.overrideForTesting = URL(fileURLWithPath: dir, isDirectory: true)
            LibraryLocation.prefersICloud = true
        }
        // キーチェーンに書けるか (API キーの置き場所)
        let ok = Keychain.set("test-key", for: "selftest") && Keychain.get("selftest") == "test-key"
        Keychain.delete("selftest")
        log("keychain \(ok ? "ok" : "FAIL") deleted=\(Keychain.get("selftest") == nil)")
    }

    static func log(_ s: String) {
        print("SELFTEST " + s)
        let u = outDir.appendingPathComponent("log.txt")
        if let h = try? FileHandle(forWritingTo: u) {
            h.seekToEndOfFile()
            h.write(Data((s + "\n").utf8))
            try? h.close()
        }
    }

    /// いまの画面を画像に撮る (アラートなど、上に出ているものも入る。キーボードは別の窓なので入らない)
    static func snap(_ name: String) {
        guard let w = (UIApplication.shared.delegate as? AppDelegate)?.window else { return }
        let r = UIGraphicsImageRenderer(bounds: w.bounds)
        let img = r.image { _ in
            for win in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows }) where !win.isHidden {
                win.drawHierarchy(in: win.frame, afterScreenUpdates: true)
            }
            if UIApplication.shared.connectedScenes.isEmpty { w.drawHierarchy(in: w.bounds, afterScreenUpdates: true) }
        }
        try? img.pngData()?.write(to: outDir.appendingPathComponent(name + ".png"))
        log("snap \(name)")
    }

    // MARK: 見本

    static let essay = """
遠足の思い出
山田 花子

　十月の遠足で、私たちは高尾山に登りました。朝早く学校に集まり、電車に乗って出発しました。
　山道は思ったより急で、途中で足が痛くなりました。でも、友だちと「がんばろう」と声をかけ合いながら、一歩ずつ登りました。
　頂上に着くと、遠くに富士山が見えました。お弁当を食べながら見た景色は、今までで一番きれいでした。
"""
    static let memo = """
買い物メモ
・牛乳
・食パン
・たまご 10 個

明日の予定
10:00 会議 (第2会議室)
13:30 歯医者
連絡先: 090-1234-5678
"""
    static let english = """
Meeting notes
- Ship the iPhone version
- Check the manuscript view on iPad
"""

    static func seed() {
        let fm = FileManager.default
        for u in (try? fm.contentsOfDirectory(at: Library.localRoot, includingPropertiesForKeys: nil)) ?? [] where u.lastPathComponent != ".selftest" {
            try? fm.removeItem(at: u)
        }
        UserDefaults.standard.removeObject(forKey: "sharedLinks")
        func write(_ name: String, _ text: String, folder: String?, mode: String?, ago: TimeInterval) {
            let dir = Library.folderURL(folder, in: Library.localRoot)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let u = dir.appendingPathComponent(name)
            try? text.data(using: .utf8)?.write(to: u)
            Library.setMode(mode, for: u)
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-ago)], ofItemAtPath: u.path)
        }
        write("遠足の思い出.txt", essay, folder: "学校", mode: "genko", ago: 4 * 60)
        write("買い物メモ.txt", memo, folder: nil, mode: nil, ago: 2 * 3600)
        write("Meeting notes.md", english, folder: "仕事", mode: nil, ago: 26 * 3600)
        write("日記.txt", "今日は雨だった。\n傘を忘れて、駅まで走った。\n", folder: nil, mode: "genkoH", ago: 3 * 86400)
        log("seeded")
    }

    // MARK: 進め方

    private static func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }
    private static var library: LibraryViewController? { (UIApplication.shared.delegate as? AppDelegate)?.library }
    private static func url(_ name: String) -> URL? { Library.items().first { $0.url.lastPathComponent == name }?.url }

    static func start() {
        guard let m = mode else { return }
        log("start \(m) lang=\(I18n.language)")
        after(1.2) {
            switch m {
            case "library": runLibrary()
            case "editor": runEditor()
            case "genko", "genkoH": runGenko(horizontal: m == "genkoH")
            case "ai": runAI()
            case "share": runShare()
            case "links": runLinks()
            case "cloud": runCloud()
            case "nocloud": runNoCloud()
            default: log("unknown mode")
            }
        }
    }

    static func runLibrary() {
        snap("library")
        library?.setFilter("学校")
        after(0.6) {
            snap("library-folder")
            library?.setFilter(nil)
            // 作る → 一覧に出る → 名前を変える → フォルダへ移す → 消す
            guard let u = Library.createBlank(in: nil, mode: "genko") else { return log("FAIL create") }
            log("created \(u.lastPathComponent)")
            let renamed = try? Library.rename(u, to: "テスト作文")
            log("renamed \(renamed?.lastPathComponent ?? "FAIL")")
            if let r = renamed, let moved = try? Library.move(r, toFolder: "学校") {
                log("moved \(moved.deletingLastPathComponent().lastPathComponent)/\(moved.lastPathComponent) mode=\(Library.mode(of: moved) ?? "nil")")
                after(0.5) {
                    snap("library-after-create")
                    try? Library.delete(moved)
                    log("deleted exists=\(FileManager.default.fileExists(atPath: moved.path))")
                    library?.navigationItem.searchController?.searchBar.text = "富士山"
                    library?.updateSearchResults(for: library!.navigationItem.searchController!)
                    after(0.6) {
                        snap("library-search")
                        log("done")
                    }
                }
            }
        }
    }

    static func runEditor() {
        Prefs.lineNumbers = true
        guard let u = url("買い物メモ.txt"), let ed = library?.open(u) else { return log("FAIL open") }
        after(1.0) {
            snap("editor")
            ed.textView.selectedRange = NSRange(location: 0, length: 0)
            ed.textView.becomeFirstResponder()
            ed.textView.insertText("追加の行\n")
            after(1.6) {
                let saved = (try? String(contentsOf: ed.doc.url, encoding: .utf8)) ?? ""
                log("saved-first-line \(saved.components(separatedBy: "\n").first ?? "")")
                ed.setMode("genko")
                after(1.0) {
                    log("mode-after-switch \(Library.mode(of: ed.doc.url) ?? "nil")")
                    ed.setMode(nil)
                    snap("editor-typed")
                    log("done")
                }
            }
        }
    }

    static func runGenko(horizontal: Bool) {
        let name = horizontal ? "日記.txt" : "遠足の思い出.txt"
        guard let u = url(name), let ed = library?.open(u) else { return log("FAIL open") }
        after(1.8) {
            log("ruby \(ed.genko.ruby.count) sheets \(Genko.sheetCount(ed.genko.columns))")
            snap(horizontal ? "genkoH" : "genko")
            // マスをタップしたのと同じ: 3 段落目の頭にカーソルを置いて書く
            let ns = ed.textView.text as NSString
            let loc = horizontal ? ns.length : ns.range(of: "　山道").location
            ed.textView.becomeFirstResponder()
            ed.textView.selectedRange = NSRange(location: loc, length: 0)
            ed.textView.insertText(horizontal ? "夜は晴れた。" : "（ここに書き足し）")
            after(1.5) {
                snap(horizontal ? "genkoH-edit" : "genko-edit")
                log("text-has-insert \(ed.textView.text.contains(horizontal ? "夜は晴れた。" : "（ここに書き足し）"))")
                ed.textView.resignFirstResponder()
                log("done")
            }
        }
    }

    static func runAI() {
        guard let u = url("遠足の思い出.txt"), let ed = library?.open(u) else { return log("FAIL open") }
        after(1.0) {
            ed.openAI()
            after(1.0) {
                guard let nav = ed.presentedViewController as? UINavigationController, let ai = nav.viewControllers.first as? AIViewController else { return log("FAIL ai sheet") }
                (nav.sheetPresentationController)?.animateChanges { nav.sheetPresentationController?.selectedDetentIdentifier = .large }
                snap("ai-sheet")
                aiFinished = {
                    after(0.5) {
                        snap("ai-answer")
                        let before = ed.textView.text ?? ""
                        ai.perform(Selector(("replacePressed")))
                        after(0.6) {
                            let after_ = ed.textView.text ?? ""
                            log("replaced changed=\(before != after_) len=\((after_ as NSString).length)")
                            nav.dismiss(animated: true)
                            after(1.0) {
                                snap("ai-replaced")
                                log("done")
                            }
                        }
                    }
                }
                ai.run(AIViewController.presets[0])
            }
        }
    }

    static func runShare() {
        // 本当に公開するときは、個人情報のない作文 (原稿用紙の並び・ふりがなも送る) を使う
        let name = env["SATORU_SHARE_PUBLISH"] == "1" ? "遠足の思い出.txt" : "買い物メモ.txt"
        guard let u = url(name), let ed = library?.open(u) else { return log("FAIL open") }
        after(1.0) {
            ed.startShare()
            after(1.0) {
                snap("share-privacy")
                // 「このまま公開する」と同じ
                guard let alert = ed.presentedViewController as? UIAlertController else {
                    log("no privacy alert")
                    return continueShare(ed)
                }
                log("privacy-alert \(alert.message?.components(separatedBy: "\n").first ?? "")")
                alert.dismiss(animated: false) {
                    let vc = ShareFormViewController(text: ed.textView.text, mode: ShareStore.serverMode(ed.doc.mode), file: ed.doc.url)
                    ed.present(UINavigationController(rootViewController: vc), animated: true)
                    continueShare(ed, form: vc)
                }
            }
        }
    }

    private static func continueShare(_ ed: EditorViewController, form: ShareFormViewController? = nil) {
        after(1.0) {
            snap("share-form")
            log("body-keys " + ShareStore.body(text: "テスト", mode: "genko", form: ShareStore.Form()).keys.sorted().joined(separator: ","))
            guard env["SATORU_SHARE_PUBLISH"] == "1" else { return log("done (no publish)") }
            guard let form = form ?? ((ed.presentedViewController as? UINavigationController)?.viewControllers.first as? ShareFormViewController) else { return log("FAIL no form") }
            form.titleForTesting = "さとるエディタ iOS 版の動作確認 (すぐ消します)"
            ShareFormViewController.onPublishedForTesting = { r in
                log("published id=\(r.id) url=\(r.url)")
                after(1.0) {
                    snap("share-published")
                    ed.presentedViewController?.presentedViewController?.dismiss(animated: false)
                    ed.presentedViewController?.dismiss(animated: false)
                    after(0.5) {
                        let links = SharedLinksViewController()
                        ed.present(UINavigationController(rootViewController: links), animated: false)
                        after(1.0) {
                            snap("share-links")
                            // 確かめ終わったら、すぐ公開をやめる
                            ShareStore.unpublish(r) { ok in
                                log("unpublished id=\(r.id) ok=\(ok)")
                                // 本当に消えたか: もう読めないこと
                                URLSession.shared.dataTask(with: URL(string: r.url)!) { _, resp, _ in
                                    log("after-delete status=\((resp as? HTTPURLResponse)?.statusCode ?? 0)")
                                    DispatchQueue.main.async {
                                        after(0.8) { snap("share-links-after"); log("done") }
                                    }
                                }.resume()
                            }
                        }
                    }
                }
            }
            form.publish()
        }
    }

    static func runLinks() {
        // 記録だけ作って一覧を見る (サーバには送らない)
        ShareStore.records = [ShareStore.Record(id: "example", url: "https://docs.satoru.net/r/example", token: "x", title: "遠足の思い出",
                                                visibility: "unlisted", created: Date().addingTimeInterval(-600), expires: Date().addingTimeInterval(30 * 86400),
                                                path: "学校/遠足の思い出.txt", contentHash: nil, keepHistory: true)]
        after(0.5) {
            snap("library-shared-badge")
            library?.present(UINavigationController(rootViewController: SharedLinksViewController()), animated: false)
            after(0.8) {
                snap("links")
                ShareStore.records = []
                log("done")
            }
        }
    }

    // MARK: iCloud Drive のフォルダ (シミュレータでは、Mac のふつうのフォルダを選んだことにして確かめる)

    private static func waitUntil(_ timeout: Double, _ cond: @escaping () -> Bool, _ then: @escaping (Bool) -> Void) {
        let start = Date()
        func tick() {
            if cond() { then(true) } else if Date().timeIntervalSince(start) > timeout { then(false) } else { after(0.3) { tick() } }
        }
        tick()
    }

    private static var topEditor: EditorViewController? { library?.navigationController?.topViewController as? EditorViewController }
    private static func back() { library?.navigationController?.popToRootViewController(animated: false) }
    private static func rawAttr(_ u: URL, _ name: String) -> String {
        Library.appAttributes(of: u)["net.satoru.satoruEditor." + name].map { String(decoding: $0, as: UTF8.self) } ?? "nil"
    }

    static func runCloud() {
        guard LibraryLocation.isICloud else { return log("FAIL not using iCloud") }
        log("location \(LibraryLocation.displayName) root=\(Library.root.path)")
        library?.reload()
        for i in Library.items() {
            log("item \(i.folder.map { $0 + "/" } ?? "")\(i.url.lastPathComponent) mode=\(i.mode ?? "nil") placeholder=\(i.isPlaceholder)")
        }
        snap("cloud-library")
        // タブを「この iPhone」に → 日記を iCloud に移す (表示の拡張属性もついていく) → タブを iCloud に戻す
        LibraryLocation.prefersICloud = false
        log("tab-local icloud=\(LibraryLocation.isICloud) items=\(Library.items().count)")
        after(0.6) {
            snap("cloud-tab-local")
            guard let d = Library.items().first(where: { $0.name == "日記" }) else { return log("FAIL no local diary") }
            library?.moveToOtherPlace(d)
            after(1.0) {
                let moved = Library.items(in: LibraryLocation.iCloudDocuments!).first { $0.name.hasPrefix("日記 ") }
                log("moved-to-icloud \(moved?.url.lastPathComponent ?? "nil") mode=\(moved?.mode ?? "nil") local-left=\(FileManager.default.fileExists(atPath: d.url.path))")
                LibraryLocation.prefersICloud = true
                after(0.6) { cloudOpenSteps() }
            }
        }
    }

    private static func cloudOpenSteps() {
        after(0.1) {
            snap("cloud-library-moved")
            // Mac で原稿用紙にしたテキスト
            guard let g = url("春の作文.txt"), let ed = library?.open(g) else { return log("FAIL open genko") }
            after(1.5) {
                log("genko-open mode=\(ed.doc.mode ?? "nil") isGenko=\(ed.isGenko)")
                snap("cloud-genko")
                back()
                // iCloud にだけあるもの (.クラウドだけ.txt.icloud): 開くと待ち、Mac 側で中身が届いたら開く
                guard let p = Library.items().first(where: { $0.isPlaceholder }) else { return log("FAIL no placeholder") }
                library?.open(p.url)
                after(0.8) {
                    snap("cloud-downloading")
                    log("await download")
                    waitUntil(25, { topEditor?.doc.url.lastPathComponent == p.url.lastPathComponent }) { ok in
                        log("downloaded-open \(ok) mode=\(topEditor?.doc.mode ?? "nil") text=\(topEditor?.textView.text.prefix(10) ?? "")")
                        after(1.2) {
                            snap("cloud-downloaded")
                            back()
                            cloudExternalEdit()
                        }
                    }
                }
            }
        }
    }

    /// 開いているあいだに Mac 側で書き換える → 読み直す。こちらでも書き換えていたら、両方残す
    private static func cloudExternalEdit() {
        guard let m = url("Macのメモ.txt"), let ed = library?.open(m) else { return log("FAIL open memo") }
        after(1.0) {
            log("await external-edit")
            waitUntil(25, { ed.textView.text.contains("Mac で書き足した行") }) { ok in
                log("reloaded \(ok) dirty=\(ed.doc.isDirty)")
                after(0.3) {
                    snap("cloud-reloaded")
                    // 食い違い: ほかの端末で書いたあとに、こちらでも書く (見直しを止めて、保存のときに気づくか)
                    ed.pauseDiskCheckForTesting = true
                    let other = "Macのメモ\n別の端末で書いた版\n"
                    try? other.data(using: .utf8)?.write(to: ed.doc.url)
                    try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: ed.doc.url.path)
                    ed.textView.becomeFirstResponder()
                    ed.textView.selectedRange = NSRange(location: (ed.textView.text as NSString).length, length: 0)
                    ed.textView.insertText("iPhone で書いた行\n")
                    after(2.5) {
                        let mine = (try? String(contentsOf: ed.doc.url, encoding: .utf8)) ?? ""
                        let copy = ed.doc.url.deletingLastPathComponent().appendingPathComponent("Macのメモ (別の端末).txt")
                        let theirs = (try? String(contentsOf: copy, encoding: .utf8)) ?? ""
                        log("conflict mine-kept=\(mine.contains("iPhone で書いた行")) other-kept=\(theirs == other)")
                        ed.textView.resignFirstResponder()
                        after(0.5) {
                            snap("cloud-conflict")
                            ed.presentedViewController?.dismiss(animated: false)
                            ed.pauseDiskCheckForTesting = false
                            back()
                            cloudKeepsAttributes()
                        }
                    }
                }
            }
        }
    }

    /// Mac 版の表示 (a4) と変更履歴の id は、iPhone で書いて保存しても消えない
    private static func cloudKeepsAttributes() {
        guard let a = url("A4の書類.txt"), let ed = library?.open(a) else { return log("FAIL open a4") }
        after(1.0) {
            log("a4-open mode=\(ed.doc.mode ?? "nil") (editor)")
            ed.textView.selectedRange = NSRange(location: 0, length: 0)
            ed.textView.insertText("追記 ")
            after(2.0) {
                log("after-save mode=\(rawAttr(a, "mode#S")) history=\(rawAttr(a, "history#S"))")
                back()
                library?.present(UINavigationController(rootViewController: SettingsViewController()), animated: false)
                after(0.8) {
                    snap("cloud-settings")
                    library?.dismiss(animated: false)
                    after(0.5) {
                        snap("cloud-library-final")
                        log("done")
                    }
                }
            }
        }
    }

    /// iCloud が使えない (シミュレータ・サインインしていない): この iPhone の中を使い、設定に書いておく
    static func runNoCloud() {
        waitUntil(10, { if case .checking = LibraryLocation.iCloud { return false }; return true }) { _ in
            log("nocloud icloud=\(LibraryLocation.isICloud) name=\(LibraryLocation.displayName) items=\(Library.items().count)")
            library?.present(UINavigationController(rootViewController: SettingsViewController()), animated: false)
            after(0.8) {
                snap("nocloud-settings")
                library?.dismiss(animated: false)
                log("done")
            }
        }
    }
}
