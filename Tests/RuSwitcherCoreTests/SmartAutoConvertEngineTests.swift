import XCTest
@testable import RuSwitcherCore

final class SmartAutoConvertEngineTests: XCTestCase {
    private func evaluate(
        _ typed: String,
        current: String = "en",
        target: String = "ru",
        context: [String] = [],
        valid: Set<String> = []
    ) -> SmartAutoConvertEvaluation {
        SmartAutoConvertEngine.evaluate(
            typed: typed,
            converted: KeyMapping.convert(typed),
            currentLanguage: current,
            targetLanguage: target,
            capsLock: false,
            contextWords: context,
            policy: .empty,
            isValidWord: { word, _ in valid.contains(word.lowercased()) }
        )
    }

    func testFrequentShortWordConvertsAtStart() {
        XCTAssertEqual(evaluate("b").decision.verdict, .switchToConverted)
        XCTAssertEqual(evaluate("b").decision.candidate.replacement, "и")
    }

    func testPlanUppercaseBStaysLatin() {
        let result = evaluate("B", context: ["plan"], valid: ["b"])
        XCTAssertEqual(result.decision.verdict, .keep)
        XCTAssertEqual(result.decision.reason, .blockedCodeLike)
    }

    func testLowercaseBStaysAfterLatinContext() {
        XCTAssertEqual(evaluate("b", context: ["plan"], valid: ["b"]).decision.verdict, .keep)
    }

    func testLowercaseBConvertsAfterRussianContext() {
        XCTAssertEqual(evaluate("b", context: ["план"], valid: ["b"]).decision.verdict, .switchToConverted)
    }

    func testCommaBecomesPunctuation() {
        let result = evaluate("ghbdtn,", valid: ["привет"])
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
        XCTAssertEqual(result.decision.candidate.replacement, "привет,")
    }

    func testPeriodCanRemainLayoutLetter() {
        let result = evaluate("ghbdtncnde.", valid: ["приветствую"])
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
        XCTAssertEqual(result.decision.candidate.replacement, "приветствую")
    }

    func testUnknownRussianLookingWordStaysInRussianContext() {
        let result = evaluate(
            "флоуменеджер",
            current: "ru",
            target: "en",
            context: ["это", "редкий"],
            valid: []
        )
        XCTAssertNotEqual(result.decision.verdict, .switchToConverted)
    }

    func testHelloTypedInRussianLayoutConvertsWithoutContext() {
        let result = evaluate("руддщ", current: "ru", target: "en", valid: ["hello"])
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
        XCTAssertEqual(result.decision.candidate.replacement, "hello")
    }

    func testStructuredTokensStayUnchanged() {
        XCTAssertEqual(evaluate("example.com").decision.verdict, .keep)
        XCTAssertEqual(evaluate("myURL").decision.verdict, .keep)
        XCTAssertEqual(evaluate("NASA").decision.verdict, .keep)
    }

    func testNeverAndAlwaysRulesRemainHardOverrides() {
        let never = SmartAutoConvertEngine.evaluate(
            typed: "b", converted: "и", currentLanguage: "en", targetLanguage: "ru",
            capsLock: false, contextWords: [],
            policy: AutoConvertPolicy(neverConvert: ["и"], alwaysConvert: []),
            isValidWord: { _, _ in false }
        )
        XCTAssertEqual(never.decision.reason, .blockedNever)

        let always = SmartAutoConvertEngine.evaluate(
            typed: "qwerty", converted: "йцукен", currentLanguage: "en", targetLanguage: "ru",
            capsLock: false, contextWords: [],
            policy: AutoConvertPolicy(neverConvert: [], alwaysConvert: ["йцукен"]),
            isValidWord: { _, _ in false }
        )
        XCTAssertEqual(always.decision.reason, .alwaysConvert)
    }

    func testImmediateUndoPenaltySuppressesSameCorrectionForSession() {
        let result = SmartAutoConvertEngine.evaluate(
            typed: "b",
            converted: "и",
            currentLanguage: "en",
            targetLanguage: "ru",
            capsLock: false,
            contextWords: [],
            policy: .empty,
            adaptiveBias: { _, _ in -12 },
            isValidWord: { _, _ in false }
        )
        XCTAssertNotEqual(result.decision.verdict, .switchToConverted)
    }
}
