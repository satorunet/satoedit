import AppKit
import HinokiCore

/// 大きなファイルを、全部は読まずに「見ている所の近くだけ」読む (AOI)。
///
/// - 開いたときは先頭の数 MB だけを読む (ファイルのその位置へ飛んで読む。全体は読まない)
/// - スクロールして読んだ範囲の端に近づいたら、今見ている行を中心に、その前後の数 MB を読み直す。
///   今見ている行は画面の同じ所に残すので、続けてスクロールできる
/// - ファイル全体の何 % の所を見ているかは、ステータスバーに出す。「位置へ移動」で % を指定して飛べる
/// - 書き換えて保存していないうちは、範囲を動かさない (動かすと変更が消えるため)。保存すると、その範囲だけがファイルに入る
final class HugeFileWindow {
    /// 一度に読む大きさ (MB)
    static var windowMB: Int { max(1, UserDefaults.standard.integer(forKey: "hugeWindowMB")) }
    static var windowBytes: UInt64 { UInt64(windowMB) << 20 }

    private weak var doc: Document?
    private var observer: NSObjectProtocol?
    /// 読み直している最中 (スクロールの知らせで、もう一度読み直さないように)
    private var sliding = false
    /// 「保存すると続きを読めます」を出したか (何度も出さない)
    private var warned = false

