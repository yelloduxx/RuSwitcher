import XCTest
@testable import RuSwitcherCore

final class ContextualLayoutDecoderTests: XCTestCase {
    private struct MockScorer: ContextualLayoutScoring {
        let manifest = ContextualModelManifest(
            formatVersion: 1,
            modelVersion: "test",
            modelSHA256: "",
            maximumBytes: 192,
            maximumCandidates: 6,
            featureCount: 12,
            embeddingSize: 4,
            temperature: 1,
            minimumProbability: 0.7,
            minimumMargin: 0.2,
            bothKnownProbability: 0.9,
            bothKnownMargin: 0.45,
            learningRate: 0.02,
            l2: 0.0001
        )
        let selectedIndex: Int
        let winningLogit: Float
        let latency: Double

        func score(byteIDs: [[Int32]], features: [[Float]]) throws -> ContextualModelOutput {
            var logits = Array(repeating: Float(-3), count: manifest.maximumCandidates)
            logits[selectedIndex] = winningLogit
            let embeddings = (0..<manifest.maximumCandidates).map { index in
                [Float(index), 1, -1, 0]
            }
            return ContextualModelOutput(logits: logits, embeddings: embeddings, latencyMilliseconds: latency)
        }
    }

    private let lexicalModel = LanguageModelStore.bundled!
    private let focus = FocusedElementIdentity(processID: 1, bundleID: "tests")

    private func snapshot(_ tokens: [InputContextToken]) -> ContextSnapshot {
        ContextSnapshot(tokens: tokens, activeLayoutID: nil, focus: focus, editRevision: 1)
    }

    func testEnglishContextCanKeepBothKnownLiteral() {
        let result = evaluate("here", context: ["put", "it"], selectedIndex: 0)
        XCTAssertEqual(result.outcome, .keep)
    }

    func testHighConfidenceCannotOverrideBothKnownSafetyGate() {
        let converted = KeyMapping.convert("here")
        let index = PhysicalKeyLattice.hypotheses(typed: "here", converted: converted)
            .firstIndex { $0.text == "руку" }!
        let result = evaluate("here", context: ["подними"], selectedIndex: index, winningLogit: 8)
        XCTAssertEqual(result.outcome, .abstain)
        XCTAssertTrue(result.evidence.contains(.abstained))
    }

    func testLowConfidenceAbstains() {
        let result = evaluate("here", context: ["это"], selectedIndex: 1, winningLogit: -2.85)
        XCTAssertEqual(result.outcome, .abstain)
        XCTAssertTrue(result.evidence.contains(.abstained))
    }

    func testSlowInferenceFallsBackToV3() {
        let result = evaluate("here", context: ["это"], selectedIndex: 1, winningLogit: 8, latency: 4.1)
        XCTAssertEqual(result.outcome, .fallbackV3)
    }

    func testConfirmedBothKnownPairUsesLearnedV3Override() {
        let result = evaluate("here", context: ["подними"], selectedIndex: 0, confirmed: true)
        XCTAssertEqual(result.outcome, .fallbackV3)
        XCTAssertEqual(result.fallback.decision.verdict, .switchToConverted)
        XCTAssertEqual(result.fallback.decision.reason, .confirmedByUser)
    }

    private func evaluate(
        _ typed: String,
        context words: [String],
        selectedIndex: Int,
        winningLogit: Float = 8,
        latency: Double = 0.2,
        confirmed: Bool = false
    ) -> V4Evaluation {
        let tokens = words.map { InputContextToken(text: $0, language: SmartTokenizer.languageHint(for: $0)) }
        return ContextualLayoutDecoder.evaluate(
            typed: typed,
            converted: KeyMapping.convert(typed),
            currentLanguage: "en",
            targetLanguage: "ru",
            capsLock: false,
            context: snapshot(tokens),
            languageBelief: .neutral,
            integrity: .clean,
            policy: .empty,
            isConfirmed: { _, _ in confirmed },
            lexicalModel: lexicalModel,
            scorer: MockScorer(selectedIndex: selectedIndex, winningLogit: winningLogit, latency: latency),
            adapter: nil
        )
    }
}
