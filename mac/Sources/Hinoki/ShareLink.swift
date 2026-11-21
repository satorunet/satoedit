import AppKit
import CryptoKit
import HinokiCore

// リンクで公開 (かんたんアップローダー): テキストを docs.satoru.net に送って、https://docs.satoru.net/r/<id> で読めるようにする。
// 公開のしかたは「公開 (一覧に載る)」「リンクを知っている人だけ」「パスワード」から選ぶ。期限も決められる。
// 公開したものは「公開したリンク」の一覧で、コピー・開く・公開をやめる ができる。

enum ShareLink {
    static let base = "https://docs.satoru.net"

    struct Record: Codable {
        let id: String
        let url: String
        let token: String
        var title: String
        var visibility: String
        let created: Date
        var expires: Date?
        /// 公開したもとのファイル (一覧で「公開中」の印を付けるため)。ファイルでないときは nil
        var path: String?
        /// 公開した (更新した) ときの中身の印。いまの中身と違えば「公開中のページを更新」が押せる
        var contentHash: String?
        /// 更新したとき、前の中身を変更履歴に残すか (前の版の記録は nil = 残す)
        var keepHistory: Bool?
        var isAlive: Bool { expires.map { $0 > Date() } ?? true }
    }

    /// 中身の印 (本文と表示から作る)
    static func contentHash(_ text: String, mode: String) -> String {
        SHA256.hash(data: Data((mode + "\u{0}" + text).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 公開してから書き換えたか (前の版で記録がなければ、書き換えたことにする)
    static func needsUpdate(_ r: Record, text: String, mode: String) -> Bool {
        guard let h = r.contentHash else {
            learnPublishedHash(r, text: text, mode: mode)
            return true
        }
        return h != contentHash(text, mode: mode)
    }

    /// 前の版で公開したもの (中身の印を覚えていない): 公開中の本文をサーバから取ってきて、いまと同じなら印を覚える。
    /// 次にメニューを開いたときから、書き換えていなければ「更新」は押せなくなる (1 件 1 回だけ問い合わせる)
    private static var asked = Set<String>()
    private static func learnPublishedHash(_ r: Record, text: String, mode: String) {
        guard r.visibility != "password", !asked.contains(r.id), let u = URL(string: r.url + ".txt") else { return }
        asked.insert(r.id)
        URLSession.shared.dataTask(with: u) { data, resp, _ in
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let data = data,
                  String(decoding: data, as: UTF8.self) == text else { return }
            DispatchQueue.main.async {
                guard var cur = records.first(where: { $0.id == r.id }), cur.contentHash == nil else { return }
                cur.contentHash = contentHash(text, mode: mode)
                replace(cur)
            }
        }.resume()
    }

    /// 記録を差し替える
    static func replace(_ r: Record) {
        records = records.map { $0.id == r.id ? r : $0 }
        TextLibrary.changed()
        SharedLinksWindow.shared.reload()
    }

    static func normalized(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    /// そのファイルの公開中のリンク (いちばん新しいもの)
    static func record(for url: URL) -> Record? {
        let p = normalized(url)
        return records.first { $0.path == p && $0.isAlive }
    }

    /// ファイルの名前や場所が変わったとき、公開の記録もそちらに付け替える (old/new はファイルかフォルダ)
    static func repath(from old: URL, to new: URL) {
        let o = normalized(old), n = normalized(new)
        var changed = false
        records = records.map { r in
            var r = r
            if let p = r.path, p == o || p.hasPrefix(o + "/") {
                r.path = n + p.dropFirst(o.count)
                changed = true
            }
            return r
        }
        if changed { TextLibrary.changed() }
    }

    private static let recordsKey = "sharedLinks"
    static var records: [Record] {
        get {
            guard let d = UserDefaults.standard.data(forKey: recordsKey) else { return [] }
            return (try? JSONDecoder().decode([Record].self, from: d)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: recordsKey) }
    }

    static func visibilityName(_ v: String) -> String {
        switch v {
        case "public": return L("公開")
        case "password": return L("パスワード")
        default: return L("リンクを知っている人だけ")
        }
    }

    // MARK: 公開する

    /// 標準エディタで公開するときの見た目: いま使っているエディタの色 (背景・文字・行番号・改行の印) と、改行の印を出すか
    static func editorTheme() -> [String: Any] {
        var t: [String: Any] = [:]
        for (k, c) in [("background", Theme.background), ("text", Theme.text), ("gutterBackground", Theme.gutterBackground),
                       ("gutterText", Theme.gutterText), ("gutterSeparator", Theme.gutterSeparator), ("newlineMark", Theme.newlineMark),
                       ("eof", Theme.eof), ("chrome", Theme.footerBackground), ("chromeText", Theme.statusText),
                       // カーソルのある行・選んだところ・カーソルの色 (公開ページでも、クリックした行がアプリと同じ色になる)
                       ("currentLine", Theme.currentLine), ("currentLineText", Theme.currentLineText),
                       ("gutterCurrentText", Theme.gutterCurrentText), ("selection", Theme.selection), ("caret", Theme.caret)] {
            t[k] = String(Theme.hex(of: c).prefix(7))
        }
        t["marks"] = UserDefaults.standard.bool(forKey: "invisibles")
        t["ruler"] = UserDefaults.standard.bool(forKey: "columnRuler")
        t["currentLineOn"] = Prefs.bool("highlightCurrentLine")
        return t
    }

    /// 公開するファイルの画面の画像 (base64 の PNG)。いま開いているときだけ作る (全体を 1 枚に。大きすぎれば縮める)
    static func shareImage(file: URL?) -> String? {
        guard let f = file, let ed = (NSDocumentController.shared.document(for: f) as? Document)?.editor,
              let shot = ed.screenshot(scope: .whole) else { return nil }
        var rep = shot.rep
        let maxW = 1400, maxH = 12000, limit = 5_500_000
        var scale = min(1.0, Double(maxW) / Double(max(1, rep.pixelsWide)))
        for _ in 0..<5 {
            let w = Int(Double(rep.pixelsWide) * scale), h = min(maxH, Int(Double(rep.pixelsHigh) * scale))
            if scale < 1 || h < Int(Double(rep.pixelsHigh) * scale), let small = resized(shot.rep, width: w, height: h, scale: scale) {
                rep = small
            }
            if let data = rep.representation(using: .png, properties: [:]), data.count <= limit {
                return data.base64EncodedString()
            }
            scale *= 0.7
            rep = shot.rep
        }
        return nil
    }

    /// 縮めた画像 (高さが上限を超えるぶんは、下を切る)
    private static func resized(_ rep: NSBitmapImageRep, width: Int, height: Int, scale: Double) -> NSBitmapImageRep? {
        guard width > 0, height > 0, let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        let fullH = Double(rep.pixelsHigh) * scale
        // 上をそろえて描く (はみ出した下は切れる)
        rep.draw(in: NSRect(x: 0, y: Double(height) - fullH, width: Double(width), height: fullH),
                 from: .zero, operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    /// 公開の画面を出して、OK なら送る。mode: "text" / "editor" / "genko" / "genkoH"
    static func share(text: String, suggestedTitle: String, mode: String, file: URL? = nil, from window: NSWindow?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        // 選んだ部分だけを公開するときは、本文の中での場所 (見直しで選ぶため) を出しておく
        var offset = 0
        if let ed = window?.windowController as? EditorWindowController, ed.textView.selectedRange().length > 0 {
            offset = ed.textView.selectedRange().location
        }
        confirmPrivacy(text, window: window, file: file, offset: offset) {
            shareChecked(text: text, suggestedTitle: suggestedTitle, mode: mode, file: file, from: window)
        }
    }

    // MARK: うっかり個人情報の公開を防ぐ

    static let privacyCheckOffKey = "sharePrivacyCheckOff"

    /// 公開する前に、電話番号・名前・住所・パスワードなどが入っていないかを手元で点検し (どこにも送らない)、
    /// 疑わしければ「このまま公開してよいか」を聞く。「次から出さない」にチェックして公開したら、もう聞かない
    static func confirmPrivacy(_ text: String, window: NSWindow?, file: URL? = nil, offset: Int = 0, then proceed: @escaping () -> Void) {
        if UserDefaults.standard.bool(forKey: privacyCheckOffKey) { return proceed() }
        // Mac の利用者の名前 (「矢野 悟」なら「矢野悟」も) は必ず探す
        let full = NSFullUserName().trimmingCharacters(in: .whitespaces)
        let names = [full, full.replacingOccurrences(of: " ", with: ""), full.replacingOccurrences(of: " ", with: "\u{3000}")]
            .filter { $0.count >= 2 && $0.unicodeScalars.contains { $0.value >= 0x3000 } }
        let found = PrivacyScan.scan(text, names: names)
        guard !found.isEmpty else { return proceed() }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = L("個人情報が入っているかもしれません")
        let lines = found.prefix(8).map { "・" + L($0.kind) + "  " + $0.sample }.joined(separator: "\n")
        a.informativeText = lines + "\n\n" + L("公開すると、リンクを知った人が読めるようになります。このまま公開してよいですか？")
        a.addButton(withTitle: L("やめて見直す"))
        a.addButton(withTitle: L("このまま公開する"))
        a.showsSuppressionButton = true
        a.suppressionButton?.title = L("次からこの確認を出さない")
        let handle: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .alertSecondButtonReturn else {
                // やめて見直す: 見つけたところを選んで、カーソルを合わせる
                DispatchQueue.main.async { review(found, file: file, offset: offset, window: window) }
                return
            }
            if a.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: privacyCheckOffKey) }
            DispatchQueue.main.async { proceed() }
        }
        if let w = window { a.beginSheetModal(for: w, completionHandler: handle) } else { handle(a.runModal()) }
    }

    /// 見つけた個人情報らしきところを、エディタで選んだ状態にして見せる (開いていなければ開く)
    static func review(_ found: [PrivacyScan.Finding], file: URL?, offset: Int, window: NSWindow?) {
        func select(in ed: EditorWindowController) {
            let len = (ed.textView.string as NSString).length
            let ranges = found.map { NSRange(location: $0.range.location + offset, length: $0.range.length) }
                .filter { NSMaxRange($0) <= len }
            guard let first = ranges.first else { return }
            ed.window?.makeKeyAndOrderFront(nil)
            ed.textView.setSelectedRanges(ranges.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
            ed.textView.scrollRangeToVisible(first)
            ed.focusEditor()
            ed.textView.setSelectedRanges(ranges.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
        }
        if let f = file {
            if let d = NSDocumentController.shared.document(for: f) as? Document, let ed = d.editor { return select(in: ed) }
            NSDocumentController.shared.openDocument(withContentsOf: f, display: true) { doc, _, _ in
                guard let ed = (doc as? Document)?.editor else { return }
                DispatchQueue.main.async { select(in: ed) }
            }
        } else if let ed = window?.windowController as? EditorWindowController {
            select(in: ed)
        }
    }

    // 公開の画面の題名は、勝手に入れない (空のまま。書きたい人だけ書く)
    private static func shareChecked(text: String, suggestedTitle: String, mode: String, file: URL?, from window: NSWindow?) {
        // もう公開中のファイル: 同じリンクのページを新しくするか、別のリンクで公開するか
        if let f = file, let r = record(for: f) {
            let a = NSAlert()
            a.messageText = L("このテキストは公開中です")
            a.informativeText = r.url + "\n\n" + L("公開中のページを今の内容に更新できます (リンクはそのまま。前の内容は変更履歴に残ります)。")
            a.addButton(withTitle: L("公開中のページを更新（変更を反映）"))
            a.addButton(withTitle: L("新しいリンクで公開…"))
            a.addButton(withTitle: L("キャンセル"))
            // 公開してから書き換えていなければ、更新は押せない
            if !needsUpdate(r, text: text, mode: mode) {
                a.buttons[0].isEnabled = false
                a.informativeText = r.url + "\n\n" + L("公開してから変更していないので、更新するものはありません。")
            }
            let pick: (NSApplication.ModalResponse) -> Void = { resp in
                switch resp {
                case .alertFirstButtonReturn: update(r, text: text, mode: mode, window: window)
                case .alertSecondButtonReturn:
                    DispatchQueue.main.async { showForm(text: text, suggestedTitle: "", mode: mode, file: file, from: window) }
                default: break
                }
            }
            if let w = window { a.beginSheetModal(for: w, completionHandler: pick) } else { pick(a.runModal()) }
            return
        }
        showForm(text: text, suggestedTitle: "", mode: mode, file: file, from: window)
    }

    /// 公開中のページを今の内容にする (URL・公開のしかた・期限はそのまま。前の内容はサイトの変更履歴に残る)
    static func update(_ r: Record, text: String, mode: String, window: NSWindow?) {
        var req = URLRequest(url: URL(string: base + "/api/share/" + r.id)!)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(r.token, forHTTPHeaderField: "X-Delete-Token")
        req.timeoutInterval = 30
        var body: [String: Any] = ["text": text, "title": r.title, "mode": mode]
        if mode == "genko" || mode == "genkoH" { body["layout"] = genkoLayout(text, horizontal: mode == "genkoH") }
        if mode == "editor" { body["theme"] = editorTheme() }
        if r.visibility != "password", let p = r.path, let img = shareImage(file: URL(fileURLWithPath: p)) { body["image"] = img }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { _, resp, err in
            DispatchQueue.main.async {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard err == nil, code == 200 else {
                    if code == 404 { // サーバにもう無い (期限切れなど): 記録も消す
                        records = records.filter { $0.id != r.id }
                        TextLibrary.changed()
                    }
                    let e = NSAlert()
                    e.messageText = L("更新できませんでした")
                    e.informativeText = code == 404 ? L("このページはもう公開されていません。もう一度公開してください。")
                        : code == 429 ? L("短い時間にたくさん公開したので、少し待ってからもう一度試してください。")
                        : err != nil ? L("インターネットにつながっているか確かめてください。") : L("サーバから答えがありませんでした ({0})", code)
                    if let w = window { e.beginSheetModal(for: w) } else { e.runModal() }
                    return
                }
                var nr = r
                nr.contentHash = contentHash(text, mode: mode)
                replace(nr)
                if let u = URL(string: r.url) { NSWorkspace.shared.open(u) }
                let done = NSAlert()
                done.messageText = L("公開中のページを更新しました")
                done.informativeText = r.url + "\n\n" + L("前の内容は、ページの「変更履歴」から見られます。")
                done.addButton(withTitle: L("閉じる"))
                if let w = window { done.beginSheetModal(for: w) } else { done.runModal() }
                SharedLinksWindow.shared.reload()
            }
        }.resume()
    }

    /// 公開の画面 (題名・公開のしかた・期限) を出す
    private static func showForm(text: String, suggestedTitle: String, mode: String, file: URL?, from window: NSWindow?) {
        let form = ShareForm(title: suggestedTitle)
        let a = NSAlert()
        a.messageText = L("リンクで公開共有")
        a.informativeText = L("文章をインターネット上に公開して URL を発行します。")
        a.accessoryView = form.view
        a.addButton(withTitle: L("公開する"))
        a.addButton(withTitle: L("キャンセル"))
        a.window.initialFirstResponder = form.titleField
        let handle: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .alertFirstButtonReturn else { return }
            if form.visibility == "password" && form.password.count < 4 {
                let e = NSAlert()
                e.messageText = L("パスワードは 4 文字以上にしてください")
                e.runModal()
                showForm(text: text, suggestedTitle: form.titleField.stringValue, mode: mode, file: file, from: window)
                return
            }
            upload(text: text, title: form.titleField.stringValue, mode: mode, visibility: form.visibility,
                   password: form.password, days: max(0, form.days), expiresAt: form.customExpiry,
                   keepHistory: form.keepHistory, file: file, window: window)
        }
        if let w = window { a.beginSheetModal(for: w, completionHandler: handle) } else { handle(a.runModal()) }
    }

    private static func upload(text: String, title: String, mode: String, visibility: String, password: String, days: Int,
                               expiresAt: Date? = nil, keepHistory: Bool, file: URL?, window: NSWindow?) {
        var req = URLRequest(url: URL(string: base + "/api/share")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        var body: [String: Any] = ["text": text, "title": title, "mode": mode, "visibility": visibility, "days": days,
                                   "keepHistory": keepHistory]
        if let e = expiresAt { body["expiresAt"] = e.timeIntervalSince1970 }
        if mode == "genko" || mode == "genkoH" { body["layout"] = genkoLayout(text, horizontal: mode == "genkoH") }
        if mode == "editor" { body["theme"] = editorTheme() }
        if visibility == "password" { body["password"] = password }
        // 「画像としてコピー」用に、いまの画面の画像も送る (パスワード制のものは送らない)
        if visibility != "password", let img = shareImage(file: file) { body["image"] = img }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard err == nil, code == 200, let data = data,
                      let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let id = o["id"] as? String, let url = o["url"] as? String, let token = o["token"] as? String else {
                    let e = NSAlert()
                    e.messageText = L("公開できませんでした")
                    e.informativeText = code == 429 ? L("短い時間にたくさん公開したので、少し待ってからもう一度試してください。")
                        : err != nil ? L("インターネットにつながっているか確かめてください。") : L("サーバから答えがありませんでした ({0})", code)
                    if let w = window { e.beginSheetModal(for: w) } else { e.runModal() }
                    return
                }
                let exp = (o["expires"] as? Double).map { Date(timeIntervalSince1970: $0) }
                records = [Record(id: id, url: url, token: token, title: title, visibility: visibility, created: Date(), expires: exp,
                                  path: file.map(normalized), contentHash: contentHash(text, mode: mode),
                                  keepHistory: keepHistory)] + records
                TextLibrary.changed() // 一覧に「公開中」の印を付ける
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                // 公開したら、すぐブラウザで開いて見せる
                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                let done = NSAlert()
                done.messageText = L("公開しました")
                done.informativeText = url + "\n\n" + L("リンクをコピーしました。") + "  " + visibilityName(visibility)
                    + (visibility == "password" ? "\n" + L("読む人にはパスワードも伝えてください。") : "")
                done.addButton(withTitle: L("閉じる"))
                if let w = window { done.beginSheetModal(for: w) } else { done.runModal() }
                SharedLinksWindow.shared.reload()
            }
        }.resume()
    }

    /// 動作確認・サイト用: 公開の画面を出さずに、アプリと同じ中身 (原稿用紙の並び・ふりがな・画像) で公開する。
    /// 自分の「公開したリンク」の一覧には入れない。答え (id・url・token) を JSON で返す
    static func publishForTest(text: String, title: String, mode: String, visibility: String, file: URL?,
                               completion: @escaping (Data?) -> Void) {
        var req = URLRequest(url: URL(string: base + "/api/share")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        var body: [String: Any] = ["text": text, "title": title, "mode": mode, "visibility": visibility, "days": 0, "keepHistory": true]
        if mode == "genko" || mode == "genkoH" { body["layout"] = genkoLayout(text, horizontal: mode == "genkoH") }
        if mode == "editor" { body["theme"] = editorTheme() }
        if let img = shareImage(file: file) { body["image"] = img }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, _, _ in DispatchQueue.main.async { completion(data) } }.resume()
    }

    /// 作文: アプリで原稿用紙に並べたとおり (自動整形・禁則・ふりがな) をサーバに渡す。サーバは同じ寸法でそのまま描く
    static func genkoLayout(_ text: String, horizontal: Bool) -> [String: Any] {
        let auto = !horizontal && UserDefaults.standard.bool(forKey: "genkoAutoFormat")
        let columns = Genko.layout(text, autoFormat: auto)
        var ruby: [String: [[Any]]] = [:]
        if UserDefaults.standard.bool(forKey: "genkoFurigana") {
            for (col, list) in Genko.placeRuby(columns, Furigana.ruby(for: text)) {
                ruby[String(col)] = list.map { [$0.row, $0.rows, $0.text] }
            }
        }
        return ["columns": columns.map { c in c.cells.map { $0 as Any? ?? NSNull() } }, "ruby": ruby]
    }

    // MARK: 公開をやめる

    static func unpublish(_ r: Record, completion: @escaping (Bool) -> Void) {
        var req = URLRequest(url: URL(string: base + "/api/share/" + r.id)!)
        req.httpMethod = "DELETE"
        req.setValue(r.token, forHTTPHeaderField: "X-Delete-Token")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { _, resp, err in
            DispatchQueue.main.async {
                let ok = err == nil && (resp as? HTTPURLResponse)?.statusCode == 200
                if ok {
                    records = records.filter { $0.id != r.id }
                    TextLibrary.changed()
                }
                completion(ok)
            }
        }.resume()
    }
}

/// 公開の画面の中身: 題名・公開のしかた・パスワード・期限
final class ShareForm: NSObject {
    let view: NSView
    let titleField = NSTextField()
    let radios: [NSButton]
    let passwordField = NSSecureTextField()
    let daysPopup = NSPopUpButton()
    private static let kinds = ["public", "unlisted", "password"]
    /// -1 = 日時を指定 (下の日時の欄で、分まで決める)
    private static let dayChoices: [(Int, String)] = [(1, "1 日"), (7, "7 日"), (30, "30 日"), (365, "1 年"), (0, "期限なし"), (-1, "日時を指定…")]
    /// 期限の日時 (「日時を指定…」を選んだときだけ使える)
    let datePicker = NSDatePicker()
    /// 日時を指定した期限 (選んでいなければ nil)
    var customExpiry: Date? { !keepExpiry && days == -1 ? datePicker.dateValue : nil }

    var visibility: String { Self.kinds[radios.firstIndex { $0.state == .on } ?? 1] }
    var password: String { passwordField.stringValue }
    var days: Int { Self.dayChoices[max(0, daysPopup.indexOfSelectedItem - (keepsExpiry ? 1 : 0))].0 }
    /// 公開中のものの設定を変えるとき: いちばん上の「期限を変えない」を選んでいる
    var keepExpiry: Bool { keepsExpiry && daysPopup.indexOfSelectedItem == 0 }
    private var keepsExpiry = false
    private var editing = false
    /// 変更履歴を残す (更新したとき、前の中身をページの「変更履歴」から見られる)
    let historyBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    /// 公開中のものの設定: 今ある変更履歴を消す
    let clearHistoryBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    var keepHistory: Bool { historyBox.state == .on }
    var clearHistory: Bool { clearHistoryBox.state == .on }

    /// 公開中のものの設定を変える画面 (いまの設定を入れておく)
    convenience init(editing r: ShareLink.Record) {
        self.init(title: r.title)
        editing = true
        for (i, b) in radios.enumerated() { b.state = Self.kinds[i] == r.visibility ? .on : .off }
        let df = DateFormatter()
        df.locale = Locale.current
        df.setLocalizedDateFormatFromTemplate("yMMMdHm")
        keepsExpiry = true
        daysPopup.insertItem(withTitle: r.expires.map { L("変えない ({0} まで)", df.string(from: $0)) } ?? L("変えない (期限なし)"), at: 0)
        daysPopup.selectItem(at: 0)
        if let e = r.expires, e > Date() { datePicker.dateValue = e }
        if r.visibility == "password" { passwordField.placeholderString = L("変えないときは空のまま") }
        historyBox.state = (r.keepHistory ?? true) ? .on : .off
        clearHistoryBox.isHidden = false
        refresh()
        // 出した項目のぶん、高さを合わせ直す
        if let stack = view.subviews.first as? NSStackView {
            view.setFrameSize(NSSize(width: max(360, stack.fittingSize.width), height: stack.fittingSize.height))
        }
    }

    init(title: String) {
        let labels = [L("公開 (だれでも読める・検索にも出る)"), L("リンクを知っている人だけ"), L("パスワードを知っている人だけ")]
        var rs: [NSButton] = []
        let holder = NSObject()
        for l in labels { rs.append(NSButton(radioButtonWithTitle: l, target: nil, action: nil)) }
        radios = rs
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 210))
        super.init()
        _ = holder
        titleField.stringValue = title
        titleField.placeholderString = L("題名 (なくてもかまいません)")
        passwordField.placeholderString = L("パスワード (4 文字以上)")
        let saved = UserDefaults.standard.string(forKey: "shareVisibility") ?? "unlisted"
        for (i, r) in radios.enumerated() {
            r.target = self
            r.action = #selector(kindChanged(_:))
            r.state = Self.kinds[i] == saved ? .on : .off
        }
        Self.dayChoices.forEach { daysPopup.addItem(withTitle: L($0.1)) }
        daysPopup.selectItem(at: Self.dayChoices.firstIndex { $0.0 == (UserDefaults.standard.object(forKey: "shareDays") as? Int ?? 30) } ?? 2)
        daysPopup.target = self
        daysPopup.action = #selector(daysChanged(_:))
        let titleRow = NSStackView(views: [NSTextField(labelWithString: L("題名")), titleField])
        titleField.widthAnchor.constraint(equalToConstant: 290).isActive = true
        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        datePicker.minDate = Date().addingTimeInterval(5 * 60)
        datePicker.maxDate = Date().addingTimeInterval(3650 * 86400)
        datePicker.dateValue = Date().addingTimeInterval(7 * 86400)
        let daysRow = NSStackView(views: [NSTextField(labelWithString: L("公開の期限")), daysPopup, datePicker])
        let note = NSTextField(wrappingLabelWithString: L("公開をやめる・設定を変えるには、メニューの「公開」から。"))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        passwordField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let pwRow = NSStackView(views: [NSView(), passwordField])
        pwRow.spacing = 20
        historyBox.title = L("変更履歴を残す (更新したとき、前の内容もページから見られる)")
        historyBox.state = UserDefaults.standard.object(forKey: "shareKeepHistory") as? Bool ?? true ? .on : .off
        historyBox.target = self
        historyBox.action = #selector(historyChanged(_:))
        clearHistoryBox.title = L("今ある変更履歴を消す")
        clearHistoryBox.isHidden = true
        let stack = NSStackView(views: [titleRow] + radios + [pwRow, daysRow, historyBox, clearHistoryBox, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        // 中身の高さぴったりにする (余ったすき間を作らない)
        let size = stack.fittingSize
        view.setFrameSize(NSSize(width: max(360, size.width), height: size.height))
        stack.frame = view.bounds
        stack.autoresizingMask = [.width, .height]
        view.addSubview(stack)
        refresh()
    }

    @objc private func kindChanged(_ sender: NSButton) {
        for r in radios { r.state = r === sender ? .on : .off }
        if !editing { UserDefaults.standard.set(visibility, forKey: "shareVisibility") }
        refresh()
    }

    @objc private func historyChanged(_ sender: NSButton) {
        if !editing { UserDefaults.standard.set(keepHistory, forKey: "shareKeepHistory") }
        if keepHistory { clearHistoryBox.state = .off }
        refresh()
    }

    @objc private func daysChanged(_ sender: NSPopUpButton) {
        if !editing && days >= 0 { UserDefaults.standard.set(days, forKey: "shareDays") }
        refresh()
    }

    func refresh() {
        passwordField.isEnabled = visibility == "password"
        datePicker.isEnabled = !keepExpiry && days == -1
        // 残さない設定にすると、今ある履歴も消える
        if !historyBox.isOn { clearHistoryBox.state = .on }
        clearHistoryBox.isEnabled = historyBox.isOn
    }
}

// MARK: - 公開したリンクの一覧

final class SharedLinksWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = SharedLinksWindow()
    private let table = NSTableView()
    private var rows: [ShareLink.Record] = []

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: true)
        w.title = L("公開したリンク")
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        super.init(window: w)
        for (id, title, width) in [("title", L("題名"), 200.0), ("vis", L("公開のしかた"), 140.0), ("date", L("公開した日"), 120.0), ("exp", L("期限"), 110.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = CGFloat(width)
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.doubleAction = #selector(openLink(_:))
        table.target = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let buttons = NSStackView(views: [
            NSButton(title: L("リンクをコピー"), target: self, action: #selector(copyLink(_:))),
            NSButton(title: L("ブラウザで開く"), target: self, action: #selector(openLink(_:))),
            NSView(),
            NSButton(title: L("公開をやめる"), target: self, action: #selector(unpublish(_:))),
        ])
        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        w.contentView = NSView()
        w.contentView?.addSubview(stack)
        if let c = w.contentView {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: c.topAnchor), stack.bottomAnchor.constraint(equalTo: c.bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: c.leadingAnchor), stack.trailingAnchor.constraint(equalTo: c.trailingAnchor),
                buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            ])
        }
        w.center()
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func reload() {
        // 期限の切れたものは一覧から外す
        let now = Date()
        ShareLink.records = ShareLink.records.filter { $0.expires.map { $0 > now } ?? true }
        rows = ShareLink.records
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy/MM/dd HH:mm"
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "title": text = r.title.isEmpty ? r.url : r.title
        case "vis": text = ShareLink.visibilityName(r.visibility)
        case "date": text = df.string(from: r.created)
        default: text = r.expires.map { df.string(from: $0) } ?? L("期限なし")
        }
        let f = NSTextField(labelWithString: text)
        f.lineBreakMode = .byTruncatingTail
        f.toolTip = r.url
        return f
    }

    private var selected: ShareLink.Record? {
        let i = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        return i >= 0 && i < rows.count ? rows[i] : nil
    }

    @objc private func copyLink(_ sender: Any?) {
        guard let r = selected else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(r.url, forType: .string)
    }

    @objc private func openLink(_ sender: Any?) {
        guard let r = selected, let u = URL(string: r.url) else { return }
        NSWorkspace.shared.open(u)
    }

    @objc private func unpublish(_ sender: Any?) {
        guard let r = selected else { NSSound.beep(); return }
        let a = NSAlert()
        a.messageText = L("「{0}」の公開をやめますか？", r.title.isEmpty ? r.url : r.title)
        a.informativeText = L("リンクを開いても読めなくなります。")
        a.addButton(withTitle: L("公開をやめる"))
        a.addButton(withTitle: L("キャンセル"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        ShareLink.unpublish(r) { [weak self] ok in
            if !ok {
                let e = NSAlert()
                e.messageText = L("公開をやめられませんでした")
                e.informativeText = L("インターネットにつながっているか確かめてください。")
                e.runModal()
            }
            self?.reload()
        }
    }
}

// MARK: - メニューから

extension EditorWindowController {
    /// ファイル > リンクで公開…: いま開いている文書 (選んでいればその部分) を公開する
    @objc func shareLinkHM(_ sender: Any?) {
        guard let doc = document as? Document else { return }
        if doc.isEncrypted {
            let a = NSAlert()
            a.messageText = L("暗号化した文書は公開できません")
            a.informativeText = L("流出防止のためです。")
            if let w = window { a.beginSheetModal(for: w) }
            return
        }
        let tv = textView
        let sel = tv.selectedRange()
        let text = sel.length > 0 ? (tv.string as NSString).substring(with: sel) : tv.string
        let first = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let title = String((first.isEmpty ? (doc.displayName ?? "") : first).prefix(60))
        // 標準エディタは行番号つきのエディタの画面、A4 は紙のテキスト
        let mode = paperMode == .genko ? (horizontalGenko ? "genkoH" : "genko") : paperMode == .a4 ? "text" : "editor"
        // 一部分だけを公開するときは、ファイルの印は付けない
        ShareLink.share(text: text, suggestedTitle: title, mode: mode, file: sel.length > 0 ? nil : doc.fileURL, from: window)
    }
}

extension AppDelegate {
    @objc func showSharedLinksHM(_ sender: Any?) { SharedLinksWindow.shared.show() }
}

// MARK: - メニュー「公開」

extension EditorWindowController {
    /// いま開いているファイルを、テキスト一覧の右クリックと同じ動きに渡す
    private func publishItem(_ object: Any?) -> NSMenuItem {
        let mi = NSMenuItem()
        mi.representedObject = object
        return mi
    }

    @objc func updatePublishedHM(_ sender: Any?) {
        guard let u = hdoc?.fileURL else { return }
        TextLibraryActions.shared.updateShare(publishItem(u))
    }

    @objc func openPublishedHM(_ sender: Any?) {
        guard let u = hdoc?.fileURL, let r = ShareLink.record(for: u), let link = URL(string: r.url) else { return }
        NSWorkspace.shared.open(link)
    }

    @objc func copyPublishedLinkHM(_ sender: Any?) {
        guard let u = hdoc?.fileURL, let r = ShareLink.record(for: u) else { return }
        TextLibraryActions.shared.copyShareLink(publishItem(r.url))
    }

    @objc func unpublishCurrentHM(_ sender: Any?) {
        guard let u = hdoc?.fileURL else { return }
        TextLibraryActions.shared.unpublishItem(publishItem(u))
    }

    /// 公開する前の個人情報の確認を、する / しない
    @objc func togglePrivacyCheckHM(_ sender: Any?) {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: ShareLink.privacyCheckOffKey), forKey: ShareLink.privacyCheckOffKey)
    }
}

// MARK: - 公開の設定を、あとから変える

extension ShareLink {
    /// 公開中のものの設定 (題名・公開のしかた・パスワード・期限) を見て、変える。中身はそのまま
    static func editSettings(_ r: Record, window: NSWindow?) {
        let form = ShareForm(editing: r)
        let a = NSAlert()
        a.messageText = L("公開の設定")
        a.informativeText = r.url
        a.accessoryView = form.view
        a.addButton(withTitle: L("変更する"))
        a.addButton(withTitle: L("キャンセル"))
        a.window.initialFirstResponder = form.titleField
        let handle: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .alertFirstButtonReturn else { return }
            let vis = form.visibility
            if vis == "password" && (r.visibility != "password" || !form.password.isEmpty) && form.password.count < 4 {
                let e = NSAlert()
                e.messageText = L("パスワードは 4 文字以上にしてください")
                e.runModal()
                DispatchQueue.main.async { editSettings(r, window: window) }
                return
            }
            var body: [String: Any] = ["title": form.titleField.stringValue, "visibility": vis]
            if vis == "password" && !form.password.isEmpty { body["password"] = form.password }
            if let e = form.customExpiry { body["expiresAt"] = e.timeIntervalSince1970 } else if !form.keepExpiry { body["days"] = form.days }
            body["keepHistory"] = form.keepHistory
            if form.clearHistory { body["clearHistory"] = true }
            putSettings(r, body: body, window: window)
        }
        if let w = window { a.beginSheetModal(for: w, completionHandler: handle) } else { handle(a.runModal()) }
    }

    private static func putSettings(_ r: Record, body: [String: Any], window: NSWindow?) {
        var req = URLRequest(url: URL(string: base + "/api/share/" + r.id)!)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(r.token, forHTTPHeaderField: "X-Delete-Token")
        req.timeoutInterval = 20
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard err == nil, code == 200, let data = data,
                      let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    let e = NSAlert()
                    e.messageText = L("設定を変えられませんでした")
                    e.informativeText = code == 404 ? L("このページはもう公開されていません。もう一度公開してください。")
                        : err != nil ? L("インターネットにつながっているか確かめてください。") : L("サーバから答えがありませんでした ({0})", code)
                    if let w = window { e.beginSheetModal(for: w) } else { e.runModal() }
                    return
                }
                var nr = r
                if let t = body["title"] as? String, !t.trimmingCharacters(in: .whitespaces).isEmpty { nr.title = t }
                nr.visibility = (o["visibility"] as? String) ?? nr.visibility
                nr.expires = (o["expires"] as? Double).map { Date(timeIntervalSince1970: $0) }
                nr.keepHistory = (o["keepHistory"] as? Bool) ?? nr.keepHistory
                replace(nr)
                let done = NSAlert()
                done.messageText = L("公開の設定を変えました")
                done.informativeText = r.url + "\n" + visibilityName(nr.visibility)
                    + "\n" + ((nr.keepHistory ?? true) ? L("変更履歴: 残す") : L("変更履歴: 残さない"))
                    + ((o["historyCount"] as? Int) == 0 && body["clearHistory"] != nil ? "  " + L("(今までの変更履歴は消しました)") : "")
                done.addButton(withTitle: L("閉じる"))
                if let w = window { done.beginSheetModal(for: w) } else { done.runModal() }
            }
        }.resume()
    }
}

extension EditorWindowController {
    /// メニュー「公開 > 公開の設定…」
    @objc func publishSettingsHM(_ sender: Any?) {
        guard let u = hdoc?.fileURL, let r = ShareLink.record(for: u) else { return }
        ShareLink.editSettings(r, window: window)
    }

    /// いまの文書を、公開してから書き換えたか (「公開中のページを更新」を押せるか)
    var publishedNeedsUpdate: Bool {
        guard let u = hdoc?.fileURL, let r = ShareLink.record(for: u) else { return false }
        let mode = paperMode == .genko ? (horizontalGenko ? "genkoH" : "genko") : paperMode == .a4 ? "text" : "editor"
        return ShareLink.needsUpdate(r, text: textView.string, mode: mode)
    }
}

private extension NSButton {
    var isOn: Bool { state == .on }
}