    init(doc: Document) {
        self.doc = doc
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: nil, queue: .main) { [weak self] note in
            self?.scrolled(note)
        }
    }

    deinit {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
    }

    /// この文書の面のスクロールなら、読んだ範囲の端に近いか見る
    private func scrolled(_ note: Notification) {
        guard !sliding, let doc = doc, let part = doc.partial, let clip = note.object as? NSClipView,
              let tv = clip.documentView as? NSTextView, let storage = doc.editor?.textView.textStorage,
              tv.textStorage === storage, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let ns = tv.string as NSString
        guard ns.length > 0 else { return }
        var visible = tv.visibleRect
        visible.origin.y -= tv.textContainerOrigin.y
        // 見えている所は組んでから測る (組む前だと、範囲が先頭の 0 字目になって「上の端」と取り違える)
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        guard glyphs.length > 0 else { return }
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // 端から 1/8 (少なくとも 2 万字) に入ったら読み直す
        let margin = max(20_000, ns.length / 8)
        let nearEnd = NSMaxRange(chars) > ns.length - margin && part.end < part.fileSize
        let nearTop = chars.location < margin && part.offset > 0
        guard nearEnd || nearTop else { return }
        if doc.isDocumentEdited {
            if !warned {
                warned = true
                _ = Toast.show(in: tv.window, kind: .info, title: L("この先はまだ読み込んでいません"),
                           detail: L("書き換えを保存すると、続きを読み込めます"))
            }
            return
        }
        // 今いちばん上に見えている行の、ファイルの中の位置 (バイト)
        let topLine = ns.lineRange(for: NSRange(location: min(chars.location, ns.length - 1), length: 0)).location
        guard let anchor = byteOffset(ofLine: lineIndex(at: topLine, in: ns), in: part, doc: doc) else { return }
        let shift = clip.bounds.minY - lineTop(topLine, tv: tv)
        // 進む向きの先を多めに読む (下へなら今の行を範囲の 1/4 に、上へなら 3/4 に置く)
        let w = Self.windowBytes
        let back = nearEnd ? w / 4 : w * 3 / 4
        load(at: anchor > back ? anchor - back : 0, anchor: anchor, shift: shift, in: tv)
    }

    /// ファイルの fraction (0〜1) の位置へ飛ぶ
    func jump(toFraction fraction: Double) {
        guard let doc = doc, let part = doc.partial, let tv = doc.editor?.textView else { return }
        let target = UInt64(Double(part.fileSize) * max(0, min(1, fraction)))
        let w = Self.windowBytes
        load(at: target > w / 2 ? target - w / 2 : 0, anchor: target, shift: 0, in: tv)
    }

    /// offset から読み直し、ファイルの anchor の位置にある行を、画面の上から shift の所に出す
    private func load(at offset: UInt64, anchor: UInt64, shift: CGFloat, in tv: NSTextView) {
        guard let doc = doc, let url = doc.fileURL else { return }
        do {
            let part = try PartialFile.align(url, offset: offset, length: Self.windowBytes)
            let data = try PartialFile.read(url, part)
            let decoded = try TextCodec.decode(data, as: doc.encoding)
            // anchor が新しい範囲の何行目か (行の切れ目 = LF を数える)
            let upTo = Int(min(UInt64(data.count), anchor > part.offset ? anchor - part.offset : 0))
            let line = data.prefix(upTo).reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            sliding = true
            // 読み直した直後は、画面の位置がいったん先頭に戻ったりするので、少しのあいだ端の判定をしない
            defer { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.sliding = false } }
            doc.partial = part
            doc.apply(decoded)
            doc.undoManager?.removeAllActions()
            doc.updateChangeCount(.changeCleared)
            warned = false
            scroll(toLine: line, shift: shift, in: tv)
        } catch {
            NSSound.beep()
        }
    }

    /// line 行目 (0 始まり) を画面のいちばん上から shift の所に出す
    private func scroll(toLine line: Int, shift: CGFloat, in tv: NSTextView) {
        let ns = tv.string as NSString
        var loc = 0, n = 0
        while n < line, loc < ns.length {
            let r = ns.range(of: "\n", options: .literal, range: NSRange(location: loc, length: ns.length - loc))
            if r.location == NSNotFound { break }
            loc = NSMaxRange(r)
            n += 1
        }
        loc = min(loc, ns.length)
        tv.setSelectedRange(NSRange(location: loc, length: 0))
        guard let clip = tv.enclosingScrollView?.contentView else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, lineTop(loc, tv: tv) + shift)))
        tv.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// 文字 loc のある行の上端 (文字の面の座標)
    private func lineTop(_ loc: Int, tv: NSTextView) -> CGFloat {
        guard let lm = tv.layoutManager else { return 0 }
        let length = (tv.string as NSString).length
        guard length > 0 else { return 0 }
        let g = lm.glyphIndexForCharacter(at: min(loc, length - 1))
        return lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minY + tv.textContainerOrigin.y
    }

    /// 文字 loc までにある行の数
    private func lineIndex(at loc: Int, in ns: NSString) -> Int {
        var n = 0, pos = 0
        while pos < loc {
            let r = ns.range(of: "\n", options: .literal, range: NSRange(location: pos, length: loc - pos))
            if r.location == NSNotFound { break }
            n += 1
            pos = NSMaxRange(r)
        }
        return n
    }

    /// 読んだ範囲の line 行目の行頭の、ファイルの中の位置 (バイト)
    private func byteOffset(ofLine line: Int, in part: PartialFile.Part, doc: Document) -> UInt64? {
        guard let url = doc.fileURL, let data = try? PartialFile.read(url, part) else { return nil }
        if line == 0 { return part.offset }
        var n = 0
        for (i, b) in data.enumerated() where b == 0x0A {
            n += 1
            if n == line { return part.offset + UInt64(i + 1) }
        }
        return part.end
    }

    // MARK: 表示

    /// ステータスバーに出す: いま読んでいる範囲がファイル全体のどこか
    static func statusText(_ part: PartialFile.Part) -> String {
        let total = Double(max(1, part.fileSize))
        let from = Double(part.offset) / total * 100, to = Double(part.end) / total * 100
        return L("大きなファイル: {0} の {1}〜{2}% を表示中", HugeFile.sizeText(part.fileSize),
                 String(format: "%.1f", from), String(format: "%.1f", to))
    }

    /// 「位置へ移動」: % を聞いて飛ぶ
    func askAndJump(in window: NSWindow?) {
        guard let doc = doc, let part = doc.partial else { return }
        if doc.isDocumentEdited {
            NSSound.beep()
            _ = Toast.show(in: window, kind: .info, title: L("先に保存してください"), detail: L("書き換えを保存すると、ほかの位置へ移動できます"))
            return
        }
        let alert = NSAlert()
        alert.messageText = L("ファイルの位置へ移動")
        alert.informativeText = L("全体 {0} のうち、何 % の所へ移動しますか？ (0〜100)", HugeFile.sizeText(part.fileSize))
        let field = NSTextField(string: String(format: "%.1f", Double(part.offset) / Double(max(1, part.fileSize)) * 100))
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L("移動"))
        alert.addButton(withTitle: L("キャンセル"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        jump(toFraction: field.doubleValue / 100)
    }
}

extension EditorWindowController {
    /// メニュー「巨大ファイル: 位置へ移動…」
    @objc func jumpInHugeFileHM(_ sender: Any?) {
        guard let w = hdoc?.hugeWindow else { NSSound.beep(); return }
        w.askAndJump(in: window)
    }
}
