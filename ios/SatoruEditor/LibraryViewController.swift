import UIKit
import HinokiCore

/// テキスト一覧 (最初の画面)。新しく書き換えた順。フォルダで分けられ、探せる。
final class LibraryViewController: UITableViewController, UISearchResultsUpdating {
    /// nil = すべて、"" = いちばん上、名前 = そのフォルダ
    private var filter: String?
    private var items: [Library.Item] = []
    private var shown: [Library.Item] = []
    private var folders: [String] = []
    private let search = UISearchController(searchResultsController: nil)
    private var timer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("さとるエディタ")
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.backButtonTitle = L("一覧")
        tableView.register(TextCell.self, forCellReuseIdentifier: "text")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = L("テキストを探す")
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false

        let add = UIBarButtonItem(image: UIImage(systemName: "square.and.pencil"), style: .plain, target: self, action: #selector(newText))
        add.accessibilityLabel = L("新しいテキスト")
        add.menu = UIMenu(children: [
            UIAction(title: L("エディタ"), image: ModeIcon.image(mode: nil, size: 22).withRenderingMode(.alwaysOriginal)) { [weak self] _ in self?.create(mode: nil) },
            UIAction(title: L("原稿用紙 (縦)"), image: ModeIcon.image(mode: "genko", size: 22).withRenderingMode(.alwaysOriginal)) { [weak self] _ in self?.create(mode: "genko") },
            UIAction(title: L("原稿用紙 (横)"), image: ModeIcon.image(mode: "genkoH", size: 22).withRenderingMode(.alwaysOriginal)) { [weak self] _ in self?.create(mode: "genkoH") },
        ])
        navigationItem.rightBarButtonItem = add
        navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "folder"), menu: nil)
        navigationItem.leftBarButtonItem?.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.folderMenu() ?? []) }])
        navigationItem.leftBarButtonItem?.accessibilityLabel = L("フォルダ")

        toolbarItems = [
            UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain, target: self, action: #selector(openSettings)),
            .flexibleSpace(),
            UIBarButtonItem(title: L("公開したリンク"), image: UIImage(systemName: "link"), primaryAction: UIAction { [weak self] _ in self?.openLinks() }, menu: nil),
        ]
        navigationController?.isToolbarHidden = false

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reload), name: Library.didChange, object: nil)
        nc.addObserver(self, selector: #selector(reload), name: ShareStore.didChange, object: nil)
        nc.addObserver(self, selector: #selector(reload), name: UIApplication.didBecomeActiveNotification, object: nil)
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(pulled), for: .valueChanged)
        reload()
        // 「5 分前」などを 1 分ごとに直す
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tableView.reloadData() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
        reload()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    @objc private func pulled() {
        reload()
        refreshControl?.endRefreshing()
    }

    @objc func reload() {
        items = Library.items()
        folders = Library.folders()
        if let f = filter, !f.isEmpty, !folders.contains(f) { filter = nil }
        applyFilter()
    }

    private var query: String { search.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? "" }
    private var showsFolders: Bool { filter == nil && query.isEmpty && !folders.isEmpty }

    private func applyFilter() {
        var list = items
        if let f = filter { list = list.filter { ($0.folder ?? "") == f } }
        let q = query
        if !q.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.snippet.localizedCaseInsensitiveContains(q) || $0.fullTextContains(q) }
        }
        shown = list
        navigationItem.title = filter.map { $0.isEmpty ? L("さとるエディタ") : $0 } ?? L("さとるエディタ")
        navigationItem.leftBarButtonItem?.image = UIImage(systemName: filter == nil ? "folder" : "folder.fill")
        tableView.reloadData()
        let empty = UILabel()
        empty.text = q.isEmpty ? L("まだテキストがありません。右上の ＋ で書き始めましょう。") : L("見つかりませんでした")
        empty.textAlignment = .center
        empty.numberOfLines = 0
        empty.textColor = .secondaryLabel
        tableView.backgroundView = shown.isEmpty && !showsFolders ? empty : nil
    }

    func updateSearchResults(for searchController: UISearchController) { applyFilter() }

    private func folderMenu() -> [UIMenuElement] {
        var list: [UIMenuElement] = [
            UIAction(title: L("すべて"), image: UIImage(systemName: "tray.full"), state: filter == nil ? .on : .off) { [weak self] _ in self?.setFilter(nil) },
            UIAction(title: L("いちばん上 (フォルダなし)"), image: UIImage(systemName: "house"), state: filter == "" ? .on : .off) { [weak self] _ in self?.setFilter("") },
        ]
        list += folders.map { f in
            UIAction(title: f, image: UIImage(systemName: "folder"), state: filter == f ? .on : .off) { [weak self] _ in self?.setFilter(f) }
        }
        var manage: [UIMenuElement] = [UIAction(title: L("新しいフォルダ"), image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in self?.newFolder() }]
        if let f = filter, !f.isEmpty {
            manage.append(UIAction(title: L("フォルダの名前を変える"), image: UIImage(systemName: "pencil")) { [weak self] _ in self?.renameFolder(f) })
            manage.append(UIAction(title: L("フォルダを消す"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.deleteFolder(f) })
        }
        return [UIMenu(options: .displayInline, children: list), UIMenu(options: .displayInline, children: manage)]
    }

    func setFilter(_ f: String?) {
        filter = f
        applyFilter()
    }

    // MARK: 作る・開く

    @objc private func newText() {
        let last = UserDefaults.standard.string(forKey: "lastPaperMode")
        create(mode: last == "genko" || last == "genkoH" ? last : nil)
    }

    func create(mode: String?) {
        let folder = filter.flatMap { $0.isEmpty ? nil : $0 }
        guard let url = Library.createBlank(in: folder, mode: mode) else { return }
        open(url)
    }

    @discardableResult
    func open(_ url: URL) -> EditorViewController? {
        do {
            let doc = try TextDocument(url: url)
            let vc = EditorViewController(doc: doc)
            if search.isActive { search.isActive = false }
            navigationController?.popToRootViewController(animated: false)
            navigationController?.pushViewController(vc, animated: !SelfTest.isRunning)
            return vc
        } catch {
            showMessage(L("開けませんでした"), error.localizedDescription)
            return nil
        }
    }

    @objc private func openSettings() {
        present(UINavigationController(rootViewController: SettingsViewController()), animated: true)
    }

    private func openLinks() {
        present(UINavigationController(rootViewController: SharedLinksViewController()), animated: true)
    }

    // MARK: 表

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? (showsFolders ? folders.count : 0) : shown.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 { return showsFolders ? L("フォルダ") : nil }
        return shown.isEmpty ? nil : (showsFolders ? L("すべて") + "  " + L("{0} 件", shown.count) : L("{0} 件", shown.count))
    }

    override func tableView(_ tableView: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        if ip.section == 0 {
            let f = folders[ip.row]
            let c = UITableViewCell(style: .value1, reuseIdentifier: nil)
            c.textLabel?.text = f
            c.imageView?.image = UIImage(systemName: "folder.fill")
            c.imageView?.tintColor = .systemTeal
            c.detailTextLabel?.text = "\(items.filter { $0.folder == f }.count)"
            c.accessoryType = .disclosureIndicator
            return c
        }
        let c = tableView.dequeueReusableCell(withIdentifier: "text", for: ip) as! TextCell
        let item = shown[ip.row]
        c.configure(item, shared: ShareStore.record(for: item.url) != nil, showFolder: filter == nil)
        return c
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt ip: IndexPath) {
        tableView.deselectRow(at: ip, animated: true)
        if ip.section == 0 { return setFilter(folders[ip.row]) }
        open(shown[ip.row].url)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt ip: IndexPath) -> UISwipeActionsConfiguration? {
        guard ip.section == 1 else { return nil }
        let item = shown[ip.row]
        let del = UIContextualAction(style: .destructive, title: L("消す")) { [weak self] _, _, done in
            self?.confirmDelete(item)
            done(false)
        }
        del.image = UIImage(systemName: "trash")
        let move = UIContextualAction(style: .normal, title: L("フォルダへ移す")) { [weak self] _, _, done in
            self?.moveItem(item, from: ip)
            done(true)
        }
        move.image = UIImage(systemName: "folder")
        move.backgroundColor = .systemTeal
        return UISwipeActionsConfiguration(actions: [del, move])
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt ip: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard ip.section == 1 else { return nil }
        let item = shown[ip.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: L("名前を変える"), image: UIImage(systemName: "pencil")) { _ in self?.renameItem(item) },
                UIAction(title: L("フォルダへ移す"), image: UIImage(systemName: "folder")) { _ in self?.moveItem(item, from: ip) },
                UIAction(title: L("消す"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in self?.confirmDelete(item) },
            ])
        }
    }

    private func renameItem(_ item: Library.Item) {
        askText(title: L("名前を変える"), initial: item.name) { [weak self] name in
            do { try Library.rename(item.url, to: name) } catch { self?.showMessage(error.localizedDescription) }
        }
    }

    private func moveItem(_ item: Library.Item, from ip: IndexPath) {
        let a = UIAlertController(title: L("フォルダへ移す"), message: item.name, preferredStyle: .actionSheet)
        let targets: [(String?, String)] = [(nil, L("いちばん上 (フォルダなし)"))] + folders.map { ($0, $0) }
        for (f, name) in targets where f != item.folder {
            a.addAction(UIAlertAction(title: name, style: .default) { [weak self] _ in
                do { try Library.move(item.url, toFolder: f) } catch { self?.showMessage(error.localizedDescription) }
            })
        }
        a.addAction(UIAlertAction(title: L("新しいフォルダ") + "…", style: .default) { [weak self] _ in
            self?.askText(title: L("新しいフォルダ"), placeholder: L("フォルダの名前"), ok: L("フォルダを作る")) { name in
                do {
                    try Library.createFolder(name)
                    try Library.move(item.url, toFolder: Library.cleanName(name))
                } catch { self?.showMessage(error.localizedDescription) }
            }
        })
        a.addAction(UIAlertAction(title: L("キャンセル"), style: .cancel))
        a.popoverPresentationController?.sourceView = tableView.cellForRow(at: ip)
        present(a, animated: true)
    }

    private func confirmDelete(_ item: Library.Item) {
        let a = UIAlertController(title: L("消してよいですか？"), message: L("「{0}」を消します。元に戻せません。", item.name), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("キャンセル"), style: .cancel))
        a.addAction(UIAlertAction(title: L("消す"), style: .destructive) { [weak self] _ in
            do { try Library.delete(item.url) } catch { self?.showMessage(error.localizedDescription) }
        })
        present(a, animated: true)
    }

    private func newFolder() {
        askText(title: L("新しいフォルダ"), placeholder: L("フォルダの名前"), ok: L("フォルダを作る")) { [weak self] name in
            do {
                try Library.createFolder(name)
                self?.setFilter(Library.cleanName(name))
            } catch { self?.showMessage(error.localizedDescription) }
        }
    }

    private func renameFolder(_ f: String) {
        askText(title: L("フォルダの名前を変える"), initial: f) { [weak self] name in
            do {
                try Library.renameFolder(f, to: name)
                self?.setFilter(Library.cleanName(name))
            } catch { self?.showMessage(error.localizedDescription) }
        }
    }

    private func deleteFolder(_ f: String) {
        let a = UIAlertController(title: L("フォルダを消す"), message: "「\(f)」\n" + L("中のテキストも消えます。消してよいですか？"), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("キャンセル"), style: .cancel))
        a.addAction(UIAlertAction(title: L("消す"), style: .destructive) { [weak self] _ in
            do {
                try Library.deleteFolder(f)
                self?.setFilter(nil)
            } catch { self?.showMessage(error.localizedDescription) }
        })
        present(a, animated: true)
    }
}

