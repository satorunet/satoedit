import AppKit
import HinokiCore

/// 後から足した機能 (拡張機能)。それぞれ使う・使わないを選べ、使わないものはメニュー・ツールバー・設定画面から消える。
enum EditorExtension: String, CaseIterable {
    case collab, server, ai, encryption, paper, folder, speech, publish, versions, library

    var prefKey: String {
        switch self {
        case .collab: return "collabEnabled"
        case .server: return "serverEnabled"
        case .ai: return "aiEnabled"
        case .encryption: return "encryptionEnabled"
        case .paper: return "paperEnabled"
        case .folder: return "folderTreeEnabled"
        case .speech: return "speechEnabled"
        case .publish: return "publishEnabled"
        case .versions: return VersionStore.prefKey   // 設定 > バックアップ の「版を残す」と同じ
        case .library: return "libraryEnabled"
        }
    }

    /// 画面に出す名前
    var title: String { L(titleKey) }

    /// 日本語の名前 (メニューの項目を覚えておく名前にも使う)
    var titleKey: String {
        switch self {
        case .collab: return "共同編集 (共有)"
        case .server: return "サーバ (SFTP / FTP)"
        case .ai: return "AI アシスタント"
        case .encryption: return "データ暗号化"
        case .paper: return "用紙切替 (原稿用紙・A4用紙)"
        case .folder: return "フォルダツリー"
        case .speech: return "読み上げ・音声入力"
        case .publish: return "リンクで公開共有"
        case .versions: return "版の履歴 (バージョン管理)"
        case .library: return "テキスト管理 (テキスト一覧、履歴)"
        }
    }

    var summary: String {
        switch self {
        case .collab: return L("同じ文書を、ほかの人と同時に編集します。チャットつき。")
        case .server: return L("サーバのファイルを開いて編集。保存するとサーバに反映。")
        case .ai: return L("AI に校正・要約・続きを書くなどを頼めます。")
        case .encryption: return L("文書を暗号化して保存。開けるのは鍵を持つ本人だけ。")
        case .paper: return L("原稿用紙 (縦書き) や A4 用紙の見た目で書けます。")
        case .folder: return L("フォルダの中身を左にツリーで表示。たくさんのファイルを行き来できます。")
        case .speech: return L("文章を声で読み上げます。マイクで話して、声で文字を入力できます。")
        case .publish: return L("テキストを docs.satoru.net に置いて、リンクで読めるようにします。公開・リンクだけ・パスワードを選べます。")
        case .versions: return L("保存のたびに、テキストごとの版を残します。前の版を見たり、違いを見たり、戻したりできます。")
        case .library: return L("左にフォルダとテキストの一覧 (履歴) を出し、サムネで見わたせます。書いたものは自動で保存され、テキストごとに版の履歴も残ります。")
        }
    }

    /// ツールバーのボタン
    var toolbarIDs: [String] {
        switch self {
        case .collab: return ["share"]
        case .server: return ["server"]
        case .ai: return ["ai"]
        case .encryption: return []
        case .paper: return ["paper"]
        case .folder: return ["folder"]
        case .speech: return ["speak", "dictate"]
        case .publish, .versions: return []
        case .library: return ["library", "libraryGrid"]
        }
    }

    /// メニューバーの見出しごと消すもの
    var topMenus: [String] {
        switch self {
        case .collab: return ["共有"]
        case .ai: return ["AI"]
        case .server: return ["サーバ"]
        case .encryption: return ["暗号化"]
        case .paper: return ["用紙"]
        case .folder: return []
        case .speech: return ["音声"]
        case .publish: return ["公開"]
        case .versions, .library: return []
        }
    }

