import AppKit
import LocalAuthentication
import HinokiCore

/// 暗号化の鍵を決める・暗号化ファイルを開くときの画面
enum PasswordPrompt {
    static let minimumPasswordLength = 8
    static let minimumPasscodeLength = 6

    private static let kinds: [(kind: FileCrypto.Kind, title: String, note: String)] = [
        (.password, L("パスワード (8 文字以上)"),
         L("どの Mac でも開けます。長いほど安全。")),
        (.passcode, L("パスコード (数字 6 桁以上)"),
         L("覚えやすいけど、パスワードより弱め。")),
        (.device, L("この Mac のロック (Touch ID / Mac のパスワード)"),
         L("覚えなくて OK。この Mac でしか開けません。")),
        (.totp, L("ワンタイム認証 (スマホの認証アプリ)"),
         L("開くたびにスマホに出る 6 桁を入れます。この Mac でしか開けません。")),
        (.twoStep, L("二段階 (パスワード + ワンタイム認証)"),
         L("パスワードとスマホの 6 桁の両方が要ります。この Mac でしか開けません。")),
        (.keyfile, L("鍵ファイル (USB メモリなど)"),
         L("鍵ファイルがあるときだけ開けます。別の Mac でも開けます。")),
    ]

    // MARK: 鍵を決める

    /// 暗号化の方法の短い名前 (ステータスバーなどに出す)
    static func shortName(_ kind: FileCrypto.Kind) -> String {
        switch kind {
        case .device: return L("この Mac のロック")
        case .totp: return L("ワンタイム認証")
        case .keyfile: return L("鍵ファイル")
        case .twoStep: return L("二段階")
        case .passcode: return L("パスコード")
        case .password: return L("パスワード")
        }
    }

    /// 暗号化の方法の一覧 (並び順)
    static var kindOrder: [FileCrypto.Kind] { kinds.map { $0.kind } }

