import AppKit
import HinokiCore

final class Document: NSDocument {
    var text = ""
    // 新規ファイルは「動作環境」の設定、開いたファイルは中身から判定した値になる
    var encoding: TextEncoding = Prefs.defaultEncoding
    var lineEnding: LineEnding = Prefs.defaultLineEnding

    override class var autosavesInPlace: Bool { false }
    override class var readableTypes: [String] { [DocumentController.textType] }
    override class var writableTypes: [String] { [DocumentController.textType] }
    override class func isNativeType(_ type: String) -> Bool { true }

    var editor: EditorWindowController? { windowControllers.first as? EditorWindowController }

    /// 暗号化して保存する文書の鍵 (パスワードから作ったもの。メモリの中だけに持つ)
    var encryptionKey: FileCrypto.Key? {
        didSet { editor?.encryptionChanged() }
    }
    var isEncrypted: Bool { encryptionKey != nil }
    /// 流出防止がオンのとき、この文書は「そのまま保存」を選んだ (保存のたびに聞かないため)
    var plainSaveChosen = false

    /// 設定ファイルは暗号化しない (アプリ自身が読めなくなるので)
    private func isSettingsFile(_ url: URL?) -> Bool {
        guard let u = url?.standardizedFileURL else { return false }
        return u == Theme.userFileURL.standardizedFileURL || u == ProfileStore.userFileURL.standardizedFileURL
    }

    /// サーバから開いたファイル (保存したらサーバへ送る)
    struct RemoteOrigin {
        let server: RemoteServer
        let path: String
    }

    var remote: RemoteOrigin? {
        didSet {
            if let r = remote { displayName = "\((r.path as NSString).lastPathComponent) — \(r.server.displayName)" }
        }
    }

    private var uploading = false
    private var uploadAgain = false

    /// 手元に保存したファイルをサーバへ送る (送信中にまた保存されたら終わってからもう一度)
    private func uploadToServer() {
        guard let r = remote, let url = fileURL else { return }
        if uploading { uploadAgain = true; return }
        uploading = true
        editor?.remoteStatusChanged("↑ \(r.server.displayName) に送信中…")
        RemoteClient(server: r.server).upload(url, to: r.path) { [weak self] result in
            guard let self = self else { return }
            self.uploading = false
            switch result {
            case .success:
                let f = DateFormatter()
                f.dateFormat = "HH:mm:ss"
                self.editor?.remoteStatusChanged("✓ \(r.server.displayName) に反映 \(f.string(from: Date()))")
            case .failure(let e):
                self.editor?.remoteStatusChanged("✗ サーバへの送信に失敗")
                let alert = NSAlert()
                alert.messageText = "\(r.path) をサーバに送れませんでした"
                alert.informativeText = e.localizedDescription + "\n\n手元には保存済み。もう一度保存で送り直します。"
                if let w = self.editor?.window { alert.beginSheetModal(for: w) } else { alert.runModal() }
            }
            if self.uploadAgain {
                self.uploadAgain = false
                self.uploadToServer()
            }
        }
    }

