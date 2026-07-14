import XCTest
@testable import RuSwitcherCore

final class LayoutDecoderTests: XCTestCase {
    private let model = LanguageModelStore.bundled!

    private func evaluate(
        _ typed: String,
        converted: String? = nil,
        current: String = "en",
        target: String = "ru",
        context: [String] = [],
        belief: LanguageBelief = .neutral,
        integrity: EditorIntegrity = .clean,
        confirmed: Bool = false,
        adaptiveBias: Double = 0
    ) -> LayoutDecoderEvaluation {
        LayoutDecoder.evaluate(
            typed: typed,
            converted: converted ?? KeyMapping.convert(typed),
            currentLanguage: current,
            targetLanguage: target,
            capsLock: typed == typed.uppercased() && typed != typed.lowercased(),
            contextWords: context,
            languageBelief: belief,
            integrity: integrity,
            policy: .empty,
            adaptiveBias: { _, _ in adaptiveBias },
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
        XCTAssertEqual(
            result.decision.verdict,
            .switchToConverted,
            "candidate=\(result.decision.candidate.replacement) reason=\(result.decision.reason) evidence=\(result.evidence)"
        )
    }

    func testKnownDirectWordBeatsTrailingPunctuationAlternative() {
        let result = evaluate("gjvjom.", context: ["с"])
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
        XCTAssertEqual(result.decision.candidate.replacement, "помощью")
    }

    func testWholeLayoutPathWinsWhenDecorationLookingKeysCompleteAWord() {
        let fixtures: [(intended: String, context: [String])] = [
            ("событиях", ["говорили", "о", "важных"]),
            ("рубеж", ["они", "перешли"]),
            ("лоб", ["ударился", "в"]),
            ("беседа", ["после", "этого"]),
        ]

        for fixture in fixtures {
            let typed = KeyMapping.convert(fixture.intended)
            let result = evaluate(typed, context: fixture.context)
            let wordScore = model.wordLogProbability(fixture.intended, language: "ru")
            let extended = model.isExtendedRussianWord(fixture.intended)
            let characterScore = model.characterLogProbability(fixture.intended, language: "ru")
            XCTAssertEqual(
                result.decision.verdict,
                .switchToConverted,
                "\(fixture.intended): typed=\(typed) candidate=\(result.decision.candidate.replacement)"
            )
            XCTAssertEqual(
                result.decision.candidate.replacement,
                fixture.intended,
                "\(fixture.intended): typed=\(typed) evidence=\(result.evidence) word=\(String(describing: wordScore)) extended=\(extended) char=\(characterScore)"
            )
        }
    }

    func testAmbiguousWholeWordNeverCommitsTheHybridPunctuationPath() {
        let intended = "статью"
        let typed = KeyMapping.convert(intended)
        let result = evaluate(typed, context: ["редактор", "проверил"])

        XCTAssertNotEqual(result.decision.candidate.replacement, "стать.")
        XCTAssertNotEqual(result.decision.verdict, .switchToConverted)
    }

    func testWholeLayoutPathTranslatesTargetHashtagAndPairedQuotes() {
        var englishBelief = LanguageBelief.neutral
        for _ in 0..<3 { englishBelief.observe(language: "en") }
        let hashtag = "#research"
        let mistypedHashtag = KeyMapping.convert(hashtag)
        XCTAssertEqual(
            SmartTokenizer.shape(of: mistypedHashtag).kind,
            .lexical,
            "typed=\(mistypedHashtag) shape=\(SmartTokenizer.shape(of: mistypedHashtag))"
        )
        let hashtagResult = evaluate(
            mistypedHashtag,
            current: "ru",
            target: "en",
            context: ["new", "research"],
            belief: englishBelief
        )
        XCTAssertEqual(
            hashtagResult.decision.verdict,
            .switchToConverted,
            "candidate=\(hashtagResult.decision.candidate.replacement) reason=\(hashtagResult.decision.reason) evidence=\(hashtagResult.evidence)"
        )
        XCTAssertEqual(hashtagResult.decision.candidate.replacement, hashtag)

        var russianBelief = LanguageBelief.neutral
        for _ in 0..<3 { russianBelief.observe(language: "ru") }
        let quoted = "\"мама\")"
        let quotedResult = evaluate(
            KeyMapping.convert(quoted),
            context: ["молодая"],
            belief: russianBelief
        )
        XCTAssertEqual(
            quotedResult.decision.verdict,
            .switchToConverted,
            "candidate=\(quotedResult.decision.candidate.replacement) reason=\(quotedResult.decision.reason) evidence=\(quotedResult.evidence)"
        )
        XCTAssertEqual(quotedResult.decision.candidate.replacement, quoted)
    }

    func testCorrectSocialIdentifiersAndPlausibleLatinWordsStayLiteral() {
        var russianBelief = LanguageBelief.neutral
        for _ in 0..<4 { russianBelief.observe(language: "ru") }

        for token in ["@abcnews", "#syria", "(@berillii)", "bhakti»"] {
            let result = evaluate(
                token,
                context: ["это", "внешняя", "ссылка"],
                belief: russianBelief
            )
            let targetCore = SmartTokenizer.lexicalCore(of: result.decision.candidate.convertedWord)
            let targetWord = model.wordLogProbability(targetCore, language: "ru")
            let targetExtended = model.isExtendedRussianWord(targetCore)
            let sourceCore = SmartTokenizer.lexicalCore(of: token)
            let sourceCharacter = model.characterLogProbability(sourceCore, language: "en")
            let targetCharacter = model.characterLogProbability(targetCore, language: "ru")
            XCTAssertNotEqual(
                result.decision.verdict,
                .switchToConverted,
                "\(token) -> \(result.decision.candidate.replacement) reason=\(result.decision.reason) evidence=\(result.evidence) source=\(EnglishSourceClassifier.classify(token, model: model)) sourceChar=\(sourceCharacter) targetWord=\(String(describing: targetWord)) targetExtended=\(targetExtended) targetChar=\(targetCharacter) floor=\(model.thresholds.englishSourceCharacterFloor)"
            )
        }
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

    func testSingleRussianConjunctionAfterEnglishInsertionUsesRecentMixedContext() {
        let mixed = evaluate("f", context: ["sent", "файл", "к", "review"])
        XCTAssertEqual(mixed.decision.candidate.replacement, "а")
        XCTAssertEqual(mixed.decision.verdict, .switchToConverted)

        let english = evaluate("f", context: ["send", "it", "to", "review"])
        XCTAssertEqual(english.decision.verdict, .keep)
    }

    func testCorrectSingleRussianConjunctionStaysRussianInEnglishContext() {
        var englishBelief = LanguageBelief.neutral
        englishBelief.observe(language: "en")
        englishBelief.observe(language: "en")

        for word in ["а", "и", "я", "в", "с", "к", "у", "о"] {
            let result = evaluate(
                word,
                current: "ru",
                target: "en",
                context: ["answer", "yes"],
                belief: englishBelief
            )
            XCTAssertEqual(result.decision.verdict, .keep, word)
        }
    }

    func testStaleConfirmationCannotOverrideCorrectSingleLetterWord() {
        var englishBelief = LanguageBelief.neutral
        englishBelief.observe(language: "en")
        englishBelief.observe(language: "en")

        for word in ["а", "и", "я", "в", "с", "к", "у", "о"] {
            let result = evaluate(
                word,
                current: "ru",
                target: "en",
                context: ["answer", "yes"],
                belief: englishBelief,
                confirmed: true
            )
            XCTAssertEqual(result.decision.verdict, .keep, word)
            XCTAssertNotEqual(result.decision.reason, .confirmedByUser, word)
        }
    }

    func testPunctuationOnlyTokensNeverTriggerLayoutConversion() {
        for token in ["\"?!\",", "...", "@", "&"] {
            let result = evaluate(token)
            XCTAssertEqual(result.decision.verdict, .keep, token)
            XCTAssertEqual(result.decision.reason, .blockedCodeLike, token)
        }
    }

    func testFrequentEnglishShortWordsBeatOnlyWeakRussianDictionaryHitsInMixedContext() {
        let butResult = evaluate(
            "иге",
            current: "ru",
            target: "en",
            context: ["Development", "работает", "в", "RU"]
        )
        XCTAssertEqual(butResult.decision.candidate.replacement, "but")
        XCTAssertEqual(butResult.decision.verdict, .switchToConverted)

        let inResult = evaluate(
            "шт",
            current: "ru",
            target: "en",
            context: ["работает", "RU", "but", "stays"]
        )
        XCTAssertEqual(inResult.decision.candidate.replacement, "in")
        XCTAssertEqual(inResult.decision.verdict, .switchToConverted)

        let russianContext = evaluate(
            "шт",
            current: "ru",
            target: "en",
            context: ["цена", "за", "одну", "штуку"]
        )
        XCTAssertEqual(russianContext.decision.verdict, .keep)
    }

    func testFrequentEnglishTargetCannotOverrideKnownRussianWord() {
        for word in ["рук", "руб", "шею"] {
            let result = evaluate(
                word,
                current: "ru",
                target: "en",
                context: ["this", "text"]
            )
            XCTAssertEqual(result.decision.verdict, .keep, word)
        }
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

    func testFrequentThreeLetterRussianWordConvertsWithoutSpecialContext() {
        for context in [[], ["это"], ["почему"]] {
            let result = evaluate("vyt", context: context)
            XCTAssertEqual(result.decision.candidate.replacement, "мне", "context=\(context)")
            XCTAssertEqual(
                result.decision.verdict,
                .switchToConverted,
                "context=\(context) margin=\(result.confidenceMargin) evidence=\(result.evidence)"
            )
        }
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

    func testPunctuationTranslatesWithPhysicalKeyWhenBothSidesArePunctuation() {
        let result = evaluate(
            "ыцшесрштп,",
            current: "ru",
            target: "en",
            context: ["this", "text"]
        )
        XCTAssertEqual(result.decision.candidate.replacement, "switching?")
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
    }

    func testEnglishQuestionKeyBecomesRussianCommaWithConvertedWord() {
        let result = evaluate(
            "ghbitk?",
            converted: "пришел,",
            context: ["он"]
        )
        XCTAssertEqual(result.decision.candidate.replacement, "пришел,")
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
    }

    func testEnglishAmpersandKeyBecomesRussianQuestionMarkWithConvertedWord() {
        let result = evaluate(
            "ghbitk&",
            converted: "пришел?",
            context: ["он"]
        )
        XCTAssertEqual(result.decision.candidate.replacement, "пришел?")
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
    }

    func testWrappedPhysicalQuestionMarkUsesTargetLayout() {
        let result = evaluate("{gjregfntkm&", context: ["этот"])
        XCTAssertEqual(result.decision.candidate.replacement, "{покупатель?")
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
    }

    func testSingleUppercaseCyrillicLetterStaysUnchanged() {
        let result = evaluate("А", current: "ru", target: "en")
        XCTAssertEqual(result.decision.verdict, .keep)
        XCTAssertEqual(result.decision.candidate.replacement, "F")
        XCTAssertEqual(result.decision.reason, .blockedCodeLike)
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
        XCTAssertEqual(result.decision.candidate.replacement, "{удали,")
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
    }

    func testLongestKnownPunctuationSuffixWins() {
        let result = evaluate("htpekmnfn?!", context: ["это"])
        XCTAssertEqual(result.decision.candidate.replacement, "результат?!")
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
    }

    func testNaturalMultiMarkSuffixWinsAcrossPhysicalLayouts() {
        let russianQuestion = evaluate("htpekmnfn&!", context: ["это"])
        XCTAssertEqual(russianQuestion.decision.candidate.replacement, "результат?!")
        XCTAssertEqual(russianQuestion.decision.verdict, .switchToConverted)

        let englishQuestion = evaluate(
            "дшту,!",
            current: "ru",
            target: "en",
            context: ["this"]
        )
        XCTAssertEqual(englishQuestion.decision.candidate.replacement, "line?!")
        XCTAssertEqual(englishQuestion.decision.verdict, .switchToConverted)

        let ellipsis = evaluate("ghjdthrf///", context: ["это"])
        XCTAssertEqual(ellipsis.decision.candidate.replacement, "проверка...")
        XCTAssertEqual(ellipsis.decision.verdict, .switchToConverted)
    }

    func testFrequentWrappedTargetBeatsBloomOnlyDirectTarget() {
        let fixtures = [
            ("[yt", "[не"),
            ("{yt)", "{не)"),
            ("[yt///", "[не..."),
            ("jy]", "он]"),
            ("rfr}", "как}"),
            ("lj;", "до;"),
            ("(lj;", "(до;"),
            ("«lj,", "«до,"),
        ]
        for (typed, expected) in fixtures {
            let result = evaluate(typed, context: ["это"])
            XCTAssertEqual(result.decision.candidate.replacement, expected, typed)
            XCTAssertEqual(result.decision.verdict, .switchToConverted, typed)
        }
    }

    func testKnownEnglishCompoundStillConvertsFromRussianLayout() {
        let result = evaluate(
            "лунищфкв",
            current: "ru",
            target: "en",
            context: ["this", "input"]
        )
        XCTAssertEqual(result.decision.candidate.replacement, "keyboard")
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
    }

    func testLayoutLetterBeforeDecorationStaysLetter() {
        let result = evaluate("gkfn`;-", context: ["это"])
        XCTAssertEqual(result.decision.candidate.replacement, "платёж-")
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
    }

    func testTypedPunctuationWinsWhenBothInterpretationsAreWords() {
        for (typed, expected) in [("b[", "и["), ("xnj,", "что,")] {
            let result = evaluate(typed, context: ["это"])
            XCTAssertEqual(result.decision.candidate.replacement, expected, typed)
            XCTAssertEqual(result.decision.verdict, .switchToConverted, typed)
        }
    }

    func testBothKnownWordAndPunctuationInterpretationsAbstainWithoutEvidence() {
        let result = evaluate("yjxm.", context: ["это"])
        XCTAssertEqual(KeyMapping.convert("yjxm."), "ночью")
        XCTAssertEqual(result.decision.verdict, .undecided)
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

    func testConfirmedPairOverridesPriorNegativeBias() {
        let result = evaluate("cegthcgbyf", confirmed: true, adaptiveBias: -20)
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
        XCTAssertEqual(result.decision.reason, .confirmedByUser)
    }

    func testConfirmedCandidateIsNotFilteredByFrequentAlternative() {
        let typed = "yt,"
        let converted = KeyMapping.convert(typed)
        let confirmedReplacement = converted
        let result = LayoutDecoder.evaluate(
            typed: typed,
            converted: converted,
            currentLanguage: "en",
            targetLanguage: "ru",
            capsLock: false,
            contextWords: [],
            languageBelief: .neutral,
            policy: .empty,
            isConfirmed: { _, replacement in replacement == confirmedReplacement },
            model: model
        )
        XCTAssertEqual(result.decision.candidate.replacement, confirmedReplacement)
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

    func testOpeningBracketAtWordEndRemainsTargetLayoutLetter() {
        var russianBelief = LanguageBelief.neutral
        for _ in 0..<3 { russianBelief.observe(language: "ru") }
        let result = evaluate(
            "dct[",
            context: ["кампании", "и", "против"],
            belief: russianBelief
        )
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
        XCTAssertEqual(result.decision.candidate.replacement, "всех")
    }

    func testLeadingApostropheCanRemainTargetLayoutLetter() {
        var russianBelief = LanguageBelief.neutral
        for _ in 0..<4 { russianBelief.observe(language: "ru") }
        let result = evaluate(
            "'njuj",
            context: ["И", "если", "да", "кто", "от"],
            belief: russianBelief
        )
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
        XCTAssertEqual(result.decision.candidate.replacement, "этого")
    }

    func testRussianColonUsesTargetPhysicalPunctuation() {
        var russianBelief = LanguageBelief.neutral
        for _ in 0..<4 { russianBelief.observe(language: "ru") }
        let result = evaluate(
            "Byljytpbb^",
            context: ["Мигранты", "направили", "это", "письмо", "президенту"],
            belief: russianBelief
        )
        XCTAssertEqual(
            result.decision.verdict,
            .switchToConverted,
            "candidate=\(result.decision.candidate.replacement) reason=\(result.decision.reason) evidence=\(result.evidence)"
        )
        XCTAssertEqual(result.decision.candidate.replacement, "Индонезии:")
    }

    func testTargetCommaAfterClosingGuillemetIsConverted() {
        var russianBelief = LanguageBelief.neutral
        for _ in 0..<4 { russianBelief.observe(language: "ru") }
        let result = evaluate(
            "ltzntktq»?",
            context: ["политических", "изданий", "сайтов", "депутатов", "политических"],
            belief: russianBelief
        )
        XCTAssertEqual(result.decision.verdict, .switchToConverted)
        XCTAssertEqual(result.decision.candidate.replacement, "деятелей»,")
    }

    func testExtendedLatinWordDoesNotBecomeMixedCyrillic() {
        let result = evaluate("Hégire", context: ["the", "newspaper"])
        XCTAssertNotEqual(result.decision.verdict, .switchToConverted)
    }

    func testUnknownLatinProperNameStaysInEnglishContext() {
        var englishBelief = LanguageBelief.neutral
        englishBelief.observe(language: "en")
        englishBelief.observe(language: "en")
        for word in ["Polska", "Ofcom"] {
            let result = evaluate(
                word,
                context: ["the", "report"],
                belief: englishBelief
            )
            XCTAssertNotEqual(result.decision.verdict, .switchToConverted, word)
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
