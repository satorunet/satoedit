import AppKit
import PDFKit

/// 「PDF として書き出す」: A4 縦・40 字 × 36 行・10.5 pt (ワープロの標準) で、ページ番号つきの PDF を作る
enum PDFExport {
    /// ページ番号を下に入れる印刷用のテキストビュー
    private final class PrintTextView: NSTextView {
        override var pageHeader: NSAttributedString { NSAttributedString(string: "") }
        override var pageFooter: NSAttributedString {
            let center = NSMutableParagraphStyle()
            center.alignment = .center
            let n = NSPrintOperation.current?.currentPage ?? 1
            return NSAttributedString(string: "- \(n) -", attributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.darkGray, .paragraphStyle: center,
            ])
        }
    }

    static func export(text: NSAttributedString, suggestedName: String, from window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (suggestedName as NSString).deletingPathExtension + ".pdf"
        panel.message = "A4・40 字 × 36 行で PDF にします"
        let run: (URL) -> Void = { url in
            do {
                try write(text: text, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                NSApp.presentError(error)
            }
        }
        if let w = window {
            panel.beginSheetModal(for: w) { r in if r == .OK, let u = panel.url { run(u) } }
        } else if panel.runModal() == .OK, let u = panel.url {
            run(u)
        }
    }

    static func write(text: String, to url: URL) throws {
        let font = NSFont(name: "HiraMinProN-W3", size: 10.5) ?? .systemFont(ofSize: 10.5)
        let style = NSMutableParagraphStyle()
        let pitch = CGFloat((842 - 99 - 85 - 0.5) / 36.0)
        style.minimumLineHeight = pitch
        style.maximumLineHeight = pitch
        try write(text: NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: style]), to: url)
    }

    /// 書式 (寄せ・字下げ) つきの文章を A4 の PDF にする
    static func write(text: NSAttributedString, to url: URL) throws {
        // A4 = 595 × 842 pt。余白は上 35 mm・下 30 mm・左右 30 mm
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)
        info.orientation = .portrait
        info.topMargin = 99
        info.bottomMargin = 85
        info.leftMargin = 85
        info.rightMargin = 85
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = true // ページ番号 (pageFooter) を入れる

        let width = 595 - 85 * 2.0
        let view = PrintTextView(frame: NSRect(x: 0, y: 0, width: width, height: 842))
        view.layoutManager?.usesFontLeading = false
        view.textContainer?.lineFragmentPadding = 0
        view.textContainerInset = .zero
        view.isRichText = false
        view.backgroundColor = .white
        view.textStorage?.setAttributedString(text)
        view.isVerticallyResizable = true
        view.sizeToFit()
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else {
            throw NSError(domain: "Satoru", code: 30, userInfo: [NSLocalizedDescriptionKey: "PDF を作れませんでした"])
        }
    }
}

/// PDF の文字を取り出してテキストとして開く
enum PDFImport {
    static func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = "テキストとして読み込む PDF を選んでください"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try openAsText(url)
        } catch {
            NSApp.presentError(error)
        }
    }

    /// ページごとの文字を取り出す (ページの区切りには空行を入れる)
    static func text(of url: URL) throws -> String {
        guard let pdf = PDFDocument(url: url) else {
            throw NSError(domain: "Satoru", code: 31, userInfo: [NSLocalizedDescriptionKey: "PDF を開けませんでした"])
        }
        if pdf.isLocked {
            throw NSError(domain: "Satoru", code: 32, userInfo: [NSLocalizedDescriptionKey: "パスワード付きの PDF は読めません"])
        }
        var pages: [String] = []
        for i in 0..<pdf.pageCount {
            pages.append(pdf.page(at: i)?.string ?? "")
        }
        let text = pages.joined(separator: "\n\n").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw NSError(domain: "Satoru", code: 33, userInfo: [NSLocalizedDescriptionKey: "この PDF には文字がありません (画像だけの PDF は読めません)"])
        }
        return text
    }

    @discardableResult
    static func openAsText(_ url: URL) throws -> Document {
        let doc = Document()
        doc.text = try text(of: url)
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
        doc.displayName = url.deletingPathExtension().lastPathComponent + " (PDF から)"
        return doc
    }
}

/// 作文用紙 (縦書き・マス目つき) を画面のとおりに PDF にする。400 字 (20 列) ごとに 1 ページ
enum GenkoPDF {
    static func write(textView tv: EditorTextView, to url: URL) throws {
        guard tv.paperMode == .genko, let lm = tv.layoutManager, let tc = tv.textContainer else {
            throw NSError(domain: "Satoru", code: 34, userInfo: [NSLocalizedDescriptionKey: "作文用紙モードではありません"])
        }
        lm.ensureLayout(for: tc)
        var lines = 0
        lm.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: lm.numberOfGlyphs)) { _, _, _, _, _ in lines += 1 }
        let pages = max(1, (max(1, lines) + 19) / 20)
        let cell = tv.genkoCell
        let o = tv.textContainerOrigin
        let margin: CGFloat = 20
        tv.isExportingPDF = true
        defer { tv.isExportingPDF = false; tv.needsDisplay = true }
        let out = PDFDocument()
        for p in 0..<pages {
            // 縦書きのビューは内部の座標が 90° 回っている (x = 画面の縦、y = 右端からの距離)。
            // 幅と高さが違う範囲を渡すと出力が欠けるので、正方形で切り出してから余分 (左の extra) を落とす。
            // 上下は余白 20 pt + 下の「n 枚目」16 pt。左右は隣の枚が写らないよう枠ぎりぎり (2 pt)
            let edge: CGFloat = 2
            let grid = cell * CGFloat(EditorTextView.genkoRows)
            let side = grid + margin * 2 + 16
            let width = grid + edge * 2
            let rect = NSRect(x: o.x - margin, y: o.y + CGFloat(p * 20) * cell - edge, width: side, height: side)
            let data = tv.dataWithPDF(inside: rect)
            guard let page = PDFDocument(data: data)?.page(at: 0) else { continue }
            let crop = NSRect(x: side - width, y: 0, width: width, height: side)
            page.setBounds(crop, for: .mediaBox)
            page.setBounds(crop, for: .cropBox)
            out.insert(page, at: out.pageCount)
        }
        guard out.pageCount > 0, out.write(to: url) else {
            throw NSError(domain: "Satoru", code: 35, userInfo: [NSLocalizedDescriptionKey: "PDF を作れませんでした"])
        }
    }
}

/// Word (.docx) に書き出す
enum WordExport {
    static func write(text: NSAttributedString, to url: URL) throws {
        let data = try text.data(from: NSRange(location: 0, length: text.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try data.write(to: url, options: .atomic)
    }
}
