import AppKit
import HinokiCore

/// 共同編集中にウインドウ右側に出るチャット欄
final class ChatPanel: NSView, NSTextFieldDelegate {
    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?

    private let header = NSTextField(wrappingLabelWithString: "")
    private let addressLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: L("コピー"), target: nil, action: nil)
    private let stopButton = NSButton(title: L("共有を終了"), target: nil, action: nil)
    private let transcript = NSTextView()
    private let input = NSTextField()
    private var address = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let title = NSTextField(labelWithString: L("共同編集"))
        title.font = .boldSystemFont(ofSize: 13)

        addressLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        addressLabel.isSelectable = true
        copyButton.bezelStyle = .inline
        copyButton.target = self
        copyButton.action = #selector(copyAddress(_:))
        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .small
        stopButton.target = self
        stopButton.action = #selector(stop(_:))
        header.font = .systemFont(ofSize: 11)
        header.textColor = .secondaryLabelColor

        transcript.isEditable = false
        transcript.isRichText = true
        transcript.drawsBackground = false
        transcript.textContainerInset = NSSize(width: 4, height: 4)
        transcript.isVerticallyResizable = true
        transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = transcript
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false

        input.placeholderString = L("メッセージ (return で送信)")
        input.delegate = self
        input.target = self
        input.action = #selector(send(_:))
        let sendButton = NSButton(title: L("送信"), target: self, action: #selector(send(_:)))
        sendButton.bezelStyle = .rounded
        sendButton.controlSize = .small
        let inputRow = NSStackView(views: [input, sendButton])
        inputRow.spacing = 4

        let addressRow = NSStackView(views: [addressLabel, copyButton])
        addressRow.spacing = 4
        let titleRow = NSStackView(views: [title, NSView(), stopButton])

        let stack = NSStackView(views: [titleRow, addressRow, header, scroll, inputRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for v in [titleRow, header, scroll, inputRow] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        widthAnchor.constraint(equalToConstant: 260).isActive = true

        // 左の区切り線
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    /// 共有用アドレス (ホストのときだけ表示)
    func setAddress(_ s: String?, code: String? = nil) {
        address = s.map { a in code.map { L("{0}  共有コード: {1}", a, $0) } ?? a } ?? ""
        addressLabel.stringValue = s.map { a in L("参加用: {0}", a) + (code.map { L("\nコード: {0}", $0) } ?? "") } ?? ""
        addressLabel.isHidden = s == nil
        copyButton.isHidden = s == nil
    }

    func setStopTitle(_ s: String, enabled: Bool) {
        stopButton.title = s
        stopButton.isEnabled = enabled
    }

    func setUsers(_ users: [CollabUser], myID: Int) {
        header.stringValue = L("参加中 ({0} 人): ", users.count) + users.sorted { $0.id < $1.id }
            .map { $0.id == myID ? L("{0} (自分)", $0.name) : $0.name }.joined(separator: "、")
    }

    func append(name: String?, color: NSColor?, text: String) {
        let s = NSMutableAttributedString()
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let time = NSAttributedString(string: f.string(from: Date()) + " ", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        s.append(time)
        if let name = name {
            s.append(NSAttributedString(string: name + "  ", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 12),
                .foregroundColor: color ?? NSColor.labelColor,
            ]))
            s.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
            ]))
        } else {
            s.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        transcript.textStorage?.append(s)
        transcript.scrollToEndOfDocument(nil)
    }

    func focusInput() {
        window?.makeFirstResponder(input)
    }

    @objc private func send(_ sender: Any?) {
        let t = input.stringValue
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        input.stringValue = ""
        onSend?(t)
    }

    @objc private func copyAddress(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        append(name: nil, color: nil, text: L("コピーしました"))
    }

    @objc private func stop(_ sender: Any?) { onStop?() }
}
