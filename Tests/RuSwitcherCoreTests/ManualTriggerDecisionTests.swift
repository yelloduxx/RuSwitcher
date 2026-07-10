import XCTest
@testable import RuSwitcherCore

final class ManualTriggerDecisionTests: XCTestCase {
    func testConvertedOutcomeSwitchesLayout() {
        XCTAssertTrue(ManualTriggerDecision.shouldSwitchLayout(after: .converted))
    }

    func testSwitchedOnlyOutcomeSwitchesLayout() {
        XCTAssertTrue(ManualTriggerDecision.shouldSwitchLayout(after: .switchedOnly))
    }

    func testSwitchedOnlyCanBeDisabledInBlockedContexts() {
        XCTAssertFalse(ManualTriggerDecision.shouldSwitchLayout(after: .switchedOnly, allowSwitchedOnly: false))
    }

    func testBlockedOutcomeDoesNotSwitchLayout() {
        XCTAssertFalse(ManualTriggerDecision.shouldSwitchLayout(after: .blocked))
    }
}
