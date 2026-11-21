import AppKit
import HinokiCore

enum MainMenu {
    static let appName = "さとるエディタ"

    static func build() -> NSMenu {
        let main = NSMenu()

        @discardableResult
        func submenu(_ title: String, in parent: NSMenu, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach { menu.addItem($0) }
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            parent.addItem(holder)
            return menu
        }

        func item(_ title: String, _ action: String?, _ key: String = "",
                  _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0, object: String? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action.map { Selector($0) }, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            i.representedObject = object
            return i
        }

        let sep = { NSMenuItem.separator() }

        submenu(appName, in: main, [
            item("\(appName)について", "orderFrontStandardAboutPanel:"),
            sep(),
            item("設定…", "openSettingsHM:", ","),
            sep(),
            item("\(appName)を隠す", "hide:", "h"),
            item("ほかを隠す", "hideOtherApplications:", "h", [.command, .option]),
            item("すべてを表示", "unhideAllApplications:"),
            sep(),
            item("\(appName)を終了", "terminate:", "q"),
        ])

        let file = submenu("ファイル", in: main, [
            item("新規", "newDocument:", "n"),
            item("新規タブ", "newWindowForTab:", "t"),
            item("開く…", "openDocument:", "o"),
            item("フォルダを開く…", "openFolderHM:", "o", [.command, .shift]),
        ])
        submenu("最近使ったファイル", in: file, [item("メニューを消去", "clearRecentDocuments:")])
        [sep(),
         item("閉じる", "performClose:", "w"),
         item("保存", "saveDocument:", "s"),
         item("別名で保存…", "saveDocumentAs:", "s", [.command, .shift]),
         item("保存時の状態に戻す", "revertDocumentToSaved:"),
         sep(),
         item("印刷…", "printDocumentHM:", "p"),
         // PDF・Word とのやりとりは、見出しつきの別の区切りにまとめる
         sep(),
         MainMenu.sectionHeader("PDF・Word"),
         item("PDF として書き出す…", "exportPDFHM:", "p", [.command, .shift]),
         item("Word (.docx) として書き出す…", "exportWordHM:"),
         item("PDF からテキストを読み込む…", "importPDFHM:"),
        ].forEach { file.addItem($0) }

        let edit = submenu("編集", in: main, [
            item("取り消す", "undo:", "z"),
            item("やり直す", "redo:", "z", [.command, .shift]),
            sep(),
            item("カット", "cut:", "x"),
            item("コピー", "copy:", "c"),
            item("ペースト", "paste:", "v"),
            item("すべてを選択", "selectAll:", "a"),
            sep(),
        ])
        let arrowUp = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        let arrowDown = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        submenu("行", in: edit, [
            item("行を複製", "duplicateLineHM:", "d"),
            item("行を削除", "deleteLineHM:", "k", [.command, .shift]),
            item("行を上へ移動", "moveLineUpHM:", arrowUp, [.command, .option]),
            item("行を下へ移動", "moveLineDownHM:", arrowDown, [.command, .option]),
            sep(),
            item("インデント", "indentHM:", "]"),
            item("逆インデント", "outdentHM:", "["),
            item("コメント / コメント解除", "toggleCommentHM:", "/"),
            sep(),
            item("行を並べ替え", "sortLinesHM:"),
            item("重複行を削除", "uniqueLinesHM:"),
            item("行末の空白を削除", "trimTrailingSpacesHM:"),
        ])
        submenu("変換", in: edit, [
            item("大文字に", "uppercaseWord:"),
            item("小文字に", "lowercaseWord:"),
            item("先頭を大文字に", "capitalizeWord:"),
        ])

        // ⌘F は打ちながら探せる検索バー、⌘R は正規表現の検索・置換パネル
        let search = NSMenu(title: "検索")
        [item("検索… (条件を決めて探す)", "showFindPanelHM:", "f"),
         item("次を検索", "findNextRegexHM:", "g"),
         item("前を検索", "findPreviousRegexHM:", "g", [.command, .shift]),
         item("選択部分を検索語にする", "useSelectionForFindHM:", "e"),
         sep(),
         item("置換…", "showReplacePanelHM:", "r"),
         item("簡易検索バー (ウインドウ内)", "performTextFinderAction:", "f", [.command, .option], tag: NSTextFinder.Action.showFindInterface.rawValue),
         sep(),
         item("grep…", "grepHM:", "f", [.command, .shift]),
         sep(),
         item("指定行へ移動…", "goToLineHM:", "l"),
         item("対応する括弧へ移動", "jumpToMatchingBracketHM:", "m", [.command, .shift]),
        ].forEach { search.addItem($0) }
        let searchHolder = NSMenuItem(title: "検索", action: nil, keyEquivalent: "")
        searchHolder.submenu = search
        main.addItem(searchHolder)

        let view = submenu("表示", in: main, [
            item("折り返し", "toggleWrapHM:"),
            item("改行・タブ・空白の記号を表示", "toggleInvisiblesHM:"),
            item("行番号を表示", "toggleLineNumbersHM:"),
            item("桁ルーラーを表示", "toggleColumnRulerHM:"),
            item("フォルダツリー", "toggleFolderTreeHM:", "e", [.command, .shift]),
            sep(),
            item("上下に分割", "toggleSplitHM:", "s", [.command, .control]),
            item("分割したもう一方へ移動", "switchSplitPaneHM:", "\u{F709}", []),
            sep(),
            item("前のタブ", "selectPreviousTab:", "{", [.command, .shift]),
            item("次のタブ", "selectNextTab:", "}", [.command, .shift]),
            item("すべてのタブを表示", "toggleTabOverview:", "\\", [.command, .shift]),
        ])
        let paper = NSMenu(title: "用紙")
        paper.addItem(item("通常", "setPaperModeHM:", tag: 0))
        paper.addItem(item("作文用紙 (縦書き 400 字詰め)", "setPaperModeHM:", tag: 1))
        paper.addItem(item("A4 用紙 (横書き 40 字 × 36 行)", "setPaperModeHM:", tag: 2))
        paper.addItem(sep())
        paper.addItem(item("保存のとき、見たままの PDF も一緒に作る", "togglePaperAutoFormatHM:", object: "paperSavePDF"))
        paper.addItem(sep())
        paper.addItem(item("作文用紙: 自動整形 (題名 3 マス下げ・名前 下寄せ・段落 1 マス下げ)", "togglePaperAutoFormatHM:", object: "genkoAutoFormat"))
        paper.addItem(item("作文用紙: 改行のたび全角スペースを入れる (自動整形オフのとき)", "toggleGenkoAssistHM:", object: "genkoAutoIndent"))
        paper.addItem(item("作文用紙: 半角の英数字を全角にする", "toggleGenkoAssistHM:", object: "genkoFullWidth"))
        paper.addItem(sep())
        paper.addItem(item("A4: 自動整形 (題名 中央・名前 右寄せ・段落 1 字下げ)", "togglePaperAutoFormatHM:", object: "a4AutoFormat"))
        paper.addItem(item("A4 段落: 自動", "setParagraphAlignHM:", tag: 0))
        paper.addItem(item("A4 段落: 左寄せ", "setParagraphAlignHM:", "{", [.command, .control], tag: 1))
        paper.addItem(item("A4 段落: 中央寄せ", "setParagraphAlignHM:", "|", [.command, .control], tag: 2))
        paper.addItem(item("A4 段落: 右寄せ", "setParagraphAlignHM:", "}", [.command, .control], tag: 3))
        let paperHolder = NSMenuItem(title: "用紙", action: nil, keyEquivalent: "")
        paperHolder.submenu = paper
        let counting = NSMenu(title: "行の数え方")
        counting.addItem(item("エディタ的 (改行ごとに 1 行)", "setLineCountingHM:", object: "logical"))
        counting.addItem(item("ワープロ的 (折り返しも 1 行)", "setLineCountingHM:", object: "visual"))
        let countingHolder = NSMenuItem(title: "行の数え方", action: nil, keyEquivalent: "")
        countingHolder.submenu = counting
        view.insertItem(countingHolder, at: 4)

        // 「設定」メニュー (秀丸の「その他」にあたる)。文字コード・言語・テーマもここにまとめる
        let settings = NSMenu(title: "設定")
        settings.addItem(item("動作環境…", "openGeneralSettingsHM:"))
        settings.addItem(item("ファイルタイプ別の設定…", "openFileTypeSettingsHM:"))
        settings.addItem(item("色・フォント…", "openThemeHM:"))
        settings.addItem(item("キー割り当て…", "openKeySettingsHM:"))
        settings.addItem(item("メニュー編集…", "openMenuSettingsHM:"))
        settings.addItem(item("ツールバーを編集…", "runToolbarCustomizationPalette:"))
        settings.addItem(item("関連付け・右クリックメニュー…", "openAssociationSettingsHM:"))
        settings.addItem(sep())
        settings.addItem(item("設定内容の保存…", "exportSettingsHM:"))
        settings.addItem(item("設定内容の復元…", "importSettingsHM:"))
        settings.addItem(sep())
        submenu("保存する文字コード", in: settings, TextEncoding.allCases.map {
            item($0.displayName, "setSaveEncodingHM:", object: $0.rawValue)
        })
        submenu("文字コードを指定して開き直す", in: settings, TextEncoding.allCases.map {
            item($0.displayName, "reopenWithEncodingHM:", object: $0.rawValue)
        })
        submenu("改行コード", in: settings, LineEnding.allCases.map {
            item($0.displayName, "setLineEndingHM:", object: $0.rawValue)
        })
        settings.addItem(sep())
        let language = submenu("言語 (このファイル)", in: settings, [])
        language.delegate = LanguageMenuDelegate.shared
        submenu("テーマ", in: settings, Theme.presets.map {
            item($0.name, "selectThemePresetHM:", object: $0.name)
        })
        let settingsHolder = NSMenuItem(title: "設定", action: nil, keyEquivalent: "")
        settingsHolder.submenu = settings
        main.addItem(settingsHolder)

        var aiItems = [
            item("AI アシスタントを表示 / 隠す", "toggleAIHM:", "a", [.command, .shift]),
            sep(),
        ]
        for (i, a) in AIPanel.Action.allCases.enumerated() {
            aiItems.append(item(a.title, "aiActionHM:", tag: i))
        }
        aiItems += [sep(), item("利用状況と料金…", "openAIUsageHM:"), item("AI の設定…", "openAISettingsHM:")]
        submenu("AI", in: main, aiItems)

        main.addItem(paperHolder)

        submenu("サーバ", in: main, [
            item("サーバにつなぐ (SFTP / FTP)…", "openServersHM:", "o", [.command, .control]),
            item("編集をすぐサーバに反映する", "toggleRemoteAutoUploadHM:"),
        ])

        submenu("暗号化", in: main, [
            item("暗号化して保存… / 鍵の変更…", "encryptDocumentHM:"),
            item("暗号化を解除…", "decryptDocumentHM:"),
            sep(),
            item("いつも暗号化して保存する", "toggleEncryptAlwaysHM:"),
        ])

        submenu("共有", in: main, [
            item("この文書を共有する…", "startShareHM:"),
            item("共有に参加…", "joinShareHM:"),
            sep(),
            item("チャットを表示 / 隠す", "toggleChatHM:"),
            item("共有を終了 / 抜ける", "stopShareHM:"),
        ])

        let window = submenu("ウインドウ", in: main, [
            item("しまう", "performMiniaturize:", "m"),
            item("拡大/縮小", "performZoom:"),
            sep(),
            item("ウインドウ上下分割", "toggleSplitHM:"),
            item("分割したもう一方へ移動", "switchSplitPaneHM:"),
            sep(),
            item("すべてを手前に移動", "arrangeInFront:"),
        ])
        NSApp.windowsMenu = window
        // 「機能」: 拡張機能の ON / OFF をまとめたメニュー
        let features = NSMenu(title: "追加機能")
        for e in EditorExtension.displayOrder {
            features.addItem(item(e.title, "toggleExtensionHM:", object: e.rawValue))
        }
        features.addItem(sep())
        features.addItem(item("追加機能の説明と設定…", "openExtensionsSettingsHM:"))
        let featuresHolder = NSMenuItem(title: "追加機能", action: nil, keyEquivalent: "")
        featuresHolder.submenu = features
        main.addItem(featuresHolder)

        // 設定はいちばん右に
        main.removeItem(settingsHolder)
        main.addItem(settingsHolder)
        return main
    }
}


extension MainMenu {
    /// メニューの中の区切りの見出し (押せない小さな灰色の文字) に付ける目印
    static let sectionHeaderTag = -9001

    static func sectionHeader(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.tag = sectionHeaderTag
        i.isEnabled = false
        i.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return i
    }
}

/// 言語メニューは設定ファイルで増減するので開くたびに作り直す
final class LanguageMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = LanguageMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: "自動 (拡張子で判定)", action: #selector(EditorWindowController.setLanguageHM(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        for p in Profiles.store.profiles {
            let i = NSMenuItem(title: p.name, action: #selector(EditorWindowController.setLanguageHM(_:)), keyEquivalent: "")
            i.representedObject = p.name
            menu.addItem(i)
        }
    }
}
