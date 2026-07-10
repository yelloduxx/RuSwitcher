import XCTest
@testable import RuSwitcherCore

final class AnonymousUsageStatisticsTests: XCTestCase {
    func testStatisticsContainOnlyBucketsAndCounters() throws {
        var statistics = AnonymousUsageStatistics(startedAt: Date(timeIntervalSince1970: 0))
        statistics.record(
            .autoConverted,
            languagePair: "en-ru",
            reason: "frequentWord",
            tokenLength: 11
        )

        let json = String(decoding: try JSONEncoder().encode(statistics), as: UTF8.self)
        XCTAssertEqual(statistics.eventCount, 1)
        XCTAssertTrue(json.contains("8-15"))
        XCTAssertFalse(json.contains("ghbdtncnde"))
    }

    func testUntrustedDimensionsAreSanitized() {
        var statistics = AnonymousUsageStatistics()
        statistics.record(.autoKept, languagePair: "en/ru secret", reason: "word with spaces", tokenLength: 2)
        let key = try! XCTUnwrap(statistics.counters.keys.first)
        XCTAssertEqual(key, "autoKept|enrusecret|wordwithspaces|2-3")
    }

    func testRemovingUploadedSnapshotPreservesNewEvents() {
        var uploaded = AnonymousUsageStatistics()
        uploaded.record(.autoConverted, languagePair: "en-ru")
        var current = uploaded
        current.record(.autoConverted, languagePair: "en-ru")
        current.record(.correctionUndone)

        current.removeCounters(in: uploaded)

        XCTAssertEqual(current.eventCount, 2)
    }
}
