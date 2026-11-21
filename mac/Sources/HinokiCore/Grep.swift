import Foundation

public struct GrepMatch: Equatable {
    public let url: URL
    /// 1 始まり
    public let line: Int
    public let text: String
}

public struct GrepOptions {
    public var pattern: String
    public var useRegex: Bool
    public var caseSensitive: Bool
    /// "*.swift;*.txt" のようなファイル名マスク。空なら全ファイル
    public var fileMask: String
    public var recursive: Bool
    public var maxResults: Int

    public init(pattern: String, useRegex: Bool = false, caseSensitive: Bool = false,
                fileMask: String = "*", recursive: Bool = true, maxResults: Int = 10_000) {
        self.pattern = pattern
        self.useRegex = useRegex
        self.caseSensitive = caseSensitive
        self.fileMask = fileMask
        self.recursive = recursive
        self.maxResults = maxResults
    }

    public func makeRegex() throws -> NSRegularExpression {
        var opts: NSRegularExpression.Options = [.anchorsMatchLines]
        if !caseSensitive { opts.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: useRegex ? pattern : NSRegularExpression.escapedPattern(for: pattern),
                                       options: opts)
    }

    var masks: [String] {
        let list = fileMask.split(whereSeparator: { $0 == ";" || $0 == "," || $0 == " " }).map(String.init)
        return list.isEmpty ? ["*"] : list
    }
}

public enum Grep {
    /// 飛ばすディレクトリ
    static let skippedDirectories: Set<String> = ["node_modules", ".build", "DerivedData", "Pods"]
    /// これより大きいファイルは読まない
    static let maxFileSize = 20 * 1024 * 1024

    public static func search(root: URL, options: GrepOptions,
                              isCancelled: () -> Bool = { false },
                              onMatch: (GrepMatch) -> Void) throws {
        let regex = try options.makeRegex()
        let masks = options.masks
        var count = 0

        for url in files(under: root, recursive: options.recursive) {
            if isCancelled() || count >= options.maxResults { return }
            guard masks.contains(where: { fnmatch($0, url.lastPathComponent, FNM_CASEFOLD) == 0 }) else { continue }
            guard let text = readText(url) else { continue }

            let ns = text as NSString
            let lines = LineIndex(ns).lineStarts
            for (k, lineStart) in lines.enumerated() {
                let lineEnd = k + 1 < lines.count ? lines[k + 1] - 1 : ns.length
                let lineRange = NSRange(location: lineStart, length: max(0, lineEnd - lineStart))
                if regex.firstMatch(in: text, options: [.withTransparentBounds], range: lineRange) != nil {
                    onMatch(GrepMatch(url: url, line: k + 1, text: ns.substring(with: lineRange)))
                    count += 1
                    if count >= options.maxResults || isCancelled() { return }
                }
            }
        }
    }

    static func files(under root: URL, recursive: Bool) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        var result: [URL] = []
        if !recursive {
            let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            for u in items where (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                result.append(u)
            }
            return result.sorted { $0.path < $1.path }
        }
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        for case let u as URL in e {
            let values = try? u.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if skippedDirectories.contains(u.lastPathComponent) { e.skipDescendants() }
                continue
            }
            if values?.isRegularFile == true && (values?.fileSize ?? 0) <= maxFileSize {
                result.append(u)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    /// バイナリっぽいファイルは nil
    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let head = data.prefix(8192)
        let isUTF16 = head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF])
        if !isUTF16 && head.contains(0) { return nil }
        return try? TextCodec.decode(data).text
    }
}
