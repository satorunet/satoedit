import UIKit
import HinokiCore

/// AI アシスト: 頼みごとを書くか、定型の依頼 (校正・要約・読みやすく・翻訳・続きを書く) を選ぶ。
/// 答えは少しずつ届き、「置き換える」「挿入」「コピー」で文章に使える。
/// 範囲を選んでいればその部分、選んでいなければ文書全体が対象 (Mac 版と同じ)。
final class AIViewController: UIViewController, UITextFieldDelegate {
    enum ApplyKind { case replace, insert, none, ask }

    struct Preset {
        let titleKey: String
        let instructionKey: String
        let apply: ApplyKind
    }

    /// Mac 版 AIPanel.Action と同じ依頼文
    static let presets: [Preset] = [
        Preset(titleKey: "校正", instructionKey: "次の文章の誤字脱字・文法の誤り・表記ゆれを直してください。直した後の全文だけを出力し、説明は付けないでください。", apply: .replace),
        Preset(titleKey: "要約", instructionKey: "次の文章を要点がわかるように短く要約してください。", apply: .none),
        Preset(titleKey: "読みやすく", instructionKey: "次の文章を、意味を変えずに、より読みやすく自然な文章に書き直してください。書き直した文章だけを出力してください。", apply: .replace),
        Preset(titleKey: "翻訳 (日⇔英)", instructionKey: "次の文章が日本語なら英語に、それ以外なら日本語に翻訳してください。訳文だけを出力してください。", apply: .replace),
        Preset(titleKey: "続きを書く", instructionKey: "次の文章の続きを、同じ文体・言語で自然に書いてください。続きの部分だけを出力してください。", apply: .insert),
    ]

    /// 原稿用紙 (作文) のときの定型の依頼 (Mac 版 AIPanel.EssayAction と同じ)
    static let essayPresets: [Preset] = [
        Preset(titleKey: "題名・名前・本文の形に整える", instructionKey: "次の作文を、原稿用紙の作文の形 (1 行目に題名、2 行目に名前、3 行目は空けて、4 行目から本文) に整えてください。題名や名前が分からなければ、題名は内容に合うものを考え、名前の行は「名前」としてください。本文は原稿用紙の決まりに合わせ、内容は変えないでください。整えた後の全文だけを出力してください。", apply: .replace),
        Preset(titleKey: "誤字・表記を直す (作文)", instructionKey: "次の作文の誤字脱字・送りがな・句読点・表記ゆれを直してください。原稿用紙の作文の決まりに合わせ、内容や言い回しは変えないでください。直した後の全文だけを出力してください。", apply: .replace),
        Preset(titleKey: "読みやすく (作文)", instructionKey: "次の作文を、書いた人らしさと内容を変えずに、読みやすい作文に整えてください。整えた後の全文だけを出力してください。", apply: .replace),
        Preset(titleKey: "続きを書く (作文)", instructionKey: "次の作文の続きを、同じ文体・同じ書き手の気持ちで自然に書いてください。続きの部分だけを出力してください。", apply: .insert),
        Preset(titleKey: "400 字にまとめる", instructionKey: "次の作文を、原稿用紙 1 枚 (400 字) ほどにまとめてください。題名と名前の行は残し、まとめた後の全文だけを出力してください。", apply: .replace),
        Preset(titleKey: "800 字にふくらませる", instructionKey: "次の作文を、内容を変えずに、くわしい様子や気持ちを足して原稿用紙 2 枚 (800 字) ほどにしてください。題名と名前の行は残し、ふくらませた後の全文だけを出力してください。", apply: .replace),
        Preset(titleKey: "先生のように講評", instructionKey: "次の作文を読んで、先生のように講評してください。よいところを 3 つ、もっとよくなるところを 3 つ、書いた人に伝わるやさしい言葉で書いてください。", apply: .none),
        Preset(titleKey: "題名を考える", instructionKey: "次の作文に合う題名の案を 5 つ考えてください。", apply: .none),
    ]

    private struct Job {
        let from: Int
        let to: Int
        let original: String
        let kind: ApplyKind
    }

