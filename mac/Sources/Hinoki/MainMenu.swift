import AppKit
import HinokiCore

enum MainMenu {
    static var appName: String { L("エディタβ") }

    static func build() -> NSMenu {
        let main = NSMenu()

        // メニューの名前は日本語で書き、画面には L() を通して出す。
        // 日本語の名前は identifier に残す (キー割り当て・メニュー編集は、言語を切り替えても同じ名前で項目を覚えているため)
        func holder(_ title: String, _ menu: NSMenu) -> NSMenuItem {
            let h = NSMenuItem(title: L(title), action: nil, keyEquivalent: "")
            h.identifier = NSUserInterfaceItemIdentifier(title)
            h.submenu = menu
            return h
        }

        @discardableResult
        func submenu(_ title: String, in parent: NSMenu, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: L(title))
            items.forEach { menu.addItem($0) }
            parent.addItem(holder(title, menu))
            return menu
        }

        /// id は、title が画面用の言葉 (訳したあと) のときに渡す日本語の名前。args は {0} に入れる言葉
        func item(_ title: String, _ action: String?, _ key: String = "",
                  _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0, object: String? = nil,
                  id: String? = nil, args: [Any] = []) -> NSMenuItem {
            let i = NSMenuItem(title: I18n.translate(title, args), action: action.map { Selector($0) }, keyEquivalent: key)
            i.identifier = NSUserInterfaceItemIdentifier(id ?? title)
            i.keyEquivalentModifierMask = mods
            i.tag = tag
            i.representedObject = object
            return i
        }

        let sep = { NSMenuItem.separator() }

