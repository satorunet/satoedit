import AppKit
import HinokiCore

/// キー割り当てとメニューの表示/非表示。UserDefaults に保存し、起動時と変更時にメニューへ当てはめる。
enum MenuCustomizer {
    struct Shortcut: Codable, Equatable {
        var key: String
        var mods: UInt

        var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: mods) }
        var isEmpty: Bool { key.isEmpty }

        /// ⌃⌥⇧⌘ + キー の表示
        var display: String {
            guard !key.isEmpty else { return "" }
            var s = ""
            if flags.contains(.control) { s += "⌃" }
            if flags.contains(.option) { s += "⌥" }
            if flags.contains(.shift) { s += "⇧" }
            if flags.contains(.command) { s += "⌘" }
            return s + MenuCustomizer.keyName(key)
        }
    }

    struct Entry {
        /// 項目を覚えておく名前。言語を切り替えても変わらないよう、日本語の名前でつなぐ (「編集 > 行 > 行を複製」)
        let id: String
        /// 画面に出す道筋 (いまの言語で)
        let path: String
        let isSubmenu: Bool
    }

    private static let keysKey = "keyBindings"
    private static let hiddenKey = "hiddenMenuItems"

    /// 起動時のメニューにあった項目と元のショートカット
    private(set) static var entries: [Entry] = []
    private static var originals: [String: Shortcut] = [:]

    // MARK: 保存値

    static var overrides: [String: Shortcut] {
        get {
            guard let data = UserDefaults.standard.data(forKey: keysKey),
                  let dict = try? JSONDecoder().decode([String: Shortcut].self, from: data) else { return [:] }
            return dict
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: keysKey)
            apply()
        }
    }

    static var hidden: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []) }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: hiddenKey)
            apply()
        }
    }

    static func original(_ id: String) -> Shortcut { originals[id] ?? Shortcut(key: "", mods: 0) }
    static func current(_ id: String) -> Shortcut { overrides[id] ?? original(id) }

    // MARK: メニューとの対応

    /// メニューを作った直後に 1 回呼ぶ
    static func setUp(_ menu: NSMenu) {
        entries = []
        originals = [:]
        walk(menu, prefix: nil) { id, path, item in
            entries.append(Entry(id: id, path: path, isSubmenu: item.hasSubmenu))
            if !item.hasSubmenu {
                originals[id] = Shortcut(key: item.keyEquivalent,
                                         mods: item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]).rawValue)
            }
        }
        apply()
    }

    /// 項目ごとに「親 > 子」の名前で呼ぶ。中身を開くたびに作り直すメニュー (言語) やウインドウ一覧は除く
    private static func walk(_ menu: NSMenu, prefix: String?, path: String? = nil, _ body: (String, String, NSMenuItem) -> Void) {
        for item in menu.items where !item.isSeparatorItem && !item.title.isEmpty && item.tag != MainMenu.sectionHeaderTag {
            // 自分で作った項目は identifier に日本語の名前が入っている (MainMenu)。システムが足した項目は題名そのまま
            let name = item.identifier?.rawValue ?? item.title
            let id = prefix.map { $0 + " > " + name } ?? name
            // 画面に出す名前では、アプリ名 (さとるエディタ) を「エディタ」と短く出す
            let title = item.title.replacingOccurrences(of: MainMenu.appName, with: L("エディタ"))
            let shown = path.map { $0 + " > " + title } ?? title
            body(id, shown, item)
            if let sub = item.submenu, sub.delegate == nil, sub !== NSApp.servicesMenu {
                walk(sub, prefix: id, path: shown, body)
            }
        }
    }

    static func apply() {
        guard let menu = NSApp.mainMenu else { return }
        let keys = overrides
        let hide = hidden
        let known = Set(entries.map { $0.id })
        walk(menu, prefix: nil) { id, _, item in
            guard known.contains(id) else { return }
            // メニュー編集で隠したもの、または使っていない拡張機能のもの
            item.isHidden = hide.contains(id) || ExtensionUI.hides(item, topLevel: !id.contains(" > "))
            if !item.hasSubmenu, let s = keys[id] ?? originals[id] {
                item.keyEquivalent = s.key
                item.keyEquivalentModifierMask = s.flags
            }
        }
    }

    /// 同じキーを使っているほかの項目
    static func conflict(for shortcut: Shortcut, except id: String) -> Entry? {
        guard !shortcut.isEmpty else { return nil }
        return entries.first { !$0.isSubmenu && $0.id != id && current($0.id) == shortcut }
    }

    static func keyName(_ key: String) -> String {
        guard let scalar = key.unicodeScalars.first else { return "" }
        switch scalar.value {
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF704...0xF726: return "F\(scalar.value - 0xF704 + 1)"
        case 0xF728, 0x7F: return "⌦"
        case 0x08: return "⌫"
        case 0x0D, 0x03: return "↩"
        case 0x09: return "⇥"
        case 0x1B: return "⎋"
        case 0x20: return "Space"
        case 0xF729: return "Home"
        case 0xF72B: return "End"
        case 0xF72C: return "PageUp"
        case 0xF72D: return "PageDown"
        default: return key.uppercased()
        }
    }
}

