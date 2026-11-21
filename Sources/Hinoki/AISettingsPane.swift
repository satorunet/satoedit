import AppKit

/// 「AI アシスタントを使う」をオンにする前の説明
enum AIConsent {
    static func confirmEnable() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "AI アシスタントをオンにする前に"
        alert.informativeText = ""
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 220))
        text.string = """
        ・ボタンを押したときだけ、文章が AI の会社に送られます。
        ・社外秘や個人情報は送らないでください。
        ・使った分だけ料金がかかります。
        ・AI の答えは間違うことがあります。
        ・暗号化した文書は送りません。
        """
        text.isEditable = false
        text.font = .systemFont(ofSize: 12)
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.drawsBackground = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 28, width: 460, height: 220))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        let check = NSButton(checkboxWithTitle: "わかりました", target: nil, action: nil)
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
        alert.addButton(withTitle: "オンにする")
        alert.addButton(withTitle: "やめる")
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
    let title = "AI アシスタント"
    let view = NSView()

    private let enabled = NSButton(checkboxWithTitle: "AI アシスタントを使う", target: nil, action: nil)
    private let providerPopup = NSPopUpButton()
    private let guideLabel = NSTextField(wrappingLabelWithString: "")
    private let keyField = NSSecureTextField()
    private let modelBox = NSComboBox()
    private let baseField = NSTextField()
    private let baseRow = NSStackView()
    private let keyPageButton = NSButton()
    private let resultLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var testClient: AIClient?
    private let linkField = NSTextField(labelWithString: "")
    private let priceLabel = NSTextField(wrappingLabelWithString: "")
    private let priceIn = NSTextField()
    private let priceOut = NSTextField()
    private let yenField = NSTextField()

    private var provider: AIProvider { AIProvider.allCases[max(0, providerPopup.indexOfSelectedItem)] }

    override init() {
        super.init()
        enabled.target = self
        enabled.action = #selector(enabledChanged(_:))
        AIProvider.allCases.forEach { providerPopup.addItem(withTitle: $0.label) }
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged(_:))
        guideLabel.font = .systemFont(ofSize: 12)
        guideLabel.textColor = .secondaryLabelColor
        guideLabel.preferredMaxLayoutWidth = 600
        keyField.placeholderString = "API キーを貼り付け"
        linkField.isSelectable = true
        linkField.allowsEditingTextAttributes = true // リンクをクリックで開けるように
        priceLabel.font = .systemFont(ofSize: 11)
        priceLabel.preferredMaxLayoutWidth = 600
        for f in [priceIn, priceOut] {
            f.placeholderString = "例: 2.5"
            f.widthAnchor.constraint(equalToConstant: 70).isActive = true
        }
        yenField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        keyField.widthAnchor.constraint(equalToConstant: 380).isActive = true
        modelBox.widthAnchor.constraint(equalToConstant: 300).isActive = true
        modelBox.completes = true
        modelBox.placeholderString = "「一覧を取得」で選ぶか、名前を入力"
        baseField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        baseField.placeholderString = "http://localhost:11434/v1"
        keyPageButton.title = "キーを取りに行く…"
        keyPageButton.bezelStyle = .rounded
        keyPageButton.target = self
        keyPageButton.action = #selector(openKeyPage(_:))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        resultLabel.font = .systemFont(ofSize: 12)
        resultLabel.preferredMaxLayoutWidth = 600

        baseRow.setViews([SettingsUI.label("アドレス"), baseField], in: .leading)
        let form = NSStackView(views: [
            SettingsUI.row([SettingsUI.label("使う AI"), providerPopup]),
            guideLabel,
            SettingsUI.row([keyPageButton]),
            linkField,
            baseRow,
            SettingsUI.row([SettingsUI.label("API キー"), keyField]),
            SettingsUI.row([SettingsUI.label("モデル"), modelBox,
                            SettingsUI.button("一覧を取得", self, #selector(fetchModels(_:)))]),
            SettingsUI.row([SettingsUI.button("保存", self, #selector(save(_:))),
                            SettingsUI.button("接続テスト", self, #selector(test(_:))), spinner]),
            resultLabel,
            priceLabel,
            SettingsUI.row([SettingsUI.label("自分で単価を入れる ($ / 100 万トークン)  入力"), priceIn, SettingsUI.label("出力"), priceOut]),
            SettingsUI.row([SettingsUI.label("1 ドル ="), yenField, SettingsUI.label("円で計算"),
                            SettingsUI.button("利用状況と料金を見る…", self, #selector(showUsage(_:)))]),
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        let box = SettingsUI.box("接続先", form, fillWidth: true)
        let note = SettingsUI.label("使い方: ⇧⌘A で開き、文章を選んでボタンを押す。", small: true)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        let stack = SettingsUI.fill(view, with: [box, note, spacer])
        box.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        load()
    }

    func willShow() { load() }

    private func load() {
        enabled.state = AISettings.isEnabled ? .on : .off
        providerPopup.selectItem(at: AIProvider.allCases.firstIndex(of: AISettings.provider) ?? 0)
        loadProvider()
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
        addLink("キーのページ", p.keyPageURL)
        addLink("料金のページ", AIPricing.pricingPage(p))
        linkField.attributedStringValue = links
        linkField.isHidden = links.length == 0
        let custom = AIPricing.custom(p)
        priceIn.stringValue = custom.map { String($0.input) } ?? ""
        priceOut.stringValue = custom.map { String($0.output) } ?? ""
        yenField.stringValue = String(Int(AIPricing.yenPerDollar))
        priceLabel.stringValue = AIPricing.describe(provider: p, model: AISettings.model(p))
        keyPageButton.isHidden = p.keyPageURL == nil
        baseRow.isHidden = p != .custom
        baseField.stringValue = AISettings.baseURL(.custom)
        keyField.stringValue = AISettings.apiKey(p)
        keyField.placeholderString = p == .custom ? "API キー (いらなければ空)" : "API キーを貼り付け"
        modelBox.removeAllItems()
        let m = AISettings.model(p)
        if !p.defaultModel.isEmpty { modelBox.addItem(withObjectValue: p.defaultModel) }
        modelBox.stringValue = m
        resultLabel.stringValue = ""
    }

    @objc private func enabledChanged(_ sender: NSButton) {
        if sender.state == .on && !AIConsent.confirmEnable() {
            sender.state = .off
            return
        }
        Prefs.set(sender.state == .on, "aiEnabled")
    }

    @objc private func providerChanged(_ sender: Any?) {
        AISettings.provider = provider
        loadProvider()
    }

    @objc private func showUsage(_ sender: Any?) { AIUsageWindowController.shared.show() }

    @objc private func openKeyPage(_ sender: Any?) {
        if let u = provider.keyPageURL { NSWorkspace.shared.open(u) }
    }

    @objc private func save(_ sender: Any?) {
        let p = provider
        AISettings.provider = p
        AISettings.setAPIKey(keyField.stringValue, p)
        AISettings.setModel(modelBox.stringValue.trimmingCharacters(in: .whitespaces), p)
        if p == .custom { AISettings.setCustomBaseURL(baseField.stringValue.trimmingCharacters(in: .whitespaces)) }
        AIPricing.setCustom(p, input: Double(priceIn.stringValue) ?? 0, output: Double(priceOut.stringValue) ?? 0)
        if let y = Double(yenField.stringValue), y > 0 { UserDefaults.standard.set(y, forKey: "aiYenPerDollar") }
        priceLabel.stringValue = AIPricing.describe(provider: p, model: AISettings.model(p))
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.stringValue = AISettings.isVerified(p) ? "保存しました" : "保存しました。「接続テスト」で確認すると使えるようになります。"
        NotificationCenter.default.post(name: .viewSettingsDidChange, object: nil)
    }

    @objc private func fetchModels(_ sender: Any?) {
        save(nil)
        let p = provider
        spinner.startAnimation(nil)
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.stringValue = "モデルの一覧を取得しています…"
        AIClient.listModels(provider: p, apiKey: AISettings.apiKey(p), baseURL: AISettings.baseURL(p)) { [weak self] r in
            guard let self = self else { return }
            self.spinner.stopAnimation(nil)
            switch r {
            case .success(let ids):
                let current = self.modelBox.stringValue
                self.modelBox.removeAllItems()
                self.modelBox.addItems(withObjectValues: ids)
                if current.isEmpty, let first = ids.first { self.modelBox.stringValue = first }
                self.resultLabel.stringValue = "▼ から選んで「保存」してください。"
                self.modelBox.window?.makeFirstResponder(self.modelBox)
            case .failure(let e):
                self.resultLabel.textColor = .systemRed
                self.resultLabel.stringValue = e.localizedDescription
            }
        }
    }

    @objc private func test(_ sender: Any?) {
        save(nil)
        spinner.startAnimation(nil)
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.stringValue = "\(provider.label) に問い合わせています…"
        var reply = ""
        let client = AIClient(provider: provider)
        testClient = client
        client.send(system: "短く答えてください。", prompt: "「接続できました」と日本語で一言だけ返してください。",
                    onDelta: { reply += $0 }) { [weak self] err in
            guard let self = self else { return }
            self.spinner.stopAnimation(nil)
            self.testClient = nil
            if let err = err {
                self.resultLabel.textColor = .systemRed
                self.resultLabel.stringValue = "✗ " + err.localizedDescription
            } else {
                self.resultLabel.textColor = .systemGreen
                self.resultLabel.stringValue = "✓ 接続できました。AI アシスタントが使えます (\(client.model)): " + reply.prefix(60)
                // 確認できた設定として覚える → エディタの AI 欄が使えるようになる
                AISettings.markVerified(client.provider)
                NotificationCenter.default.post(name: .viewSettingsDidChange, object: nil)
            }
        }
    }
}
