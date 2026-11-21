import Foundation
import HinokiCore

struct RemoteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// SFTP / FTP のやりとり。どちらも macOS に入っているコマンド (sftp, curl) を使う。
/// 終わったら main スレッドで done を呼ぶ。
final class RemoteClient {
    let server: RemoteServer
    private let queue = DispatchQueue(label: "satoru.remote")

    init(server: RemoteServer) {
        self.server = server
    }

    // MARK: 公開する操作

    /// ログに残す (先頭にサーバ名)
    private func log(_ text: String, _ level: RemoteLog.Level = .info) {
        RemoteLog.add("[\(server.displayName)] " + text, level)
    }

    private func firstLine(_ e: Error) -> String {
        e.localizedDescription.components(separatedBy: "\n").first(where: { !$0.isEmpty }) ?? ""
    }

    /// 最初に開くフォルダ
    func home(_ done: @escaping (Result<String, Error>) -> Void) {
        let started = Date()
        log(L("接続しています: {0}", connectionText))
        let done: (Result<String, Error>) -> Void = { r in
            switch r {
            case .success(let p): self.log(L("接続しました ({0} 秒)。最初のフォルダ: {1}", RemoteLog.seconds(since: started), p), .success)
            case .failure(let e): self.log(L("接続できませんでした: {0}", self.firstLine(e)), .failure)
            }
            done(r)
        }
        if !server.initialPath.isEmpty {
            return DispatchQueue.main.async { done(.success(self.server.initialPath)) }
        }
        switch server.kind {
        case .sftp:
            sftp(["pwd"]) { r in
                done(r.flatMap { out in
                    for line in out.split(separator: "\n") where line.hasPrefix("Remote working directory: ") {
                        return .success(String(line.dropFirst("Remote working directory: ".count)))
                    }
                    return .success("/")
                })
            }
        case .ftp, .ftps:
            DispatchQueue.main.async { done(.success("/")) }
        }
    }

    /// 一覧。更新日時を秒まで取るため、まず細かい一覧を頼み (SFTP: SSH で ls、FTP: MLSD)、
    /// だめならふつうの一覧にする (そのときは分まで)
    func list(_ path: String, _ done: @escaping (Result<[RemoteEntry], Error>) -> Void) {
        let started = Date()
        log(L("一覧を読み込み中: {0}", path))
        let done: (Result<[RemoteEntry], Error>) -> Void = { r in
            switch r {
            case .success(let list):
                self.log(L("一覧: {0} ({1} 項目、{2} 秒)", path, list.count, RemoteLog.seconds(since: started)), .success)
            case .failure(let e):
                self.log(L("一覧を読めませんでした: {0} — {1}", path, self.firstLine(e)), .failure)
            }
            done(r)
        }
        /// ふつうの一覧。markIfWorks: 細かい一覧がだめでこちらが通ったら、このサーバは次からふつうの一覧だけにする
        let plain: (_ markIfWorks: Bool) -> Void = { markIfWorks in
            let handle: (Result<String, Error>) -> Void = { r in
                if markIfWorks, case .success = r { Self.noPreciseListing.insert(self.server.id) }
                done(r.map { Self.parseListing($0) })
            }
            switch self.server.kind {
            case .sftp: self.sftp(["cd \(self.quote(path))", "ls -la"], handle)
            case .ftp, .ftps: self.curl(self.url(path, directory: true), [], handle)
            }
        }
        if Self.noPreciseListing.contains(server.id) { return plain(false) }
        let precise: (Result<String, Error>) -> Void = { r in
            if case .success(let out) = r {
                let list = Self.parseListing(out)
                // 中身が読めたならそれを使う (ls は空のフォルダでも「.」「..」や total を出す)
                if !list.isEmpty || out.contains("total ") || out.contains("type=cdir") {
                    return done(.success(list))
                }
            }
            self.log(L("秒まで分かる一覧が使えないので、ふつうの一覧にします"))
            plain(true)
        }
        switch server.kind {
        case .sftp:
            // GNU ls (Linux) は秒つきの数字、BSD ls は -T で秒まで出す
            let p = shellQuote(path)
            ssh("cd \(p) && { LC_ALL=C ls -la --time-style=+%s 2>/dev/null || LC_ALL=C ls -laT; }", precise)
        case .ftp, .ftps:
            curl(url(path, directory: true), ["-X", "MLSD"], precise)
        }
    }

    /// 細かい一覧が使えなかったサーバ (アプリを終えるまで覚える)
    private static var noPreciseListing: Set<String> = []

