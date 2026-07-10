import XCTest
@testable import RuSwitcherCore

final class LayoutDecoderTests: XCTestCase {
    private let model = LanguageModelStore.bundled!

    private func evaluate(
        _ typed: String,
        current: String = "en",
        target: String = "ru",
        context: [String] = [],
        belief: LanguageBelief = .neutral,
        integrity: EditorIntegrity = .clean,
        confirmed: Bool = false
    ) -> LayoutDecoderEvaluation {
        LayoutDecoder.evaluate(
            typed: typed,
            converted: KeyMapping.convert(typed),
            currentLanguage: current,
            targetLanguage: target,
            capsLock: typed == typed.uppercased() && typed != typed.lowercased(),
            contextWords: context,
            languageBelief: belief,
            integrity: integrity,
            policy: .empty,
            isConfirmed: { _, _ in confirmed },
            model: model
        )
    }

    func testUnknownCompoundConvertsAtBoundary() {
        let result = evaluate("cegthcgbyf", context: ["это"])
        XCTAssertEqual(result.decision.verdict, .switchToConverted, "margin=\(result.confidenceMargin) evidence=\(result.evidence)")
        XCTAssertEqual(result.decision.candidate.replacement, "суперспина")
        XCTAssertEqual(result.decision.reason, .compound)
        XCTAssertTrue(result.evidence.contains(.compound(segmentLengths: [5, 5])))
    }

    func testInternalPhysicalPeriodRemainsLayoutLetterInRevolution() {
        let mistyped = KeyMapping.convert("революция")
        XCTAssertEqual(mistyped, "htdjk.wbz")
        let result = evaluate(mistyped)
        XCTAssertEqual(result.decision.candidate.replacement, "революция")
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
    }

    func testKnownDirectWordBeatsTrailingPunctuationAlternative() {
        let result = evaluate("gjvjom.", context: ["это"])
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
        XCTAssertEqual(result.decision.candidate.replacement, "помощью")
    }

    func testTwoKnownWordsOnSameKeysRemainLiteral() {
        var russianBelief = LanguageBelief.neutral
        russianBelief.observe(language: "ru")
        russianBelief.observe(language: "ru")
        let result = evaluate("here", context: ["это", "текст"], belief: russianBelief)
        XCTAssertEqual(KeyMapping.convert("here"), "руку")
        XCTAssertEqual(result.decision.verdict, .keep)
        XCTAssertEqual(result.decision.reason, .blockedContext)
    }

    func testColloquialSuffixConvertsFromKnownStem() {
        var englishBelief = LanguageBelief.neutral
        englishBelief.observe(language: "en")
        englishBelief.observe(language: "en")
        let result = evaluate(
            "ghbdtnekmrb",
            context: ["this", "is"],
            belief: englishBelief
        )
        XCTAssertEqual(result.decision.candidate.replacement, "приветульки")
        XCTAssertEqual(
            result.decision.verdict,
            .switchToConverted,
            "margin=\(result.confidenceMargin) threshold=\(result.threshold) evidence=\(result.evidence)"
        )
        XCTAssertTrue(result.evidence.contains(.compound(segmentLengths: [6, 5])))
    }

    func testEnglishUseWithCommaRemainsEnglishInRussianContext() {
        var russianBelief = LanguageBelief.neutral
        russianBelief.observe(language: "ru")
        russianBelief.observe(language: "ru")
        let result = evaluate(
            "use,",
            current: "en",
            target: "ru",
            context: ["это", "текст"],
            belief: russianBelief
        )
        XCTAssertEqual(result.decision.verdict, .keep)
        XCTAssertEqual(result.decision.candidate.replacement, "гыу,")
    }

    func testShortConjunctionAndPlanBAreDisambiguatedByContext() {
        XCTAssertEqual(evaluate("b", context: ["это", "план"]).decision.candidate.replacement, "и")
        XCTAssertEqual(evaluate("b", context: ["это", "план"]).decision.verdict, .switchToConverted)
        XCTAssertEqual(evaluate("b", context: ["plan"]).decision.verdict, .keep)
        XCTAssertEqual(evaluate("B", context: ["plan"]).decision.verdict, .keep)
    }

