import AppKit
import HinokiCore

/// 設定ウインドウの「ファイルタイプ別の設定」タブ。
/// 左で言語を選び、右で拡張子・タブ幅・コメント記号・キーワードなどを変える。変更はすぐ反映・保存される。
final class FileTypeSettingsPane: NSObject, SettingsPane, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    let title = L("ファイルタイプ別の設定")
    let view = NSView()

    private var profiles: [LanguageProfile] = []
    private let builtIns = BuiltInProfiles.all
    private let table = NSTableView()
    private var selected: Int { table.selectedRow }

    private let nameField = NSTextField()
    private let extField = NSTextField()
    private let fileNamesField = NSTextField()
    private let tabWidthField = NSTextField()
    private let tabStepper = NSStepper()
    private let spacesCheck = NSButton(checkboxWithTitle: L("Tab キーでスペースを入れる"), target: nil, action: nil)
    private let lineCommentField = NSTextField()
    private let blockCommentField = NSTextField()
    private let stringField = NSTextField()
    private let multilineField = NSTextField()
    private let caseCheck = NSButton(checkboxWithTitle: L("大文字・小文字を区別しない"), target: nil, action: nil)
    private let capTypeCheck = NSButton(checkboxWithTitle: L("大文字で始まる語を型名の色にする"), target: nil, action: nil)
    private let tagCheck = NSButton(checkboxWithTitle: L("HTML/XML のタグに色を付ける"), target: nil, action: nil)
    private let keywordsView = NSTextView()
    private let typesView = NSTextView()
    private let stateLabel = SettingsUI.label("", small: true)
    private let removeButton = NSButton()
    private var form: NSView!
    private var loading = false
    private var saveWork: DispatchWorkItem?

    override init() {
        super.init()
        buildUI()
        reloadProfiles()
        NotificationCenter.default.addObserver(self, selector: #selector(externalChange),
                                               name: .profilesDidChange, object: nil)
    }

    func willShow() {
        if saveWork == nil { reloadProfiles() }
    }

    func willHide() { flushSave() }

    // MARK: 画面

    private func buildUI() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = L("ファイルタイプ")
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        let list = SettingsUI.scrolled(table)
        list.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let add = SettingsUI.button(L("追加"), self, #selector(addProfile(_:)))
        removeButton.title = L("削除")
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeProfile(_:))
        let leftButtons = SettingsUI.row([add, removeButton])
        let left = NSStackView(views: [list, leftButtons])
        left.orientation = .vertical
        left.alignment = .leading

        for f in [nameField, extField, fileNamesField, lineCommentField, blockCommentField, stringField, multilineField] {
            f.delegate = self
            f.translatesAutoresizingMaskIntoConstraints = false
        }
        tabWidthField.delegate = self
        tabWidthField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        tabStepper.minValue = 1
        tabStepper.maxValue = 16
        tabStepper.target = self
        tabStepper.action = #selector(stepperChanged(_:))
        for c in [spacesCheck, caseCheck, capTypeCheck, tagCheck] {
            c.target = self
            c.action = #selector(fieldChanged(_:))
        }

        let grid = NSGridView(views: [
            [SettingsUI.label(L("名前")), nameField],
            [SettingsUI.label(L("拡張子")), extField],
            [SettingsUI.label(L("ファイル名")), fileNamesField],
            [SettingsUI.label(L("タブ幅")), SettingsUI.row([tabWidthField, tabStepper, spacesCheck])],
            [SettingsUI.label(L("行コメント")), lineCommentField],
            [SettingsUI.label(L("ブロックコメント")), blockCommentField],
            [SettingsUI.label(L("文字列の囲み")), stringField],
            [SettingsUI.label(L("複数行の文字列")), multilineField],
            [NSGridCell.emptyContentView, SettingsUI.row([caseCheck, capTypeCheck])],
            [NSGridCell.emptyContentView, tagCheck],
        ])
        grid.rowSpacing = 6
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for f in [nameField, extField, fileNamesField, lineCommentField, blockCommentField, stringField, multilineField] {
            f.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        }
        extField.placeholderString = L("例: c h cpp (空白区切り)")
        fileNamesField.placeholderString = L("例: Makefile .zshrc")
        lineCommentField.placeholderString = L("例: //")
        blockCommentField.placeholderString = L("例: /* */ , <!-- -->")
        stringField.placeholderString = L("例: \" '")

        let words = NSStackView(views: [
            labeled(L("キーワード (空白・改行区切り)"), keywordsView),
            labeled(L("型名など (空白・改行区切り)"), typesView),
        ])
        words.distribution = .fillEqually
        words.spacing = 12

        let json = SettingsUI.button(L("profiles.json を直接編集…"), self, #selector(openJSON(_:)))
        let reset = SettingsUI.button(L("組み込みの設定に戻す"), self, #selector(resetProfile(_:)))
        let bottom = SettingsUI.row([stateLabel, NSView(), reset, json])

        let right = NSStackView(views: [grid, words, bottom])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 10
        for v in [words, bottom] {
            v.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        }
        form = right

        let split = NSStackView(views: [left, right])
        split.orientation = .horizontal
        split.alignment = .top
        split.spacing = 16
        let stack = SettingsUI.fill(view, with: [split,
            SettingsUI.label(L("変更はすぐ反映されます。"), small: true)])
        split.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        list.heightAnchor.constraint(equalTo: right.heightAnchor, constant: -30).isActive = true
    }

    private func labeled(_ title: String, _ tv: NSTextView) -> NSView {
        tv.isRichText = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.delegate = self
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let s = NSStackView(views: [SettingsUI.label(title), sv])
        s.orientation = .vertical
        s.alignment = .leading
        sv.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        return s
    }

    // MARK: 表

    func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let p = profiles[row]
        let mark: String
        if let b = builtIns.first(where: { $0.name == p.name }) {
            mark = b == p ? "" : "  ●"
        } else {
            mark = L("  (追加)")
        }
        let cell = NSTextField(labelWithString: p.name + mark)
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showSelected()
    }

    // MARK: 読み書き

    private func reloadProfiles() {
        let name = selected >= 0 && selected < profiles.count ? profiles[selected].name : nil
        profiles = Profiles.store.profiles
        table.reloadData()
        let row = name.flatMap { n in profiles.firstIndex { $0.name == n } } ?? 0
        if !profiles.isEmpty { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        showSelected()
    }

    @objc private func externalChange() {
        // 自分の保存で起きた通知なら表示はそのまま
        if saveWork == nil && !savingNow { reloadProfiles() }
    }

    private func split(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
    }

    private func showSelected() {
        loading = true
        defer { loading = false }
        guard selected >= 0, selected < profiles.count else {
            form.isHidden = true
            return
        }
        form.isHidden = false
        let p = profiles[selected]
        let isBuiltIn = builtIns.contains { $0.name == p.name }
        nameField.stringValue = p.name
        nameField.isEditable = !isBuiltIn
        nameField.toolTip = isBuiltIn ? L("組み込みのファイルタイプは名前を変えられません") : nil
        extField.stringValue = p.extensions.joined(separator: " ")
        fileNamesField.stringValue = p.fileNames.joined(separator: " ")
        tabWidthField.stringValue = "\(p.tabWidth)"
        tabStepper.integerValue = p.tabWidth
        spacesCheck.state = p.useSpaces ? .on : .off
        lineCommentField.stringValue = p.lineComments.joined(separator: " ")
        blockCommentField.stringValue = p.blockComments.map { $0.joined(separator: " ") }.joined(separator: " , ")
        stringField.stringValue = p.stringDelimiters.joined(separator: " ")
        multilineField.stringValue = p.multilineStrings.joined(separator: " ")
        caseCheck.state = p.caseInsensitive ? .on : .off
        capTypeCheck.state = p.capitalizedIsType ? .on : .off
        tagCheck.state = p.markupTags ? .on : .off
        keywordsView.string = p.keywords.joined(separator: " ")
        typesView.string = p.types.joined(separator: " ")
        removeButton.isEnabled = !isBuiltIn
        if let b = builtIns.first(where: { $0.name == p.name }) {
            stateLabel.stringValue = b == p ? L("組み込みの設定のまま") : L("● 組み込みの設定から変更あり")
        } else {
            stateLabel.stringValue = L("自分で追加したファイルタイプ")
        }
    }

    /// 画面の内容を選択中のプロファイルに書き戻す
    private func commit() {
        guard !loading, selected >= 0, selected < profiles.count else { return }
        var p = profiles[selected]
        let newName = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if nameField.isEditable, !newName.isEmpty, !profiles.enumerated().contains(where: { $0.offset != selected && $0.element.name == newName }) {
            p.name = newName
        }
        p.extensions = split(extField.stringValue).map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".*")) }
        p.fileNames = split(fileNamesField.stringValue)
        p.tabWidth = max(1, min(16, Int(tabWidthField.stringValue) ?? p.tabWidth))
        p.useSpaces = spacesCheck.state == .on
        p.lineComments = split(lineCommentField.stringValue)
        p.blockComments = blockCommentField.stringValue.components(separatedBy: ",").compactMap {
            let pair = split($0)
            return pair.count == 2 ? pair : nil
        }
        p.stringDelimiters = split(stringField.stringValue)
        p.multilineStrings = split(multilineField.stringValue)
        p.caseInsensitive = caseCheck.state == .on
        p.capitalizedIsType = capTypeCheck.state == .on
        p.markupTags = tagCheck.state == .on
        p.keywords = split(keywordsView.string)
        p.types = split(typesView.string)
        guard p != profiles[selected] else { return }
        profiles[selected] = p
        table.reloadData(forRowIndexes: IndexSet(integer: selected), columnIndexes: IndexSet(integer: 0))
        if let b = builtIns.first(where: { $0.name == p.name }) {
            stateLabel.stringValue = b == p ? L("組み込みの設定のまま") : L("● 組み込みの設定から変更あり")
        }
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func flushSave() {
        if let w = saveWork { w.cancel(); save() }
    }

    private var savingNow = false

    /// 組み込みと違うもの・追加したものだけを profiles.json に書く
    private func save() {
        saveWork = nil
        let custom = profiles.filter { p in
            guard let b = builtIns.first(where: { $0.name == p.name }) else { return true }
            return b != p
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        do {
            let url = ProfileStore.userFileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(custom).write(to: url, options: .atomic)
            savingNow = true
            Profiles.reload()
            savingNow = false
        } catch {
            NSApp.presentError(error)
        }
    }

    // MARK: 操作

    func controlTextDidChange(_ obj: Notification) { commit() }
    func textDidChange(_ notification: Notification) { commit() }

    @objc private func fieldChanged(_ sender: Any?) { commit() }

    @objc private func stepperChanged(_ sender: NSStepper) {
        tabWidthField.stringValue = "\(sender.integerValue)"
        commit()
    }

    @objc private func addProfile(_ sender: Any?) {
        var name = L("新しいファイルタイプ")
        var n = 2
        while profiles.contains(where: { $0.name == name }) { name = L("新しいファイルタイプ {0}", n); n += 1 }
        guard let data = try? JSONSerialization.data(withJSONObject: ["name": name]),
              let p = try? JSONDecoder().decode(LanguageProfile.self, from: data) else { return }
        profiles.append(p)
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: profiles.count - 1), byExtendingSelection: false)
        table.scrollRowToVisible(profiles.count - 1)
        view.window?.makeFirstResponder(nameField)
        scheduleSave()
    }

    @objc private func removeProfile(_ sender: Any?) {
        guard selected >= 0, selected < profiles.count,
              !builtIns.contains(where: { $0.name == profiles[selected].name }) else { return }
        profiles.remove(at: selected)
        table.reloadData()
        if !profiles.isEmpty {
            table.selectRowIndexes(IndexSet(integer: min(selected < 0 ? 0 : selected, profiles.count - 1)), byExtendingSelection: false)
        }
        showSelected()
        scheduleSave()
    }

    @objc private func resetProfile(_ sender: Any?) {
        guard selected >= 0, selected < profiles.count,
              let b = builtIns.first(where: { $0.name == profiles[selected].name }) else { NSSound.beep(); return }
        profiles[selected] = b
        table.reloadData(forRowIndexes: IndexSet(integer: selected), columnIndexes: IndexSet(integer: 0))
        showSelected()
        scheduleSave()
    }

    @objc private func openJSON(_ sender: Any?) {
        flushSave()
        Profiles.openUserFile()
    }
}
