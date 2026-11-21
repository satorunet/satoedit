import AppKit
import HinokiCore

extension Notification.Name {
    static let themeDidChange = Notification.Name("SatomaruThemeDidChange")
}

/// 色とフォント。
/// プリセット (ダーク・ライト・暖色・ピンク…) を選び、そのうえで項目ごとに上書きできる。
/// 設定は ~/.satomaru/theme.json に保存され、手で書き換えてもよい。
enum Theme {
    /// (キー, 説明) — 画面と theme.json はこの順で並べる
    static let entries: [(key: String, label: String)] = [
        ("background", "本文の背景"),
        ("text", "普通の文字"),
        ("caret", "カーソル (キャレット)"),
        ("selection", "選択範囲の背景"),
        ("currentLine", "カーソル行の背景"),
        ("gutterBackground", "行番号の背景"),
        ("gutterText", "行番号"),
        ("gutterCurrentText", "カーソル行の行番号"),
        ("gutterSeparator", "行番号と本文の区切り線"),
        ("statusBackground", "ステータスバーの背景 (*)"),
        ("statusText", "ステータスバーの文字 (*)"),
        ("newlineMark", "改行マーク ↓"),
        ("invisible", "タブ・全角空白の記号"),
        ("eof", "[EOF]"),
        ("keyword", "キーワード"),
        ("type", "型名"),
        ("string", "文字列"),
        ("comment", "コメント"),
        ("number", "数値"),
        ("tag", "HTML タグ・grep のファイル名"),
        ("link", "URL・メールアドレス (リンク)"),
    ]

    struct Preset {
        let name: String
        let colors: [String: String]
    }

    /// 並び順: background text caret selection currentLine gutterBackground gutterText gutterCurrentText
    /// gutterSeparator statusBackground statusText newlineMark invisible eof keyword type string comment number tag
    private static func preset(_ name: String, _ hexes: [String]) -> Preset {
        precondition(hexes.count == entries.count, "preset \(name) の色の数が違う")
        var dict: [String: String] = [:]
        for (e, h) in zip(entries, hexes) { dict[e.key] = h }
        return Preset(name: name, colors: dict)
    }

    static let presets: [Preset] = [
        // 秀丸エディタ公式サイトのダークモードのスクリーンショットから拾った色 (選択・構文色などは独自)
        preset("ダーク", [
            "#2B2B2B", "#E5E5E5", "#E5E5E5", "#2F5A8A", "#FFFFFF0B", "#2B2B2B", "#E5E5E5", "#FFFFFF",
            "#484848", "#484848", "#E5E5E5", "#31E3E5", "#828282", "#31E3E5",
            "#C792EA", "#E5C07B", "#E8483F", "#7F8C8D", "#F78C6C", "#61AFEF", "#6CB6FF"]),
        preset("ライト", [
            "#FFFFFF", "#1E1E1E", "#000000", "#B4D5FE", "#0000000A", "#F3F3F3", "#8A8A8A", "#1E1E1E",
            "#DDDDDD", "#E8E8E8", "#333333", "#2A9FB0", "#BBBBBB", "#2A9FB0",
            "#0033B3", "#7A3E9D", "#C41A16", "#6A8A6A", "#1750EB", "#0B7A75", "#0B57D0"]),
        preset("暖色ダーク", [
            "#2A211C", "#EBDBC2", "#F5C26B", "#5C4632", "#FFE0B014", "#241C18", "#8C7A66", "#F5C26B",
            "#4A3B30", "#3A2E26", "#EBDBC2", "#D9A05B", "#6E5E50", "#D9A05B",
            "#F28C5B", "#E8C267", "#A9C46C", "#8C7A66", "#E39B7B", "#E0A96D", "#7FB8E6"]),
        preset("和紙 (暖色ライト)", [
            "#F7F1E3", "#3B3127", "#8B4513", "#E8D5B0", "#8B451310", "#EFE6D2", "#A8957A", "#5C4033",
            "#DCCEB0", "#E6DAC0", "#3B3127", "#B0803C", "#C8B89A", "#B0803C",
            "#A0522D", "#6B5B95", "#B03A2E", "#8A9A6B", "#C0662D", "#2E6E8E", "#1A5FB4"]),
        preset("さくら (ピンク)", [
            "#FFF0F5", "#4A2C3A", "#E0457B", "#FFC2D9", "#E0457B12", "#FCE4EE", "#C08AA2", "#E0457B",
            "#F3C6D8", "#F8D3E2", "#4A2C3A", "#E07BA5", "#D9AFC2", "#E07BA5",
            "#C2185B", "#8E44AD", "#D35400", "#A88799", "#E91E63", "#AD1457", "#2F6FD0"]),
        preset("ピンクダーク", [
            "#2B1F28", "#F2DDE8", "#FF7EB6", "#6B3555", "#FF7EB612", "#261B23", "#9C7A8E", "#FF7EB6",
            "#4A3343", "#3D2A37", "#F2DDE8", "#FF7EB6", "#7A5C6E", "#FF7EB6",
            "#FF79C6", "#FFB3D9", "#FFD27F", "#9C7A8E", "#FF9E9E", "#D7A6FF", "#8FC1FF"]),
        preset("ミッドナイト (青)", [
            "#14192B", "#D6DEEB", "#7FDBFF", "#26407A", "#FFFFFF0A", "#111526", "#5A6788", "#D6DEEB",
            "#2A3250", "#1E2540", "#C0CAE0", "#4FA3D9", "#3E4A6B", "#4FA3D9",
            "#82AAFF", "#7FDBCA", "#ECC48D", "#637777", "#F78C6C", "#7FDBFF", "#9CC4FF"]),
        preset("黒板 (緑)", [
            "#1F2B24", "#E6EDE3", "#FFFFFF", "#3D5A47", "#FFFFFF0A", "#1A251F", "#7D9184", "#FFFFFF",
            "#34453A", "#2A3A30", "#E6EDE3", "#F2E394", "#5E7266", "#F2E394",
            "#F2E394", "#9FD3F0", "#F5A9A9", "#8FA897", "#FFC48C", "#9FD3F0", "#A8D8FF"]),
    ]

