import AppKit

/// 1 つの表示面 (テキスト・行番号・桁ルーラー)。
/// 上下分割のときは 2 つの EditorPane が同じ文字データ (NSTextStorage) を共有する。
final class EditorPane {
    let scrollView = NSScrollView()
    let textView: EditorTextView
    let ruler: LineNumberRulerView
    let columnRuler: ColumnRulerView
    /// 原稿用紙のとき、文字の面の代わりに出すマス目の面 (使うときに初めて作る)
    var genkoView: GenkoView?

    /// sharing を渡すとその文字データを一緒に表示する (分割した下側)
    init(sharing storage: NSTextStorage? = nil) {
        let frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        if let storage = storage {
            let lm = InvisiblesLayoutManager()
            storage.addLayoutManager(lm)
            let tc = PagedTextContainer(size: NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude))
            tc.widthTracksTextView = true
            lm.addTextContainer(tc)
            textView = EditorTextView(frame: frame, textContainer: tc)
        } else {
            textView = EditorTextView(frame: frame)
            textView.textContainer?.replaceLayoutManager(InvisiblesLayoutManager())
            // A4 用紙モードでページごとに分けられる入れ物に替える
            let paged = PagedTextContainer(size: NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude))
            paged.widthTracksTextView = true
            textView.replaceTextContainer(paged)
        }
        // カーソル行の文字の色を、描くときに差し替える
        textView.layoutManager?.delegate = textView
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        columnRuler = ColumnRulerView(scrollView: scrollView, textView: textView)
        scrollView.horizontalRulerView = columnRuler
        scrollView.hasHorizontalRuler = true
        scrollView.rulersVisible = true
    }

    /// 分割を閉じるとき、共有している文字データから外す
    func detach() {
        if let lm = textView.layoutManager {
            lm.textStorage?.removeLayoutManager(lm)
        }
        scrollView.removeFromSuperview()
    }
}

/// 行をページごとに分けて並べる入れ物 (A4 用紙モード用)。
/// pageStride (1 ページ分 + 用紙の間) ごとに、上から textHeight までだけ行を置き、
/// はみ出す行は次のページの頭へ送る。pageStride が 0 なら普通の入れ物と同じ。
final class PagedTextContainer: NSTextContainer {
    var pageStride: CGFloat = 0
    var textHeight: CGFloat = 0

    override var isSimpleRectangularTextContainer: Bool { pageStride <= 0 }

    override func lineFragmentRect(forProposedRect proposedRect: NSRect, at characterIndex: Int,
                                   writingDirection baseWritingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<NSRect>?) -> NSRect {
        var proposed = proposedRect
        if pageStride > 0 {
            let page = floor(proposed.minY / pageStride)
            let top = page * pageStride
            if proposed.maxY > top + textHeight + 0.5 {
                proposed.origin.y = top + pageStride // 次のページの 1 行目へ
            }
        }
        return super.lineFragmentRect(forProposedRect: proposed, at: characterIndex,
                                      writingDirection: baseWritingDirection, remaining: remainingRect)
    }
}
