import AppKit
import HinokiCore

/// スクリーンショット: 表示されている部分・文書全体・アプリ全体 (ウインドウ全体) を画像にして、コピーするか PNG で保存する
enum Screenshot {
    /// 画像にする範囲
    enum Scope: Int {
        case visible, whole, window
    }
    /// 文書全体を画像にするときの高さの上限 (ピクセル)。これより長い文書は途中までにする
    static let maxPixelHeight: CGFloat = 20000
    /// 原稿用紙を全部並べるときの枚数の上限
    static let maxSheets = 20
    /// 横に長い行 (折り返さない設定) の幅の上限 (pt)
    static let maxWidth: CGFloat = 6000

    /// 前回選んだ範囲
    static var lastScope = Scope.visible

    struct Shot {
        let rep: NSBitmapImageRep
        /// 長すぎて途中までになった
        let truncated: Bool
    }

    /// 上下を返して、左上が原点・1 が 1 pt の描画先を作る
    static func makeBitmap(size: NSSize, scale: CGFloat) -> (NSBitmapImageRep, NSGraphicsContext)? {
        let w = Int((size.width * scale).rounded(.up)), h = Int((size.height * scale).rounded(.up))
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let g = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        g.cgContext.translateBy(x: 0, y: CGFloat(h))
        g.cgContext.scaleBy(x: scale, y: -scale)
        return (rep, NSGraphicsContext(cgContext: g.cgContext, flipped: true))
    }

    /// アプリ全体: ウインドウをタイトル・ツールバー・横の欄・フッターごと画像にする
    /// (ウインドウに自分で描いてもらうので、Mac の「画面収録」の許可は要らない)
    static func window(_ window: NSWindow) -> Shot? {
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        return visible(of: view)
    }

    /// A4 用紙: いちばん多く見えている 1 枚を、まわりに少し余白を付けて、ちょうど用紙が入る大きさで撮る
    /// (用紙の一部が画面の外にあっても、その 1 枚を丸ごと描く)
    static func a4Page(_ tv: EditorTextView) -> Shot? {
        let L = tv.a4Layout
        let visible = tv.visibleRect
        var best = 0, bestArea: CGFloat = -1
        for k in 0..<tv.a4PageCount {
            let r = L.pageRect(k).intersection(visible)
            let area = r.isNull ? 0 : r.width * r.height
            if area > bestArea { best = k; bestArea = area }
        }
        let margin = EditorTextView.A4Layout.gap / 2
        let rect = L.pageRect(best).insetBy(dx: -margin, dy: -margin).intersection(tv.bounds)
        guard !rect.isEmpty, let rep = tv.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        // カーソル (点滅する縦線) は写さない
        let was = tv.isExportingPDF
        tv.isExportingPDF = true
        tv.cacheDisplay(in: rect, to: rep)
        tv.isExportingPDF = was
        return Shot(rep: rep, truncated: false)
    }

