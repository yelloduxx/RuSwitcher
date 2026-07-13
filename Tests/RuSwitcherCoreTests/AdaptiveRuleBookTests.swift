import XCTest
@testable import RuSwitcherCore

final class AdaptiveRuleBookTests: XCTestCase {
    func testV2JSONMigratesWithoutLosingRules() throws {
        let oldJSON = #"{"rules":[{"original":"ghbdtn","converted":"привет","appBundleID":null,"positiveCount":2,"negativeCount":0,"lastUsed":0}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let book = try decoder.decode(AdaptiveRuleBook.self, from: Data(oldJSON.utf8))

        XCTAssertEqual(book.modelVersion, 8)
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

    func testSingleCharacterManualPairIsNeverPersisted() {
        var book = AdaptiveRuleBook()

        book.recordManualCorrection(original: "а", converted: "f", appBundleID: "chat.one")
        book.recordPositive(original: "b", converted: "и")
        book.recordPositive(original: ",s", converted: "бы")
        book.recordPositive(original: "3ч", converted: "3x")

        XCTAssertTrue(book.rules.isEmpty)
        XCTAssertFalse(book.isConfirmed(original: "а", converted: "f", appBundleID: nil))
    }

    func testV6MigrationRemovesUnsafeSingleCharacterRules() throws {
        let json = #"{"modelVersion":6,"rules":[{"original":"а","converted":"f","appBundleID":null,"positiveCount":22,"negativeCount":0,"confirmed":true,"lastUsed":800000000},{"original":"b","converted":"и","appBundleID":null,"positiveCount":40,"negativeCount":0,"confirmed":true,"lastUsed":800000000},{"original":"ghbdtn","converted":"привет","appBundleID":null,"positiveCount":2,"negativeCount":0,"confirmed":true,"lastUsed":800000000}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let book = try decoder.decode(AdaptiveRuleBook.self, from: Data(json.utf8))

        XCTAssertEqual(book.modelVersion, 8)
        XCTAssertEqual(book.rules.map(\.original), ["ghbdtn"])
        XCTAssertTrue(book.isConfirmed(original: "ghbdtn", converted: "привет", appBundleID: nil))
    }

    func testCurrentArchiveCannotReintroduceUnsafeSingleCharacterRule() {
        let unsafe = AdaptiveRule(
            original: "а",
            converted: "f",
            positiveCount: 22,
            confirmed: true
        )

        var current = AdaptiveRuleBook()
        current.merge(AdaptiveRuleBook(rules: [unsafe], modelVersion: 8))

        XCTAssertTrue(current.rules.isEmpty)
        XCTAssertFalse(current.isConfirmed(original: "а", converted: "f", appBundleID: nil))
    }

    func testPositiveAndNegativeSignalsAdjustBias() {
        var book = AdaptiveRuleBook()
        book.recordPositive(original: "ghbdtn", converted: "привет")
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

    func testConfirmedWordIsGlobalAcrossApplications() {
        var book = AdaptiveRuleBook()
        book.recordConfirmed(original: "qazwsxedc", converted: "йфяцычувс")

        XCTAssertTrue(book.isConfirmed(
            original: "qazwsxedc",
            converted: "йфяцычувс",
            appBundleID: "chat.one"
        ))
        XCTAssertTrue(book.isConfirmed(
            original: "qazwsxedc",
            converted: "йфяцычувс",
            appBundleID: "editor.two"
        ))
    }

    func testReversalCreatesExceptionOnlyForCurrentApplication() {
        var book = AdaptiveRuleBook()
        book.recordConfirmed(original: "qazwsxedc", converted: "йфяцычувс")
        book.recordNegative(
            original: "qazwsxedc",
            converted: "йфяцычувс",
            appBundleID: "chat.one"
        )

        XCTAssertFalse(book.isConfirmed(
            original: "qazwsxedc",
            converted: "йфяцычувс",
            appBundleID: "chat.one"
        ))
        XCTAssertLessThanOrEqual(book.bias(
            original: "qazwsxedc",
            converted: "йфяцычувс",
            appBundleID: "chat.one"
        ), -10)
        XCTAssertTrue(book.isConfirmed(
            original: "qazwsxedc",
            converted: "йфяцычувс",
            appBundleID: "editor.two"
        ))
    }

    func testWeakAutomaticLearningDoesNotCreatePermanentApplicationException() {
        var book = AdaptiveRuleBook()
        book.recordPositive(original: "gjxtve", converted: "почему")
        book.recordNegative(original: "gjxtve", converted: "почему", appBundleID: "chat.one")

        XCTAssertFalse(book.hasApplicationException(
            original: "gjxtve",
            converted: "почему",
            appBundleID: "chat.one"
        ))
        XCTAssertGreaterThanOrEqual(book.bias(
            original: "gjxtve",
            converted: "почему",
            appBundleID: "chat.one"
        ), -2.5)
    }

    func testV4WeakApplicationExceptionRemovesLegacyBackspaceFeedback() throws {
        let json = #"{"modelVersion":4,"rules":[{"original":"gjxtve","converted":"почему","appBundleID":null,"positiveCount":1,"negativeCount":0,"confirmed":false,"applicationException":false,"lastUsed":800000000},{"original":"gjxtve","converted":"почему","appBundleID":"chat.one","positiveCount":0,"negativeCount":1,"confirmed":false,"applicationException":true,"lastUsed":800000000}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let book = try decoder.decode(AdaptiveRuleBook.self, from: Data(json.utf8))

        XCTAssertEqual(book.modelVersion, 8)
        XCTAssertFalse(book.hasApplicationException(
            original: "gjxtve",
            converted: "почему",
            appBundleID: "chat.one"
        ))
        XCTAssertFalse(book.rules.contains {
            $0.original == "gjxtve" && $0.converted == "почему" && $0.appBundleID == "chat.one"
        })
    }

    func testManualConfirmationClearsOnlyCurrentApplicationException() {
        var book = AdaptiveRuleBook()
        book.recordConfirmed(original: "qazwsxedc", converted: "йфяцычувс")
        book.recordNegative(original: "qazwsxedc", converted: "йфяцычувс", appBundleID: "chat.one")
        book.recordNegative(original: "qazwsxedc", converted: "йфяцычувс", appBundleID: "editor.two")

        book.recordConfirmed(
            original: "qazwsxedc",
            converted: "йфяцычувс",
            clearingExceptionFor: "chat.one"
        )

        XCTAssertTrue(book.isConfirmed(
            original: "qazwsxedc",
            converted: "йфяцычувс",
            appBundleID: "chat.one"
        ))
        XCTAssertFalse(book.isConfirmed(
            original: "qazwsxedc",
            converted: "йфяцычувс",
            appBundleID: "editor.two"
        ))
    }

    func testManualReverseCreatesApplicationExceptionInsteadOfOppositeGlobalRule() {
        var book = AdaptiveRuleBook()
        book.recordConfirmed(original: "qazwsxedc", converted: "йфяцычувс")

        book.recordManualCorrection(
            original: "йфяцычувс",
            converted: "qazwsxedc",
            appBundleID: "chat.one"
        )

        XCTAssertTrue(book.hasApplicationException(
            original: "qazwsxedc",
            converted: "йфяцычувс",
            appBundleID: "chat.one"
        ))
        XCTAssertTrue(book.isConfirmed(
            original: "qazwsxedc",
            converted: "йфяцычувс",
            appBundleID: "editor.two"
        ))
        XCTAssertFalse(book.isConfirmed(
            original: "йфяцычувс",
            converted: "qazwsxedc",
            appBundleID: "editor.two"
        ))
    }

    func testAcceptedCorrectionBuildsGlobalBias() {
        var book = AdaptiveRuleBook()
        book.recordPositive(original: "qazwsxedc", converted: "йфяцычувс")

        XCTAssertGreaterThan(book.bias(
            original: "qazwsxedc",
            converted: "йфяцычувс",
            appBundleID: "chat.one"
        ), 0)
        XCTAssertGreaterThan(book.bias(
            original: "qazwsxedc",
            converted: "йфяцычувс",
            appBundleID: "editor.two"
        ), 0)
    }

    func testLegacyApplicationLearningMigratesToGlobalWithLocalException() throws {
        let json = #"{"modelVersion":3,"rules":[{"original":"qazwsxedc","converted":"йфяцычувс","appBundleID":"chat.one","positiveCount":3,"negativeCount":0,"confirmed":true,"lastUsed":0},{"original":"qazwsxedc","converted":"йфяцычувс","appBundleID":"editor.two","positiveCount":0,"negativeCount":1,"confirmed":false,"lastUsed":0}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let book = try decoder.decode(AdaptiveRuleBook.self, from: Data(json.utf8))

        XCTAssertEqual(book.modelVersion, 8)
        XCTAssertTrue(book.isConfirmed(
            original: "qazwsxedc",
            converted: "йфяцычувс",
            appBundleID: "another.app"
        ))
        XCTAssertFalse(book.isConfirmed(
            original: "qazwsxedc",
            converted: "йфяцычувс",
            appBundleID: "editor.two"
        ))
        XCTAssertTrue(book.hasApplicationException(
            original: "qazwsxedc",
            converted: "йфяцычувс",
            appBundleID: "editor.two"
        ))
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

    func testLearnedCorrectionsArchiveRejectsGlobalApplicationException() {
        let book = AdaptiveRuleBook(rules: [
            AdaptiveRule(
                original: "qazwsxedc",
                converted: "йфяцычувс",
                applicationException: true
            ),
        ])

        XCTAssertThrowsError(try LearnedCorrectionsArchive(ruleBook: book).encoded()) { error in
            XCTAssertEqual(error as? LearnedCorrectionsArchiveError, .invalidRule)
        }
    }
}
