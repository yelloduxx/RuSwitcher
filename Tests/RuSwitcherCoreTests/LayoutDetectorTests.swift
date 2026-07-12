import XCTest
@testable import RuSwitcherCore

final class LayoutDetectorTests: XCTestCase {
    func testShortRussianFrequentWordConverts() {
        let candidate = AutoConvertCandidate(
            typedRaw: "b",
            convertedRaw: "и",
            convertedWord: "и",
            suffix: "",
            kind: .directWord
        )

        let decision = LayoutDetector.decide(
            candidate: candidate,
            currentLang: "en",
            otherLang: "ru",
            capsLock: false,
            policy: .empty,
            isCurrentWordValid: false,
            isConvertedWordValid: false
        )

        XCTAssertEqual(decision.verdict, .switchToConverted)
        XCTAssertEqual(decision.reason, .frequentShort)
    }

    func testConvertedFrequentShortWinsWhenSystemDictionaryTreatsSourceLetterAsValid() {
        let candidate = AutoConvertCandidate(
            typedRaw: "b",
            convertedRaw: "и",
            convertedWord: "и",
            suffix: "",
            kind: .directWord
        )

        let decision = LayoutDetector.decide(
            candidate: candidate,
            currentLang: "en",
            otherLang: "ru",
            capsLock: false,
            policy: .empty,
            isCurrentWordValid: true,
            isConvertedWordValid: false
        )

        XCTAssertEqual(decision.verdict, .switchToConverted)
        XCTAssertEqual(decision.reason, .frequentShort)
    }

    func testAnotherShortRussianFrequentWordConverts() {
        let candidate = AutoConvertCandidate(
            typedRaw: "z",
            convertedRaw: "я",
            convertedWord: "я",
            suffix: "",
            kind: .directWord
        )

        let decision = LayoutDetector.decide(
            candidate: candidate,
            currentLang: "en",
            otherLang: "ru",
            capsLock: false,
            policy: .empty,
            isCurrentWordValid: false,
            isConvertedWordValid: false
        )

        XCTAssertEqual(decision.verdict, .switchToConverted)
        XCTAssertEqual(decision.reason, .frequentShort)
    }

    func testSingleUppercaseLatinLetterDoesNotConvertToFrequentShortWord() {
        let candidate = AutoConvertCandidate(
            typedRaw: "B",
            convertedRaw: "И",
            convertedWord: "И",
            suffix: "",
            kind: .directWord
        )

        let decision = LayoutDetector.decide(
            candidate: candidate,
            currentLang: "en",
            otherLang: "ru",
            capsLock: true,
            policy: .empty,
            isCurrentWordValid: true,
            isConvertedWordValid: false
        )

        XCTAssertEqual(decision.verdict, .undecided)
        XCTAssertEqual(decision.reason, .blockedCodeLike)
    }

    func testSingleUppercaseCyrillicLetterDoesNotConvertToLatin() {
        let candidate = AutoConvertCandidate(
            typedRaw: "А",
            convertedRaw: "F",
            convertedWord: "F",
            suffix: "",
            kind: .directWord
        )
        let result = LayoutDetector.decide(
            candidate: candidate,
            currentLang: "ru",
            otherLang: "en",
            capsLock: false,
            policy: .empty,
            isCurrentWordValid: true,
            isConvertedWordValid: true
        )
        XCTAssertNotEqual(result.verdict, .switchToConverted)
        XCTAssertEqual(result.reason, .blockedCodeLike)
    }

    func testSingleLowercaseLatinLetterDoesNotConvertAfterLatinWord() {
        let candidate = AutoConvertCandidate(
            typedRaw: "b",
            convertedRaw: "и",
            convertedWord: "и",
            suffix: "",
            kind: .directWord
        )

        let decision = LayoutDetector.decide(
            candidate: candidate,
            currentLang: "en",
            otherLang: "ru",
            capsLock: false,
            policy: .empty,
            isCurrentWordValid: true,
            isConvertedWordValid: false,
            context: AutoConvertContext(previousWord: "plan")
        )

        XCTAssertEqual(decision.verdict, .keep)
        XCTAssertEqual(decision.reason, .blockedContext)
    }