    /// 個別に消すメニュー項目 (動作名)
    var menuActions: [String] {
        switch self {
        case .collab: return ["startShareHM:", "joinShareHM:", "toggleChatHM:", "stopShareHM:"]
        case .server: return ["openServersHM:", "toggleRemoteAutoUploadHM:", "toggleRemoteTreeHM:"]
        case .ai: return ["toggleAIHM:", "aiActionHM:", "openAISettingsHM:", "openAIUsageHM:", "openLocalAIHM:"]
        case .encryption: return ["encryptDocumentHM:", "decryptDocumentHM:", "toggleEncryptAlwaysHM:", "changeEncryptionMethodHM:",
                                  "changeEncryptionKeyHM:", "openEncryptionSettingsHM:", "openEncryptionPrefsHM:"]
        case .paper: return ["openPaperSettingsHM:", "setPaperModeHM:", "cyclePaperModeHM:", "toggleGenkoAssistHM:", "togglePaperAutoFormatHM:", "setParagraphAlignHM:"]
        case .folder: return ["toggleFolderTreeHM:", "openFolderHM:"]
        case .speech: return ["readAloudHM:", "stopReadingHM:", "toggleDictationHM:", "openSpeechSettingsHM:"]
        case .publish: return ["shareLinkHM:", "updatePublishedHM:", "publishSettingsHM:", "openPublishedHM:", "copyPublishedLinkHM:",
                               "unpublishCurrentHM:", "showSharedLinksHM:", "togglePrivacyCheckHM:", "openPublishPrefsHM:"]
        case .versions: return ["versionHistoryHM:"]
        case .library: return ["toggleTextLibraryHM:", "showLibraryGridHM:", "versionHistoryHM:", "openLibraryPrefsHM:"]
        }
    }

    /// 見出しで消すサブメニュー
    var subMenus: [String] {
        []
    }

    /// 画面とメニューに並べる順 (身近なものを上に、サーバなど設定が要るものを下に)
    /// (共同編集は、いまは使わないので一覧に出さない。中身は残してあるので、ここに .collab を戻せば出る)
    /// (フォルダツリーも、いまはテキスト一覧とぶつかるので出さない)
    /// (データ暗号化は、いちばん下。最初はオフ)
    /// (用紙切替は、最初からオン。切ることもできる)
    /// (版の履歴は、テキスト管理の中の機能。細かい入り切りは 設定 > バックアップ で)
    static let displayOrder: [EditorExtension] = [.ai, .paper, .library, .publish, .speech, .server, .encryption]
    /// 一覧に出さない (見えない) 機能。前にオンにしていてもオフにする
    /// 見せない機能 (メニュー・ツールバー・設定に出さず、いつもオフ)。
    /// フォルダツリーは、左のテキスト一覧 (フォルダと履歴) とぶつかるので、いったん見せない
    static let hidden: [EditorExtension] = [.collab, .folder]

    /// 標準機能 (切り替えられず、いつもオン)
    static let standard: [EditorExtension] = []

    var isOn: Bool { !Self.hidden.contains(self) && (Self.standard.contains(self) || UserDefaults.standard.bool(forKey: prefKey)) }

    /// オンにする前の説明 (なければそのままオン)
    func confirmEnable() -> Bool {
        switch self {
        case .collab: return CollabConsent.confirmEnable()
        case .ai: return AIConsent.confirmEnable()
        case .encryption:
            let a = NSAlert()
            a.messageText = L("データ暗号化をオンにします")
            a.accessoryView = diagram()
            a.informativeText = L("パスワードを忘れると、だれにも開けなくなります。")
            a.addButton(withTitle: L("オンにする"))
            a.addButton(withTitle: L("やめる"))
            return a.runModal() == .alertFirstButtonReturn
        case .server:
            let a = NSAlert()
            a.messageText = L("サーバ (SFTP / FTP) をオンにします")
            a.accessoryView = diagram()
            a.informativeText = L("保存するとすぐサーバに反映されます。本番サーバでは注意。")
            a.addButton(withTitle: L("オンにする"))
            a.addButton(withTitle: L("やめる"))
            return a.runModal() == .alertFirstButtonReturn
        case .paper:
            let a = NSAlert()
            a.messageText = L("用紙モードをオンにします")
            a.informativeText = L("メニューバーの「用紙」で切り替えます。")
            a.accessoryView = diagram()
            a.addButton(withTitle: L("オンにする"))
            a.addButton(withTitle: L("やめる"))
            return a.runModal() == .alertFirstButtonReturn
        case .speech:
            let a = NSAlert()
            a.messageText = L("読み上げ・音声入力をオンにします")
            a.informativeText = L("メニューバーの「音声」とツールバーのボタンで使います。\n音声入力では、声を Apple のサーバに送って文字にします。はじめて使うとき、マイクと音声認識の許可を聞かれます。")
            a.accessoryView = diagram()
            a.addButton(withTitle: L("オンにする"))
            a.addButton(withTitle: L("やめる"))
            return a.runModal() == .alertFirstButtonReturn
        case .folder:
            let a = NSAlert()
            a.messageText = L("フォルダツリーをオンにします")
            a.informativeText = L("「表示 > フォルダツリー」で出し入れ、「ファイル > フォルダを開く…」でフォルダを選びます。")
            a.accessoryView = diagram()
            a.addButton(withTitle: L("オンにする"))
            a.addButton(withTitle: L("やめる"))
            return a.runModal() == .alertFirstButtonReturn
        case .publish, .versions, .library:
            return true
        }
    }

