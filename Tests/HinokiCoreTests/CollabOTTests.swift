import XCTest
@testable import HinokiCore

final class CollabOTTests: XCTestCase {
    private struct RNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private func randomOp(for s: String, _ rng: inout RNG) -> TextOp {
        let n = (s as NSString).length
        let loc = Int.random(in: 0...n, using: &rng)
        let len = Int.random(in: 0...min(4, n - loc), using: &rng)
        let pool = ["a", "b", "あ", "\n", "xy", "", "😀"]
        let text = pool[Int.random(in: 0..<pool.count, using: &rng)]
        return TextOp(loc: loc, len: len, text: text)
    }

    private func applied(_ s: String, _ ops: TextOp...) -> String {
        let m = NSMutableString(string: s)
        ops.forEach { $0.apply(to: m) }
        return m as String
    }

    /// 2 つの同時変更をすり合わせると、どちらの順でも同じ文章になる
    func testTransformConverges() {
        var rng = RNG(state: 42)
        for _ in 0..<20000 {
            let base = ["", "abc", "あいうえお\nかきくけこ", "0123456789"][Int.random(in: 0..<4, using: &rng)]
            let a = randomOp(for: base, &rng)
            let b = randomOp(for: base, &rng)
            for aWins in [true, false] {
                let (a2, b2) = OT.transform(a, b, aWins: aWins)
                XCTAssertEqual(applied(base, a, b2), applied(base, b, a2), "base=\(base) a=\(a) b=\(b) aWins=\(aWins)")
            }
        }
    }

    func testSimpleConcurrentInsert() {
        let (a2, b2) = OT.transform(TextOp(loc: 1, len: 0, text: "X"), TextOp(loc: 3, len: 0, text: "Y"), aWins: true)
        XCTAssertEqual(applied("abcd", TextOp(loc: 1, len: 0, text: "X"), b2), "aXbcYd")
        XCTAssertEqual(applied("abcd", TextOp(loc: 3, len: 0, text: "Y"), a2), "aXbcYd")
    }

    /// ホスト 1 人 + 参加者 2 人が好き勝手に打ち、通信が遅れても最後は全員同じになる
    func testServerAndClientsConverge() {
        for seed in 1...200 {
            var rng = RNG(state: UInt64(seed))
            let initial = "共同編集のテスト\nline2\n"
            let server = OTServer()
            let hostDoc = NSMutableString(string: initial)
            let clients = [OTClient(revision: 0), OTClient(revision: 0)]
            let docs = [NSMutableString(string: initial), NSMutableString(string: initial)]
            // ネットワーク: 参加者 → ホスト、ホスト → 参加者 (到着順は保たれる)
            var toServer: [[(TextOp, Int)]] = [[], []]
            var toClient: [[(op: TextOp, rev: Int, author: Int)]] = [[], []]

            func broadcast(_ op: TextOp, _ rev: Int, author: Int) {
                for i in 0..<2 { toClient[i].append((op, rev, author)) }
            }

            for _ in 0..<60 {
                switch Int.random(in: 0..<5, using: &rng) {
                case 0: // ホストが打つ
                    let op = randomOp(for: hostDoc as String, &rng)
                    op.apply(to: hostDoc)
                    broadcast(op, server.localEdit(op), author: -1)
                case 1, 2: // 参加者が打つ
                    let i = Int.random(in: 0..<2, using: &rng)
                    let op = randomOp(for: docs[i] as String, &rng)
                    op.apply(to: docs[i])
                    if let send = clients[i].localEdit(op) { toServer[i].append((send.op, send.baseRevision)) }
                case 3: // ホストに 1 通届く
                    let i = Int.random(in: 0..<2, using: &rng)
                    if !toServer[i].isEmpty {
                        let (op, base) = toServer[i].removeFirst()
                        let r = server.receive(op, baseRevision: base)
                        r.op.apply(to: hostDoc)
                        broadcast(r.op, r.revision, author: i)
                    }
                default: // 参加者に 1 通届く
                    let i = Int.random(in: 0..<2, using: &rng)
                    if !toClient[i].isEmpty {
                        let m = toClient[i].removeFirst()
                        if m.author == i {
                            if let send = clients[i].acknowledged(revision: m.rev) { toServer[i].append((send.op, send.baseRevision)) }
                        } else {
                            clients[i].remote(m.op, revision: m.rev).apply(to: docs[i])
                        }
                    }
                }
            }
            // 残りの通信をすべて流す
            var moved = true
            while moved {
                moved = false
                for i in 0..<2 {
                    while !toServer[i].isEmpty {
                        moved = true
                        let (op, base) = toServer[i].removeFirst()
                        let r = server.receive(op, baseRevision: base)
                        r.op.apply(to: hostDoc)
                        broadcast(r.op, r.revision, author: i)
                    }
                    while !toClient[i].isEmpty {
                        moved = true
                        let m = toClient[i].removeFirst()
                        if m.author == i {
                            if let send = clients[i].acknowledged(revision: m.rev) { toServer[i].append((send.op, send.baseRevision)) }
                        } else {
                            clients[i].remote(m.op, revision: m.rev).apply(to: docs[i])
                        }
                    }
                }
            }
            XCTAssertEqual(docs[0] as String, hostDoc as String, "seed \(seed)")
            XCTAssertEqual(docs[1] as String, hostDoc as String, "seed \(seed)")
        }
    }
}
