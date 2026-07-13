import XCTest
@testable import RuSwitcherCore

final class MixedPhraseDecoderTests: XCTestCase {
    private struct Step {
        let typed: String
        let manualLanguage: String?
        let expected: String
        let shouldSwitch: Bool

        init(_ typed: String, manualLanguage: String? = nil, expected: String? = nil, shouldSwitch: Bool = false) {
            self.typed = typed
            self.manualLanguage = manualLanguage
            self.expected = expected ?? typed
            self.shouldSwitch = shouldSwitch
        }
    }

    private let model = LanguageModelStore.bundled!

    private func simulate(initialLanguage: String, steps: [Step]) -> String {
        var currentLanguage = initialLanguage
        var context: [String] = []
        var belief = LanguageBelief.neutral
        var resolvedWords: [String] = []

        for step in steps {
            if let manualLanguage = step.manualLanguage { currentLanguage = manualLanguage }
            let targetLanguage = currentLanguage == "ru" ? "en" : "ru"
            let evaluation = LayoutDecoder.evaluate(
                typed: step.typed,
                converted: KeyMapping.convert(step.typed),
                currentLanguage: currentLanguage,
                targetLanguage: targetLanguage,
                capsLock: step.typed == step.typed.uppercased() && step.typed != step.typed.lowercased(),
                contextWords: context,
                languageBelief: belief,
                policy: .empty,
                model: model
            )
            let switched = evaluation.decision.verdict == .switchToConverted
            let resolved = switched ? evaluation.decision.candidate.replacement : step.typed
            XCTAssertEqual(switched, step.shouldSwitch, step.typed)
            XCTAssertEqual(resolved, step.expected, step.typed)
            resolvedWords.append(resolved)
            context.append(SmartTokenizer.lexicalCore(of: resolved))
            if context.count > 5 { context.removeFirst() }
            let resolvedLanguage = switched ? targetLanguage : currentLanguage
            belief.observe(language: resolvedLanguage, weight: switched ? 1.4 : 1.0)
            if switched { currentLanguage = targetLanguage }
        }
        return resolvedWords.joined(separator: " ")
    }

    func testRussianEnglishThenMistypedRussianPhrase() {
        XCTAssertEqual(simulate(initialLanguage: "ru", steps: [
            Step("это"), Step("обычный"), Step("use,", manualLanguage: "en"),
            Step("ghbdtn", expected: "привет", shouldSwitch: true), Step("и"), Step("текст"),
        ]), "это обычный use, привет и текст")
    }

    func testEnglishRussianThenMistypedEnglishPhrase() {
        XCTAssertEqual(simulate(initialLanguage: "en", steps: [
            Step("this"), Step("feature"), Step("привет", manualLanguage: "ru"),
            Step("руддщ", expected: "hello", shouldSwitch: true), Step("world"),
        ]), "this feature привет hello world")
    }

    func testPlanBAndPunctuationRemainProtectedInsideMixedPhrases() {
        XCTAssertEqual(simulate(initialLanguage: "ru", steps: [
            Step("сегодня"), Step("plan", manualLanguage: "en"), Step("B"),
            Step("готов", manualLanguage: "ru"),
        ]), "сегодня plan B готов")
        XCTAssertEqual(simulate(initialLanguage: "en", steps: [
            Step("ghbdtn,", expected: "привет,", shouldSwitch: true), Step("мир"),
            Step("use,", manualLanguage: "en"),
        ]), "привет, мир use,")
    }

    func testCompoundAndLayoutLetterWorkInsidePhrases() {
        XCTAssertEqual(simulate(initialLanguage: "ru", steps: [
            Step("новая"),
            Step("cegthcgbyf", manualLanguage: "en", expected: "суперспина", shouldSwitch: true),
            Step("работает"),
        ]), "новая суперспина работает")
        XCTAssertEqual(simulate(initialLanguage: "en", steps: [
            Step("htdjk.wbz", expected: "революция", shouldSwitch: true), Step("началась"),
            Step("online", manualLanguage: "en"),
        ]), "революция началась online")
    }

    func testSimpleRussianPhraseTypedInEnglishLayout() {
        XCTAssertEqual(simulate(initialLanguage: "en", steps: [
            Step("gjxtve", expected: "почему", shouldSwitch: true),
            Step("я"),
        ]), "почему я")
    }
}
