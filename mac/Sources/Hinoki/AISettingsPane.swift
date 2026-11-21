import AppKit
import HinokiCore

/// 「AI アシスタントを使う」をオンにする前の説明
enum AIConsent {
    static func confirmEnable() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("AI アシスタントをオンにする前に")
        alert.informativeText = ""
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 220))
        text.string = L("・ボタンを押したときだけ、文章が AI の会社に送られます。\n・社外秘や個人情報は送らないでください。\n・使った分だけ料金がかかります。\n・AI の答えは間違うことがあります。\n・暗号化した文書は送りません。")
        text.isEditable = false
        text.font = .systemFont(ofSize: 12)
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.drawsBackground = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 28, width: 460, height: 220))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        let check = NSButton(checkboxWithTitle: L("わかりました"), target: nil, action: nil)
        check.frame = NSRect(x: 0, y: 0, width: 460, height: 20)
        // 図 + 注意 + チェック
        text.frame.size.height = 110
        scroll.frame = NSRect(x: 0, y: 28, width: 460, height: 110)
        let diagram = EditorExtension.ai.diagram()
        diagram.translatesAutoresizingMaskIntoConstraints = true
        diagram.frame.origin = NSPoint(x: 0, y: 146)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 244))
        box.addSubview(diagram)
        box.addSubview(scroll)
        box.addSubview(check)
        alert.accessoryView = box
        alert.addButton(withTitle: L("オンにする"))
        alert.addButton(withTitle: L("やめる"))
        let ok = alert.buttons[0]
        ok.isEnabled = false
        let watcher = Watcher { ok.isEnabled = check.state == .on }
        check.target = watcher
        check.action = #selector(Watcher.changed(_:))
        let r = alert.runModal()
        _ = watcher
        return r == .alertFirstButtonReturn && check.state == .on
    }

    final class Watcher: NSObject {
        let f: () -> Void
        init(_ f: @escaping () -> Void) { self.f = f }
        @objc func changed(_ sender: Any?) { f() }
    }
}

/// 設定ウインドウの「AI アシスタント」タブ
final class AISettingsPane: NSObject, SettingsPane, NSComboBoxDelegate {
    let title = L("AI アシスタント")
    let view = NSView()

