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
        let result = evaluate("gjvjom.", context: ["с"])
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
    }

    func testExtendedEnglishDictionaryProtectsOOVWordsInRussianContext() {
        var russianBelief = LanguageBelief.neutral
        russianBelief.observe(language: "ru")
        russianBelief.observe(language: "ru")
        for word in ["cyst", "juju", "codex"] {
            XCTAssertFalse(model.contains(word, language: "en"), word)
            XCTAssertTrue(model.isExtendedEnglishWord(word), word)
            let result = evaluate(
                word,
                current: "en",
                target: "ru",
                context: ["это", "текст"],
                belief: russianBelief
            )
            XCTAssertEqual(result.decision.verdict, .keep, word)
            XCTAssertTrue(result.evidence.contains(.englishSourceDictionary), word)
        }
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

    func testLiteralTypedCommaBeatsConvertedQuestionMark() {
        let result = evaluate(
            "ыцшесрштп,",
            current: "ru",
            target: "en",
            context: ["this", "text"]
        )
        XCTAssertEqual(result.decision.candidate.replacement, "switching,")
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
    }

    func testWrappingPunctuationIsPreservedAroundConvertedWord() {
        let result = evaluate("{gjnjv)", context: ["это"])
        XCTAssertEqual(result.decision.candidate.replacement, "{потом)")
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
        XCTAssertEqual(result.decision.candidate.kind, .wrappingPunctuation)
    }

    func testKnownWrappedTargetBeatsUnknownDirectTargetInEnglishContext() {
        var englishBelief = LanguageBelief.neutral
        englishBelief.observe(language: "en")
        englishBelief.observe(language: "en")
        let result = evaluate(
            "{elfkb?",
            context: ["keyboard", "again"],
            belief: englishBelief
        )
        XCTAssertEqual(result.decision.candidate.replacement, "{удали?")
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
    }

    func testLongestKnownPunctuationSuffixWins() {
        let result = evaluate("htpekmnfn?!", context: ["это"])
        XCTAssertEqual(result.decision.candidate.replacement, "результат?!")
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
    }

    func testFrequentWrappedTargetBeatsBloomOnlyDirectTarget() {
        for typed in ["[yt", "{yt)", "«lj,"] {
            let result = evaluate(typed, context: ["это"])
            let expected = typed.contains("lj")
                ? typed.replacingOccurrences(of: "lj", with: "до")
                : typed.replacingOccurrences(of: "yt", with: "не")
            XCTAssertEqual(result.decision.candidate.replacement, expected, typed)
            XCTAssertEqual(result.decision.verdict, .switchToConverted, typed)
        }
    }

    func testLayoutLetterBeforeDecorationStaysLetter() {
        let result = evaluate("gkfn`;-", context: ["это"])
        XCTAssertEqual(result.decision.candidate.replacement, "платёж-")
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
    }

    func testTypedPunctuationWinsWhenBothInterpretationsAreWords() {
        for (typed, expected) in [("b[", "и["), ("xnj,", "что,"), ("yjxm.", "ночь.")] {
            let result = evaluate(typed, context: ["это"])
            XCTAssertEqual(result.decision.candidate.replacement, expected, typed)
            XCTAssertEqual(result.decision.verdict, .switchToConverted, typed)
        }
    }

    func testFullTypedEllipsisWinsOverPartialLayoutLetterTail() {
        let result = evaluate("(yt...", context: ["это"])
        XCTAssertEqual(result.decision.candidate.replacement, "(не...")
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
    }

    func testTrailingUnderscoreIsPreservedWithoutBlockingWord() {
        let result = evaluate(
            "црн_",
            current: "ru",
            target: "en",
            context: ["this", "text"]
        )
        XCTAssertEqual(result.decision.candidate.replacement, "why_")
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
    }

    func testCorrectDecoratedEnglishWordStaysEnglish() {
        var russianBelief = LanguageBelief.neutral
        russianBelief.observe(language: "ru")
        russianBelief.observe(language: "ru")
        for token in ["input_", "input-", "input—"] {
            let result = evaluate(
                token,
                current: "en",
                target: "ru",
                context: ["это", "текст"],
                belief: russianBelief
            )
            XCTAssertNotEqual(result.decision.verdict, .switchToConverted, token)
        }
    }

    func testPlausibleUnknownEnglishWordConvertsFromRussianLayout() {
        let result = evaluate("афиду", current: "ru", target: "en")
        XCTAssertEqual(result.decision.candidate.replacement, "fable")
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
    }

    func testUnknownRussianWordsUseGeneralCharacterEvidence() {
        for (typed, expected) in [
            ("ghjnthtnm", "протереть"),
            ("pflybwf", "задница"),
            ("gblh", "пидр"),
        ] {
            let result = evaluate(typed, context: ["нужно"])
            XCTAssertEqual(
                result.decision.verdict,
                .switchToConverted,
                "\(typed) -> \(expected), margin=\(result.confidenceMargin) threshold=\(result.threshold) evidence=\(result.evidence)"
            )
            XCTAssertEqual(result.decision.candidate.replacement, expected)
        }
    }

    func testEnglishBeliefOnlyAllowsLongStrongRussianOOVWords() {
        var englishBelief = LanguageBelief.neutral
        englishBelief.observe(language: "en")
        englishBelief.observe(language: "en")

        let wipe = evaluate("ghjnthtnm", context: ["this"], belief: englishBelief)
        let butt = evaluate("pflybwf", context: ["this"], belief: englishBelief)
        XCTAssertEqual(wipe.decision.verdict, .switchToConverted, "margin=\(wipe.confidenceMargin) threshold=\(wipe.threshold)")
        XCTAssertEqual(butt.decision.verdict, .switchToConverted, "margin=\(butt.confidenceMargin) threshold=\(butt.threshold)")
        XCTAssertEqual(
            evaluate("gblh", context: ["this"], belief: englishBelief).decision.verdict,
            .undecided
        )
    }

    func testPlausibleUnknownEnglishWordStaysBlockedInStrongRussianContext() {
        var russianBelief = LanguageBelief.neutral
        russianBelief.observe(language: "ru")
        russianBelief.observe(language: "ru")
        let intended = "contextualizable"
        let mistyped = KeyMapping.convert(intended)
        XCTAssertFalse(model.contains(intended, language: "en"))
        XCTAssertFalse(model.isExtendedEnglishWord(intended))
        let result = evaluate(
            mistyped,
            current: "ru",
            target: "en",
            context: ["это", "текст"],
            belief: russianBelief
        )
        XCTAssertEqual(result.decision.verdict, .keep)
    }

    func testExtendedEnglishTargetCanOverrideStaleRussianContext() {
        var russianBelief = LanguageBelief.neutral
        russianBelief.observe(language: "ru")
        russianBelief.observe(language: "ru")
        let result = evaluate(
            "дщщыут",
            current: "ru",
            target: "en",
            context: ["нужно", "немного"],
            belief: russianBelief
        )
        XCTAssertFalse(model.contains("loosen", language: "en"))
        XCTAssertTrue(model.isExtendedEnglishWord("loosen"))
        XCTAssertEqual(result.decision.candidate.replacement, "loosen")
        XCTAssertEqual(
            result.decision.verdict,
            .switchToConverted,
            "margin=\(result.confidenceMargin) threshold=\(result.threshold) evidence=\(result.evidence)"
        )
        XCTAssertTrue(result.evidence.contains(.englishTargetDictionary))
    }

    func testKnownRussianLiteralWinsOverExtendedEnglishCollision() {
        var checked = 0
        for word in model.trainingWords(language: "ru") {
            let english = KeyMapping.convert(word)
            guard english.count >= 4, model.isExtendedEnglishWord(english) else { continue }
            checked += 1
            let result = evaluate(word, current: "ru", target: "en")
            XCTAssertNotEqual(result.decision.verdict, .switchToConverted, "\(word) -> \(english)")
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testExtendedRussianDictionaryProtectsCorrectSourceAndConfirmsTarget() {
        var englishBelief = LanguageBelief.neutral
        englishBelief.observe(language: "en")
        englishBelief.observe(language: "en")
        for word in ["ввод", "сервер", "отчёт", "буфер", "клавиатура", "платёж"] {
            let correct = evaluate(word, current: "ru", target: "en")
            XCTAssertNotEqual(correct.decision.verdict, .switchToConverted, word)

            let mistyped = KeyMapping.convert(word)
            let converted = evaluate(
                mistyped,
                current: "en",
                target: "ru",
                context: ["this", "text"],
                belief: englishBelief
            )
            XCTAssertEqual(converted.decision.candidate.replacement, word, mistyped)
            XCTAssertEqual(converted.decision.verdict, .switchToConverted, mistyped)
            XCTAssertTrue(converted.evidence.contains(.russianTargetDictionary), mistyped)
        }
    }

    func testLeadingPunctuationKeyCanBecomeRussianLetterForExactTarget() {
        var englishBelief = LanguageBelief.neutral
        englishBelief.observe(language: "en")
        englishBelief.observe(language: "en")
        let result = evaluate(
            ",eath...",
            context: ["this", "text"],
            belief: englishBelief
        )
        XCTAssertEqual(result.decision.candidate.replacement, "буфер...")
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
    }

    func testBothKnownRussianSourceAndEnglishTargetRemainLiteral() {
        let result = evaluate(
            "туче",
            current: "ru",
            target: "en",
            context: ["this", "text"]
        )
        XCTAssertEqual(KeyMapping.convert("туче"), "next")
        XCTAssertEqual(result.decision.verdict, .keep)
        XCTAssertTrue(
            result.evidence.contains(.russianSourceDictionary)
                || result.evidence.contains(.blockedContext)
        )
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
