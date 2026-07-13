import XCTest
@testable import RuSwitcherCore

final class ScriptMismatchHeuristicsTests: XCTestCase {
    func testLatinKeysCanBeStrongRussianMismatch() {
        XCTAssertTrue(ScriptMismatchHeuristics.hasStrongMismatch(
            typed: "ghbdtn",
            converted: "привет",
            targetLanguage: "ru"
        ))
    }

    func testCyrillicKeysCanBeStrongEnglishMismatch() {
        XCTAssertTrue(ScriptMismatchHeuristics.hasStrongMismatch(
            typed: "руддщ",
            converted: "hello",
            targetLanguage: "en"
        ))
    }

    func testShortTokensAreNotStrongEnough() {
        XCTAssertFalse(ScriptMismatchHeuristics.hasStrongMismatch(
            typed: "ult",
            converted: "где",
            targetLanguage: "ru"
        ))
    }

    func testUnsupportedTargetLanguageDoesNotGuess() {
        XCTAssertFalse(ScriptMismatchHeuristics.hasStrongMismatch(
            typed: "ghbdtn",
            converted: "привет",
            targetLanguage: "ja"
        ))
    }
}
