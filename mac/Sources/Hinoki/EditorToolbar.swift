import AppKit
import HinokiCore

/// ウインドウ上部のツールバー (秀丸のツールバーにあたるもの)。
/// ボタンはメニューと同じ動作を呼ぶ。右クリック →「ツールバーをカスタマイズ…」で並びを変えられる。
final class EditorToolbar: NSObject, NSToolbarDelegate {
    static let shared = EditorToolbar()
    /// 前の版で右端に置いていた「≡」ボタン (いまは使わない。残っていたら外す)
    private static let oldMoreID = NSToolbarItem.Identifier("satomaru.more")

    private struct Button {
        let id: String
        let label: String
        let symbol: String
        let action: String
        var tag: Int = 0
        var tip: String? = nil
    }

    private static let buttons: [Button] = [
        Button(id: "new", label: L("新規作成"), symbol: "doc.badge.plus", action: "newDocument:", tip: L("新規作成 (⌘N)")),
        Button(id: "open", label: L("開く"), symbol: "folder", action: "openDocument:", tip: L("ファイルを開く (⌘O)")),
        Button(id: "server", label: L("サーバ"), symbol: "server.rack", action: "openServersHM:", tip: L("サーバ (SFTP / FTP) につないでファイルを開く (⌃⌘O)")),
        Button(id: "save", label: L("保存"), symbol: "square.and.arrow.down", action: "saveDocument:", tip: L("上書き保存 (⌘S)")),
        Button(id: "saveAs", label: L("別名保存"), symbol: "square.and.arrow.down.on.square", action: "saveDocumentAs:", tip: L("名前を付けて保存 (⌘⇧S)")),
        Button(id: "undo", label: L("元に戻す"), symbol: "arrow.uturn.backward", action: "undo:", tip: L("元に戻す (⌘Z)")),
        Button(id: "redo", label: L("やり直し"), symbol: "arrow.uturn.forward", action: "redo:", tip: L("やり直し (⌘⇧Z)")),
        Button(id: "library", label: L("テキスト一覧"), symbol: "list.bullet.rectangle", action: "toggleTextLibraryHM:", tip: L("テキスト一覧を出す / しまう (⌘⇧L)")),
        Button(id: "libraryGrid", label: L("サムネ一覧"), symbol: "square.grid.2x2", action: "showLibraryGridHM:", tip: L("テキストをサムネ (カード) で見渡す (⌥⌘⇧L)")),
        Button(id: "folder", label: L("フォルダ"), symbol: "sidebar.left", action: "toggleFolderTreeHM:", tip: L("フォルダツリーを出す / しまう (⌘⇧E)")),
        Button(id: "cut", label: L("切り取り"), symbol: "scissors", action: "cut:", tip: L("切り取り (⌘X)")),
        Button(id: "copy", label: L("コピー"), symbol: "doc.on.doc", action: "copy:", tip: L("コピー (⌘C)")),
        Button(id: "paste", label: L("貼り付け"), symbol: "doc.on.clipboard", action: "paste:", tip: L("貼り付け (⌘V)")),
        Button(id: "duplicate", label: L("行複製"), symbol: "plus.square.on.square", action: "duplicateLineHM:", tip: L("行を複製 (⌘D)")),
        Button(id: "find", label: L("検索"), symbol: "magnifyingglass", action: "showFindPanelHM:", tip: L("検索 (⌘F)")),
        Button(id: "replace", label: L("置換"), symbol: "arrow.left.arrow.right", action: "showReplacePanelHM:", tip: L("置換 (⌘R)")),
        Button(id: "grep", label: "grep", symbol: "doc.text.magnifyingglass", action: "grepHM:", tip: L("ファイルから検索 (⌘⇧F)")),
        Button(id: "diff", label: L("差分"), symbol: "plus.forwardslash.minus", action: "toggleDiffHM:", tip: L("差分: 編集前とどこが変わったかを横に表示 (⇧⌘D)")),
        Button(id: "goto", label: L("行移動"), symbol: "arrow.right.to.line", action: "goToLineHM:", tip: L("指定行へ移動 (⌘L)")),
        Button(id: "split", label: L("分割"), symbol: "rectangle.split.1x2", action: "toggleSplitHM:", tip: L("上下に分割 / 分割をやめる (⌃⌘S)")),
        Button(id: "splitSide", label: L("左右分割"), symbol: "rectangle.split.2x1", action: "toggleSplitSideHM:", tip: L("左右に分割 / 分割をやめる (⌃⌥⌘S)")),
        Button(id: "share", label: L("共有"), symbol: "person.2", action: "startShareHM:", tip: L("この文書を共有して共同編集する")),
        Button(id: "screenshot", label: L("スクショ"), symbol: "camera", action: "screenshotHM:", tip: L("スクリーンショット (画像にする): 見えている部分か文書全体を、コピーまたは PNG で保存")),
        Button(id: "paper", label: L("用紙"), symbol: "doc.plaintext", action: "cyclePaperModeHM:", tip: L("用紙切替: 標準エディタ → 原稿用紙 → A4用紙")),
        Button(id: "speak", label: L("読み上げ"), symbol: "speaker.wave.2", action: "readAloudHM:", tip: L("読み上げる / 止める (⌥⌘R)")),
        Button(id: "dictate", label: L("音声入力"), symbol: "mic", action: "toggleDictationHM:", tip: L("声で入力。もう一度押すと止まる")),
        Button(id: "ai", label: L("AI"), symbol: "sparkles", action: "toggleAIHM:", tip: L("AI アシスタント (⇧⌘A)")),
        Button(id: "theme", label: L("色・フォント"), symbol: "paintpalette", action: "openThemeHM:", tip: L("色・フォント (⌘,)")),
    ]