    func testRussianUnknownDoesNotFlipToEnglishInRussianBelief() {
        var belief = LanguageBelief.neutral
        belief.observe(language: "ru")
        belief.observe(language: "ru")
        let unknown = "квазиподходовость"
        XCTAssertFalse(model.contains(unknown, language: "ru"))
        let result = evaluate(unknown, current: "ru", target: "en", context: ["это"], belief: belief)
        XCTAssertNotEqual(result.decision.verdict, .switchToConverted)
    }

    func testRussianUnknownDoesNotFlipToUnknownEnglishEvenWhenBeliefIsNeutral() {
        let unknown = "квазиподходовость"
        let result = evaluate(unknown, current: "ru", target: "en")
        XCTAssertEqual(result.decision.verdict, .keep)
        XCTAssertEqual(result.decision.reason, .blockedContext)
    }

    func testKnownEnglishWordConvertsFromRussianLayoutInNeutralContext() {
        let result = evaluate("руддщ", current: "ru", target: "en")
        XCTAssertEqual(result.decision.candidate.replacement, "hello")
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
    }

    func testReverseConversionKeepsProducedEnglishComma() {
        let result = evaluate("гыуб", current: "ru", target: "en")
        XCTAssertEqual(result.decision.candidate.replacement, "use,")
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
    }

    func testPlausibleUnknownEnglishWordConvertsFromRussianLayout() {
        let result = evaluate("афиду", current: "ru", target: "en")
        XCTAssertEqual(result.decision.candidate.replacement, "fable")
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
    }

    func testPlausibleUnknownEnglishWordStaysBlockedInStrongRussianContext() {
        var russianBelief = LanguageBelief.neutral
        russianBelief.observe(language: "ru")
        russianBelief.observe(language: "ru")
        let result = evaluate(
            "афиду",
            current: "ru",
            target: "en",
            context: ["это", "текст"],
            belief: russianBelief
        )
        XCTAssertEqual(result.decision.verdict, .keep)
    }

    func testKnownEnglishWordCanStartAfterRussianContext() {
        var russianBelief = LanguageBelief.neutral
        russianBelief.observe(language: "ru")
        russianBelief.observe(language: "ru")
        let result = evaluate(
            "руддщ",
            current: "ru",
            target: "en",
            context: ["это", "текст"],
            belief: russianBelief
        )
        XCTAssertEqual(result.decision.candidate.replacement, "hello")
        XCTAssertEqual(
            result.decision.verdict,
            .switchToConverted,
            "margin=\(result.confidenceMargin) threshold=\(result.threshold) evidence=\(result.evidence)"
        )
    }

    func testConfirmedPairOverridesLexicalMiss() {
        let result = evaluate("cegthcgbyf", confirmed: true)
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
        XCTAssertEqual(result.decision.reason, .confirmedByUser)
    }

    func testInvalidatedEditorBlocksDecoder() {
        let result = evaluate("ghbdtn", integrity: .invalidated)
        XCTAssertEqual(result.decision.verdict, .keep)
        XCTAssertEqual(result.decision.reason, .blockedEditing)
    }

    func testProtectedShapesNeverConvert() {
        for token in ["example.com", "me@example.com", "myURL", "NASA", "snake_case"] {
            XCTAssertEqual(evaluate(token).decision.verdict, .keep, token)
        }
    }

    func testDecoderPerformanceBudget() {
        var durations: [Double] = []
        durations.reserveCapacity(2_000)
        for _ in 0..<2_000 {
            let start = ContinuousClock.now
            _ = evaluate("ghbdtncnde.", context: ["я", "вас"])
            durations.append(Double(start.duration(to: .now).components.attoseconds) / 1e18)
        }
        durations.sort()
        XCTAssertLessThan(durations[Int(Double(durations.count) * 0.95)], 0.005)
    }
}