    override var fileURL: URL? {
        didSet { editor?.fileURLDidChange() }
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        // 「常に暗号化」なら、まだ鍵のない文書はここでパスワードを決めてもらう
        if Prefs.bool("encryptAlways"), encryptionKey == nil, !isSettingsFile(url) {
            guard let key = PasswordPrompt.createKey(for: url.lastPathComponent) else {
                completionHandler(CocoaError(.userCancelled))
                return
            }
            encryptionKey = key
        }
        // 流出防止がオンなら、暗号化していない文書はどちらで保存するか聞く。
        // 同じ文書で保存のたびに聞かないよう、答えは開いている間おぼえておく (別名で保存のときは聞き直す)
        let asksHowToSave = saveOperation == .saveOperation || saveOperation == .saveAsOperation
        if EditorExtension.encryption.isOn, encryptionKey == nil, !isSettingsFile(url), asksHowToSave,
           editor?.collabSession?.isActive != true,
           !plainSaveChosen || saveOperation == .saveAsOperation {
            let alert = NSAlert()
            alert.messageText = "「\(url.lastPathComponent)」をどちらで保存しますか？"
            alert.informativeText = "暗号化すると、鍵を持つ本人しか開けません。\nこの文書では、次の保存からは聞きません。"
            alert.addButton(withTitle: "暗号化して保存")
            alert.addButton(withTitle: "そのまま保存")
            alert.addButton(withTitle: "キャンセル")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard let key = PasswordPrompt.createKey(for: url.lastPathComponent) else {
                    completionHandler(CocoaError(.userCancelled))
                    return
                }
                encryptionKey = key
            case .alertSecondButtonReturn:
                plainSaveChosen = true
            default:
                completionHandler(CocoaError(.userCancelled))
                return
            }
        }
        if Prefs.bool("backupOnSave"), saveOperation == .saveOperation {
            makeBackup(of: url)
        }
        if Prefs.bool("trimTrailingOnSave") {
            editor?.textView.trimTrailingSpacesHM(nil)
        }
        super.save(to: url, ofType: typeName, for: saveOperation) { error in
            // プロファイル設定ファイルを保存したら即反映
            if error == nil && url.standardizedFileURL == ProfileStore.userFileURL.standardizedFileURL {
                Profiles.reload()
            }
            if error == nil && url.standardizedFileURL == Theme.userFileURL.standardizedFileURL {
                Theme.reload()
            }
            if error == nil {
                self.editor?.savePaperAlignments()
                self.editor?.savePaperPDFIfNeeded(textURL: url)
            }
            if error == nil && self.remote != nil && saveOperation == .saveOperation {
                self.uploadToServer()
            }
            completionHandler(error)
        }
    }

    /// 上書き前のファイルを「ファイル名.bak」にコピーしておく
    private func makeBackup(of url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        // 暗号化する文書なのに元のファイルが平文なら、平文のバックアップを残さない
        if isEncrypted {
            let head = (try? FileHandle(forReadingFrom: url).readData(ofLength: FileCrypto.magic.count + 1)) ?? Data()
            guard FileCrypto.isEncrypted(head) else { return }
        }
        let bak = url.appendingPathExtension("bak")
        try? fm.removeItem(at: bak)
        do {
            try fm.copyItem(at: url, to: bak)
        } catch {
            NSLog("バックアップを作れませんでした: \(error)")
        }
    }

    override func makeWindowControllers() {
        addWindowController(EditorWindowController(document: self))
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard FileCrypto.isEncrypted(data) else {
            encryptionKey = nil
            apply(try TextCodec.decode(data))
            return
        }
        let unlocked = try PasswordPrompt.unlock(data, name: fileURL?.lastPathComponent ?? "このファイル")
        // 中身: 1 行目に文字コードと改行コード、その後ろに本文
        let plain = unlocked.plain
        let nl = plain.firstIndex(of: 0x0A) ?? plain.endIndex
        let meta = (try? JSONSerialization.jsonObject(with: plain[plain.startIndex..<nl])) as? [String: String] ?? [:]
        let body = nl < plain.endIndex ? plain[plain.index(after: nl)...] : Data()
        let enc = TextEncoding(rawValue: meta["e"] ?? "") ?? .utf8
        var decoded = try TextCodec.decode(Data(body), as: enc)
        if let le = LineEnding(rawValue: meta["l"] ?? "") { decoded.lineEnding = le }
        encryptionKey = unlocked.key
        apply(decoded)
    }

    func apply(_ decoded: DecodedText) {
        text = decoded.text
        encoding = decoded.encoding
        lineEnding = decoded.lineEnding
        editor?.reloadFromDocument()
    }

    override func data(ofType typeName: String) throws -> Data {
        if let tv = editor?.textView { text = tv.string }
        let body = try TextCodec.encode(text, encoding: encoding, lineEnding: lineEnding)
        guard let key = encryptionKey else { return body }
        // 暗号化: 平文はディスクに一切書かない
        var payload = Data("{\"e\":\"\(encoding.rawValue)\",\"l\":\"\(lineEnding.rawValue)\"}\n".utf8)
        payload.append(body)
        return try FileCrypto.seal(payload, with: key)
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowsOtherFileTypes = true
        savePanel.isExtensionHidden = false
        return true
    }
}