// MARK: - キー割り当て

/// 設定ウインドウの「キー割り当て」タブ
final class KeyBindingSettingsPane: NSObject, SettingsPane, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let title = L("キー割り当て")
    let view = NSView()

    private let table = NSTableView()
    private let search = NSSearchField()
    private var rows: [MenuCustomizer.Entry] = []
    private var monitor: Any?

    override init() {
        super.init()
        let cmd = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cmd"))
        cmd.title = L("メニュー")
        cmd.width = 430
        let key = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key"))
        key.title = L("キー")
        key.width = 140
        table.addTableColumn(cmd)
        table.addTableColumn(key)
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(assign(_:))
        table.target = self
        table.usesAlternatingRowBackgroundColors = true
        search.placeholderString = L("メニュー名やキーで絞り込み")
        search.delegate = self

        let list = SettingsUI.scrolled(table)
        let buttons = SettingsUI.row([
            SettingsUI.button(L("キーを割り当てる…"), self, #selector(assign(_:))),
            SettingsUI.button(L("割り当てを外す"), self, #selector(clear(_:))),
            SettingsUI.button(L("既定に戻す"), self, #selector(resetOne(_:))),
            NSView(),
            SettingsUI.button(L("すべて既定に戻す"), self, #selector(resetAll(_:))),
        ])
        let note = SettingsUI.label(L("ダブルクリックして、キーを押す。太字は変更したもの。"), small: true)
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 2
        let stack = SettingsUI.fill(view, with: [search, list, buttons, note])
        for v in [search, list, buttons, note] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        reload()
    }

    func willShow() { reload() }

    private func reload() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        rows = MenuCustomizer.entries.filter { e in
            guard !e.isSubmenu else { return false }
            if q.isEmpty { return true }
            return e.path.lowercased().contains(q) || MenuCustomizer.current(e.id).display.lowercased().contains(q)
        }
        table.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = rows[row]
        let changed = MenuCustomizer.overrides[e.id] != nil
        let text = tableColumn?.identifier.rawValue == "key" ? MenuCustomizer.current(e.id).display : e.path
        let cell = NSTextField(labelWithString: text)
        cell.lineBreakMode = .byTruncatingHead
        if changed { cell.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
        return cell
    }

    private var selectedEntry: MenuCustomizer.Entry? {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        return r >= 0 && r < rows.count ? rows[r] : nil
    }

    private func set(_ shortcut: MenuCustomizer.Shortcut?, for id: String) {
        var o = MenuCustomizer.overrides
        if let s = shortcut, s != MenuCustomizer.original(id) { o[id] = s } else { o.removeValue(forKey: id) }
        MenuCustomizer.overrides = o
        reload()
    }

    @objc private func assign(_ sender: Any?) {
        guard let entry = selectedEntry, let window = view.window else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = L("「{0}」に割り当てるキーを押してください", entry.path)
        let now = MenuCustomizer.current(entry.id).display
        alert.informativeText = L("いま: {0}\nやめるときは esc", now.isEmpty ? L("なし") : now)
        alert.addButton(withTitle: L("やめる"))
        var captured: MenuCustomizer.Shortcut?
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53 && mods.isEmpty { // esc
                window.endSheet(alert.window, returnCode: .cancel)
                return nil
            }
            guard var chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
            let scalar = chars.unicodeScalars.first!.value
            let isFunctionKey = (0xF704...0xF726).contains(scalar)
            guard isFunctionKey || !mods.intersection([.command, .control, .option]).isEmpty else {
                NSSound.beep()
                return nil
            }
            if chars.count == 1, chars.lowercased() != chars.uppercased() { chars = chars.lowercased() }
            captured = MenuCustomizer.Shortcut(key: chars, mods: mods.rawValue)
            window.endSheet(alert.window, returnCode: .OK)
            return nil
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            if let m = self.monitor { NSEvent.removeMonitor(m) }
            self.monitor = nil
            guard response == .OK, let s = captured else { return }
            if let other = MenuCustomizer.conflict(for: s, except: entry.id) {
                let ask = NSAlert()
                ask.messageText = L("{0} は「{1}」で使われています", s.display, other.path)
                ask.informativeText = L("そちらの割り当てを外して、「{0}」に割り当てますか？", entry.path)
                ask.addButton(withTitle: L("割り当てる"))
                ask.addButton(withTitle: L("やめる"))
                guard ask.runModal() == .alertFirstButtonReturn else { return }
                self.set(MenuCustomizer.Shortcut(key: "", mods: 0), for: other.id)
            }
            self.set(s, for: entry.id)
        }
    }

    @objc private func clear(_ sender: Any?) {
        guard let e = selectedEntry else { NSSound.beep(); return }
        set(MenuCustomizer.Shortcut(key: "", mods: 0), for: e.id)
    }

    @objc private func resetOne(_ sender: Any?) {
        guard let e = selectedEntry else { NSSound.beep(); return }
        set(nil, for: e.id)
    }

    @objc private func resetAll(_ sender: Any?) {
        MenuCustomizer.overrides = [:]
        reload()
    }
}

// MARK: - メニュー編集

/// 設定ウインドウの「メニュー編集」タブ。使わないメニュー項目を隠す
final class MenuSettingsPane: NSObject, SettingsPane, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let title = L("メニュー編集")
    let view = NSView()

    private let table = NSTableView()
    private let search = NSSearchField()
    private var rows: [MenuCustomizer.Entry] = []

    override init() {
        super.init()
        let show = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("show"))
        show.title = L("表示")
        show.width = 44
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.title = L("メニュー項目")
        name.width = 440
        let key = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key"))
        key.title = L("キー")
        key.width = 110
        [show, name, key].forEach { table.addTableColumn($0) }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        search.placeholderString = L("メニュー名で絞り込み")
        search.delegate = self

        let list = SettingsUI.scrolled(table)
        let buttons = SettingsUI.row([
            SettingsUI.button(L("すべて表示に戻す"), self, #selector(showAll(_:))),
            NSView(),
            SettingsUI.button(L("ツールバーを編集…"), self, #selector(editToolbar(_:))),
        ])
        let note = SettingsUI.label(L("チェックを外すとメニューに出なくなります。"), small: true)
        let stack = SettingsUI.fill(view, with: [search, list, buttons, note])
        for v in [search, list, buttons, note] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        reload()
    }

    func willShow() { reload() }

    private func reload() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        rows = MenuCustomizer.entries.filter { q.isEmpty || $0.path.lowercased().contains(q) }
        table.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = rows[row]
        switch tableColumn?.identifier.rawValue {
        case "show":
            let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
            b.state = MenuCustomizer.hidden.contains(e.id) ? .off : .on
            b.tag = row
            return b
        case "key":
            return NSTextField(labelWithString: e.isSubmenu ? "" : MenuCustomizer.current(e.id).display)
        default:
            let depth = e.path.components(separatedBy: " > ").count - 1
            let name = e.path.components(separatedBy: " > ").last ?? e.path
            let cell = NSTextField(labelWithString: String(repeating: "　　", count: depth) + name + (e.isSubmenu ? " ▸" : ""))
            if depth == 0 { cell.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
            return cell
        }
    }

    @objc private func toggle(_ sender: NSButton) {
        guard sender.tag < rows.count else { return }
        var h = MenuCustomizer.hidden
        let id = rows[sender.tag].id
        if sender.state == .on { h.remove(id) } else { h.insert(id) }
        MenuCustomizer.hidden = h
    }

    @objc private func showAll(_ sender: Any?) {
        MenuCustomizer.hidden = []
        reload()
    }

    @objc private func editToolbar(_ sender: Any?) {
        guard let w = NSApp.orderedWindows.first(where: { $0.windowController is EditorWindowController }) else {
            NSSound.beep()
            return
        }
        w.makeKeyAndOrderFront(nil)
        w.toolbar?.runCustomizationPalette(nil)
    }
}
