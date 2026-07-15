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

    func testTrailingPunctuationStaysInToken() {
        let parsed = CaretTokenParser.tokenBeforeCaret(from: "ok ghbdtn,")
        XCTAssertEqual(parsed?.word, "ghbdtn,")
        XCTAssertEqual(parsed?.trailingWhitespace, "")
    }

    func testWhitespaceOnlyIsNil() {
        XCTAssertNil(CaretTokenParser.tokenBeforeCaret(from: "   "))
        XCTAssertNil(CaretTokenParser.tokenBeforeCaret(from: ""))
    }
}
