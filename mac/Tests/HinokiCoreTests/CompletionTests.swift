import XCTest
@testable import HinokiCore

final class CompletionTests: XCTestCase {
    func testPrefixRange() {
        let t = "let x = getEl" as NSString
        XCTAssertEqual(t.substring(with: Completion.prefixRange(in: t, caret: t.length)), "getEl")
        let p = "echo $us" as NSString
        XCTAssertEqual(p.substring(with: Completion.prefixRange(in: p, caret: p.length)), "$us")
        let c = "  font-we" as NSString
        XCTAssertEqual(c.substring(with: Completion.prefixRange(in: c, caret: c.length, allowDash: true)), "font-we")
        XCTAssertEqual(c.substring(with: Completion.prefixRange(in: c, caret: c.length)), "we")
    }

    func testFilterOrder() {
        let items = [
            Completion.Item(label: "getElementById", kind: .word),
            Completion.Item.function("getElementById(elementId)"),
            Completion.Item(label: "GetThing", kind: .word),
            Completion.Item(label: "toString", kind: .word),
            Completion.Item(label: "get", kind: .keyword),
        ]
        let r = Completion.filter(items, typed: "get")
        XCTAssertEqual(r.map { $0.label }, ["getElementById", "get", "GetThing"])
        // 同じ名前は先に来た関数を残す
        XCTAssertEqual(r[0].kind, .function)
        // 頭文字 + 順番どおり (gEBI)
        XCTAssertEqual(Completion.filter(items, typed: "gEBI").first?.label, "getElementById")
        XCTAssertTrue(Completion.filter(items, typed: "xyz").isEmpty)
    }

    func testDefinedFunctions() {
        let src = """
        function hello(name, age) {}
        const add = (a, b) => a + b;
        def greet(self, who="x"):
        func move(to point: CGPoint, animated: Bool) {}
        function &refFn($a) {}
        """
        let fns = Completion.definedFunctions(in: src)
        let byName = Dictionary(uniqueKeysWithValues: fns.map { ($0.label, $0) })
        XCTAssertEqual(byName["hello"]?.params, ["name", "age"])
        XCTAssertEqual(byName["add"]?.params, ["a", "b"])
        XCTAssertEqual(byName["greet"]?.params, ["self", "who=\"x\""])
        XCTAssertEqual(byName["move"]?.params, ["to point: CGPoint", "animated: Bool"])
        XCTAssertEqual(byName["refFn"]?.params, ["$a"])
    }

    func testWords() {
        let w = Completion.words(in: "alpha beta be alpha 123abc gamma_1 $user")
        XCTAssertEqual(w, ["alpha", "beta", "gamma_1", "$user"])
    }

    func testInsertion() {
        let f = Completion.Item.function("substr(string, offset, length)")
        XCTAssertEqual(Completion.insertion(for: f, next: nil, language: "PHP"), .init(text: "substr()", caret: 7))
        XCTAssertEqual(Completion.insertion(for: f, next: 0x28, language: "PHP"), .init(text: "substr", caret: 6))
        let noArgs = Completion.Item.function("time()")
        XCTAssertEqual(Completion.insertion(for: noArgs, next: nil, language: "PHP"), .init(text: "time()", caret: 6))
        let tag = Completion.Item(label: "div", kind: .tag)
        XCTAssertEqual(Completion.insertion(for: tag, next: nil, language: "HTML / XML"), .init(text: "div></div>", caret: 4))
        let br = Completion.Item(label: "br", kind: .tag)
        XCTAssertEqual(Completion.insertion(for: br, next: nil, language: "HTML / XML"), .init(text: "br>", caret: 3))
        let prop = Completion.Item(label: "color", kind: .property)
        XCTAssertEqual(Completion.insertion(for: prop, next: nil, language: "CSS"), .init(text: "color: ;", caret: 7))
    }

    func testCallContext() {
        func ctx(_ s: String) -> Completion.CallContext? {
            let t = s as NSString
            return Completion.callContext(in: t, caret: t.length)
        }
        XCTAssertEqual(ctx("substr($s, ")?.name, "substr")
        XCTAssertEqual(ctx("substr($s, ")?.argIndex, 1)
        XCTAssertEqual(ctx("foo(bar(1, 2), ")?.name, "foo")
        XCTAssertEqual(ctx("foo(bar(1, 2), ")?.argIndex, 1)
        XCTAssertEqual(ctx("foo(\"a, b\", ")?.argIndex, 1)
        XCTAssertEqual(ctx("foo(bar(")?.name, "bar")
        XCTAssertNil(ctx("foo(1); x"))
        XCTAssertNil(ctx("if (a, "))
        XCTAssertNil(ctx("plain text"))
    }

    func testLibrary() {
        let js = CompletionLibrary.items(for: "JavaScript / TypeScript")
        XCTAssertTrue(js.contains { $0.label == "JSON.stringify" && $0.params.count == 3 })
        XCTAssertTrue(CompletionLibrary.items(for: "PHP").contains { $0.label == "str_replace" })
        XCTAssertTrue(CompletionLibrary.items(for: "HTML / XML").contains { $0.label == "div" && $0.kind == .tag })
        XCTAssertTrue(CompletionLibrary.items(for: nil).isEmpty)
        XCTAssertEqual(Completion.splitParams("a, b = (1, 2), ...rest"), ["a", "b = (1, 2)", "...rest"])
    }
}
