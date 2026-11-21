import AppKit
import AVFoundation
import HinokiCore

// 読み上げ (追加機能「読み上げ・音声入力」の半分)。
// 声は 2 種類から選ぶ: Mac に入っている声 (AVSpeechSynthesizer) か、VOICEVOX (別のアプリ。この Mac の中で動くエンジンに頼んで声を作る)。
// 読んでいる間は、ウインドウの下に操作の欄 (ぐるぐる・一時停止 / 再生・最初から・停止) を出す。

// MARK: - 設定の値

enum ReadingSettings {
    private static var d: UserDefaults { .standard }
    private static func double(_ key: String, _ def: Double) -> Double { d.object(forKey: key) as? Double ?? def }

    /// "system" (Mac の声) / "voicevox"
    static var engine: String {
        get { d.string(forKey: "speechEngine") == "voicevox" ? "voicevox" : "system" }
        set { d.set(newValue, forKey: "speechEngine") }
    }

    // Mac の声
    static var systemVoice: AVSpeechSynthesisVoice? {
        if let id = d.string(forKey: "speechVoice"), !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return macDefaultVoice ?? AVSpeechSynthesisVoice(language: I18n.language == "en" ? "en-US" : "ja-JP")
    }

    /// その Mac で選んである読み上げの声 (システム設定 > アクセシビリティ > 読み上げコンテンツ)。
    /// 表示の言葉と合わない声 (日本語の画面で英語の声など) のときは使わない
    static var macDefaultVoice: AVSpeechSynthesisVoice? {
        let sys = NSSpeechSynthesizer.defaultVoice
        if let v = AVSpeechSynthesisVoice(identifier: sys.rawValue) { return v.language.hasPrefix(I18n.language == "en" ? "en" : "ja") ? v : nil }
        // 名前の付け方がちがうので、声の名前 (Kyoko など) で探す。同じ名前がいくつかあれば、いちばん良い音質
        guard let name = NSSpeechSynthesizer.attributes(forVoice: sys)[.name] as? String else { return nil }
        let lang = I18n.language == "en" ? "en" : "ja"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.name == name && $0.language.hasPrefix(lang) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
    }
    static var rate: Double { double("speechRate", Double(AVSpeechUtteranceDefaultSpeechRate)) }
    static var pitch: Double { double("speechPitch", 1.0) }   // 0.5 〜 2
    static var volume: Double { double("speechVolume", 1.0) } // 0 〜 1

    // VOICEVOX
    static var vvURL: String {
        let s = (d.string(forKey: "vvURL") ?? "").trimmingCharacters(in: .whitespaces)
        return (s.isEmpty ? "http://127.0.0.1:50021" : s).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }
    static var vvSpeaker: Int { d.object(forKey: "vvSpeaker") as? Int ?? 3 } // 3 = ずんだもん (ノーマル)
    static var vvSpeakerName: String { d.string(forKey: "vvSpeakerName") ?? "ずんだもん (ノーマル)" }
    static var vvSpeed: Double { double("vvSpeed", 1.0) }          // 0.5 〜 2
    static var vvPitch: Double { double("vvPitch", 0.0) }          // -0.15 〜 0.15
    static var vvIntonation: Double { double("vvIntonation", 1.0) } // 0 〜 2
    static var vvVolume: Double { double("vvVolume", 1.0) }        // 0 〜 2
    static let vvKeys = ["vvSpeed", "vvPitch", "vvIntonation", "vvVolume"]
    static let systemKeys = ["speechRate", "speechPitch", "speechVolume"]
}

// MARK: - VOICEVOX とのやりとり

enum VoiceVox {
    static let downloadURL = URL(string: "https://voicevox.hiroshiba.jp/")!
    static let termsURL = URL(string: "https://voicevox.hiroshiba.jp/term/")!

    struct Style { let name: String; let id: Int }
    struct Speaker { let name: String; let styles: [Style] }

    enum Failure: LocalizedError {
        case notRunning, bad(String)
        var errorDescription: String? {
            switch self {
            case .notRunning: return L("VOICEVOX につながりません。VOICEVOX を起動してください。")
            case .bad(let s): return s
            }
        }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        return URLSession(configuration: c)
    }()

    private static func url(_ path: String, _ query: [String: String] = [:]) -> URL? {
        var c = URLComponents(string: ReadingSettings.vvURL + path)
        if !query.isEmpty { c?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return c?.url
    }

    private static func call(_ req: URLRequest, _ done: @escaping (Result<Data, Error>) -> Void) {
        session.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if err != nil { done(.failure(Failure.notRunning)); return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200, let data = data else {
                    done(.failure(Failure.bad(L("VOICEVOX から答えがありませんでした ({0})", code)))); return
                }
                done(.success(data))
            }
        }.resume()
    }

