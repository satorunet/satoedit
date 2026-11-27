import AppKit
import HinokiCore

// MARK: - 窓割り (Tera Term Mac の TTMado と同じしくみ)

/// 窓割り: ちがうタブの文書を、1 つのウインドウの中に左右・上下に並べる。
/// 追加機能の「窓割り」で入/切できる (再起動はいらない。はじめは入)。切ると macOS のふつうのタブと同じ動きになる。
/// (同じ文書を上下・左右に分けて見る「ウインドウ上下分割 / 左右分割」とは別のもの。どちらも一緒に使える)
///
/// 窓割りのファイル:
/// - MadoSplit.swift: 並べる (TabSplit・画面・見出し・≡ メニュー・ドラッグの行き先と見本)、タブの印 (TabMarks)
/// - MadoTearOff.swift: 引き出したタブ・ウインドウのドラッグ (元のウインドウに戻す・ほかのウインドウに入れる)、
///   タブのバーからのドラッグ (TabBarDrag)、見えないままの受け渡し (HiddenHandoff)
/// - Mado.swift: この入口 (isEnabled / install / uninstall)、エディタ側のつなぎ (メニュー・閉じる・開く場所)
enum Mado {
    static var isEnabled: Bool { EditorExtension.mado.isOn }

    /// 起動時 (入のとき)・入にしたとき: タブの Shift+クリックの見張り、タブ・ウインドウのドラッグの見張りを始める
    static func install() {
        TabMarks.install()
        TabTearOff.install()
        installFocusWatch()
    }

    /// 切るとき: 並びを全部やめてタブに戻し、印を消し、見張りを止めて、引き出した元のウインドウを忘れる
    static func uninstall() {
        defer { PaneCountBadge.refreshAll() }
        TabSplit.unsplitAll()
        TabSplit.all.forEach { $0.clearPaneMarks() }
        TabMarks.uninstall()
        TabTearOff.uninstall()
        if let m = focusMonitor { NSEvent.removeMonitor(m) }
        focusMonitor = nil
        for c in EditorWindowController.all {
            c.paneMarked = false
            if let w = c.window, w.tab.title.hasPrefix(TabMarks.prefix) { w.tab.title = w.title }
        }
    }

    /// 画面のどこを押しても (ステータスバー・横の欄でも)、その画面にフォーカスを移す
    private static var focusMonitor: Any?
    private static func installFocusWatch() {
        guard focusMonitor == nil else { return }
        focusMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { ev in
            if let w = ev.window, let sp = TabSplit.split(of: w) {
                let pt = ev.locationInWindow
                if let p = sp.panes.first(where: { $0.convert($0.bounds, to: nil).contains(pt) }), let c = p.editor, c !== sp.focused {
                    DispatchQueue.main.async { sp.paneFocused(c) }
                }
            }
            return ev
        }
    }

    // MARK: 窓割りしているウインドウから、新しい文書を開く場所

    /// 開く場所: 窓内 (フォーカスのある画面の隣) / 新しいタブ / 新しいウインドウ
    enum OpenPlace: String { case ask, split, tab, window }

    static let openPlaceKey = "madoOpenPlace"
    static var openPlace: OpenPlace {
        OpenPlace(rawValue: UserDefaults.standard.string(forKey: openPlaceKey) ?? "") ?? .ask
    }

    /// 窓割りしているウインドウが前にあるときに開いた新しいエディタ c を、選んだ場所に開く。
    /// 窓内に入れたら true (ふつうに出さない)。タブ・新しいウインドウなら false (このあと、ふつうに出す)
    /// タブの「＋」・⌘T で開くあいだは true (開く場所を聞かずに、タブで開く)
    static var forceTab = false

