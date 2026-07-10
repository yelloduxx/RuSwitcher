import XCTest
@testable import RuSwitcherCore

final class CorpusQualityTests: XCTestCase {
    private func evaluate(
        typed: String,
        current: String,
        target: String,
        context: [String]
    ) -> LayoutVerdict {
        SmartAutoConvertEngine.evaluate(
            typed: typed,
            converted: KeyMapping.convert(typed),
            currentLanguage: current,
            targetLanguage: target,
            capsLock: false,
            contextWords: context,
            policy: .empty,
            isValidWord: { word, language in
                FrequentWordLexicon.contains(word, language: language)
            }
        ).decision.verdict
    }

    func testCorrectFrequentWordsHaveVeryLowFalsePositiveRate() {
        var total = 0
        var falsePositives = 0
        let suffixes = ["", ".", ",", "!", "?", ";"]
        for (language, target, contexts) in [
            ("ru", "en", [
                ["это", "обычный", "текст"], ["мы", "сейчас", "пишем"], ["мой", "новый", "план"],
                ["в", "этом", "проекте"], ["спасибо", "за", "ответ"], ["сегодня", "будет", "работа"],
                ["я", "думаю", "что"], ["для", "этой", "системы"], ["можно", "сказать", "так"], [],
            ]),
            ("en", "ru", [
                ["this", "is", "text"], ["we", "are", "writing"], ["my", "new", "plan"],
                ["in", "this", "project"], ["thank", "you", "for"], ["today", "we", "work"],
                ["i", "think", "that"], ["for", "this", "system"], ["you", "can", "say"], [],
            ]),
        ] {
            for context in contexts {
                for suffix in suffixes {
                    for word in FrequentWordLexicon.trainingWords(language: language) {
                        total += 1
                        if evaluate(typed: word + suffix, current: language, target: target, context: context) == .switchToConverted {
                            falsePositives += 1
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(total, 10_000)
        XCTAssertEqual(falsePositives, 0)
    }

    func testWrongLayoutFrequentWordsReachRecallFloor() {
        let russian = FrequentWordLexicon.trainingWords(language: "ru").filter { $0.count >= 2 }
        let english = FrequentWordLexicon.trainingWords(language: "en").filter { $0.count >= 2 }

        let ruHits = russian.filter { word in
            let wrongLayout = KeyMapping.convert(word)
            return evaluate(typed: wrongLayout, current: "en", target: "ru", context: ["это", "русский", "текст"]) == .switchToConverted
        }.count
        let enHits = english.filter { word in
            let wrongLayout = KeyMapping.convert(word)
            return evaluate(typed: wrongLayout, current: "ru", target: "en", context: ["this", "is", "english"]) == .switchToConverted
        }.count

        XCTAssertGreaterThanOrEqual(Double(ruHits) / Double(russian.count), 0.95)
        XCTAssertGreaterThanOrEqual(Double(enHits) / Double(english.count), 0.95)
    }
}
