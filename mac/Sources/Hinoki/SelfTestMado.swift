import AppKit
import HinokiCore

/// 開発用: 窓割り (Mado*.swift) を組んで、ウインドウを絵に保存して確かめる。環境変数 SATORU_MADO_SNAP=<フォルダ> のときだけ動く。
/// <フォルダ> に例の文書を作って 1 つのウインドウのタブで開き、いろいろな並べ方にして <フォルダ>/mado_*.png に写し、
/// 確かめた結果を標準エラーに「MADO …」の行で書いて終わる。
/// 起動の引数 -madoEnabled YES -madoOpenPlace split で、利用者の設定には書かずに動かす
enum SelfTestMado {
    private static func soon(_ sec: Double, _ f: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + sec, execute: f)
    }

    private static func note(_ s: String) {
        FileHandle.standardError.write(("MADO " + s + "\n").data(using: .utf8)!)
    }

    /// ウインドウ全体 (タイトルバー・ツールバー・タブのバーも) を写す。over があれば、その範囲 (ウインドウの座標) に行き先の見本を重ねる
    private static func snap(_ w: NSWindow, _ path: String, over: (NSRect, String?)? = nil) {
        guard let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let (r, label) = over, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            let pv = SplitDropPreviewView(frame: NSRect(origin: .zero, size: r.size))
            pv.label = label
            if let prep = pv.bitmapImageRepForCachingDisplay(in: pv.bounds) {
                pv.cacheDisplay(in: pv.bounds, to: prep)
                prep.draw(in: r.insetBy(dx: 2, dy: 2))
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        note("snap \(path)")
    }

    private static let samples: [(String, String)] = [
        ("はじめに.txt", "窓割りのためし書き\n\nちがうタブの文書を、1 つのウインドウに並べます。\n左右にも上下にも並べられます。\n"),
        ("メモ.md", "# メモ\n\n- 左の画面: はじめに\n- 右の画面: このメモ\n- 下の画面: プログラム\n"),
        ("sample.swift", "import Foundation\n\nfunc hello(_ name: String) -> String {\n    \"こんにちは、\\(name)\"\n}\n\nprint(hello(\"さとる\"))\n"),
        ("原稿.txt", "　吾輩は猫である。名前はまだ無い。\n　どこで生れたかとんと見当がつかぬ。何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している。\n"),
    ]

    /// サイトの紹介用: SATORU_MADO_SITE=<出力.png>。左に作文 (縦書きの原稿用紙)、右にそのメモを並べて撮る
    private static func siteShot(_ out: String) {
        let base = URL(fileURLWithPath: out).deletingLastPathComponent().appendingPathComponent("mado-site", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let files = [
            ("春の遠足.txt", "春の遠足\n山田花子\n\n　先週の金曜日、学校の遠足で動物園に行きました。天気はとても良くて、朝から楽しみでした。\n「早く行こう。」\nと、友だちが言いました。\n　入り口を入ると、すぐに大きな象がいました。長い鼻で水をあびている様子は、とても気持ちよさそうでした。\n"),
            ("遠足メモ.md", "# 遠足メモ\n\n## 見たもの\n- 象: 長い鼻で水をあびていた\n- キリン: 首がとても長い\n- ペンギン: 歩き方がかわいい\n\n## 書きたいこと\n- 朝から楽しみだった気持ち\n- 友だちの「早く行こう。」\n- 象がいちばん心に残った\n"),
        ]
        let urls = files.map { f -> URL in
            let u = base.appendingPathComponent(f.0)
            try? f.1.write(to: u, atomically: true, encoding: .utf8)
            return u
        }
        soon(1.0) {
            for d in NSDocumentController.shared.documents where d.fileURL == nil && !d.isDocumentEdited { d.close() }
            open(urls, []) { eds in
                guard eds.count == 2, let host = eds[0].window else { exit(1) }
                host.setContentSize(NSSize(width: 900, height: 690))
                host.tabGroup?.selectedWindow = host
                eds[0].applyPaperMode(.genko)
                TabMarks.set(eds[1], true)
                TabSplit.splitTabs(of: host, sideBySide: true)
                soon(1.5) {
                    TabSplit.split(of: host)?.focus(eds[0])
                    soon(0.5) {
                        snap(host, out)
                        for d in NSDocumentController.shared.documents { d.updateChangeCount(.changeCleared) }
                        exit(0)
                    }
                }
            }
        }
    }

    static func runIfRequested() {
        if let out = ProcessInfo.processInfo.environment["SATORU_MADO_SITE"] { siteShot(out); return }
        guard let dir = ProcessInfo.processInfo.environment["SATORU_MADO_SNAP"] else { return }
        let base = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let urls = samples.map { s -> URL in
            let u = base.appendingPathComponent(s.0)
            try? s.1.write(to: u, atomically: true, encoding: .utf8)
            return u
        }
        // 起動のときの白紙の文書を閉じてから、例の文書を順に開く
        soon(1.0) {
            for d in NSDocumentController.shared.documents where d.fileURL == nil && !d.isDocumentEdited { d.close() }
            open(urls, []) { eds in run(eds, dir: dir) }
        }
    }

    private static func open(_ urls: [URL], _ done: [EditorWindowController], _ finish: @escaping ([EditorWindowController]) -> Void) {
        guard let u = urls.first else { finish(done); return }
        NSDocumentController.shared.openDocument(withContentsOf: u, display: true) { doc, _, err in
            guard let ed = (doc as? Document)?.editor else { note("open failed \(u.lastPathComponent) \(String(describing: err))"); exit(1) }
            // 1 つ目のウインドウのタブにする (アプリが前にいなくても)
            if let first = done.first?.window, let w = ed.window, first !== w, !(first.tabGroup?.windows.contains(w) ?? false) {
                (first.tabGroup?.windows.last ?? first).addTabbedWindow(w, ordered: .above)
            }
            soon(0.2) { open(Array(urls.dropFirst()), done + [ed], finish) }
        }
    }

    private static func name(_ c: EditorWindowController) -> String { c.hdoc?.fileURL?.deletingPathExtension().lastPathComponent ?? "?" }

    /// 応答者の順で、文書の動作 (保存) と窓割りの動作が、フォーカスのある画面に届くか
    private static func checkResponder(_ sp: TabSplit, _ c: EditorWindowController) {
        guard let w = sp.hostWindow else { return }
        var r: NSResponder? = w.firstResponder
        var path: [String] = []
        var saveTarget: Any?
        var closeTarget: NSResponder?
        var hops = 0
        while let x = r, hops < 80 {
            hops += 1
            if closeTarget == nil, x.responds(to: #selector(NSWindow.performClose(_:))) { closeTarget = x }
            if saveTarget == nil { saveTarget = x.responds(to: #selector(NSDocument.save(_:))) ? x : x.supplementalTarget(forAction: #selector(NSDocument.save(_:)), sender: nil) }
            if x is EditorWindowController || x is NSWindow || x is TabPaneView || x is MadoCloseForwarder { path.append("\(type(of: x))") }
            r = x.nextResponder
        }
        let saveOK = (saveTarget as? Document) === c.hdoc
        let closeName: String = {
            if let f = closeTarget as? MadoCloseForwarder { return "forwarder(\(f.editor.map(name) ?? "?"))" }
            if let e = closeTarget as? EditorWindowController { return "editor(\(name(e)))" }
            return closeTarget.map { "\(type(of: $0))" } ?? "nil"
        }()
        note("responder focused=\(name(c)) firstResponderIsPane=\(c.focusView === w.firstResponder) save->\(saveOK ? "focused doc" : "WRONG") close->\(closeName) hops=\(hops) chain=\(path.joined(separator: ">"))")
    }

    private static func run(_ eds: [EditorWindowController], dir: String) {
        guard eds.count == 4, let host = eds[0].window else { note("need 4 editors (got \(eds.count))"); exit(1) }
        host.setFrame(NSRect(x: 60, y: 80, width: 1180, height: 760), display: true)
        host.tabGroup?.selectedWindow = host
        func libShown0(_ v: NSView) -> Bool { (v is TextLibraryPanel && !v.isHiddenOrHasHiddenAncestor) || v.subviews.contains(where: libShown0) }
        note("before split library shownIn=\(eds.filter { libShown0($0.contentRoot) }.map(name))")
        note("tabs=\(host.tabGroup?.windows.count ?? 0) canSplit=\(TabSplit.canSplit(host)) enabled=\(Mado.isEnabled)")
        // (1) 1 つ目と 2 つ目のタブだけを左右に並べる (2 つ目に印を付けて「タブを左右に並べる」)
        TabMarks.set(eds[1], true)
        note("marked=\(TabMarks.marked(in: host).map(name)) tabTitle=\(eds[1].window?.tab.title ?? "")")
        TabSplit.splitTabs(of: host, sideBySide: true)
        guard let sp = TabSplit.split(of: host) else { note("split failed"); exit(1) }
        soon(0.8) {
            note("lr layout=\(sp.layoutDescription(name)) tabsLeft=\(host.tabGroup?.windows.count ?? 0) title=\(host.title)")
            snap(host, dir + "/mado_lr.png")
            // (2) 右の画面を上下に分けて、次のタブ (sample.swift) を入れる
            sp.focus(eds[1])
            TabSplit.splitFocused(of: host, sideBySide: false)
            soon(0.8) {
                func libShown(_ v: NSView) -> Bool { (v is TextLibraryPanel && !v.isHiddenOrHasHiddenAncestor) || v.subviews.contains(where: libShown) }
                note("library visible=\(TextLibrary.isVisible) shownIn=\(eds.filter { libShown($0.contentRoot) }.map(name))")
                note("nested layout=\(sp.layoutDescription(name)) panes=\(sp.panes.count) tabsLeft=\(host.tabGroup?.windows.count ?? 0)")
                sp.focus(eds[2])
                checkResponder(sp, eds[2])
                sp.focus(eds[1])
                checkResponder(sp, eds[1])
                sp.focus(eds[0])
                checkResponder(sp, eds[0])
                // 見出しにマウスが乗ったときの × と ≡ (左の画面)、右下の画面に「選ぶ」の印
                sp.panes.first?.header.hovered = true
                sp.togglePaneMark(eds[2])
                snap(host, dir + "/mado_nested.png")
                sp.panes.first?.header.hovered = false
                sp.togglePaneMark(eds[2])
                // (3) 新しい文書は窓内で開く (-madoOpenPlace split)。左の画面の隣 (縦長なら下) に入る。原稿.txt はタブのまま
                sp.focus(eds[0])
                guard let doc = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true) as? Document, let ne = doc.editor else { note("new doc failed"); exit(1) }
                ne.textView.insertText(samples[3].1, replacementRange: NSRange(location: 0, length: 0))
                soon(0.6) {
                    note("new doc inSplit=\(ne.madoSplit === sp) visibleOwnWindow=\(ne.window?.isVisible ?? false) tabsLeft=\(host.tabGroup?.windows.count ?? 0)")
                    paperStep(eds + [ne], sp, host, dir)
                }
            }
        }
    }

    /// 原稿用紙 と A4 の画面を並べて写す。そのあと閉じる・やめるを確かめる
    private static func paperStep(_ eds: [EditorWindowController], _ sp: TabSplit, _ host: NSWindow, _ dir: String) {
        note("four layout=\(sp.layoutDescription(name)) panes=\(sp.panes.count)")
        // 原稿.txt (まだタブ) を原稿用紙にしてから、右下の画面 (sample.swift) の右に入れる。sample.swift は A4 にする
        let ne = eds[3]
        ne.applyPaperMode(.genko)
        eds[2].applyPaperMode(.a4)
        sp.focus(eds[2])
        TabSplit.splitFocused(of: host, sideBySide: true)
        soon(1.5) {
            note("paper layout=\(sp.layoutDescription(name)) genko=\(ne.paperMode == .genko) a4=\(eds[2].paperMode == .a4) focusIsGenko=\(host.firstResponder is GenkoView) title=\(host.title)")
            snap(host, dir + "/mado_paper.png")
            eds[2].applyPaperMode(.normal)
            // (4) 左の画面の上の端に落とす見本 (根の端)
            let r = sp.root.convert(sp.root.bounds, to: nil)
            let pt = NSPoint(x: r.midX, y: r.maxY - 10)
            if let z = sp.dropAt(for: nil, at: pt) {
                note("drop edge side=\(z.side) label=\(z.label ?? "-")")
                snap(host, dir + "/mado_drop.png", over: (z.rect, z.label))
            }
            soon(0.5) { closeStep(eds, sp, host, dir) }
        }
    }

    /// 保存の確認のシートで「保存しない」(新規なら「削除」) を押す
    private static func dontSave(_ sheet: NSWindow) {
        guard let v = sheet.contentView?.superview ?? sheet.contentView else { return }
        func buttons(_ v: NSView) -> [NSButton] { (v as? NSButton).map { [$0] } ?? v.subviews.flatMap(buttons) }
        let all = buttons(v)
        note("sheet buttons=\(all.map { $0.title })")
        all.first { $0.title.contains("保存しない") || $0.title.contains("Don") || $0.title.contains("削除") || $0.title.contains("Delete") }?.performClick(nil)
    }

    /// (6b) タブを新しいウインドウに分けてから、そのウインドウを元のウインドウの中身の右へドラッグして離したときと同じ処理で並べる
    private static func windowDropStep(_ host: NSWindow, _ dir: String) {
        guard let sample = (host.tabGroup?.windows ?? []).compactMap({ $0.windowController as? EditorWindowController }).first(where: { name($0) == "sample" }),
              let sw = sample.window else { note("windowDrop: no sample"); closeAllStep(host, dir); return }
        TabSplit.moveToNewWindow(sample)
        host.tabGroup?.selectedWindow = host
        soon(0.6) {
            note("windowDrop torn=\(!(host.tabGroup?.windows.contains(sw) ?? true)) origin=\(sample.tearOffOrigin.map(name) ?? "-")")
            // 元のウインドウの中身の右のはし (右 10%) の上
            let c = host.convertToScreen(host.contentLayoutRect)
            let mouse = NSPoint(x: c.maxX - c.width * 0.1, y: c.midY)
            guard let z = TabTearOff.zone(in: host, mouse: mouse) else { note("windowDrop: no zone"); closeAllStep(host, dir); return }
            note("windowDrop zone side=\(z.side)")
            snap(host, dir + "/mado_window_drop.png", over: (host.convertFromScreen(z.rect), z.label))
            TabTearOff.finishRelease(sample, sw, near: nil, zoneWindow: host, pane: z.pane, side: z.side)
            soon(0.8) {
                let sp = TabSplit.split(of: host)
                note("windowDrop layout=\(sp?.layoutDescription(name) ?? "none") sampleWindowVisible=\(sw.isVisible) alpha=\(sw.alphaValue)")
                snap(host, dir + "/mado_window_dropped.png")
                sp?.unsplit()
                soon(0.5) { closeAllStep(host, dir) }
            }
        }
    }

    /// (7) もう一度全部のタブを並べて、1 つ (ホストでない画面) を書き換えてから、ウインドウの閉じるボタン (performClose)。
    /// 1 つずつ確認しながら全部の画面が閉じるか
    private static func closeAllStep(_ host: NSWindow, _ dir: String) {
        for d in NSDocumentController.shared.documents { d.updateChangeCount(.changeCleared) }
        host.tabGroup?.selectedWindow = host
        TabSplit.splitTabs(of: host, sideBySide: true)
        guard let sp = TabSplit.split(of: host) else { note("closeAll: no split"); exit(1) }
        let dirty = sp.editors.filter { $0 !== (host.windowController as? EditorWindowController) }.first
        dirty?.hdoc?.updateChangeCount(.changeDone)
        note("closeAll layout=\(sp.layoutDescription(name)) dirty=\(dirty.map(name) ?? "-")")
        soon(0.5) {
            host.performClose(nil)
            var rounds = 0
            func step() {
                rounds += 1
                let left = NSDocumentController.shared.documents.count
                if let s = NSApp.windows.compactMap({ $0.attachedSheet }).first {
                    note("closeAll round \(rounds): sheet shown, docs=\(left)")
                    dontSave(s)
                }
                if left == 0 || rounds > 12 {
                    note("closeAll done docs=\(left) editorWindowsVisible=\(NSApp.windows.filter { $0.isVisible && $0.windowController is EditorWindowController }.count)")
                    exit(0)
                }
                soon(0.6, step)
            }
            soon(0.6, step)
        }
    }

    private static func closeStep(_ eds: [EditorWindowController], _ sp: TabSplit, _ host: NSWindow, _ dir: String) {
        // (5) 書き換えた画面 (メモ.md) を閉じる: 保存の確認が、並べているウインドウに出るか。「保存しない」で閉じる
        let memo = eds[1]
        memo.textView.insertText("書き足した\n", replacementRange: NSRange(location: 0, length: 0))
        memo.hdoc?.updateChangeCount(.changeDone)
        note("memo edited=\(memo.hdoc?.isDocumentEdited ?? false) hostDot=\(host.isDocumentEdited)")
        sp.focus(memo)
        note("after focus hostDot=\(host.isDocumentEdited) title=\(host.title)")
        memo.closeMadoPane { closed in note("memo closed=\(closed)") }
        soon(0.8) {
            let sheet = host.attachedSheet
            note("save sheet on host=\(sheet != nil) on memo window=\(memo.window?.attachedSheet != nil)")
            if let s = sheet, let v = s.contentView?.superview ?? s.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/mado_savesheet.png"))
                note("snap \(dir)/mado_savesheet.png")
                // 「保存しない」を押す
                dontSave(s)
            }
            soon(1.0) {
                note("after close layout=\(TabSplit.split(of: host)?.layoutDescription(name) ?? "none") docs=\(NSDocumentController.shared.documents.count)")
                snap(host, dir + "/mado_closed.png")
                // (6) やめてタブに戻す
                TabSplit.split(of: host)?.unsplit()
                soon(0.8) {
                    let tabs = (host.tabGroup?.windows ?? []).compactMap { ($0.windowController as? EditorWindowController).map(name) }
                    note("unsplit splits=\(TabSplit.all.count) tabs=\(tabs) plain=\((host.tabGroup?.windows ?? []).allSatisfy { TabSplit.isPlain($0) }) visibleHidden=\(NSApp.windows.filter { $0.isVisible && $0.windowController is EditorWindowController && !TabSplit.isPlain($0) }.count)")
                    snap(host, dir + "/mado_unsplit.png")
                    windowDropStep(host, dir)
                }
            }
        }
    }
}