    private weak var editor: EditorViewController?
    private let selection: NSRange
    private let infoLabel = UILabel()
    private let notice = UIStackView()
    private let answerView = UITextView()
    private let input = UITextField()
    private let sendButton = UIButton(type: .system)
    private let replaceButton = UIButton(type: .system)
    private let insertButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private let usageLabel = UILabel()
    private var client: AIClient?
    private var job: Job?
    private var answer = ""
    private var running = false

    init(editor: EditorViewController, selection: NSRange) {
        self.editor = editor
        self.selection = selection
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var text: String { editor?.textView.text ?? "" }
    private var hasSelection: Bool { selection.length > 0 && NSMaxRange(selection) <= (text as NSString).length }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("AI アシスト")
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: L("閉じる"), style: .plain, target: self, action: #selector(close))
        let gear = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain, target: self, action: #selector(openSettings))
        gear.accessibilityLabel = L("AI の設定")
        navigationItem.rightBarButtonItem = gear

        infoLabel.font = .systemFont(ofSize: 13)
        infoLabel.textColor = .secondaryLabel
        infoLabel.numberOfLines = 0

        // まだ使えないときの案内
        let noticeLabel = UILabel()
        noticeLabel.text = L("まだ使えません。\nAI の設定をして「接続テスト」で確認してください。")
        noticeLabel.numberOfLines = 0
        noticeLabel.font = .systemFont(ofSize: 15)
        let setup = UIButton(type: .system)
        setup.setTitle(L("AI の設定"), for: .normal)
        setup.titleLabel?.font = .boldSystemFont(ofSize: 16)
        setup.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
        notice.axis = .vertical
        notice.spacing = 8
        notice.alignment = .leading
        notice.addArrangedSubview(noticeLabel)
        notice.addArrangedSubview(setup)
        notice.backgroundColor = .secondarySystemBackground
        notice.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        notice.isLayoutMarginsRelativeArrangement = true
        notice.layer.cornerRadius = 10

        // 定型の依頼
        let chips = UIStackView()
        chips.axis = .horizontal
        chips.spacing = 8
        let isEssay = editor?.isGenko ?? false
        for (i, p) in Self.presets.enumerated() {
            chips.addArrangedSubview(chip(L(p.titleKey), tag: i))
        }
        if isEssay {
            let essay = chip(L("作文") + " ▾", tag: -1)
            essay.menu = UIMenu(title: L("作文"), children: Self.essayPresets.map { p in
                UIAction(title: L(p.titleKey)) { [weak self] _ in self?.run(p) }
            })
            essay.showsMenuAsPrimaryAction = true
            chips.insertArrangedSubview(essay, at: 0)
        }
        let chipScroll = UIScrollView()
        chipScroll.showsHorizontalScrollIndicator = false
        chipScroll.addSubview(chips)
        chips.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chips.leadingAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.leadingAnchor),
            chips.trailingAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.trailingAnchor),
            chips.topAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.topAnchor),
            chips.bottomAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.bottomAnchor),
            chips.heightAnchor.constraint(equalTo: chipScroll.frameLayoutGuide.heightAnchor),
            chipScroll.heightAnchor.constraint(equalToConstant: 36),
        ])

        // 頼みごとの欄
        input.placeholder = L("AI に頼みたいことを書く")
        input.borderStyle = .roundedRect
        input.returnKeyType = .send
        input.delegate = self
        input.accessibilityIdentifier = "aiInput"
        sendButton.setTitle(L("送る"), for: .normal)
        sendButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        sendButton.addTarget(self, action: #selector(sendPressed), for: .touchUpInside)
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        let composer = UIStackView(arrangedSubviews: [input, sendButton])
        composer.spacing = 8

        // 答え
        answerView.isEditable = false
        answerView.font = .systemFont(ofSize: 16)
        answerView.backgroundColor = .secondarySystemBackground
        answerView.layer.cornerRadius = 10
        answerView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        answerView.accessibilityIdentifier = "aiAnswer"

        for (b, t, sym) in [(replaceButton, L("置き換える"), "arrow.left.arrow.right"), (insertButton, L("挿入"), "text.insert"),
                            (copyButton, L("コピー"), "doc.on.doc")] {
            b.setTitle(" " + t, for: .normal)
            b.setImage(UIImage(systemName: sym), for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        }
        replaceButton.addTarget(self, action: #selector(replacePressed), for: .touchUpInside)
        insertButton.addTarget(self, action: #selector(insertPressed), for: .touchUpInside)
        copyButton.addTarget(self, action: #selector(copyPressed), for: .touchUpInside)
        let actions = UIStackView(arrangedSubviews: [replaceButton, insertButton, copyButton])
        actions.distribution = .fillEqually
        usageLabel.font = .systemFont(ofSize: 11)
        usageLabel.textColor = .secondaryLabel
        usageLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [infoLabel, notice, chipScroll, composer, answerView, actions, usageLabel])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            answerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    private func chip(_ title: String, tag: Int) -> UIButton {
        var c = UIButton.Configuration.tinted()
        c.title = title
        c.cornerStyle = .capsule
        c.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        let b = UIButton(configuration: c)
        b.tag = tag
        if tag >= 0 { b.addTarget(self, action: #selector(chipPressed(_:)), for: .touchUpInside) }
        return b
    }

    private func refresh() {
        let ready = AISettings.isReady
        notice.isHidden = ready
        let p = AISettings.provider
        let model = AISettings.model(p)
        let target = hasSelection ? L("対象: 選んでいる {0} 文字", Genko.characterCount((text as NSString).substring(with: selection))) : L("対象: 文書全体")
        infoLabel.text = (ready ? p.label + (model.isEmpty ? "" : " ・ " + model) + "\n" : "") + target
        sendButton.setTitle(running ? L("中止") : L("送る"), for: .normal)
        let parts = AIAnswerParts.split(answer)
        let usable = !running && !answer.isEmpty && job != nil
        let content = parts.content ?? (parts.message.isEmpty ? nil : parts.message)
        replaceButton.isEnabled = usable && content != nil
        insertButton.isEnabled = usable && content != nil
        copyButton.isEnabled = !answer.isEmpty
    }

    @objc private func close() {
        client?.cancel()
        dismiss(animated: true)
    }

    @objc private func openSettings() {
        navigationController?.pushViewController(AISettingsViewController(), animated: true)
    }

    @objc private func chipPressed(_ b: UIButton) { run(Self.presets[b.tag]) }

    func textFieldShouldReturn(_ f: UITextField) -> Bool { sendPressed(); return true }

    @objc private func sendPressed() {
        if running { client?.cancel(); return }
        let t = (input.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        input.resignFirstResponder()
        run(Preset(titleKey: t, instructionKey: t, apply: .ask))
    }

    /// 依頼を送る (Mac 版 EditorWindowController の AI の送り方と同じ文面)
    func run(_ p: Preset) {
        guard AISettings.isReady else {
            refresh()
            return openSettings()
        }
        client?.cancel()
        let ns = text as NSString
        let target = hasSelection ? ns.substring(with: selection) : text
        if (target as NSString).length > 200_000 {
            return showMessage(L("文章が長すぎます"), L("{0} 文字まで。範囲を選んで分けて送ってください。", 200_000))
        }
        let j = Job(from: hasSelection ? selection.location : 0, to: hasSelection ? NSMaxRange(selection) : ns.length, original: target, kind: p.apply)
        job = j
        var system = L("あなたはテキストエディタ「さとるエディタ」に組み込まれた文章作成アシスタントです。依頼された結果だけを出力し、前置きや締めの言葉は書かないでください。元の文章がマークダウンを使っていない限り、マークダウンの装飾は使わないでください。")
        if editor?.isGenko == true {
            system += L("\n\nいま書いているのは、原稿用紙 (縦書き 400 字詰め) の作文です。作文の形と、原稿用紙の書き方の決まりを守ってください。\n作文の形: 1 行目に題名、2 行目に名前、3 行目は空けて、4 行目から本文。題名・名前の行には空白を入れない (題名を 3 マス下げる・名前を下に寄せるのは、アプリが自動で行う)。文書全体を書き直すときは、この形のまま出力する。\n本文の決まり: 段落の初めは全角スペース 1 つで 1 字下げる。会話は「」で囲み、行を改める (会話の行は字下げしない)。数字は漢数字で書く。英字・記号・半角の文字はできるだけ使わない (使うときは全角)。句読点やかっこも 1 字として数える。文体 (です・ます / だ・である) はもとの作文にそろえる。マークダウンや箇条書きは使わない。")
        }
        let fullText = p.apply == .ask && !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L("\n\n(文章を変える依頼なら、入れる内容には、変えていない部分も含めて対象の文章を省略せずに全部入れてください。)") : ""
        let format: String
        switch p.apply {
        case .replace, .insert:
            format = L("\n\n出力の形: はじめにユーザーへのひとこと (1〜2 文。何をしたか) を書き、そのあと文章に入れる内容だけを <result> と </result> で囲んで出力してください。")
        case .ask:
            format = L("\n\n出力の形: はじめにユーザーへのひとこと (1〜2 文) を書いてください。文章やコードを書く・直す・足す・消すなど、エディタの中身を変える依頼なら、そのあとエディタに入れる内容だけを <result> と </result> で囲んで出力してください (コードも ``` ではなく <result> で囲む)。エディタの中身を変えない質問への答えのときだけ、<result> を使わないでください。")
        case .none:
            format = ""
        }
        let instruction = L(p.instructionKey)
        let prompt = target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? instruction + format
            : instruction + fullText + format + L("\n\n対象の文章:\n<<<\n") + target + "\n>>>"
        answer = ""
        usageLabel.text = ""
        showAnswer(request: L(p.titleKey))
        running = true
        refresh()
        let c = AIClient()
        client = c
        c.send(system: system, prompt: prompt, onDelta: { [weak self] t in
            guard let self = self else { return }
            self.answer += t
            self.showAnswer(request: L(p.titleKey))
        }) { [weak self] err in
            guard let self = self else { return }
            self.running = false
            if let e = err {
                self.showAnswer(request: L(p.titleKey), error: e.localizedDescription)
            } else {
                let u = c.usage
                if u.inputTokens > 0 || u.outputTokens > 0 {
                    self.usageLabel.text = L("入力 {0} / 出力 {1} トークン", u.inputTokens, u.outputTokens) + (u.estimated ? " " + L("(見積もり)") : "")
                        + L(" ・ ") + AIPricing.format(AIPricing.cost(u, model: c.model))
                }
                self.showAnswer(request: L(p.titleKey))
            }
            if self.client === c { self.client = nil }
            self.refresh()
            SelfTest.aiFinished?()
        }
    }

    private func showAnswer(request: String, error: String? = nil) {
        let parts = AIAnswerParts.split(answer)
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "▶︎ " + request + "\n", attributes: [.font: UIFont.boldSystemFont(ofSize: 14), .foregroundColor: UIColor.systemBlue]))
        if !parts.message.isEmpty {
            out.append(NSAttributedString(string: parts.message + "\n", attributes: [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.secondaryLabel]))
        }
        if let c = parts.content {
            out.append(NSAttributedString(string: "\n" + c, attributes: [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.label]))
        }
        if answer.isEmpty && error == nil {
            out.append(NSAttributedString(string: L("答えを待っています…"), attributes: [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.tertiaryLabel]))
        }
        if let e = error {
            out.append(NSAttributedString(string: "\n" + e, attributes: [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.systemRed]))
        }
        answerView.attributedText = out
        let end = NSRange(location: max(0, out.length - 1), length: 1)
        answerView.scrollRangeToVisible(end)
    }

    /// 文章に入れるもの: <result> の中身。囲みがなければ答え全体
    private var content: String {
        let parts = AIAnswerParts.split(answer)
        return parts.content ?? parts.message
    }

    @objc private func replacePressed() {
        guard let j = job, let ed = editor else { return }
        guard let r = AIApply.locate(in: ed.textView.text, from: j.from, to: j.to, original: j.original) else {
            return showMessage(L("置き換える場所が分からなくなりました"), L("頼んだあとで文章が変わったためです。コピーして貼り付けてください。"))
        }
        ed.replace(range: r, with: content)
        toast(L("置き換えました"))
        job = nil
        refresh()
    }

    @objc private func insertPressed() {
        guard let j = job, let ed = editor else { return }
        let now = ed.textView.text ?? ""
        let to = AIApply.locate(in: now, from: j.from, to: j.to, original: j.original).map { NSMaxRange($0) } ?? (now as NSString).length
        ed.replace(range: NSRange(location: to, length: 0), with: AIApply.insertion(after: to, in: now, text: content))
        toast(L("挿入しました"))
        job = nil
        refresh()
    }

    @objc private func copyPressed() {
        UIPasteboard.general.string = content
        toast(L("コピーしました"))
    }
}

/// AI の設定: 接続先・API キー (キーチェーン)・モデル・接続テスト
final class AISettingsViewController: UITableViewController, UITextFieldDelegate {
    private var provider = AISettings.provider
    private let keyField = UITextField()
    private let modelField = UITextField()
    private let urlField = UITextField()
    private var status = ""
    private var statusOK = false
    private var models: [String] = []
    private var testing = false

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("AI の設定")
        for f in [keyField, modelField, urlField] {
            f.autocapitalizationType = .none
            f.autocorrectionType = .no
            f.clearButtonMode = .whileEditing
            f.delegate = self
        }
        keyField.isSecureTextEntry = true
        keyField.accessibilityIdentifier = "aiKey"
        modelField.accessibilityIdentifier = "aiModel"
        urlField.keyboardType = .URL
        loadFields()
    }

    private func loadFields() {
        keyField.text = ""
        keyField.placeholder = AISettings.hasAPIKey(provider) ? L("キーを保存済み (変えるときだけ入れる)") : L("キーを貼り付け")
        modelField.text = AISettings.model(provider)
        modelField.placeholder = AIModels.presets[provider.rawValue]?.fast ?? "model"
        urlField.text = AISettings.baseURL(provider)
        models = []
        status = AISettings.isVerified(provider) ? L("接続できました") : ""
        statusOK = AISettings.isVerified(provider)
        tableView.reloadData()
    }

    func textFieldShouldReturn(_ f: UITextField) -> Bool { f.resignFirstResponder(); return true }

    override func numberOfSections(in tableView: UITableView) -> Int { 4 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection s: Int) -> String? {
        [L("接続先"), L("API キー"), L("モデル"), nil][s]
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection s: Int) -> String? {
        switch s {
        case 0: return provider.guide
        case 1: return L("キーはこの iPhone / iPad のキーチェーンにだけ保存します。")
        case 3: return status.isEmpty ? nil : status
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection s: Int) -> Int {
        switch s {
        case 0: return AIProvider.allCases.count + (provider == .custom ? 1 : 0)
        case 1: return AISettings.hasAPIKey(provider) ? 3 : 2
        case 2: return 1 + quickModels.count + models.count
        default: return 1
        }
    }

    private var quickModels: [String] {
        guard let p = AIModels.presets[provider.rawValue] else { return [] }
        return [p.fast, p.quality]
    }

    private func fieldCell(_ f: UITextField, label: String? = nil) -> UITableViewCell {
        let c = UITableViewCell()
        f.translatesAutoresizingMaskIntoConstraints = false
        f.removeFromSuperview()
        c.contentView.addSubview(f)
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: c.contentView.layoutMarginsGuide.leadingAnchor),
            f.trailingAnchor.constraint(equalTo: c.contentView.layoutMarginsGuide.trailingAnchor),
            f.topAnchor.constraint(equalTo: c.contentView.topAnchor),
            f.bottomAnchor.constraint(equalTo: c.contentView.bottomAnchor),
            f.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        c.selectionStyle = .none
        return c
    }

    override func tableView(_ tableView: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        switch ip.section {
        case 0:
            if ip.row == AIProvider.allCases.count { return fieldCell(urlField) }
            let p = AIProvider.allCases[ip.row]
            let c = UITableViewCell()
            c.textLabel?.text = p.label
            c.textLabel?.numberOfLines = 0
            c.accessoryType = p == provider ? .checkmark : .none
            return c
        case 1:
            if ip.row == 0 { return fieldCell(keyField) }
            let c = UITableViewCell()
            if ip.row == 1 {
                c.textLabel?.text = L("キーを取りに行く")
                c.textLabel?.textColor = provider.keyPageURL == nil ? .secondaryLabel : .systemBlue
            } else {
                c.textLabel?.text = L("キーを消す")
                c.textLabel?.textColor = .systemRed
            }
            return c
        case 2:
            if ip.row == 0 { return fieldCell(modelField) }
            let i = ip.row - 1
            let m = i < quickModels.count ? quickModels[i] : models[i - quickModels.count]
            let c = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            c.textLabel?.text = m
            if i < quickModels.count { c.detailTextLabel?.text = i == 0 ? L("最安 & 最速") : L("内容重視") }
            c.accessoryType = modelField.text == m ? .checkmark : .none
            return c
        default:
            let c = UITableViewCell()
            c.textLabel?.text = testing ? L("接続テスト") + "…" : L("保存して接続テスト")
            c.textLabel?.textColor = .systemBlue
            c.textLabel?.textAlignment = .center
            c.textLabel?.font = .boldSystemFont(ofSize: 17)
            return c
        }
    }

    override func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection s: Int) {
        if s == 3, let f = view as? UITableViewHeaderFooterView {
            f.textLabel?.textColor = statusOK ? .systemGreen : .systemRed
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt ip: IndexPath) {
        tableView.deselectRow(at: ip, animated: true)
        switch ip.section {
        case 0 where ip.row < AIProvider.allCases.count:
            saveFields()
            provider = AIProvider.allCases[ip.row]
            AISettings.provider = provider
            loadFields()
        case 1 where ip.row == 1:
            if let u = provider.keyPageURL { UIApplication.shared.open(u) }
        case 1 where ip.row == 2:
            AISettings.deleteAPIKey(provider)
            loadFields()
        case 2 where ip.row > 0:
            let i = ip.row - 1
            modelField.text = i < quickModels.count ? quickModels[i] : models[i - quickModels.count]
            AISettings.setModel(modelField.text ?? "", provider)
            tableView.reloadSections([2], with: .none)
        case 3:
            test()
        default: break
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveFields()
    }

    private func saveFields() {
        AISettings.setAPIKey(keyField.text ?? "", provider)
        let m = (modelField.text ?? "").trimmingCharacters(in: .whitespaces)
        if !m.isEmpty { AISettings.setModel(m, provider) }
        if provider == .custom, let u = urlField.text?.trimmingCharacters(in: .whitespaces), !u.isEmpty, AISettings.baseURLOverrideForTesting[.custom] == nil {
            AISettings.setCustomBaseURL(u)
        }
    }

    private func test() {
        guard !testing else { return }
        view.endEditing(true)
        saveFields()
        loadFields()
        testing = true
        status = ""
        tableView.reloadData()
        let p = provider
        let c = AIClient(provider: p)
        var reply = ""
        c.send(system: L("短く答えてください。"), prompt: L("「接続できました」と日本語で一言だけ返してください。"), onDelta: { reply += $0 }) { [weak self] err in
            guard let self = self else { return }
            self.testing = false
            if let e = err {
                self.status = L("接続できませんでした") + "\n" + e.localizedDescription
                self.statusOK = false
            } else {
                AISettings.markVerified(p)
                self.status = L("接続できました") + (reply.isEmpty ? "" : "  「" + String(reply.prefix(40)) + "」")
                self.statusOK = true
            }
            self.tableView.reloadData()
        }
        // モデルの一覧も取る (選べるように)
        AIClient.listModels(provider: p, apiKey: AISettings.apiKey(p), baseURL: AISettings.baseURL(p)) { [weak self] r in
            guard let self = self, self.provider == p, case .success(let ids) = r else { return }
            self.models = ids.filter { !self.quickModels.contains($0) }.prefix(40).map { $0 }
            self.tableView.reloadSections([2], with: .none)
        }
    }
}
