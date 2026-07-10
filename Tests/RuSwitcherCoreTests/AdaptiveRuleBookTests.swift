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

    func testLearnedCorrectionsArchiveRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let book = AdaptiveRuleBook(rules: [
            AdaptiveRule(
                original: "qazwsxedc",
                converted: "йфяцычувс",
                positiveCount: 3,
                negativeCount: 1,
                confirmed: true,
                lastUsed: date
            ),
            AdaptiveRule(
                original: "brand",
                converted: "икфтв",
                appBundleID: "com.example.editor",
                negativeCount: 2,
                lastUsed: date
            ),
        ])

        let data = try LearnedCorrectionsArchive(ruleBook: book, exportedAt: date).encoded()
        let decoded = try LearnedCorrectionsArchive.decode(data)

        XCTAssertEqual(decoded.ruleBook, book)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("qazwsxedc"))
    }

    func testImportMergeIsIdempotentAndPreservesConfirmation() {
        let oldDate = Date(timeIntervalSince1970: 1_600_000_000)
        let newDate = Date(timeIntervalSince1970: 1_700_000_000)
        var current = AdaptiveRuleBook(rules: [
            AdaptiveRule(
                original: "qazwsxedc",
                converted: "йфяцычувс",
                positiveCount: 2,
                negativeCount: 3,
                lastUsed: oldDate
            ),
        ])
        let imported = AdaptiveRuleBook(rules: [
            AdaptiveRule(
                original: "qazwsxedc",
                converted: "йфяцычувс",
                positiveCount: 5,
                negativeCount: 1,
                confirmed: true,
                lastUsed: newDate
            ),
        ])

        current.merge(imported)
        current.merge(imported)

        XCTAssertEqual(current.rules.count, 1)
        XCTAssertEqual(current.rules[0].positiveCount, 5)
        XCTAssertEqual(current.rules[0].negativeCount, 3)
        XCTAssertTrue(current.rules[0].confirmed)
        XCTAssertEqual(current.rules[0].lastUsed, newDate)
    }

    func testLearnedCorrectionsArchiveRejectsAnotherFormat() {
        let data = Data(#"{"format":"OtherApp","formatVersion":1,"exportedAt":"2026-07-10T10:00:00Z","modelVersion":3,"rules":[]}"#.utf8)

        XCTAssertThrowsError(try LearnedCorrectionsArchive.decode(data)) { error in
            XCTAssertEqual(error as? LearnedCorrectionsArchiveError, .invalidFormat)
        }
    }
}