    func download(_ path: String, to local: URL, _ done: @escaping (Result<Void, Error>) -> Void) {
        try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        let started = Date()
        log(L("受信中: {0}", path))
        let handle: (Result<String, Error>) -> Void = { r in
            switch r {
            case .success:
                let size = (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize).map {
                    ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "?"
                self.log(L("受信しました: {0} ({1}、{2} 秒)", path, size, RemoteLog.seconds(since: started)), .success)
            case .failure(let e):
                self.log(L("受信できませんでした: {0} — {1}", path, self.firstLine(e)), .failure)
            }
            done(r.map { _ in () })
        }
        switch server.kind {
        case .sftp: sftp(["get \(quote(path)) \(quote(local.path))"], handle)
        case .ftp, .ftps: curl(url(path, directory: false), ["-o", local.path], handle)
        }
    }

    func upload(_ local: URL, to path: String, _ done: @escaping (Result<Void, Error>) -> Void) {
        let started = Date()
        let size = (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize).map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "?"
        log(L("送信中: {0} ({1})", path, size))
        let handle: (Result<String, Error>) -> Void = { r in
            switch r {
            case .success: self.log(L("送信しました: {0} ({1} 秒)", path, RemoteLog.seconds(since: started)), .success)
            case .failure(let e): self.log(L("送信できませんでした: {0} — {1}", path, self.firstLine(e)), .failure)
            }
            done(r.map { _ in () })
        }
        switch server.kind {
        case .sftp: sftp(["put \(quote(local.path)) \(quote(path))"], handle)
        case .ftp, .ftps: curl(url(path, directory: false), ["-T", local.path], handle)
        }
    }

    /// ファイル 1 つの大きさと更新日時をサーバに聞く (見つからなければ nil)
    func stat(_ path: String, _ done: @escaping (RemoteEntry?) -> Void) {
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        // 親フォルダの一覧から探す (秒まで分かる一覧を使うため)
        list(parent.isEmpty ? "/" : parent) { r in
            guard case .success(let entries) = r else { return done(nil) }
            done(entries.first { $0.name == name })
        }
    }

    /// 「SFTP i@example.com:22」のような、つなぎ先の説明
    var connectionText: String {
        let proto = server.kind == .sftp ? "SFTP" : (server.kind == .ftps ? "FTPS" : "FTP")
        return "\(proto) \(server.user)@\(server.host):\(server.port)"
    }

    // MARK: SFTP

    private func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static var controlDir: String {
        let dir = AppPaths.file("ssh")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.path
    }

    private func sftp(_ commands: [String], _ done: @escaping (Result<String, Error>) -> Void) {
        var args = ["-b", "-", "-P", String(server.port),
                    // sftp のバッチモードはパスワード入力を禁止するので、手伝い役を挟んで外す
                    "-S", RemoteHelper.executablePath] + sshOptions + authOptions
        args.append("\(server.user)@\(server.host)")
        var env = askpassEnv
        env[RemoteHelper.wrapKey] = "1"
        let input = commands.joined(separator: "\n") + "\n"
        run("/usr/bin/sftp", args, input: input, env: env) { r in
            done(r.map { out in
                out.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.hasPrefix("sftp> ") }
                    .joined(separator: "\n")
            })
        }
    }

    /// sftp と ssh で共通の指定
    private var sshOptions: [String] {
        [
            "-o", "StrictHostKeyChecking=accept-new",
            // 新しく覚えたサーバの鍵はアプリ専用のファイルに書く (~/.ssh/known_hosts も読むだけ使う)
            "-o", "UserKnownHostsFile=\"\(Self.controlDir)/known_hosts\" \"~/.ssh/known_hosts\"",
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=30",
            "-o", "NumberOfPasswordPrompts=1",
            // 1 回つないだら 5 分間使い回す (毎回のログインを省く)
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(Self.controlDir)/%C",
            "-o", "ControlPersist=300",
        ]
    }

