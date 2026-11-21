import AppKit
import HinokiCore
import UniformTypeIdentifiers

/// 文字ではないファイルの見せ方: 画像は「かんたんビューア」、それ以外のバイナリは「バイナリ表示」(16 進数)
enum FileViewers {
    /// 「テキストとして開く」を選んだファイル (次にこのファイルを開くときはエディタで開く)
    static var forceText: Set<URL> = []
    /// 開いているビューア (閉じるまで持っておく)
    fileprivate static var open: [NSWindowController] = []

    /// 画像として見るファイルか (SVG は中身が文字なのでエディタで開く)
    static func isImage(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        if t.conforms(to: .svg) { return false }
        return t.conforms(to: .image)
    }

    /// 先頭を見てバイナリか (暗号化した文書は、エディタで開いてパスワードを聞くので除く)
    static func isBinary(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let head = h.readData(ofLength: 8192)
        if head.starts(with: FileCrypto.magic) { return false }
        return BinaryData.looksBinary(head)
    }

    /// エディタで開く代わりにビューアで見せたら true
    static func showIfNeeded(_ url: URL) -> Bool {
        let u = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue else { return false }
        if forceText.contains(u) { return false }
        // もう開いていれば前に出す (クリックが 2 回届いても 1 枚だけ)
        if let v = open.first(where: { ($0 as? ViewerWindowController)?.url == u }) {
            v.window?.makeKeyAndOrderFront(nil)
            return true
        }
        if isImage(u), let image = NSImage(contentsOf: u), image.isValid {
            ImageViewerWindowController(url: u, image: image).showWindow(nil)
            return true
        }
        if isBinary(u) {
            guard let c = HexViewerWindowController(url: u) else { return false }
            c.showWindow(nil)
            return true
        }
        return false
    }

    static func sizeText(_ url: URL) -> String {
        let n = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

/// ビューアに共通: 閉じたら手放す。サーバから取ってきた一時ファイルなら消す
class ViewerWindowController: NSWindowController, NSWindowDelegate {
    let url: URL

    init(url: URL, window: NSWindow) {
        self.url = url
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.representedURL = url
        window.title = url.lastPathComponent
        FileViewers.open.append(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        FileViewers.open.removeAll { $0 === self }
        RemoteDocuments.removeTemp(url)
    }

    /// 情報の行
    func infoLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.lineBreakMode = .byTruncatingMiddle
        return l
    }
}

// MARK: - かんたん画像ビューア

/// 画像を窓に合わせて見せる。ダブルクリックか「実寸」で実際の大きさ、⌘+ / ⌘- で拡大・縮小
final class ImageViewerWindowController: ViewerWindowController {
    private let imageView = NSImageView()
    private let scroll = NSScrollView()
    private let info: NSTextField
    private let image: NSImage
    private var pixelSize: NSSize
    /// nil = 窓に合わせる
    private var zoom: CGFloat?

    init(url: URL, image: NSImage) {
        self.image = image
        // 実際のピクセル数 (Retina 用の画像でも本当の大きさを出す)
        let rep = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        var px = rep.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
        if px.width <= 0 || px.height <= 0 { px = image.size }
        pixelSize = px
        info = NSTextField(labelWithString: "")
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        let w = min(max(px.width, 360), screen.width * 0.8)
        let h = min(max(px.height, 240), screen.height * 0.8) + 30
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 240, height: 180)
        super.init(url: url, window: window)
        build()
        window.center()
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.animates = true // GIF アニメーション
        imageView.setAccessibilityLabel(url.lastPathComponent)

        let clip = CenteringClipView()
        scroll.contentView = clip
        scroll.documentView = imageView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.drawsBackground = true

        let fit = NSButton(title: L("窓に合わせる"), target: self, action: #selector(fitWindow(_:)))
        let actual = NSButton(title: L("実寸"), target: self, action: #selector(actualSize(_:)))
        let external = NSButton(title: L("ほかのアプリで開く"), target: self, action: #selector(openExternally(_:)))
        [fit, actual, external].forEach { $0.bezelStyle = .rounded; $0.controlSize = .small }
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        info.lineBreakMode = .byTruncatingMiddle
        let bar = NSStackView(views: [info, NSView(), fit, actual, external])
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)

        for v in [scroll, bar] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 30),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSView.frameDidChangeNotification, object: scroll)
        scroll.postsFrameChangedNotifications = true
    }

    /// 画像の大きさを、いまの倍率に合わせる
    private func update() {
        let area = scroll.contentSize
        let size: NSSize
        if let z = zoom {
            size = NSSize(width: pixelSize.width * z, height: pixelSize.height * z)
        } else {
            // 窓に合わせる (小さい画像は引き伸ばさない)
            let s = min(1, min(area.width / max(pixelSize.width, 1), area.height / max(pixelSize.height, 1)))
            size = NSSize(width: floor(pixelSize.width * s), height: floor(pixelSize.height * s))
        }
        imageView.frame = NSRect(origin: .zero, size: size)
        let shown = zoom ?? (size.width / max(pixelSize.width, 1))
        info.stringValue = "\(Int(pixelSize.width)) × \(Int(pixelSize.height))  ·  \(FileViewers.sizeText(url))  ·  \(Int((shown * 100).rounded()))%"
    }

    @objc private func resized() { if zoom == nil { update() } }
    @objc private func fitWindow(_ sender: Any?) { zoom = nil; update() }
    @objc private func actualSize(_ sender: Any?) { zoom = 1; update() }
    @objc private func openExternally(_ sender: Any?) { NSWorkspace.shared.open(url) }

    private func currentZoom() -> CGFloat { zoom ?? (imageView.frame.width / max(pixelSize.width, 1)) }
    @objc func zoomIn(_ sender: Any?) { zoom = min(currentZoom() * 1.25, 16); update() }
    @objc func zoomOut(_ sender: Any?) { zoom = max(currentZoom() / 1.25, 0.05); update() }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "+", "=": zoomIn(nil)
        case "-": zoomOut(nil)
        case "0": fitWindow(nil)
        case "1": actualSize(nil)
        case " ", "\u{1B}": window?.performClose(nil) // スペース・Esc で閉じる (クイックルックと同じ)
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { zoom == nil ? actualSize(nil) : fitWindow(nil) } else { super.mouseDown(with: event) }
    }

