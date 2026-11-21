import AppKit
import HinokiCore

/// サーバごとの「お気に入り」と「最近見たフォルダ・最近開いたファイル」。一発でそこへ行けるようにする
enum RemotePlaces {
    struct Place: Codable, Equatable {
        var path: String
        var isFile: Bool
    }

    private struct Store: Codable {
        var favorites: [Place] = []
        var recentFolders: [String] = []
        var recentFiles: [String] = []
    }

    static let didChange = Notification.Name("RemotePlacesDidChange")
    private static let key = "remotePlaces"
    private static let maxRecent = 15

    private static var all: [String: Store] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let v = try? JSONDecoder().decode([String: Store].self, from: data) else { return [:] }
            return v
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: key) }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static func favorites(_ serverID: String) -> [Place] { all[serverID]?.favorites ?? [] }
    static func recentFolders(_ serverID: String) -> [String] { all[serverID]?.recentFolders ?? [] }
    static func recentFiles(_ serverID: String) -> [String] { all[serverID]?.recentFiles ?? [] }

    static func isFavorite(_ serverID: String, _ path: String) -> Bool {
        favorites(serverID).contains { $0.path == path }
    }

    static func toggleFavorite(_ serverID: String, _ place: Place) {
        var a = all
        var s = a[serverID] ?? Store()
        if let i = s.favorites.firstIndex(where: { $0.path == place.path }) {
            s.favorites.remove(at: i)
        } else {
            s.favorites.append(place)
            s.favorites.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        a[serverID] = s
        all = a
    }

    /// 見たフォルダを覚える (新しいものが先頭)
    static func visitFolder(_ serverID: String, _ path: String) {
        var a = all
        var s = a[serverID] ?? Store()
        s.recentFolders.removeAll { $0 == path }
        s.recentFolders.insert(path, at: 0)
        s.recentFolders = Array(s.recentFolders.prefix(maxRecent))
        a[serverID] = s
        all = a
    }

    /// 開いたファイルを覚える
    static func visitFile(_ serverID: String, _ path: String) {
        var a = all
        var s = a[serverID] ?? Store()
        s.recentFiles.removeAll { $0 == path }
        s.recentFiles.insert(path, at: 0)
        s.recentFiles = Array(s.recentFiles.prefix(maxRecent))
        a[serverID] = s
        all = a
    }

    static func clearRecent(_ serverID: String) {
        var a = all
        a[serverID]?.recentFolders = []
        a[serverID]?.recentFiles = []
        all = a
    }

    /// サーバを消したとき
    static func forget(_ serverID: String) {
        var a = all
        a[serverID] = nil
        all = a
    }

    /// お気に入り・最近のフォルダ・最近のファイルのメニュー。選ぶと pick が呼ばれる
    static func menu(serverID: String, currentFolder: String?, pick: @escaping (Place) -> Void) -> NSMenu {
        let menu = NSMenu()
        let handler = MenuHandler(serverID: serverID, pick: pick)
        func header(_ title: String) {
            let h = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            h.isEnabled = false
            menu.addItem(h)
        }
        func add(_ place: Place) {
            let item = NSMenuItem(title: place.path, action: #selector(MenuHandler.choose(_:)), keyEquivalent: "")
            item.target = handler
            item.representedObject = PlaceBox(place)
            item.image = NSImage(systemSymbolName: place.isFile ? "doc.text" : "folder", accessibilityDescription: nil)
            item.indentationLevel = 1
            menu.addItem(item)
        }

        if let cur = currentFolder {
            let fav = isFavorite(serverID, cur)
            let t = NSMenuItem(title: fav ? L("このフォルダをお気に入りから外す") : L("このフォルダをお気に入りに入れる"),
                               action: #selector(MenuHandler.toggleCurrent(_:)), keyEquivalent: "")
            t.target = handler
            t.representedObject = cur
            t.image = NSImage(systemSymbolName: fav ? "star.slash" : "star", accessibilityDescription: nil)
            menu.addItem(t)
            menu.addItem(.separator())
        }

        let favs = favorites(serverID)
        header(L("お気に入り"))
        if favs.isEmpty {
            let none = NSMenuItem(title: L("(まだありません)"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            none.indentationLevel = 1
            menu.addItem(none)
        }
        favs.forEach(add)

        let folders = recentFolders(serverID)
        if !folders.isEmpty {
            menu.addItem(.separator())
            header(L("最近見たフォルダ"))
            folders.forEach { add(Place(path: $0, isFile: false)) }
        }
        let files = recentFiles(serverID)
        if !files.isEmpty {
            menu.addItem(.separator())
            header(L("最近開いたファイル"))
            files.forEach { add(Place(path: $0, isFile: true)) }
        }
        if !folders.isEmpty || !files.isEmpty {
            menu.addItem(.separator())
            let clear = NSMenuItem(title: L("履歴を消す"), action: #selector(MenuHandler.clear(_:)), keyEquivalent: "")
            clear.target = handler
            menu.addItem(clear)
        }
        // メニューが開いているあいだ handler を生かしておく
        objc_setAssociatedObject(menu, &handlerKey, handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return menu
    }

    private static var handlerKey = 0

    private final class PlaceBox: NSObject {
        let place: Place
        init(_ p: Place) { place = p }
    }

    private final class MenuHandler: NSObject {
        let serverID: String
        let pick: (Place) -> Void
        init(serverID: String, pick: @escaping (Place) -> Void) { self.serverID = serverID; self.pick = pick }

        @objc func choose(_ sender: NSMenuItem) {
            if let b = sender.representedObject as? PlaceBox { pick(b.place) }
        }
        @objc func toggleCurrent(_ sender: NSMenuItem) {
            if let p = sender.representedObject as? String { RemotePlaces.toggleFavorite(serverID, Place(path: p, isFile: false)) }
        }
        @objc func clear(_ sender: NSMenuItem) { RemotePlaces.clearRecent(serverID) }
    }
}

/// お気に入り・最近見たフォルダ・最近開いたファイルを常に出しておく一覧。クリックでそこへ行く
final class RemotePlacesListView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private enum Row {
        case header(String)
        case place(RemotePlaces.Place, favorite: Bool)
        case empty(String)
    }

    /// 出すサーバ (nil なら空)
    var serverID: String? { didSet { if oldValue != serverID { reload() } } }
    /// いま見ているフォルダ (太字にする)
    var currentFolder: String? { didSet { if oldValue != currentFolder { table.reloadData() } } }
    /// 場所を選んだとき
    var onPick: ((RemotePlaces.Place) -> Void)?

    private let table = NSTableView()
    private var rows: [Row] = []

    init(compact: Bool = false) {
        super.init(frame: .zero)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("place"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .sourceList
        table.rowSizeStyle = .custom
        table.rowHeight = 20
        table.usesAutomaticRowHeights = false
        // 見出しを上に貼り付けない (スクロールしたときに下の行と重なるため)
        table.floatsGroupRows = false
        // 列の幅はいつも欄の幅に合わせる (横にはみ出さず、長い名前は省く)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        table.setAccessibilityLabel(L("お気に入り"))
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = compact ? .noBorder : .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: RemotePlaces.didChange, object: nil)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func reload() {
        rows = []
        guard let sid = serverID else {
            rows = [.header(L("お気に入り")), .empty(L("サーバを選ぶと出ます"))]
            table.reloadData()
            return
        }
        let favs = RemotePlaces.favorites(sid)
        rows.append(.header(L("お気に入り")))
        if favs.isEmpty { rows.append(.empty(L("★ または右クリックで追加"))) }
        rows += favs.map { .place($0, favorite: true) }
        let folders = RemotePlaces.recentFolders(sid)
        if !folders.isEmpty {
            rows.append(.header(L("最近見たフォルダ")))
            rows += folders.map { .place(RemotePlaces.Place(path: $0, isFile: false), favorite: false) }
        }
        let files = RemotePlaces.recentFiles(sid)
        if !files.isEmpty {
            rows.append(.header(L("最近開いたファイル")))
            rows += files.map { .place(RemotePlaces.Place(path: $0, isFile: true), favorite: false) }
        }
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .place = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let t):
            return Self.cell(text: NSAttributedString(string: t, attributes: [
                .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]),
                image: nil, tint: nil, indent: 2)
        case .empty(let t):
            return Self.cell(text: NSAttributedString(string: t, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.tertiaryLabelColor]),
                image: nil, tint: nil, indent: 22)
        case .place(let p, let favorite):
            // 名前を先に、場所は薄く後ろに (1 行に収め、長ければ真ん中を「…」で省く)
            let name = (p.path as NSString).lastPathComponent.isEmpty ? p.path : (p.path as NSString).lastPathComponent
            let parent = (p.path as NSString).deletingLastPathComponent
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingMiddle
            let text = NSMutableAttributedString(string: name, attributes: [
                .font: p.path == currentFolder ? NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
                                               : NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor, .paragraphStyle: para])
            if !parent.isEmpty && parent != p.path {
                text.append(NSAttributedString(string: "  " + parent, attributes: [
                    .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]))
            }
            let symbol = favorite ? "star.fill" : (p.isFile ? "doc.text" : "folder")
            let tint: NSColor = favorite ? .systemYellow : (p.isFile ? .secondaryLabelColor : .controlAccentColor)
            let cell = Self.cell(text: text, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil), tint: tint, indent: 6)
            cell.toolTip = p.path
            return cell
        }
    }

    /// 1 行のセル: (アイコン) 文字。文字は 1 行だけで、はみ出す分は省く
    private static func cell(text: NSAttributedString, image: NSImage?, tint: NSColor?, indent: CGFloat) -> NSTableCellView {
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithAttributedString: text)
        tf.usesSingleLineMode = true
        tf.maximumNumberOfLines = 1
        tf.lineBreakMode = .byTruncatingMiddle
        tf.cell?.truncatesLastVisibleLine = true
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf
        var lead = cell.leadingAnchor
        var gap = indent
        if let image = image {
            let iv = NSImageView(image: image)
            iv.contentTintColor = tint
            iv.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(iv)
            cell.imageView = iv
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: indent),
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 14),
                iv.heightAnchor.constraint(equalToConstant: 14),
            ])
            lead = iv.trailingAnchor
            gap = 5
        }
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: lead, constant: gap),
            tf.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func clicked(_ sender: Any?) {
        let row = table.clickedRow
        guard row >= 0, row < rows.count, case .place(let p, _) = rows[row] else { return }
        onPick?(p)
        table.deselectAll(nil)
    }

    // 右クリック: お気に入りに入れる / 外す
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard let sid = serverID, row >= 0, row < rows.count, case .place(let p, _) = rows[row] else { return }
        let fav = RemotePlaces.isFavorite(sid, p.path)
        let open = NSMenuItem(title: L("開く"), action: #selector(menuOpen(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = row
        menu.addItem(open)
        let t = NSMenuItem(title: fav ? L("お気に入りから外す") : L("お気に入りに入れる"), action: #selector(menuToggle(_:)), keyEquivalent: "")
        t.target = self
        t.representedObject = row
        menu.addItem(t)
    }

    @objc private func menuOpen(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int, row < rows.count, case .place(let p, _) = rows[row] else { return }
        onPick?(p)
    }

    @objc private func menuToggle(_ sender: NSMenuItem) {
        guard let sid = serverID, let row = sender.representedObject as? Int, row < rows.count,
              case .place(let p, _) = rows[row] else { return }
        RemotePlaces.toggleFavorite(sid, p)
    }
}