    /// 動いているか (版を聞いてみる)
    static func version(_ done: @escaping (String?) -> Void) {
        guard let u = url("/version") else { done(nil); return }
        var r = URLRequest(url: u)
        r.timeoutInterval = 2
        call(r) { res in
            if case .success(let d) = res { done(String(data: d, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))) } else { done(nil) }
        }
    }

    /// 使える声 (キャラクターと話し方) の一覧
    static func speakers(_ done: @escaping (Result<[Speaker], Error>) -> Void) {
        guard let u = url("/speakers") else { done(.failure(Failure.notRunning)); return }
        call(URLRequest(url: u)) { res in
            switch res {
            case .failure(let e): done(.failure(e))
            case .success(let data):
                let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
                done(.success(list.map { s in
                    let styles = (s["styles"] as? [[String: Any]] ?? []).compactMap { st -> Style? in
                        guard let id = st["id"] as? Int else { return nil }
                        return Style(name: st["name"] as? String ?? "", id: id)
                    }
                    return Speaker(name: s["name"] as? String ?? "", styles: styles)
                }))
            }
        }
    }

    /// 文 → 声 (WAV)。速さ・高さ・抑揚・音量は設定の値
    static func synthesize(_ text: String, speaker: Int, _ done: @escaping (Result<Data, Error>) -> Void) {
        guard let q = url("/audio_query", ["text": text, "speaker": String(speaker)]) else { done(.failure(Failure.notRunning)); return }
        var r = URLRequest(url: q)
        r.httpMethod = "POST"
        call(r) { res in
            switch res {
            case .failure(let e): done(.failure(e))
            case .success(let data):
                guard var query = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let s = url("/synthesis", ["speaker": String(speaker)]) else { done(.failure(Failure.bad(L("VOICEVOX の答えを読めませんでした")))); return }
                query["speedScale"] = ReadingSettings.vvSpeed
                query["pitchScale"] = ReadingSettings.vvPitch
                query["intonationScale"] = ReadingSettings.vvIntonation
                query["volumeScale"] = ReadingSettings.vvVolume
                var r2 = URLRequest(url: s)
                r2.httpMethod = "POST"
                r2.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r2.httpBody = try? JSONSerialization.data(withJSONObject: query)
                call(r2, done)
            }
        }
    }

    /// 入っている VOICEVOX のアプリ
    static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "jp.hiroshiba.voicevox")
            ?? ["/Applications/VOICEVOX.app", NSHomeDirectory() + "/Applications/VOICEVOX.app"].map { URL(fileURLWithPath: $0) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 動かせる VOICEVOX があるか (このアプリで入れたもの、または入っている VOICEVOX アプリ)
    static var canLaunch: Bool { VoiceVoxInstaller.info != nil || appURL != nil }

    /// VOICEVOX を後ろで動かして、つながるまで待つ (最大 60 秒)。
    /// このアプリで入れたエンジンがあればそれを (画面を出さずに)、なければ VOICEVOX アプリを隠して起動する
    static func launchAndWait(_ done: @escaping (Bool) -> Void) {
        if VoiceVoxInstaller.info != nil {
            VoiceVoxInstaller.shared.startEngine()
        } else if let app = appURL {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            cfg.hides = true
            NSWorkspace.shared.openApplication(at: app, configuration: cfg) { _, _ in }
        } else {
            done(false)
            return
        }
        var tries = 0
        func poll() {
            version { v in
                if v != nil { done(true); return }
                tries += 1
                if tries > 60 { done(false); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { poll() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { poll() }
    }
}

// MARK: - 読み上げ

final class SpeechReader: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = SpeechReader()

    /// 読んでいる (一時停止中も含む)
    private(set) var isActive = false
    private(set) var isPaused = false

    private weak var textView: NSTextView?
    private weak var window: NSWindow?
    private var range = NSRange(location: 0, length: 0) // 読む範囲 (文章の中の位置)
    private var expectedLength = 0
    private var hud: ReadingHUD?
    private var usingVoiceVox = false

    // Mac の声
    private let synth = AVSpeechSynthesizer()
    // VOICEVOX: 文ごとに声を作って、順に鳴らす
    private var chunks: [NSRange] = []
    private var index = 0
    private var audio: [Int: Data] = [:]
    private var waiting: Set<Int> = []
    private var player: AVAudioPlayer?
    /// 止めたあとに届いた答えを捨てるための番号
    private var generation = 0

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: 操作

    func speak(_ tv: NSTextView, in window: NSWindow?) {
        stop()
        let ns = tv.string as NSString
        var r = tv.selectedRange()
        if r.length == 0 { r = NSRange(location: r.location, length: ns.length - r.location) }
        // カーソルが最後にあるときは、はじめから読む
        if r.length == 0 { r = NSRange(location: 0, length: ns.length) }
        guard !ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
        Dictation.shared.stop() // 自分の声を拾わないように
        textView = tv
        self.window = window ?? tv.window
        range = r
        expectedLength = ns.length
        isActive = true
        isPaused = false
        usingVoiceVox = ReadingSettings.engine == "voicevox"
        showHUD()
        start()
    }

    /// 同じ範囲を、はじめから読み直す
    func restart() {
        guard isActive, let tv = textView else { return }
        let r = range, w = window
        stopPlayback()
        guard (tv.string as NSString).length == expectedLength else { stop(); return }
        tv.setSelectedRange(r)
        isActive = false
        speak(tv, in: w)
    }

    func togglePause() {
        guard isActive else { return }
        if isPaused {
            isPaused = false
            if usingVoiceVox {
                if let p = player { p.play() } else { playChunk(index) }
            } else {
                synth.continueSpeaking()
            }
        } else {
            isPaused = true
            if usingVoiceVox { player?.pause() } else { synth.pauseSpeaking(at: .word) }
        }
        hud?.update(paused: isPaused, loading: false, title: title)
    }

    func stop() {
        guard isActive else { return }
        stopPlayback()
        finish()
    }

    private func stopPlayback() {
        generation += 1
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
        player?.stop()
        player = nil
        audio = [:]
        waiting = []
    }

    private func finish() {
        isActive = false
        isPaused = false
        hud?.close()
        hud = nil
        textView = nil
    }

    private var title: String {
        usingVoiceVox ? L("読み上げ中 (VOICEVOX:{0})", ReadingSettings.vvSpeakerName) : L("読み上げ中")
    }

    private func showHUD() {
        guard let w = window else { return }
        let h = ReadingHUD()
        h.onPlayPause = { [weak self] in self?.togglePause() }
        h.onRestart = { [weak self] in self?.restart() }
        h.onStop = { [weak self] in self?.stop() }
        h.show(over: w)
        h.update(paused: false, loading: usingVoiceVox, title: title)
        hud = h
    }

    /// 文章が書き換わったら、読んでいる場所がずれるので止める
    private func textChanged() -> Bool {
        guard let tv = textView else { return true }
        return (tv.string as NSString).length != expectedLength
    }

    private func highlight(_ r: NSRange) {
        guard let tv = textView, NSMaxRange(r) <= expectedLength else { return }
        tv.setSelectedRange(r)
        tv.scrollRangeToVisible(r)
    }

    private func start() {
        guard let tv = textView else { return }
        let text = (tv.string as NSString).substring(with: range)
        if usingVoiceVox {
            chunks = Self.sentences(in: text).map { NSRange(location: range.location + $0.location, length: $0.length) }
            index = 0
            // VOICEVOX が動いていなければ、先に動かしてから読む
            let gen = generation
            VoiceVox.version { [weak self] v in
                guard let self = self, gen == self.generation, self.isActive else { return }
                if v != nil || !VoiceVox.canLaunch { self.playChunk(0); return }
                self.hud?.update(paused: false, loading: true, title: self.title)
                VoiceVox.launchAndWait { ok in
                    guard gen == self.generation, self.isActive else { return }
                    if ok { self.playChunk(0) } else { self.failed(VoiceVox.Failure.notRunning) }
                }
            }
        } else {
            let u = AVSpeechUtterance(string: text)
            u.voice = ReadingSettings.systemVoice
            u.rate = Float(max(Double(AVSpeechUtteranceMinimumSpeechRate), min(Double(AVSpeechUtteranceMaximumSpeechRate), ReadingSettings.rate)))
            u.pitchMultiplier = Float(max(0.5, min(2, ReadingSettings.pitch)))
            u.volume = Float(max(0, min(1, ReadingSettings.volume)))
            synth.speak(u)
        }
    }

    // MARK: Mac の声

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        guard isActive, !usingVoiceVox else { return }
        if textChanged() { stop(); return }
        highlight(NSRange(location: range.location + characterRange.location, length: characterRange.length))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if isActive && !usingVoiceVox { finish() }
    }

    // MARK: VOICEVOX

    /// 読む文の区切り: 。！？ と改行のあと。長すぎる文は 120 字で切る
    static func sentences(in text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        var start = 0
        func push(_ end: Int) {
            let r = NSRange(location: start, length: end - start)
            if r.length > 0, !ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(r) }
            start = end
        }
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            i += 1
            if [0x3002, 0xFF01, 0xFF1F, 0x21, 0x3F, 0x0A].contains(c) || i - start >= 120 {
                // 文の終わりのかぎかっこも、その文に入れる
                while i < ns.length, [0x300D, 0x300F, 0xFF09, 0x29].contains(ns.character(at: i)) { i += 1 }
                push(i)
            }
        }
        push(ns.length)
        return out
    }

    private func fetch(_ i: Int) {
        guard i < chunks.count, audio[i] == nil, !waiting.contains(i), let tv = textView else { return }
        waiting.insert(i)
        let gen = generation
        let text = (tv.string as NSString).substring(with: chunks[i]).trimmingCharacters(in: .whitespacesAndNewlines)
        VoiceVox.synthesize(text, speaker: ReadingSettings.vvSpeaker) { [weak self] res in
            guard let self = self, gen == self.generation, self.isActive else { return }
            self.waiting.remove(i)
            switch res {
            case .success(let data):
                self.audio[i] = data
                if i == self.index, self.player == nil, !self.isPaused { self.playChunk(i) }
            case .failure(let e):
                self.failed(e)
            }
        }
    }

    private func playChunk(_ i: Int) {
        guard isActive else { return }
        if textChanged() { stop(); return }
        guard i < chunks.count else { stopPlayback(); finish(); return }
        index = i
        guard let data = audio[i] else {
            hud?.update(paused: isPaused, loading: true, title: title)
            fetch(i)
            return
        }
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            player = p
            highlight(chunks[i])
            hud?.update(paused: isPaused, loading: false, title: title)
            if !isPaused { p.play() }
            audio[i - 1] = nil // 鳴らし終えたものは捨てる
            fetch(i + 1)       // 次の文を先に作っておく
        } catch {
            failed(error)
        }
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        guard p === player else { return }
        player = nil
        playChunk(index + 1)
    }

    private func failed(_ e: Error) {
        let w = window
        stopPlayback()
        finish()
        let a = NSAlert()
        a.messageText = L("VOICEVOX で読み上げられませんでした")
        a.informativeText = e.localizedDescription
        if case VoiceVox.Failure.notRunning = e {
            if VoiceVox.canLaunch {
                a.addButton(withTitle: L("VOICEVOX を起動"))
            } else {
                a.addButton(withTitle: L("VOICEVOX をインストール…"))
            }
            a.addButton(withTitle: L("閉じる"))
            let handle: (NSApplication.ModalResponse) -> Void = { r in
                guard r == .alertFirstButtonReturn else { return }
                if VoiceVox.canLaunch { VoiceVox.launchAndWait { _ in } } else { VoiceVoxInstaller.shared.confirmAndInstall(from: w) }
            }
            if let w = w { a.beginSheetModal(for: w, completionHandler: handle) } else { handle(a.runModal()) }
        } else if let w = w {
            a.beginSheetModal(for: w)
        } else {
            a.runModal()
        }
    }
}