    static let defaultFontName = "Osaka-Mono"
    static let defaultFontSize: CGFloat = 14

    static var userFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".satomaru/theme.json")
    }

    // MARK: 状態

    private static var loaded = false
    private(set) static var presetName = presets[0].name
    /// プリセットから変えた色 (キー → #RRGGBB / #RRGGBBAA)
    private(set) static var overrides: [String: String] = [:]
    private(set) static var fontName = defaultFontName
    private(set) static var fontSize = defaultFontSize
    private(set) static var loadError: String?

    private static var colors: [String: NSColor] = [:]
    private static var cachedFont: NSFont?

    static var currentPreset: Preset {
        presets.first { $0.name == presetName } ?? presets[0]
    }

    /// ウインドウ枠・タブバー・メニュー・ダイアログの見た目
    static let windowStyles: [(key: String, label: String)] = [
        ("gray", "灰色"),
        ("theme", "テーマに合わせる"),
        ("system", "macOS の設定に合わせる"),
    ]
    private(set) static var windowStyle = "gray"

    static func setWindowStyle(_ key: String) {
        ensureLoaded()
        windowStyle = key
        changed()
    }

    static var isDarkBackground: Bool {
        let bg = background.usingColorSpace(.sRGB) ?? background
        return 0.2126 * bg.redComponent + 0.7152 * bg.greenComponent + 0.0722 * bg.blueComponent < 0.5
    }

    static var appearance: NSAppearance? {
        switch windowStyle {
        case "system": return nil
        case "theme": break
        default: return NSAppearance(named: .aqua)
        }
        // 背景が暗ければダーク、明るければライト
        let bg = background.usingColorSpace(.sRGB) ?? background
        let luminance = 0.2126 * bg.redComponent + 0.7152 * bg.greenComponent + 0.0722 * bg.blueComponent
        return NSAppearance(named: luminance < 0.5 ? .darkAqua : .aqua)
    }

    static var font: NSFont {
        ensureLoaded()
        return cachedFont ?? .monospacedSystemFont(ofSize: defaultFontSize, weight: .regular)
    }

    static var background: NSColor { c("background") }
    static var text: NSColor { c("text") }
    static var caret: NSColor { c("caret") }
    static var selection: NSColor { c("selection") }
    static var currentLine: NSColor { c("currentLine") }
    static var gutterBackground: NSColor { c("gutterBackground") }
    static var gutterText: NSColor { c("gutterText") }
    static var gutterCurrentText: NSColor { c("gutterCurrentText") }
    static var gutterSeparator: NSColor { c("gutterSeparator") }
    static var statusBackground: NSColor { c("statusBackground") }
    static var statusText: NSColor { c("statusText") }
    static var newlineMark: NSColor { c("newlineMark") }
    static var invisible: NSColor { c("invisible") }
    static var eof: NSColor { c("eof") }
    static var keyword: NSColor { c("keyword") }
    static var type: NSColor { c("type") }
    static var string: NSColor { c("string") }
    static var comment: NSColor { c("comment") }
    static var number: NSColor { c("number") }
    static var tag: NSColor { c("tag") }
    static var link: NSColor { c("link") }

    /// ステータスバー (フッター) の色。ウインドウ枠が「灰色」「macOS」のときは、
    /// 個別に色を変えていない限りヘッダーと同じウインドウ枠の色にそろえる
    private static var footerFollowsChrome: Bool { windowStyle != "theme" }
    static var footerBackground: NSColor {
        footerFollowsChrome && overrides["statusBackground"] == nil ? .windowBackgroundColor : statusBackground
    }
    static var footerText: NSColor {
        footerFollowsChrome && overrides["statusText"] == nil ? .labelColor : statusText
    }
    static var footerSeparator: NSColor {
        footerFollowsChrome && overrides["statusBackground"] == nil ? .separatorColor : gutterSeparator
    }

    static func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .keyword: return keyword
        case .type: return type
        case .string: return string
        case .comment: return comment
        case .number: return number
        case .tag: return tag
        }
    }

    static func color(forKey key: String) -> NSColor { c(key) }

    private static func c(_ key: String) -> NSColor {
        ensureLoaded()
        return colors[key] ?? .magenta
    }

    private static func ensureLoaded() {
        if !loaded { load() }
    }

    private static func rebuild() {
        var result: [String: NSColor] = [:]
        for (key, hex) in currentPreset.colors { result[key] = parse(hex: hex) }
        for (key, hex) in overrides { result[key] = parse(hex: hex) }
        colors = result
        cachedFont = NSFont(name: fontName, size: fontSize)
            ?? NSFont(name: defaultFontName, size: fontSize)
            ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        NSApp?.appearance = appearance
    }

    // MARK: 色の変換

    static func parse(hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let rgba = s.count == 6 ? (v << 8) | 0xFF : v
        return NSColor(srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255,
                       green: CGFloat((rgba >> 16) & 0xFF) / 255,
                       blue: CGFloat((rgba >> 8) & 0xFF) / 255,
                       alpha: CGFloat(rgba & 0xFF) / 255)
    }

    static func hex(of color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        var s = String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
        if byte(c.alphaComponent) < 255 { s += String(format: "%02X", byte(c.alphaComponent)) }
        return s
    }

    private static func normalized(_ hex: String) -> String? {
        parse(hex: hex).map { self.hex(of: $0) }
    }

    // MARK: 画面からの変更

    /// プリセットを切り替える (個別に変えた色は消える)
    static func selectPreset(_ name: String) {
        ensureLoaded()
        presetName = name
        overrides = [:]
        changed()
    }

    /// 1 項目の色を変える。プリセットと同じ色ならカスタム扱いをやめる
    static func setColor(_ color: NSColor, forKey key: String) {
        ensureLoaded()
        let h = hex(of: color)
        if let base = currentPreset.colors[key], normalized(base) == h {
            overrides.removeValue(forKey: key)
        } else {
            overrides[key] = h
        }
        changed()
    }

    static func resetColor(forKey key: String) {
        ensureLoaded()
        overrides.removeValue(forKey: key)
        changed()
    }

    static func resetAllColors() {
        ensureLoaded()
        overrides = [:]
        changed()
    }

    static func setFont(_ font: NSFont) {
        ensureLoaded()
        fontName = font.fontName
        fontSize = min(max(font.pointSize, 6), 72)
        changed()
    }

    private static var saveWork: DispatchWorkItem?

    private static func changed() {
        rebuild()
        NotificationCenter.default.post(name: .themeDidChange, object: nil)
        // カラーパネルをドラッグ中は何度も呼ばれるので、書き込みは少し待ってまとめる
        saveWork?.cancel()
        let work = DispatchWorkItem { save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: 読み込み・保存

    static func load() {
        loaded = true
        presetName = presets[0].name
        overrides = [:]
        fontName = defaultFontName
        fontSize = defaultFontSize
        windowStyle = "gray"
        var problems: [String] = []

        if let data = try? Data(contentsOf: userFileURL) {
            do {
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw NSError(domain: "Satomaru", code: 1, userInfo: [NSLocalizedDescriptionKey: "一番外側が { } ではありません"])
                }
                if var p = root["preset"] as? String {
                    if p == "秀丸ダーク" { p = "ダーク" } // 旧名
                    if presets.contains(where: { $0.name == p }) {
                        presetName = p
                    } else {
                        problems.append("知らないプリセット: \(p) (使えるもの: \(presets.map { $0.name }.joined(separator: " / ")))")
                    }
                }
                if let w = root["windowStyle"] as? String {
                    if windowStyles.contains(where: { $0.key == w }) {
                        windowStyle = w
                    } else {
                        problems.append("windowStyle は gray / theme / system のどれかにしてください")
                    }
                }
                if let f = root["font"] as? [String: Any] {
                    if let n = f["name"] as? String, !n.isEmpty { fontName = n }
                    if let sz = f["size"] as? Double, sz >= 6, sz <= 72 { fontSize = CGFloat(sz) }
                }
                let base = currentPreset.colors
                for (key, value) in root["colors"] as? [String: Any] ?? [:] {
                    guard let baseHex = base[key] else { problems.append("知らない項目: \(key)"); continue }
                    guard let s = value as? String, let h = normalized(s) else {
                        problems.append("\(key) の色が読めません (#RRGGBB か #RRGGBBAA で書いてください)")
                        continue
                    }
                    // プリセットと同じ色は上書き扱いにしない
                    if h != normalized(baseHex) { overrides[key] = h }
                }
                if NSFont(name: fontName, size: fontSize) == nil {
                    problems.append("フォント \"\(fontName)\" が見つかりません")
                }
            } catch {
                problems.append("JSON として読めません: \(error.localizedDescription)")
            }
        }
        loadError = problems.isEmpty ? nil : problems.joined(separator: "\n")
        rebuild()
    }

    /// theme.json を手で書き換えて保存したとき
    static func reload() {
        saveWork?.cancel()
        load()
        if let err = loadError {
            let alert = NSAlert()
            alert.messageText = "theme.json に問題があります (その項目は既定値を使います)"
            alert.informativeText = err
            alert.runModal()
        }
        NotificationCenter.default.post(name: .themeDidChange, object: nil)
    }

    private static func jsonString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s], options: [])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    /// 今の設定を theme.json の形にする (説明つき)
    static func fileContents() -> String {
        ensureLoaded()
        let width = entries.map { $0.key.count }.max() ?? 0
        var lines: [String] = []
        lines.append("{")
        lines.append("  \"_説明\": \"preset で土台を選び、colors に書いた項目だけ上書きします。色は #RRGGBB (透明度つきは #RRGGBBAA)。保存するとすぐ反映されます。\",")
        lines.append("  \"_使えるpreset\": [" + presets.map { jsonString($0.name) }.joined(separator: ", ") + "],")
        lines.append("  \"preset\": \(jsonString(presetName)),")
        lines.append("  \"windowStyle\": \(jsonString(windowStyle)),")
        lines.append("  \"_windowStyleの意味\": \"ウインドウ枠・タブ・メニューの色。gray = 灰色、theme = テーマに合わせる、system = macOS に合わせる。(*) の項目は gray / system のとき、colors に書かない限り枠と同じ色になります\",")
        lines.append("  \"font\": { \"name\": \(jsonString(fontName)), \"size\": \(fontSize == fontSize.rounded() ? String(Int(fontSize)) : String(Double(fontSize))) },")
        let custom = entries.filter { overrides[$0.key] != nil }
        if custom.isEmpty {
            lines.append("  \"colors\": {},")
        } else {
            lines.append("  \"colors\": {")
            for (i, e) in custom.enumerated() {
                let pad = String(repeating: " ", count: width - e.key.count)
                lines.append("    \"\(e.key)\": \(pad)\"\(overrides[e.key]!)\"" + (i == custom.count - 1 ? "" : ","))
            }
            lines.append("  },")
        }
        lines.append("  \"_項目の意味\": {")
        for (i, e) in entries.enumerated() {
            lines.append("    \"\(e.key)\": \(jsonString(e.label))" + (i == entries.count - 1 ? "" : ","))
        }
        lines.append("  }")
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    static func save() {
        saveWork = nil
        let url = userFileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileContents().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSApp.presentError(error)
        }
    }

    /// ~/.satomaru/theme.json を (無ければ今の設定で作って) エディタで開く
    static func openUserFile() {
        if let work = saveWork { work.cancel(); save() }
        if !FileManager.default.fileExists(atPath: userFileURL.path) { save() }
        NSDocumentController.shared.openDocument(withContentsOf: userFileURL, display: true) { _, _, error in
            if let error = error { NSApp.presentError(error) }
        }
    }
}
