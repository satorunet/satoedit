import Foundation

/// エディタが扱う文字コード。
public enum TextEncoding: String, CaseIterable {
    case utf8, utf8BOM, shiftJIS, eucJP, iso2022JP, utf16LE, utf16BE

    /// 画面に出す名前
    public var displayName: String { L(displayNameKey) }

    /// 日本語の名前 (メニューの項目を覚えておく名前にも使う)
    public var displayNameKey: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8 (BOM付)"
        case .shiftJIS: return "Shift_JIS"
        case .eucJP: return "EUC-JP"
        case .iso2022JP: return "JIS"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        }
    }

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: return .utf8
        // Windows由来のファイルを扱うので CP932 (機種依存文字を含む Shift_JIS) を使う
        case .shiftJIS:
            let cf = CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        case .eucJP: return .japaneseEUC
        case .iso2022JP: return .iso2022JP
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        }
    }

    public var bomBytes: [UInt8] { bom }

    var bom: [UInt8] {
        switch self {
        case .utf8BOM: return [0xEF, 0xBB, 0xBF]
        case .utf16LE: return [0xFF, 0xFE]
        case .utf16BE: return [0xFE, 0xFF]
        default: return []
        }
    }
}

public enum LineEnding: String, CaseIterable {
    case lf, crlf, cr

    public var displayName: String {
        switch self {
        case .lf: return "LF"
        case .crlf: return "CRLF"
        case .cr: return "CR"
        }
    }

    public var string: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }
}

public struct DecodedText: Equatable {
    /// 改行は LF に正規化済み
    public var text: String
    public var encoding: TextEncoding
    public var lineEnding: LineEnding

    public init(text: String, encoding: TextEncoding, lineEnding: LineEnding) {
        self.text = text
        self.encoding = encoding
        self.lineEnding = lineEnding
    }
}

public enum TextCodecError: LocalizedError {
    case cannotDecode(TextEncoding)
    case cannotEncode(TextEncoding)

    public var errorDescription: String? {
        switch self {
        case .cannotDecode(let e): return L("{0} として読み込めませんでした。", e.displayName)
        case .cannotEncode(let e): return L("{0} では保存できない文字が含まれています。", e.displayName)
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .cannotDecode: return L("別の文字コードを指定して開き直してください。")
        case .cannotEncode: return L("書式 > 文字コード で UTF-8 などに変更してから保存してください。")
        }
    }
}

public enum TextCodec {

    // MARK: 判別

    public static func detectEncoding(_ whole: Data) -> TextEncoding {
        // 巨大なファイルは先頭の 4 MB (最後の改行まで) だけで見分ける。外れても decode が別の文字コードを試す
        var data = whole
        let sample = 4 << 20
        if whole.count > sample {
            let head = whole.prefix(sample)
            data = head.lastIndex(of: 0x0A).map { head[head.startIndex...$0] } ?? head
        }
        let bytes = [UInt8](data)
        if bytes.starts(with: TextEncoding.utf8BOM.bom) { return .utf8BOM }
        if bytes.starts(with: TextEncoding.utf16LE.bom) { return .utf16LE }
        if bytes.starts(with: TextEncoding.utf16BE.bom) { return .utf16BE }

        let isASCII = !bytes.contains { $0 >= 0x80 }
        if isASCII {
            return containsJISEscape(bytes) ? .iso2022JP : .utf8
        }
        if String(data: data, encoding: .utf8) != nil { return .utf8 }

        let sjisOK = isValidShiftJIS(bytes)
        let eucOK = isValidEUCJP(bytes)
        switch (sjisOK, eucOK) {
        case (true, false): return .shiftJIS
        case (false, true): return .eucJP
        // 普通の Shift_JIS は 0x81-0x9F の先行バイトを含むので EUC としては不正になる。
        // 両方通るなら EUC-JP の可能性が高い。
        case (true, true): return .eucJP
        case (false, false): return .shiftJIS
        }
    }

