import Foundation

/// 共同編集の 1 回分の変更: loc から len 文字 (UTF-16) を text に置き換える
public struct TextOp: Codable, Equatable {
    public var loc: Int
    public var len: Int
    public var text: String

    public init(loc: Int, len: Int, text: String) {
        self.loc = loc
        self.len = len
        self.text = text
    }

    public static let noop = TextOp(loc: 0, len: 0, text: "")

    public var insertedLength: Int { (text as NSString).length }
    public var end: Int { loc + len }
    public var delta: Int { insertedLength - len }
    public var isNoop: Bool { len == 0 && text.isEmpty }

    func shifted(by d: Int) -> TextOp { TextOp(loc: loc + d, len: len, text: text) }

    public func apply(to s: NSMutableString) {
        let l = max(0, min(loc, s.length))
        s.replaceCharacters(in: NSRange(location: l, length: max(0, min(len, s.length - l))), with: text)
    }

    /// この変更のあと、位置 p はどこへ動くか (カーソル位置の追従用)
    public func transformPosition(_ p: Int) -> Int {
        if p <= loc { return p }
        if p >= end { return p + delta }
        return loc + insertedLength
    }
}

/// 同じ状態に対して同時に行われた 2 つの変更をすり合わせる (Operational Transformation)。
/// 結果 (a', b') は「b のあとに a'」「a のあとに b'」がどちらも同じ文章になる。
/// aWins: 同じ位置への挿入などで a を先 (左) にするか。
public enum OT {
    public static func transform(_ a: TextOp, _ b: TextOp, aWins: Bool) -> (TextOp, TextOp) {
        if a.isNoop || b.isNoop { return (a, b) }
        // 1. 同じ位置への挿入どうし
        if a.len == 0 && b.len == 0 && a.loc == b.loc {
            return aWins ? (a, b.shifted(by: a.insertedLength)) : (a.shifted(by: b.insertedLength), b)
        }
        // 2. a が b より前 (接しているのも含む)
        if a.end <= b.loc { return (a, b.shifted(by: a.delta)) }
        // 3. b が a より前
        if b.end <= a.loc { return (a.shifted(by: b.delta), b) }
        // ここから先は範囲が重なっている
        let identical = a.loc == b.loc && a.end == b.end
        // 4. a が b を含む (同じ範囲なら勝つほう)
        if a.loc <= b.loc && b.end <= a.end && (!identical || aWins) {
            return (TextOp(loc: a.loc, len: a.len + b.delta, text: a.text), .noop)
        }
        // 5. b が a を含む
        if b.loc <= a.loc && a.end <= b.end {
            return (.noop, TextOp(loc: b.loc, len: b.len + a.delta, text: b.text))
        }
        // 6. 一部が重なる (a が先に始まる)
        if a.loc < b.loc {
            return (TextOp(loc: a.loc, len: b.loc - a.loc, text: a.text),
                    TextOp(loc: a.loc + a.insertedLength, len: b.end - a.end, text: b.text))
        }
        // 7. 一部が重なる (b が先に始まる)
        return (TextOp(loc: b.loc + b.insertedLength, len: a.end - b.end, text: a.text),
                TextOp(loc: b.loc, len: a.loc - b.loc, text: b.text))
    }
}

/// 共有する側 (ホスト) の変更の記録。全員の変更はここで順番が決まる。
public final class OTServer {
    public private(set) var revision = 0
    private var history: [TextOp] = []

    public init() {}

    /// ホスト自身の変更 (すでに文章に反映済み)
    @discardableResult
    public func localEdit(_ op: TextOp) -> Int {
        history.append(op)
        revision += 1
        return revision
    }

    /// 参加者から届いた変更。baseRevision 以降の変更とすり合わせた結果を返す (これを文章に反映して全員に配る)
    public func receive(_ op: TextOp, baseRevision: Int) -> (op: TextOp, revision: Int) {
        var o = op
        let start = max(0, min(baseRevision, history.count))
        for h in history[start...] {
            o = OT.transform(o, h, aWins: false).0
        }
        history.append(o)
        revision += 1
        return (o, revision)
    }
}

/// 参加する側 (ゲスト) の状態。返事待ちの変更は 1 つだけ送り、残りはためておく。
public final class OTClient {
    public private(set) var revision: Int
    private var outstanding: TextOp?
    private var buffer: [TextOp] = []

    public init(revision: Int) {
        self.revision = revision
    }

    public var hasPending: Bool { outstanding != nil || !buffer.isEmpty }

    /// 自分の変更 (すでに文章に反映済み)。今すぐ送るべきものがあれば返す
    public func localEdit(_ op: TextOp) -> (op: TextOp, baseRevision: Int)? {
        if outstanding == nil {
            outstanding = op
            return (op, revision)
        }
        buffer.append(op)
        return nil
    }

    /// 自分の変更がホストに受け付けられた。次に送るものがあれば返す
    public func acknowledged(revision r: Int) -> (op: TextOp, baseRevision: Int)? {
        revision = r
        outstanding = nil
        guard !buffer.isEmpty else { return nil }
        let next = buffer.removeFirst()
        outstanding = next
        return (next, revision)
    }

    /// ほかの人の変更が届いた。自分の文章に反映すべき形にして返す
    public func remote(_ op: TextOp, revision r: Int) -> TextOp {
        revision = r
        var o = op
        if let out = outstanding {
            let (o2, out2) = OT.transform(o, out, aWins: true)
            o = o2
            outstanding = out2
        }
        for i in buffer.indices {
            let (o2, b2) = OT.transform(o, buffer[i], aWins: true)
            o = o2
            buffer[i] = b2
        }
        return o
    }
}
