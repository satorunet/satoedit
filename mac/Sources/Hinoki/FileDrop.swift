import AppKit
import HinokiCore

/// エディタにファイルを放り込んだら開く (フォルダならフォルダツリーに出す)。
/// ⌥ を押しながら放り込むと、これまでどおりファイルの場所を文字として入れる
enum FileDrop {
    static func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls ?? []
    }

    /// 開く扱いにするか (ファイルが入っていて、⌥ を押していない)
    static func handles(_ info: NSDraggingInfo) -> Bool {
        !NSEvent.modifierFlags.contains(.option) && !fileURLs(info).isEmpty
    }

    /// target は放り込まれたエディタ。まっさらな新規文書なら、開いたファイルと入れ替える
    static func open(_ urls: [URL], into target: EditorWindowController? = nil) {
        var folders: [URL] = []
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            // .app などのパッケージはフォルダとして扱わない
            if isDir.boolValue && !NSWorkspace.shared.isFilePackage(atPath: url.path) {
                folders.append(url)
            } else {
                files.append(url)
            }
        }
        // 何も書いていない新規文書に放り込んだら、その文書は閉じて、開いたファイルに入れ替える
        let blank: Document? = {
            guard let d = target?.hdoc, d.fileURL == nil, d.remote == nil, !d.isDocumentEdited,
                  (target?.textView.string.isEmpty ?? false) else { return nil }
            return d
        }()
        var replaced = false
        for (i, url) in files.enumerated() {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, error in
                if let error = error, (error as NSError).code != NSUserCancelledError {
                    NSApp.presentError(error)
                }
                guard let doc = doc as? Document, let editor = doc.editor else { return }
                if let b = blank, !replaced, b !== doc {
                    replaced = true
                    b.close()
                }
                // 最後に放り込んだファイルを手前に出して、すぐ書けるようにする
                if i == files.count - 1 { editor.focusEditor() }
            }
        }
        // フォルダはフォルダツリーに出す (最後に放り込んだもの)
        if let folder = folders.last {
            FolderTree.setRoot(folder)
            if !EditorExtension.folder.isOn { EditorExtension.folder.set(true) }
        }
    }
}