    static func openNewEditor(_ c: EditorWindowController) -> Bool {
        if forceTab { return false }
        let front = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.orderedWindows.first { $0.isVisible && $0.windowController is EditorWindowController }
        guard isEnabled, c.madoSplit == nil, let key = front,
              let sp = TabSplit.split(of: key), let f = sp.focused ?? sp.panes.first?.editor, f !== c else { return false }
        var place = openPlace
        if place == .ask { place = askOpenPlace() }
        switch place {
        case .split:
            return openInSplit(c, next: f)
        case .window:
            // タブにまとめずに別のウインドウで開く (出し終えたら元に戻す)
            c.window?.tabbingMode = .disallowed
            DispatchQueue.main.async { c.window?.tabbingMode = .preferred }
            return false
        case .tab, .ask:
            return false
        }
    }

    /// 「窓内で開く / タブで開く / 新しいウインドウで開く」を聞く。「次から聞かない」を選んだら覚える
    private static func askOpenPlace() -> OpenPlace {
        let a = NSAlert()
        a.messageText = L("新しい文書をどこに開きますか？")
        a.informativeText = L("このウインドウは窓割りで並べています。")
        a.addButton(withTitle: L("窓内で開く"))
        a.addButton(withTitle: L("タブで開く"))
        a.addButton(withTitle: L("新しいウインドウで開く"))
        a.showsSuppressionButton = true
        a.suppressionButton?.title = L("次から聞かない (ウインドウ > 窓割り で変えられます)")
        let place: OpenPlace
        switch a.runModal() {
        case .alertFirstButtonReturn: place = .split
        case .alertSecondButtonReturn: place = .tab
        default: place = .window
        }
        if a.suppressionButton?.state == .on { UserDefaults.standard.set(place.rawValue, forKey: openPlaceKey) }
        return place
    }

    /// エディタ c を、画面 f の隣に入れる (横長なら右、縦長なら下)。入れたら true
    static func openInSplit(_ c: EditorWindowController, next f: EditorWindowController) -> Bool {
        guard let sp = f.madoSplit, let pane = sp.panes.first(where: { $0.editor === f }) else { return false }
        let side: TabSplit.DropSide = pane.bounds.width >= pane.bounds.height ? .right : .below
        sp.insert(c, at: pane, side: side)
        guard c.madoSplit === sp else { return false }
        sp.focus(c)
        c.updateAITab()
        return true
    }
}

/// エディタのウインドウの中身。窓割りのときは画面 (TabPaneView) に移し、次の応答者をその画面のエディタにする
final class EditorContentView: NSView {
    /// 窓割りの画面のとき、この中身の次の応答者 (その画面のエディタ)
    weak var paneResponder: NSResponder?
    override var nextResponder: NSResponder? {
        get { paneResponder ?? super.nextResponder }
        set { super.nextResponder = newValue }
    }
}

// MARK: - 窓割り中のどの画面か (ウインドウ・ビューからエディタを探す)

extension NSWindow {
    /// このウインドウで今使っているエディタ (窓割りのウインドウなら、フォーカスのある画面のエディタ)
    var frontEditor: EditorWindowController? { EditorWindowController.editor(for: self) }
}

extension NSView {
    /// このビューを持つエディタ (窓割りの画面の中なら、その画面のエディタ)
    var owningEditor: EditorWindowController? {
        var v: NSView? = self
        while let x = v {
            if let p = x as? TabPaneView { return p.editor }
            v = x.superview
        }
        return window?.windowController as? EditorWindowController
    }
}

// MARK: - エディタ側のつなぎ

extension EditorWindowController {
    /// 開いているすべてのエディタ
    static var all: [EditorWindowController] {
        NSDocumentController.shared.documents.compactMap { ($0 as? Document)?.editor }
    }

    /// 今のエディタ: キーウインドウ (なければメインウインドウ) のエディタ。窓割り中はフォーカスのある画面
    static var current: EditorWindowController? { editor(for: NSApp.keyWindow) ?? editor(for: NSApp.mainWindow) }

    /// ウインドウに出ているエディタ (窓割りのウインドウならフォーカスのある画面)
    static func editor(for w: NSWindow?) -> EditorWindowController? {
        guard let w = w else { return nil }
        if let r = w.contentView as? TabSplitRootView { return r.split?.focused ?? r.split?.panes.first?.editor }
        return w.windowController as? EditorWindowController
    }

