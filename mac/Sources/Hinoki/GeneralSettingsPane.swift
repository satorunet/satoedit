import AppKit
import HinokiCore

/// 動作環境の設定値 (UserDefaults)
enum Prefs {
    static let defaults: [String: Any] = [
        "wrap": true, "invisibles": true, "lineNumbers": true, "columnRuler": true,
        "showEOF": true, "highlightCurrentLine": true,
        "autoIndent": true, "rememberCaret": true, "codeCompletion": true,
        "defaultEncoding": TextEncoding.utf8.rawValue, "defaultLineEnding": LineEnding.lf.rawValue,
        "backupOnSave": false, "trimTrailingOnSave": false, "lineCounting": "logical",
        "remoteAutoUpload": true, "collabEnabled": false, "encryptAlways": false, "aiEnabled": true,
        "serverEnabled": false, "encryptionEnabled": false, "paperEnabled": true, "publishEnabled": true, "libraryEnabled": true, "versionHistory": true, "folderTreeEnabled": false,
        "lineSpacing": 2.0, "genkoAutoIndent": true, "genkoFullWidth": false,
        "genkoAutoFormat": true, "a4AutoFormat": true, "linkURLs": true, "paperSavePDF": true,
        "genkoFurigana": true, "language": "auto", "hugeFileMB": 200, "hugePartMB": 64,
    ]

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    static var defaultEncoding: TextEncoding {
        TextEncoding(rawValue: UserDefaults.standard.string(forKey: "defaultEncoding") ?? "") ?? .utf8
    }

    static var defaultLineEnding: LineEnding {
        LineEnding(rawValue: UserDefaults.standard.string(forKey: "defaultLineEnding") ?? "") ?? .lf
    }

    static func set(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        NotificationCenter.default.post(name: .viewSettingsDidChange, object: nil)
    }
}

/// 設定ウインドウの「動作環境」タブ
final class GeneralSettingsPane: NSObject, SettingsPane {
    let title = L("動作環境")
    let view = NSView()

    private var checks: [(NSButton, String)] = []
    private let countingPopup = NSPopUpButton()
    private let spacingPopup = NSPopUpButton()
    private static let spacings: [Double] = [0, 1, 2, 3, 4, 6, 8]
    private let encodingPopup = NSPopUpButton()
    private let lineEndingPopup = NSPopUpButton()
    private let languagePopup = NSPopUpButton()
    /// 起動したときの白紙の表示 ("last" = 前回と同じ / "genko" / "normal" / "a4")
    private let startModePopup = NSPopUpButton()
    static let startModes: [(id: String, label: String)] = [("last", "前回と同じ"), ("genko", "原稿用紙"), ("normal", "エディタ (通常)"), ("a4", "A4 用紙")]

    override init() {
        super.init()
        Self.startModes.forEach { startModePopup.addItem(withTitle: L($0.label)) }
        startModePopup.target = self
        startModePopup.action = #selector(startModeChanged(_:))
        countingPopup.addItems(withTitles: [L("エディタ的 (改行ごとに 1 行)"), L("ワープロ的 (折り返しも 1 行)")])
        spacingPopup.addItems(withTitles: Self.spacings.map { $0 == 0 ? L("なし") : "\(Int($0)) pt" + ($0 == 2 ? L(" (標準)") : "") })
        spacingPopup.target = self
        spacingPopup.action = #selector(spacingChanged(_:))
        countingPopup.target = self
        countingPopup.action = #selector(countingChanged(_:))
        TextEncoding.allCases.forEach { encodingPopup.addItem(withTitle: $0.displayName) }
        encodingPopup.target = self
        encodingPopup.action = #selector(encodingChanged(_:))
        LineEnding.allCases.forEach { lineEndingPopup.addItem(withTitle: $0.displayName) }
        lineEndingPopup.target = self
        lineEndingPopup.action = #selector(lineEndingChanged(_:))

        AppLanguage.choices.forEach { languagePopup.addItem(withTitle: L($0.label)) }
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged(_:))

