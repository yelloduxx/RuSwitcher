import XCTest
@testable import RuSwitcherAppSupport

final class ReleaseVersionTests: XCTestCase {
    func testNewerBuildOfSameSemanticVersionIsUpdate() {
        XCTAssertTrue(ReleaseVersion(version: "4.0.0", build: 76) > ReleaseVersion(version: "4.0.0", build: 73))
    }

    func testNewerSemanticVersionWinsRegardlessOfBuild() {
        XCTAssertTrue(ReleaseVersion(version: "4.1.0", build: 1) > ReleaseVersion(version: "4.0.0", build: 999))
    }

    func testLegacySkippedVersionDoesNotHideNewBuild() {
        let release = ReleaseVersion(version: "4.0.0", build: 76)
        XCTAssertFalse(release.matchesSkipIdentifier("4.0.0"))
        XCTAssertTrue(release.matchesSkipIdentifier("4.0.0+76"))
    }
}
