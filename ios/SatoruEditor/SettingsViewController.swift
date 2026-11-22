import UIKit
import HinokiCore

/// 設定: 言語・保存場所・書く画面の見た目・AI・公開
final class SettingsViewController: UITableViewController {
    private enum Row {
        case language, location, font, size, lineNumbers, furigana, autoFormat, ai, links, privacy, folder, version
    }
    private static let placeSection = "保存場所"
    private var sections: [(String?, [Row])] { [
        (nil, [.language]),
        (Self.placeSection, [.location]),
        ("書く", [.font, .size, .lineNumbers, .furigana, .autoFormat]),
        ("AI アシスト", [.ai]),
        ("リンクで公開共有", [.links, .privacy]),
        ("このバージョン", [.folder, .version]),
    ] }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("設定")
        NotificationCenter.default.addObserver(tableView!, selector: #selector(UITableView.reloadData), name: Library.didChange, object: nil)
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("完了"), style: .done, target: self, action: #selector(close))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    @objc private func close() { dismiss(animated: true) }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection s: Int) -> String? { sections[s].0.map { L($0) } }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection s: Int) -> Int { sections[s].1.count }

    override func tableView(_ tableView: UITableView, titleForFooterInSection s: Int) -> String? {
        if sections[s].0 == Self.placeSection {
            switch LibraryLocation.iCloud {
            case .available:
                return LibraryLocation.isICloud
                    ? L("Mac のさとるエディタと同じテキストが見られます。ファイル App では iCloud Drive の「さとるエディタ」にあります。一覧の上のタブで「ローカル」に切り替えられます。")
                    : L("一覧の上のタブで iCloud に切り替えられます。")
            case .unavailable: return L("iCloud が使えないので、この iPhone の中に保存しています。iPhone の設定で iCloud にサインインし、iCloud Drive をオンにすると、Mac と同じテキストが見られます。")
            case .checking: return nil
            }
        }
        guard s == sections.count - 1 else { return nil }
        return LibraryLocation.isICloud ? L("ファイル App の「iCloud Drive」>「さとるエディタ」にあります。")
            : L("ファイル App の「このiPhone内」>「さとるエディタ」にあります。")
    }

    private func toggle(_ title: String, _ on: Bool, _ action: @escaping (Bool) -> Void) -> UITableViewCell {
        let c = UITableViewCell()
        c.textLabel?.text = title
        c.textLabel?.numberOfLines = 0
        let sw = UISwitch()
        sw.isOn = on
        sw.addAction(UIAction { _ in action(sw.isOn) }, for: .valueChanged)
        c.accessoryView = sw
        c.selectionStyle = .none
        return c
    }

    override func tableView(_ tableView: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let row = sections[ip.section].1[ip.row]
        let c = UITableViewCell(style: row == .location ? .subtitle : .value1, reuseIdentifier: nil)
        switch row {
        case .language:
            c.textLabel?.text = L("言語") + " / Language"
            let v = UserDefaults.standard.string(forKey: "language") ?? "auto"
            c.detailTextLabel?.text = v == "ja" ? "日本語" : v == "en" ? "English" : L("自動 (iPhone の設定に合わせる)")
            c.accessoryType = .disclosureIndicator
        case .location:
            c.textLabel?.text = L("いまの場所")
            c.detailTextLabel?.text = LibraryLocation.displayName
            c.detailTextLabel?.numberOfLines = 0
            c.imageView?.image = UIImage(systemName: LibraryLocation.isICloud ? "icloud" : "iphone")
            c.selectionStyle = .none
        case .font:
            c.textLabel?.text = L("文字の形")
            c.detailTextLabel?.text = ["mincho": L("明朝"), "mono": L("等幅")][Prefs.fontStyle] ?? L("ゴシック")
            c.accessoryType = .disclosureIndicator
        case .size:
            c.textLabel?.text = L("文字の大きさ")
            let st = UIStepper()
            st.minimumValue = 12
            st.maximumValue = 32
            st.value = Double(Prefs.fontSize)
            c.detailTextLabel?.text = "\(Int(Prefs.fontSize))"
            st.addAction(UIAction { [weak c] _ in
                Prefs.fontSize = CGFloat(st.value)
                c?.detailTextLabel?.text = "\(Int(st.value))"
            }, for: .valueChanged)
            c.accessoryView = st
            c.selectionStyle = .none
        case .lineNumbers: return toggle(L("行番号"), Prefs.lineNumbers) { Prefs.lineNumbers = $0 }
        case .furigana: return toggle(L("ふりがな (自動)"), Prefs.furigana) { Prefs.furigana = $0 }
        case .autoFormat: return toggle(L("作文の自動整形 (題名・名前・段落)"), Prefs.genkoAutoFormat) { Prefs.genkoAutoFormat = $0 }
        case .ai:
            c.textLabel?.text = L("AI の設定")
            let p = AISettings.provider
            c.detailTextLabel?.text = AISettings.isReady ? p.label : L("まだ使えません")
            c.accessoryType = .disclosureIndicator
        case .links:
            c.textLabel?.text = L("公開したリンク")
            c.detailTextLabel?.text = "\(ShareStore.records.count)"
            c.accessoryType = .disclosureIndicator
        case .privacy: return toggle(L("公開する前に個人情報を点検する"), !Prefs.privacyCheckOff) { Prefs.privacyCheckOff = !$0 }
        case .folder:
            c.textLabel?.text = L("テキストのフォルダ")
            c.detailTextLabel?.text = L("{0} 件", Library.items().count)
        case .version:
            c.textLabel?.text = L("このバージョン")
            let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            c.detailTextLabel?.text = v + " (β)"
        }
        return c
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt ip: IndexPath) {
        tableView.deselectRow(at: ip, animated: true)
        switch sections[ip.section].1[ip.row] {
        case .language:
            pick(L("言語") + " / Language", [("auto", L("自動 (iPhone の設定に合わせる)")), ("ja", "日本語"), ("en", "English")],
                 current: UserDefaults.standard.string(forKey: "language") ?? "auto") { v in
                UserDefaults.standard.set(v, forKey: "language")
                IOSStrings.applyLanguage()
                (UIApplication.shared.delegate as? AppDelegate)?.rebuildUI()
            }
        case .font:
            pick(L("文字の形"), [("gothic", L("ゴシック")), ("mincho", L("明朝")), ("mono", L("等幅"))], current: Prefs.fontStyle) { [weak self] v in
                Prefs.fontStyle = v
                self?.tableView.reloadData()
            }
        case .ai: navigationController?.pushViewController(AISettingsViewController(), animated: true)
        case .links: navigationController?.pushViewController(SharedLinksViewController(), animated: true)
        default: break
        }
    }

    private func pick(_ title: String, _ options: [(String, String)], current: String, done: @escaping (String) -> Void) {
        let a = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for (k, name) in options {
            a.addAction(UIAlertAction(title: (k == current ? "✓ " : "") + name, style: .default) { _ in done(k) })
        }
        a.addAction(UIAlertAction(title: L("キャンセル"), style: .cancel))
        a.popoverPresentationController?.sourceView = tableView
        a.popoverPresentationController?.sourceRect = CGRect(x: tableView.bounds.midX, y: 80, width: 1, height: 1)
        present(a, animated: true)
    }
}
