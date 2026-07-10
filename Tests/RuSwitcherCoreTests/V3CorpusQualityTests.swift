import XCTest
@testable import RuSwitcherCore

final class V3CorpusQualityTests: XCTestCase {
    private let model = LanguageModelStore.bundled!

    private func belief(_ language: String) -> LanguageBelief {
        var value = LanguageBelief.neutral
        value.observe(language: language)
        value.observe(language: language)
        return value
    }

    private func evaluate(
        _ typed: String,
        current: String,
        target: String,
        context: [String],
        beliefLanguage: String? = nil
    ) -> LayoutDecoderEvaluation {
        LayoutDecoder.evaluate(
            typed: typed,
            converted: KeyMapping.convert(typed),
            currentLanguage: current,
            targetLanguage: target,
            capsLock: false,
            contextWords: context,
            languageBelief: belief(beliefLanguage ?? current),
            policy: .empty,
            model: model
        )
    }

    func testFiftyThousandCorrectTokensStayBelowFalsePositiveGate() {
        let configurations: [(String, String, [[String]])] = [
            ("ru", "en", [
                ["это", "обычный"], ["мы", "сейчас"], ["мой", "новый"],
                ["в", "этом"], ["спасибо", "за"],
            ]),
            ("en", "ru", [
                ["this", "is"], ["we", "are"], ["my", "new"],
                ["in", "this"], ["thank", "you"],
            ]),
        ]
        let suffixes = ["", "."]
        var total = 0
        var falsePositives = 0

        for (current, target, contexts) in configurations {
            for word in model.trainingWords(language: current, limit: 2_500) {
                for context in contexts {
                    for suffix in suffixes {
                        total += 1
                        let result = evaluate(word + suffix, current: current, target: target, context: context)
                        if result.decision.verdict == .switchToConverted { falsePositives += 1 }
                    }
                }
            }
        }

        XCTAssertEqual(total, 50_000)
        XCTAssertLessThanOrEqual(Double(falsePositives) / Double(total), 0.002)
    }

    func testCommonWrongLayoutRecallGate() {
        func recall(source: String, target: String, context: [String]) -> Double {
            let targetWords = model.trainingWords(language: target, limit: 1_000)
                .filter { $0.count >= 2 }
            var eligible = 0
            var hits = 0
            for intended in targetWords {
                let mistyped = KeyMapping.convert(intended)
                guard SmartTokenizer.languageHint(for: mistyped) == source else { continue }
                eligible += 1
                let result = evaluate(
                    mistyped,
                    current: source,
                    target: target,
                    context: context,
                    beliefLanguage: target
                )
                if result.decision.verdict == .switchToConverted { hits += 1 }
            }
            return Double(hits) / Double(eligible)
        }

        XCTAssertGreaterThanOrEqual(recall(source: "en", target: "ru", context: ["это", "текст"]), 0.97)
        XCTAssertGreaterThanOrEqual(recall(source: "ru", target: "en", context: ["this", "text"]), 0.97)
    }

    func testProtectedCorpusHasNoConversions() {
        let fixtures = [
            "https://example.com/path", "me@example.com", "api.example.com",
            "snake_case", "camelCase", "PascalCase", "NASA", "HTTPServer",
            "foo/bar", "--option=value", "127.0.0.1", "user+tag@example.org",
        ]
        for fixture in fixtures {
            let result = evaluate(fixture, current: "en", target: "ru", context: ["this", "code"])
            XCTAssertNotEqual(result.decision.verdict, .switchToConverted, fixture)
        }
    }

    func testUnknownCompoundRecallGate() {
        let intended = [
            "суперспина", "мегапроект", "киберспорт", "нейросвязь", "автосистема",
            "видеотекст", "супергерой", "фотомодель", "ультрамир", "телестанция",
        ]
        let hits = intended.filter { word in
            let result = evaluate(
                KeyMapping.convert(word),
                current: "en",
                target: "ru",
                context: ["это", "новый"],
                beliefLanguage: "ru"
            )
            return result.decision.verdict == .switchToConverted
        }.count
        XCTAssertGreaterThanOrEqual(Double(hits) / Double(intended.count), 0.9)
    }

    func testGeneratedUnknownEnglishFormsGeneralizeWithoutWordOverrides() {
        var eligible = 0
        var hits = 0
        for stem in model.trainingWords(language: "en", limit: 1_000) {
            for suffix in ["able", "less", "ish", "like"] {
                let intended = stem + suffix
                let mistyped = KeyMapping.convert(intended)
                let advantage = model.characterLogProbability(intended, language: "en")
                    - model.characterLogProbability(mistyped, language: "ru")
                guard intended.count >= 5,
                      model.wordLogProbability(intended, language: "en") == nil,
                      model.wordLogProbability(mistyped, language: "ru") == nil,
                      advantage >= 2.2 else { continue }
                eligible += 1
                let result = evaluate(
                    mistyped,
                    current: "ru",
                    target: "en",
                    context: ["this", "text"],
                    beliefLanguage: "en"
                )
                if result.decision.verdict == .switchToConverted,
                   result.decision.candidate.replacement == intended {
                    hits += 1
                }
            }
        }

        XCTAssertGreaterThanOrEqual(eligible, 100)
        XCTAssertGreaterThanOrEqual(Double(hits) / Double(eligible), 0.98)
    }
}