    static func containsJISEscape(_ b: [UInt8]) -> Bool {
        guard b.count >= 3 else { return false }
        for i in 0..<(b.count - 2) where b[i] == 0x1B {
            if (b[i + 1] == 0x24 && (b[i + 2] == 0x42 || b[i + 2] == 0x40)) || (b[i + 1] == 0x28 && b[i + 2] == 0x4A) {
                return true
            }
        }
        return false
    }

    static func isValidShiftJIS(_ b: [UInt8]) -> Bool {
        var i = 0
        while i < b.count {
            let c = b[i]
            if c < 0x80 || (0xA1...0xDF).contains(c) {
                i += 1
            } else if (0x81...0x9F).contains(c) || (0xE0...0xFC).contains(c) {
                guard i + 1 < b.count else { return false }
                let t = b[i + 1]
                guard (0x40...0x7E).contains(t) || (0x80...0xFC).contains(t) else { return false }
                i += 2
            } else {
                return false
            }
        }
        return true
    }

    static func isValidEUCJP(_ b: [UInt8]) -> Bool {
        var i = 0
        while i < b.count {
            let c = b[i]
            if c < 0x80 {
                i += 1
            } else if c == 0x8E {
                guard i + 1 < b.count, (0xA1...0xDF).contains(b[i + 1]) else { return false }
                i += 2
            } else if c == 0x8F {
                guard i + 2 < b.count, (0xA1...0xFE).contains(b[i + 1]), (0xA1...0xFE).contains(b[i + 2]) else { return false }
                i += 3
            } else if (0xA1...0xFE).contains(c) {
                guard i + 1 < b.count, (0xA1...0xFE).contains(b[i + 1]) else { return false }
                i += 2
            } else {
                return false
            }
        }
        return true
    }

    public static func detectLineEnding(_ s: String) -> LineEnding {
        let ns = s as NSString
        if ns.range(of: "\r\n").location != NSNotFound { return .crlf }
        if ns.range(of: "\r").location != NSNotFound { return .cr }
        return .lf
    }

    public static func normalizeLineEndings(_ s: String) -> String {
        let ns = s as NSString
        guard ns.range(of: "\r").location != NSNotFound else { return s }
        return ns.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: 読み書き

    /// `encoding` が nil なら自動判別する。
    public static func decode(_ data: Data, as encoding: TextEncoding? = nil) throws -> DecodedText {
        if let encoding = encoding {
            guard let raw = decodeRaw(data, encoding) else { throw TextCodecError.cannotDecode(encoding) }
            return DecodedText(text: normalizeLineEndings(raw), encoding: encoding, lineEnding: detectLineEnding(raw))
        }
        let guess = detectEncoding(data)
        let candidates = [guess] + [.utf8, .shiftJIS, .eucJP].filter { $0 != guess }
        for e in candidates {
            if let raw = decodeRaw(data, e) {
                return DecodedText(text: normalizeLineEndings(raw), encoding: e, lineEnding: detectLineEnding(raw))
            }
        }
        // 最後の手段: 壊れたバイトを置換文字にして UTF-8 として開く
        let raw = String(decoding: data, as: UTF8.self)
        return DecodedText(text: normalizeLineEndings(raw), encoding: .utf8, lineEnding: detectLineEnding(raw))
    }

    static func decodeRaw(_ data: Data, _ encoding: TextEncoding) -> String? {
        var body = data
        let bom = encoding.bom
        if !bom.isEmpty && data.starts(with: bom) {
            body = Data(data.dropFirst(bom.count))
        }
        return String(data: body, encoding: encoding.stringEncoding)
    }

    /// `text` は LF 改行である前提。
    public static func encode(_ text: String, encoding: TextEncoding, lineEnding: LineEnding) throws -> Data {
        let converted = lineEnding == .lf ? text : (text as NSString).replacingOccurrences(of: "\n", with: lineEnding.string)
        guard let body = converted.data(using: encoding.stringEncoding, allowLossyConversion: false) else {
            throw TextCodecError.cannotEncode(encoding)
        }
        return Data(encoding.bom) + body
    }
}
