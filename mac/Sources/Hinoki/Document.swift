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

    /// 上書き保存で拡張子を変えない。
    /// どのファイルも「プレーンテキスト」として扱うので、何もしないと macOS が保存のときに
    /// index.html → index.txt、style.css → style.txt のように名前を変えてしまう
    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        if saveOperation != .saveAsOperation, let ext = fileURL?.pathExtension {
            return ext.isEmpty ? nil : ext
        }
        return super.fileNameExtension(forType: typeName, saveOperation: saveOperation)
    }

    var editor: EditorWindowController? { windowControllers.first as? EditorWindowController }

    /// 暗号化して保存する文書の鍵 (パスワードから作ったもの。メモリの中だけに持つ)
    var encryptionKey: FileCrypto.Key? {
        didSet { editor?.encryptionChanged() }
    }
    var isEncrypted: Bool { encryptionKey != nil }
    /// 巨大なファイルの一部分だけを読み込んでいるとき、その範囲 (保存すると、その部分だけを差し替える)
    var partial: PartialFile.Part? {
        didSet { editor?.encryptionChanged() }
    }
    /// 次に読み込むときの範囲 (「読み込む範囲を変える」用)
    var nextPart: (offset: UInt64, length: UInt64)?
    /// 保存で書き出した、一部分のバイト数 (保存が成功したら partial に反映する)
    private var writtenPartLength: UInt64?

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
            // 一時ファイルなので、次の起動で開き直さない
            if remote != nil { windowControllers.forEach { $0.window?.isRestorable = false } }
            // サーバのファイルを編集中は、サイドにサーバツリーを出す
            editor?.remoteDocumentChanged()
        }
    }

    /// タブを閉じたら、サーバから取ってきた一時ファイルを消す
    /// 開いてから書き換えたか (保存しても戻らない)。見るだけで開いたタブは、次に開くファイルで置き換える
    var touched = false
    /// このタブのまま別のファイルに入れ替えている最中
    private(set) var switchingFile = false

    /// 見ただけのタブを、そのまま別のファイルの中身に入れ替える (タブを閉じたり開いたりしない)。
    /// 暗号化したファイル・大きなファイルは、聞くことがあるので扱わない (false を返す → ふつうに開く)
    func switchContents(to url: URL) -> Bool {
        let head = (try? FileHandle(forReadingFrom: url))?.readData(ofLength: 16) ?? Data()
        let size = (try? PartialFile.fileSize(of: url)) ?? 0
        if FileCrypto.isEncrypted(head) || (HugeFile.thresholdMB > 0 && size >= UInt64(HugeFile.thresholdMB) * 1_048_576) { return false }
        guard let data = try? Data(contentsOf: url) else { return false }
        let old = fileURL
        editor?.saveCaretPosition()
        switchingFile = true
        defer { switchingFile = false }
        fileURL = url
        fileType = DocumentController.textType
        do {
            try read(from: data, ofType: DocumentController.textType)
        } catch {
            fileURL = old
            return false
        }
        fileModificationDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        updateChangeCount(.changeCleared)
        touched = false
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return true
    }

    /// 開いているファイルを削除したとき: タブ (ウインドウ) は閉じず、何も書いていない新しいテキストにする
    func becomeBlank() {
        editor?.saveCaretPosition()
        switchingFile = true
        defer { switchingFile = false }
        fileURL = nil
        fileType = DocumentController.textType
        try? read(from: Data(), ofType: DocumentController.textType)
        fileModificationDate = nil
        updateChangeCount(.changeCleared)
        touched = false
    }

    /// ⌘S で保存したところ (版をすぐ作る)
    private var userSaved = false
    /// 版の履歴の番号 (保存で拡張属性が消えても、付け直すため)
    private var versionID: String?

    /// 名前を付けて保存する前の「新規テキスト」の場所
    private var placeholderBeforeSave: URL?

    override func close() {
        // 閉じるときは、待っている版の記録をすぐ済ませる
        if let u = fileURL, partial == nil, encryptionKey == nil, !isDocumentEdited { VersionStore.noteSaved(u, now: true) }
        // 何も書かないまま閉じた「新規テキスト」は消す (一覧に空のカードを残さない)
        if TextLibrary.isBlankPlaceholder(fileURL), let u = fileURL,
           (editor?.textView.string ?? text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: u)
            TextLibrary.changed()
        }
        let temp = remote != nil ? fileURL : nil
        super.close()
        if let r = remote, RemoteDocuments.openDocument(server: r.server, path: r.path) == nil {
            // タブを閉じた: 「開き中」「編集中 (保存せずに閉じた)」の色は消す。送ったものは「更新済み」のまま
            switch RemoteDocuments.state(serverID: r.server.id, path: r.path) {
            case .opened?, .editing?: RemoteDocuments.clearState(server: r.server, path: r.path)
            default: break
            }
        }
        if uploading, let t = temp {
            RemoteDocuments.removeAfterUpload.insert(t.standardizedFileURL)
        } else {
            RemoteDocuments.removeTemp(temp)
        }
    }

    private var uploading = false
    private var uploadAgain = false

    /// 手元に保存したファイルをサーバへ送る (送信中にまた保存されたら終わってからもう一度)
    private func uploadToServer() {
        guard let r = remote, let url = fileURL else { return }
        if uploading { uploadAgain = true; return }
        uploading = true
        editor?.remoteStatusChanged(L("↑ {0} に送信中…", r.server.displayName))
        let client = RemoteClient(server: r.server)
        let started = Date()
        let window = editor?.window
        RemoteDocuments.setState(.uploading, server: r.server, path: r.path)
        Toast.show(in: window, key: "remote", kind: .progress, title: L("サーバへ送信中…"),
                   detail: L("接続: {0}", client.connectionText) + "\n" + r.path)
        client.upload(url, to: r.path) { [weak self] result in
            // 送信中にタブを閉じていたら、送り終えたここで一時ファイルを消す
            if RemoteDocuments.removeAfterUpload.remove(url.standardizedFileURL) != nil {
                RemoteDocuments.removeTemp(url)
            }
            guard let self = self else { return }
            self.uploading = false
            switch result {
            case .success:
                let f = DateFormatter()
                f.dateFormat = "HH:mm:ss"
                let now = Date()
                let secs = now.timeIntervalSince(started)
                self.editor?.remoteStatusChanged(L("✓ {0} に反映 {1}", r.server.displayName, f.string(from: now)))
                // 送った後のサーバ上の大きさ・日時を確かめて知らせる
                client.stat(r.path) { entry in
                    var lines = [L("接続: {0}", client.connectionText), r.path]
                    let info = RemoteDocuments.describe(entry)
                    if !info.isEmpty { lines.append(info) }
                    lines.append(L("{0} に送信 ({1} 秒)", f.string(from: now), String(format: "%.1f", secs)))
                    Toast.show(in: window, key: "remote", kind: .success,
                               title: L("サーバに保存しました"), detail: lines.joined(separator: "\n"))
                    // 送信のあいだにまた書き換えていたら「編集中」のまま
                    RemoteDocuments.setState(self.isDocumentEdited ? .editing : .uploaded(now), server: r.server, path: r.path)
                }
            case .failure(let e):
                self.editor?.remoteStatusChanged(L("✗ サーバへの送信に失敗"))
                RemoteDocuments.setState(.failed, server: r.server, path: r.path)
                Toast.show(in: window, key: "remote", kind: .failure, title: L("サーバに送れませんでした"),
                           detail: L("接続: {0}", client.connectionText) + "\n" + r.path + "\n"
                               + (e.localizedDescription.components(separatedBy: "\n").first ?? ""))
                let alert = NSAlert()
                alert.messageText = L("{0} をサーバに送れませんでした", r.path)
                alert.informativeText = e.localizedDescription + L("\n\n手元には保存済み。もう一度保存で送り直します。")
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

    /// サーバのファイルを書き換えたら、一覧・ツリーで「編集中」の色にする
    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        editor?.editedStateChanged()
        // メモ帳のように、書いたら自動で保存する (名前のない文書と「書類/さとるエディタ」の文書)
        if change != .changeCleared { touched = true; scheduleLibrarySave() }
        guard let r = remote, !uploading else { return }
        if isDocumentEdited {
            RemoteDocuments.setState(.editing, server: r.server, path: r.path)
        } else if RemoteDocuments.state(serverID: r.server.id, path: r.path) == .editing {
            // 取り消しで元に戻ったとき
            RemoteDocuments.setState(.opened, server: r.server, path: r.path)
        }
    }

    /// 保存したときの「編集済み」の解除も、タイトルの ＊ に反映する
    override func updateChangeCount(withToken changeCountToken: Any, for saveOperation: NSDocument.SaveOperationType) {
        super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        editor?.editedStateChanged()
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        // 「常に暗号化」なら、まだ鍵のない文書はここでパスワードを決めてもらう
        if Prefs.bool("encryptAlways"), encryptionKey == nil, !isSettingsFile(url), partial == nil {
            guard let key = PasswordPrompt.createKey(for: url.lastPathComponent) else {
                completionHandler(CocoaError(.userCancelled))
                return
            }
            encryptionKey = key
        }
        // 流出防止がオンなら、暗号化していない文書はどちらで保存するか聞く。
        // 同じ文書で保存のたびに聞かないよう、答えは開いている間おぼえておく (別名で保存のときは聞き直す)
        let asksHowToSave = saveOperation == .saveOperation || saveOperation == .saveAsOperation
        if EditorExtension.encryption.isOn, encryptionKey == nil, !isSettingsFile(url), asksHowToSave, partial == nil,
           editor?.collabSession?.isActive != true,
           !plainSaveChosen || saveOperation == .saveAsOperation {
            let alert = NSAlert()
            alert.messageText = L("「{0}」をどちらで保存しますか？", url.lastPathComponent)
            alert.informativeText = L("暗号化すると、鍵を持つ本人しか開けません。\nこの文書では、次の保存からは聞きません。")
            alert.addButton(withTitle: L("暗号化して保存"))
            alert.addButton(withTitle: L("そのまま保存"))
            alert.addButton(withTitle: L("キャンセル"))
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
        // 版の履歴の番号 (ファイルの見えない所に書いてある) を、保存の前に覚えておく (保存で消えることがあるため)
        if let id = VersionStore.historyID(of: url) { versionID = id }
        if Prefs.bool("backupOnSave"), saveOperation == .saveOperation, partial == nil {
            makeBackup(of: url)
        }
        // 拡張機能の「保存の直前」(ここで本文を書き換えると、その内容で保存される)
        PluginManager.shared.emit("beforeSave", editor: editor)
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
            if error == nil, let p = self.partial, let n = self.writtenPartLength {
                // 差し替えた部分の大きさが変わったので、範囲を直す
                self.partial = PartialFile.Part(offset: p.offset, length: n,
                                                fileSize: p.fileSize - p.length + n)
            }
            self.writtenPartLength = nil
            if error == nil, let ed = self.editor {
                // 保存で書き直したファイルにも、表示 (作文の縦・横、A4) を書き直す (上書き保存で拡張属性が消えることがあるため)
                let m: String? = ed.paperMode == .genko ? (ed.horizontalGenko ? "genkoH" : "genko") : ed.paperMode == .a4 ? "a4" : nil
                TextLibrary.writeFileMode(m, to: url)
            }
            if error == nil {
                self.editor?.savePaperAlignments()
                self.editor?.savePaperPDFIfNeeded(textURL: url)
            }
            if error == nil && self.remote != nil && saveOperation == .saveOperation {
                self.uploadToServer()
            }
            if error == nil {
                PluginManager.shared.emit("save", editor: self.editor)
                PluginManager.shared.fileSaved(url)
                // 版の記録 (git)。暗号化した文書・一部分だけ開いた文書は入れない
                // 書き換えて保存したら、テキスト一覧 (履歴) に入れる (開いただけでは入れない)
                if self.touched { TextLibrary.remember(url) }
                if self.partial == nil && self.encryptionKey == nil {
                    if let id = self.versionID, VersionStore.historyID(of: url) == nil { VersionStore.setHistoryID(id, on: url) }
                    VersionStore.noteSaved(url, now: self.userSaved)
                }
                self.userSaved = false
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
            NSLog(L("バックアップを作れませんでした: {0}", error))
        }
    }

    override func makeWindowControllers() {
        addWindowController(EditorWindowController(document: self))
    }

    /// 巨大なファイルは、開く前に「全部か一部分か」を聞く
    override func read(from url: URL, ofType typeName: String) throws {
        let size = (try? PartialFile.fileSize(of: url)) ?? 0
        let head = (try? FileHandle(forReadingFrom: url))?.readData(ofLength: 16) ?? Data()
        // 暗号化した文書と UTF-16 は、途中から読めないので全部読む
        let canPart = !FileCrypto.isEncrypted(head) && !head.starts(with: [0xFF, 0xFE]) && !head.starts(with: [0xFE, 0xFF])
        var wanted: (offset: UInt64, length: UInt64)?
        if let n = nextPart {
            wanted = n
        } else if let p = partial {
            wanted = (p.offset, p.length) // 「保存時の状態に戻す」などは、同じ範囲を読み直す
        } else if canPart, HugeFile.thresholdMB > 0, size >= UInt64(HugeFile.thresholdMB) * 1_048_576 {
            switch HugeFile.ask(name: url.lastPathComponent, size: size) {
            case .whole: break
            case .part(let o, let l): wanted = (o, l)
            case .cancel: throw CocoaError(.userCancelled)
            }
        }
        nextPart = nil
        if canPart, let w = wanted {
            let part = try PartialFile.align(url, offset: w.offset, length: w.length)
            if !part.isWholeFile {
                encryptionKey = nil
                partial = part
                apply(try TextCodec.decode(try PartialFile.read(url, part)))
                return
            }
        }
        partial = nil
        try read(from: try Data(contentsOf: url, options: .mappedIfSafe), ofType: typeName)
    }

    /// 一部分だけ読み込んだ文書は、「前の部分 + いまの文章 + 後ろの部分」をつないで書き出す
    override func write(to url: URL, ofType typeName: String) throws {
        guard let part = partial, let original = fileURL else {
            try super.write(to: url, ofType: typeName)
            return
        }
        guard encryptionKey == nil else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
                NSLocalizedDescriptionKey: L("一部分だけ読み込んだ文書は、暗号化して保存できません。全部読み込んでから暗号化してください。")])
        }
        if let tv = editor?.textView { text = tv.string }
        var body = try TextCodec.encode(text, encoding: encoding, lineEnding: lineEnding)
        // ファイルの途中に BOM を書かない
        let bom = encoding.bomBytes
        if part.offset > 0, !bom.isEmpty, body.starts(with: bom) { body = Data(body.dropFirst(bom.count)) }
        try PartialFile.write(original: original, part: part, replacement: body, to: url)
        writtenPartLength = UInt64(body.count)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard FileCrypto.isEncrypted(data) else {
            encryptionKey = nil
            apply(try TextCodec.decode(data))
            return
        }
        let unlocked = try PasswordPrompt.unlock(data, name: fileURL?.lastPathComponent ?? L("このファイル"))
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
        // どの拡張子でも保存できるようにする (.html などにしたとき「.txt を使いますか？」と聞かない)
        savePanel.allowedContentTypes = []
        savePanel.allowsOtherFileTypes = true
        savePanel.isExtensionHidden = false
        savePanel.delegate = self   // 拡張子を付けなかったときだけ .txt を足す
        // テキスト一覧の「新規テキスト」: 置き場所はそのフォルダ、名前の候補は 1 行目 (決めるのは自分)
        if let u = fileURL, TextLibrary.isBlankPlaceholder(u) {
            savePanel.directoryURL = u.deletingLastPathComponent()
            savePanel.nameFieldStringValue = TextLibrary.newFileURL(for: editor?.textView.string ?? "", in: u.deletingLastPathComponent()).lastPathComponent
        }
        return true
    }

    /// 保存 (⌘S): テキスト一覧で作った「新規テキスト」は、名前を付けて保存にする
    override func save(_ sender: Any?) {
        guard let u = fileURL, TextLibrary.isBlankPlaceholder(u) else {
            userSaved = true   // ⌘S: 保存が終わったら、すぐ版を作る
            return super.save(sender)
        }
        placeholderBeforeSave = u
        runModalSavePanel(for: .saveAsOperation, delegate: self,
                          didSave: #selector(placeholderSaved(_:didSave:contextInfo:)), contextInfo: nil)
    }

    /// 「新規テキスト」を名前を付けて保存したら、元の仮のファイルは消し、表示 (作文など)・公開リンクは引き継ぐ
    @objc private func placeholderSaved(_ doc: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard didSave, let old = placeholderBeforeSave, let new = fileURL,
              old.standardizedFileURL != new.standardizedFileURL else { placeholderBeforeSave = nil; return }
        placeholderBeforeSave = nil
        let mode = TextLibrary.fileMode(old) ?? TextLibrary.mode(for: old.standardizedFileURL.resolvingSymlinksInPath().path)
        try? FileManager.default.removeItem(at: old)
        // 「用紙を PDF でも保存」で横に作った仮の PDF も消す
        try? FileManager.default.removeItem(at: old.deletingPathExtension().appendingPathExtension("pdf"))
        ShareLink.repath(from: old, to: new)
        VersionStore.repath(from: old, to: new)
        if let m = mode { TextLibrary.setMode(m, for: new) }
        TextLibrary.remember(new)
        TextLibrary.changed()
    }
}

/// 名前を付けて保存: 拡張子を付けなかったときだけ .txt を足す (付けたものは、そのまま)
extension Document: NSOpenSavePanelDelegate {
    func panel(_ sender: Any, userEnteredFilename filename: String, confirmed okFlag: Bool) -> String? {
        guard okFlag, (filename as NSString).pathExtension.isEmpty else { return filename }
        return filename + ".txt"
    }
}
