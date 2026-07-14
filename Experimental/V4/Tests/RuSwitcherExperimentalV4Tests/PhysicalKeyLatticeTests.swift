import XCTest
@testable import RuSwitcherCore
@testable import RuSwitcherExperimentalV4

final class PhysicalKeyLatticeTests: XCTestCase {
    func testReverseLayoutPunctuationIsCandidateText() {
        let typed = "гыуб"
        let converted = KeyMapping.convert(typed)
        XCTAssertEqual(converted, "use,")
        let hypotheses = RuSwitcherExperimentalV4.PhysicalKeyLattice.hypotheses(
            typed: typed,
            converted: converted
        )
        XCTAssertEqual(hypotheses.first?.text, typed)
        XCTAssertTrue(hypotheses.contains { $0.text == "use," })
        XCTAssertLessThanOrEqual(
            hypotheses.count,
            RuSwitcherExperimentalV4.PhysicalKeyLattice.maximumHypotheses
        )
    }

    func testPhysicalPeriodKeepsWordAndPunctuationAlternatives() {
        let hypotheses = RuSwitcherExperimentalV4.PhysicalKeyLattice.hypotheses(
            typed: "ghbdtncnde.",
            converted: KeyMapping.convert("ghbdtncnde.")
        )
        XCTAssertTrue(hypotheses.contains { $0.text == "приветствую" })
        XCTAssertTrue(hypotheses.contains { $0.kind == .trailingPunctuation })
    }

    func testWrappingPunctuationHypothesisPreservesBothSides() {
        let typed = "[gjxtve."
        let hypotheses = RuSwitcherExperimentalV4.PhysicalKeyLattice.hypotheses(
            typed: typed,
            converted: KeyMapping.convert(typed)
        )
        XCTAssertTrue(hypotheses.contains {
            $0.text == "[почему." && $0.kind == .wrappingPunctuation
        })
    }
}
