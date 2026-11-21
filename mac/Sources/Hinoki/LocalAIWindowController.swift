import AppKit
import HinokiCore

/// 「ローカルLLM簡単設定」: 自分の Mac の中で動く軽い LLM (Ollama) を、入れる・選ぶ・つなぐ を 1 つの画面で。
/// 文章は外に送られず、料金もかからない
final class LocalAIWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, URLSessionDataDelegate, URLSessionDownloadDelegate {
    static let shared = LocalAIWindowController()

    private enum ServerState { case checking, notInstalled, stopped, running }
    private var state = ServerState.checking
    private var installed: [LocalLLM.Installed] = []
    private var timer: Timer?

    private struct Row {
        let name: String
        let note: String
        let size: String
        let isInstalled: Bool
    }
    private var rows: [Row] = []

    // 取ってきている最中のモデル
    private var pulling: String?
    private var pullTask: URLSessionDataTask?
    private var pullSession: URLSession?
    private var pullBuffer = Data()
    private var pullProgress: LocalLLM.Progress?

    // Ollama を自動で入れている最中
    private var installSession: URLSession?
    private var installTask: URLSessionDownloadTask?
    private var installing = false
    private let installBar = NSProgressIndicator()
    /// いまの Ollama に必要な macOS (公式の説明書から読む。読めるまでは控えの値)
    private var requiredMacOS = LocalLLM.fallbackRequiredMacOS
    private var requirementChecked = false
    private let compatLabel = NSTextField(wrappingLabelWithString: "")

