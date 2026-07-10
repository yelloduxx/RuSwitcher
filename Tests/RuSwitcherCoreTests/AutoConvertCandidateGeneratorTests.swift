import XCTest
@testable import RuSwitcherCore

final class AutoConvertCandidateGeneratorTests: XCTestCase {
    func testBestCandidateKeepsLayoutLetterTailForLongFrequentWord() {
        let converted = KeyMapping.convert("ghbdtncnde.")

        let candidate = AutoConvertCandidateGenerator.bestCandidate(
            typed: "ghbdtncnde.",
            converted: converted,
            targetLanguage: "ru",
            isValidWord: { word, lang in lang == "ru" && word == "приветствую" }
        )

        XCTAssertEqual(candidate?.replacement, "приветствую")
        XCTAssertEqual(candidate?.convertedWord, "приветствую")
        XCTAssertEqual(candidate?.suffix, "")
        XCTAssertEqual(candidate?.kind, .layoutLetterTail)
    }

    func testBestCandidateTreatsTrailingCommaAsPunctuation() {
        let converted = KeyMapping.convert("ghbdtn,")

        let candidate = AutoConvertCandidateGenerator.bestCandidate(
            typed: "ghbdtn,",
            converted: converted,
            targetLanguage: "ru",
            isValidWord: { word, lang in lang == "ru" && word == "привет" }
        )

        XCTAssertEqual(candidate?.replacement, "привет,")
        XCTAssertEqual(candidate?.convertedWord, "привет")
        XCTAssertEqual(candidate?.suffix, ",")
        XCTAssertEqual(candidate?.kind, .trailingPunctuation)
    }

    func testBestCandidateTreatsTrailingPeriodAsPunctuationWhenLayoutLetterWordIsInvalid() {
        let converted = KeyMapping.convert("ghbdtn.")

        let candidate = AutoConvertCandidateGenerator.bestCandidate(
            typed: "ghbdtn.",
            converted: converted,
            targetLanguage: "ru",
            isValidWord: { word, lang in lang == "ru" && word == "привет" }
        )

        XCTAssertEqual(candidate?.replacement, "привет.")
        XCTAssertNotEqual(candidate?.replacement, "приветю")
        XCTAssertEqual(candidate?.kind, .trailingPunctuation)
    }

    func testBestCandidateKeepsTrailingLayoutLetterWhenThatWordIsValid() {
        let converted = KeyMapping.convert("ghbdtn.")

        let candidate = AutoConvertCandidateGenerator.bestCandidate(
            typed: "ghbdtn.",
            converted: converted,
            targetLanguage: "ru",
            isValidWord: { word, lang in lang == "ru" && word == "приветю" }
        )

        XCTAssertEqual(candidate?.replacement, "приветю")
        XCTAssertEqual(candidate?.suffix, "")
        XCTAssertEqual(candidate?.kind, .layoutLetterTail)
    }
}
