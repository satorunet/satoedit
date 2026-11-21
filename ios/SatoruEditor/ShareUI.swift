import UIKit
import HinokiCore

enum ShareFlow {
    /// 公開する前に、電話番号・住所・パスワードなどが入っていないかを手元で点検する (どこにも送らない。Mac 版と同じ)
    static func confirmPrivacy(_ text: String, from vc: UIViewController, review: @escaping ([PrivacyScan.Finding]) -> Void,
                               proceed: @escaping () -> Void) {
        if Prefs.privacyCheckOff { return proceed() }
        let found = PrivacyScan.scan(text)
        guard !found.isEmpty else { return proceed() }
        let lines = found.prefix(8).map { "・" + L($0.kind) + "  " + $0.sample }.joined(separator: "\n")
        let a = UIAlertController(title: L("個人情報が入っているかもしれません"),
                                  message: lines + "\n\n" + L("公開すると、リンクを知った人が読めるようになります。このまま公開してよいですか？"),
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("やめて見直す"), style: .cancel) { _ in review(found) })
        a.addAction(UIAlertAction(title: L("このまま公開する"), style: .destructive) { _ in proceed() })
        a.addAction(UIAlertAction(title: L("次からこの確認を出さない"), style: .default) { _ in
            Prefs.privacyCheckOff = true
            proceed()
        })
        vc.present(a, animated: true)
    }
}

/// 公開の画面: 題名・公開のしかた・パスワード・期限・変更履歴
final class ShareFormViewController: UITableViewController, UITextFieldDelegate {
    private let text: String
    private let mode: String
    private let file: URL?
    private var form = ShareStore.Form()
    private let titleField = UITextField()
    private let passwordField = UITextField()
    private static let kinds: [(String, String)] = [("public", "公開 (だれでも読める・検索にも出る)"), ("unlisted", "リンクを知っている人だけ"),
                                                   ("password", "パスワードを知っている人だけ")]
    private static let dayChoices: [(Int, String)] = [(1, "1 日"), (7, "7 日"), (30, "30 日"), (365, "1 年"), (0, "期限なし")]
    private var busy = false
    /// 動作確認用: 公開できたときに呼ぶ
    static var onPublishedForTesting: ((ShareStore.Record) -> Void)?
    var titleForTesting: String {
        get { titleField.text ?? "" }
        set { titleField.text = newValue }
    }

    init(text: String, mode: String, file: URL?) {
        self.text = text
        self.mode = mode
        self.file = file
        super.init(style: .insetGrouped)
        let d = UserDefaults.standard
        form.visibility = d.string(forKey: "shareVisibility") ?? "unlisted"
        form.days = d.object(forKey: "shareDays") as? Int ?? 30
        form.keepHistory = d.object(forKey: "shareKeepHistory") as? Bool ?? true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("リンクで公開共有")
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: L("キャンセル"), style: .plain, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("公開する"), style: .done, target: self, action: #selector(publish))
        titleField.placeholder = L("題名 (なくてもかまいません)")
        titleField.clearButtonMode = .whileEditing
        titleField.returnKeyType = .done
        titleField.delegate = self
        passwordField.placeholder = L("パスワード (4 文字以上)")
        passwordField.isSecureTextEntry = true
        passwordField.delegate = self
    }

    func textFieldShouldReturn(_ f: UITextField) -> Bool { f.resignFirstResponder(); return true }

    @objc private func cancel() { dismiss(animated: true) }