    /// 小さい画像は真ん中に置く
    private final class CenteringClipView: NSClipView {
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
            var r = super.constrainBoundsRect(proposedBounds)
            guard let doc = documentView else { return r }
            if doc.frame.width < r.width { r.origin.x = (doc.frame.width - r.width) / 2 }
            if doc.frame.height < r.height { r.origin.y = (doc.frame.height - r.height) / 2 }
            return r
        }
    }
}

// MARK: - バイナリ表示 (16 進数)

/// バイナリのファイルを「位置 | 16 進数 | 文字」の表で見せる (読むだけ)。
/// ファイルはメモリに写すだけなので、大きなファイルでもすぐ開く
final class HexViewerWindowController: ViewerWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let data: Data
    private let table = NSTableView()
    private let offsetDigits: Int
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    init?(url: URL) {
        guard let d = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        data = d
        offsetDigits = max(8, String(d.count, radix: 16).count)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 520, height: 240)
        super.init(url: url, window: window)
        window.title = L("{0} (バイナリ表示)", url.lastPathComponent)
        build()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        let charW = ("0" as NSString).size(withAttributes: [.font: font]).width
        for (id, title, chars) in [("offset", L("位置"), offsetDigits), ("hex", L("16 進数"), 49), ("ascii", L("文字"), 16)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = ceil(charW * CGFloat(chars)) + 16
            c.minWidth = c.width
            c.resizingMask = id == "ascii" ? .autoresizingMask : []
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = ceil(font.boundingRectForFont.height) + 2
        table.usesAlternatingRowBackgroundColors = true
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true

        let info = infoLabel(L("{0} ({1} バイト)・読むだけ", FileViewers.sizeText(url), NumberFormatter.localizedString(from: NSNumber(value: data.count), number: .decimal)))
        let goField = NSTextField()
        goField.placeholderString = L("位置 (16 進)")
        goField.font = font
        goField.target = self
        goField.action = #selector(goTo(_:))
        goField.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let asText = NSButton(title: L("テキストとして開く"), target: self, action: #selector(openAsText(_:)))
        let external = NSButton(title: L("ほかのアプリで開く"), target: self, action: #selector(openExternally(_:)))
        [asText, external].forEach { $0.bezelStyle = .rounded; $0.controlSize = .small }
        let bar = NSStackView(views: [info, NSView(), goField, asText, external])
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)

        for v in [scroll, bar] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { BinaryData.lineCount(data.count) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("hex")
        let f = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: "")
            t.identifier = id
            t.font = font
            t.isSelectable = true
            return t
        }()
        let line = BinaryData.line(data, at: row * BinaryData.bytesPerLine, offsetDigits: offsetDigits)
        switch id.rawValue {
        case "offset": f.stringValue = line.offset; f.textColor = .secondaryLabelColor
        case "ascii": f.stringValue = line.ascii; f.textColor = .labelColor
        default: f.stringValue = line.hex; f.textColor = .labelColor
        }
        return f
    }

    /// 選んだ行をコピー (表示のまま)
    @objc func copy(_ sender: Any?) {
        let text = table.selectedRowIndexes.map { r -> String in
            let l = BinaryData.line(data, at: r * BinaryData.bytesPerLine, offsetDigits: offsetDigits)
            return "\(l.offset)  \(l.hex)  |\(l.ascii)|"
        }.joined(separator: "\n")
        guard !text.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func goTo(_ sender: NSTextField) {
        let s = sender.stringValue.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "0x", with: "")
        guard let off = Int(s, radix: 16), off >= 0, off < max(data.count, 1) else { NSSound.beep(); return }
        let row = off / BinaryData.bytesPerLine
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        window?.makeFirstResponder(table)
    }

    @objc private func openAsText(_ sender: Any?) {
        FileViewers.forceText.insert(url)
        let u = url
        // 一時ファイルをすぐ消さないように、先に閉じる処理から外す
        FileViewers.open.removeAll { $0 === self }
        window?.delegate = nil
        window?.close()
        NSDocumentController.shared.openDocument(withContentsOf: u, display: true) { doc, _, error in
            if let error = error { NSApp.presentError(error) }
            (doc as? Document)?.editor?.focusEditor()
        }
    }

    @objc private func openExternally(_ sender: Any?) { NSWorkspace.shared.open(url) }
}
