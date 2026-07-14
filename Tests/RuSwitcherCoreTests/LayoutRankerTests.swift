import XCTest
@testable import RuSwitcherCore

final class LayoutRankerTests: XCTestCase {
    private let languageModel = try! XCTUnwrap(LanguageModelStore.bundled)

    func testRuntimeFeatureSchemaIsFiniteAndMatchesEveryLatticePath() {
        let context = LayoutRankerContext(
            typed: "ghbitk?",
            converted: "пришел,",
            currentLanguage: "en",
            targetLanguage: "ru",
            contextWords: ["он", "снова"],
            languageBelief: russianBelief
        )
        let items = LayoutRankerFeatureSchema.extract(context: context, model: languageModel)

        XCTAssertEqual(items.first?.hypothesis.kind, .literal)
        XCTAssertTrue(items.contains { $0.hypothesis.text == "пришел," })
        XCTAssertTrue(items.allSatisfy {
            $0.features.count == LayoutRankerFeatureSchema.names.count
                && $0.features.allSatisfy(\.isFinite)
        })
    }

    func testHighConversionMarginSwitchesAndCalibratedThresholdCanAbstain() throws {
        let items = LayoutRankerFeatureSchema.extract(
            context: LayoutRankerContext(
                typed: "ghbdtn",
                converted: "привет",
                currentLanguage: "en",
                targetLanguage: "ru",
                contextWords: ["это"],
                languageBelief: russianBelief
            ),
            model: languageModel
        )
        var weights = Array(repeating: 0.0, count: LayoutRankerFeatureSchema.names.count)
        weights[index("isDirect")] = 8

        let active = try LayoutRankerModel(artifact: artifact(weights: weights, threshold: 0.1))
        XCTAssertEqual(active.predict(items: items).action, .switchLayout)

        let cautious = try LayoutRankerModel(artifact: artifact(weights: weights, threshold: 1.0))
        XCTAssertEqual(cautious.predict(items: items).action, .abstain)
    }

    func testCharacterFeaturesDistinguishLexicalStructureWithoutWordRules() throws {
        let first = LayoutRankerFeatureSchema.extract(
            context: LayoutRankerContext(
                typed: "руку",
                converted: "here",
                currentLanguage: "ru",
                targetLanguage: "en",
                contextWords: [],
                languageBelief: .neutral
            ),
            model: languageModel
        )
        let second = LayoutRankerFeatureSchema.extract(
            context: LayoutRankerContext(
                typed: "руки",
                converted: "herb",
                currentLanguage: "ru",
                targetLanguage: "en",
                contextWords: [],
                languageBelief: .neutral
            ),
            model: languageModel
        )
        let firstLiteral = try XCTUnwrap(first.first)
        let secondLiteral = try XCTUnwrap(second.first)
        let firstConverted = try XCTUnwrap(first.first(where: { !$0.hypothesis.isLiteral }))
        let secondConverted = try XCTUnwrap(second.first(where: { !$0.hypothesis.isLiteral }))

        XCTAssertNotEqual(
            Array(firstLiteral.features[featureRange(prefix: "candidateRUCharHash")]),
            Array(secondLiteral.features[featureRange(prefix: "candidateRUCharHash")])
        )
        XCTAssertNotEqual(
            Array(firstConverted.features[featureRange(prefix: "candidateENCharHash")]),
            Array(secondConverted.features[featureRange(prefix: "candidateENCharHash")])
        )
    }

    func testCandidateConditionedContextFeaturesChangeWithPreviousWords() throws {
        let first = try XCTUnwrap(LayoutRankerFeatureSchema.extract(
            context: LayoutRankerContext(
                typed: "j,",
                converted: "об",
                currentLanguage: "en",
                targetLanguage: "ru",
                contextWords: ["думаю"],
                languageBelief: russianBelief
            ),
            model: languageModel
        ).first(where: { !$0.hypothesis.isLiteral }))
        let second = try XCTUnwrap(LayoutRankerFeatureSchema.extract(
            context: LayoutRankerContext(
                typed: "j,",
                converted: "об",
                currentLanguage: "en",
                targetLanguage: "ru",
                contextWords: ["позаботься"],
                languageBelief: russianBelief
            ),
            model: languageModel
        ).first(where: { !$0.hypothesis.isLiteral }))

        XCTAssertNotEqual(
            Array(first.features[featureRange(prefix: "candidateRUContextHash")]),
            Array(second.features[featureRange(prefix: "candidateRUContextHash")])
        )
    }

