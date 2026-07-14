import XCTest
@testable import RuSwitcherCore

final class V3LayoutEngineTests: XCTestCase {
    private let languageModel = LanguageModelStore.bundled!

    func testShadowMeasuresLearnedDecisionWithoutChangingBaseline() throws {
        let evaluation = evaluate(
            typed: "cnfnm.",
            ranker: try forcedFullOppositeRanker(),
            mode: .shadow
        )

        XCTAssertEqual(evaluation.selected, evaluation.baseline)
        XCTAssertEqual(evaluation.learned?.decision.verdict, .switchToConverted)
        XCTAssertTrue(evaluation.disagrees)
    }

    func testActiveUsesLearnedPhysicalKeyCandidate() throws {
        let evaluation = evaluate(
            typed: "cnfnm.",
            ranker: try forcedFullOppositeRanker(),
            mode: .active
        )

        XCTAssertEqual(evaluation.selected.decision.verdict, .switchToConverted)
        XCTAssertEqual(evaluation.selected.decision.candidate.replacement, "статью")
    }

    func testRankerPreservesCorrectedMixedPunctuationPath() throws {
        let typed = "uhzpye."
        let converted = KeyMapping.convert(typed)
        let evaluation = evaluate(
            typed: typed,
            context: ["увидели", "очень"],
            ranker: try forcedFullOppositeRanker(),
            mode: .active
        )

        XCTAssertEqual(evaluation.baseline.decision.verdict, .switchToConverted)
        XCTAssertEqual(evaluation.baseline.decision.candidate.replacement, converted)
        XCTAssertEqual(evaluation.selected.decision.verdict, .switchToConverted)
        XCTAssertEqual(evaluation.selected.decision.candidate.replacement, converted)
    }

    func testRankerPreservesCorrectedStrongUnknownWholeLayoutPath() throws {
        let typed = ",b,kbc"
        let converted = KeyMapping.convert(typed)
        XCTAssertNil(languageModel.wordLogProbability(converted, language: "ru"))
        XCTAssertFalse(languageModel.isExtendedRussianWord(converted))

        let evaluation = evaluate(
            typed: typed,
            context: ["обсуждали", "имя"],
            ranker: try forcedFullOppositeRanker(),
            mode: .active
        )

        XCTAssertEqual(evaluation.baseline.decision.verdict, .switchToConverted)
        XCTAssertEqual(evaluation.baseline.decision.candidate.replacement, converted)
        XCTAssertEqual(evaluation.selected.decision.candidate.replacement, converted)
    }

    func testRankerCannotTurnLiteralPunctuationIntoWeakBoundaryLetters() throws {
        for (typed, expected) in [("ghbdtn,", "привет,"), ("[yt", "[не")] {
            let evaluation = evaluate(
                typed: typed,
                context: ["это", "слово"],
                ranker: try forcedFullOppositeRanker(),
                mode: .active
            )

            XCTAssertEqual(evaluation.baseline.decision.candidate.replacement, expected, typed)
            XCTAssertEqual(evaluation.selected.decision.candidate.replacement, expected, typed)
        }
    }

    func testNeverConvertCannotBeOverriddenByRanker() throws {
        let evaluation = evaluate(
            typed: "asdfgh",
            policy: AutoConvertPolicy(neverConvert: ["asdfgh"], alwaysConvert: []),
            ranker: try forcedRanker(literalWins: false),
            mode: .active
        )

        XCTAssertEqual(evaluation.selected.decision.verdict, .keep)
        XCTAssertEqual(evaluation.selected.decision.reason, .blockedNever)
    }

    func testConfirmedPairCannotBeSuppressedByRanker() throws {
        let evaluation = evaluate(
            typed: "asdfgh",
            confirmed: true,
            ranker: try forcedRanker(literalWins: true),
            mode: .active
        )

        XCTAssertEqual(evaluation.selected.decision.verdict, .switchToConverted)
        XCTAssertEqual(evaluation.selected.decision.reason, .confirmedByUser)
    }

    func testKnownSingleLetterStaysLiteral() throws {
        let evaluation = evaluate(
            typed: "a",
            currentLanguage: "en",
            targetLanguage: "ru",
            ranker: try forcedRanker(literalWins: false),
            mode: .active
        )

        XCTAssertEqual(evaluation.selected.decision.verdict, .keep)
        XCTAssertEqual(evaluation.selected.decision.reason, .keepCurrentWord)
    }

    func testBundledRankerIsCompatibleWithRuntimeSchema() throws {
        let ranker = try XCTUnwrap(LayoutRankerModel.bundled)

        XCTAssertEqual(ranker.artifact.modelVersion, "2026.07-v3.1-ranker-11")
        XCTAssertEqual(ranker.artifact.featureSchemaVersion, LayoutRankerFeatureSchema.version)
    }

