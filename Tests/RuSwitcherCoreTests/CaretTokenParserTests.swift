import XCTest
@testable import RuSwitcherCore

final class CaretTokenParserTests: XCTestCase {
    func testWordWithTrailingSpaces() {
        let parsed = CaretTokenParser.tokenBeforeCaret(from: "hello ghbdtn  ")
        XCTAssertEqual(parsed?.word, "ghbdtn")
        XCTAssertEqual(parsed?.trailingWhitespace, "  ")
    }

    func testWordWithoutTrailingSpace() {
        let parsed = CaretTokenParser.tokenBeforeCaret(from: "say привет")
        XCTAssertEqual(parsed?.word, "привет")
        XCTAssertEqual(parsed?.trailingWhitespace, "")
    }

    func testPunctuationRemainsPartOfToken() {
        let parsed = CaretTokenParser.tokenBeforeCaret(from: "ok ghbdtn,")
        XCTAssertEqual(parsed?.word, "ghbdtn,")
        XCTAssertEqual(parsed?.trailingWhitespace, "")
    }

    func testWhitespaceOnlyIsNil() {
        XCTAssertNil(CaretTokenParser.tokenBeforeCaret(from: "   "))
        XCTAssertNil(CaretTokenParser.tokenBeforeCaret(from: ""))
    }

    func testTruncatedTokenAtReadWindowStartIsRejected() {
        XCTAssertNil(CaretTokenParser.tokenBeforeCaret(
            from: String(repeating: "a", count: 96),
            tokenAtInputStartIsComplete: false
        ))
        XCTAssertEqual(CaretTokenParser.tokenBeforeCaret(
            from: "partial hello",
            tokenAtInputStartIsComplete: false
        )?.word, "hello")
    }

    func testNewlineAndTabAfterTokenAreNotCrossed() {
        XCTAssertNil(CaretTokenParser.tokenBeforeCaret(from: "hello\n"))
        XCTAssertNil(CaretTokenParser.tokenBeforeCaret(from: "hello\t"))
    }

    func testComposedUnicodeAndHorizontalSpaces() {
        let parsed = CaretTokenParser.tokenBeforeCaret(from: "тёплый  ")
        XCTAssertEqual(parsed?.word, "тёплый")
        XCTAssertEqual(parsed?.trailingWhitespace, "  ")
    }
}
