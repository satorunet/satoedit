import AppKit
import AVFoundation
import Speech
import HinokiCore

// 追加機能「読み上げ・音声入力」
// 読み上げは SpeechReading.swift
// 音声入力: マイクの声を文字にして、カーソルの位置に入れる。話している途中の文字は、ウインドウの下の小さな欄に出す。

// MARK: - 音声入力

final class Dictation: NSObject {
    static let shared = Dictation()
    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private weak var textView: NSTextView?
    private var hud: DictationHUD?
    /// まだ入れていない (話している途中の) 文字
    private var pending = ""
    private var silenceTimer: Timer?
    /// 聞き取りの回の番号。前の回 (止めた回) から遅れて届く知らせを無視するため
    private var generation = 0
    /// 話している途中の文字を、文章の中に仮に入れている場所
    private var liveRange: NSRange?
    private var liveText = ""
    /// 聞き取りの回を止めていて、次に声が聞こえたら始める
    private var waitingForVoice = false
    private var lastStart = Date.distantPast
    private var failures = 0
    /// この Mac の中だけで聞き取る。うまくいかなければ、Apple のサーバーで聞き取る方に切り替える
    private var useOnDevice = true
    private var usedOnDevice = false
    private var escMonitor: Any?
    /// 声の出始めを取りこぼさないよう、少し前からの音を取っておく (音の処理の糸で使う)
    private let bufLock = NSLock()
    private var recent: [AVAudioPCMBuffer] = []

    private(set) var isListening = false

    func toggle(for tv: NSTextView, in window: NSWindow?) {
        if isListening { stop() } else { start(for: tv, in: window) }
    }

