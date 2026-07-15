import XCTest
@testable import RuSwitcherCore

final class AutoConvertCandidateGeneratorTests: XCTestCase {
    func testReverseConversionRecognizesProducedPunctuation() {
        let candidates = AutoConvertCandidateGenerator.candidates(typed: "гыуб", converted: "use,")
        XCTAssertTrue(candidates.contains {
            $0.convertedWord == "use" && $0.suffix == "," && $0.replacement == "use,"
        })
    }

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

    func testWrappingPunctuationCanRemainLiteral() {
        let typed = "{gjnjv)"
        let candidates = AutoConvertCandidateGenerator.candidates(
            typed: typed,
            converted: KeyMapping.convert(typed)
        )
        XCTAssertTrue(candidates.contains {
            $0.prefix == "{"
                && $0.convertedWord == "потом"
                && $0.suffix == ")"
                && $0.replacement == "{потом)"
                && $0.kind == .wrappingPunctuation
        })
    }

    func testLeadingCommaCanStillBecomeLayoutLetter() {
        let typed = ",hfnmtd"
        let candidate = AutoConvertCandidateGenerator.bestCandidate(
            typed: typed,
            converted: KeyMapping.convert(typed),
            targetLanguage: "ru",
            isValidWord: { word, language in language == "ru" && word == "братьев" }
        )
        XCTAssertEqual(candidate?.replacement, "братьев")
        XCTAssertEqual(candidate?.prefix, "")
    }

    func testLeadingBracketCandidatesIncludeFullLayoutLetterWord() {
        let typed = "[etvjt"
        let candidates = AutoConvertCandidateGenerator.candidates(
            typed: typed,
            converted: KeyMapping.convert(typed)
        )
        XCTAssertTrue(candidates.contains { $0.replacement == "хуемое" && $0.prefix.isEmpty })
        XCTAssertTrue(candidates.contains {
            $0.prefix == "[" && $0.convertedWord == "уемое" && $0.replacement == "[уемое"
        })
    }

    func testThreeCharacterEllipsisCanStayPunctuation() {
        let typed = "штышву..."
        let candidates = AutoConvertCandidateGenerator.candidates(
            typed: typed,
            converted: KeyMapping.convert(typed)
        )
        XCTAssertTrue(candidates.contains {
            $0.convertedWord == "inside"
                && $0.suffix == "..."
                && $0.replacement == "inside..."
        })
    }

    func testPrefixAndSuffixChoicesAreIndependent() {
        let typed = "{gkfn`;..."
        let candidates = AutoConvertCandidateGenerator.candidates(
            typed: typed,
            converted: KeyMapping.convert(typed)
        )
        XCTAssertTrue(candidates.contains {
            $0.prefix == "{"
                && $0.convertedWord == "платёж"
                && $0.suffix == "..."
                && $0.replacement == "{платёж..."
        })
    }
}