    private static var osText: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }
    private static var cpuText: String {
        #if arch(arm64)
        return "Apple Silicon"
        #else
        return "Intel"
        #endif
    }
    private var compatibility: LocalLLM.Compatibility {
        LocalLLM.compatibility(osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion, required: requiredMacOS)
    }
    private let pageButton = NSButton(title: "", target: nil, action: nil)

    private let stateIcon = NSTextField(labelWithString: "●")
    private let stateLabel = NSTextField(wrappingLabelWithString: "")
    private let installButton = NSButton(title: "", target: nil, action: nil)
    private let startButton = NSButton(title: "", target: nil, action: nil)
    private let table = NSTableView()
    private let nameField = NSTextField(string: "")
    private let currentLabel = NSTextField(wrappingLabelWithString: "")

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        w.title = L("ローカルLLM簡単設定")
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.minSize = NSSize(width: 560, height: 440)
        super.init(window: w)
        w.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        refresh()
        checkRequirement()
        timer?.invalidate()
        // 入れ終わった・起動したのに気づけるよう、開いているあいだは 2 秒ごとに見直す
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    // MARK: 画面

    private func build() {
        guard let content = window?.contentView else { return }
        let head = NSTextField(labelWithString: L("自分の Mac の中で動く AI"))
        head.font = .systemFont(ofSize: 17, weight: .bold)
        let lead = NSTextField(wrappingLabelWithString: L("文章は外に送られません。料金もかかりません。軽いモデルなので、短い文章の手直しや、ちょっとしたコード向きです (長い文書は、範囲を選んで頼んでください)。"))
        lead.font = .systemFont(ofSize: 11)
        lead.textColor = .secondaryLabelColor

        // 1. Ollama
        stateIcon.font = .systemFont(ofSize: 14)
        stateLabel.font = .systemFont(ofSize: 12)
        for (b, title, action) in [(installButton, L("Ollama を自動で入れる"), #selector(installOllama)),
                                    (pageButton, L("公式ページを開く…"), #selector(openDownloadPage)),
                                    (startButton, L("Ollama を起動する"), #selector(startServer))] {
            b.title = title
            b.bezelStyle = .rounded
            b.target = self
            b.action = action
        }
        let stateRow = NSStackView(views: [stateIcon, stateLabel])
        stateRow.alignment = .firstBaseline
        stateRow.spacing = 6
        installButton.bezelColor = .controlAccentColor
        installBar.style = .bar
        installBar.minValue = 0
        installBar.maxValue = 1
        installBar.isIndeterminate = false
        installBar.isHidden = true
        installBar.translatesAutoresizingMaskIntoConstraints = false
        installBar.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let buttons = NSStackView(views: [installButton, pageButton, startButton, installBar])
        buttons.spacing = 8
        compatLabel.font = .systemFont(ofSize: 11)
        let step1 = NSStackView(views: [stateRow, compatLabel, buttons])
        step1.orientation = .vertical
        step1.alignment = .leading
        step1.spacing = 8

        // 2. モデル
        for (id, title, width) in [("name", L("モデル"), 170.0), ("size", L("大きさ"), 70.0), ("note", L("説明"), 190.0), ("act", "", 150.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = CGFloat(width)
            c.resizingMask = id == "note" ? .autoresizingMask : []
            table.addTableColumn(c)
        }
        table.rowHeight = 30
        table.dataSource = self
        table.delegate = self
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        nameField.placeholderString = L("ほかのモデルの名前 (例: phi4-mini)")
        nameField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let pullOther = NSButton(title: L("入れる"), target: self, action: #selector(pullTyped))
        pullOther.bezelStyle = .rounded
        let library = NSButton(title: L("モデルの一覧を見る…"), target: self, action: #selector(openLibrary))
        library.bezelStyle = .rounded
        let otherRow = NSStackView(views: [nameField, pullOther, NSView(), library])
        otherRow.spacing = 8

        currentLabel.font = .systemFont(ofSize: 12)

        func box(_ title: String, _ v: NSView) -> NSView { SettingsUI.box(title, v, fillWidth: true) }
        let step2 = NSStackView(views: [scroll, otherRow])
        step2.orientation = .vertical
        step2.alignment = .leading
        step2.spacing = 8
        let boxes = [box(L("1. Ollama (AI を動かす無料のソフト)"), step1), box(L("2. モデルを入れて「使う」"), step2), box(L("いまの接続先"), currentLabel)]
        let stack = NSStackView(views: [head, lead] + boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            lead.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.widthAnchor.constraint(equalTo: step2.widthAnchor),
            otherRow.widthAnchor.constraint(equalTo: step2.widthAnchor),
        ])
        for b in boxes { b.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        boxes[1].setContentHuggingPriority(.init(1), for: .vertical)
        updateUI()
    }

    // MARK: Ollama の状態

    private static var appURL: URL? {
        let fm = FileManager.default
        let candidates = ["/Applications/Ollama.app", NSHomeDirectory() + "/Applications/Ollama.app"]
        return candidates.first { fm.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    private static var cliPath: String? {
        ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval = 3) -> URLRequest {
        var r = URLRequest(url: URL(string: LocalLLM.server + path)!, timeoutInterval: timeout)
        r.httpMethod = method
        if let b = body {
            r.httpBody = try? JSONSerialization.data(withJSONObject: b)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    /// 入れる前に: 公式の説明書から、いまの Ollama に必要な macOS を調べる
    private func checkRequirement() {
        guard let url = URL(string: LocalLLM.requirementsURL) else { return }
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 8)) { [weak self] data, resp, _ in
            let text = (resp as? HTTPURLResponse)?.statusCode == 200 ? String(data: data ?? Data(), encoding: .utf8) : nil
            let found = text.flatMap { LocalLLM.parseRequiredMacOS($0) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let n = found { self.requiredMacOS = n }
                self.requirementChecked = found != nil
                self.updateUI()
            }
        }.resume()
    }

    /// 動いているか・何が入っているかを見直す
    private func refresh() {
        URLSession.shared.dataTask(with: request("/api/tags")) { [weak self] data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            let list = ok ? LocalLLM.parseTags(data ?? Data()) : []
            DispatchQueue.main.async {
                guard let self = self else { return }
                let newState: ServerState = ok ? .running : (Self.appURL != nil || Self.cliPath != nil ? .stopped : .notInstalled)
                if self.installing && newState != .running { return } // 入れている最中の表示を上書きしない
                if newState != self.state || list != self.installed {
                    self.state = newState
                    self.installed = list
                    self.updateUI()
                }
            }
        }.resume()
    }

    private func updateUI() {
        switch state {
        case .checking:
            stateIcon.textColor = .tertiaryLabelColor
            stateLabel.stringValue = L("確かめています…")
        case .notInstalled:
            stateIcon.textColor = .systemOrange
            stateLabel.stringValue = L("Ollama がまだ入っていません。「Ollama を自動で入れる」を押すと、公式サイトから取ってきて「アプリケーション」に入れ、起動するところまで行います。")
        case .stopped:
            stateIcon.textColor = .systemOrange
            stateLabel.stringValue = L("Ollama は入っていますが、動いていません。「Ollama を起動する」を押してください。")
        case .running:
            stateIcon.textColor = .systemGreen
            stateLabel.stringValue = L("Ollama は動いています。")
        }
        // 入れる前の確かめ: この Mac の macOS で動くか
        let compat = compatibility
        let source = requirementChecked ? L("公式の説明書で確認") : L("アプリに入っている情報で判断")
        switch compat {
        case .current:
            compatLabel.stringValue = "✓ " + L("この Mac (macOS {0}・{1}) は、いまの Ollama (macOS {2} 以上) に対応しています。({3})", Self.osText, Self.cpuText, requiredMacOS, source)
            compatLabel.textColor = .systemGreen
            installButton.title = L("Ollama を自動で入れる")
        case .legacy:
            compatLabel.stringValue = "⚠︎ " + L("この Mac は macOS {0} ({1}) です。いまの Ollama は macOS {2} 以上が必要なので動きません。代わりに、この Mac でも動く前の版 ({3}) を入れます。({4})", Self.osText, Self.cpuText, requiredMacOS, LocalLLM.legacyVersion, source)
            compatLabel.textColor = .systemOrange
            installButton.title = L("前の版の Ollama ({0}) を自動で入れる", LocalLLM.legacyVersion)
        case .unsupported:
            compatLabel.stringValue = "✗ " + L("この Mac (macOS {0}) では Ollama は動きません。macOS {1} 以上が必要です。", Self.osText, LocalLLM.legacyRequiredMacOS)
            compatLabel.textColor = .systemRed
        }
        compatLabel.isHidden = state == .running || state == .stopped
        installButton.isHidden = state != .notInstalled
        pageButton.isHidden = state != .notInstalled
        installButton.isEnabled = !installing && compat != .unsupported
        installBar.isHidden = !installing
        startButton.isHidden = state != .stopped

        // おすすめ + それ以外に入っているもの
        var list: [Row] = LocalLLM.recommended.map { r in
            let have = installed.first { LocalLLM.sameModel($0.name, r.name) }
            return Row(name: r.name, note: L(r.note), size: have.map { LocalLLM.sizeText($0.size) } ?? L("約 {0} GB", String(format: "%.1f", r.sizeGB)),
                       isInstalled: have != nil)
        }
        for m in installed where !LocalLLM.recommended.contains(where: { LocalLLM.sameModel($0.name, m.name) }) {
            list.append(Row(name: m.name, note: L("入っているモデル"), size: LocalLLM.sizeText(m.size), isInstalled: true))
        }
        if let p = pulling, !list.contains(where: { LocalLLM.sameModel($0.name, p) }) {
            list.append(Row(name: p, note: "", size: "", isInstalled: false))
        }
        rows = list
        table.reloadData()

        let p = AISettings.provider
        if p == .custom, AISettings.baseURL(.custom).contains("11434") {
            let ready = AISettings.isReady
            currentLabel.stringValue = (ready ? "● " : "") + L("AI アシスタントは、ローカルの「{0}」を使います。", AISettings.model(.custom))
            currentLabel.textColor = ready ? .systemGreen : .labelColor
        } else {
            currentLabel.stringValue = L("AI アシスタントは、いま「{0}」につないでいます。上の一覧で「使う」を押すと、ローカルの AI に切り替わります。", p.label)
            currentLabel.textColor = .secondaryLabelColor
        }
    }

    @objc private func openDownloadPage() {
        if let u = URL(string: LocalLLM.downloadPage) { NSWorkspace.shared.open(u) }
    }

    // MARK: Ollama を自動で入れる

    @objc private func installOllama() {
        guard !installing else { return }
        let a = NSAlert()
        a.messageText = L("Ollama を入れますか？")
        a.informativeText = L("公式サイト (ollama.com) からダウンロードして、「アプリケーション」フォルダに入れて起動します。\n正規のアプリか、この Mac で動く版かを確かめてから入れます。数百 MB あるので、少し時間がかかります。")
        a.addButton(withTitle: L("入れる"))
        a.addButton(withTitle: L("やめる"))
        // この Mac で動く版を選ぶ (いまの版が動かなければ前の版)
        let compat = compatibility
        guard compat != .unsupported else { return }
        let source = compat == .current ? LocalLLM.installerURL : LocalLLM.legacyInstallerURL
        if compat == .legacy {
            a.informativeText += "\n\n" + L("この Mac の macOS では、いまの版が動かないので、前の版 ({0}) を入れます。", LocalLLM.legacyVersion)
        }
        guard a.runModal() == .alertFirstButtonReturn, let url = URL(string: source) else { return }
        installing = true
        installBar.doubleValue = 0
        stateIcon.textColor = .systemBlue
        stateLabel.stringValue = L("ダウンロードしています…")
        updateUI()
        stateLabel.stringValue = L("ダウンロードしています…")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        installSession = session
        let task = session.downloadTask(with: url)
        installTask = task
        task.resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        installBar.doubleValue = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let percent = Int((Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100).rounded(.down))
        stateLabel.stringValue = L("ダウンロードしています… {0}% ({1} / {2})", percent,
                                   LocalLLM.sizeText(totalBytesWritten), LocalLLM.sizeText(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 一時ファイルはこの関数を抜けると消えるので、先に移しておく
        let ext = downloadTask.originalRequest?.url?.pathExtension.lowercased() == "zip" ? "zip" : "dmg"
        let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("Ollama-\(UUID().uuidString).\(ext)")
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, (try? FileManager.default.moveItem(at: location, to: dmg)) != nil else {
            finishInstall(error: L("ダウンロードできませんでした: {0}", "HTTP \(status)"))
            return
        }
        stateLabel.stringValue = L("確かめて、アプリケーションに入れています…")
        installBar.isIndeterminate = true
        installBar.startAnimation(nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let problem = Self.installPackage(dmg)
            try? FileManager.default.removeItem(at: dmg)
            DispatchQueue.main.async { self?.finishInstall(error: problem) }
        }
    }

    private func finishInstall(error: String?) {
        installing = false
        installBar.stopAnimation(nil)
        installBar.isIndeterminate = false
        installSession?.finishTasksAndInvalidate()
        installSession = nil
        installTask = nil
        if let e = error {
            updateUI()
            alert(L("Ollama を入れられませんでした"), e)
        } else {
            state = .stopped
            updateUI()
            startServer() // 入れ終わったら、そのまま起動する
            _ = Toast.show(in: window, kind: .success, title: L("Ollama を入れました"), detail: L("起動したら、下の一覧からモデルを入れてください"))
        }
    }

    /// 取ってきた .dmg / .zip を開いて、中のアプリを確かめてから「アプリケーション」に入れる。だめなら理由を返す
    private static func installPackage(_ dmg: URL) -> String? {
        func run(_ tool: String, _ args: [String]) -> (status: Int32, out: Data) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            do { try p.run() } catch { return (-1, Data()) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, data)
        }
        let fm = FileManager.default
        let mount: String
        if dmg.pathExtension == "zip" {
            // zip は一時フォルダに広げる
            let dir = fm.temporaryDirectory.appendingPathComponent("Ollama-unzip-\(UUID().uuidString)")
            guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
                  run("/usr/bin/ditto", ["-x", "-k", dmg.path, dir.path]).status == 0 else {
                return L("ダウンロードしたファイルを開けませんでした")
            }
            mount = dir.path
        } else {
            let attach = run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-plist"])
            guard attach.status == 0,
                  let plist = (try? PropertyListSerialization.propertyList(from: attach.out, format: nil)) as? [String: Any],
                  let entities = plist["system-entities"] as? [[String: Any]],
                  let m = entities.compactMap({ $0["mount-point"] as? String }).first else {
                return L("ダウンロードしたファイルを開けませんでした")
            }
            mount = m
        }
        defer {
            if dmg.pathExtension == "zip" { try? fm.removeItem(atPath: mount) } else { _ = run("/usr/bin/hdiutil", ["detach", mount, "-quiet"]) }
        }
        guard let name = (try? fm.contentsOfDirectory(atPath: mount))?.first(where: { $0.hasSuffix(".app") }) else {
            return L("ダウンロードしたファイルの中に、アプリが見つかりません")
        }
        let app = URL(fileURLWithPath: mount).appendingPathComponent(name)
        // Apple の確認 (公証) を通った正規のアプリか
        guard run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]).status == 0 else {
            return L("正規のアプリだと確かめられなかったので、入れませんでした")
        }
        // この Mac の macOS で動く版か
        if let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
           let minimum = info["LSMinimumSystemVersion"] as? String {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            let mine = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            if PluginVersion.compare(minimum, mine) > 0 {
                return L("いまの Ollama は macOS {0} 以上が必要です。この Mac は macOS {1} なので動きません。「公式ページを開く…」から、古い版を探すか、macOS を新しくしてください。", minimum, mine)
            }
        }
        // この Mac の CPU (Intel / Apple Silicon) で動くか
        if let archs = Bundle(url: app)?.executableArchitectures?.map({ $0.intValue }) {
            #if arch(arm64)
            let mine = NSBundleExecutableArchitectureARM64
            #else
            let mine = NSBundleExecutableArchitectureX86_64
            #endif
            if !archs.isEmpty, !archs.contains(mine) {
                return L("この版の Ollama は、この Mac の CPU ({0}) では動きません。", cpuText)
            }
        }
        var destDir = URL(fileURLWithPath: "/Applications")
        if !fm.isWritableFile(atPath: destDir.path) {
            destDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
            try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        }
        let dest = destDir.appendingPathComponent(name)
        if fm.fileExists(atPath: dest.path) { return nil } // もう入っている
        // 署名を壊さないように ditto で写す
        guard run("/usr/bin/ditto", [app.path, dest.path]).status == 0 else {
            try? fm.removeItem(at: dest)
            return L("「アプリケーション」フォルダに入れられませんでした")
        }
        return nil
    }

    @objc private func openLibrary() {
        if let u = URL(string: "https://ollama.com/library") { NSWorkspace.shared.open(u) }
    }

    @objc private func startServer() {
        if let app = Self.appURL {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        } else if let cli = Self.cliPath {
            // コマンドだけ入っている場合 (Homebrew など)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = ["serve"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
        stateLabel.stringValue = L("起動しています…")
    }

    // MARK: モデルを入れる・使う・消す

    private func pull(_ name: String) {
        guard state == .running else { NSSound.beep(); return }
        guard pulling == nil else {
            alert(L("いま別のモデルを入れています"), L("終わってから、もう一度押してください。"))
            return
        }
        guard LocalLLM.isValidModelName(name) else {
            alert(L("モデルの名前が正しくありません"), name)
            return
        }
        pulling = name
        pullProgress = nil
        pullBuffer = Data()
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        pullSession = session
        // 大きなファイルなので、時間切れは長めに
        let task = session.dataTask(with: request("/api/pull", method: "POST", body: ["model": name, "stream": true], timeout: 3600))
        pullTask = task
        task.resume()
        updateUI()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        pullBuffer.append(data)
        while let nl = pullBuffer.firstIndex(of: 0x0A) {
            let line = String(data: pullBuffer[pullBuffer.startIndex..<nl], encoding: .utf8) ?? ""
            pullBuffer.removeSubrange(pullBuffer.startIndex...nl)
            if let p = LocalLLM.parseProgress(line) { pullProgress = p }
        }
        updatePullRow()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Ollama 本体のダウンロードのほう (うまくいったときは didFinishDownloadingTo で続きをする)
        if session === installSession {
            if let e = error, installing { finishInstall(error: L("ダウンロードできませんでした: {0}", e.localizedDescription)) }
            return
        }
        let name = pulling ?? ""
        let cancelled = (error as NSError?)?.code == NSURLErrorCancelled
        let failure = pullProgress?.error ?? (cancelled ? nil : error?.localizedDescription)
        let done = pullProgress?.done == true && failure == nil
        pulling = nil
        pullTask = nil
        pullSession?.finishTasksAndInvalidate()
        pullSession = nil
        pullProgress = nil
        if let f = failure {
            alert(L("「{0}」を入れられませんでした", name), f)
        } else if done {
            _ = Toast.show(in: window, kind: .success, title: L("「{0}」を入れました", name), detail: L("「使う」を押すと、AI アシスタントがこのモデルになります"))
        }
        refresh()
        updateUI()
    }

    private func updatePullRow() {
        guard let name = pulling, let i = rows.firstIndex(where: { LocalLLM.sameModel($0.name, name) }) else { return }
        table.reloadData(forRowIndexes: [i], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
    }

    @objc private func pullTyped() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        pull(name)
    }

    @objc private func rowButton(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        let r = rows[sender.tag]
        if let p = pulling, LocalLLM.sameModel(p, r.name) {
            pullTask?.cancel() // 途中までの分は Ollama が残すので、次は続きから
        } else if r.isInstalled {
            use(r.name)
        } else {
            pull(r.name)
        }
    }

    @objc private func deleteRow(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        let name = rows[sender.tag].name
        let a = NSAlert()
        a.messageText = L("「{0}」を消しますか？", name)
        a.informativeText = L("モデルのファイルを Mac から消します。あとでまた入れられます。")
        a.addButton(withTitle: L("消す"))
        a.addButton(withTitle: L("やめる"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        URLSession.shared.dataTask(with: request("/api/delete", method: "DELETE", body: ["model": name], timeout: 30)) { [weak self] _, _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }.resume()
    }

    /// AI アシスタントの接続先を、このモデルにする
    private func use(_ name: String) {
        AISettings.setCustomBaseURL(LocalLLM.openAIBase)
        AISettings.setModel(name, .custom)
        AISettings.provider = .custom
        AISettings.markVerified(.custom)
        // 追加機能の AI がオフなら入れる (ローカルなので、外に送る前の確認は要らない)
        if !EditorExtension.ai.isOn {
            UserDefaults.standard.set(true, forKey: EditorExtension.ai.prefKey)
            ExtensionUI.apply()
        }
        NotificationCenter.default.post(name: .viewSettingsDidChange, object: nil)
        updateUI()
        _ = Toast.show(in: window, kind: .success, title: L("AI アシスタントを「{0}」につなぎました", name),
                       detail: L("エディタの AI アシスタントで、そのまま使えます"))
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = text
        if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    // MARK: 表

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let isPulling = pulling.map { LocalLLM.sameModel($0, r.name) } ?? false
        let inUse = AISettings.provider == .custom && AISettings.baseURL(.custom).contains("11434")
            && LocalLLM.sameModel(AISettings.model(.custom), r.name)
        func label(_ s: String, bold: Bool = false, gray: Bool = false) -> NSView {
            let f = NSTextField(labelWithString: s)
            f.font = bold ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 11)
            if gray { f.textColor = .secondaryLabelColor }
            f.lineBreakMode = .byTruncatingTail
            f.toolTip = s
            let cell = NSTableCellView()
            f.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(f)
            NSLayoutConstraint.activate([
                f.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                f.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                f.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
        switch tableColumn?.identifier.rawValue {
        case "name": return label((inUse ? "● " : "") + r.name, bold: true)
        case "size": return label(r.size, gray: true)
        case "note":
            if isPulling {
                let bar = NSProgressIndicator()
                bar.style = .bar
                bar.minValue = 0
                bar.maxValue = 1
                if let f = pullProgress?.fraction {
                    bar.isIndeterminate = false
                    bar.doubleValue = f
                } else {
                    bar.isIndeterminate = true
                    bar.startAnimation(nil)
                }
                let pct = pullProgress?.fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "…"
                let t = NSTextField(labelWithString: pct)
                t.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                let s = NSStackView(views: [bar, t])
                s.spacing = 6
                s.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
                return s
            }
            return label(r.note, gray: true)
        default:
            let main = NSButton(title: isPulling ? L("中止") : r.isInstalled ? (inUse ? L("使用中") : L("使う")) : L("入れる"),
                                target: self, action: #selector(rowButton(_:)))
            main.bezelStyle = .rounded
            main.controlSize = .small
            main.tag = row
            main.isEnabled = isPulling || (state == .running && !(r.isInstalled && inUse) && (r.isInstalled || pulling == nil))
            if r.isInstalled && !inUse { main.bezelColor = .controlAccentColor }
            var views: [NSView] = [main]
            if r.isInstalled && !isPulling {
                let del = NSButton(title: L("消す"), target: self, action: #selector(deleteRow(_:)))
                del.bezelStyle = .rounded
                del.controlSize = .small
                del.tag = row
                del.isEnabled = state == .running
                views.append(del)
            }
            let s = NSStackView(views: views)
            s.spacing = 4
            s.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
            return s
        }
    }
}
