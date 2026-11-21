import AppKit
import JavaScriptCore
import HinokiCore

/// 1 つの JS 拡張機能。manifest.json と main.js の入ったフォルダ
final class Plugin {
    let manifest: PluginManifest
    let folder: URL
    private(set) var context: JSContext?

    struct Command {
        let id: String
        let title: String
        let key: PluginShortcut?
        let run: JSValue
    }
    private(set) var commands: [Command] = []
    private var handlers: [String: [JSValue]] = [:]
    private var completionProviders: [JSValue] = []
    private var timers: [Int: DispatchWorkItem] = [:]
    private var nextTimer = 1

    struct LogLine {
        let date: Date
        let error: Bool
        let text: String
    }
    private(set) var log: [LogLine] = []
    /// 読み込みに失敗したときの理由
    private(set) var loadError: String?

    var isRunning: Bool { context != nil }

    init(manifest: PluginManifest, folder: URL) {
        self.manifest = manifest
        self.folder = folder
    }

    func addLog(_ text: String, error: Bool = false) {
        log.append(LogLine(date: Date(), error: error, text: text))
        if log.count > 300 { log.removeFirst(log.count - 300) }
        NotificationCenter.default.post(name: .pluginLogDidChange, object: self)
    }

    // MARK: 読み込み・止める

    func start() {
        stop()
        loadError = nil
        let mainURL = folder.appendingPathComponent(manifest.main).resolvingSymlinksInPath()
        // フォルダの外 (シンボリックリンクの先など) は読まない
        guard mainURL.path.hasPrefix(folder.resolvingSymlinksInPath().path + "/") else {
            fail(L("{0} がフォルダの外を指しています", manifest.main)); return
        }
        guard let source = try? String(contentsOf: mainURL, encoding: .utf8) else {
            fail(L("{0} を読めませんでした", manifest.main)); return
        }
        guard let ctx = JSContext() else { fail(L("JavaScript を動かせませんでした")); return }
        ctx.name = manifest.name
        ctx.exceptionHandler = { [weak self] _, ex in
            guard let ex = ex else { return }
            let line = ex.objectForKeyedSubscript("line").map { $0.isUndefined ? "" : " (" + L("{0} 行目", $0.toInt32()) + ")" } ?? ""
            self?.addLog("\(ex.toString() ?? "error")\(line)", error: true)
        }
        context = ctx
        installAPI(in: ctx)
        ctx.evaluateScript(source, withSourceURL: mainURL)
        addLog(L("読み込みました (コマンド {0} 個)", commands.count))
    }

    private func fail(_ message: String) {
        loadError = message
        addLog(message, error: true)
    }

    func stop() {
        timers.values.forEach { $0.cancel() }
        timers.removeAll()
        commands.removeAll()
        handlers.removeAll()
        completionProviders.removeAll()
        context = nil
    }

    // MARK: 呼び出し

    func run(command id: String) {
        guard let c = commands.first(where: { $0.id == id }) else { return }
        c.run.call(withArguments: [])
    }

    func emit(_ event: String, _ info: [String: Any]) {
        for h in handlers[event] ?? [] { h.call(withArguments: [info]) }
    }

    func hasHandlers(_ event: String) -> Bool { !(handlers[event] ?? []).isEmpty }

    func completions(_ info: [String: Any]) -> [Completion.Item] {
        var out: [Completion.Item] = []
        for p in completionProviders {
            guard let list = p.call(withArguments: [info]), list.isArray, let n = list.forProperty("length")?.toInt32() else { continue }
            for i in 0..<min(Int(n), 500) {
                guard let v = list.atIndex(i) else { continue }
                if v.isString, let s = v.toString() {
                    out.append(Completion.Item(label: s, kind: .snippet))
                } else if v.isObject, let label = v.forProperty("label")?.toString(), !label.isEmpty, label != "undefined" {
                    let detail = v.forProperty("detail").flatMap { $0.isString ? $0.toString() : nil } ?? manifest.name
                    var kind = Completion.Kind.snippet
                    switch v.forProperty("kind")?.toString() {
                    case "function": kind = .function
                    case "keyword": kind = .keyword
                    case "type": kind = .type
                    case "property": kind = .property
                    case "word": kind = .word
                    default: break
                    }
                    if kind == .function, detail.hasPrefix("(") {
                        out.append(.function(label + detail))
                    } else {
                        out.append(Completion.Item(label: label, kind: kind, detail: detail))
                    }
                }
            }
        }
        return out
    }