        submenu(appName, in: main, [
            item("{0} について", "showAboutHM:", args: [appName]),
            item("アップデートを確認…", "checkForUpdatesHM:"),
            item("アップデートを自動で確認", "toggleAutoUpdateHM:"),
            sep(),
            item("設定…", "openSettingsHM:", ","),
            sep(),
            item("{0} を隠す", "hide:", "h", args: [appName]),
            item("ほかを隠す", "hideOtherApplications:", "h", [.command, .option]),
            item("すべてを表示", "unhideAllApplications:"),
            sep(),
            item("{0} を終了", "terminate:", "q", args: [appName]),
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
         item("名前を変更…", "renameFileHM:"),
         item("保存時の状態に戻す", "revertDocumentToSaved:"),
         item("版の履歴…", "versionHistoryHM:"),
         item("巨大ファイル: 読み込む範囲を変える…", "changePartialRangeHM:"),
         item("巨大ファイル: 位置へ移動…", "jumpInHugeFileHM:"),
         sep(),
         item("印刷…", "printDocumentHM:", "p"),
         item("スクリーンショット (画像にする)…", "screenshotHM:"),
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
        let search = NSMenu(title: L("検索"))
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
        let searchHolder = holder("検索", search)
        main.addItem(searchHolder)

        let view = submenu("表示", in: main, [
            item("折り返し", "toggleWrapHM:"),
            item("改行・タブ・空白の記号を表示", "toggleInvisiblesHM:"),
            item("行番号を表示", "toggleLineNumbersHM:"),
            item("桁ルーラーを表示", "toggleColumnRulerHM:"),
            item("テキスト一覧", "toggleTextLibraryHM:", "l", [.command, .shift]),
            item("テキストをサムネで一覧", "showLibraryGridHM:", "l", [.command, .shift, .option]),
            item("テキスト管理の設定…", "openLibraryPrefsHM:"),
            item("フォルダツリー", "toggleFolderTreeHM:", "e", [.command, .shift]),
            item("差分 (編集前との違い) を表示", "toggleDiffHM:", "d", [.command, .shift]),
            sep(),
            item("上下に分割", "toggleSplitHM:", "s", [.command, .control]),
            item("左右に分割", "toggleSplitSideHM:", "s", [.command, .control, .option]),
            item("分割したもう一方へ移動", "switchSplitPaneHM:", "\u{F709}", []),
            sep(),
            item("前のタブ", "selectPreviousTab:", "{", [.command, .shift]),
            item("次のタブ", "selectNextTab:", "}", [.command, .shift]),
            item("すべてのタブを表示", "toggleTabOverview:", "\\", [.command, .shift]),
        ])
        let paper = NSMenu(title: L("用紙"))
        paper.addItem(item("標準エディタ", "setPaperModeHM:", tag: 0, id: "通常")) // キー割り当ては前の名前「通常」で覚えている
        paper.addItem(item("原稿用紙 (縦書き 400 字詰め)", "setPaperModeHM:", tag: 1))
        paper.addItem(item("原稿用紙 (横書き 400 字詰め)", "setPaperModeHM:", tag: 3))
        paper.addItem(item("A4 用紙 (横書き 40 字 × 36 行)", "setPaperModeHM:", tag: 2))
        paper.addItem(sep())
        paper.addItem(item("保存のとき、見たままの PDF も一緒に作る", "togglePaperAutoFormatHM:", object: "paperSavePDF"))
        paper.addItem(sep())
        paper.addItem(item("原稿用紙: 自動整形 (題名 3 マス下げ・名前 下寄せ・段落 1 マス下げ)", "togglePaperAutoFormatHM:", object: "genkoAutoFormat"))
        paper.addItem(item("原稿用紙: 改行のたび全角スペースを入れる (自動整形オフのとき)", "toggleGenkoAssistHM:", object: "genkoAutoIndent"))
        paper.addItem(item("原稿用紙: 半角の英数字を全角にする", "toggleGenkoAssistHM:", object: "genkoFullWidth"))
        paper.addItem(item("原稿用紙: 漢字にふりがなを付ける (自動)", "togglePaperAutoFormatHM:", object: "genkoFurigana"))
        paper.addItem(sep())
        paper.addItem(item("A4: 自動整形 (題名 中央・名前 右寄せ・段落 1 字下げ)", "togglePaperAutoFormatHM:", object: "a4AutoFormat"))
        paper.addItem(item("A4 段落: 自動", "setParagraphAlignHM:", tag: 0))
        paper.addItem(item("A4 段落: 左寄せ", "setParagraphAlignHM:", "{", [.command, .control], tag: 1))
        paper.addItem(item("A4 段落: 中央寄せ", "setParagraphAlignHM:", "|", [.command, .control], tag: 2))
        paper.addItem(item("A4 段落: 右寄せ", "setParagraphAlignHM:", "}", [.command, .control], tag: 3))
        paper.addItem(sep())
        paper.addItem(item("用紙モードの設定…", "openPaperSettingsHM:"))
        let paperHolder = holder("用紙", paper)
        let counting = NSMenu(title: L("行の数え方"))
        counting.addItem(item("エディタ的 (改行ごとに 1 行)", "setLineCountingHM:", object: "logical"))
        counting.addItem(item("ワープロ的 (折り返しも 1 行)", "setLineCountingHM:", object: "visual"))
        let countingHolder = holder("行の数え方", counting)
        view.insertItem(countingHolder, at: 4)

        // 「設定」メニュー (秀丸の「その他」にあたる)。文字コード・言語・テーマもここにまとめる
        let settings = NSMenu(title: L("設定"))
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
            item($0.displayNameKey, "setSaveEncodingHM:", object: $0.rawValue)
        })
        submenu("文字コードを指定して開き直す", in: settings, TextEncoding.allCases.map {
            item($0.displayNameKey, "reopenWithEncodingHM:", object: $0.rawValue)
        })
        submenu("改行コード", in: settings, LineEnding.allCases.map {
            item($0.displayName, "setLineEndingHM:", object: $0.rawValue)
        })
        settings.addItem(sep())
        // 画面に出す言葉 (日本語 / 英語)。どちらの言葉でも見つけられるように、見出しは両方の言葉で書く
        submenu("表示の言語 (Language)", in: settings, [
            item("自動 (macOS の言語に合わせる)", "setDisplayLanguageHM:", object: "auto"),
            item("日本語", "setDisplayLanguageHM:", object: "ja"),
            item("English", "setDisplayLanguageHM:", object: "en"),
        ])
        let language = submenu("言語 (このファイル)", in: settings, [])
        language.delegate = LanguageMenuDelegate.shared
        submenu("テーマ", in: settings, Theme.presets.map {
            item($0.name, "selectThemePresetHM:", object: $0.name)
        })
        let settingsHolder = holder("設定", settings)
        main.addItem(settingsHolder)

