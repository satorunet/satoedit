import AppKit
import HinokiCore
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
        panel.message = L("A4・40 字 × 36 行で PDF にします")
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
            throw NSError(domain: "Satoru", code: 30, userInfo: [NSLocalizedDescriptionKey: L("PDF を作れませんでした")])
        }
    }
}

/// PDF の文字を取り出してテキストとして開く
enum PDFImport {
    static func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = L("テキストとして読み込む PDF を選んでください")
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
            throw NSError(domain: "Satoru", code: 31, userInfo: [NSLocalizedDescriptionKey: L("PDF を開けませんでした")])
        }
        if pdf.isLocked {
            throw NSError(domain: "Satoru", code: 32, userInfo: [NSLocalizedDescriptionKey: L("パスワード付きの PDF は読めません")])
        }
        var pages: [String] = []
        for i in 0..<pdf.pageCount {
            pages.append(pdf.page(at: i)?.string ?? "")
        }
        let text = pages.joined(separator: "\n\n").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw NSError(domain: "Satoru", code: 33, userInfo: [NSLocalizedDescriptionKey: L("この PDF には文字がありません (画像だけの PDF は読めません)")])
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
        doc.displayName = url.deletingPathExtension().lastPathComponent + L(" (PDF から)")
        return doc
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
