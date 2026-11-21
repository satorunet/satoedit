import AppKit

/// ウインドウ上部のツールバー (秀丸のツールバーにあたるもの)。
/// ボタンはメニューと同じ動作を呼ぶ。右クリック →「ツールバーをカスタマイズ…」で並びを変えられる。
final class EditorToolbar: NSObject, NSToolbarDelegate {
    static let shared = EditorToolbar()

    private struct Button {
        let id: String
        let label: String
        let symbol: String
        let action: String
        var tag: Int = 0
        var tip: String? = nil
    }

    private static let buttons: [Button] = [
        Button(id: "new", label: "新規", symbol: "doc.badge.plus", action: "newWindowForTab:", tip: "新しいタブ (⌘T)"),
        Button(id: "open", label: "開く", symbol: "folder", action: "openDocument:", tip: "ファイルを開く (⌘O)"),
        Button(id: "server", label: "サーバ", symbol: "server.rack", action: "openServersHM:", tip: "サーバ (SFTP / FTP) につないでファイルを開く (⌃⌘O)"),
        Button(id: "save", label: "保存", symbol: "square.and.arrow.down", action: "saveDocument:", tip: "上書き保存 (⌘S)"),
        Button(id: "saveAs", label: "別名保存", symbol: "square.and.arrow.down.on.square", action: "saveDocumentAs:", tip: "名前を付けて保存 (⌘⇧S)"),
        Button(id: "undo", label: "元に戻す", symbol: "arrow.uturn.backward", action: "undo:", tip: "元に戻す (⌘Z)"),
        Button(id: "redo", label: "やり直し", symbol: "arrow.uturn.forward", action: "redo:", tip: "やり直し (⌘⇧Z)"),
        Button(id: "folder", label: "フォルダ", symbol: "sidebar.left", action: "toggleFolderTreeHM:", tip: "フォルダツリーを出す / しまう (⌘⇧E)"),
        Button(id: "cut", label: "切り取り", symbol: "scissors", action: "cut:", tip: "切り取り (⌘X)"),
        Button(id: "copy", label: "コピー", symbol: "doc.on.doc", action: "copy:", tip: "コピー (⌘C)"),
        Button(id: "paste", label: "貼り付け", symbol: "doc.on.clipboard", action: "paste:", tip: "貼り付け (⌘V)"),
        Button(id: "duplicate", label: "行複製", symbol: "plus.square.on.square", action: "duplicateLineHM:", tip: "行を複製 (⌘D)"),
        Button(id: "find", label: "検索", symbol: "magnifyingglass", action: "showFindPanelHM:", tip: "検索 (⌘F)"),
        Button(id: "replace", label: "置換", symbol: "arrow.left.arrow.right", action: "showReplacePanelHM:", tip: "置換 (⌘R)"),
        Button(id: "grep", label: "grep", symbol: "doc.text.magnifyingglass", action: "grepHM:", tip: "ファイルから検索 (⌘⇧F)"),
        Button(id: "goto", label: "行移動", symbol: "arrow.right.to.line", action: "goToLineHM:", tip: "指定行へ移動 (⌘L)"),
        Button(id: "split", label: "分割", symbol: "rectangle.split.1x2", action: "toggleSplitHM:", tip: "上下に分割 / 分割をやめる (⌃⌘S)"),
        Button(id: "share", label: "共有", symbol: "person.2", action: "startShareHM:", tip: "この文書を共有して共同編集する"),
        Button(id: "paper", label: "用紙", symbol: "doc.plaintext", action: "cyclePaperModeHM:", tip: "用紙モード: 通常 → 作文用紙 → A4"),
        Button(id: "ai", label: "AI", symbol: "sparkles", action: "toggleAIHM:", tip: "AI アシスタント (⇧⌘A)"),
        Button(id: "theme", label: "色・フォント", symbol: "paintpalette", action: "openThemeHM:", tip: "色・フォント (⌘,)"),
    ]

    private static func id(_ s: String) -> NSToolbarItem.Identifier { NSToolbarItem.Identifier("satomaru.\(s)") }

    /// 最初に並べるもの
    private static let defaultOrder: [NSToolbarItem.Identifier] = [
        id("folder"), .space, id("new"), id("open"), id("server"), id("save"), .space,
        id("undo"), id("redo"), .space,
        id("cut"), id("copy"), id("paste"), id("duplicate"), .space,
        id("find"), id("replace"), id("grep"), id("goto"), .space, id("split"), id("paper"), id("share"), id("ai"),
        .flexibleSpace, id("theme"),
    ]

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: Self.identifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        return toolbar
    }

    static let identifier = "SatomaruToolbar8"

    /// 使っていない拡張機能のボタンは出さない
    private static func enabled(_ ident: NSToolbarItem.Identifier) -> Bool {
        let raw = ident.rawValue.replacingOccurrences(of: "satomaru.", with: "")
        return EditorExtension.extensionFor(toolbarID: raw)?.isOn ?? true
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultOrder.filter(Self.enabled)
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
        item.image = NSImage(systemSymbolName: b.symbol, accessibilityDescription: b.label)
            ?? NSImage(systemSymbolName: "paintbrush", accessibilityDescription: b.label)
        item.action = Selector(b.action)
        item.target = nil // メニューと同じくレスポンダチェーンに送る
        item.tag = b.tag
        item.isBordered = true
        return item
    }
}