    override func numberOfSections(in tableView: UITableView) -> Int { 4 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        [L("題名"), L("公開のしかた"), L("公開の期限"), nil][section]
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? L("文章をインターネット上に公開して URL を発行します。")
            : section == 3 ? L("公開をやめるには「公開したリンク」から。") : nil
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 1
        case 1: return Self.kinds.count + (form.visibility == "password" ? 1 : 0)
        case 2: return Self.dayChoices.count
        default: return 1
        }
    }

    private func fieldCell(_ f: UITextField) -> UITableViewCell {
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
        case 0: return fieldCell(titleField)
        case 1:
            if ip.row == Self.kinds.count { return fieldCell(passwordField) }
            let c = UITableViewCell()
            c.textLabel?.text = L(Self.kinds[ip.row].1)
            c.textLabel?.numberOfLines = 0
            c.accessoryType = form.visibility == Self.kinds[ip.row].0 ? .checkmark : .none
            return c
        case 2:
            let c = UITableViewCell()
            c.textLabel?.text = L(Self.dayChoices[ip.row].1)
            c.accessoryType = form.days == Self.dayChoices[ip.row].0 ? .checkmark : .none
            return c
        default:
            let c = UITableViewCell()
            c.textLabel?.text = L("変更履歴を残す (更新したとき、前の内容もページから見られる)")
            c.textLabel?.numberOfLines = 0
            let sw = UISwitch()
            sw.isOn = form.keepHistory
            sw.addTarget(self, action: #selector(historyChanged(_:)), for: .valueChanged)
            c.accessoryView = sw
            c.selectionStyle = .none
            return c
        }
    }

    @objc private func historyChanged(_ sw: UISwitch) {
        form.keepHistory = sw.isOn
        UserDefaults.standard.set(sw.isOn, forKey: "shareKeepHistory")
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt ip: IndexPath) {
        tableView.deselectRow(at: ip, animated: true)
        if ip.section == 1, ip.row < Self.kinds.count {
            form.visibility = Self.kinds[ip.row].0
            UserDefaults.standard.set(form.visibility, forKey: "shareVisibility")
            tableView.reloadSections([1], with: .automatic)
            if form.visibility == "password" { DispatchQueue.main.async { self.passwordField.becomeFirstResponder() } }
        } else if ip.section == 2 {
            form.days = Self.dayChoices[ip.row].0
            UserDefaults.standard.set(form.days, forKey: "shareDays")
            tableView.reloadSections([2], with: .none)
        }
    }

    @objc func publish() {
        guard !busy else { return }
        view.endEditing(true)
        form.title = titleField.text ?? ""
        form.password = passwordField.text ?? ""
        if form.visibility == "password" && form.password.count < 4 {
            return showMessage(L("パスワードは 4 文字以上にしてください"))
        }
        busy = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        navigationItem.titleView = spinner
        ShareStore.upload(text: text, mode: mode, form: form, file: file) { [weak self] res in
            guard let self = self else { return }
            self.busy = false
            self.navigationItem.titleView = nil
            self.navigationItem.rightBarButtonItem?.isEnabled = true
            switch res {
            case .failure(let e):
                self.showMessage(L("公開できませんでした"), e.message)
            case .success(let r):
                UIPasteboard.general.string = r.url
                Self.onPublishedForTesting?(r)
                let msg = r.url + "\n\n" + L("リンクをコピーしました。") + "  " + ShareStore.visibilityName(r.visibility)
                    + (r.visibility == "password" ? "\n" + L("読む人にはパスワードも伝えてください。") : "")
                let a = UIAlertController(title: L("公開しました"), message: msg, preferredStyle: .alert)
                a.addAction(UIAlertAction(title: L("ブラウザで開く"), style: .default) { _ in
                    if let u = URL(string: r.url) { UIApplication.shared.open(u) }
                    self.dismiss(animated: true)
                })
                a.addAction(UIAlertAction(title: L("閉じる"), style: .cancel) { _ in self.dismiss(animated: true) })
                self.present(a, animated: true)
            }
        }
    }
}

/// 公開したリンクの一覧: 開く・コピー・公開をやめる
final class SharedLinksViewController: UITableViewController {
    private var rows: [ShareStore.Record] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("公開したリンク")
        if navigationController?.viewControllers.first === self {
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("閉じる"), style: .done, target: self, action: #selector(close))
        }
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: ShareStore.didChange, object: nil)
        reload()
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func reload() {
        rows = ShareStore.records
        tableView.reloadData()
        if rows.isEmpty {
            let l = UILabel()
            l.text = L("まだ公開したものはありません")
            l.textAlignment = .center
            l.textColor = .secondaryLabel
            tableView.backgroundView = l
        } else {
            tableView.backgroundView = nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    override func tableView(_ tableView: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let r = rows[ip.row]
        let c = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let name = r.title.isEmpty ? (r.path.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? r.id) : r.title
        c.textLabel?.text = name
        let df = DateFormatter()
        df.locale = I18n.language == "en" ? Locale(identifier: "en_US") : Locale(identifier: "ja_JP")
        df.setLocalizedDateFormatFromTemplate("yMMMd")
        let exp = r.expires.map { L("期限") + " " + df.string(from: $0) } ?? L("期限なし")
        c.detailTextLabel?.text = ShareStore.visibilityName(r.visibility) + " ・ " + Library.dateText(r.created) + " ・ " + exp + "\n" + r.url
        c.detailTextLabel?.numberOfLines = 0
        c.detailTextLabel?.textColor = r.isAlive ? .secondaryLabel : .systemRed
        c.imageView?.image = UIImage(systemName: "link")
        c.accessoryType = .detailButton
        return c
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt ip: IndexPath) {
        tableView.deselectRow(at: ip, animated: true)
        actions(for: rows[ip.row], at: ip)
    }

    override func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith ip: IndexPath) {
        actions(for: rows[ip.row], at: ip)
    }

    private func actions(for r: ShareStore.Record, at ip: IndexPath) {
        let a = UIAlertController(title: r.title.isEmpty ? nil : r.title, message: r.url, preferredStyle: .actionSheet)
        a.addAction(UIAlertAction(title: L("ブラウザで開く"), style: .default) { _ in
            if let u = URL(string: r.url) { UIApplication.shared.open(u) }
        })
        a.addAction(UIAlertAction(title: L("リンクをコピー"), style: .default) { [weak self] _ in
            UIPasteboard.general.string = r.url
            self?.toast(L("コピーしました"))
        })
        a.addAction(UIAlertAction(title: L("公開をやめる"), style: .destructive) { [weak self] _ in self?.unpublish(r) })
        a.addAction(UIAlertAction(title: L("キャンセル"), style: .cancel))
        a.popoverPresentationController?.sourceView = tableView.cellForRow(at: ip)
        present(a, animated: true)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt ip: IndexPath) -> UISwipeActionsConfiguration? {
        let r = rows[ip.row]
        let del = UIContextualAction(style: .destructive, title: L("公開をやめる")) { [weak self] _, _, done in
            self?.unpublish(r)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [del])
    }

    func unpublish(_ r: ShareStore.Record) {
        ShareStore.unpublish(r) { [weak self] ok in
            if ok { self?.toast(L("公開をやめました")) } else { self?.showMessage(L("公開をやめられませんでした"), L("インターネットにつながっているか確かめてください。")) }
            self?.reload()
        }
    }
}