extension Library.Item {
    /// 本文の中も探す (小さいファイルだけ)
    func fullTextContains(_ q: String) -> Bool {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 2_000_000,
              let data = try? Data(contentsOf: url), let t = try? TextCodec.decode(data) else { return false }
        return t.text.localizedCaseInsensitiveContains(q)
    }
}

/// 一覧の 1 行: 表示の印・名前・拡張子・フォルダ・時間、その下にはじめの部分
final class TextCell: UITableViewCell {
    private let icon = UIImageView()
    private let nameLabel = UILabel()
    private let extLabel = PaddedSmallLabel()
    private let folderLabel = UILabel()
    private let timeLabel = UILabel()
    private let snippetLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        nameLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        extLabel.font = .systemFont(ofSize: 11, weight: .medium)
        extLabel.textColor = .secondaryLabel
        extLabel.backgroundColor = .tertiarySystemFill
        extLabel.layer.cornerRadius = 4
        extLabel.clipsToBounds = true
        folderLabel.font = .systemFont(ofSize: 12)
        folderLabel.textColor = .systemTeal
        timeLabel.font = .systemFont(ofSize: 13)
        timeLabel.textColor = .secondaryLabel
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        extLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        extLabel.setContentHuggingPriority(.required, for: .horizontal)
        folderLabel.setContentHuggingPriority(.required, for: .horizontal)
        snippetLabel.font = .systemFont(ofSize: 14)
        snippetLabel.textColor = .secondaryLabel
        snippetLabel.numberOfLines = 2
        let top = UIStackView(arrangedSubviews: [nameLabel, extLabel, folderLabel, UIView(), timeLabel])
        top.spacing = 6
        top.alignment = .center
        let text = UIStackView(arrangedSubviews: [top, snippetLabel])
        text.axis = .vertical
        text.spacing = 3
        let row = UIStackView(arrangedSubviews: [icon, text])
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 30), icon.heightAnchor.constraint(equalToConstant: 30),
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: Library.Item, shared: Bool, showFolder: Bool) {
        icon.image = ModeIcon.image(mode: item.mode, size: 30, shared: shared)
        nameLabel.text = item.name
        extLabel.text = item.ext.isEmpty ? nil : item.ext.lowercased()
        extLabel.isHidden = item.ext.isEmpty
        if let f = item.folder {
            let a = NSMutableAttributedString(attachment: NSTextAttachment(image: UIImage(systemName: "folder")!.withTintColor(.systemTeal, renderingMode: .alwaysOriginal)))
            a.append(NSAttributedString(string: " " + f))
            folderLabel.attributedText = a
        } else {
            folderLabel.attributedText = nil
        }
        folderLabel.isHidden = !showFolder || item.folder == nil
        timeLabel.text = Library.dateText(item.modified)
        snippetLabel.text = item.snippet.isEmpty ? " " : item.snippet
        accessibilityIdentifier = "row-" + item.name
    }
}

final class PaddedSmallLabel: UILabel {
    override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 4, dy: 1)) }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + 8, height: s.height + 2)
    }
}