    func start(for tv: NSTextView, in window: NSWindow?) {
        SpeechReader.shared.stop() // 読み上げの声を拾わないように
        // マイクと音声認識の許可をもらってから始める
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else { Self.explainDenied(L("音声認識")); return }
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    DispatchQueue.main.async {
                        guard ok else { Self.explainDenied(L("マイク")); return }
                        self.begin(tv, window)
                    }
                }
            }
        }
    }

    private static func explainDenied(_ what: String) {
        let a = NSAlert()
        a.messageText = L("{0} が許可されていません", what)
        a.informativeText = L("「システム設定 > プライバシーとセキュリティ」で、satoEditに {0} を許可してください。", what)
        a.addButton(withTitle: L("システム設定を開く"))
        a.addButton(withTitle: L("閉じる"))
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func begin(_ tv: NSTextView, _ window: NSWindow?) {
        let locale = Locale(identifier: (I18n.language == "en") ? "en-US" : "ja-JP")
        guard let r = SFSpeechRecognizer(locale: locale), r.isAvailable else {
            let a = NSAlert()
            a.messageText = L("いまは音声入力を使えません")
            a.informativeText = L("インターネットにつながっているか確かめてください。")
            a.runModal()
            return
        }
        recognizer = r
        textView = tv
        pending = ""
        liveRange = nil
        liveText = ""
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.bufLock.lock()
            if let req = self.request { req.append(buffer) }
            self.recent.append(buffer)
            if self.recent.count > 24 { self.recent.removeFirst(self.recent.count - 24) } // 約 0.5 秒
            self.bufLock.unlock()
            // 声の大きさ (話しただけで、すぐ欄が動くように)
            guard let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = n > 0 ? sqrt(sum / Float(n)) : 0
            let db = 20 * log10(max(rms, 0.000_01))
            let level = CGFloat(min(max((db + 55) / 40, 0), 1))
            DispatchQueue.main.async { [weak self] in self?.heard(level) }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            let a = NSAlert(error: error)
            a.runModal()
            return
        }
        isListening = true
        if let w = window ?? tv.window {
            let h = hud ?? DictationHUD()
            hud = h
            h.onStop = { [weak self] in self?.stop() }
            h.show(over: w)
            h.update(text: "", listening: true)
        }
        failures = 0
        lastStart = .distantPast
        bufLock.lock(); recent = []; bufLock.unlock()
        useOnDevice = true
        newTask() // すぐ聞き取りを始める (黙ったあとは、次に声が聞こえたら始める)
        // esc キーでも止められる
        if escMonitor == nil {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self = self, self.isListening, e.keyCode == 53 else { return e }
                self.stop()
                return nil
            }
        }
        NotificationCenter.default.post(name: .dictationStateDidChange, object: nil)
    }

    /// 声が聞こえたら、止めていた聞き取りを始める (黙っているあいだは Apple に送らない。送りすぎると回数の上限で止まるため)
    private func heard(_ level: CGFloat) {
        hud?.setLevel(level)
        guard isListening, waitingForVoice, level > 0.1 else { return }
        // うまくいかないことが続いたら、間を空けてからやり直す
        let wait = min(8.0, failures == 0 ? 0 : pow(2.0, Double(failures - 1)))
        guard Date().timeIntervalSince(lastStart) >= wait else { return }
        newTask()
    }

    /// 聞き取りの回を止めて、次の声を待つ
    private func pause() {
        generation += 1
        task?.cancel()
        task = nil
        bufLock.lock(); request = nil; bufLock.unlock()
        waitingForVoice = true
    }

    /// 1 つのまとまり (話して、少し黙るまで) ごとに、新しく聞き取りを始める
    private func newTask() {
        waitingForVoice = false
        lastStart = Date()
        generation += 1
        let gen = generation
        // 前の回を止める。止めた回から届く「取り消しました」の知らせは、番号が古いので無視する
        // (前はこの知らせで、また新しい回を始めて今の回を止めてしまい、話し始めで止まっていた)
        task?.cancel()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        // この Mac の中だけで聞き取れるなら、そうする (Apple のサーバーに送らないので、回数の上限が無く、ネットも要らない)
        usedOnDevice = useOnDevice && recognizer?.supportsOnDeviceRecognition == true
        if usedOnDevice { req.requiresOnDeviceRecognition = true }
        // 声の出始め (少し前からの音) も渡す
        bufLock.lock()
        for b in recent { req.append(b) }
        request = req
        bufLock.unlock()
        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self, self.isListening, gen == self.generation else { return }
                if let result = result {
                    self.failures = 0
                    self.pending = result.bestTranscription.formattedString
                    self.showLive()
                    if result.isFinal { self.commit(); self.pause(); return }
                    self.restartSilenceTimer()
                } else if let error = error {
                    let msg = "\(error)"
                    if msg.contains("Quota") || msg.contains("quota") {
                        // Apple の音声認識の回数の上限: 止めて知らせる
                        self.stop()
                        let a = NSAlert()
                        a.messageText = L("音声認識の回数の上限に達しました")
                        a.informativeText = L("Apple の音声認識は、短い時間に使える回数が決まっています。少し時間をおいてから、もう一度お試しください。")
                        a.runModal()
                        return
                    }
                    if self.pending.isEmpty {
                        self.failures += 1
                        // Mac の中での聞き取りがうまくいかない: サーバーの方でやり直す
                        let ns = error as NSError
                        if self.usedOnDevice {
                            // (「Siri と音声入力」を切っている Mac では、中だけでは聞き取れない: 201)
                            self.useOnDevice = false
                            self.failures = 0
                            self.newTask()
                            return
                        }
                        // 「取り消した」「何も聞こえなかった」以外は、欄に出して知らせる
                        if !(ns.code == 216 || ns.code == 1110 || ns.code == 301) {
                            self.hud?.note(L("うまく聞き取れませんでした ({0})", "\(ns.code)"))
                        }
                    }
                    // 何も聞こえないまま時間切れになったときなど: 聞き取りを続ける
                    self.commit()
                    self.pause()
                }
            }
        }
    }

    /// 少し黙ったら、そこまでを文章に入れる
    private func restartSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.3, repeats: false) { [weak self] _ in
            guard let self = self, self.isListening, !self.pending.isEmpty else { return }
            self.commit()
            self.pause()
        }
    }

    /// 話している途中の文字を、その場で文章に仮に入れて見せる (薄い色の下線つき。まだ ⌘Z の記録はしない)
    private func showLive() {
        hud?.update(text: pending, listening: true)
        guard let tv = textView, tv.isEditable, let storage = tv.textStorage else { return }
        let range: NSRange
        if let r = liveRange, NSMaxRange(r) <= storage.length,
           (storage.string as NSString).substring(with: r) == liveText {
            range = r
        } else {
            // まだ入れていない / 文章が別に変わった: 今のカーソルの位置から入れ直す
            liveRange = nil
            range = tv.selectedRange()
        }
        let um = tv.undoManager
        um?.disableUndoRegistration()
        if tv.shouldChangeText(in: range, replacementString: pending) {
            storage.replaceCharacters(in: range, with: pending)
            tv.didChangeText()
        }
        um?.enableUndoRegistration()
        let r = NSRange(location: range.location, length: (pending as NSString).length)
        if let old = liveRange { tv.layoutManager?.removeTemporaryAttribute(.underlineStyle, forCharacterRange: old) }
        liveRange = r
        liveText = pending
        tv.layoutManager?.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                                                  .underlineColor: NSColor.systemBlue.withAlphaComponent(0.6)], forCharacterRange: r)
        tv.setSelectedRange(NSRange(location: NSMaxRange(r), length: 0))
        tv.scrollRangeToVisible(r)
    }

    /// 仮に入れていた文字を外す (⌘Z の記録なし)
    private func removeLive() {
        guard let r = liveRange, let tv = textView, let storage = tv.textStorage else { liveRange = nil; return }
        liveRange = nil
        guard NSMaxRange(r) <= storage.length, (storage.string as NSString).substring(with: r) == liveText else { return }
        tv.layoutManager?.removeTemporaryAttribute(.underlineStyle, forCharacterRange: r)
        let um = tv.undoManager
        um?.disableUndoRegistration()
        if tv.shouldChangeText(in: r, replacementString: "") {
            storage.replaceCharacters(in: r, with: "")
            tv.didChangeText()
        }
        um?.enableUndoRegistration()
        tv.setSelectedRange(NSRange(location: r.location, length: 0))
    }

    /// 話した分を確定してカーソルの位置に入れる (1 回の ⌘Z で戻せる)
    private func commit() {
        silenceTimer?.invalidate()
        let text = pending
        pending = ""
        hud?.update(text: "", listening: isListening)
        removeLive()
        liveText = ""
        guard !text.isEmpty, let tv = textView, tv.isEditable else { return }
        tv.insertText(text, replacementRange: tv.selectedRange())
        tv.scrollRangeToVisible(tv.selectedRange())
    }

    func stop() {
        guard isListening else { return }
        commit()
        isListening = false
        generation += 1
        silenceTimer?.invalidate()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        bufLock.lock(); request = nil; recent = []; bufLock.unlock()
        waitingForVoice = false
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        hud?.close()
        NotificationCenter.default.post(name: .dictationStateDidChange, object: nil)
    }
}