    /// ビューの見えている部分をそのまま画像にする
    static func visible(of view: NSView) -> Shot? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return Shot(rep: rep, truncated: false)
    }

    /// 原稿用紙: 全部の用紙を縦に並べる (1 mm = 4 ピクセル)
    static func genko(text: String, autoFormat: Bool, ruby: [Genko.Ruby], horizontal: Bool) -> Shot? {
        let columns = Genko.layout(text, autoFormat: autoFormat)
        let placed = Genko.placeRuby(columns, ruby)
        let total = Genko.sheetCount(columns)
        let shown = min(total, maxSheets)
        let u: CGFloat = 4, pad: CGFloat = 16
        let sheet = GenkoRenderer.sheetSize(u: u, horizontal: horizontal)
        let size = NSSize(width: sheet.width + pad * 2, height: pad + CGFloat(shown) * (sheet.height + pad))
        guard let (rep, g) = makeBitmap(size: size, scale: 1) else { return nil }
        let ctx = g.cgContext
        ctx.setFillColor(GenkoView.deskColor.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        for i in 0..<shown {
            GenkoRenderer.drawSheet(i, of: total, columns: columns, ruby: placed,
                                    at: CGPoint(x: pad, y: pad + CGFloat(i) * (sheet.height + pad)), u: u,
                                    paper: GenkoRenderer.paperColor, horizontal: horizontal, in: ctx)
        }
        return Shot(rep: rep, truncated: total > shown)
    }

    /// 通常の文書・A4: 見えていない部分も含めて、文字の面を最初から最後まで描く。lineNumbers が true なら左に行番号も付ける
    static func whole(textView tv: EditorTextView, lineNumbers: Bool, gutterWidth: CGFloat, countsVisualLines: Bool) -> Shot? {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        lm.ensureLayout(for: tc)
        let full = tv.bounds
        let width = min(full.width, maxWidth)
        var scale = tv.window?.backingScaleFactor ?? 2
        // 長い文書は等倍にして、それでも収まらなければ途中まで
        if full.height * scale > maxPixelHeight { scale = 1 }
        let height = min(full.height, maxPixelHeight / scale)
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        let gutter = lineNumbers ? gutterWidth : 0
        guard let (rep, g) = makeBitmap(size: NSSize(width: gutter + width, height: height), scale: scale) else { return nil }

        // 文字の面 (色分け・記号・[EOF] も画面と同じに出る)
        guard let textRep = tv.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        tv.cacheDisplay(in: rect, to: textRep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        textRep.draw(in: NSRect(x: gutter, y: 0, width: width, height: height), from: .zero, operation: .copy,
                     fraction: 1, respectFlipped: true, hints: nil)

        if lineNumbers {
            Theme.gutterBackground.setFill()
            NSRect(x: 0, y: 0, width: gutter, height: height).fill()
            Theme.gutterSeparator.setFill()
            NSRect(x: gutter - 1, y: 0, width: 1, height: height).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: Theme.gutterText,
            ]
            let top = tv.textContainerOrigin.y
            func label(_ n: Int, _ fragment: NSRect) {
                let s = "\(n)" as NSString
                let size = s.size(withAttributes: attrs)
                let lineHeight = fragment.height > 0 ? fragment.height : size.height
                s.draw(at: NSPoint(x: gutter - size.width - 8, y: top + fragment.minY + (lineHeight - size.height) / 2), withAttributes: attrs)
            }
            let ns = tv.string as NSString
            let shown = lm.glyphRange(forBoundingRect: rect.offsetBy(dx: 0, dy: -top), in: tc)
            if countsVisualLines {
                // ワープロ的: 折り返した行にも番号
                var n = 0
                lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: NSMaxRange(shown))) { fragment, _, _, _, _ in
                    n += 1
                    label(n, fragment)
                }
                let extra = lm.extraLineFragmentRect
                if !extra.isEmpty, top + extra.minY < height { label(n + 1, extra) }
            } else {
                let index = LineIndex(ns)
                let lastChar = NSMaxRange(lm.characterRange(forGlyphRange: shown, actualGlyphRange: nil))
                var line = 0
                while line < index.lineCount {
                    let start = index.startOfLine(line)
                    if start > lastChar { break }
                    if start >= ns.length {
                        // 最終行が空 (末尾が改行) のとき
                        let extra = lm.extraLineFragmentRect
                        if !extra.isEmpty, top + extra.minY < height { label(line + 1, extra) }
                        break
                    }
                    let fragment = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: start), effectiveRange: nil)
                    if top + fragment.minY >= height { break }
                    label(line + 1, fragment)
                    line += 1
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return Shot(rep: rep, truncated: full.height > height + 0.5 || full.width > width + 0.5)
    }

    static func png(_ shot: Shot) -> Data? {
        shot.rep.representation(using: .png, properties: [:])
    }

    static func copy(_ shot: Shot) -> Bool {
        guard let data = png(shot) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        let image = NSImage(size: shot.rep.size)
        image.addRepresentation(shot.rep)
        // PNG そのものと、画像として受け取るアプリ向けの両方を置く
        let ok = pb.writeObjects([image])
        pb.setData(data, forType: .png)
        return ok
    }
}

extension EditorWindowController {
    /// いまの設定で画像を作る
    func screenshot(scope: Screenshot.Scope) -> Screenshot.Shot? {
        if scope == .window { return presentingWindow.flatMap { Screenshot.window($0) } }   // 窓割りの画面なら、並べているウインドウ全体
        if scope == .visible {
            // A4・原稿用紙のときは、見えている用紙 1 枚がちょうど入る大きさで
            if paperMode == .a4 { return Screenshot.a4Page(screenshotTextView) }
            if paperMode == .genko, let rep = screenshotTextView.genkoProxy.flatMap({ $0 as? GenkoView })?.visibleSheetImage() {
                return Screenshot.Shot(rep: rep, truncated: false)
            }
            return Screenshot.visible(of: screenshotArea)
        }
        let tv = screenshotTextView
        if paperMode == .genko {
            let text = tv.string
            return Screenshot.genko(text: text, autoFormat: tv.genkoAutoFormat,
                                    ruby: UserDefaults.standard.bool(forKey: "genkoFurigana") ? Furigana.ruby(for: text) : [],
                                    horizontal: tv.genkoHorizontal)
        }
        let numbers = paperMode == .normal && UserDefaults.standard.bool(forKey: "lineNumbers")
        return Screenshot.whole(textView: tv, lineNumbers: numbers, gutterWidth: screenshotGutterWidth,
                                countsVisualLines: UserDefaults.standard.string(forKey: "lineCounting") == "visual")
    }