    /// キー入力を受けるビュー (原稿用紙ならマス目の面)
    var focusView: NSView { textView.focusTarget }

    /// 窓割りの見出し・ウインドウのタイトルに出す名前 (タブと同じ)
    var madoTitle: String { windowTitle(forDocumentDisplayName: hdoc?.displayName ?? "") }

    /// タイトルが変わった: 窓割りの見出しとウインドウのタイトル、タブの印 (✓) を合わせる
    func madoTitleChanged() {
        if let sp = madoSplit { sp.titlesChanged(); return }
        guard Mado.isEnabled || tabMarked, let w = window else { return }
        let t = (tabMarked ? TabMarks.prefix : "") + w.title
        if w.tab.title != t { w.tab.title = t }
    }

    /// このエディタを前に出す (窓割りの画面なら、並べているウインドウを前に出して、その画面にフォーカス)
    func bringToFront() {
        guard let w = presentingWindow else { return }
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
        if let sp = madoSplit { sp.focus(self) } else { w.makeFirstResponder(focusView) }
    }

    /// この文書を閉じる (保存していなければ確かめる)。窓割りの画面なら、その画面だけを閉じる。
    /// done には閉じたかどうか (やめたら false)
    func closeMadoPane(_ done: ((Bool) -> Void)? = nil) {
        guard let doc = hdoc else { window?.performClose(nil); done?(true); return }
        MadoCloser.ask(doc) { [weak self] ok in
            if ok {
                // 先に並びから外す (ホストなら、並びをほかのウインドウに移してから閉じる)
                if let self = self { self.madoSplit?.remove(self) }
                doc.close()
            }
            done?(ok)
        }
    }

    /// ⌘W (ファイル > 閉じる): 窓割りの画面なら、その画面の文書だけを閉じる。
    /// (ふつうのウインドウではウインドウが先に受けるので、ここには来ない)
    @objc func performClose(_ sender: Any?) {
        if madoSplit != nil { closeMadoPane() } else { window?.performClose(sender) }
    }

