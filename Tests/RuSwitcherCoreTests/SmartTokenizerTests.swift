import XCTest
@testable import RuSwitcherCore

final class SmartTokenizerTests: XCTestCase {
    func testSeparatesUnicodeQuotesAndPunctuation() {
        let shape = SmartTokenizer.shape(of: "«привет,»")
        XCTAssertEqual(shape.prefix, "«")
        XCTAssertEqual(shape.lexicalCore, "привет")
        XCTAssertEqual(shape.suffix, ",»")
        XCTAssertEqual(shape.kind, .lexical)
    }

    func testRecognizesProtectedStructuredTokens() {
        XCTAssertEqual(SmartTokenizer.kind(of: "https://example.com/a"), .url)
        XCTAssertEqual(SmartTokenizer.kind(of: "me@example.com"), .email)
        XCTAssertEqual(SmartTokenizer.kind(of: "snake_case"), .identifier)
        XCTAssertEqual(SmartTokenizer.kind(of: "myURL"), .identifier)
        XCTAssertEqual(SmartTokenizer.kind(of: "abcЖ"), .mixedScript)
    }

    func testTrailingDecorationsDoNotTurnWordsIntoIdentifiers() {
        for token in ["input_", "input-", "input—"] {
            let shape = SmartTokenizer.shape(of: token)
            XCTAssertEqual(shape.lexicalCore, "input", token)
            XCTAssertEqual(shape.kind, .lexical, token)
        }
        XCTAssertEqual(SmartTokenizer.kind(of: "snake_case"), .identifier)
    }
}