    /// オン・オフを切り替える (オンにするときは説明を出す)。切り替えたら true
    @discardableResult
    func set(_ on: Bool) -> Bool {
        if on == isOn { return true }
        if Self.standard.contains(self) { return false } // 標準機能は切れない
        if on && !confirmEnable() { return false }
        UserDefaults.standard.set(on, forKey: prefKey)
        if !on && self == .server { ServerExplorerWindowController.closeIfOpen() }
        if !on && self == .encryption { UserDefaults.standard.set(false, forKey: "encryptAlways") }
        ExtensionUI.apply()
        NotificationCenter.default.post(name: .viewSettingsDidChange, object: nil)
        if on { reveal() }
        return true
    }

    /// オンにした直後に、その機能を画面に出す (オンにしただけでは何も変わって見えないのを防ぐ)。
    /// 共同編集と暗号化は、相手や文書を選んで始める操作なので自動では始めない (メニューとボタンだけ出る)
    private func reveal() {
        switch self {
        case .server:
            ServerExplorerWindowController.shared.showForSetup()
        case .ai, .paper:
            guard let w = NSApp.orderedWindows.first(where: { $0.windowController is EditorWindowController }),
                  let editor = w.windowController as? EditorWindowController else { return }
            if self == .ai { editor.revealAIPanel() } else { editor.applyPaperMode(.genko) }
            // 設定ウインドウから切り替えたときも見えるように、エディタをそのすぐ後ろへ持ってくる
            if let key = NSApp.keyWindow, key !== w { w.order(.below, relativeTo: key.windowNumber) }
        case .folder:
            // 左にツリーを出す。まだフォルダを選んでいなければ、続けて選んでもらう
            FolderTree.setVisible(true)
            if FolderTree.root == nil { FolderTree.chooseRoot() }
        case .collab, .encryption, .speech, .publish, .versions:
            break
        case .library:
            TextLibrary.setVisible(true)
        }
    }

    static func extensionFor(toolbarID id: String) -> EditorExtension? {
        allCases.first { $0.toolbarIDs.contains(id) }
    }
}

/// オン・オフをメニューとツールバーに反映する
enum ExtensionUI {
    static func hides(_ item: NSMenuItem, topLevel: Bool) -> Bool {
        for e in EditorExtension.allCases where !e.isOn {
            // 見出しは日本語の名前 (identifier) で見分ける
            let name = item.identifier?.rawValue ?? item.title
            if topLevel && e.topMenus.contains(name) { return true }
            if item.hasSubmenu && e.subMenus.contains(name) { return true }
            if let a = item.action, e.menuActions.contains(NSStringFromSelector(a)) { return true }
        }
        return false
    }

    static func apply() {
        MenuCustomizer.apply()
        // ツールバー: 同じ名前のツールバーは全ウインドウで連動するので 1 つ直せばよい
        guard let toolbar = NSApp.windows.compactMap({ $0.toolbar }).first(where: { $0.identifier == EditorToolbar.identifier }) else { return }
        for i in toolbar.items.indices.reversed() {
            let raw = toolbar.items[i].itemIdentifier.rawValue.replacingOccurrences(of: "satomaru.", with: "")
            if let e = EditorExtension.extensionFor(toolbarID: raw), !e.isOn { toolbar.removeItem(at: i) }
        }
        for e in EditorExtension.allCases where e.isOn {
            for id in e.toolbarIDs {
                let ident = NSToolbarItem.Identifier("satomaru.\(id)")
                guard !toolbar.items.contains(where: { $0.itemIdentifier == ident }) else { continue }
                // 右端の「色・フォント」の前あたりに入れる
                let idx = toolbar.items.firstIndex { $0.itemIdentifier == .flexibleSpace } ?? toolbar.items.count
                toolbar.insertItem(withItemIdentifier: ident, at: idx)
            }
        }
    }
}

extension EditorExtension {
    /// 一覧に出す絵
    var icon: String {
        switch self {
        case .collab: return "👥"
        case .server: return "🖥"
        case .ai: return "✨"
        case .encryption: return "🔒"
        case .paper: return "📜"
        case .folder: return "🗂"
        case .speech: return "🔊"
        case .publish: return "🔗"
        case .versions: return "🕘"
        case .library: return "🗂"
        }
    }

