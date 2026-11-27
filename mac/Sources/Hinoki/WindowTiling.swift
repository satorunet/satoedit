import AppKit
import HinokiCore

/// 割窓: 開いている文書のウインドウを、画面いっぱいに左右 (または上下) に並べる。
/// タブにまとまっている文書は、1 つずつのウインドウに分けてから並べる。「タブにまとめる」で元に戻せる
enum WindowTiling {
    enum Direction { case sideBySide, stacked }

    /// 並べる対象: 文書のウインドウ (タブのまとまりごとに、タブの順に)。前にあるまとまりから
    static func editorWindows() -> [NSWindow] {
        var out: [NSWindow] = []
        var seen = Set<ObjectIdentifier>()
        let all = NSApp.orderedWindows + NSApp.windows // 前にあるものを先に。隠れているタブも拾う
        // 窓割りの画面として隠しているウインドウは除く
        for w in all where w.windowController is EditorWindowController && !w.isMiniaturized && (w.windowController as? EditorWindowController)?.madoSplit == nil {
            guard !seen.contains(ObjectIdentifier(w)) else { continue }
            for t in w.tabbedWindows ?? [w] where t.windowController is EditorWindowController {
                if seen.insert(ObjectIdentifier(t)).inserted { out.append(t) }
            }
        }
        return out
    }

    static var canTile: Bool { editorWindows().count >= 2 }

    static func tile(_ direction: Direction) {
        // 窓割りで並べているときは、やめてタブに戻してから並べる (隠している画面のウインドウを拾わないように)
        TabSplit.unsplitAll()
        let windows = editorWindows()
        guard windows.count >= 2 else { NSSound.beep(); return }
        let screen = (NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        guard screen.width > 0 else { return }
        // タブを 1 つずつのウインドウに分ける (分けたあとも勝手にタブにまとまらないように)
        for w in windows where (w.tabbedWindows?.count ?? 0) > 1 {
            w.moveTabToNewWindow(nil)
        }
        let n = CGFloat(windows.count)
        for (i, w) in windows.enumerated() {
            let k = CGFloat(i)
            var f: NSRect
            switch direction {
            case .sideBySide:
                // 縦書きの原稿のように、1 つ目を右から並べる
                let width = (screen.width / n).rounded(.down)
                f = NSRect(x: screen.maxX - width * (k + 1), y: screen.minY, width: width, height: screen.height)
            case .stacked:
                let height = (screen.height / n).rounded(.down)
                f = NSRect(x: screen.minX, y: screen.maxY - height * (k + 1), width: screen.width, height: height)
            }
            w.setFrame(f, display: true, animate: false)
            w.orderFront(nil)
        }
        windows.first?.makeKeyAndOrderFront(nil)
    }
}