    func testBundledRankerProtectsLatinCodeSwitchNamesInRussianContext() throws {
        let ranker = try XCTUnwrap(LayoutRankerModel.bundled)
        var russianBelief = LanguageBelief.neutral
        for _ in 0..<4 { russianBelief.observe(language: "ru") }
        let cases = [
            ("Polska", ["Блог"]),
            ("(Ofcom)", ["по", "коммуникациям", "Великобритании"]),
            ("Hégire", ["газета", "пишет"]),
        ]
        for (word, context) in cases {
            let evaluation = evaluate(
                typed: word,
                currentLanguage: "en",
                targetLanguage: "ru",
                context: context,
                belief: russianBelief,
                ranker: ranker,
                mode: .active
            )
            XCTAssertNotEqual(
                evaluation.selected.decision.verdict,
                .switchToConverted,
                "\(word) baseline=\(evaluation.baseline.decision.verdict) learned=\(String(describing: evaluation.learned?.decision.verdict))"
            )
        }
    }

    func testBundledRankerDoesNotTurnSocialIdentifiersIntoWords() throws {
        let ranker = try XCTUnwrap(LayoutRankerModel.bundled)
        var russianBelief = LanguageBelief.neutral
        for _ in 0..<4 { russianBelief.observe(language: "ru") }

        for token in ["@givenjoy", "#noalaleteo", "(@nightlybuild)"] {
            let evaluation = evaluate(
                typed: token,
                currentLanguage: "en",
                targetLanguage: "ru",
                context: ["это", "внешняя", "ссылка"],
                belief: russianBelief,
                ranker: ranker,
                mode: .active
            )
            XCTAssertNotEqual(
                evaluation.selected.decision.verdict,
                .switchToConverted,
                "\(token) -> \(evaluation.selected.decision.candidate.replacement)"
            )
        }
    }

    func testBundledRankerPrefersWholeLayoutForAmbiguousInflection() throws {
        let ranker = try XCTUnwrap(LayoutRankerModel.bundled)
        let intended = "статью"
        let typed = KeyMapping.convert(intended)
        var belief = LanguageBelief.neutral
        for _ in 0..<3 { belief.observe(language: "ru") }
        let context = LayoutRankerContext(
            typed: typed,
            converted: intended,
            currentLanguage: "en",
            targetLanguage: "ru",
            contextWords: ["редактор", "проверил"],
            languageBelief: belief
        )
        let items = LayoutRankerFeatureSchema.extract(context: context, model: languageModel)
        let prediction = ranker.predict(items: items)
        let winner = items[prediction.winnerIndex].hypothesis
        let risk = items[prediction.winnerIndex].risk

        if prediction.action == .switchLayout {
            XCTAssertEqual(
                winner.text,
                intended,
                "winner=\(winner.text) probability=\(prediction.winnerProbability) margin=\(prediction.winnerMargin) risk=\(risk)"
            )
        } else {
            XCTAssertEqual(prediction.action, .abstain)
            XCTAssertEqual(risk, .punctuationAmbiguous)
        }
    }

    private func evaluate(
        typed: String,
        currentLanguage: String = "en",
        targetLanguage: String = "ru",
        context: [String] = [],
        belief: LanguageBelief = .neutral,
        policy: AutoConvertPolicy = .empty,
        confirmed: Bool = false,
        ranker: LayoutRankerModel,
        mode: V3LayoutEngineMode
    ) -> V3LayoutEngineEvaluation {
        V3LayoutEngine.evaluate(
            typed: typed,
            converted: KeyMapping.convert(typed),
            currentLanguage: currentLanguage,
            targetLanguage: targetLanguage,
            capsLock: false,
            contextWords: context,
            languageBelief: belief,
            policy: policy,
            isConfirmed: { _, _ in confirmed },
            model: languageModel,
            ranker: ranker,
            mode: mode
        )
    }

    private func forcedRanker(literalWins: Bool) throws -> LayoutRankerModel {
        var weights = Array(repeating: 0.0, count: LayoutRankerFeatureSchema.names.count)
        let literal = try XCTUnwrap(LayoutRankerFeatureSchema.names.firstIndex(of: "isLiteral"))
        weights[literal] = literalWins ? 10 : -10
        return try LayoutRankerModel(artifact: LayoutRankerArtifact(
            modelVersion: "test",
            featureSchemaVersion: LayoutRankerFeatureSchema.version,
            featureNames: LayoutRankerFeatureSchema.names,
            weights: weights,
            temperature: 1,
            thresholds: Dictionary(uniqueKeysWithValues: LayoutRankerRisk.allCases.map {
                ($0.rawValue, 0.0)
            }),
            trainingManifestSHA256: "test",
            trainExamples: 1,
            validationExamples: 1
        ))
    }

    private func forcedFullOppositeRanker() throws -> LayoutRankerModel {
        var weights = Array(repeating: 0.0, count: LayoutRankerFeatureSchema.names.count)
        let fullOpposite = try XCTUnwrap(
            LayoutRankerFeatureSchema.names.firstIndex(of: "isFullOpposite")
        )
        weights[fullOpposite] = 10
        return try LayoutRankerModel(artifact: LayoutRankerArtifact(
            modelVersion: "test-full-opposite",
            featureSchemaVersion: LayoutRankerFeatureSchema.version,
            featureNames: LayoutRankerFeatureSchema.names,
            weights: weights,
            temperature: 1,
            thresholds: Dictionary(uniqueKeysWithValues: LayoutRankerRisk.allCases.map {
                ($0.rawValue, 0.0)
            }),
            trainingManifestSHA256: "test",
            trainExamples: 1,
            validationExamples: 1
        ))
    }
}
