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

    func testRapidAlternatingPhraseUsesProvisionalSessionContext() throws {
        struct LiveStep {
            let typed: String
            let sourceLanguage: String
            let expected: String
            let shouldSwitch: Bool
        }

        let steps = [
            LiveStep(typed: "Куыуфкср", sourceLanguage: "ru", expected: "Research", shouldSwitch: true),
            LiveStep(typed: "&", sourceLanguage: "en", expected: "&", shouldSwitch: false),
            LiveStep(typed: "Вумудщзьуте", sourceLanguage: "ru", expected: "Development", shouldSwitch: true),
            LiveStep(typed: "hf,jnftn", sourceLanguage: "en", expected: "работает", shouldSwitch: true),
            LiveStep(typed: "в", sourceLanguage: "ru", expected: "в", shouldSwitch: false),
            LiveStep(typed: "RU,", sourceLanguage: "en", expected: "RU,", shouldSwitch: false),
            LiveStep(typed: "иге", sourceLanguage: "ru", expected: "but", shouldSwitch: true),
            LiveStep(typed: "stays", sourceLanguage: "en", expected: "stays", shouldSwitch: false),
            LiveStep(typed: "шт", sourceLanguage: "ru", expected: "in", shouldSwitch: true),
            LiveStep(typed: "EN.", sourceLanguage: "en", expected: "EN.", shouldSwitch: false),
        ]
        let focus = FocusedElementIdentity(processID: 42, bundleID: "test.host")
        var session = InputSession(contextLimit: InputContextLimits.maximumTokens)
        var resolved: [String] = []

        for step in steps {
            for character in step.typed {
                session.append(TypedKey(
                    keyCode: 0,
                    shift: character.isUppercase,
                    caps: false,
                    producedText: String(character),
                    sourceLayoutID: step.sourceLanguage
                ))
            }
            let snapshot = try XCTUnwrap(session.snapshot(boundary: .space(count: 1), focus: focus))
            XCTAssertTrue(session.beginCommit(expectedRevision: snapshot.editRevision))
            let targetLanguage = step.sourceLanguage == "ru" ? "en" : "ru"
            let evaluation = LayoutDecoder.evaluate(
                typed: step.typed,
                converted: KeyMapping.convert(step.typed),
                currentLanguage: step.sourceLanguage,
                targetLanguage: targetLanguage,
                capsLock: false,
                contextWords: snapshot.context.map(\.text),
                languageBelief: snapshot.languageBelief,
                policy: .empty,
                model: model
            )
            let switched = evaluation.decision.verdict == .switchToConverted
            let text = switched ? evaluation.decision.candidate.replacement : step.typed
            XCTAssertEqual(switched, step.shouldSwitch, step.typed)
            XCTAssertEqual(text, step.expected, step.typed)
            resolved.append(text)

            if switched {
                session.stageCompletion(
                    resolvedText: text,
                    language: targetLanguage,
                    wasConverted: true
                )
            } else {
                session.complete(
                    resolvedText: text,
                    language: step.sourceLanguage,
                    wasConverted: false
                )
            }
        }

        XCTAssertEqual(resolved.joined(separator: " "), "Research & Development работает в RU, but stays in EN.")
    }
}
