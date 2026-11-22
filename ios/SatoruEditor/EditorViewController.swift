import UIKit
import HinokiCore

/// 書く画面。表示は 3 つ: エディタ / 原稿用紙 (縦) / 原稿用紙 (横)。ファイルごとに覚える (Mac 版と同じ拡張属性)。
///
/// 原稿用紙のときは、上に原稿用紙、下に小さな書く欄 (エディタと同じ文字の面) を出す。
/// 書く欄は iPhone の日本語入力・選択・コピー・取り消しがそのまま使え、書いた字はすぐ原稿用紙のマスに入る。
/// マスをタップすると、書く欄のカーソルがそこへ動く。
final class EditorViewController: UIViewController, UITextViewDelegate {
    let doc: TextDocument
    let textView = EditorTextView(frame: .zero, textContainer: nil)
    let genko = GenkoPaperView()
    private let stack = UIStackView()
    private let statusLabel = UILabel()
    private let placeholder = UILabel()
    private let divider = UIView()
    /// 原稿用紙のときの、原稿用紙の欄の高さ (用紙 1 枚ぶん。残りを書く欄にする)
    private var genkoHeight: NSLayoutConstraint!
    private var saveWork: DispatchWorkItem?
    private var rubyWork: DispatchWorkItem?
    private var modeButton: UIBarButtonItem!
    /// ほかの端末 (Mac・iCloud) で書き換えられていないか、ときどき見る
    private var diskTimer: Timer?
    var pauseDiskCheckForTesting = false

