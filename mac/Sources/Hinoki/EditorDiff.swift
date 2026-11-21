import AppKit
import HinokiCore

// MARK: - 差分表示 (編集前と、いまの違いを右の欄に出す)

private var diffPanelKey = 0
private var diffBaselineKey = 0
private var diffWorkKey = 0
private var diffObserverKey = 0
private var diffScrollKey = 0
private var diffThemeKey = 0
private var diffSelectionKey = 0

extension EditorWindowController {
    /// 「編集前」の内容 (開いたとき・最後に保存したとき)
    var diffBaseline: String {
        get { (objc_getAssociatedObject(self, &diffBaselineKey) as? String) ?? "" }
        set {
            objc_setAssociatedObject(self, &diffBaselineKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            if diffPanelVisible { scheduleDiff(delay: 0) }
        }
    }

    private var diffPanel: DiffPanel {
        if let p = objc_getAssociatedObject(self, &diffPanelKey) as? DiffPanel { return p }
        let p = DiffPanel()
        p.onClose = { [weak self] in self?.showDiffPanel(false) }
        p.onJump = { [weak self] line in self?.textView.goTo(line: line) }
        objc_setAssociatedObject(self, &diffPanelKey, p, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return p
    }

    var diffPanelVisible: Bool {
        guard let p = objc_getAssociatedObject(self, &diffPanelKey) as? DiffPanel else { return false }
        return p.superview != nil && !p.isHidden
    }

    func showDiffPanel(_ show: Bool) {
        let p = diffPanel
        if show {
            if p.superview == nil {
                editorArea.addArrangedSubview(p)
                // エディタと同じ高さいっぱいに広げる (これがないと、下に細い帯としてしか出ない)
                NSLayoutConstraint.activate([
                    p.topAnchor.constraint(equalTo: editorArea.topAnchor),
                    p.bottomAnchor.constraint(equalTo: editorArea.bottomAnchor),
                ])
            }
            p.isHidden = false
            fitWindowForSidePanels()
            watchTextForDiff()
            watchScrollForDiff()
            scheduleDiff(delay: 0)
        } else {
            p.isHidden = true
            window?.makeFirstResponder(textView.focusTarget)
        }
    }

    @objc func toggleDiffHM(_ sender: Any?) {
        showDiffPanel(!diffPanelVisible)
    }

    /// エディタのいちばん上に見えている行を、差分の欄でもいちばん上にする
    func syncDiffScroll() {
        guard diffPanelVisible, let lm = textView.layoutManager, let tc = textView.textContainer,
              let ruler = textView.enclosingScrollView?.verticalRulerView as? LineNumberRulerView else { return }
        // 本文の上の端 (桁ルーラーの下) と、文字の上の余白をそろえる
        let sv = textView.enclosingScrollView
        let rulerHeight = (sv?.rulersVisible == true && sv?.hasHorizontalRuler == true) ? (sv?.horizontalRulerView?.ruleThickness ?? 0) + (sv?.horizontalRulerView?.reservedThicknessForMarkers ?? 0) + (sv?.horizontalRulerView?.reservedThicknessForAccessoryView ?? 0) : 0
        diffPanel.alignWithEditor(top: rulerHeight, containerInset: textView.textContainerInset)
        let origin = textView.textContainerOrigin
        let visibleTop = textView.visibleRect.minY
        let top = NSPoint(x: 0, y: visibleTop - origin.y + 1)
        let g = lm.glyphIndex(for: top, in: tc)
        let loc = lm.characterIndexForGlyph(at: g)
        // 行の頭まで戻して、その行がいま画面のどの高さにあるか
        let lineNo = ruler.lineIndex.lineNumber(at: loc)
        let lineStart = ruler.lineIndex.startOfLine(lineNo)
        let frag = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: min(lineStart, max(0, (textView.string as NSString).length - 1))), effectiveRange: nil)
        let offset = frag.minY + origin.y - visibleTop
        diffPanel.scroll(toLine: lineNo + 1, offset: offset)
    }

    /// エディタのカーソル行を、差分の欄の同じ行にも出す (同じ色の帯と文字色)
    func syncDiffCurrentLine() {
        guard diffPanelVisible, let ruler = textView.enclosingScrollView?.verticalRulerView as? LineNumberRulerView else { return }
        let sel = textView.selectedRange()
        let on = textView.highlightsCurrentLine && sel.length == 0 && textView.paperMode == .normal
        let line = ruler.lineIndex.lineNumber(at: min(sel.location, (textView.string as NSString).length)) + 1
        diffPanel.setCurrentLine(on ? line : nil, band: Theme.currentLine, text: textView.currentLineTextColor)
    }

    /// エディタをスクロールしたら、差分の欄も一緒に動かす
    private func watchScrollForDiff() {
        guard objc_getAssociatedObject(self, &diffScrollKey) == nil, let clip = textView.enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        let o = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            self?.syncDiffScroll()
        }
        objc_setAssociatedObject(self, &diffScrollKey, o, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        // カーソルを動かしたら、差分の欄のカーソル行も動かす
        let s = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self = self, (note.object as? NSTextView) === self.textView else { return }
            self.syncDiffCurrentLine()
        }
        objc_setAssociatedObject(self, &diffSelectionKey, s, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// 文字が変わったら、少し待ってから比べ直す
    private func watchTextForDiff() {
        guard objc_getAssociatedObject(self, &diffObserverKey) == nil, let storage = textView.textStorage else { return }
        let o = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: .main) { [weak self] note in
            guard let self = self, self.diffPanelVisible,
                  (note.object as? NSTextStorage)?.editedMask.contains(.editedCharacters) == true else { return }
            self.scheduleDiff(delay: 0.4)
        }
        objc_setAssociatedObject(self, &diffObserverKey, o, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        // テーマや字の大きさを変えたら、色・行の高さを合わせ直す
        let t = NotificationCenter.default.addObserver(forName: .themeDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.diffPanelVisible else { return }
            self.scheduleDiff(delay: 0.1)
        }
        objc_setAssociatedObject(self, &diffThemeKey, t, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func scheduleDiff(delay: TimeInterval) {
        (objc_getAssociatedObject(self, &diffWorkKey) as? DispatchWorkItem)?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runDiff() }
        objc_setAssociatedObject(self, &diffWorkKey, work, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runDiff() {
        guard diffPanelVisible else { return }
        let old = diffBaseline, new = textView.string
        // エディタと同じ字・同じ行間 (横に並べて見比べられるように)
        let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let spacing = (textView.defaultParagraphStyle?.lineSpacing) ?? CGFloat(UserDefaults.standard.double(forKey: "lineSpacing"))
        // 大きな文書でも打つのを止めないよう、比べるのは裏で
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 変わっていない行も省かずに全部 (エディタと 1 行ずつ対応させる)
            let result = TextDiff.inline(old: old, new: new, context: Int.max / 4)
            DispatchQueue.main.async {
                guard let self = self, self.textView.string == new else { return } // その間に変わったら次の回に任せる
                let colors = DiffPanel.Colors(background: Theme.background, text: Theme.text, dark: Theme.isDarkBackground)
                self.diffPanel.show(result, font: font, lineSpacing: spacing, colors: colors)
                self.syncDiffScroll()
                self.syncDiffCurrentLine()
            }
        }
    }
}
