import XCTest
@testable import RuSwitcherCore

final class PhysicalBoundaryPolicyTests: XCTestCase {
    func testPeriodIsDeferredWhenOppositeLayoutProducesRussianLetter() {
        XCTAssertTrue(PhysicalBoundaryPolicy.shouldDeferTerminalPunctuation(
            produced: ".",
            oppositeLayoutCharacter: "ю"
        ))
    }

    func testUnambiguousPunctuationCanFinishToken() {
        XCTAssertFalse(PhysicalBoundaryPolicy.shouldDeferTerminalPunctuation(
            produced: "!",
            oppositeLayoutCharacter: "!"
        ))
        XCTAssertFalse(PhysicalBoundaryPolicy.shouldDeferTerminalPunctuation(
            produced: ".",
            oppositeLayoutCharacter: nil
        ))
    }

    func testLetterIsNeverClassifiedAsPunctuationBoundary() {
        XCTAssertFalse(PhysicalBoundaryPolicy.shouldDeferTerminalPunctuation(
            produced: "a",
            oppositeLayoutCharacter: "ф"
        ))
    }
}