        let display = box(L("表示"), [
            SettingsUI.row([SettingsUI.label(L("起動したときの表示")), startModePopup]),
            SettingsUI.label(L("アプリを開いたときの白紙を、どの表示で始めるか。「前回と同じ」は、最後に使っていた表示で始めます。"), small: true),
            check(L("折り返して表示する"), "wrap"),
            check(L("改行・タブ・空白 (全角・半角) の記号を表示する"), "invisibles"),
            check(L("[EOF] を表示する"), "showEOF"),
            check(L("行番号を表示する"), "lineNumbers"),
            check(L("桁ルーラーを表示する"), "columnRuler"),
            check(L("カーソル行に色を付ける"), "highlightCurrentLine"),
            check(L("URL・メールアドレスをリンクにする (⌘ クリックで開く)"), "linkURLs"),
            SettingsUI.row([SettingsUI.label(L("行の数え方")), countingPopup]),
            SettingsUI.row([SettingsUI.label(L("行間")), spacingPopup]),
            SettingsUI.row([SettingsUI.label(L("表示の言語 (Language)")), languagePopup,
                            SettingsUI.label(L("変えたあと、起動し直すと切り替わります。"), small: true)]),
        ])
        let edit = box(L("編集"), [
            check(L("改行したとき前の行のインデントを引き継ぐ (自動インデント)"), "autoIndent"),
            check(L("ファイルを開いたとき、前回のカーソル位置に戻す"), "rememberCaret"),
            check(L("プログラムを書くとき、入力中に候補と関数の引数を出す (入力補完)"), "codeCompletion"),
            SettingsUI.label(L("候補は ↑↓ で選び、Enter か Tab で入れます。Esc で閉じます。⌃Space か ⌥Esc でいつでも出せます。"), small: true),
            SettingsUI.label(L("タブ幅は「ファイルタイプ別の設定」で。"), small: true),
        ])
        let file = box(L("ファイル"), [
            SettingsUI.row([SettingsUI.label(L("新規ファイルの文字コード")), encodingPopup]),
            SettingsUI.row([SettingsUI.label(L("新規ファイルの改行コード")), lineEndingPopup]),
            check(L("上書き保存の前にバックアップ (ファイル名.bak) を作る"), "backupOnSave"),
            check(L("保存するとき行末の空白を削除する"), "trimTrailingOnSave"),
        ])
        let share = box(L("追加機能"), [
            SettingsUI.label(L("共同編集・AI などは「追加機能」でオン・オフ。"), small: true),
        ])
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        for b in [display, edit, file, share] { b.setContentHuggingPriority(.defaultHigh, for: .vertical) }
        let stack = SettingsUI.fill(view, with: [display, edit, file, share, spacer])
        for b in [display, edit, file, share] {
            b.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        refresh()
        // メニューから切り替えたときも表示を合わせる
        NotificationCenter.default.addObserver(self, selector: #selector(externalChange),
                                               name: .viewSettingsDidChange, object: nil)
    }

    @objc private func externalChange() { refresh() }

    @objc private func startModeChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        guard i >= 0, i < Self.startModes.count else { return }
        UserDefaults.standard.set(Self.startModes[i].id, forKey: "startPaperMode")
    }

    func willShow() { refresh() }

    private func check(_ title: String, _ key: String) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(checkChanged(_:)))
        checks.append((b, key))
        return b
    }

    private func box(_ title: String, _ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return SettingsUI.box(title, stack)
    }

    private func refresh() {
        for (b, key) in checks { b.state = Prefs.bool(key) ? .on : .off }
        let start = UserDefaults.standard.string(forKey: "startPaperMode") ?? "normal"
        startModePopup.selectItem(at: Self.startModes.firstIndex { $0.id == start } ?? 0)
        countingPopup.selectItem(at: UserDefaults.standard.string(forKey: "lineCounting") == "visual" ? 1 : 0)
        let sp = UserDefaults.standard.double(forKey: "lineSpacing")
        spacingPopup.selectItem(at: Self.spacings.firstIndex(where: { abs($0 - sp) < 0.01 }) ?? 2)
        encodingPopup.selectItem(at: TextEncoding.allCases.firstIndex(of: Prefs.defaultEncoding) ?? 0)
        lineEndingPopup.selectItem(at: LineEnding.allCases.firstIndex(of: Prefs.defaultLineEnding) ?? 0)
        languagePopup.selectItem(at: AppLanguage.choices.firstIndex { $0.id == AppLanguage.setting } ?? 0)
    }

    @objc private func checkChanged(_ sender: NSButton) {
        guard let key = checks.first(where: { $0.0 === sender })?.1 else { return }
        if key == "collabEnabled" && sender.state == .on && !CollabConsent.confirmEnable() {
            sender.state = .off
            return
        }
        Prefs.set(sender.state == .on, key)
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        AppLanguage.change(to: AppLanguage.choices[max(0, sender.indexOfSelectedItem)].id)
        refresh()
    }

    @objc private func spacingChanged(_ sender: NSPopUpButton) {
        Prefs.set(Self.spacings[max(0, sender.indexOfSelectedItem)], "lineSpacing")
    }

    @objc private func countingChanged(_ sender: NSPopUpButton) {
        Prefs.set(sender.indexOfSelectedItem == 1 ? "visual" : "logical", "lineCounting")
    }

    @objc private func encodingChanged(_ sender: NSPopUpButton) {
        Prefs.set(TextEncoding.allCases[sender.indexOfSelectedItem].rawValue, "defaultEncoding")
    }

    @objc private func lineEndingChanged(_ sender: NSPopUpButton) {
        Prefs.set(LineEnding.allCases[sender.indexOfSelectedItem].rawValue, "defaultLineEnding")
    }
}