    @objc func screenshotHM(_ sender: Any?) {
        guard let window = window, let doc = document as? Document else { return }
        let alert = NSAlert()
        alert.messageText = L("スクリーンショット (画像にする)")
        alert.informativeText = L("画像にする範囲を選んでください。")
        let visible = NSButton(radioButtonWithTitle: L("表示されている部分"), target: nil, action: nil)
        let whole = NSButton(radioButtonWithTitle: L("文書全体"), target: nil, action: nil)
        let app = NSButton(radioButtonWithTitle: L("アプリ全体 (ウインドウ全体)"), target: nil, action: nil)
        let chooser = ScreenshotChooser([visible, whole, app])
        for b in [visible, whole, app] {
            b.target = chooser
            b.action = #selector(ScreenshotChooser.pick(_:))
        }
        chooser.select(Screenshot.lastScope.rawValue)
        let stack = NSStackView(views: [
            visible, SettingsUI.label(paperMode == .a4 ? L("いま見えている A4 用紙 1 枚を、ちょうど用紙が入る大きさで画像にします。") : paperMode == .genko ? L("いま見えている原稿用紙 1 枚を、ちょうど用紙が入る大きさで画像にします。") : L("いま見えている範囲を、そのまま画像にします。"), small: true),
            whole, SettingsUI.label(L("見えていない部分も含めて、最初から最後までを 1 枚の画像にします。"), small: true),
            app, SettingsUI.label(L("ツールバー・タブ・横の欄・フッターも入れて、ウインドウをまるごと画像にします。"), small: true),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(10, after: stack.views[1])
        stack.setCustomSpacing(10, after: stack.views[3])
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        alert.accessoryView = stack
        alert.addButton(withTitle: L("コピー"))
        alert.addButton(withTitle: L("画像として保存…"))
        alert.addButton(withTitle: L("キャンセル"))
        alert.beginSheetModal(for: window) { [weak self] response in
            _ = chooser // シートが閉じるまで持っておく
            guard let self = self, response != .alertThirdButtonReturn else { return }
            let scope = Screenshot.Scope(rawValue: chooser.selected) ?? .visible
            Screenshot.lastScope = scope
            // シートが消えてから撮る
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if response == .alertFirstButtonReturn {
                    self.finishScreenshot(scope: scope, saveTo: nil)
                    return
                }
                let panel = NSSavePanel()
                panel.allowedFileTypes = ["png"]
                let name = doc.fileURL?.lastPathComponent ?? doc.displayName ?? L("画像")
                panel.nameFieldStringValue = (name as NSString).deletingPathExtension + ".png"
                panel.beginSheetModal(for: window) { r in
                    guard r == .OK, let url = panel.url else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.finishScreenshot(scope: scope, saveTo: url) }
                }
            }
        }
    }

    private func finishScreenshot(scope: Screenshot.Scope, saveTo url: URL?) {
        guard let shot = screenshot(scope: scope), let data = Screenshot.png(shot) else {
            presentError(NSError(domain: "Satoru", code: 40, userInfo: [NSLocalizedDescriptionKey: L("画像にできませんでした")]))
            return
        }
        var message: String
        if let url = url {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                presentError(error)
                return
            }
            message = L("🖼 画像を保存しました: {0}", url.lastPathComponent)
        } else {
            guard Screenshot.copy(shot) else {
                presentError(NSError(domain: "Satoru", code: 40, userInfo: [NSLocalizedDescriptionKey: L("画像にできませんでした")]))
                return
            }
            message = L("🖼 画像をコピーしました ({0} × {1})", shot.rep.pixelsWide, shot.rep.pixelsHigh)
        }
        if shot.truncated { message += " " + L("(長いので途中までです)") }
        remoteStatusChanged(message)
    }
}

/// 範囲のラジオボタン (別々の行に置くので、選んだもの以外をここで外す)
private final class ScreenshotChooser: NSObject {
    let buttons: [NSButton]
    private(set) var selected = 0

    init(_ buttons: [NSButton]) {
        self.buttons = buttons
    }

    func select(_ index: Int) {
        selected = max(0, min(index, buttons.count - 1))
        for (i, b) in buttons.enumerated() { b.state = i == selected ? .on : .off }
    }

    @objc func pick(_ sender: NSButton) { select(buttons.firstIndex(of: sender) ?? 0) }
}