extension Notification.Name {
    static let dictationStateDidChange = Notification.Name("satoru.dictationStateDidChange")
}

/// 音声入力中に、ウインドウの下に出す小さな欄 (話している途中の文字を見せる)
final class DictationHUD: NSPanel {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let meter = DictationMeter()
    private var text = ""
    private var hearing = false
    private var quietSince = Date()
    private var noteText = ""
    var onStop: (() -> Void)?
    private lazy var stopButton: NSButton = {
        let b = NSButton(title: L("止める"), target: self, action: #selector(stopPressed))
        b.bezelStyle = .rounded
        b.controlSize = .regular
        b.keyEquivalent = ""
        b.toolTip = L("音声入力を止めます (esc キーでも止まります)")
        return b
    }()
    @objc private func stopPressed() { onStop?() }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 64), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        label.font = .systemFont(ofSize: 16)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(label)
        meter.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(meter)
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stopButton)
        NSLayoutConstraint.activate([
            stopButton.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -12),
            stopButton.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            meter.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 14),
            meter.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            meter.widthAnchor.constraint(equalToConstant: 34),
            meter.heightAnchor.constraint(equalToConstant: 30),
            label.leadingAnchor.constraint(equalTo: meter.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])
        contentView = bg
    }

    func show(over window: NSWindow) {
        let f = window.frame
        setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.minY + 40))
        window.addChildWindow(self, ordered: .above)
        orderFront(nil)
    }

    /// 困ったことを少しのあいだ欄に出す
    func note(_ s: String) {
        noteText = s
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, self.noteText == s else { return }
            self.noteText = ""
            self.refresh()
        }
    }

    func update(text: String, listening: Bool) {
        self.text = text
        refresh()
    }

    /// 声の大きさ (0〜1)。声が聞こえたら、文字になる前から「聞こえています」と出す
    func setLevel(_ level: CGFloat) {
        meter.level = level
        let loud = level > 0.1
        if loud { quietSince = Date() }
        let now = loud || Date().timeIntervalSince(quietSince) < 0.8
        if now != hearing { hearing = now; refresh() }
    }

    private func refresh() {
        if !text.isEmpty { label.stringValue = text; label.textColor = .labelColor; return }
        label.textColor = .secondaryLabelColor
        if !noteText.isEmpty { label.stringValue = noteText; return }
        label.stringValue = hearing ? L("聞こえています…") : L("聞き取り中… 話してください")
    }

    override func close() {
        parent?.removeChildWindow(self)
        super.close()
    }
}

