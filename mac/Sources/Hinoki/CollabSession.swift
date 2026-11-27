import AppKit
import Network
import HinokiCore

/// 共同編集でやりとりする 1 本の TCP 接続。
/// メッセージは JSON を共有コードの鍵で暗号化し、base64 にして 1 行ずつ送る。
final class CollabPeer {
    let connection: NWConnection
    private let cipher: CollabCipher
    /// 1 通でも正しく復号できたか (できないまま切れたら共有コード違いの可能性が高い)
    private(set) var decryptedAny = false
    private(set) var decryptFailed = false
    var id = -1
    var name = ""
    var approved = false
    private var buffer = Data()
    var onMessage: (([String: Any]) -> Void)?
    var onClose: (() -> Void)?
    private var closed = false

    init(_ connection: NWConnection, cipher: CollabCipher) {
        self.connection = connection
        self.cipher = cipher
    }

    var remoteAddress: String {
        if case let .hostPort(host, _) = connection.endpoint { return "\(host)" }
        return "\(connection.endpoint)"
    }

    func start(onReady: (() -> Void)? = nil) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: onReady?()
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        connection.start(queue: .main)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.buffer.append(data)
                while let nl = self.buffer.firstIndex(of: 0x0A) {
                    let line = self.buffer[self.buffer.startIndex..<nl]
                    self.buffer.removeSubrange(self.buffer.startIndex...nl)
                    // 鍵が違う・改ざん・順番違いなら、その場で切る
                    guard let plain = self.cipher.open(Data(line)),
                          let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
                        self.decryptFailed = true
                        self.cancel()
                        return
                    }
                    self.decryptedAny = true
                    self.onMessage?(obj)
                }
                // 1 行が大きすぎるものは捨てる (64MB)
                if self.buffer.count > 64 << 20 { self.cancel() }
            }
            if isComplete || error != nil {
                self.finish()
            } else {
                self.receive()
            }
        }
    }

    func send(_ message: [String: Any]) {
        guard !closed, let plain = try? JSONSerialization.data(withJSONObject: message),
              var data = try? cipher.seal(plain) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func cancel() {
        connection.cancel()
        finish()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        onClose?()
    }
}

/// 参加者 (自分を含む)
struct CollabUser {
    let id: Int
    let name: String
    var color: NSColor { CollabSession.color(for: id) }
}

/// 1 つの文書の共同編集。共有する側 (ホスト) と参加する側 (ゲスト) の両方をこれで扱う。
final class CollabSession {
    enum Role { case host, guest }

    static let defaultPort: UInt16 = 7650
    static let protocolVersion = 1

    let role: Role
    private(set) var myID: Int
    let myName: String
    private(set) var users: [Int: CollabUser] = [:]
    private(set) var cursors: [Int: (loc: Int, len: Int)] = [:]
    private(set) var isActive = true
    private(set) var port: UInt16 = 0
    /// 共有コード (共有を始めるたびに新しく作る。暗号の鍵の元)
    let code: String

    weak var editor: EditorWindowController?
    private var storageObserver: Any?
    private var applyingRemote = false

    // ホスト
    private var listener: NWListener?
    private var peers: [CollabPeer] = []
    private let server = OTServer()
    private var nextID = 1
    private var pendingApprovals: [CollabPeer] = []
    private var approvalShowing = false

    // ゲスト
    private var hostPeer: CollabPeer?
    private var client: OTClient?
    /// 承認されて最初の状態が届いたとき (文章, 題名)
    var onWelcome: ((String, String) -> Void)?
    var onJoinFailed: ((String) -> Void)?

    static let palette: [NSColor] = [
        NSColor(srgbRed: 0.95, green: 0.45, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.70, blue: 0.95, alpha: 1),
        NSColor(srgbRed: 0.55, green: 0.85, blue: 0.30, alpha: 1),
        NSColor(srgbRed: 0.90, green: 0.35, blue: 0.75, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.80, blue: 0.20, alpha: 1),
        NSColor(srgbRed: 0.60, green: 0.50, blue: 0.95, alpha: 1),
    ]

    static func color(for id: Int) -> NSColor { palette[abs(id) % palette.count] }