    /// 暗号化の方法を選んで鍵を作る。やめたら nil。initialKind を渡すと、その方法を選んだ状態で始める
    /// onlyKind を渡すと、方法は選ばせずにその方法の鍵だけを作り直す (鍵の変更)
    static func createKey(for name: String, initialKind: FileCrypto.Kind? = nil, onlyKind: FileCrypto.Kind? = nil) -> FileCrypto.Key? {
        var message = L("パスワード・パスコードは、忘れるとだれにも開けなくなります。")
        // 最初は「この Mac のロック」を選んでおく (覚えるものがなく、いちばん手軽)
        // 前に別の方法 (パスワード・パスコード) で暗号化していたら、次からはそれを最初に選んでおく
        var selected = (onlyKind ?? initialKind).flatMap { k in kinds.firstIndex { $0.kind == k } } ?? defaultKindIndex
        while true {
            let alert = NSAlert()
            alert.messageText = onlyKind == nil ? L("暗号化のしかた") : L("鍵の変更 ({0})", shortName(kinds[selected].kind))
            alert.informativeText = message
            let popup = NSPopUpButton()
            kinds.forEach { popup.addItem(withTitle: $0.title) }
            popup.selectItem(at: selected)
            popup.isHidden = onlyKind != nil // 鍵の変更では方法を変えない
            let note = NSTextField(wrappingLabelWithString: kinds[selected].note)
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            note.preferredMaxLayoutWidth = 320
            let p1 = NSSecureTextField()
            let p2 = NSSecureTextField()
            for f in [p1, p2] { f.widthAnchor.constraint(equalToConstant: 320).isActive = true }
            let fields = NSStackView(views: [p1, p2])
            fields.orientation = .vertical
            fields.alignment = .leading
            let stack = NSStackView(views: [popup, note, fields])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            let updater = KindUpdater { i in
                selected = i
                note.stringValue = kinds[i].note
                let k = kinds[i].kind
                fields.isHidden = k == .device || k == .totp || k == .keyfile
                p1.placeholderString = k == .passcode ? L("パスコード (数字)") : L("パスワード")
                p2.placeholderString = L("もう一度")
                stack.frame.size = stack.fittingSize
            }
            popup.target = updater
            popup.action = #selector(KindUpdater.changed(_:))
            updater.apply(selected)
            stack.frame = NSRect(origin: .zero, size: NSSize(width: 330, height: 150))
            alert.accessoryView = stack
            alert.addButton(withTitle: L("暗号化する"))
            alert.addButton(withTitle: L("やめる"))
            alert.window.initialFirstResponder = p1
            let response = alert.runModal()
            _ = updater
            guard response == .alertFirstButtonReturn else { return nil }
            let kind = kinds[selected].kind
            switch kind {
            case .device:
                if let key = makeDeviceKey() { rememberKind(kind); return key }
                message = L("鍵を保存できませんでした。ほかの方法を選んでください。")
            case .totp:
                // まだスマホを登録していなければ、ここで登録する (やめたら選び直し)
                guard enrollTOTPIfNeeded() else {
                    message = L("スマホの登録をやめました。")
                    continue
                }
                if let key = makeDeviceKey(kind: .totp) { rememberKind(kind); return key }
                message = L("鍵を保存できませんでした。ほかの方法を選んでください。")
            case .keyfile:
                switch chooseKeyFileForEncrypting() {
                case .some(let secret):
                    rememberKind(kind)
                    return FileCrypto.keyFileKey(secret: secret)
                case .none:
                    message = L("鍵ファイルを選びませんでした。")
                }
            case .twoStep:
                let a = p1.stringValue, b = p2.stringValue
                if a != b {
                    message = L("2 回の入力が違います。")
                } else if a.count < minimumPasswordLength {
                    message = L("パスワードは {0} 文字以上にしてください。", minimumPasswordLength)
                } else if !enrollTOTPIfNeeded() {
                    message = L("スマホの登録をやめました。")
                } else if let secret = totpSecret, let key = try? FileCrypto.twoStepKey(password: a, totpSecret: secret) {
                    rememberKind(kind)
                    return key
                } else {
                    message = L("鍵を作れませんでした。ほかの方法を選んでください。")
                }
            case .password, .passcode:
                let a = p1.stringValue, b = p2.stringValue
                if a != b {
                    message = L("2 回の入力が違います。")
                } else if kind == .passcode && (a.count < minimumPasscodeLength || !a.allSatisfy({ $0.isASCII && $0.isNumber })) {
                    message = L("数字 {0} 桁以上にしてください。", minimumPasscodeLength)
                } else if kind == .password && a.count < minimumPasswordLength {
                    message = L("{0} 文字以上にしてください。", minimumPasswordLength)
                } else {
                    let iterations = kind == .passcode ? FileCrypto.passcodeIterations : FileCrypto.defaultIterations
                    guard let key = try? FileCrypto.deriveKey(password: a, iterations: iterations, kind: kind) else { return nil }
                    rememberKind(kind)
                    return key
                }
            }
        }
    }

    /// 最後に使った暗号化の方法 (次に暗号化するときの初期選択。パスワードそのものは覚えない)
    private static let lastKindPrefKey = "encryptLastKind"

    private static func rememberKind(_ kind: FileCrypto.Kind) {
        UserDefaults.standard.set(String(describing: kind), forKey: lastKindPrefKey)
        NotificationCenter.default.post(name: .viewSettingsDidChange, object: nil) // 設定画面の表示を合わせる
    }

    /// 設定画面に出す、暗号化の方法の一覧 (名前と短い説明)
    static var kindChoices: [(title: String, note: String)] { kinds.map { ($0.title, $0.note) } }

    /// 暗号化するときに最初に選ばれている方法 (kindChoices の何番目か)。
    /// 設定画面で選べるほか、別の方法で暗号化するとそれに変わる。何も決めていなければ「この Mac のロック」
    static var defaultKindIndex: Int {
        get {
            let saved = UserDefaults.standard.string(forKey: lastKindPrefKey)
            return kinds.firstIndex { String(describing: $0.kind) == saved }
                ?? kinds.firstIndex { $0.kind == .device } ?? 0
        }
        set {
            guard kinds.indices.contains(newValue) else { return }
            UserDefaults.standard.set(String(describing: kinds[newValue].kind), forKey: lastKindPrefKey)
        }
    }