        var aiItems = [
            item("AI アシスタントを表示 / 隠す", "toggleAIHM:", "a", [.command, .shift]),
            sep(),
        ]
        for (i, a) in AIPanel.Action.allCases.enumerated() {
            aiItems.append(item(a.titleKey, "aiActionHM:", tag: i))
        }
        aiItems += [sep(), item("利用状況と料金…", "openAIUsageHM:"), item("AI の設定…", "openAISettingsHM:"),
                    item("ローカルLLM簡単設定…", "openLocalAIHM:")]
        submenu("AI", in: main, aiItems)

        main.addItem(paperHolder)

        submenu("音声", in: main, [
            item("読み上げる / 止める (選んだところ・なければカーソルから)", "readAloudHM:", "r", [.command, .option]),
            item("読み上げを止める", "stopReadingHM:"),
            sep(),
            item("声で入力 (始める / 止める)", "toggleDictationHM:"), // ⌥⌘D は Dock の表示切り替えなので付けない
            sep(),
            item("読み上げ・音声入力の設定…", "openSpeechSettingsHM:"),
        ])

        submenu("サーバ", in: main, [
            item("サーバにつなぐ (SFTP / FTP)…", "openServersHM:", "o", [.command, .control]),
            item("編集をすぐサーバに反映する", "toggleRemoteAutoUploadHM:"),
            item("サーバツリーをエディタの横に出す", "toggleRemoteTreeHM:", "e", [.command, .control]),
            sep(),
            item("サーバの設定…", "openServersHM:"),
        ])

        submenu("暗号化", in: main, [
            item("暗号化して保存…", "encryptDocumentHM:"),
            item("暗号化の方法を変える…", "changeEncryptionMethodHM:"),
            item("鍵の変更…", "changeEncryptionKeyHM:"),
            item("暗号化を解除…", "decryptDocumentHM:"),
            sep(),
            item("この文書の暗号化の設定…", "openEncryptionSettingsHM:"),
            sep(),
            item("いつも暗号化して保存する", "toggleEncryptAlwaysHM:"),
            sep(),
            item("データ暗号化の設定…", "openEncryptionPrefsHM:"),
        ])

        // 公開: リンクで公開 (docs.satoru.net) にかかわるものは、ここにまとめる
        submenu("公開", in: main, [
            item("リンクで公開共有…", "shareLinkHM:", "u", [.command, .option]),
            item("公開中のページを更新（変更を反映）", "updatePublishedHM:"),
            item("公開の設定…", "publishSettingsHM:"),
            sep(),
            item("公開中ページ表示", "openPublishedHM:"),
            item("公開中のリンクをコピー", "copyPublishedLinkHM:"),
            item("公開をやめる…", "unpublishCurrentHM:"),
            sep(),
            item("公開したリンク…", "showSharedLinksHM:"),
            sep(),
            item("公開する前に個人情報を確認する", "togglePrivacyCheckHM:"),
            sep(),
            item("リンクで公開共有の設定…", "openPublishPrefsHM:"),
        ])

        // 共同編集は見えなくしているので、メニューも作らない (キー割り当て・メニュー編集の一覧にも出ない)
        if !EditorExtension.hidden.contains(.collab) {
            submenu("共有", in: main, [
                item("この文書を共有する…", "startShareHM:"),
                item("共有に参加…", "joinShareHM:"),
                sep(),
                item("チャットを表示 / 隠す", "toggleChatHM:"),
                item("共有を終了 / 抜ける", "stopShareHM:"),
            ])
        }