    func testSingleLowercaseLatinLetterConvertsAfterCyrillicWord() {
        let candidate = AutoConvertCandidate(
            typedRaw: "b",
            convertedRaw: "и",
            convertedWord: "и",
            suffix: "",
            kind: .directWord
        )

        let decision = LayoutDetector.decide(
            candidate: candidate,
            currentLang: "en",
            otherLang: "ru",
            capsLock: false,
            policy: .empty,
            isCurrentWordValid: true,
            isConvertedWordValid: false,
            context: AutoConvertContext(previousWord: "план")
        )

        XCTAssertEqual(decision.verdict, .switchToConverted)
        XCTAssertEqual(decision.reason, .frequentShort)
    }

    func testEnglishShortWordsAreProtectedInEnglishContext() {
        let candidate = AutoConvertCandidate(
            typedRaw: "i",
            convertedRaw: "ш",
            convertedWord: "ш",
            suffix: "",
            kind: .directWord
        )

        let decision = LayoutDetector.decide(
            candidate: candidate,
            currentLang: "en",
            otherLang: "ru",
            capsLock: false,
            policy: .empty,
            isCurrentWordValid: true,
            isConvertedWordValid: false
        )

        XCTAssertEqual(decision.verdict, .keep)
        XCTAssertEqual(decision.reason, .keepCurrentWord)
    }

    func testNeverConvertBlocksConvertedWord() {
        let candidate = AutoConvertCandidate(
            typedRaw: "b",
            convertedRaw: "и",
            convertedWord: "и",
            suffix: "",
            kind: .directWord
        )
        let policy = AutoConvertPolicy(neverConvert: ["и"], alwaysConvert: [])

        let decision = LayoutDetector.decide(
            candidate: candidate,
            currentLang: "en",
            otherLang: "ru",
            capsLock: false,
            policy: policy,
            isCurrentWordValid: false,
            isConvertedWordValid: false
        )

        XCTAssertEqual(decision.verdict, .keep)
        XCTAssertEqual(decision.reason, .blockedNever)
    }

    func testAlwaysConvertOverridesDictionaryMiss() {
        let candidate = AutoConvertCandidate(
            typedRaw: "ghbdtn",
            convertedRaw: "привет",
            convertedWord: "привет",
            suffix: "",
            kind: .directWord
        )
        let policy = AutoConvertPolicy(neverConvert: [], alwaysConvert: ["привет"])

        let decision = LayoutDetector.decide(
            candidate: candidate,
            currentLang: "en",
            otherLang: "ru",
            capsLock: false,
            policy: policy,
            isCurrentWordValid: false,
            isConvertedWordValid: false
        )

        XCTAssertEqual(decision.verdict, .switchToConverted)
        XCTAssertEqual(decision.reason, .alwaysConvert)
    }

    func testLongObviousScriptMismatchConverts() {
        let candidate = AutoConvertCandidate(
            typedRaw: "asdfghjk",
            convertedRaw: "фывапрол",
            convertedWord: "фывапрол",
            suffix: "",
            kind: .directWord
        )

        let decision = LayoutDetector.decide(
            candidate: candidate,
            currentLang: "en",
            otherLang: "ru",
            capsLock: false,
            policy: .empty,
            isCurrentWordValid: false,
            isConvertedWordValid: false
        )

        XCTAssertEqual(decision.verdict, .switchToConverted)
        XCTAssertEqual(decision.reason, .scriptScore)
    }

    func testUnknownCyrillicWordDoesNotConvertToLatinByScriptScoreOnly() {
        let candidate = AutoConvertCandidate(
            typedRaw: "жцщшдф",
            convertedRaw: "zxcvbn",
            convertedWord: "zxcvbn",
            suffix: "",
            kind: .directWord
        )

        let decision = LayoutDetector.decide(
            candidate: candidate,
            currentLang: "ru",
            otherLang: "en",
            capsLock: false,
            policy: .empty,
            isCurrentWordValid: false,
            isConvertedWordValid: false
        )

        XCTAssertEqual(decision.verdict, .undecided)
        XCTAssertEqual(decision.reason, .undecided)
    }