// MARK: - メニューとボタン

extension EditorWindowController {
    @objc func readAloudHM(_ sender: Any?) {
        if SpeechReader.shared.isActive { SpeechReader.shared.stop(); return }
        SpeechReader.shared.speak(textView, in: window)
    }

    @objc func stopReadingHM(_ sender: Any?) { SpeechReader.shared.stop() }

    @objc func toggleDictationHM(_ sender: Any?) {
        Dictation.shared.toggle(for: textView, in: window)
    }

    @objc func openSpeechSettingsHM(_ sender: Any?) { SettingsWindowController.shared.show(.speech) }
}


/// 声の大きさに合わせて伸び縮みする棒 (マイクが反応しているのが、すぐわかるように)
final class DictationMeter: NSView {
    private var bars: [CGFloat] = [0, 0, 0, 0, 0]
    var level: CGFloat = 0 {
        didSet {
            // 真ん中が大きく、端は小さく。少しゆらぎを入れて生きている感じに
            let shape: [CGFloat] = [0.45, 0.75, 1, 0.75, 0.45]
            for i in 0..<bars.count {
                let target = level * shape[i] * CGFloat.random(in: 0.75...1)
                bars[i] = target > bars[i] ? target : bars[i] * 0.7 + target * 0.3
            }
            needsDisplay = true
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let w: CGFloat = 4, gap: CGFloat = 3
        let total = CGFloat(bars.count) * w + CGFloat(bars.count - 1) * gap
        var x = (bounds.width - total) / 2
        let active = bars.max() ?? 0 > 0.12
        (active ? NSColor.systemRed : NSColor.tertiaryLabelColor).setFill()
        for b in bars {
            let h = max(4, b * bounds.height)
            NSBezierPath(roundedRect: NSRect(x: x, y: (bounds.height - h) / 2, width: w, height: h), xRadius: 2, yRadius: 2).fill()
            x += w + gap
        }
    }
}