        // 窓割り: ちがうタブの文書を 1 つのウインドウに並べる (Mado*.swift)
        let madoMenu = NSMenu(title: L("窓割り"))
        let arrowRight = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        [item("タブを左右に並べる", "madoSplitTabsSideBySideHM:", arrowRight, [.command, .control]),
         item("タブを上下に並べる", "madoSplitTabsStackedHM:", arrowDown, [.command, .control]),
         item("この画面を左右に分割", "madoSplitPaneSideBySideHM:", arrowRight, [.command, .control, .option]),
         item("この画面を上下に分割", "madoSplitPaneStackedHM:", arrowDown, [.command, .control, .option]),
         item("並べるのをやめる (タブに戻す)", "madoUnsplitHM:", arrowUp, [.command, .control]),
         sep(),
         item("次の画面へ", "madoNextPaneHM:", "]", [.command, .control]),
         item("前の画面へ", "madoPreviousPaneHM:", "[", [.command, .control]),
         item("画面の大きさをそろえる", "madoEqualizeHM:"),
         sep(),
         item("このタブを選ぶ", "madoToggleMarkHM:"),
         item("選択をすべて外す", "madoClearMarksHM:"),
         sep(),
         item("このタブを新しいウインドウに分ける", "madoMoveToNewWindowHM:"),
        ].forEach { madoMenu.addItem($0) }
        let placeMenu = NSMenu(title: L("窓割り中に新しい文書を開く場所"))
        for (title, v) in [("毎回聞く", "ask"), ("窓内で開く", "split"), ("タブで開く", "tab"), ("新しいウインドウで開く", "window")] {
            placeMenu.addItem(item(title, "madoSetOpenPlaceHM:", object: v, id: "madoOpenPlace." + v))
        }
        madoMenu.addItem(sep())
        madoMenu.addItem(holder("窓割り中に新しい文書を開く場所", placeMenu))

        let window = submenu("ウインドウ", in: main, [
            item("しまう", "performMiniaturize:", "m"),
            item("拡大/縮小", "performZoom:"),
            sep(),
            item("ウインドウ上下分割", "toggleSplitHM:"),
            item("ウインドウ左右分割", "toggleSplitSideHM:"),
            item("分割したもう一方へ移動", "switchSplitPaneHM:"),
            sep(),
            holder("窓割り", madoMenu),
            sep(),
            item("ウインドウを左右に並べる", "tileWindowsSideBySideHM:"),
            item("ウインドウを上下に並べる", "tileWindowsStackedHM:"),
            item("タブにまとめる", "mergeAllWindows:"),
            sep(),
            item("すべてを手前に移動", "arrangeInFront:"),
        ])
        NSApp.windowsMenu = window
        // 「機能」: 拡張機能の ON / OFF をまとめたメニュー
        let features = NSMenu(title: L("追加機能"))
        for e in EditorExtension.displayOrder {
            features.addItem(item(e.titleKey, "toggleExtensionHM:", object: e.rawValue))
        }
        features.addItem(sep())
        features.addItem(item("追加機能を入れる・外す…", "openExtensionsSettingsHM:"))
        let featuresHolder = holder("追加機能", features)
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
        let i = NSMenuItem(title: L(title), action: nil, keyEquivalent: "")
        i.tag = sectionHeaderTag
        i.isEnabled = false
        i.attributedTitle = NSAttributedString(string: L(title), attributes: [
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
        menu.addItem(NSMenuItem(title: L("自動 (拡張子で判定)"), action: #selector(EditorWindowController.setLanguageHM(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        for p in Profiles.store.profiles {
            let i = NSMenuItem(title: L(p.name), action: #selector(EditorWindowController.setLanguageHM(_:)), keyEquivalent: "")
            i.representedObject = p.name
            menu.addItem(i)
        }
    }
}
