import XCTest
@testable import HinokiCore

final class LanguageGuessTests: XCTestCase {
    func testGuesses() {
        XCTAssertEqual(LanguageGuess.guess("<?php\necho 'hi';"), "PHP")
        XCTAssertEqual(LanguageGuess.guess("<!DOCTYPE html>\n<html></html>"), "HTML / XML")
        XCTAssertEqual(LanguageGuess.guess("function add(a, b) {\n  return a + b;\n}\nconsole.log(add(1, 2));"), "JavaScript / TypeScript")
        XCTAssertEqual(LanguageGuess.guess("def add(a, b):\n    return a + b\n\nprint(add(1, 2))"), "Python")
        XCTAssertEqual(LanguageGuess.guess("import SwiftUI\nstruct A: View {}"), "Swift")
        XCTAssertEqual(LanguageGuess.guess("package main\n\nfunc main() {\n\tx := 1\n}"), "Go")
        XCTAssertEqual(LanguageGuess.guess("#include <stdio.h>\nint main() { return 0; }"), "C / C++ / Objective-C")
        XCTAssertEqual(LanguageGuess.guess("#!/bin/bash\necho hi"), "シェル")
        XCTAssertEqual(LanguageGuess.guess("{\"a\": 1, \"b\": [1, 2]}"), "JSON")
        XCTAssertEqual(LanguageGuess.guess("SELECT name FROM users WHERE id = 1;"), "SQL")
        XCTAssertEqual(LanguageGuess.guess("body {\n  color: red;\n}"), "CSS")
        XCTAssertEqual(LanguageGuess.guess("fn main() {\n    let mut x = 1;\n    println!(\"{}\", x);\n}"), "Rust")
        XCTAssertNil(LanguageGuess.guess("今日はいい天気でした。\n明日も晴れるといいな。"))
        XCTAssertNil(LanguageGuess.guess(""))
    }
}