    /// 並べているウインドウの閉じるボタン・タブの ×: 画面を全部閉じる
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let sp = madoSplit, sender === sp.hostWindow { return sp.windowShouldCloseAll() }
        return true
    }

    /// タイトルバーのドラッグが始まった: ほかのウインドウに寄せて離すと、タブにする・並びに入れる (TabTearOff)
    func windowWillMove(_ notification: Notification) {
        if Mado.isEnabled { TabTearOff.dragBegan(self) }
    }

    /// 窓割りの画面のとき: 文書の動作 (保存など) は、この画面の文書が受ける
    /// (何もしないと、並べているウインドウの文書が受けてしまう)
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if paneNextResponder != nil, let d = document as? NSDocument, d.responds(to: action) { return d }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    // MARK: メニュー (ウインドウ > 窓割り)

    @objc func madoSplitTabsSideBySideHM(_ sender: Any?) {
        if let w = presentingWindow { TabSplit.splitTabs(of: w, sideBySide: true) }
    }
    @objc func madoSplitTabsStackedHM(_ sender: Any?) {
        if let w = presentingWindow { TabSplit.splitTabs(of: w, sideBySide: false) }
    }
    @objc func madoSplitPaneSideBySideHM(_ sender: Any?) {
        if let w = presentingWindow { TabSplit.splitFocused(of: w, sideBySide: true) }
    }
    @objc func madoSplitPaneStackedHM(_ sender: Any?) {
        if let w = presentingWindow { TabSplit.splitFocused(of: w, sideBySide: false) }
    }
    @objc func madoUnsplitHM(_ sender: Any?) { madoSplit?.unsplit() }
    @objc func madoEqualizeHM(_ sender: Any?) { madoSplit?.equalizeAll() }
    @objc func madoNextPaneHM(_ sender: Any?) { moveMadoFocus(by: 1) }
    @objc func madoPreviousPaneHM(_ sender: Any?) { moveMadoFocus(by: -1) }
    private func moveMadoFocus(by d: Int) {
        guard let sp = madoSplit else { return }
        let list = sp.editors
        guard let i = list.firstIndex(where: { $0 === self }), list.count > 1 else { return }
        sp.focus(list[(i + d + list.count) % list.count])
    }
    @objc func madoToggleMarkHM(_ sender: Any?) {
        // 画面なら「この画面を選ぶ」(画面の ≡ メニューと同じ)
        if let sp = madoSplit { sp.togglePaneMark(self); return }
        guard TabMarks.canMark(self) else { return }
        TabMarks.toggle(self)
    }
    @objc func madoClearMarksHM(_ sender: Any?) {
        TabMarks.clearAll()
        TabSplit.all.forEach { $0.clearPaneMarks() }
    }
    @objc func madoMoveToNewWindowHM(_ sender: Any?) { TabSplit.moveToNewWindow(self) }
    @objc func madoSetOpenPlaceHM(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String else { return }
        UserDefaults.standard.set(v, forKey: Mado.openPlaceKey)
    }

    /// 窓割りのメニューの使える/使えない (窓割りの項目でなければ nil)
    func validateMadoItem(_ item: NSMenuItem) -> Bool? {
        let w = presentingWindow
        let sp = madoSplit
        switch item.action {
        case #selector(madoSplitTabsSideBySideHM(_:)):
            item.state = sp?.isSideBySide == true ? .on : .off
            return TabSplit.canSplit(w)
        case #selector(madoSplitTabsStackedHM(_:)):
            item.state = sp != nil && sp?.isSideBySide == false ? .on : .off
            return TabSplit.canSplit(w)
        case #selector(madoSplitPaneSideBySideHM(_:)), #selector(madoSplitPaneStackedHM(_:)):
            return TabSplit.canSplitFocused(w)
        case #selector(madoUnsplitHM(_:)), #selector(madoEqualizeHM(_:)),
             #selector(madoNextPaneHM(_:)), #selector(madoPreviousPaneHM(_:)):
            return sp != nil
        case #selector(madoToggleMarkHM(_:)):
            if let ps = sp {
                item.title = paneMarked ? L("この画面の選択を外す") : L("この画面を選ぶ")
                return ps.panes.count > 1
            }
            item.title = tabMarked ? L("このタブの選択を外す") : L("このタブを選ぶ")
            guard Mado.isEnabled, TabMarks.canMark(self) else { return false }
            return (window?.tabGroup?.windows.count ?? 1) > 1 || tabMarked
        case #selector(madoClearMarksHM(_:)):
            return Mado.isEnabled && (TabMarks.any || TabSplit.all.contains { $0.editors.contains { $0.paneMarked } })
        case #selector(madoMoveToNewWindowHM(_:)):
            item.title = sp != nil ? L("この画面を新しいウインドウに分ける") : L("このタブを新しいウインドウに分ける")
            return TabSplit.canMoveToNewWindow(w)
        case #selector(madoSetOpenPlaceHM(_:)):
            item.state = (item.representedObject as? String) == Mado.openPlace.rawValue ? .on : .off
            return Mado.isEnabled
        default:
            return nil
        }
    }
}

/// 文書を閉じてよいかを聞く (保存していなければ「保存しますか？」)。NSDocument の canClose の受け手
final class MadoCloser: NSObject {
    private static var waiting: [MadoCloser] = []
    private let done: (Bool) -> Void
    private init(_ done: @escaping (Bool) -> Void) { self.done = done }

    static func ask(_ doc: NSDocument, done: @escaping (Bool) -> Void) {
        let c = MadoCloser(done)
        waiting.append(c)
        doc.canClose(withDelegate: c, shouldClose: #selector(document(_:shouldClose:contextInfo:)), contextInfo: nil)
    }

    @objc func document(_ doc: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        MadoCloser.waiting.removeAll { $0 === self }
        done(shouldClose)
    }
}
