import XCTest
@testable import RuSwitcherCore

final class ContextualLayoutModelTests: XCTestCase {
    func testBundledModelLoadsAndProducesFiniteOutputs() throws {
        let model = try XCTUnwrap(ContextualLayoutModel.bundled)
        let manifest = model.manifest
        let output = try model.score(
            byteIDs: Array(
                repeating: Array(repeating: 0, count: manifest.maximumBytes),
                count: manifest.maximumCandidates
            ),
            features: Array(
                repeating: Array(repeating: 0, count: manifest.featureCount),
                count: manifest.maximumCandidates
            )
        )
        XCTAssertEqual(output.logits.count, manifest.maximumCandidates)
        XCTAssertEqual(output.embeddings.count, manifest.maximumCandidates)
        XCTAssertEqual(output.embeddings.first?.count, manifest.embeddingSize)
        XCTAssertTrue(output.logits.allSatisfy(\.isFinite))
        XCTAssertLessThan(output.latencyMilliseconds, 100)
    }

    func testBundledModelProtectsBothKnownAmbiguity() throws {
        let scorer = try XCTUnwrap(ContextualLayoutModel.bundled)
        let lexical = try XCTUnwrap(LanguageModelStore.bundled)
        let focus = FocusedElementIdentity(processID: 1, bundleID: "tests")

        func evaluate(_ context: [String]) -> V4Evaluation {
            ContextualLayoutDecoder.evaluate(
                typed: "here",
                converted: KeyMapping.convert("here"),
                currentLanguage: "en",
                targetLanguage: "ru",
                capsLock: false,
                context: ContextSnapshot(
                    tokens: context.map {
                        InputContextToken(text: $0, language: SmartTokenizer.languageHint(for: $0))
                    },
                    activeLayoutID: nil,
                    focus: focus,
                    editRevision: 1
                ),
                languageBelief: .neutral,
                integrity: .clean,
                policy: .empty,
                lexicalModel: lexical,
                scorer: scorer,
                adapter: nil,
                maximumLatencyMilliseconds: 100
            )
        }

        XCTAssertEqual(evaluate(["put", "it"]).outcome, .keep)
        XCTAssertEqual(evaluate(["это"]).outcome, .keep)
        let russian = evaluate(["подними"])
        XCTAssertEqual(russian.outcome, .abstain)
    }
}
