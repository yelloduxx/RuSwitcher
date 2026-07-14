import XCTest
@testable import RuSwitcherAppSupport

final class RuntimePreferencesDomainTests: XCTestCase {
    func testHIDProbeUsesIsolatedPreferences() {
        for argument in [
            "--hid-probe",
            "--hid-probe-file",
            "--hid-transport-probe",
            "--hid-transport-probe-file",
        ] {
            XCTAssertEqual(
                RuntimePreferencesDomain.isolatedSuiteName(
                    arguments: ["RuSwitcher", argument, "fixture.json"]
                ),
                RuntimePreferencesDomain.hidProbeSuiteName
            )
        }
    }

    func testManualPersistenceTestCanExplicitlyUseStandardPreferences() {
        XCTAssertNil(RuntimePreferencesDomain.isolatedSuiteName(arguments: [
            "RuSwitcher",
            "--hid-probe",
            "manual-learning-double-shift",
            "--hid-use-standard-preferences",
        ]))
    }

    func testHIDMonitorUsesASeparateIsolatedPreferencesSuite() {
        XCTAssertEqual(
            RuntimePreferencesDomain.isolatedSuiteName(arguments: [
                "RuSwitcher",
                "--hid-monitor",
                "status.json",
            ]),
            RuntimePreferencesDomain.hidMonitorSuiteName
        )
        XCTAssertNotEqual(
            RuntimePreferencesDomain.hidMonitorSuiteName,
            RuntimePreferencesDomain.hidProbeSuiteName
        )
    }

    func testNormalApplicationUsesStandardPreferences() {
        XCTAssertNil(RuntimePreferencesDomain.isolatedSuiteName(arguments: ["RuSwitcher"]))
    }
}