// MARK: - 読み上げ中の操作の欄

/// ウインドウの下に浮かぶ小さな欄: ぐるぐる・題 (声の名前)・最初から・一時停止 / 再生・停止。ドラッグで動かせる
final class ReadingHUD: NSPanel {
    var onPlayPause: (() -> Void)?
    var onRestart: (() -> Void)?
    var onStop: (() -> Void)?
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private var playPause: NSButton!

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 52), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = true
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            b.isBordered = false
            b.toolTip = tip
            b.contentTintColor = .labelColor
            b.symbolConfiguration = .init(pointSize: 17, weight: .regular)
            b.widthAnchor.constraint(equalToConstant: 30).isActive = true
            return b
        }
        let restart = button("backward.end.fill", L("最初から"), #selector(restartPressed(_:)))
        playPause = button("pause.fill", L("一時停止"), #selector(playPausePressed(_:)))
        let stop = button("stop.fill", L("停止"), #selector(stopPressed(_:)))
        let row = NSStackView(views: [spinner, label, restart, playPause, stop])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])
        contentView = bg
    }

    func show(over window: NSWindow) {
        let f = window.frame
        setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.minY + 40))
        window.addChildWindow(self, ordered: .above)
        orderFront(nil)
    }

    /// loading = 声を作っているところ (VOICEVOX)
    func update(paused: Bool, loading: Bool, title: String) {
        if paused { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
        label.stringValue = paused ? L("一時停止中") : (loading ? L("声を作っています…") : title)
        playPause.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
        playPause.toolTip = paused ? L("再生") : L("一時停止")
    }

    @objc private func playPausePressed(_ sender: Any?) { onPlayPause?() }
    @objc private func restartPressed(_ sender: Any?) { onRestart?() }
    @objc private func stopPressed(_ sender: Any?) { onStop?() }

    override func close() {
        parent?.removeChildWindow(self)
        super.close()
    }
}