    /// 動作確認用: 承認の確認を出さずに受け入れる (アプリ本体では使わない)
    static var approvesAutomaticallyForTesting = false

    static var computerName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private init(role: Role, name: String, code: String) {
        self.role = role
        self.myName = name
        self.code = code
        self.myID = role == .host ? 0 : -1
    }

    // MARK: 共有を始める (ホスト)

    static func host(editor: EditorWindowController, name: String, port: UInt16) throws -> CollabSession {
        let s = CollabSession(role: .host, name: name, code: CollabCipher.newCode())
        s.users[0] = CollabUser(id: 0, name: name)
        guard let p = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "Satoru", code: 10, userInfo: [NSLocalizedDescriptionKey: L("ポート番号が正しくありません")])
        }
        let listener = try NWListener(using: .tcp, on: p)
        s.listener = listener
        s.port = port
        listener.newConnectionHandler = { [weak s] conn in s?.incoming(conn) }
        listener.stateUpdateHandler = { [weak s] state in
            if case let .failed(error) = state {
                s?.system(L("共有を始められませんでした: {0}", error.localizedDescription))
                s?.stop()
            }
        }
        listener.start(queue: .main)
        s.attach(editor)
        return s
    }

    private func incoming(_ conn: NWConnection) {
        let peer = CollabPeer(conn, cipher: CollabCipher(code: code, isHost: true))
        peers.append(peer)
        peer.onMessage = { [weak self, weak peer] msg in
            guard let self = self, let peer = peer else { return }
            self.hostReceive(msg, from: peer)
        }
        peer.onClose = { [weak self, weak peer] in
            guard let self = self, let peer = peer else { return }
            self.peerLeft(peer)
        }
        peer.start()
    }

    private func hostReceive(_ msg: [String: Any], from peer: CollabPeer) {
        let type = msg["t"] as? String ?? ""
        if !peer.approved {
            guard type == "hello", peer.id == -1 else { return }
            peer.name = String((msg["name"] as? String ?? L("名無し")).prefix(40))
            peer.id = -2 // 承認待ち
            pendingApprovals.append(peer)
            showNextApproval()
            return
        }
        switch type {
        case "op":
            guard let op = op(from: msg), let base = msg["rev"] as? Int else { return }
            let r = server.receive(op, baseRevision: base)
            applyRemote(r.op, author: peer.id)
            broadcast(["t": "op", "rev": r.revision, "author": peer.id, "loc": r.op.loc, "len": r.op.len, "text": r.op.text])
        case "cursor":
            guard let loc = msg["loc"] as? Int, let len = msg["len"] as? Int else { return }
            cursors[peer.id] = (loc, len)
            editor?.collabCursorsChanged()
            broadcast(["t": "cursor", "author": peer.id, "loc": loc, "len": len], except: peer)
        case "chat":
            guard let text = msg["text"] as? String else { return }
            let clipped = String(text.prefix(2000))
            editor?.collabChat(from: users[peer.id], text: clipped)
            broadcast(["t": "chat", "author": peer.id, "text": clipped], except: peer)
        case "bye":
            peer.cancel()
        default:
            break
        }
    }

    /// 参加の承認 (1 人ずつ確認する)
    private func showNextApproval() {
        guard !approvalShowing, !pendingApprovals.isEmpty else { return }
        let peer = pendingApprovals.removeFirst()
        if Self.approvesAutomaticallyForTesting {
            approve(peer)
            showNextApproval()
            return
        }
        guard peers.contains(where: { $0 === peer }) else { showNextApproval(); return }
        approvalShowing = true
        let alert = NSAlert()
        alert.messageText = L("「{0}」が共同編集に参加しようとしています", peer.name)
        alert.informativeText = L("接続元: {0}\n承認すると、この文書が相手に見えます。", peer.remoteAddress)
        alert.addButton(withTitle: L("承認する"))
        alert.addButton(withTitle: L("断る"))
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self = self else { return }
            self.approvalShowing = false
            if response == .alertFirstButtonReturn, self.isActive {
                self.approve(peer)
            } else {
                peer.send(["t": "reject", "reason": L("ホストが参加を断りました")])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { peer.cancel() }
            }
            self.showNextApproval()
        }
        NSApp.requestUserAttention(.criticalRequest)
        if let w = editor?.presentingWindow {
            alert.beginSheetModal(for: w, completionHandler: done)
        } else {
            done(alert.runModal())
        }
    }

    private func approve(_ peer: CollabPeer) {
        peer.id = nextID
        nextID += 1
        peer.approved = true
        users[peer.id] = CollabUser(id: peer.id, name: peer.name)
        let text = editor?.collabText ?? ""
        peer.send([
            "t": "welcome", "v": Self.protocolVersion, "id": peer.id, "rev": server.revision,
            "text": text, "title": editor?.collabTitle ?? "",
            "users": users.values.map { ["id": $0.id, "name": $0.name] },
            "cursors": cursors.map { ["author": $0.key, "loc": $0.value.loc, "len": $0.value.len] },
        ])
        broadcast(["t": "join", "id": peer.id, "name": peer.name], except: peer)
        system(L("{0} さんが参加しました (いま {1} 人)", peer.name, users.count))
        editor?.collabUsersChanged()
        sendMyCursor()
    }

    private func peerLeft(_ peer: CollabPeer) {
        peers.removeAll { $0 === peer }
        pendingApprovals.removeAll { $0 === peer }
        guard peer.approved, isActive else { return }
        users.removeValue(forKey: peer.id)
        cursors.removeValue(forKey: peer.id)
        broadcast(["t": "leave", "id": peer.id])
        system(L("{0} さんが抜けました (いま {1} 人)", peer.name, users.count))
        editor?.collabUsersChanged()
        editor?.collabCursorsChanged()
    }

    private func broadcast(_ msg: [String: Any], except: CollabPeer? = nil) {
        for p in peers where p.approved && p !== except { p.send(msg) }
    }

    // MARK: 参加する (ゲスト)

    static func join(host: String, port: UInt16, name: String, code: String) -> CollabSession {
        let s = CollabSession(role: .guest, name: name, code: code)
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 7650, using: .tcp)
        let peer = CollabPeer(conn, cipher: CollabCipher(code: code, isHost: false))
        s.hostPeer = peer
        peer.onMessage = { [weak s] msg in s?.guestReceive(msg) }
        peer.onClose = { [weak s] in s?.hostGone() }
        peer.start { [weak s, weak peer] in
            peer?.send(["t": "hello", "v": protocolVersion, "name": name])
            _ = s
        }
        return s
    }

    private func guestReceive(_ msg: [String: Any]) {
        switch msg["t"] as? String ?? "" {
        case "welcome":
            guard client == nil, let id = msg["id"] as? Int, let rev = msg["rev"] as? Int else { return }
            myID = id
            client = OTClient(revision: rev)
            for u in msg["users"] as? [[String: Any]] ?? [] {
                if let uid = u["id"] as? Int, let n = u["name"] as? String { users[uid] = CollabUser(id: uid, name: n) }
            }
            for c in msg["cursors"] as? [[String: Any]] ?? [] {
                if let a = c["author"] as? Int, let l = c["loc"] as? Int, let n = c["len"] as? Int { cursors[a] = (l, n) }
            }
            onWelcome?(msg["text"] as? String ?? "", msg["title"] as? String ?? "")
        case "reject":
            onJoinFailed?(msg["reason"] as? String ?? L("参加できませんでした"))
            onJoinFailed = nil
            isActive = false
            hostPeer?.cancel()
        case "op":
            guard let client = client, let op = op(from: msg), let rev = msg["rev"] as? Int, let author = msg["author"] as? Int else { return }
            if author == myID {
                if let next = client.acknowledged(revision: rev) { sendOp(next.op, base: next.baseRevision) }
            } else {
                applyRemote(client.remote(op, revision: rev), author: author)
            }
        case "cursor":
            guard let a = msg["author"] as? Int, let l = msg["loc"] as? Int, let n = msg["len"] as? Int, a != myID else { return }
            cursors[a] = (l, n)
            editor?.collabCursorsChanged()
        case "chat":
            guard let a = msg["author"] as? Int, let text = msg["text"] as? String else { return }
            editor?.collabChat(from: users[a], text: text)
        case "join":
            guard let id = msg["id"] as? Int, let n = msg["name"] as? String else { return }
            users[id] = CollabUser(id: id, name: n)
            system(L("{0} さんが参加しました (いま {1} 人)", n, users.count))
            editor?.collabUsersChanged()
        case "leave":
            guard let id = msg["id"] as? Int else { return }
            let n = users[id]?.name ?? L("だれか")
            users.removeValue(forKey: id)
            cursors.removeValue(forKey: id)
            system(L("{0} さんが抜けました (いま {1} 人)", n, users.count))
            editor?.collabUsersChanged()
            editor?.collabCursorsChanged()
        case "bye":
            hostPeer?.cancel()
        default:
            break
        }
    }

    private func hostGone() {
        guard isActive else { return }
        if client == nil {
            let codeProblem = hostPeer.map { !$0.decryptedAny } ?? false
            onJoinFailed?(codeProblem
                ? L("つながりません。アドレスとコードを確認してください。")
                : L("つながりません。アドレスを確認してください。"))
            onJoinFailed = nil
        } else {
            system(L("接続が切れました。"))
        }
        isActive = false
        users = users.filter { $0.key == myID }
        cursors = [:]
        editor?.collabUsersChanged()
        editor?.collabCursorsChanged()
    }

    private func sendOp(_ op: TextOp, base: Int) {
        hostPeer?.send(["t": "op", "rev": base, "loc": op.loc, "len": op.len, "text": op.text])
    }

    // MARK: 文書との結び付け

    func attach(_ editor: EditorWindowController) {
        self.editor = editor
        if let storage = editor.collabStorage {
            storageObserver = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
            ) { [weak self] note in
                self?.storageEdited(note.object as? NSTextStorage)
            }
        }
        editor.collabUsersChanged()
        editor.collabCursorsChanged()
        sendMyCursor()
    }

    /// 自分の編集を捕まえて送る
    private func storageEdited(_ storage: NSTextStorage?) {
        guard isActive, !applyingRemote, let storage = storage, storage.editedMask.contains(.editedCharacters) else { return }
        let r = storage.editedRange
        let oldLen = r.length - storage.changeInLength
        guard r.location != NSNotFound, oldLen >= 0 else { return }
        let op = TextOp(loc: r.location, len: oldLen, text: (storage.string as NSString).substring(with: r))
        shiftCursors(by: op)
        switch role {
        case .host:
            let rev = server.localEdit(op)
            broadcast(["t": "op", "rev": rev, "author": 0, "loc": op.loc, "len": op.len, "text": op.text])
        case .guest:
            if let send = client?.localEdit(op) { sendOp(send.op, base: send.baseRevision) }
        }
    }

    private func applyRemote(_ op: TextOp, author: Int) {
        guard !op.isNoop else { return }
        applyingRemote = true
        editor?.collabApply(op)
        applyingRemote = false
        shiftCursors(by: op)
        editor?.collabCursorsChanged()
    }

    /// 変更に合わせてほかの人のカーソル位置もずらす
    private func shiftCursors(by op: TextOp) {
        for (id, c) in cursors {
            let s = op.transformPosition(c.loc)
            let e = op.transformPosition(c.loc + c.len)
            cursors[id] = (s, max(0, e - s))
        }
    }

    private var cursorWork: DispatchWorkItem?

    /// 自分のカーソルが動いた (少しまとめて送る)
    func localSelectionChanged() {
        guard isActive else { return }
        cursorWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.sendMyCursor() }
        cursorWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: w)
    }

    private func sendMyCursor() {
        guard isActive, let sel = editor?.textView.selectedRange() else { return }
        let msg: [String: Any] = ["t": "cursor", "author": myID, "loc": sel.location, "len": sel.length]
        switch role {
        case .host: broadcast(msg)
        case .guest: if client != nil { hostPeer?.send(msg) }
        }
    }

    // MARK: チャット

    func sendChat(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        editor?.collabChat(from: users[myID] ?? CollabUser(id: myID, name: myName), text: t)
        guard isActive else { return }
        let msg: [String: Any] = ["t": "chat", "author": myID, "text": String(t.prefix(2000))]
        switch role {
        case .host: broadcast(msg)
        case .guest: hostPeer?.send(msg)
        }
    }

    private func system(_ text: String) {
        editor?.collabChat(from: nil, text: text)
    }

    // MARK: 終了

    func stop() {
        guard isActive else { return }
        switch role {
        case .host:
            broadcast(["t": "bye"])
            isActive = false
            listener?.cancel()
            let ps = peers
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ps.forEach { $0.cancel() } }
            peers = []
        case .guest:
            hostPeer?.send(["t": "bye"])
            isActive = false
            let p = hostPeer
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { p?.cancel() }
        }
        if let o = storageObserver { NotificationCenter.default.removeObserver(o) }
        storageObserver = nil
        users = users.filter { $0.key == myID }
        cursors = [:]
        editor?.collabUsersChanged()
        editor?.collabCursorsChanged()
    }

    /// 参加の取りやめ (承認待ちの途中)
    func cancelJoin() {
        isActive = false
        onJoinFailed = nil
        hostPeer?.cancel()
    }

    private func op(from msg: [String: Any]) -> TextOp? {
        guard let loc = msg["loc"] as? Int, let len = msg["len"] as? Int, let text = msg["text"] as? String,
              loc >= 0, len >= 0 else { return nil }
        return TextOp(loc: loc, len: len, text: text)
    }

    // MARK: この Mac のアドレス

    /// インターネット側から見たこの Mac の IP (グローバル IP)。Mac 自身では分からないので、外のサービスに聞く。
    /// 1 つ目に答えてもらえなければ 2 つ目へ。取れなければ nil
    static func publicAddress(_ done: @escaping (String?) -> Void) {
        let services = ["https://api.ipify.org", "https://ipv4.icanhazip.com"]
        func attempt(_ i: Int) {
            guard i < services.count, let url = URL(string: services[i]) else { DispatchQueue.main.async { done(nil) }; return }
            var req = URLRequest(url: url, timeoutInterval: 6)
            req.setValue("satoruEditor", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                let text = data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if (resp as? HTTPURLResponse)?.statusCode == 200, isIPv4(text) {
                    DispatchQueue.main.async { done(text) }
                } else {
                    attempt(i + 1)
                }
            }.resume()
        }
        attempt(0)
    }

    /// "203.0.113.5" のような IPv4 の形か (サービスの答えをそのまま信じない)
    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in p.count <= 3 && !p.isEmpty && p.allSatisfy(\.isNumber) && (Int(p) ?? 999) <= 255 }
    }

    static func localAddresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let flags = Int32(cur.pointee.ifa_flags)
            if let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let s = String(cString: host)
                    if !s.hasPrefix("169.254.") { result.append(s) }
                }
            }
            p = cur.pointee.ifa_next
        }
        return result
    }
}