    init(doc: TextDocument) {
        self.doc = doc
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// "editor" 以外は原稿用紙
    var isGenko: Bool { doc.mode == "genko" || doc.mode == "genkoH" }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never

        textView.text = doc.text
        textView.delegate = self
        textView.accessibilityIdentifier = "editor"
        textView.inputAccessoryView = makeAccessory()

        placeholder.text = L("ここに書く (原稿用紙に入ります)")
        placeholder.textColor = .placeholderText
        placeholder.font = .systemFont(ofSize: 15)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: textView.frameLayoutGuide.leadingAnchor, constant: 16),
            placeholder.topAnchor.constraint(equalTo: textView.frameLayoutGuide.topAnchor, constant: 12),
        ])

        genko.onTap = { [weak self] off in self?.tappedGenko(off) }

        divider.backgroundColor = .separator
        divider.heightAnchor.constraint(equalToConstant: 0.5).isActive = true

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.backgroundColor = .secondarySystemBackground
        statusLabel.heightAnchor.constraint(equalToConstant: 22).isActive = true

        stack.axis = .vertical
        stack.addArrangedSubview(genko)
        stack.addArrangedSubview(divider)
        stack.addArrangedSubview(textView)
        stack.addArrangedSubview(statusLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        genkoHeight = genko.heightAnchor.constraint(equalToConstant: 300)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])

        modeButton = UIBarButtonItem(image: nil, menu: nil)
        modeButton.accessibilityLabel = L("表示を切り替える")
        let ai = UIBarButtonItem(image: UIImage(systemName: "sparkles"), style: .plain, target: self, action: #selector(openAI))
        ai.accessibilityLabel = L("AI アシスト")
        let share = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), menu: nil)
        share.accessibilityLabel = L("リンクで公開共有")
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: nil)
        navigationItem.rightBarButtonItems = [more, share, ai, modeButton]
        // メニューは開くたびに作り直す (チェックの印をいまの設定に合わせる)
        share.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.shareMenuItems() ?? []) }])
        more.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.moreMenuItems() ?? []) }])
        modeButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.modeMenuItems() ?? []) }])

        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged), name: Prefs.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResign), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(checkDisk), name: UIApplication.didBecomeActiveNotification, object: nil)
        doc.onKeptOtherVersion = { [weak self] copy in
            DispatchQueue.main.async { self?.keptOtherVersion(copy) }
        }
        applyPrefs()
        applyMode()
        updateTitle()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if doc.text.isEmpty && !SelfTest.isRunning { textView.becomeFirstResponder() }
        diskTimer?.invalidate()
        diskTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkDisk() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        diskTimer?.invalidate()
        diskTimer = nil
    }

    // MARK: ほかの端末で書き換えられたとき

    @objc private func checkDisk() {
        guard !pauseDiskCheckForTesting, view.window != nil, UIApplication.shared.applicationState == .active,
              textView.markedTextRange == nil else { return }
        doc.text = textView.text
        guard doc.checkDisk() == .reloaded else { return }
        let sel = textView.selectedRange
        let len = (doc.text as NSString).length
        textView.text = doc.text
        textView.selectedRange = NSRange(location: min(sel.location, len), length: 0)
        textView.textDidChange()
        applyMode()
        toast(L("ほかの端末で書き換えられたので、読み直しました"))
        SelfTest.log("editor-reloaded")
    }

    private func keptOtherVersion(_ copy: URL) {
        SelfTest.log("kept-other \(copy.lastPathComponent)")
        showMessage(L("ほかの端末でも書き換えられていました"),
                    L("こちらで書いたものはそのまま残し、ほかの端末の版は「{0}」として保存しました。", copy.deletingPathExtension().lastPathComponent))
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveNow()
        doc.renameFromFirstLineIfNeeded()
    }

    @objc private func appWillResign() { saveNow() }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard isGenko else { return }
        // 原稿用紙は用紙 1 枚が入る高さまで。書く欄には少なくとも 3 行ぶん残す
        let avail = stack.bounds.height - 22 - 0.5
        let minStrip = max(96, (textView.font?.lineHeight ?? 20) * 3 + 30)
        let h = max(120, min(genko.fittedHeight(width: stack.bounds.width), avail - minStrip))
        if abs(genkoHeight.constant - h) > 0.5 { genkoHeight.constant = h }
    }

    private func updateTitle() {
        title = doc.url.deletingPathExtension().lastPathComponent
    }

    // MARK: 表示

    private func applyPrefs() {
        textView.font = Prefs.editorFont()
        textView.showsLineNumbers = Prefs.lineNumbers && !isGenko
        if isGenko { textView.font = Prefs.editorFont(size: min(Prefs.fontSize, 16)) }
        refreshRuby()
        genko.reload()
    }

    @objc private func prefsChanged() { applyPrefs() }

    func applyMode() {
        let g = isGenko
        genko.isHidden = !g
        divider.isHidden = !g
        genkoHeight.isActive = g
        view.setNeedsLayout()
        genko.horizontal = doc.mode == "genkoH"
        genko.text = textView.text
        textView.showsLineNumbers = Prefs.lineNumbers && !g
        textView.font = g ? Prefs.editorFont(size: min(Prefs.fontSize, 16)) : Prefs.editorFont()
        updatePlaceholder()
        modeButton.image = ModeIcon.image(mode: doc.mode, size: 22).withRenderingMode(.alwaysOriginal)
        refreshRuby()
        updateStatus()
        syncGenkoSelection()
        UserDefaults.standard.set(g ? (doc.mode == "genkoH" ? "genkoH" : "genko") : "editor", forKey: "lastPaperMode")
    }

    func setMode(_ m: String?) {
        guard m != doc.mode else { return }
        doc.mode = m
        applyMode()
    }

    private func modeMenuItems() -> [UIMenuElement] {
        [(nil as String?, L("エディタ")), ("genko", L("原稿用紙 (縦)")), ("genkoH", L("原稿用紙 (横)"))].map { m, name in
            UIAction(title: name, image: ModeIcon.image(mode: m, size: 22).withRenderingMode(.alwaysOriginal),
                     state: doc.mode == m ? .on : .off) { [weak self] _ in self?.setMode(m) }
        }
    }

    private func moreMenuItems() -> [UIMenuElement] {
        var view: [UIMenuElement] = []
        if !isGenko {
            view.append(UIAction(title: L("行番号"), image: UIImage(systemName: "list.number"), state: Prefs.lineNumbers ? .on : .off) { _ in
                Prefs.lineNumbers.toggle()
            })
        } else {
            view.append(UIAction(title: L("ふりがな (自動)"), image: UIImage(systemName: "character.textbox"), state: Prefs.furigana ? .on : .off) { _ in
                Prefs.furigana.toggle()
            })
            view.append(UIAction(title: L("作文の自動整形 (題名・名前・段落)"), image: UIImage(systemName: "text.alignright"),
                                 state: Prefs.genkoAutoFormat ? .on : .off) { _ in Prefs.genkoAutoFormat.toggle() })
        }
        let fonts = UIMenu(title: L("文字の形"), image: UIImage(systemName: "textformat"), children:
            [("gothic", L("ゴシック")), ("mincho", L("明朝")), ("mono", L("等幅"))].map { key, name in
                UIAction(title: name, state: Prefs.fontStyle == key ? .on : .off) { _ in Prefs.fontStyle = key }
            })
        let sizes = UIMenu(title: L("文字の大きさ"), image: UIImage(systemName: "textformat.size"), children:
            [13, 15, 17, 20, 24, 28].map { s in
                UIAction(title: "\(s)", state: Int(Prefs.fontSize) == s ? .on : .off) { _ in Prefs.fontSize = CGFloat(s) }
            })
        let file = UIMenu(options: .displayInline, children: [
            UIAction(title: L("名前を変える"), image: UIImage(systemName: "pencil")) { [weak self] _ in self?.renameFile() },
            UIAction(title: L("設定"), image: UIImage(systemName: "gearshape")) { [weak self] _ in self?.openSettings() },
        ])
        return [UIMenu(options: .displayInline, children: view + [fonts, sizes]), file]
    }

    private func updatePlaceholder() {
        placeholder.isHidden = !(isGenko && textView.text.isEmpty)
    }

    private func updateStatus() {
        let n = Genko.characterCount(textView.text)
        if isGenko {
            statusLabel.text = L("{0} 字 ・ {1} 枚", n, Genko.sheetCount(genko.columns))
        } else {
            statusLabel.text = L("{0} 字", n)
        }
    }

    // MARK: 文章が変わったとき

    func textViewDidChange(_ tv: UITextView) {
        doc.text = tv.text
        textView.textDidChange()
        updatePlaceholder()
        if isGenko {
            genko.text = tv.text
            syncGenkoSelection()
            refreshRuby()
        }
        updateStatus()
        scheduleSave()
    }

    func textViewDidChangeSelection(_ tv: UITextView) {
        if isGenko { syncGenkoSelection() } else if textView.showsLineNumbers { textView.setNeedsLayout() }
    }

    func textViewDidBeginEditing(_ textView: UITextView) { genko.showsCaret = true }
    func textViewDidEndEditing(_ textView: UITextView) { genko.showsCaret = false }

    private func syncGenkoSelection() {
        guard isGenko else { return }
        genko.selection = textView.selectedRange
        if let m = textView.markedTextRange {
            let loc = textView.offset(from: textView.beginningOfDocument, to: m.start)
            let len = textView.offset(from: m.start, to: m.end)
            genko.marked = NSRange(location: loc, length: len)
        } else {
            genko.marked = nil
        }
        if textView.isFirstResponder { genko.revealCaret(animated: false) }
    }

    private func tappedGenko(_ off: Int) {
        textView.selectedRange = NSRange(location: off, length: 0)
        if !textView.isFirstResponder { textView.becomeFirstResponder() }
        textView.scrollRangeToVisible(textView.selectedRange)
        syncGenkoSelection()
    }

    /// ふりがなを取り直す (入力が止まってから少し待ち、辞書引きは裏で)
    private func refreshRuby() {
        rubyWork?.cancel()
        guard isGenko, Prefs.furigana else {
            if !genko.ruby.isEmpty { genko.ruby = [] }
            return
        }
        let text = textView.text ?? ""
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                let list = Furigana.ruby(for: text)
                DispatchQueue.main.async {
                    guard let self = self, self.textView.text == text else { return }
                    self.genko.ruby = list
                }
            }
        }
        rubyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    // MARK: 保存

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
    }

    func saveNow() {
        saveWork?.cancel()
        doc.text = textView.text
        doc.save()
    }

    // MARK: 文章を書き換える (AI の答えなど)。取り消しできるように、文字の面を通して入れる

    func replace(range: NSRange, with s: String) {
        let ns = textView.text as NSString
        let r = NSRange(location: min(range.location, ns.length), length: max(0, min(range.length, ns.length - min(range.location, ns.length))))
        guard let start = textView.position(from: textView.beginningOfDocument, offset: r.location),
              let end = textView.position(from: start, offset: r.length),
              let tr = textView.textRange(from: start, to: end) else { return }
        textView.replace(tr, withText: s)
        textView.selectedRange = NSRange(location: r.location, length: (s as NSString).length)
        textViewDidChange(textView)
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    // MARK: キーボードの上の段

    private func makeAccessory() -> UIView {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        let undo = UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.backward"), style: .plain, target: self, action: #selector(undoPressed))
        undo.accessibilityLabel = L("もとに戻す")
        let redo = UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.forward"), style: .plain, target: self, action: #selector(redoPressed))
        redo.accessibilityLabel = L("やり直す")
        let ai = UIBarButtonItem(image: UIImage(systemName: "sparkles"), style: .plain, target: self, action: #selector(openAI))
        let done = UIBarButtonItem(title: L("完了"), style: .done, target: self, action: #selector(donePressed))
        bar.items = [undo, redo, .flexibleSpace(), ai, .flexibleSpace(), done]
        return bar
    }

    @objc private func undoPressed() { textView.undoManager?.undo(); textViewDidChange(textView) }
    @objc private func redoPressed() { textView.undoManager?.redo(); textViewDidChange(textView) }
    @objc private func donePressed() { textView.resignFirstResponder() }

    // MARK: ほかの画面

    @objc func openAI() {
        let sel = textView.selectedRange
        let vc = AIViewController(editor: self, selection: sel)
        let nav = UINavigationController(rootViewController: vc)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.largestUndimmedDetentIdentifier = .medium
        }
        textView.resignFirstResponder()
        present(nav, animated: true)
    }

    private func shareMenuItems() -> [UIMenuElement] {
        var items: [UIMenuElement] = [
            UIAction(title: L("リンクで公開共有") + "…", image: UIImage(systemName: "link")) { [weak self] _ in self?.startShare() },
        ]
        if let r = ShareStore.record(for: doc.url) {
            items.append(UIMenu(title: L("公開中"), options: .displayInline, children: [
                UIAction(title: L("公開中のページを更新（変更を反映）"), image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.updatePublished(r) },
                UIAction(title: L("ブラウザで開く"), image: UIImage(systemName: "safari")) { _ in
                    if let u = URL(string: r.url) { UIApplication.shared.open(u) }
                },
                UIAction(title: L("リンクをコピー"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                    UIPasteboard.general.string = r.url
                    self?.toast(L("コピーしました"))
                },
            ]))
        }
        items.append(UIAction(title: L("公開したリンク"), image: UIImage(systemName: "list.bullet")) { [weak self] _ in
            let nav = UINavigationController(rootViewController: SharedLinksViewController())
            self?.present(nav, animated: true)
        })
        items.append(UIAction(title: L("ほかのアプリで共有"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            guard let self = self else { return }
            self.saveNow()
            let vc = UIActivityViewController(activityItems: [self.doc.url], applicationActivities: nil)
            vc.popoverPresentationController?.barButtonItem = self.navigationItem.rightBarButtonItems?[1]
            self.present(vc, animated: true)
        })
        return items
    }

    func startShare() {
        saveNow()
        let text = textView.text ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return showMessage(L("テキストが空です")) }
        ShareFlow.confirmPrivacy(text, from: self, review: { [weak self] found in self?.review(found) }) { [weak self] in
            guard let self = self else { return }
            let vc = ShareFormViewController(text: text, mode: ShareStore.serverMode(self.doc.mode), file: self.doc.url)
            let nav = UINavigationController(rootViewController: vc)
            self.present(nav, animated: true)
        }
    }

    /// 個人情報らしきところを選んで見せる
    private func review(_ found: [PrivacyScan.Finding]) {
        guard let f = found.first else { return }
        textView.becomeFirstResponder()
        textView.selectedRange = f.range
        textView.scrollRangeToVisible(f.range)
        syncGenkoSelection()
    }

    private func updatePublished(_ r: ShareStore.Record) {
        saveNow()
        let mode = ShareStore.serverMode(doc.mode)
        ShareStore.update(r, text: textView.text, mode: mode) { [weak self] res in
            switch res {
            case .success: self?.showMessage(L("公開中のページを更新しました"), r.url)
            case .failure(let e): self?.showMessage(L("更新できませんでした"), e.message)
            }
        }
    }

    private func renameFile() {
        askText(title: L("名前を変える"), initial: doc.url.deletingPathExtension().lastPathComponent) { [weak self] name in
            guard let self = self else { return }
            self.saveNow()
            do {
                let u = try Library.rename(self.doc.url, to: name)
                self.doc.renamed(to: u)
                self.updateTitle()
            } catch {
                self.showMessage(error.localizedDescription)
            }
        }
    }

    private func openSettings() {
        present(UINavigationController(rootViewController: SettingsViewController()), animated: true)
    }
}