    func testCyrillicToLatinDictionaryWordDoesNotConvertInsideCyrillicContext() {
        let candidate = AutoConvertCandidate(
            typedRaw: "руддщ",
            convertedRaw: "hello",
            convertedWord: "hello",
            suffix: "",
            kind: .directWord
        )

        let decision = LayoutDetector.decide(
            candidate: candidate,
            currentLang: "ru",
            otherLang: "en",
            capsLock: false,
            policy: .empty,
            isCurrentWordValid: false,
            isConvertedWordValid: true,
            context: AutoConvertContext(previousWord: "это")
        )

        XCTAssertEqual(decision.verdict, .keep)
        XCTAssertEqual(decision.reason, .blockedContext)
    }

    func testCyrillicToLatinDictionaryWordStillConvertsWithoutCyrillicContext() {
        let candidate = AutoConvertCandidate(
            typedRaw: "руддщ",
            convertedRaw: "hello",
            convertedWord: "hello",
            suffix: "",
            kind: .directWord
        )

        let decision = LayoutDetector.decide(
            candidate: candidate,
            currentLang: "ru",
            otherLang: "en",
            capsLock: false,
            policy: .empty,
            isCurrentWordValid: false,
            isConvertedWordValid: true
        )

        XCTAssertEqual(decision.verdict, .switchToConverted)
        XCTAssertTrue([.dictionary, .frequentWord].contains(decision.reason))
    }

    func testCodeLikeWordsStayUnchanged() {
        let candidate = AutoConvertCandidate(
            typedRaw: "myURL",
            convertedRaw: "ьнГКД",
            convertedWord: "ьнГКД",
            suffix: "",
            kind: .directWord
        )

        let decision = LayoutDetector.decide(
            candidate: candidate,
            currentLang: "en",
            otherLang: "ru",
            capsLock: false,
            policy: .empty,
            isCurrentWordValid: false,
            isConvertedWordValid: false
        )

        XCTAssertEqual(decision.verdict, .undecided)
        XCTAssertEqual(decision.reason, .blockedCodeLike)
    }

    func testDomainLikeWordsStayUnchanged() {
        let candidate = AutoConvertCandidate(
            typedRaw: "example.com",
            convertedRaw: "учфьздуюсщь",
            convertedWord: "учфьздуюсщь",
            suffix: "",
            kind: .directWord
        )

        let decision = LayoutDetector.decide(
            candidate: candidate,
            currentLang: "en",
            otherLang: "ru",
            capsLock: false,
            policy: .empty,
            isCurrentWordValid: false,
            isConvertedWordValid: false
        )

        XCTAssertEqual(decision.verdict, .undecided)
        XCTAssertEqual(decision.reason, .blockedCodeLike)
    }

    func testEmailLikeWordsStayUnchanged() {
        let candidate = AutoConvertCandidate(
            typedRaw: "me@example.com",
            convertedRaw: "ьуАучфьздуюсщь",
            convertedWord: "ьуАучфьздуюсщь",
            suffix: "",
            kind: .directWord
        )

        let decision = LayoutDetector.decide(
            candidate: candidate,
            currentLang: "en",
            otherLang: "ru",
            capsLock: false,
            policy: .empty,
            isCurrentWordValid: false,
            isConvertedWordValid: false
        )

        XCTAssertEqual(decision.verdict, .undecided)
        XCTAssertEqual(decision.reason, .blockedCodeLike)
    }

    func testAllCapsAcronymsStayUnchangedWhenCapsLockIsOff() {
        let candidate = AutoConvertCandidate(
            typedRaw: "NASA",
            convertedRaw: "ТФЫФ",
            convertedWord: "тфыф",
            suffix: "",
            kind: .directWord
        )

        let decision = LayoutDetector.decide(
            candidate: candidate,
            currentLang: "en",
            otherLang: "ru",
            capsLock: false,
            policy: .empty,
            isCurrentWordValid: false,
            isConvertedWordValid: false
        )

        XCTAssertEqual(decision.verdict, .undecided)
        XCTAssertEqual(decision.reason, .blockedCodeLike)
    }
}
