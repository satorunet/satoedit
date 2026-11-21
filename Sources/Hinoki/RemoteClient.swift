import Foundation

/// サーバ上のファイル・フォルダ 1 つ
struct RemoteEntry {
    let name: String
    let isDirectory: Bool
    let isLink: Bool
    let size: Int64
    let date: String
}

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

    /// 最初に開くフォルダ
    func home(_ done: @escaping (Result<String, Error>) -> Void) {
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

    func list(_ path: String, _ done: @escaping (Result<[RemoteEntry], Error>) -> Void) {
        let handle: (Result<String, Error>) -> Void = { r in
            done(r.map { Self.parseListing($0) })
        }
        switch server.kind {
        case .sftp: sftp(["cd \(quote(path))", "ls -la"], handle)
        case .ftp, .ftps: curl(url(path, directory: true), [], handle)
        }
    }

    func download(_ path: String, to local: URL, _ done: @escaping (Result<Void, Error>) -> Void) {
        try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        let handle: (Result<String, Error>) -> Void = { r in done(r.map { _ in () }) }
        switch server.kind {
        case .sftp: sftp(["get \(quote(path)) \(quote(local.path))"], handle)
        case .ftp, .ftps: curl(url(path, directory: false), ["-o", local.path], handle)
        }
    }

    func upload(_ local: URL, to path: String, _ done: @escaping (Result<Void, Error>) -> Void) {
        let handle: (Result<String, Error>) -> Void = { r in done(r.map { _ in () }) }
        switch server.kind {
        case .sftp: sftp(["put \(quote(local.path)) \(quote(path))"], handle)
        case .ftp, .ftps: curl(url(path, directory: false), ["-T", local.path], handle)
        }
    }

    // MARK: SFTP

    private func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static var controlDir: String {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".satomaru/ssh")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.path
    }

    private func sftp(_ commands: [String], _ done: @escaping (Result<String, Error>) -> Void) {
        var args = [
            "-b", "-",
            "-P", String(server.port),
            // sftp のバッチモードはパスワード入力を禁止するので、手伝い役を挟んで外す
            "-S", RemoteHelper.executablePath,
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
        if server.auth == .key && !server.keyPath.isEmpty {
            args += ["-i", (server.keyPath as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
        } else {
            args += ["-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password,keyboard-interactive"]
        }
        args.append("\(server.user)@\(server.host)")
        var env = ProcessInfo.processInfo.environment
        env[RemoteHelper.wrapKey] = "1"
        env["SSH_ASKPASS"] = RemoteHelper.executablePath
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["DISPLAY"] = env["DISPLAY"] ?? ":0"
        env[RemoteHelper.secretKey] = server.secret ?? ""
        let input = commands.joined(separator: "\n") + "\n"
        run("/usr/bin/sftp", args, input: input, env: env) { r in
            done(r.map { out in
                out.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.hasPrefix("sftp> ") }
                    .joined(separator: "\n")
            })
        }
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
            return "ログインできません。ユーザー名とパスワードを確認してください。\n\n\(err)"
        }
        if e.contains("host key verification failed") || e.contains("remote host identification has changed") {
            return "サーバの鍵が前と違うので止めました (なりすましの恐れ)。\n\n\(err)"
        }
        if e.contains("could not resolve") || e.contains("nodename nor servname") {
            return "サーバが見つかりません。\n\n\(err)"
        }
        if e.contains("timed out") || e.contains("timeout") {
            return "時間切れです。ホストとポートを確認してください。\n\n\(err)"
        }
        if e.contains("connection refused") || e.contains("couldn't connect") || e.contains("failed to connect") {
            return "接続を断られました。ポートを確認してください。\n\n\(err)"
        }
        if e.contains("login denied") || e.contains("access denied") || e.contains("530") {
            return "ログインできません。\n\n\(err)"
        }
        if e.contains("no such file") || e.contains("not found") || e.contains("550") {
            return "見つからないか、権限がありません。\n\n\(err)"
        }
        return err.isEmpty ? "エラーで終了しました (コード \(status))" : err
    }

    // MARK: 一覧の読み取り (ls -l の形式)

    static func parseListing(_ text: String) -> [RemoteEntry] {
        var result: [RemoteEntry] = []
        for raw in text.split(separator: "\n") {
            let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard let first = line.first, "-dlcbps".contains(first) else { continue }
            // 権限 リンク数 所有者 グループ サイズ 月 日 時刻 名前
            var fields: [String] = []
            var rest = Substring(line)
            for _ in 0..<8 {
                rest = rest.drop(while: { $0 == " " })
                guard let end = rest.firstIndex(of: " ") else { break }
                fields.append(String(rest[..<end]))
                rest = rest[end...]
            }
            guard fields.count == 8 else { continue }
            var name = String(rest.drop(while: { $0 == " " }))
            let isLink = first == "l"
            if isLink, let r = name.range(of: " -> ") { name = String(name[..<r.lowerBound]) }
            if name == "." || name == ".." || name.isEmpty { continue }
            result.append(RemoteEntry(name: name, isDirectory: first == "d", isLink: isLink,
                                      size: Int64(fields[4]) ?? 0, date: "\(fields[5]) \(fields[6]) \(fields[7])"))
        }
        return result.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
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