    private var authOptions: [String] {
        if server.auth == .key && !server.keyPath.isEmpty {
            return ["-i", (server.keyPath as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
        }
        return ["-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password,keyboard-interactive"]
    }

    /// パスワードを聞かれたら、アプリ本体がキーチェーンの値を答える
    private var askpassEnv: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = RemoteHelper.executablePath
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = env["DISPLAY"] ?? ":0"
        env[RemoteHelper.secretKey] = server.secret ?? ""
        return env
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// SSH でコマンドを 1 つ実行する (sftp と同じ接続を使い回す)
    private func ssh(_ command: String, _ done: @escaping (Result<String, Error>) -> Void) {
        let args = ["-p", String(server.port), "-T"] + sshOptions + authOptions + ["\(server.user)@\(server.host)", command]
        run("/usr/bin/ssh", args, input: "", env: askpassEnv, done)
    }

    // MARK: FTP

    private func url(_ path: String, directory: Bool) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#;")
        let scheme = server.kind == .sftp ? "sftp" : "ftp"
        let parts = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
        var u = "\(scheme)://\(server.host):\(server.port)/" + parts.joined(separator: "/")
        if directory && !u.hasSuffix("/") { u += "/" }
        return u
    }

    private func curl(_ url: String, _ extra: [String], _ done: @escaping (Result<String, Error>) -> Void) {
        var args = ["-s", "-S", "--connect-timeout", "15", "-K", "-"]
        if server.kind == .ftps { args.append("--ssl-reqd") }
        args += extra
        args.append(url)
        // パスワードはコマンドラインに出さず、標準入力の設定として渡す
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let config = "user = \"\(esc(server.user)):\(esc(server.secret ?? ""))\"\n"
        run("/usr/bin/curl", args, input: config, env: nil, done)
    }

    // MARK: コマンド実行

    private func run(_ exe: String, _ args: [String], input: String, env: [String: String]?,
                     _ done: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            if let env = env { p.environment = env }
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            p.standardInput = inPipe
            p.standardOutput = outPipe
            p.standardError = errPipe
            var result: Result<String, Error>
            do {
                try p.run()
                inPipe.fileHandleForWriting.write(Data(input.utf8))
                try? inPipe.fileHandleForWriting.close()
                // 先に読み切らないと大きな出力で止まる
                var outData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                let out = String(decoding: outData, as: UTF8.self)
                let err = String(decoding: errData, as: UTF8.self)
                    .split(separator: "\n").filter { !$0.hasPrefix("Warning: Permanently added") }
                    .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if p.terminationStatus == 0 {
                    result = .success(out)
                } else {
                    result = .failure(RemoteError(message: Self.explain(err, status: p.terminationStatus)))
                }
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { done(result) }
        }
    }

    /// よくあるエラーを日本語で
    private static func explain(_ err: String, status: Int32) -> String {
        let e = err.lowercased()
        if e.contains("permission denied") || e.contains("too many authentication failures") {
            return L("ログインできません。ユーザー名とパスワードを確認してください。\n\n{0}", err)
        }
        if e.contains("host key verification failed") || e.contains("remote host identification has changed") {
            return L("サーバの鍵が前と違うので止めました (なりすましの恐れ)。\n\n{0}", err)
        }
        if e.contains("could not resolve") || e.contains("nodename nor servname") {
            return L("サーバが見つかりません。\n\n{0}", err)
        }
        if e.contains("timed out") || e.contains("timeout") {
            return L("時間切れです。ホストとポートを確認してください。\n\n{0}", err)
        }
        if e.contains("connection refused") || e.contains("couldn't connect") || e.contains("failed to connect") {
            return L("接続を断られました。ポートを確認してください。\n\n{0}", err)
        }
        if e.contains("login denied") || e.contains("access denied") || e.contains("530") {
            return L("ログインできません。\n\n{0}", err)
        }
        if e.contains("no such file") || e.contains("not found") || e.contains("550") {
            return L("見つからないか、権限がありません。\n\n{0}", err)
        }
        return err.isEmpty ? L("エラーで終了しました (コード {0})", status) : err
    }

    static func parseListing(_ text: String) -> [RemoteEntry] { RemoteListing.parse(text) }
}

/// アプリ本体を SSH の手伝い役としても使う。
/// 1) sftp から ssh の代わりに呼ばれる → バッチモードの指定だけ外して本物の ssh を起動
/// 2) ssh からパスワードを聞かれる (SSH_ASKPASS) → キーチェーンから渡された値を答える
enum RemoteHelper {
    static let wrapKey = "SATORU_SSH_WRAP"
    static let secretKey = "SATORU_ASKPASS_SECRET"

    static var executablePath: String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    }

    static func runIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        if env[wrapKey] != nil {
            unsetenv(wrapKey)
            let args = CommandLine.arguments.dropFirst().filter { $0.lowercased() != "-obatchmode yes" }
            let argv = (["/usr/bin/ssh"] + args).map { strdup($0) } + [nil]
            execv("/usr/bin/ssh", argv)
            perror("ssh")
            exit(255)
        }
        if let secret = env[secretKey], env["SSH_ASKPASS"] != nil, CommandLine.arguments.count >= 2 {
            // 知らないサーバの確認 (yes/no) には答えない (accept-new で自動処理される)
            let prompt = CommandLine.arguments[1].lowercased()
            if prompt.contains("yes/no") { exit(1) }
            print(secret)
            exit(0)
        }
    }
}
