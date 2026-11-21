import Foundation
import CryptoKit
import HinokiCore

// リンクで公開: Mac 版 ShareLink.swift と同じく、テキストを docs.satoru.net に送って https://docs.satoru.net/r/<id> で読めるようにする。
// 公開したものは手元に記録 (id・URL・公開をやめるための鍵) を残し、「公開したリンク」から開く・コピー・公開をやめる ができる。

enum ShareStore {
    static var base: String { ProcessInfo.processInfo.environment["SATORU_SHARE_BASE"] ?? "https://docs.satoru.net" }

    struct Record: Codable, Equatable {
        let id: String
        let url: String
        let token: String
        var title: String
        var visibility: String
        let created: Date
        var expires: Date?
        var path: String?
        var contentHash: String?
        var keepHistory: Bool?
        var isAlive: Bool { expires.map { $0 > Date() } ?? true }
    }

    static let didChange = Notification.Name("ShareStoreDidChange")
    private static let recordsKey = "sharedLinks"

    static var records: [Record] {
        get {
            guard let d = UserDefaults.standard.data(forKey: recordsKey) else { return [] }
            return (try? JSONDecoder().decode([Record].self, from: d)) ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: recordsKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// 書類フォルダからの相対パスで覚える (アプリを入れ直すとフォルダの絶対パスが変わるため)
    static func key(_ url: URL) -> String {
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        let r = Library.root.standardizedFileURL.resolvingSymlinksInPath().path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : p
    }

    static func record(for url: URL) -> Record? {
        let k = key(url)
        return records.first { $0.path == k && $0.isAlive }
    }

    static func repath(from old: URL, to new: URL) {
        let o = key(old), n = key(new)
        var changed = false
        let list = records.map { r -> Record in
            var r = r
            if let p = r.path, p == o || p.hasPrefix(o + "/") {
                r.path = n + p.dropFirst(o.count)
                changed = true
            }
            return r
        }
        if changed { records = list }
    }

    static func contentHash(_ text: String, mode: String) -> String {
        SHA256.hash(data: Data((mode + "\u{0}" + text).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func visibilityName(_ v: String) -> String {
        switch v {
        case "public": return L("公開")
        case "password": return L("パスワード")
        default: return L("リンクを知っている人だけ")
        }
    }

    /// 表示 → サーバに送る mode ("editor" / "genko" / "genkoH")
    static func serverMode(_ docMode: String?) -> String {
        docMode == "genko" || docMode == "genkoH" ? docMode! : "editor"
    }

    // MARK: 公開する

    /// 標準エディタで公開するときの見た目 (この版のエディタの色 = Mac 版の「ライト」と同じ色)
    static func editorTheme(lineNumbers: Bool) -> [String: Any] {
        let c = EditorTheme.light
        var t: [String: Any] = [:]
        for k in ["background", "text", "gutterBackground", "gutterText", "gutterSeparator", "newlineMark", "eof", "chrome", "chromeText",
                  "currentLine", "currentLineText", "gutterCurrentText", "selection", "caret"] {
            t[k] = String((c[k] ?? "#000000").prefix(7))
        }
        t["marks"] = false
        t["ruler"] = false
        t["currentLineOn"] = false
        _ = lineNumbers
        return t
    }

    /// 作文: アプリで原稿用紙に並べたとおり (自動整形・ふりがな) をサーバに渡す (Mac 版と同じ形)
    static func genkoLayout(_ text: String, horizontal: Bool) -> [String: Any] {
        let auto = !horizontal && Prefs.genkoAutoFormat
        let columns = Genko.layout(text, autoFormat: auto)
        var ruby: [String: [[Any]]] = [:]
        if Prefs.furigana {
            for (col, list) in Genko.placeRuby(columns, Furigana.ruby(for: text)) {
                ruby[String(col)] = list.map { [$0.row, $0.rows, $0.text] }
            }
        }
        return ["columns": columns.map { c in c.cells.map { $0 as Any? ?? NSNull() } }, "ruby": ruby]
    }

    struct Form {
        var title = ""
        var visibility = "unlisted"
        var password = ""
        var days = 30
        var keepHistory = true
    }

    static func body(text: String, mode: String, form: Form) -> [String: Any] {
        var body: [String: Any] = ["text": text, "title": form.title, "mode": mode, "visibility": form.visibility, "days": form.days,
                                   "keepHistory": form.keepHistory]
        if mode == "genko" || mode == "genkoH" { body["layout"] = genkoLayout(text, horizontal: mode == "genkoH") }
        if mode == "editor" { body["theme"] = editorTheme(lineNumbers: Prefs.lineNumbers) }
        if form.visibility == "password" { body["password"] = form.password }
        return body
    }

    static func errorText(code: Int, error: Error?) -> String {
        code == 429 ? L("短い時間にたくさん公開したので、少し待ってからもう一度試してください。")
            : error != nil ? L("インターネットにつながっているか確かめてください。") : L("サーバから答えがありませんでした ({0})", code)
    }

    /// 送る。成功したら記録を残して返す
    static func upload(text: String, mode: String, form: Form, file: URL?, completion: @escaping (Result<Record, LibraryError>) -> Void) {
        var req = URLRequest(url: URL(string: base + "/api/share")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try? JSONSerialization.data(withJSONObject: body(text: text, mode: mode, form: form))
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard err == nil, code == 200, let data = data,
                      let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let id = o["id"] as? String, let url = o["url"] as? String, let token = o["token"] as? String else {
                    return completion(.failure(LibraryError(errorText(code: code, error: err))))
                }
                let exp = (o["expires"] as? Double).map { Date(timeIntervalSince1970: $0) }
                let r = Record(id: id, url: url, token: token, title: form.title, visibility: form.visibility, created: Date(), expires: exp,
                               path: file.map(key), contentHash: contentHash(text, mode: mode), keepHistory: form.keepHistory)
                records = [r] + records
                completion(.success(r))
            }
        }.resume()
    }

    /// 公開中のページを今の内容にする (URL・公開のしかた・期限はそのまま)
    static func update(_ r: Record, text: String, mode: String, completion: @escaping (Result<Record, LibraryError>) -> Void) {
        var req = URLRequest(url: URL(string: base + "/api/share/" + r.id)!)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(r.token, forHTTPHeaderField: "X-Delete-Token")
        req.timeoutInterval = 30
        var body: [String: Any] = ["text": text, "title": r.title, "mode": mode]
        if mode == "genko" || mode == "genkoH" { body["layout"] = genkoLayout(text, horizontal: mode == "genkoH") }
        if mode == "editor" { body["theme"] = editorTheme(lineNumbers: Prefs.lineNumbers) }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { _, resp, err in
            DispatchQueue.main.async {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard err == nil, code == 200 else {
                    if code == 404 { records = records.filter { $0.id != r.id } }
                    return completion(.failure(LibraryError(code == 404 ? L("このページはもう公開されていません。もう一度公開してください。")
                                                            : errorText(code: code, error: err))))
                }
                var nr = r
                nr.contentHash = contentHash(text, mode: mode)
                records = records.map { $0.id == r.id ? nr : $0 }
                completion(.success(nr))
            }
        }.resume()
    }

    // MARK: 公開をやめる

    static func unpublish(_ r: Record, completion: @escaping (Bool) -> Void) {
        var req = URLRequest(url: URL(string: base + "/api/share/" + r.id)!)
        req.httpMethod = "DELETE"
        req.setValue(r.token, forHTTPHeaderField: "X-Delete-Token")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { _, resp, err in
            DispatchQueue.main.async {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                // サーバにもう無い (期限切れなど) ときも、記録は消す
                let ok = err == nil && (code == 200 || code == 404)
                if ok { records = records.filter { $0.id != r.id } }
                completion(ok)
            }
        }.resume()
    }
}

/// エディタの色 (Mac 版のテーマ「ライト」「ダーク」と同じ値)
enum EditorTheme {
    static let light: [String: String] = [
        "background": "#FFFFFF", "text": "#1E1E1E", "caret": "#000000", "selection": "#B4D5FE", "currentLine": "#0000000A",
        "currentLineText": "#A8862A", "gutterBackground": "#F3F3F3", "gutterText": "#8A8A8A", "gutterCurrentText": "#A8862A",
        "gutterSeparator": "#DDDDDD", "chrome": "#E8E8E8", "chromeText": "#333333", "newlineMark": "#2A9FB0", "invisible": "#BBBBBB",
        "eof": "#2A9FB0",
    ]
    static let dark: [String: String] = [
        "background": "#2B2B2B", "text": "#E5E5E5", "caret": "#E5E5E5", "selection": "#2F5A8A", "currentLine": "#FFFFFF0B",
        "currentLineText": "#D0AF4C", "gutterBackground": "#2B2B2B", "gutterText": "#E5E5E5", "gutterCurrentText": "#D0AF4C",
        "gutterSeparator": "#484848", "chrome": "#484848", "chromeText": "#E5E5E5", "newlineMark": "#31E3E5", "invisible": "#828282",
        "eof": "#31E3E5",
    ]
}