    private static func id(_ s: String) -> NSToolbarItem.Identifier { NSToolbarItem.Identifier("satomaru.\(s)") }

    /// 最初に並べるもの: よく使うものだけ (ほかのボタンは「ツールバーをカスタマイズ…」で足せる)
    private static let defaultOrder: [NSToolbarItem.Identifier] = [
        id("new"), id("open"), id("save"), .space,
        id("undo"), id("redo"), .space,
        id("find"), .space,
        id("paper"), id("split"), id("screenshot"), id("ai"),
        .flexibleSpace, id("theme"),
    ]

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: Self.identifier)
        toolbar.delegate = self
        // アイコンの下に名前を出す (アイコンだけだと何のボタンか分かりにくい)
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        // 前の版で足した「≡」ボタンが並びに残っていたら外す
        DispatchQueue.main.async {
            if let i = toolbar.items.firstIndex(where: { $0.itemIdentifier == Self.oldMoreID }) { toolbar.removeItem(at: i) }
        }
        return toolbar
    }

    /// ウインドウが狭くてボタンが入りきらないときに出る Mac 標準の「»」を、「≡」の見た目にする (押したときの一覧はそのまま)。
    /// 「»」は公開された部品ではなく、絵を替えても描き直されるので、本物は透明にして (押せるまま)、上に「≡」の絵を重ねる。
    /// ツールバーの中から名前で探す。見つからなければ何もしない
    static func restyleOverflowButton(in window: NSWindow?) {
        guard let root = window?.contentView?.superview else { return }
        func walk(_ v: NSView) {
            if let b = v as? NSPopUpButton, NSStringFromClass(type(of: v)).contains("ClippedItemsIndicator"), let holder = b.superview {
                b.alphaValue = 0.011 // 見えないが、押せる
                b.toolTip = L("隠れたボタン")
                let mark = holder.subviews.compactMap { $0 as? OverflowMarkView }.first ?? {
                    let m = OverflowMarkView()
                    holder.addSubview(m)
                    return m
                }()
                m_layout(mark, over: b)
                return
            }
            v.subviews.forEach(walk)
        }
        func m_layout(_ m: OverflowMarkView, over b: NSView) {
            m.frame = b.frame
            m.autoresizingMask = b.autoresizingMask
        }
        walk(root)
    }

    /// 並びを大きく変えたときは名前を変える (前の版で覚えた並びではなく、新しい並びから始まるように)
    static let identifier = "SatomaruToolbar13"

    /// 使っていない拡張機能のボタンは出さない
    private static func enabled(_ ident: NSToolbarItem.Identifier) -> Bool {
        let raw = ident.rawValue.replacingOccurrences(of: "satomaru.", with: "")
        // 見えなくした機能 (共同編集) のボタンは、並べ替えの候補にも出さない
        if let e = EditorExtension.extensionFor(toolbarID: raw), EditorExtension.hidden.contains(e) { return false }
        return EditorExtension.extensionFor(toolbarID: raw)?.isOn ?? true
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultOrder.filter(Self.enabled)
    }

    /// 「用紙切替」のアイコン: 用紙の上 (右上) に、切り替えを表す丸い矢印を重ねる。
    /// 矢印のまわりは少し透かして、用紙の線と重ならないようにする (色はツールバーに合わせて変わる)
    static func paperSwitchImage(label: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let paper = NSImage(systemSymbolName: "doc.plaintext", accessibilityDescription: label)?.withSymbolConfiguration(cfg),
              let arrows = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .bold)) else { return nil }
        let size = NSSize(width: paper.size.width + 7, height: paper.size.height + 3)
        let img = NSImage(size: size, flipped: false) { _ in
            paper.draw(in: NSRect(x: 0, y: 0, width: paper.size.width, height: paper.size.height))
            let a = NSRect(x: size.width - arrows.size.width, y: size.height - arrows.size.height,
                           width: arrows.size.width, height: arrows.size.height)
            // 矢印の下の用紙を丸く消してから、矢印を描く
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setFill()
            NSBezierPath(ovalIn: a.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            arrows.draw(in: a)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = label
        return img
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.buttons.map { Self.id($0.id) }.filter(Self.enabled) + [.space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard Self.enabled(itemIdentifier), let b = Self.buttons.first(where: { Self.id($0.id) == itemIdentifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = b.label
        item.paletteLabel = b.label
        item.toolTip = b.tip
        // macOS 11 にない記号は似たもので代用する
        item.image = b.id == "paper" ? Self.paperSwitchImage(label: b.label)
            : NSImage(systemSymbolName: b.symbol, accessibilityDescription: b.label)
            ?? NSImage(systemSymbolName: "paintbrush", accessibilityDescription: b.label)
        item.action = Selector(b.action)
        item.target = nil // メニューと同じくレスポンダチェーンに送る
        item.tag = b.tag
        item.isBordered = true
        return item
    }
}

/// 「»」の上に重ねる「≡」の絵。押されたことは下の本物のボタンに通す
final class OverflowMarkView: NSImageView {
    init() {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: L("隠れたボタン"))
        symbolConfiguration = .init(pointSize: 15, weight: .regular)
        contentTintColor = .secondaryLabelColor
        imageScaling = .scaleNone
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
