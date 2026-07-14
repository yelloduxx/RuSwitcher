import Foundation
import XCTest
@testable import RuSwitcherCore

final class PhysicalKeyLatticeTests: XCTestCase {
    func testEveryEnglishBoundaryKeyKeepsBothPhysicallyValidInterpretations() {
        for (literal, opposite) in KeyMapping.enToRu.sorted(by: { $0.key < $1.key }) {
            let strokes = lexicalPrefix + [PhysicalKeyStroke(
                literal: String(literal),
                opposite: String(opposite)
            )]
            let typed = strokes.map(\.literal).joined()
            let converted = strokes.map(\.opposite).joined()
            let candidates = PhysicalKeyLattice.candidates(
                typed: typed,
                converted: converted,
                strokes: strokes
            )

            XCTAssertTrue(candidates.contains(where: { $0.replacement == converted }), String(literal))
            if isPunctuation(literal) {
                XCTAssertTrue(candidates.contains(where: {
                    $0.convertedWord == "тест" && $0.suffix == String(literal)
                }), "literal punctuation path for \(literal) -> \(opposite)")
            }
            if isPunctuation(opposite) {
                XCTAssertTrue(candidates.contains(where: {
                    $0.convertedWord == "тест" && $0.suffix == String(opposite)
                }), "target punctuation path for \(literal) -> \(opposite)")
            }
        }
    }

    func testTargetPunctuationDoesNotTurnLiteralLetterIntoPreservedSuffix() {
        let strokes = [
            PhysicalKeyStroke(literal: "г", opposite: "u"),
            PhysicalKeyStroke(literal: "ы", opposite: "s"),
            PhysicalKeyStroke(literal: "у", opposite: "e"),
            PhysicalKeyStroke(literal: "б", opposite: ","),
        ]
        let candidates = PhysicalKeyLattice.candidates(
            typed: "гыуб",
            converted: "use,",
            strokes: strokes
        )

        XCTAssertTrue(candidates.contains {
            $0.convertedWord == "use" && $0.suffix == "," && $0.replacement == "use,"
        })
        XCTAssertFalse(candidates.contains { $0.suffix == "б" })
    }

    func testShiftedDigitRowPunctuationUsesPhysicalRussianCounterpart() {
        XCTAssertEqual(KeyMapping.convert("word@"), "цщкв\"")
        XCTAssertEqual(KeyMapping.convert("слово\""), "ckjdj@")
        XCTAssertEqual(KeyMapping.convert("word$"), "цщкв;")
        XCTAssertEqual(KeyMapping.convert("слово;"), "ckjdj$")
        XCTAssertEqual(KeyMapping.convert("word^"), "цщкв:")
        XCTAssertEqual(KeyMapping.convert("слово:"), "ckjdj^")
        XCTAssertEqual(KeyMapping.convert("word#"), "цщкв№")
        XCTAssertEqual(KeyMapping.convert("слово№"), "ckjdj#")
    }

    func testLayoutLetterSymbolsAreNotCutFromWordAsGenericDecoration() {
        let typed = "gkfn`;"
        let converted = KeyMapping.convert(typed)
        let candidates = PhysicalKeyLattice.candidates(typed: typed, converted: converted)

        XCTAssertEqual(converted, "платёж")
        XCTAssertTrue(candidates.contains { $0.replacement == "платёж" })
        XCTAssertFalse(candidates.contains { $0.replacement == "плат`;" })
    }

    func testLongPunctuationRunIsNotLimitedToThreeCharacters() {
        let suffix = "........"
        let typed = "ghbdtn" + suffix
        let candidates = PhysicalKeyLattice.candidates(
            typed: typed,
            converted: KeyMapping.convert(typed)
        )

        XCTAssertTrue(candidates.contains {
            $0.convertedWord == "привет"
                && $0.suffix == suffix
                && $0.replacement == "привет" + suffix
        })
    }

    func testWrapperAndSuffixBoundariesRemainIndependent() {
        let typed = "{gkfn`;..."
        let candidates = PhysicalKeyLattice.candidates(
            typed: typed,
            converted: KeyMapping.convert(typed)
        )

        XCTAssertTrue(candidates.contains {
            $0.prefix == "{"
                && $0.convertedWord == "платёж"
                && $0.suffix == "..."
        })
    }

    func testPathologicalDecorationRunsStayInsideResourceGuard() {
        let typed = String(repeating: "(", count: 20)
            + "ghbdtn"
            + String(repeating: ")", count: 20)
        let converted = KeyMapping.convert(typed)
        let first = PhysicalKeyLattice.hypotheses(typed: typed, converted: converted)
        let second = PhysicalKeyLattice.hypotheses(typed: typed, converted: converted)

        XCTAssertLessThanOrEqual(first.count, PhysicalKeyLattice.maximumHypotheses)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains(where: { $0.isLiteral }))
    }

    func testTrailingDecorationCanAlternateTargetLiteralAndTargetKeys() {
        let typed = "ghjdthrf&\"?"
        let converted = KeyMapping.convert(typed)
        let replacements = PhysicalKeyLattice.candidates(
            typed: typed,
            converted: converted
        ).map(\.replacement)

        XCTAssertTrue(
            replacements.contains("проверка?\","),
            "candidates=\(replacements)"
        )
    }

    private var lexicalPrefix: [PhysicalKeyStroke] {
        zip(Array("ntcn"), Array("тест")).map {
            PhysicalKeyStroke(literal: String($0), opposite: String($1))
        }
    }

    private func isPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
    }
}