/// 「共同編集」をオンにする前の説明と確認 (図つき)
enum CollabConsent {
    /// 説明を読んで「わかりました」にチェックしたときだけ true
    static func confirmEnable() -> Bool {
        let alert = NSAlert()
        alert.messageText = L("共同編集のしくみ")
        alert.informativeText = ""

        let diagram = CollabDiagramView(frame: NSRect(x: 0, y: 0, width: 480, height: 210))
        let text = NSTextField(wrappingLabelWithString: L("注意\n・承認した相手には、文書がすべて見えます。\n・承認は、信頼できる相手だけに。\n・使い終わったら「共有を終了」。"))
        text.font = .systemFont(ofSize: 12)
        text.preferredMaxLayoutWidth = 470
        let check = NSButton(checkboxWithTitle: L("わかりました"), target: nil, action: nil)

        let stack = NSStackView(views: [diagram, text, check])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        diagram.widthAnchor.constraint(equalToConstant: 480).isActive = true
        diagram.heightAnchor.constraint(equalToConstant: 210).isActive = true
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        alert.accessoryView = stack

        alert.addButton(withTitle: L("オンにする"))
        alert.addButton(withTitle: L("やめる"))
        let ok = alert.buttons[0]
        ok.isEnabled = false
        let watcher = CheckWatcher { ok.isEnabled = check.state == .on }
        check.target = watcher
        check.action = #selector(CheckWatcher.changed(_:))
        let response = alert.runModal()
        _ = watcher
        return response == .alertFirstButtonReturn && check.state == .on
    }

