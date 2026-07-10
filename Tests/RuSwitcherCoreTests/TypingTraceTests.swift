import XCTest
@testable import RuSwitcherCore

final class TypingTraceTests: XCTestCase {
    private func verdict(_ typed: String, context: [String]) -> SmartAutoConvertEvaluation {
        SmartAutoConvertEngine.evaluate(
            typed: typed,
            converted: KeyMapping.convert(typed),
            currentLanguage: "en",
            targetLanguage: "ru",
            capsLock: typed == typed.uppercased() && typed != typed.lowercased(),
            contextWords: context,
            policy: .empty,
            isValidWord: { word, language in
                let valid: [String: Set<String>] = [
                    "en": ["plan", "b"],
                    "ru": ["план", "и", "привет", "приветствую"],
                ]
                return valid[String(language.prefix(2))]?.contains(word.lowercased()) ?? false
            }
        )
    }

    func testBilingualPhraseTraceKeepsPlanB() {
        let plan = verdict("plan", context: [])
        XCTAssertNotEqual(plan.decision.verdict, .switchToConverted)
        let letter = verdict("B", context: ["plan"])
        XCTAssertEqual(letter.decision.verdict, .keep)
    }

    func testRussianPhraseTraceConvertsShortConjunction() {
        let letter = verdict("b", context: ["это", "план"])
        XCTAssertEqual(letter.decision.verdict, .switchToConverted)
        XCTAssertEqual(letter.decision.candidate.replacement, "и")
    }

    func testPunctuationTraceChoosesDifferentPhysicalInterpretations() {
        XCTAssertEqual(verdict("ghbdtn,", context: []).decision.candidate.replacement, "привет,")
        XCTAssertEqual(verdict("ghbdtncnde.", context: []).decision.candidate.replacement, "приветствую")
    }
}