// MARK: - 設定

/// 設定ウインドウの「読み上げ・音声入力」タブ (追加機能がオンのときだけ出る)
final class SpeechSettingsPane: NSObject, SettingsPane {
    let title = L("読み上げ・音声入力")
    let view = NSView()

    private let enginePopup = NSPopUpButton()
    private let voicePopup = NSPopUpButton()
    private var voices: [AVSpeechSynthesisVoice] = []
    private let vvStatus = NSTextField(wrappingLabelWithString: "")
    private let vvSpeakerPopup = NSPopUpButton()
    private var vvStyles: [(label: String, id: Int)] = []
    private let vvURLField = NSTextField()
    private var sliders: [String: (slider: NSSlider, value: NSTextField, def: Double)] = [:]
    private var systemBox = NSView()
    private var vvBox = NSView()
    // かんたんインストール・ON / OFF・削除
    private let onSwitch = NSSwitch()
    private let onLabel = NSTextField(labelWithString: "")
    private var installButton: NSButton!
    private var deleteButton: NSButton!
    private var cancelButton: NSButton!
    private let progress = NSProgressIndicator()
    private let installLabel = NSTextField(labelWithString: "")

    override init() {
        super.init()
        enginePopup.addItems(withTitles: [L("Mac に入っている声"), "VOICEVOX"])
        enginePopup.target = self
        enginePopup.action = #selector(engineChosen(_:))
        let engineRow = NSStackView(views: [SettingsUI.label(L("声の種類")), enginePopup])
        engineRow.spacing = 8

        // Mac の声
        voicePopup.target = self
        voicePopup.action = #selector(voiceChosen(_:))
        let voiceRow = NSStackView(views: [SettingsUI.label(L("声")), voicePopup])
        voiceRow.spacing = 8
        let sysCol = NSStackView(views: [
            voiceRow,
            sliderRow("speechRate", L("速さ"), Double(AVSpeechUtteranceMinimumSpeechRate), Double(AVSpeechUtteranceMaximumSpeechRate), Double(AVSpeechUtteranceDefaultSpeechRate)),
            sliderRow("speechPitch", L("高さ"), 0.5, 2.0, 1.0),
            sliderRow("speechVolume", L("音量"), 0.0, 1.0, 1.0),
            buttons([(L("試しに聞く"), #selector(tryVoice(_:))), (L("初期値に戻す"), #selector(resetSystem(_:)))]),
            SettingsUI.note(L("声は「システム設定 > アクセシビリティ > 読み上げコンテンツ」で増やせます (きれいな「拡張」の声もダウンロードできます)。")),
        ])
        sysCol.orientation = .vertical
        sysCol.alignment = .leading
        sysCol.spacing = 8
        systemBox = SettingsUI.box(L("Mac の声"), sysCol)

        // VOICEVOX
        vvStatus.preferredMaxLayoutWidth = 420
        vvStatus.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        installLabel.lineBreakMode = .byTruncatingTail
        vvURLField.placeholderString = "http://127.0.0.1:50021"
        vvURLField.stringValue = UserDefaults.standard.string(forKey: "vvURL") ?? ""
        vvURLField.target = self
        vvURLField.action = #selector(urlChanged(_:))
        vvURLField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        vvSpeakerPopup.target = self
        vvSpeakerPopup.action = #selector(speakerChosen(_:))
        let statusRow = NSStackView(views: [vvStatus, buttons([(L("つなぎ直す"), #selector(reconnect(_:)))])])
        statusRow.spacing = 12
        onSwitch.target = self
        onSwitch.action = #selector(switchChanged(_:))
        installButton = SettingsUI.button(L("かんたんインストール (約 2 GB)"), self, #selector(installPressed(_:)))
        deleteButton = SettingsUI.button(L("削除"), self, #selector(deletePressed(_:)))
        cancelButton = SettingsUI.button(L("中止"), self, #selector(cancelPressed(_:)))
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.widthAnchor.constraint(equalToConstant: 200).isActive = true
        installLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        installLabel.textColor = .secondaryLabelColor
        let manageRow = NSStackView(views: [onSwitch, onLabel, installButton, progress, installLabel, cancelButton, deleteButton,
                                            SettingsUI.button(L("公式サイト"), self, #selector(getVoiceVox(_:)))])
        manageRow.spacing = 10
        VoiceVoxInstaller.shared.onChange = { [weak self] in self?.refreshInstall() }
        let speakerRow = NSStackView(views: [SettingsUI.label(L("キャラクター")), vvSpeakerPopup])
        speakerRow.spacing = 8
        let urlRow = NSStackView(views: [SettingsUI.label(L("エンジンのアドレス")), vvURLField])
        urlRow.spacing = 8
        let vvCol = NSStackView(views: [
            SettingsUI.note(L("VOICEVOX (無料の読み上げソフト) を使うと、キャラクターのきれいな声で読み上げます。「かんたんインストール」で入れると、キャラクターの声もまとめて入り、ON / OFF・削除もここでできます。")),
            manageRow, statusRow, speakerRow,
            sliderRow("vvSpeed", L("話す速さ"), 0.5, 2.0, 1.0),
            sliderRow("vvPitch", L("声の高さ"), -0.15, 0.15, 0.0),
            sliderRow("vvIntonation", L("抑揚"), 0.0, 2.0, 1.0),
            sliderRow("vvVolume", L("音量"), 0.0, 2.0, 1.0),
            vvButtonsRow(),
            urlRow,
            SettingsUI.note(L("キャラクターごとの利用規約を守ってください。読み上げた声を公開するときは「VOICEVOX:キャラクター名」と書く必要があります。")),
        ])
        vvCol.orientation = .vertical
        vvCol.alignment = .leading
        vvCol.spacing = 8
        vvBox = SettingsUI.box("VOICEVOX", vvCol)

        let mic = SettingsUI.note(L("メニュー「音声 > 声で入力」かツールバーのマイクのボタンで始めます。話した言葉はカーソルの位置に入ります。少し黙ると、そこまでが文章に入ります。\n声は Apple のサーバに送って文字にします (インターネットが必要です)。"))
        let readingCol = NSStackView(views: [engineRow, systemBox, vvBox])
        readingCol.orientation = .vertical
        readingCol.alignment = .leading
        readingCol.spacing = 10
        _ = SettingsUI.fill(view, with: [SettingsUI.box(L("読み上げ"), readingCol), SettingsUI.box(L("音声入力"), mic), NSView()])
        willShow()
    }

    /// VOICEVOX の「試しに聞く・初期値に戻す」(つながるまで押せない) と「利用規約」(いつでも)
    private var vvTryButtons: [NSButton] = []
    private func vvButtonsRow() -> NSStackView {
        let t = SettingsUI.button(L("試しに聞く"), self, #selector(tryVoice(_:)))
        let r = SettingsUI.button(L("初期値に戻す"), self, #selector(resetVoiceVox(_:)))
        vvTryButtons = [t, r]
        let row = NSStackView(views: [t, r, SettingsUI.button(L("利用規約"), self, #selector(openTerms(_:)))])
        row.spacing = 8
        return row
    }

    /// VOICEVOX につながっていないあいだは、キャラクター・調整・試しに聞くを使えなくする
    private func setVoiceVoxReady(_ ready: Bool) {
        vvSpeakerPopup.isEnabled = ready && !vvStyles.isEmpty
        vvTryButtons.forEach { $0.isEnabled = ready }
        for key in ReadingSettings.vvKeys {
            sliders[key]?.slider.isEnabled = ready
            sliders[key]?.value.textColor = ready ? .secondaryLabelColor : .tertiaryLabelColor
        }
    }

    private func buttons(_ list: [(String, Selector)]) -> NSStackView {
        let row = NSStackView(views: list.map { SettingsUI.button($0.0, self, $0.1) })
        row.spacing = 8
        return row
    }

    private func sliderRow(_ key: String, _ title: String, _ min: Double, _ max: Double, _ def: Double) -> NSView {
        let s = NSSlider(value: UserDefaults.standard.object(forKey: key) as? Double ?? def, minValue: min, maxValue: max, target: self, action: #selector(sliderMoved(_:)))
        s.identifier = NSUserInterfaceItemIdentifier(key)
        s.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let name = SettingsUI.label(title)
        name.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let value = SettingsUI.label("", small: true)
        value.widthAnchor.constraint(equalToConstant: 50).isActive = true
        sliders[key] = (s, value, def)
        let row = NSStackView(views: [name, s, value])
        row.spacing = 8
        showValue(key)
        return row
    }

    private func showValue(_ key: String) {
        guard let e = sliders[key] else { return }
        e.value.stringValue = String(format: key == "vvPitch" ? "%+.2f" : "%.2f", e.slider.doubleValue)
    }

    func willShow() {
        enginePopup.selectItem(at: ReadingSettings.engine == "voicevox" ? 1 : 0)
        let lang = I18n.language == "en" ? "en" : "ja"
        voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
        voicePopup.removeAllItems()
        // はじめは、その Mac で選んである声
        voicePopup.addItem(withTitle: ReadingSettings.macDefaultVoice.map { L("Mac の設定の声 ({0})", $0.name) } ?? L("標準"))
        for v in voices { voicePopup.addItem(withTitle: v.name + (v.quality == .enhanced ? " " + L("(高音質)") : "")) }
        let saved = UserDefaults.standard.string(forKey: "speechVoice") ?? ""
        voicePopup.selectItem(at: (voices.firstIndex { $0.identifier == saved }).map { $0 + 1 } ?? 0)
        for (key, e) in sliders {
            e.slider.doubleValue = UserDefaults.standard.object(forKey: key) as? Double ?? e.def
            showValue(key)
        }
        refreshEngineBoxes()
        reconnect(nil)
    }

    private func refreshEngineBoxes() {
        let vv = ReadingSettings.engine == "voicevox"
        systemBox.isHidden = vv
        vvBox.isHidden = !vv
        refreshInstall()
    }

    /// インストールの状態に合わせて、ボタン・進み具合・ON / OFF を出し分ける
    private func refreshInstall() {
        let inst = VoiceVoxInstaller.shared
        let installed = VoiceVoxInstaller.info != nil
        var busy = false
        switch inst.state {
        case .downloading(let f):
            busy = true
            progress.doubleValue = f
            installLabel.stringValue = L("ダウンロード中… {0}%", Int(f * 100))
        case .extracting:
            busy = true
            progress.doubleValue = 1
            installLabel.stringValue = L("展開しています…")
        case .failed(let m):
            installLabel.stringValue = "⚠︎ " + m
        default:
            installLabel.stringValue = installed ? L("インストール済み ({0})", VoiceVoxInstaller.info?.version ?? "") : ""
        }
        progress.isHidden = !busy
        cancelButton.isHidden = !busy
        installButton.isHidden = busy || installed || VoiceVox.appURL != nil
        deleteButton.isHidden = busy || !installed
        let usable = installed || VoiceVox.appURL != nil
        onSwitch.isHidden = !usable || busy
        onLabel.isHidden = onSwitch.isHidden
        onSwitch.state = ReadingSettings.engine == "voicevox" && (installed ? inst.isEngineRunning : true) ? .on : .off
        onLabel.stringValue = onSwitch.state == .on ? L("ON (VOICEVOX で読み上げる)") : L("OFF")
    }

    @objc private func installPressed(_ sender: Any?) { VoiceVoxInstaller.shared.confirmAndInstall(from: view.window) }
    @objc private func cancelPressed(_ sender: Any?) { VoiceVoxInstaller.shared.cancel() }

    @objc private func deletePressed(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = L("VOICEVOX を削除しますか？")
        a.informativeText = L("このアプリで入れた VOICEVOX (約 2 GB) を消します。読み上げは Mac の声に戻ります。")
        a.addButton(withTitle: L("削除"))
        a.addButton(withTitle: L("やめる"))
        a.buttons.first?.hasDestructiveAction = true
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            VoiceVoxInstaller.shared.uninstall()
            ReadingSettings.engine = "system"
            self?.willShow()
        }
        if let w = view.window { a.beginSheetModal(for: w, completionHandler: done) } else { done(a.runModal()) }
    }

    /// ON: VOICEVOX で読み上げる (エンジンを動かす)。OFF: エンジンを止めて Mac の声に戻す
    @objc private func switchChanged(_ sender: NSSwitch) {
        if sender.state == .on {
            ReadingSettings.engine = "voicevox"
            vvStatus.stringValue = "⏳ " + L("VOICEVOX を起動しています…")
            VoiceVox.launchAndWait { [weak self] _ in self?.reconnect(nil); self?.refreshInstall() }
        } else {
            VoiceVoxInstaller.shared.stopEngine()
            ReadingSettings.engine = "system"
        }
        enginePopup.selectItem(at: ReadingSettings.engine == "voicevox" ? 1 : 0)
        refreshEngineBoxes()
    }

    @objc private func engineChosen(_ sender: NSPopUpButton) {
        ReadingSettings.engine = sender.indexOfSelectedItem == 1 ? "voicevox" : "system"
        refreshEngineBoxes()
        if ReadingSettings.engine == "voicevox" { reconnect(nil) }
    }

    @objc private func voiceChosen(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        UserDefaults.standard.set(i > 0 ? voices[i - 1].identifier : "", forKey: "speechVoice")
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        guard let key = sender.identifier?.rawValue else { return }
        UserDefaults.standard.set(sender.doubleValue, forKey: key)
        showValue(key)
    }

    private func reset(_ keys: [String]) {
        for k in keys { UserDefaults.standard.removeObject(forKey: k) }
        willShow()
    }
    @objc private func resetSystem(_ sender: Any?) { reset(ReadingSettings.systemKeys + ["speechVoice"]) }
    @objc private func resetVoiceVox(_ sender: Any?) { reset(ReadingSettings.vvKeys) }

    @objc private func urlChanged(_ sender: NSTextField) {
        UserDefaults.standard.set(sender.stringValue.trimmingCharacters(in: .whitespaces), forKey: "vvURL")
        reconnect(nil)
    }

    @objc private func getVoiceVox(_ sender: Any?) { NSWorkspace.shared.open(VoiceVox.downloadURL) }
    @objc private func openTerms(_ sender: Any?) { NSWorkspace.shared.open(VoiceVox.termsURL) }

    @objc private func launchVoiceVox(_ sender: Any?) {
        guard VoiceVox.canLaunch else {
            vvStatus.stringValue = "⚠︎ " + L("VOICEVOX が見つかりません。「VOICEVOX を入手…」から入れてください。")
            return
        }
        vvStatus.stringValue = "⏳ " + L("VOICEVOX を起動しています…")
        VoiceVox.launchAndWait { [weak self] ok in
            if ok { self?.reconnect(nil) } else { self?.vvStatus.stringValue = "⚠︎ " + L("VOICEVOX につながりません。VOICEVOX を起動してください。") }
        }
    }

    /// つながるか確かめて、キャラクターの一覧を取り直す
    @objc private func reconnect(_ sender: Any?) {
        vvStatus.stringValue = "⏳ " + L("確かめています…")
        setVoiceVoxReady(false)
        VoiceVox.version { [weak self] v in
            guard let self = self else { return }
            guard let v = v else {
                self.vvStatus.stringValue = "⚠︎ " + (!VoiceVox.canLaunch ? L("VOICEVOX が入っていません。「かんたんインストール」で入れられます。")
                                                       : L("VOICEVOX につながりません。VOICEVOX を起動してください。"))
                self.fillSpeakers([])
                return
            }
            self.vvStatus.stringValue = "✓ " + L("VOICEVOX {0} につながりました", v)
            VoiceVox.speakers { res in
                if case .success(let list) = res { self.fillSpeakers(list) }
                self.setVoiceVoxReady(true)
            }
        }
    }

    private func fillSpeakers(_ list: [VoiceVox.Speaker]) {
        vvSpeakerPopup.removeAllItems()
        vvStyles = list.flatMap { s in s.styles.map { (label: "\(s.name) (\($0.name))", id: $0.id) } }
        if vvStyles.isEmpty {
            vvSpeakerPopup.addItem(withTitle: ReadingSettings.vvSpeakerName)
            vvSpeakerPopup.isEnabled = false
            return
        }
        vvSpeakerPopup.isEnabled = true
        vvSpeakerPopup.addItems(withTitles: vvStyles.map { $0.label })
        if let i = vvStyles.firstIndex(where: { $0.id == ReadingSettings.vvSpeaker }) { vvSpeakerPopup.selectItem(at: i) }
    }

    @objc private func speakerChosen(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        guard i >= 0, i < vvStyles.count else { return }
        UserDefaults.standard.set(vvStyles[i].id, forKey: "vvSpeaker")
        UserDefaults.standard.set(vvStyles[i].label, forKey: "vvSpeakerName")
    }

    @objc private func tryVoice(_ sender: Any?) {
        let tv = NSTextView()
        tv.string = I18n.language == "en" ? "This is how the text will be read aloud." : "春の遠足。先週の金曜日、学校の遠足で動物園に行きました。"
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        SpeechReader.shared.speak(tv, in: view.window)
    }
}