    /// 「この Mac のロック」用の鍵を作ってキーチェーンにしまう
    private static func makeDeviceKey(kind: FileCrypto.Kind = .device) -> FileCrypto.Key? {
        let (key, raw) = FileCrypto.newDeviceKey(kind: kind)
        let account = deviceAccount(key.salt)
        Keychain.set(raw.base64EncodedString(), for: account)
        guard Keychain.get(account) == raw.base64EncodedString() else { return nil }
        return key
    }

    private static func deviceAccount(_ id: Data) -> String {
        "filekey-" + id.map { String(format: "%02x", $0) }.joined()
    }

    private final class KindUpdater: NSObject {
        let f: (Int) -> Void
        init(_ f: @escaping (Int) -> Void) { self.f = f }
        func apply(_ i: Int) { f(i) }
        @objc func changed(_ sender: NSPopUpButton) { f(max(0, sender.indexOfSelectedItem)) }
    }

    // MARK: 開く

    /// 暗号化ファイルを開く。正しく開けるまで聞き直し、やめたら userCancelled を投げる
    static func unlock(_ data: Data, name: String) throws -> (plain: Data, key: FileCrypto.Key) {
        let header = try FileCrypto.header(of: data)
        if header.kind == .device { return try unlockWithDevice(data, header: header, name: name) }
        if header.kind == .totp { return try unlockWithTOTP(data, header: header, name: name) }
        if header.kind == .keyfile { return try unlockWithKeyFile(data, header: header, name: name) }
        if header.kind == .twoStep { return try unlockTwoStep(data, name: name) }
        let word = header.kind == .passcode ? L("パスコード") : L("パスワード")
        var message = L("「{0}」は暗号化されています。", name)
        while true {
            let alert = NSAlert()
            alert.messageText = L("🔒 {0}を入れてください", word)
            alert.informativeText = message
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.placeholderString = word
            alert.accessoryView = field
            alert.addButton(withTitle: L("開く"))
            alert.addButton(withTitle: L("やめる"))
            alert.window.initialFirstResponder = field
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { throw CocoaError(.userCancelled) }
            do {
                return try FileCrypto.open(data, password: field.stringValue)
            } catch FileCrypto.CryptoError.wrongPasswordOrDamaged {
                message = L("{0}が違います。", word)
            }
        }
    }