    /// 「詳細設定」ボタンを出すか (移る先があるか)
    var hasDetailSettings: Bool {
        switch self {
        case .ai, .encryption, .paper, .server, .speech, .versions, .library: return true
        case .collab, .folder, .publish: return false
        }
    }

    /// 細かい設定の画面へ移る
    func openDetailSettings() {
        switch self {
        case .ai: SettingsWindowController.shared.show(.ai)
        case .encryption: SettingsWindowController.shared.show(.encryption)
        case .paper: SettingsWindowController.shared.show(.paper)
        case .server: NSApp.sendAction(#selector(AppDelegate.openServersHM(_:)), to: nil, from: nil)
        case .speech: SettingsWindowController.shared.show(.speech)
        case .versions, .library: SettingsWindowController.shared.show(.backup)
        case .collab, .folder, .publish: break
        }
    }
}

/// 設定ウインドウの「暗号化」タブ (追加機能の「流出防止」がオンのときだけ出る)
final class EncryptionSettingsPane: NSObject, SettingsPane {
    let title = L("暗号化")
    let view = NSView()
    private let encryptAlways = NSButton(checkboxWithTitle: L("いつも暗号化して保存する"), target: nil, action: nil)
    private var kindRadios: [NSButton] = []

    override init() {
        super.init()
        encryptAlways.target = self
        encryptAlways.action = #selector(encryptAlwaysChanged(_:))
        let heading = SettingsUI.label(L("暗号化の方法 (暗号化するときに最初に選ばれているものを選べます。保存のときに変えることもできます)"), small: true)
        var rows: [NSView] = [heading]
        for (i, k) in PasswordPrompt.kindChoices.enumerated() {
            let radio = NSButton(radioButtonWithTitle: k.title, target: self, action: #selector(kindChosen(_:)))
            radio.tag = i
            kindRadios.append(radio)
            let row = NSStackView(views: [radio, SettingsUI.label(k.note, small: true)])
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .firstBaseline
            rows.append(row)
        }
        let kinds = NSStackView(views: rows)
        kinds.orientation = .vertical
        kinds.alignment = .leading
        kinds.spacing = 4
        let keyNote = SettingsUI.label(L("開いている文書の鍵の変更・暗号化の解除は、メニューの「暗号化」か、下のステータスバーの 🔒 から行えます。"), small: true)
        _ = SettingsUI.fill(view, with: [
            SettingsUI.box(L("保存"), encryptAlways),
            SettingsUI.box(L("暗号化の方法"), kinds),
            keyNote,
            NSView(),
        ])
        refresh()
    }

    func willShow() { refresh() }

    private func refresh() {
        encryptAlways.state = Prefs.bool("encryptAlways") ? .on : .off
        let chosen = PasswordPrompt.defaultKindIndex
        for (i, r) in kindRadios.enumerated() { r.state = i == chosen ? .on : .off }
    }

    /// ラジオボタンは 1 つずつ別の行に入れているので、選んだもの以外は refresh で外す
    @objc private func kindChosen(_ sender: NSButton) {
        PasswordPrompt.defaultKindIndex = sender.tag
        refresh()
    }

    @objc private func encryptAlwaysChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "encryptAlways")
    }
}

/// 設定ウインドウの「用紙モード」タブ (標準機能なので、いつも出す)
final class PaperSettingsPane: NSObject, SettingsPane {
    let title = L("用紙モード")
    let view = NSView()
    private let furigana = NSButton(checkboxWithTitle: L("原稿用紙の漢字に、自動でふりがなを付ける"), target: nil, action: nil)
    private let candidates = NSPopUpButton()
    private static let candidateChoices: [(id: String, label: String)] = [("outside", "原稿用紙のマス目の外 (字にかぶらない)"), ("beside", "書いている字の横")]

