import XCTest
@testable import RuSwitcherAppSupport

final class PrivacySafeLoggerTests: XCTestCase {
    func testLoggerWritesOnlyStaticEventCode() {
        let box = OutputBox()
        let logger = PrivacySafeLogger { box.values.append($0) }

        logger.log("replacement_verified")

        XCTAssertEqual(box.values, ["replacement_verified"])
        XCTAssertFalse(box.values.joined().contains("secret.example.bundle"))
        XCTAssertFalse(box.values.joined().contains("контрольное-слово"))
    }
}

private final class OutputBox: @unchecked Sendable {
    var values: [String] = []
}
