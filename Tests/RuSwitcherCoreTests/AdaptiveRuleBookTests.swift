import XCTest
@testable import RuSwitcherCore

final class AdaptiveRuleBookTests: XCTestCase {
    func testV2JSONMigratesWithoutLosingRules() throws {
        let oldJSON = #"{"rules":[{"original":"ghbdtn","converted":"привет","appBundleID":null,"positiveCount":2,"negativeCount":0,"lastUsed":0}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let book = try decoder.decode(AdaptiveRuleBook.self, from: Data(oldJSON.utf8))

        XCTAssertEqual(book.modelVersion, 3)
        XCTAssertEqual(book.rules.count, 1)
        XCTAssertFalse(book.rules[0].confirmed)
        XCTAssertGreaterThan(book.bias(original: "ghbdtn", converted: "привет", appBundleID: nil), 0)
    }

    func testNegativeSignalRemovesConfirmationWithoutCreatingNeverRule() {
        var book = AdaptiveRuleBook()
        book.recordConfirmed(original: "cegthcgbyf", converted: "суперспина")
        XCTAssertTrue(book.isConfirmed(original: "cegthcgbyf", converted: "суперспина", appBundleID: nil))

        book.recordNegative(original: "cegthcgbyf", converted: "суперспина", appBundleID: nil)
        XCTAssertFalse(book.isConfirmed(original: "cegthcgbyf", converted: "суперспина", appBundleID: nil))
        XCTAssertFalse(book.rules.contains { $0.confirmed })
    }

    func testPositiveAndNegativeSignalsAdjustBias() {
        var book = AdaptiveRuleBook()
        book.recordPositive(original: "ghbdtn", converted: "привет", appBundleID: nil)
        XCTAssertGreaterThan(book.bias(original: "ghbdtn", converted: "привет", appBundleID: "chat"), 0)

        book.recordNegative(original: "ghbdtn", converted: "привет", appBundleID: nil)
        book.recordNegative(original: "ghbdtn", converted: "привет", appBundleID: nil)
        XCTAssertLessThan(book.bias(original: "ghbdtn", converted: "привет", appBundleID: "chat"), 0)
    }

    func testAppScopedRuleDoesNotLeakToAnotherApp() {
        var book = AdaptiveRuleBook()
        book.recordNegative(original: "brand", converted: "икфтв", appBundleID: "chat.one")
        XCTAssertLessThan(book.bias(original: "brand", converted: "икфтв", appBundleID: "chat.one"), 0)
        XCTAssertEqual(book.bias(original: "brand", converted: "икфтв", appBundleID: "chat.two"), 0)
    }
}