    func testLiteralWinnerAlwaysKeeps() throws {
        let items = LayoutRankerFeatureSchema.extract(
            context: LayoutRankerContext(
                typed: "hello",
                converted: "руддщ",
                currentLanguage: "en",
                targetLanguage: "ru",
                contextWords: ["say"],
                languageBelief: .neutral
            ),
            model: languageModel
        )
        var weights = Array(repeating: 0.0, count: LayoutRankerFeatureSchema.names.count)
        weights[index("isLiteral")] = 8
        let ranker = try LayoutRankerModel(artifact: artifact(weights: weights, threshold: 0))

        XCTAssertEqual(ranker.predict(items: items).action, .keep)
    }

    func testArtifactRejectsFeatureDrift() {
        let invalid = LayoutRankerArtifact(
            modelVersion: "test",
            featureSchemaVersion: LayoutRankerFeatureSchema.version,
            featureNames: ["different"],
            weights: [0],
            temperature: 1,
            thresholds: thresholds(0),
            trainingManifestSHA256: "test",
            trainExamples: 1,
            validationExamples: 1
        )
        XCTAssertThrowsError(try LayoutRankerModel(artifact: invalid)) { error in
            XCTAssertEqual(error as? LayoutRankerError, .incompatibleFeatures)
        }
    }

    func testCompactHiddenLayerScoresCandidates() throws {
        let items = LayoutRankerFeatureSchema.extract(
            context: LayoutRankerContext(
                typed: "ghbdtn",
                converted: "привет",
                currentLanguage: "en",
                targetLanguage: "ru",
                contextWords: ["это"],
                languageBelief: russianBelief
            ),
            model: languageModel
        )
        var hidden = Array(repeating: 0.0, count: LayoutRankerFeatureSchema.names.count)
        hidden[index("isDirect")] = 4
        let model = try LayoutRankerModel(artifact: LayoutRankerArtifact(
            formatVersion: 2,
            modelVersion: "test-mlp",
            featureSchemaVersion: LayoutRankerFeatureSchema.version,
            featureNames: LayoutRankerFeatureSchema.names,
            weights: Array(repeating: 0, count: hidden.count),
            hiddenWeights: [hidden],
            hiddenBias: [0],
            outputWeights: [8],
            temperature: 1,
            thresholds: thresholds(0.1),
            trainingManifestSHA256: "test",
            trainExamples: 1,
            validationExamples: 1
        ))

        XCTAssertEqual(model.predict(items: items).action, .switchLayout)
    }

    func testHiddenLayerRejectsInvalidDimensions() {
        let invalid = LayoutRankerArtifact(
            formatVersion: 2,
            modelVersion: "test-mlp",
            featureSchemaVersion: LayoutRankerFeatureSchema.version,
            featureNames: LayoutRankerFeatureSchema.names,
            weights: Array(repeating: 0, count: LayoutRankerFeatureSchema.names.count),
            hiddenWeights: [[0]],
            hiddenBias: [0],
            outputWeights: [1],
            temperature: 1,
            thresholds: thresholds(0),
            trainingManifestSHA256: "test",
            trainExamples: 1,
            validationExamples: 1
        )

        XCTAssertThrowsError(try LayoutRankerModel(artifact: invalid)) { error in
            XCTAssertEqual(error as? LayoutRankerError, .invalidWeights)
        }
    }

    private var russianBelief: LanguageBelief {
        var belief = LanguageBelief.neutral
        belief.observe(language: "ru")
        belief.observe(language: "ru")
        return belief
    }

    private func index(_ name: String) -> Int {
        try! XCTUnwrap(LayoutRankerFeatureSchema.names.firstIndex(of: name))
    }

    private func featureRange(prefix: String) -> Range<Int> {
        let indices = LayoutRankerFeatureSchema.names.indices.filter {
            LayoutRankerFeatureSchema.names[$0].hasPrefix(prefix)
        }
        return indices.first!..<(indices.last! + 1)
    }

    private func artifact(weights: [Double], threshold: Double) -> LayoutRankerArtifact {
        LayoutRankerArtifact(
            modelVersion: "test",
            featureSchemaVersion: LayoutRankerFeatureSchema.version,
            featureNames: LayoutRankerFeatureSchema.names,
            weights: weights,
            temperature: 1,
            thresholds: thresholds(threshold),
            trainingManifestSHA256: "test",
            trainExamples: 1,
            validationExamples: 1
        )
    }

    private func thresholds(_ value: Double) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: LayoutRankerRisk.allCases.map { ($0.rawValue, value) })
    }
}