    /// いちばん上の「使える / まだ使えない」の表示
    private let banner = NSTextField(labelWithString: "")
    private let bannerBox = NSView()
    private let providerPopup = NSPopUpButton()
    private let guideLabel = NSTextField(wrappingLabelWithString: "")
    private let keyField = NSSecureTextField()
    private lazy var deleteKeyButton = SettingsUI.button(L("キーを消す"), self, #selector(deleteKey(_:)))
    private let modelBox = NSComboBox()
    private let baseField = NSTextField()
    private let baseRow = NSStackView()
    private let keyPageButton = NSButton()
    private let resultLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var testClient: AIClient?
    private let linkField = NSTextField(labelWithString: "")
    private let priceIn = NSTextField()
    private let priceOut = NSTextField()
    private let yenField = NSTextField()
    /// モデルのかんたん選択: 最安 & 最速 / 内容重視 / 自分で選ぶ
    private enum Choice: Int { case fast, quality, custom }
    private var choice = Choice.custom
    private var choiceRadios: [NSButton] = []
    private var choiceNotes: [NSTextField] = []
    private var choiceRows: [NSView] = []
    private var customRow = NSStackView()

    private var provider: AIProvider { AIProvider.allCases[max(0, providerPopup.indexOfSelectedItem)] }
    private var presets: (fast: String, quality: String)? { AIModels.presets[provider.rawValue] }

    override init() {
        super.init()
        AIProvider.allCases.forEach { providerPopup.addItem(withTitle: $0.label) }
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged(_:))
        guideLabel.font = .systemFont(ofSize: 12)
        guideLabel.textColor = .secondaryLabelColor
        guideLabel.preferredMaxLayoutWidth = 600
        keyField.placeholderString = L("API キーを貼り付け")
        linkField.isSelectable = true
        linkField.allowsEditingTextAttributes = true // リンクをクリックで開けるように
        for f in [priceIn, priceOut] {
            f.placeholderString = L("例: 2.5")
            f.widthAnchor.constraint(equalToConstant: 70).isActive = true
        }
        yenField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        keyField.widthAnchor.constraint(equalToConstant: 380).isActive = true
        modelBox.widthAnchor.constraint(equalToConstant: 300).isActive = true
        modelBox.completes = true
        modelBox.placeholderString = L("「一覧を取得」で選ぶか、名前を入力")
        modelBox.delegate = self
        baseField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        baseField.placeholderString = "http://localhost:11434/v1"
        keyPageButton.title = L("キーを取りに行く…")
        keyPageButton.bezelStyle = .rounded
        keyPageButton.target = self
        keyPageButton.action = #selector(openKeyPage(_:))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        resultLabel.font = .systemFont(ofSize: 12)
        resultLabel.preferredMaxLayoutWidth = 600

        // 使えるかどうかが一目で分かる帯
        banner.font = .boldSystemFont(ofSize: 13)
        banner.translatesAutoresizingMaskIntoConstraints = false
        bannerBox.wantsLayer = true
        bannerBox.layer?.cornerRadius = 6
        bannerBox.translatesAutoresizingMaskIntoConstraints = false
        bannerBox.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: bannerBox.leadingAnchor, constant: 12),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: bannerBox.trailingAnchor, constant: -12),
            banner.topAnchor.constraint(equalTo: bannerBox.topAnchor, constant: 7),
            banner.bottomAnchor.constraint(equalTo: bannerBox.bottomAnchor, constant: -7),
        ])

        // モデル: たくさんある中から選ばなくて済むように、まず 3 つから選ぶ
        var choiceViews: [NSView] = []
        for (i, label) in [L("最安 & 最速 (おすすめ)"), L("内容重視"), L("自分で選ぶ")].enumerated() {
            let radio = NSButton(radioButtonWithTitle: label, target: self, action: #selector(choicePicked(_:)))
            radio.tag = i
            let note = SettingsUI.label("", small: true)
            note.lineBreakMode = .byTruncatingTail
            choiceRadios.append(radio)
            choiceNotes.append(note)
            let row = NSStackView(views: [radio, note])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 1
            note.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20).isActive = true
            choiceRows.append(row)
            choiceViews.append(row)
        }
        customRow = SettingsUI.row([SettingsUI.label(L("モデル")), modelBox,
                                    SettingsUI.button(L("一覧を取得"), self, #selector(fetchModels(_:)))])
        let choices = NSStackView(views: choiceViews + [customRow])
        choices.orientation = .vertical
        choices.alignment = .leading
        choices.spacing = 5

        baseRow.setViews([SettingsUI.label(L("アドレス")), baseField], in: .leading)
        let form = NSStackView(views: [
            SettingsUI.row([SettingsUI.label(L("使う AI")), providerPopup]),
            guideLabel,
            SettingsUI.row([keyPageButton]),
            linkField,
            baseRow,
            SettingsUI.row([SettingsUI.label(L("API キー")), keyField, deleteKeyButton]),
            SettingsUI.label(L("モデル (かんたん選択)"), bold: true),
            choices,
            SettingsUI.row([SettingsUI.button(L("保存"), self, #selector(save(_:))),
                            SettingsUI.button(L("接続テスト"), self, #selector(test(_:))), spinner, NSView(),
                            SettingsUI.button(L("ローカルLLM簡単設定…"), self, #selector(openLocalAI(_:)))]),
            resultLabel,
            SettingsUI.row([SettingsUI.label(L("一覧表にないモデルの単価 ($ / 100 万トークン)  入力")), priceIn, SettingsUI.label(L("出力")), priceOut]),
            SettingsUI.row([SettingsUI.label(L("1 ドル =")), yenField, SettingsUI.label(L("円で計算")),
                            SettingsUI.button(L("利用状況と料金を見る…"), self, #selector(showUsage(_:)))]),
            SettingsUI.label(L("料金はアプリに入っている一覧表 ({0} に確認) による目安です。モデルを替えても、接続テストのやり直しは要りません。", AIModels.updated), small: true),
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        let box = SettingsUI.box(L("接続先"), form, fillWidth: true)
        let note = SettingsUI.label(L("使い方: ⇧⌘A で開き、文章を選んでボタンを押す。"), small: true)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        let stack = SettingsUI.fill(view, with: [bannerBox, box, note, spacer])
        box.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        bannerBox.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        load()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .viewSettingsDidChange, object: nil)
    }

    func willShow() { load() }

    @objc private func settingsChanged() { showBanner() }

    private func load() {
        providerPopup.selectItem(at: AIProvider.allCases.firstIndex(of: AISettings.provider) ?? 0)
        loadProvider()
    }

    private func showBanner() {
        let p = provider
        let ok = AISettings.isEnabled && AISettings.isVerified(p)
        if ok {
            banner.stringValue = "✓ " + L("AI 利用可能 (接続を確認済み)")
        } else if !AISettings.isEnabled {
            banner.stringValue = L("AI アシスタントはオフです。「追加機能」でオンにしてください。")
        } else {
            banner.stringValue = L("まだ使えません。キーを入れて「接続テスト」を押してください。")
        }
        banner.textColor = ok ? .white : .labelColor
        bannerBox.layer?.backgroundColor = (ok ? NSColor.systemGreen : NSColor.systemOrange.withAlphaComponent(0.25)).cgColor
    }

    /// いまのモデルが、かんたん選択のどれに当たるか
    private func pickChoice() {
        let model = modelBox.stringValue.trimmingCharacters(in: .whitespaces)
        guard let set = presets else { choice = .custom; return }
        if model.isEmpty {
            // まだ何も選んでいなければ、最安 & 最速を選んでおく
            choice = .fast
            modelBox.stringValue = set.fast
            AISettings.setModel(set.fast, provider)
        } else {
            choice = model == set.fast ? .fast : (model == set.quality ? .quality : .custom)
        }
    }

    private func renderChoices() {
        let p = provider
        let set = presets
        let titles = [L("最安 & 最速 (おすすめ)"), L("内容重視"), L("自分で選ぶ")]
        for (i, radio) in choiceRadios.enumerated() {
            radio.state = i == choice.rawValue ? .on : .off
            let name = i == 0 ? set?.fast : (i == 1 ? set?.quality : nil)
            radio.title = titles[i] + (name.map { " — " + $0 } ?? "")
        }
        // カスタム (手元の AI など) には、おすすめのモデルが無い
        choiceRows[0].isHidden = set == nil
        choiceRows[1].isHidden = set == nil
        choiceNotes[0].stringValue = set.map { AIPricing.priceText(provider: p, model: $0.fast) } ?? ""
        choiceNotes[1].stringValue = set.map { AIPricing.priceText(provider: p, model: $0.quality) } ?? ""
        let model = modelBox.stringValue.trimmingCharacters(in: .whitespaces)
        choiceNotes[2].stringValue = choice == .custom && !model.isEmpty
            ? AIPricing.priceText(provider: p, model: model) : L("一覧から好きなモデルを選びます。")
        customRow.isHidden = choice != .custom
    }

    private func loadProvider() {
        let p = provider
        guideLabel.stringValue = p.guide
        // ページの URL をクリックで開けるように
        let links = NSMutableAttributedString()
        func addLink(_ title: String, _ url: URL?) {
            guard let url = url else { return }
            if links.length > 0 { links.append(NSAttributedString(string: "    ")) }
            links.append(NSAttributedString(string: title + ": ", attributes: [.font: NSFont.systemFont(ofSize: 11)]))
            links.append(NSAttributedString(string: url.absoluteString, attributes: [
                .link: url, .font: NSFont.systemFont(ofSize: 11), .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]))
        }
        addLink(L("キーのページ"), p.keyPageURL)
        addLink(L("料金のページ"), AIPricing.pricingPage(p))
        linkField.attributedStringValue = links
        linkField.isHidden = links.length == 0
        let custom = AIPricing.custom(p)
        priceIn.stringValue = custom.map { String($0.input) } ?? ""
        priceOut.stringValue = custom.map { String($0.output) } ?? ""
        yenField.stringValue = String(Int(AIPricing.yenPerDollar))
        keyPageButton.isHidden = p.keyPageURL == nil
        baseRow.isHidden = p != .custom
        baseField.stringValue = AISettings.baseURL(.custom)
        // キーは画面に読み込まない (設定を開くたびに macOS の確認が出ないように)。保存済みなら、空のままで使える
        keyField.stringValue = ""
        let saved = AISettings.hasAPIKey(p)
        keyField.placeholderString = saved ? L("保存済み (変えるときだけ貼り付け)") : (p == .custom ? L("API キー (いらなければ空)") : L("API キーを貼り付け"))
        deleteKeyButton.isHidden = !saved
        modelBox.removeAllItems()
        if !p.defaultModel.isEmpty { modelBox.addItem(withObjectValue: p.defaultModel) }
        modelBox.stringValue = AISettings.model(p)
        pickChoice()
        renderChoices()
        resultLabel.stringValue = ""
        showBanner()
    }

    /// かんたん選択を押したら、すぐそのモデルに替える (接続テストのやり直しは要らない)
    @objc private func choicePicked(_ sender: NSButton) {
        choice = Choice(rawValue: sender.tag) ?? .custom
        if let set = presets, choice != .custom {
            let model = choice == .fast ? set.fast : set.quality
            modelBox.stringValue = model
            AISettings.provider = provider
            AISettings.setModel(model, provider)
            NotificationCenter.default.post(name: .viewSettingsDidChange, object: nil)
        }
        renderChoices()
        if choice == .custom { modelBox.window?.makeFirstResponder(modelBox) }
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSComboBox) === modelBox { renderChoices() }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        // 選んだ直後はまだ欄の文字が変わっていないので、少しあとで
        DispatchQueue.main.async { [weak self] in self?.renderChoices() }
    }

    @objc private func providerChanged(_ sender: Any?) {
        AISettings.provider = provider
        loadProvider()
        NotificationCenter.default.post(name: .viewSettingsDidChange, object: nil)
    }

    @objc private func showUsage(_ sender: Any?) { AIUsageWindowController.shared.show() }
    @objc private func openLocalAI(_ sender: Any?) { LocalAIWindowController.shared.show() }

    @objc private func openKeyPage(_ sender: Any?) {
        if let u = provider.keyPageURL { NSWorkspace.shared.open(u) }
    }

    @objc private func deleteKey(_ sender: Any?) {
        AISettings.deleteAPIKey(provider)
        loadProvider()
        resultLabel.stringValue = L("キーを消しました")
        NotificationCenter.default.post(name: .viewSettingsDidChange, object: nil)
    }

    @objc private func save(_ sender: Any?) {
        let p = provider
        AISettings.provider = p
        let typed = !keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        AISettings.setAPIKey(keyField.stringValue, p)
        if typed {
            keyField.stringValue = ""
            keyField.placeholderString = L("保存済み (変えるときだけ貼り付け)")
            deleteKeyButton.isHidden = false
        }
        AISettings.setModel(modelBox.stringValue.trimmingCharacters(in: .whitespaces), p)
        if p == .custom { AISettings.setCustomBaseURL(baseField.stringValue.trimmingCharacters(in: .whitespaces)) }
        AIPricing.setCustom(p, input: Double(priceIn.stringValue) ?? 0, output: Double(priceOut.stringValue) ?? 0)
        if let y = Double(yenField.stringValue), y > 0 { UserDefaults.standard.set(y, forKey: "aiYenPerDollar") }
        renderChoices()
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.stringValue = AISettings.isVerified(p) ? L("保存しました") : L("保存しました。「接続テスト」で確認すると使えるようになります。")
        NotificationCenter.default.post(name: .viewSettingsDidChange, object: nil)
    }

    @objc private func fetchModels(_ sender: Any?) {
        save(nil)
        let p = provider
        spinner.startAnimation(nil)
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.stringValue = L("モデルの一覧を取得しています…")
        AIClient.listModels(provider: p, apiKey: AISettings.apiKey(p), baseURL: AISettings.baseURL(p)) { [weak self] r in
            guard let self = self else { return }
            self.spinner.stopAnimation(nil)
            switch r {
            case .success(let ids):
                let current = self.modelBox.stringValue
                self.modelBox.removeAllItems()
                self.modelBox.addItems(withObjectValues: ids)
                if current.isEmpty, let first = ids.first { self.modelBox.stringValue = first }
                self.resultLabel.stringValue = L("▼ から選んで「保存」してください。")
                self.renderChoices()
                self.modelBox.window?.makeFirstResponder(self.modelBox)
            case .failure(let e):
                self.resultLabel.textColor = .systemRed
                self.resultLabel.stringValue = e.localizedDescription
            }
        }
    }

    @objc private func test(_ sender: Any?) {
        save(nil)
        guard !AISettings.model(provider).isEmpty else {
            resultLabel.textColor = .systemRed
            resultLabel.stringValue = L("モデルを選んでください")
            return
        }
        spinner.startAnimation(nil)
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.stringValue = L("{0} に問い合わせています…", provider.label)
        var reply = ""
        let client = AIClient(provider: provider)
        testClient = client
        client.send(system: L("短く答えてください。"), prompt: L("「接続できました」と日本語で一言だけ返してください。"),
                    onDelta: { reply += $0 }) { [weak self] err in
            guard let self = self else { return }
            self.spinner.stopAnimation(nil)
            self.testClient = nil
            if let err = err {
                self.resultLabel.textColor = .systemRed
                self.resultLabel.stringValue = "✗ " + err.localizedDescription
            } else {
                self.resultLabel.textColor = .systemGreen
                self.resultLabel.stringValue = L("✓ 接続できました。AI アシスタントが使えます ({0}): ", client.model) + reply.prefix(60)
                // 確認できた設定として覚える → エディタの AI 欄が使えるようになる
                AISettings.markVerified(client.provider)
                NotificationCenter.default.post(name: .viewSettingsDidChange, object: nil)
            }
            self.showBanner()
        }
    }
}
