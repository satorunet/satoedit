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
        a.informativeText = L("「システム設定 > プライバシーとセキュリティ」で、さとるエディタに {0} を許可してください。", what)
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
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
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
            h.show(over: w)
            h.update(text: "", listening: true)
        }
        newTask()
        NotificationCenter.default.post(name: .dictationStateDidChange, object: nil)
    }

    /// 1 つのまとまり (話して、少し黙るまで) ごとに、新しく聞き取りを始める
    private func newTask() {
        task?.cancel()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req
        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self, self.isListening else { return }
                if let result = result {
                    self.pending = result.bestTranscription.formattedString
                    self.hud?.update(text: self.pending, listening: true)
                    if result.isFinal { self.commit(); self.newTask(); return }
                    self.restartSilenceTimer()
                } else if error != nil {
                    // 何も聞こえないまま時間切れになったときなど: 聞き取りを続ける
                    self.commit()
                    self.newTask()
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
            self.newTask()
        }
    }

    /// 話した分をカーソルの位置に入れる (1 回の ⌘Z で戻せる)
    private func commit() {
        silenceTimer?.invalidate()
        let text = pending
        pending = ""
        hud?.update(text: "", listening: isListening)
        guard !text.isEmpty, let tv = textView, tv.isEditable else { return }
        tv.insertText(text, replacementRange: tv.selectedRange())
        tv.scrollRangeToVisible(tv.selectedRange())
    }

    func stop() {
        guard isListening else { return }
        commit()
        isListening = false
        silenceTimer?.invalidate()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
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
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -16),
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

    func update(text: String, listening: Bool) {
        label.stringValue = "🎤 " + (text.isEmpty ? L("聞き取り中… 話してください (もう一度押すと止まります)") : text)
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

