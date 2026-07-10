import XCTest
@testable import RuSwitcherCore

final class TypingLanguageStateTests: XCTestCase {
    func testRecentLanguageBuildsAndDecaysConfidence() {
        var state = TypingLanguageState.neutral
        state.observe(language: "ru")
        state.observe(language: "ru")
        XCTAssertGreaterThan(state.confidence(language: "ru"), 0.9)

        state.observe(language: "en")
        state.observe(language: "en")
        state.observe(language: "en")
        XCTAssertGreaterThan(state.confidence(language: "en"), 0.6)
    }

    func testConvertedTokenHasStrongerSessionEvidence() {
        var session = InputSession()
        session.append(TypedKey(keyCode: 0, shift: false, caps: false, producedCharacter: "g"))
        session.complete(resolvedText: "привет", language: "ru", wasConverted: true)
        XCTAssertGreaterThan(session.languageState.score(language: "ru"), 0)
    }
}
