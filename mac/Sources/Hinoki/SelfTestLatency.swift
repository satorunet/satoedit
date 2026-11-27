import AppKit

/// 開発用: SATORU_LATENCY_TEST=<結果のファイル> SATORU_LATENCY_FILE=<開くファイル> のときだけ動く。
/// 文書の真ん中で 1 字ずつ打ち、それぞれにかかった時間を測って書き出して終わる (Tera Term Mac の TERAMAC_LATENCY_TEST と同じ考え方)
///   打つ+描く … 文字を入れて画面に描き終わるまで
///   あと始末  … そのあと順番待ちしていた処理 (行番号・ステータスなど) が終わるまで
///   引っかかり … 打ってから次を打つまでのあいだで、画面が止まっていたいちばん長い時間 (色付けなど、後から走る処理を含む)
enum SelfTestLatency {
    /// サイトの GIF 用: SATORU_HUGE_GIF=<フォルダ> SATORU_LATENCY_FILE=<大きなファイル>。
    /// 開いた直後・スクロール・途中への移動の画面を frame_NN.png に書き、開くまでの時間を open_ms.txt に書いて終わる
    static func hugeGif(dir: String, file: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var n = 0
        func snap(_ w: NSWindow) {
            w.displayIfNeeded()
            guard let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(format: "%@/frame_%02d.png", dir, n)))
            n += 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            for d in NSDocumentController.shared.documents where d.fileURL == nil && !d.isDocumentEdited { d.close() }
            let start = CFAbsoluteTimeGetCurrent()
            NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: file), display: true) { doc, _, _ in
                guard let doc = doc as? Document, let ed = doc.editor, let w = ed.window else { exit(1) }
                // 起動のときの空の文書を閉じる (タブのバーが写らないように)
                for d in NSDocumentController.shared.documents where d !== doc {
                    d.updateChangeCount(.changeCleared)
                    d.close()
                }
                w.setContentSize(NSSize(width: 800, height: 520))
                w.displayIfNeeded()
                let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
                try? String(format: "%.0f", ms).write(toFile: dir + "/open_ms.txt", atomically: true, encoding: .utf8)
                snap(w)
                let tv = ed.textView
                // スクロールを 10 回 (下へ)、そのあと 50% と 95% へ移動
                var steps: [() -> Void] = []
                for _ in 0..<10 {
                    steps.append {
                        if let clip = tv.enclosingScrollView?.contentView {
                            clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + 1400))
                            tv.enclosingScrollView?.reflectScrolledClipView(clip)
                        }
                    }
                }
                for f in [0.5, 0.95] { steps.append { doc.hugeWindow?.jump(toFraction: f) } }
                func run(_ i: Int) {
                    guard i < steps.count else { exit(0) }
                    steps[i]()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { snap(w); run(i + 1) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { run(0) }
            }
        }
    }

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["SATORU_HUGE_GIF"], let file = env["SATORU_LATENCY_FILE"] { hugeGif(dir: dir, file: file); return }
        guard let out = env["SATORU_LATENCY_TEST"], let file = env["SATORU_LATENCY_FILE"] else { return }
        let openStart = CFAbsoluteTimeGetCurrent()
        NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: file), display: true) { doc, _, _ in
            guard let doc = doc as? Document, let ed = doc.editor, let w = ed.window else { exit(1) }
            w.displayIfNeeded()
            let openMs = (CFAbsoluteTimeGetCurrent() - openStart) * 1000
            let memMB = Self.residentMB()
            let tv = ed.textView
            let keys = Array(env["SATORU_LATENCY_KEYS"] ?? "abcdefghijあいうえおかきくけこ")
            var typed: [Double] = [], after: [Double] = [], color: [Double] = []
            // 5 ms ごとに時計を回し、間があいたら「止まっていた」とみなす
            var last = CFAbsoluteTimeGetCurrent(), worst = 0.0
            let ticker = Timer(timeInterval: 0.005, repeats: true) { _ in
                let now = CFAbsoluteTimeGetCurrent()
                worst = max(worst, (now - last) * 1000)
                last = now
            }
            RunLoop.main.add(ticker, forMode: .common)
            func ms(_ t: CFAbsoluteTime) -> Double { (CFAbsoluteTimeGetCurrent() - t) * 1000 }
            func step(_ i: Int) {
                guard i < keys.count else {
                    func line(_ name: String, _ v: [Double]) -> String {
                        let s = v.sorted()
                        return String(format: "%@: 最小 %.1f / 中央 %.1f / 最大 %.1f ms", name, s.first ?? 0, s.isEmpty ? 0 : s[s.count / 2], s.last ?? 0)
                    }
                    let text = [
                        "file: \((file as NSString).lastPathComponent)  \((tv.string as NSString).length) 字  mode: \(ed.paperMode)",
                        String(format: "開くまで: %.0f ms  メモリ: %.0f MB (開いた直後) / %.0f MB (打ったあと)", openMs, memMB, Self.residentMB()),
                        line("打つ+描く", typed), line("あと始末 ", after), line("引っかかり", color),
                    ].joined(separator: "\n")
                    print(text); fflush(stdout)
                    try? text.write(toFile: out, atomically: true, encoding: .utf8)
                    doc.updateChangeCount(.changeCleared)
                    exit(0)
                }
                last = CFAbsoluteTimeGetCurrent()
                worst = 0
                var t = CFAbsoluteTimeGetCurrent()
                tv.insertText(String(keys[i]), replacementRange: NSRange(location: NSNotFound, length: 0))
                w.displayIfNeeded()
                typed.append(ms(t))
                t = CFAbsoluteTimeGetCurrent()
                DispatchQueue.main.async {
                    DispatchQueue.main.async {
                        w.displayIfNeeded()
                        after.append(ms(t))
                        // 色付けなどが終わるのを待ってから、そのあいだの引っかかりを見る
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            color.append(worst)
                            step(i + 1)
                        }
                    }
                }
            }
            // SATORU_LATENCY_SCROLL: 大きなファイルで下へスクロールし続け、続きを読み足せるか見る
            if env["SATORU_LATENCY_SCROLL"] != nil {
                var lines: [String] = []
                func scrollStep(_ k: Int) {
                    let tv = ed.textView
                    if k == 40 || doc.partial == nil {
                        let text = lines.joined(separator: "\n")
                        print(text); fflush(stdout)
                        try? text.write(toFile: out, atomically: true, encoding: .utf8)
                        exit(0)
                    }
                    if let clip = tv.enclosingScrollView?.contentView {
                        let t = CFAbsoluteTimeGetCurrent()
                        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + 4000))
                        tv.enclosingScrollView?.reflectScrolledClipView(clip)
                        w.displayIfNeeded()
                        let ns = tv.string as NSString
                        let top = tv.layoutManager.map { lm -> String in
                            let g = lm.glyphIndex(for: NSPoint(x: 5, y: clip.bounds.minY + 5), in: tv.textContainer!)
                            let c = lm.characterIndexForGlyph(at: g)
                            return ns.substring(with: ns.lineRange(for: NSRange(location: min(c, max(0, ns.length - 1)), length: 0))).trimmingCharacters(in: .newlines)
                        } ?? ""
                        if let p = doc.partial {
                            lines.append(String(format: "%2d: %.0f ms  範囲 %.1f〜%.1f MB  先頭の行: %@", k, (CFAbsoluteTimeGetCurrent() - t) * 1000,
                                                Double(p.offset) / 1_048_576, Double(p.end) / 1_048_576, String(top.suffix(14))))
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { scrollStep(k + 1) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { scrollStep(0) }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                w.makeFirstResponder(tv)
                let ns = tv.string as NSString
                let mid = ns.lineRange(for: NSRange(location: ns.length / 2, length: 0)).location
                tv.setSelectedRange(NSRange(location: mid, length: 0))
                tv.scrollRangeToVisible(NSRange(location: mid, length: 0))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { step(0) }
            }
        }
    }

    /// このアプリが使っているメモリ (MB)
    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }
}