    // MARK: JS に見せる API (satoru.*)

    private func installAPI(in ctx: JSContext) {
        let n = JSValue(newObjectIn: ctx)!
        func def(_ name: String, _ block: Any) { n.setObject(block, forKeyedSubscript: name as NSString) }
        let m = manifest

        def("appVersion", (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev")
        let registerCommand: @convention(block) (String, String, String, JSValue) -> Void = { [weak self] id, title, key, fn in
            guard let self = self else { return }
            self.commands.removeAll { $0.id == id }
            self.commands.append(Command(id: id, title: title, key: PluginShortcut.parse(key), run: fn))
            PluginManager.shared.commandsChanged()
        }
        def("registerCommand", registerCommand)
        let on: @convention(block) (String, JSValue) -> Void = { [weak self] event, fn in
            self?.handlers[event, default: []].append(fn)
        }
        def("on", on)
        let addCompletion: @convention(block) (JSValue) -> Void = { [weak self] fn in self?.completionProviders.append(fn) }
        def("addCompletion", addCompletion)

        // 文書
        let getText: @convention(block) () -> String = { PluginManager.shared.targetText?.string ?? "" }
        def("getText", getText)
        let setText: @convention(block) (String) -> Void = { s in
            guard let tv = PluginManager.shared.targetText else { return }
            let sel = tv.selectedRange()
            tv.replace(NSRange(location: 0, length: (tv.string as NSString).length), with: s,
                       select: NSRange(location: min(sel.location, (s as NSString).length), length: 0))
        }
        def("setText", setText)
        let getSelection: @convention(block) () -> [String: Any] = {
            guard let tv = PluginManager.shared.targetText else { return ["start": 0, "end": 0, "text": ""] }
            let r = tv.selectedRange()
            return ["start": r.location, "end": NSMaxRange(r), "text": (tv.string as NSString).substring(with: r)]
        }
        def("getSelection", getSelection)
        let replaceSelection: @convention(block) (String) -> Void = { s in
            guard let tv = PluginManager.shared.targetText else { return }
            let r = tv.selectedRange()
            tv.replace(r, with: s, select: NSRange(location: r.location + (s as NSString).length, length: 0))
        }
        def("replaceSelection", replaceSelection)
        let select: @convention(block) (Int, Int) -> Void = { a, b in
            guard let tv = PluginManager.shared.targetText else { return }
            let len = (tv.string as NSString).length
            let s = max(0, min(a, len)), e = max(s, min(b, len))
            tv.setSelectedRange(NSRange(location: s, length: e - s))
            tv.scrollRangeToVisible(NSRange(location: s, length: e - s))
        }
        def("select", select)
        let language: @convention(block) () -> String = { PluginManager.shared.targetEditor?.profile?.name ?? "" }
        def("language", language)
        let fileName: @convention(block) () -> String = { PluginManager.shared.targetEditor?.hdoc?.displayName ?? "" }
        def("fileName", fileName)
        let filePath: @convention(block) () -> String = {
            guard let d = PluginManager.shared.targetEditor?.hdoc else { return "" }
            if let r = d.remote { return r.path }
            return d.fileURL?.path ?? ""
        }
        def("filePath", filePath)

        // 画面
        let toast: @convention(block) (String, String) -> Void = { title, detail in
            _ = Toast.show(in: PluginManager.shared.targetEditor?.window, kind: .info, title: title, detail: detail)
        }
        def("toast", toast)
        let alert: @convention(block) (String) -> Void = { msg in
            let a = NSAlert()
            a.messageText = m.name
            a.informativeText = msg
            a.runModal()
        }
        def("alert", alert)
        let confirm: @convention(block) (String) -> Bool = { msg in
            let a = NSAlert()
            a.messageText = m.name
            a.informativeText = msg
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: L("キャンセル"))
            return a.runModal() == .alertFirstButtonReturn
        }
        def("confirm", confirm)
        let prompt: @convention(block) (String, String) -> JSValue = { msg, value in
            let a = NSAlert()
            a.messageText = m.name
            a.informativeText = msg
            let field = NSTextField(string: value)
            field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
            a.accessoryView = field
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: L("キャンセル"))
            a.window.initialFirstResponder = field
            let ok = a.runModal() == .alertFirstButtonReturn
            return ok ? JSValue(object: field.stringValue, in: JSContext.current()) : JSValue(nullIn: JSContext.current())
        }
        def("prompt", prompt)

        // 保存 (拡張機能ごと)
        let storeKey = "plugin.\(m.id)"
        let storageGet: @convention(block) (String) -> JSValue = { k in
            let d = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String]
            guard let v = d?[k] else { return JSValue(undefinedIn: JSContext.current()) }
            return JSValue(object: v, in: JSContext.current())
        }
        def("storageGet", storageGet)
        let storageSet: @convention(block) (String, String) -> Void = { k, v in
            var d = (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String]) ?? [:]
            d[k] = v
            UserDefaults.standard.set(d, forKey: storeKey)
        }
        def("storageSet", storageSet)

        // クリップボード (権限が要る)
        let clipboardRead: @convention(block) () -> String = { [weak self] in
            guard m.has(.clipboard) else { self?.denied("clipboard"); return "" }
            return NSPasteboard.general.string(forType: .string) ?? ""
        }
        def("clipboardRead", clipboardRead)
        let clipboardWrite: @convention(block) (String) -> Void = { [weak self] s in
            guard m.has(.clipboard) else { self?.denied("clipboard"); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
        def("clipboardWrite", clipboardWrite)

        // ネット (権限が要る)
        let fetch: @convention(block) (String, String, JSValue) -> Void = { [weak self] urlText, optsJSON, done in
            guard let self = self else { return }
            guard m.has(.network) else {
                self.denied("network")
                done.call(withArguments: [L("この拡張機能にはネットを使う権限がありません"), 0, "", [:]])
                return
            }
            guard let url = URL(string: urlText), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                done.call(withArguments: [L("URL が正しくありません: {0}", urlText), 0, "", [:]])
                return
            }
            var req = URLRequest(url: url, timeoutInterval: 30)
            if let data = optsJSON.data(using: .utf8),
               let opts = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let method = opts["method"] as? String { req.httpMethod = method.uppercased() }
                if let headers = opts["headers"] as? [String: Any] {
                    for (k, v) in headers { req.setValue("\(v)", forHTTPHeaderField: k) }
                }
                if let body = opts["body"] as? String { req.httpBody = body.data(using: .utf8) }
            }
            self.addLog("fetch \(req.httpMethod ?? "GET") \(url.absoluteString)")
            URLSession.shared.dataTask(with: req) { data, resp, error in
                DispatchQueue.main.async {
                    guard self.context != nil else { return }
                    if let error = error {
                        done.call(withArguments: [error.localizedDescription, 0, "", [:]])
                        return
                    }
                    let http = resp as? HTTPURLResponse
                    var headers: [String: String] = [:]
                    for (k, v) in http?.allHeaderFields ?? [:] { headers["\(k)".lowercased()] = "\(v)" }
                    let body = data.flatMap { String(data: $0, encoding: .utf8) ?? String(data: $0, encoding: .isoLatin1) } ?? ""
                    done.call(withArguments: [NSNull(), http?.statusCode ?? 0, body, headers])
                }
            }.resume()
        }
        def("fetch", fetch)

        // タイマー・ログ
        let setTimeout: @convention(block) (JSValue, Double) -> Int = { [weak self] fn, ms in
            guard let self = self else { return 0 }
            let id = self.nextTimer
            self.nextTimer += 1
            let work = DispatchWorkItem { [weak self] in
                self?.timers[id] = nil
                fn.call(withArguments: [])
            }
            self.timers[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, ms) / 1000, execute: work)
            return id
        }
        def("setTimeout", setTimeout)
        let clearTimeout: @convention(block) (Int) -> Void = { [weak self] id in
            self?.timers[id]?.cancel()
            self?.timers[id] = nil
        }
        def("clearTimeout", clearTimeout)
        let log: @convention(block) (String, String) -> Void = { [weak self] level, text in
            self?.addLog(text, error: level == "error")
        }
        def("log", log)

        ctx.setObject(n, forKeyedSubscript: "__native" as NSString)
        ctx.evaluateScript(Self.bootstrap)
        ctx.evaluateScript("delete globalThis.__native;")
    }

    private func denied(_ permission: String) {
        addLog(L("権限「{0}」がないので使えません。manifest.json の permissions に書いてください", permission), error: true)
    }

    /// satoru.* を __native の上に組み立てる
    private static let bootstrap = #"""
    (function (n) {
      const fmt = v => {
        if (typeof v === 'string') return v;
        if (v instanceof Error) return v.message;
        try { return JSON.stringify(v); } catch (e) { return String(v); }
      };
      const satoru = Object.freeze({
        version: n.appVersion,
        commands: Object.freeze({
          register(spec, fn) {
            if (typeof spec === 'string') spec = { id: spec, title: spec };
            if (typeof fn !== 'function') throw new Error('commands.register: function required');
            n.registerCommand(String(spec.id || spec.title), String(spec.title || spec.id), String(spec.key || ''), fn);
          },
        }),
        on(event, fn) { n.on(String(event), fn); },
        editor: Object.freeze({
          getText() { return n.getText(); },
          setText(s) { n.setText(String(s)); },
          getSelection() { return n.getSelection(); },
          replaceSelection(s) { n.replaceSelection(String(s)); },
          insert(s) { n.replaceSelection(String(s)); },
          select(start, end) { n.select(start | 0, (end === undefined ? start : end) | 0); },
          language() { return n.language(); },
          fileName() { return n.fileName(); },
          filePath() { return n.filePath(); },
        }),
        completion: Object.freeze({ register(fn) { n.addCompletion(fn); } }),
        ui: Object.freeze({
          toast(title, detail) { n.toast(String(title), detail == null ? '' : String(detail)); },
          alert(msg) { n.alert(String(msg)); },
          confirm(msg) { return n.confirm(String(msg)); },
          prompt(msg, value) { return n.prompt(String(msg), value == null ? '' : String(value)); },
        }),
        storage: Object.freeze({
          get(key, fallback) {
            const v = n.storageGet(String(key));
            if (v === undefined || v === null) return fallback;
            try { return JSON.parse(v); } catch (e) { return fallback; }
          },
          set(key, value) { n.storageSet(String(key), JSON.stringify(value)); },
        }),
        clipboard: Object.freeze({
          readText() { return n.clipboardRead(); },
          writeText(s) { n.clipboardWrite(String(s)); },
        }),
        fetch(url, options) {
          return new Promise((resolve, reject) => {
            n.fetch(String(url), JSON.stringify(options || {}), (err, status, body, headers) => {
              if (err) { reject(new Error(err)); return; }
              resolve({
                status, ok: status >= 200 && status < 300, headers,
                text: () => Promise.resolve(body),
                json: () => new Promise((ok, ng) => { try { ok(JSON.parse(body)); } catch (e) { ng(e); } }),
              });
            });
          });
        },
      });
      globalThis.satoru = satoru;
      globalThis.console = {
        log: (...a) => n.log('info', a.map(fmt).join(' ')),
        info: (...a) => n.log('info', a.map(fmt).join(' ')),
        warn: (...a) => n.log('info', a.map(fmt).join(' ')),
        error: (...a) => n.log('error', a.map(fmt).join(' ')),
      };
      globalThis.setTimeout = (fn, ms, ...args) => n.setTimeout(() => fn(...args), Number(ms) || 0);
      globalThis.clearTimeout = id => n.clearTimeout(id | 0);
    })(__native);
    """#
}

extension Notification.Name {
    static let pluginLogDidChange = Notification.Name("satomaru.pluginLogDidChange")
    static let pluginsDidChange = Notification.Name("satomaru.pluginsDidChange")
}