    /// Touch ID / Mac のパスワードで本人か確かめてから、キーチェーンの鍵で開く
    private static func unlockWithDevice(_ data: Data, header: FileCrypto.Header, name: String) throws -> (plain: Data, key: FileCrypto.Key) {
        guard let b64 = Keychain.get(deviceAccount(header.salt)), let raw = Data(base64Encoded: b64) else {
            throw FileCrypto.CryptoError.keyNotOnThisMac
        }
        let context = LAContext()
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            throw RemoteError(message: L("この Mac で本人確認が使えません: {0}", authError?.localizedDescription ?? ""))
        }
        var finished = false
        var success = false
        var failure: Error?
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L("「{0}」を開く", name)) { ok, err in
            DispatchQueue.main.async {
                success = ok
                failure = err
                finished = true
            }
        }
        // 確認の画面が閉じるまで待つ (画面の処理は止めない)
        while !finished {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        guard success else {
            if let e = failure as? LAError, e.code == .userCancel || e.code == .appCancel || e.code == .systemCancel {
                throw CocoaError(.userCancelled)
            }
            throw RemoteError(message: L("本人確認できませんでした: {0}", failure?.localizedDescription ?? ""))
        }
        let key = FileCrypto.deviceKey(raw: raw, id: header.salt)
        return (try FileCrypto.open(data, with: key), key)
    }

    // MARK: ワンタイム認証 (スマホの認証アプリ)

    /// 認証アプリと共有する秘密の置き場所 (キーチェーン)。全部の文書で 1 つを使い回す
    private static let totpAccount = "totp-secret"
    static let totpMaxAttempts = 5

    private static var totpSecret: Data? {
        Keychain.get(totpAccount).flatMap { Data(base64Encoded: $0) }
    }

    /// スマホの登録が済んでいなければ、QR コードを見せて登録してもらう。済んだら true
    private static func enrollTOTPIfNeeded() -> Bool {
        if totpSecret != nil { return true }
        let secret = TOTP.newSecret()
        let setupKey = TOTP.base32(secret)
        let uri = TOTP.uri(secret: secret, account: NSUserName(), issuer: MainMenu.appName)
        var message = L("スマホの認証アプリ (Google Authenticator など) でこの QR コードを読み、出てきた 6 桁を入れてください。")
        while true {
            let alert = NSAlert()
            alert.messageText = L("ワンタイム認証: スマホを登録")
            alert.informativeText = message
            let (stack, field) = totpEnrollView(uri: uri, setupKey: setupKey)
            alert.accessoryView = stack
            alert.addButton(withTitle: L("登録する"))
            alert.addButton(withTitle: L("やめる"))
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            if TOTP.verify(field.stringValue, secret: secret) {
                Keychain.set(secret.base64EncodedString(), for: totpAccount)
                return totpSecret == secret
            }
            message = L("6 桁が違います。スマホに出ている最新のものを入れてください。")
        }
    }

    /// 登録画面の中身: QR コード・設定キー・注意・コードの入力欄
    static func totpEnrollView(uri: String, setupKey: String) -> (view: NSView, field: NSTextField) {
        let qr = NSImageView(image: qrImage(uri, side: 200) ?? NSImage())
        qr.widthAnchor.constraint(equalToConstant: 200).isActive = true
        qr.heightAnchor.constraint(equalToConstant: 200).isActive = true
        // 読み取れないとき・機種変更のときのために、手で打てる設定キーも出す
        let grouped = stride(from: 0, to: setupKey.count, by: 4).map { i -> String in
            let a = setupKey.index(setupKey.startIndex, offsetBy: i)
            let b = setupKey.index(a, offsetBy: min(4, setupKey.count - i))
            return String(setupKey[a..<b])
        }.joined(separator: " ")
        let keyLabel = NSTextField(wrappingLabelWithString: L("設定キー: {0}", grouped))
        keyLabel.isSelectable = true
        keyLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        keyLabel.preferredMaxLayoutWidth = 320
        let warn = NSTextField(wrappingLabelWithString: L("スマホをなくすと開けなくなります。設定キーを控えておくと、新しいスマホに登録し直せます。"))
        warn.font = .systemFont(ofSize: 11)
        warn.textColor = .secondaryLabelColor
        warn.preferredMaxLayoutWidth = 320
        let field = NSTextField()
        field.placeholderString = L("6 桁の数字")
        field.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let stack = NSStackView(views: [qr, keyLabel, warn, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(origin: .zero, size: NSSize(width: 330, height: stack.fittingSize.height))
        return (stack, field)
    }

    static func qrImage(_ text: String, side: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        // 白地に、ぼかさず拡大する (まわりの余白も読み取りに必要)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        rep.draw(in: NSRect(x: 12, y: 12, width: side - 24, height: side - 24))
        image.unlockFocus()
        return image
    }

    /// スマホのコードで本人か確かめてから、キーチェーンの鍵で開く
    private static func unlockWithTOTP(_ data: Data, header: FileCrypto.Header, name: String) throws -> (plain: Data, key: FileCrypto.Key) {
        guard let b64 = Keychain.get(deviceAccount(header.salt)), let raw = Data(base64Encoded: b64),
              let secret = totpSecret else {
            throw FileCrypto.CryptoError.keyNotOnThisMac
        }
        var message = L("「{0}」は暗号化されています。", name)
        for attempt in 1...totpMaxAttempts {
            let alert = NSAlert()
            alert.messageText = L("🔒 ワンタイム認証: スマホの認証アプリの 6 桁を入れてください")
            alert.informativeText = message
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
            field.placeholderString = L("6 桁の数字")
            alert.accessoryView = field
            alert.addButton(withTitle: L("開く"))
            alert.addButton(withTitle: L("やめる"))
            alert.window.initialFirstResponder = field
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { throw CocoaError(.userCancelled) }
            if TOTP.verify(field.stringValue, secret: secret) {
                let key = FileCrypto.deviceKey(raw: raw, id: header.salt, kind: .totp)
                return (try FileCrypto.open(data, with: key), key)
            }
            message = L("6 桁が違います。(あと {0} 回)", totpMaxAttempts - attempt)
        }
        throw RemoteError(message: L("ワンタイム認証を {0} 回まちがえたので、開くのをやめました。", totpMaxAttempts))
    }

    // MARK: 二段階 (パスワード + ワンタイム認証)

    private static func unlockTwoStep(_ data: Data, name: String) throws -> (plain: Data, key: FileCrypto.Key) {
        guard let secret = totpSecret else { throw FileCrypto.CryptoError.keyNotOnThisMac }
        var message = L("「{0}」は二段階で暗号化されています。", name)
        var wrongCodes = 0
        while true {
            let alert = NSAlert()
            alert.messageText = L("🔒 パスワードと、スマホの認証アプリの 6 桁を入れてください")
            alert.informativeText = message
            let password = NSSecureTextField()
            password.placeholderString = L("パスワード")
            let code = NSTextField()
            code.placeholderString = L("6 桁の数字")
            for f in [password, code] { f.widthAnchor.constraint(equalToConstant: 280).isActive = true }
            let stack = NSStackView(views: [password, code])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.frame = NSRect(origin: .zero, size: NSSize(width: 280, height: stack.fittingSize.height))
            alert.accessoryView = stack
            alert.addButton(withTitle: L("開く"))
            alert.addButton(withTitle: L("やめる"))
            alert.window.initialFirstResponder = password
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { throw CocoaError(.userCancelled) }
            guard TOTP.verify(code.stringValue, secret: secret) else {
                wrongCodes += 1
                if wrongCodes >= totpMaxAttempts {
                    throw RemoteError(message: L("ワンタイム認証を {0} 回まちがえたので、開くのをやめました。", totpMaxAttempts))
                }
                message = L("6 桁が違います。(あと {0} 回)", totpMaxAttempts - wrongCodes)
                continue
            }
            do {
                return try FileCrypto.open(data, password: password.stringValue, totpSecret: secret)
            } catch FileCrypto.CryptoError.wrongPasswordOrDamaged {
                message = L("パスワードが違います。")
            }
        }
    }

    // MARK: 鍵ファイル (USB メモリなど)

    /// 最後に使った鍵ファイルの場所 (次に暗号化・解錠するとき、まずここを見る)
    private static let keyFilePathPrefKey = "encryptKeyFilePath"

    private static func keyFileSecret(at url: URL) -> Data? {
        // 鍵ファイルは小さい。大きなファイルを選ばれても丸ごと読まない
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 4096,
              let data = try? Data(contentsOf: url) else { return nil }
        return FileCrypto.keyFileSecret(data)
    }

    /// 見つかりそうな場所: 前に使った場所と、挿してあるディスク (USB メモリなど) のいちばん上の階層
    static func keyFileCandidates() -> [URL] {
        var urls: [URL] = []
        if let p = UserDefaults.standard.string(forKey: keyFilePathPrefKey) { urls.append(URL(fileURLWithPath: p)) }
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        for v in volumes where v.path != "/" {
            let items = (try? FileManager.default.contentsOfDirectory(at: v, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            urls += items.filter { $0.pathExtension == FileCrypto.keyFileExtension }
        }
        return urls
    }

    /// 暗号化に使う鍵ファイルを決める: 前に使ったものがあればそれ、なければ作るか選んでもらう。やめたら nil
    private static func chooseKeyFileForEncrypting() -> Data? {
        if let p = UserDefaults.standard.string(forKey: keyFilePathPrefKey),
           let secret = keyFileSecret(at: URL(fileURLWithPath: p)) {
            let alert = NSAlert()
            alert.messageText = L("この鍵ファイルで暗号化しますか？")
            alert.informativeText = p
            alert.addButton(withTitle: L("これで暗号化"))
            alert.addButton(withTitle: L("別の鍵ファイル…"))
            alert.addButton(withTitle: L("やめる"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: return secret
            case .alertSecondButtonReturn: break
            default: return nil
            }
        }
        let alert = NSAlert()
        alert.messageText = L("鍵ファイル")
        alert.informativeText = L("鍵ファイルを USB メモリなどに置くと、それを挿しているときだけ開けます。\nなくすと開けなくなるので、控え (コピー) を別の場所にも置いてください。")
        alert.addButton(withTitle: L("新しく作る…"))
        alert.addButton(withTitle: L("ある鍵ファイルを選ぶ…"))
        alert.addButton(withTitle: L("やめる"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return createKeyFile()
        case .alertSecondButtonReturn: return pickKeyFile(message: L("暗号化に使う鍵ファイルを選んでください"))
        default: return nil
        }
    }

    private static func removableVolume() -> URL? {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.first { v in
            guard v.path != "/", let r = try? v.resourceValues(forKeys: Set(keys)) else { return false }
            return r.volumeIsRemovable == true || r.volumeIsEjectable == true || r.volumeIsInternal == false
        }
    }

    private static func createKeyFile() -> Data? {
        let panel = NSSavePanel()
        panel.message = L("鍵ファイルを置く場所を選んでください (USB メモリなど)")
        panel.nameFieldStringValue = L("さとるエディタの鍵.") + FileCrypto.keyFileExtension
        panel.allowedFileTypes = [FileCrypto.keyFileExtension]
        if let usb = removableVolume() { panel.directoryURL = usb }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let contents = FileCrypto.newKeyFileContents()
        do {
            try contents.write(to: url, options: .atomic)
            // 本人だけ読めるようにする (USB メモリの形式によっては効かない)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSApp.presentError(error)
            return nil
        }
        // 書けたものを読み直して確かめてから使う
        guard let secret = keyFileSecret(at: url), secret == FileCrypto.keyFileSecret(contents) else { return nil }
        UserDefaults.standard.set(url.path, forKey: keyFilePathPrefKey)
        return secret
    }

    private static func pickKeyFile(message: String) -> Data? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.allowedFileTypes = [FileCrypto.keyFileExtension]
        panel.allowsOtherFileTypes = true
        if let usb = removableVolume() { panel.directoryURL = usb }
        while true {
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            if let secret = keyFileSecret(at: url) {
                UserDefaults.standard.set(url.path, forKey: keyFilePathPrefKey)
                return secret
            }
            let alert = NSAlert()
            alert.messageText = L("これは鍵ファイルではありません")
            alert.informativeText = url.lastPathComponent
            alert.runModal()
        }
    }

    /// 鍵ファイルを探して開く。見つからなければ、挿し直すか選んでもらう
    private static func unlockWithKeyFile(_ data: Data, header: FileCrypto.Header, name: String) throws -> (plain: Data, key: FileCrypto.Key) {
        var message = L("「{0}」を暗号化したときの鍵ファイルが見つかりません。\nUSB メモリなどを挿して「もう一度探す」を押すか、鍵ファイルを選んでください。", name)
        while true {
            // 指紋が合う鍵ファイルが見つかれば、何も聞かずに開く
            for url in keyFileCandidates() {
                guard let secret = keyFileSecret(at: url), FileCrypto.keyFileFingerprint(secret) == header.iterations else { continue }
                let opened = try FileCrypto.open(data, keyFileSecret: secret)
                UserDefaults.standard.set(url.path, forKey: keyFilePathPrefKey)
                return opened
            }
            let alert = NSAlert()
            alert.messageText = L("🔒 鍵ファイルが必要です")
            alert.informativeText = message
            alert.addButton(withTitle: L("もう一度探す"))
            alert.addButton(withTitle: L("鍵ファイルを選ぶ…"))
            alert.addButton(withTitle: L("やめる"))
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                continue
            case .alertSecondButtonReturn:
                guard let secret = pickKeyFile(message: L("「{0}」を開く鍵ファイルを選んでください", name)) else { continue }
                do {
                    return try FileCrypto.open(data, keyFileSecret: secret)
                } catch FileCrypto.CryptoError.wrongKeyFile {
                    message = L("選んだ鍵ファイルは、この文書を暗号化したときのものではありません。")
                }
            default:
                throw CocoaError(.userCancelled)
            }
        }
    }
}