    override init() {
        super.init()
        furigana.target = self
        furigana.action = #selector(furiganaChanged(_:))
        let col = NSStackView(views: [furigana, SettingsUI.label(L("読みは Mac に入っている辞書で付けます。人名などは外れることがあります。印刷・PDF にも入ります。"), small: true)])
        Self.candidateChoices.forEach { candidates.addItem(withTitle: L($0.label)) }
        candidates.target = self
        candidates.action = #selector(candidatesChanged(_:))
        col.addArrangedSubview(SettingsUI.row([SettingsUI.label(L("予測変換の出る場所")), candidates]))
        col.addArrangedSubview(SettingsUI.note(L("日本語入力の予測変換 (打っている途中に出る候補) を出す場所です。出さないようにするには、Mac の「システム設定 > キーボード > 入力ソース > 日本語」で「推測候補表示」を切ります (ほかのアプリでも出なくなります)。")))
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 6
        // 用紙切替のボタン・メニューに出す候補
        let pick = NSStackView()
        pick.orientation = .vertical
        pick.alignment = .leading
        pick.spacing = 4
        for (i, c) in PaperCandidates.all.enumerated() {
            let b = NSButton(checkboxWithTitle: L(c.label), target: self, action: #selector(paperCandidateChanged(_:)))
            b.tag = i
            pick.addArrangedSubview(b)
            paperChecks.append(b)
        }
        pick.addArrangedSubview(SettingsUI.note(L("ツールバーの用紙切替のボタンで、チェックしたものを順に切り替えます。")))
        _ = SettingsUI.fill(view, with: [SettingsUI.box(L("切り替えの候補"), pick), SettingsUI.box(L("原稿用紙"), col), NSView()])
        willShow()
    }

    private var paperChecks: [NSButton] = []
    @objc private func paperCandidateChanged(_ sender: NSButton) {
        let id = PaperCandidates.all[sender.tag].id
        PaperCandidates.set(id, on: sender.state == .on)
        willShow()   // 全部外したときは標準エディタが残る
    }

    func willShow() {
        for b in paperChecks { b.state = PaperCandidates.isOn(PaperCandidates.all[b.tag].id) ? .on : .off }
        furigana.state = Prefs.bool("genkoFurigana") ? .on : .off
        let c = UserDefaults.standard.string(forKey: "genkoCandidates") ?? "outside"
        candidates.selectItem(at: Self.candidateChoices.firstIndex { $0.id == c } ?? 0)
    }

    @objc private func candidatesChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        guard i >= 0, i < Self.candidateChoices.count else { return }
        UserDefaults.standard.set(Self.candidateChoices[i].id, forKey: "genkoCandidates")
    }

    @objc private func furiganaChanged(_ sender: NSButton) {
        Prefs.set(sender.state == .on, "genkoFurigana")
    }
}

// MARK: - 図

/// 左から右へ流れる簡単な図: [絵 + 名前] → [絵 + 名前] → …
final class FlowDiagramView: NSView {
    struct Step { let icon: String; let title: String }
    struct Arrow { let label: String; let both: Bool }

    let steps: [Step]
    let arrows: [Arrow]

    init(steps: [Step], arrows: [Arrow], width: CGFloat = 460) {
        self.steps = steps
        self.arrows = arrows
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 96))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 96).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let n = CGFloat(steps.count)
        let boxW: CGFloat = 104, boxH: CGFloat = 80
        let area = bounds.insetBy(dx: 3, dy: 0) // 枠線が端で切れないように
        let gap = (area.width - boxW * n) / max(1, n - 1)
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        var boxes: [NSRect] = []
        for (i, s) in steps.enumerated() {
            let r = NSRect(x: area.minX + CGFloat(i) * (boxW + gap), y: 8, width: boxW, height: boxH)
            boxes.append(r)
            let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            accent.withAlphaComponent(0.10).setFill()
            path.fill()
            accent.setStroke()
            path.lineWidth = 1.5
            path.stroke()
            (s.icon as NSString).draw(in: NSRect(x: r.minX, y: r.minY + 8, width: r.width, height: 36),
                                      withAttributes: [.font: NSFont.systemFont(ofSize: 28), .paragraphStyle: center])
            (s.title as NSString).draw(in: NSRect(x: r.minX + 2, y: r.minY + 48, width: r.width - 4, height: 30),
                                       withAttributes: [.font: NSFont.boldSystemFont(ofSize: 11), .paragraphStyle: center,
                                                        .foregroundColor: NSColor.labelColor])
        }
        for (i, a) in arrows.enumerated() where i + 1 < boxes.count {
            let x0 = boxes[i].maxX + 6, x1 = boxes[i + 1].minX - 6
            let y = boxes[i].midY + 6
            accent.setStroke()
            accent.setFill()
            let line = NSBezierPath()
            line.lineWidth = 2
            line.move(to: NSPoint(x: x0, y: y))
            line.line(to: NSPoint(x: x1, y: y))
            line.stroke()
            func head(_ x: CGFloat, _ right: Bool) {
                let d: CGFloat = right ? -1 : 1
                let p = NSBezierPath()
                p.move(to: NSPoint(x: x, y: y))
                p.line(to: NSPoint(x: x + 8 * d, y: y - 5))
                p.line(to: NSPoint(x: x + 8 * d, y: y + 5))
                p.close()
                p.fill()
            }
            head(x1, true)
            if a.both { head(x0, false) }
            (a.label as NSString).draw(in: NSRect(x: x0 - 10, y: y - 30, width: x1 - x0 + 20, height: 28), withAttributes: [
                .font: NSFont.systemFont(ofSize: 10), .paragraphStyle: center, .foregroundColor: NSColor.secondaryLabelColor,
            ])
        }
    }
}