    private final class CheckWatcher: NSObject {
        let onChange: () -> Void
        init(_ onChange: @escaping () -> Void) { self.onChange = onChange }
        @objc func changed(_ sender: Any?) { onChange() }
    }
}

/// 共同編集のしくみの図
///   [あなたの Mac] ── ① アドレスとコードを伝える ──▶ [相手の Mac]
///                ◀── ② 参加を申し込む ──
///                ── ③ 承認すると文書が届く ──▶
///                ◀═ ④ 一緒に編集 (暗号化) ═▶
final class CollabDiagramView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let box = NSSize(width: 110, height: 150)
        let leftBox = NSRect(x: 4, y: 30, width: box.width, height: box.height)
        let rightBox = NSRect(x: bounds.width - box.width - 4, y: 30, width: box.width, height: box.height)

        func drawMac(_ r: NSRect, _ title: String, _ sub: String) {
            let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            accent.withAlphaComponent(0.10).setFill()
            path.fill()
            accent.setStroke()
            path.lineWidth = 1.5
            path.stroke()
            let center = NSMutableParagraphStyle()
            center.alignment = .center
            ("💻" as NSString).draw(in: NSRect(x: r.minX, y: r.minY + 22, width: r.width, height: 44),
                                   withAttributes: [.font: NSFont.systemFont(ofSize: 36), .paragraphStyle: center])
            (title as NSString).draw(in: NSRect(x: r.minX, y: r.minY + 76, width: r.width, height: 20),
                                     withAttributes: [.font: NSFont.boldSystemFont(ofSize: 13), .paragraphStyle: center, .foregroundColor: NSColor.labelColor])
            (sub as NSString).draw(in: NSRect(x: r.minX + 4, y: r.minY + 98, width: r.width - 8, height: 44),
                                   withAttributes: [.font: NSFont.systemFont(ofSize: 10), .paragraphStyle: center, .foregroundColor: NSColor.secondaryLabelColor])
        }
        drawMac(leftBox, L("あなた"), L("「共有する」を押す"))
        drawMac(rightBox, L("相手"), L("「参加」を押す"))

        let x0 = leftBox.maxX + 8, x1 = rightBox.minX - 8
        let steps: [(String, Bool, Bool)] = [
            (L("① アドレスとコードを伝える"), true, false),
            (L("② 相手が申し込む"), false, false),
            (L("③ 承認すると文書が届く"), true, false),
            (L("④ 一緒に編集・チャット"), true, true),
        ]
        for (i, step) in steps.enumerated() {
            let y = leftBox.minY + 22 + CGFloat(i) * 34
            let (label, toRight, both) = step
            let color = i == 3 ? NSColor.systemGreen : accent
            color.setStroke()
            color.setFill()
            let line = NSBezierPath()
            line.lineWidth = i == 3 ? 3 : 1.5
            line.move(to: NSPoint(x: x0, y: y))
            line.line(to: NSPoint(x: x1, y: y))
            line.stroke()
            func head(at x: CGFloat, pointingRight: Bool) {
                let d: CGFloat = pointingRight ? -1 : 1
                let p = NSBezierPath()
                p.move(to: NSPoint(x: x, y: y))
                p.line(to: NSPoint(x: x + 9 * d, y: y - 5))
                p.line(to: NSPoint(x: x + 9 * d, y: y + 5))
                p.close()
                p.fill()
            }
            if toRight || both { head(at: x1, pointingRight: true) }
            if !toRight || both { head(at: x0, pointingRight: false) }
            let center = NSMutableParagraphStyle()
            center.alignment = .center
            (label as NSString).draw(in: NSRect(x: x0, y: y - 17, width: x1 - x0, height: 15), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11), .paragraphStyle: center, .foregroundColor: NSColor.labelColor,
            ])
        }
        let note = L("🔒 コードを知らない人は入れません") as NSString
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        note.draw(in: NSRect(x: 0, y: leftBox.maxY + 8, width: bounds.width, height: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11), .paragraphStyle: center, .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }
}
