import AppKit
import HinokiCore

/// VOICEVOX のかんたんインストール・ON / OFF・削除。
/// 公式の配布物 (GitHub の VOICEVOX/voicevox の最新版、Mac 用 CPU 版の zip) を取ってきて、
/// ~/Library/Application Support/satoruEditor/VOICEVOX に展開し、中の声を作る部分 (エンジン) だけを画面を出さずに動かす。
/// /Applications には何も入れないので、「削除」でそのフォルダを消せば元どおり
final class VoiceVoxInstaller: NSObject, URLSessionDownloadDelegate {
    static let shared = VoiceVoxInstaller()

    enum State: Equatable {
        case notInstalled
        case downloading(Double)   // 0 〜 1
        case extracting
        case installed
        case failed(String)
    }

    /// 状態が変わったら呼ぶ (設定画面の表示を合わせる)
    var onChange: (() -> Void)?
    private(set) var state: State = .notInstalled { didSet { DispatchQueue.main.async { self.onChange?() } } }
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var expectedVersion = ""
    private var engine: Process?

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("satoruEditor/VOICEVOX", isDirectory: true)
    }
    private static var infoURL: URL { root.appendingPathComponent("installed.json") }

    /// 入れた版とエンジンの場所
    struct Info: Codable { let version: String; let engine: String }
    static var info: Info? {
        guard let d = try? Data(contentsOf: infoURL), let i = try? JSONDecoder().decode(Info.self, from: d),
              FileManager.default.isExecutableFile(atPath: i.engine) else { return nil }
        return i
    }

    override init() {
        super.init()
        state = Self.info != nil ? .installed : .notInstalled
        // アプリを終えるときは、動かしたエンジンも止める
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.stopEngine()
        }
    }

    var isBusy: Bool {
        switch state {
        case .downloading, .extracting: return true
        default: return false
        }
    }
    var isEngineRunning: Bool { engine?.isRunning == true }

    // MARK: インストール

    /// 利用規約を見せて、同意したらダウンロードを始める
    func confirmAndInstall(from window: NSWindow?) {
        guard !isBusy else { return }
        let a = NSAlert()
        a.messageText = L("VOICEVOX をインストールします")
        a.informativeText = L("公式の配布物 (約 2 GB) をダウンロードして、このアプリ専用の場所に入れます。少し時間がかかります。\n\nVOICEVOX の利用規約と、キャラクターごとの利用規約に同意したうえで使ってください。読み上げた声を公開するときは「VOICEVOX:キャラクター名」と書く必要があります。")
        a.addButton(withTitle: L("同意してインストール"))
        a.addButton(withTitle: L("利用規約を見る"))
        a.addButton(withTitle: L("やめる"))
        let handle: (NSApplication.ModalResponse) -> Void = { r in
            switch r {
            case .alertFirstButtonReturn: self.install()
            case .alertSecondButtonReturn: NSWorkspace.shared.open(VoiceVox.termsURL)
            default: break
            }
        }
        if let w = window { a.beginSheetModal(for: w, completionHandler: handle) } else { handle(a.runModal()) }
    }

    func install() {
        guard !isBusy else { return }
        state = .downloading(0)
        // 最新版の、この Mac に合う zip を探す
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/VOICEVOX/voicevox/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("satoruEditor", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, err in
            guard err == nil, let data = data,
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = o["tag_name"] as? String, let assets = o["assets"] as? [[String: Any]] else {
                self.state = .failed(L("VOICEVOX の最新版を調べられませんでした。インターネットにつながっているか確かめてください。"))
                return
            }
            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "x64"
            #endif
            let name = "voicevox-macos-cpu-\(arch)-\(tag).zip"
            guard let asset = assets.first(where: { ($0["name"] as? String) == name }),
                  let s = asset["browser_download_url"] as? String, let url = URL(string: s) else {
                self.state = .failed(L("この Mac 用の VOICEVOX が見つかりませんでした ({0})。", name))
                return
            }
            self.expectedVersion = tag
            DispatchQueue.main.async { self.download(url) }
        }.resume()
    }

    private func download(_ url: URL) {
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        session = s
        let t = s.downloadTask(with: url)
        task = t
        t.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        state = Self.info != nil ? .installed : .notInstalled
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        state = .downloading(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 渡された一時ファイルはこの関数を抜けると消えるので、すぐ移す
        let fm = FileManager.default
        let zip = fm.temporaryDirectory.appendingPathComponent("voicevox-\(UUID().uuidString).zip")
        do {
            try fm.moveItem(at: location, to: zip)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        state = .extracting
        let version = expectedVersion
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.extract(zip, version: version)
            try? fm.removeItem(at: zip)
            DispatchQueue.main.async {
                switch result {
                case .success: self.state = .installed
                case .failure(let e): self.state = .failed(e.localizedDescription)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error as NSError?, e.code != NSURLErrorCancelled { state = .failed(e.localizedDescription) }
        self.task = nil
        session.finishTasksAndInvalidate()
        self.session = nil
    }

    /// zip を展開して、中のエンジン (…/vv-engine/run) を探す
    private static func extract(_ zip: URL, version: String) -> Result<Void, Error> {
        let fm = FileManager.default
        let dest = root.appendingPathComponent(version, isDirectory: true)
        let work = root.appendingPathComponent(".work", isDirectory: true)
        try? fm.removeItem(at: work)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", zip.path, work.path]
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw NSError(domain: "VOICEVOX", code: 1, userInfo: [NSLocalizedDescriptionKey: L("展開に失敗しました")]) }
            guard let engine = findEngine(in: work) else {
                throw NSError(domain: "VOICEVOX", code: 2, userInfo: [NSLocalizedDescriptionKey: L("配布物の中にエンジンが見つかりませんでした")])
            }
            // 前の版は消して、新しい版を置く
            for old in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where old.lastPathComponent != ".work" {
                try? fm.removeItem(at: old)
            }
            try fm.moveItem(at: work, to: dest)
            let enginePath = dest.path + engine.path.dropFirst(work.path.count)
            let data = try JSONEncoder().encode(Info(version: version, engine: enginePath))
            try data.write(to: infoURL)
            return .success(())
        } catch {
            try? fm.removeItem(at: work)
            return .failure(error)
        }
    }

    private static func findEngine(in dir: URL) -> URL? {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        var fallback: URL?
        for case let u as URL in e where u.lastPathComponent == "run" && FileManager.default.isExecutableFile(atPath: u.path) {
            if u.deletingLastPathComponent().lastPathComponent == "vv-engine" { return u }
            if fallback == nil { fallback = u }
        }
        return fallback
    }

    // MARK: ON / OFF

    /// 入れたエンジンを、画面を出さずに動かす (すでに動いていれば何もしない)
    @discardableResult
    func startEngine() -> Bool {
        if isEngineRunning { return true }
        guard let info = Self.info else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: info.engine)
        let port = URLComponents(string: ReadingSettings.vvURL)?.port ?? 50021
        p.arguments = ["--host", "127.0.0.1", "--port", String(port)]
        p.currentDirectoryURL = URL(fileURLWithPath: info.engine).deletingLastPathComponent()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.onChange?() } }
        do { try p.run() } catch { return false }
        engine = p
        onChange?()
        return true
    }

    func stopEngine() {
        engine?.terminate()
        engine = nil
        onChange?()
    }

    // MARK: 削除

    func uninstall() {
        stopEngine()
        try? FileManager.default.removeItem(at: Self.root)
        state = .notInstalled
    }
}