extension EditorExtension {
    /// しくみの図
    func diagram(width: CGFloat = 460) -> NSView {
        typealias S = FlowDiagramView.Step
        typealias A = FlowDiagramView.Arrow
        switch self {
        case .collab:
            return FlowDiagramView(steps: [S(icon: "💻", title: L("あなた")), S(icon: "💻", title: L("相手"))],
                                   arrows: [A(label: L("アドレスとコードで参加\n→ 一緒に編集・チャット"), both: true)], width: width)
        case .server:
            return FlowDiagramView(steps: [S(icon: "📝", title: MainMenu.appName), S(icon: "🖥", title: L("サーバ"))],
                                   arrows: [A(label: L("開く ←\n保存するとすぐ反映 →"), both: true)], width: width)
        case .ai:
            return FlowDiagramView(steps: [S(icon: "📝", title: L("文章を選ぶ")), S(icon: "✨", title: "AI"), S(icon: "✅", title: L("挿入・置き換え"))],
                                   arrows: [A(label: L("送る"), both: false), A(label: L("答え"), both: false)], width: width)
        case .encryption:
            return FlowDiagramView(steps: [S(icon: "📄", title: L("文書")), S(icon: "🔒", title: L("暗号化ファイル\n(だれも読めない)")), S(icon: "🔑", title: L("本人だけ開ける"))],
                                   arrows: [A(label: L("保存"), both: false), A(label: L("鍵で開く"), both: false)], width: width)
        case .folder:
            return FlowDiagramView(steps: [S(icon: "📁", title: L("フォルダを選ぶ")), S(icon: "🗂", title: L("左にツリー")), S(icon: "📝", title: L("クリックで開く"))],
                                   arrows: [A(label: L("表示"), both: false), A(label: L("タブで開く"), both: false)], width: width)
        case .speech:
            return FlowDiagramView(steps: [S(icon: "🎤", title: L("話す")), S(icon: "📝", title: L("文章")), S(icon: "🔊", title: L("読み上げ"))],
                                   arrows: [A(label: L("文字になる"), both: false), A(label: L("声で読む"), both: false)], width: width)
        case .paper:
            return FlowDiagramView(steps: [S(icon: "📄", title: L("ふつう")), S(icon: "📜", title: L("原稿用紙\n(縦書き)")), S(icon: "📃", title: L("A4 用紙"))],
                                   arrows: [A(label: L("切り替え"), both: true), A(label: L("切り替え"), both: true)], width: width)
        case .library:
            return FlowDiagramView(steps: [S(icon: "📝", title: L("書く")), S(icon: "💾", title: L("自動で保存")), S(icon: "🗂", title: L("一覧に並ぶ"))],
                                   arrows: [A(label: L("すぐ"), both: false), A(label: L("更新順"), both: false)], width: width)
        case .versions:
            return FlowDiagramView(steps: [S(icon: "💾", title: L("保存")), S(icon: "🕘", title: L("版が残る")), S(icon: "↩️", title: L("前の版に戻す"))],
                                   arrows: [A(label: L("そのたびに"), both: false), A(label: L("いつでも"), both: false)], width: width)
        case .publish:
            return FlowDiagramView(steps: [S(icon: "📝", title: L("テキスト")), S(icon: "🔗", title: "docs.satoru.net"), S(icon: "👀", title: L("リンクで読める"))],
                                   arrows: [A(label: L("公開"), both: false), A(label: L("URL を送る"), both: false)], width: width)
        }
    }
}

/// 上から並べるための (y が下向きの) 入れ物
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
