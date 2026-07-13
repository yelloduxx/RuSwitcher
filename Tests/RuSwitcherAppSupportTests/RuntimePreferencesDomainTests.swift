import XCTest
@testable import RuSwitcherAppSupport

final class RuntimePreferencesDomainTests: XCTestCase {
    func testHIDProbeUsesIsolatedPreferences() {
        XCTAssertEqual(
            RuntimePreferencesDomain.isolatedSuiteName(
                arguments: ["RuSwitcher", "--hid-probe-file", "fixture.json"]
            ),
            RuntimePreferencesDomain.hidProbeSuiteName
        )
    }

    func testManualPersistenceTestCanExplicitlyUseStandardPreferences() {
        XCTAssertNil(RuntimePreferencesDomain.isolatedSuiteName(arguments: [
            "RuSwitcher",
            "--hid-probe",
            "manual-learning-double-shift",
            "--hid-use-standard-preferences",
        ]))
    }

    func testNormalApplicationUsesStandardPreferences() {
        XCTAssertNil(RuntimePreferencesDomain.isolatedSuiteName(arguments: ["RuSwitcher"]))
    }
}
