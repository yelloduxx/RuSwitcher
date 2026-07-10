import XCTest
@testable import RuSwitcherCore

final class LanguageModelStoreTests: XCTestCase {
    func testBundledModelLoadsAndHasPinnedMetadata() throws {
        let model = try XCTUnwrap(LanguageModelStore.bundled)
        XCTAssertEqual(model.metadata.formatVersion, 1)
        XCTAssertEqual(model.metadata.sourceRevision, "e20471c15a758be3362b16d07870b34df4f7ccc3")
        XCTAssertGreaterThan(model.metadata.wordCounts["ru"] ?? 0, 9_000)
        XCTAssertGreaterThan(model.metadata.wordCounts["en"] ?? 0, 9_000)
        XCTAssertGreaterThan(model.metadata.wordCounts["enExtended"] ?? 0, 80_000)
        XCTAssertGreaterThan(model.trainingExtendedEnglishWords().count, 80_000)
    }

    func testCompoundIsDiscoveredFromPartsRatherThanWholeWord() throws {
        let model = try XCTUnwrap(LanguageModelStore.bundled)
        XCTAssertFalse(model.contains("суперспина", language: "ru"))
        let analysis = try XCTUnwrap(CompoundWordAnalyzer.analyze("суперспина", language: "ru", model: model))
        XCTAssertEqual(analysis.segments, ["супер", "спина"])
    }

    func testProductiveColloquialSuffixUsesKnownStem() throws {
        let model = try XCTUnwrap(LanguageModelStore.bundled)
        XCTAssertFalse(model.contains("приветульки", language: "ru"))
        let analysis = try XCTUnwrap(CompoundWordAnalyzer.analyze("приветульки", language: "ru", model: model))
        XCTAssertEqual(analysis.segments, ["привет", "ульки"])
    }

    func testChecksumRejectsCorruptedModel() throws {
        let url = try XCTUnwrap(LanguageModelStore.bundledResourceURL)
        var data = try Data(contentsOf: url)
        data[data.count - 1] ^= 0xff
        XCTAssertThrowsError(try LanguageModelStore(data: data)) { error in
            XCTAssertEqual(error as? LanguageModelError, .checksumMismatch)
        }
    }
}
