import XCTest
@testable import RuSwitcherCore

final class ConversionTransactionTests: XCTestCase {
    private let focus = FocusedElementIdentity(processID: 7, bundleID: "notes")

    func testSpaceIsReplayedInsideTransaction() {
        let transaction = ConversionTransaction(
            original: "ghbdtn",
            replacement: "привет",
            boundary: .space(count: 1),
            focus: focus,
            sourceLayoutID: "en",
            targetLayoutID: "ru",
            sequence: 6,
            automatic: true
        )
        XCTAssertEqual(transaction.insertedText, "привет ")
        XCTAssertEqual(transaction.originalTextForUndo, "ghbdtn ")
    }

    func testPunctuationIsAlreadyPartOfCandidate() {
        let transaction = ConversionTransaction(
            original: "ghbdtn,",
            replacement: "привет,",
            boundary: .punctuation(","),
            focus: focus,
            sourceLayoutID: "en",
            targetLayoutID: "ru",
            sequence: 7,
            automatic: true
        )
        XCTAssertEqual(transaction.insertedText, "привет,")
        XCTAssertEqual(transaction.originalTextForUndo, "ghbdtn,")
    }

    func testUndeliveredPunctuationIsNotCountedAsBackspace() {
        let keys = Array("ghbdtn,").enumerated().map { index, char in
            TypedKey(keyCode: UInt16(index), shift: false, caps: false, producedCharacter: char, sourceLayoutID: "en")
        }
        let snapshot = TokenSnapshot(
            keys: keys,
            context: [],
            boundary: .punctuation(","),
            focus: focus,
            sequence: 7
        )
        XCTAssertEqual(snapshot.deliveredKeyCount, 6)
    }

    func testEventReplacementPlanHasOneInsertionPayload() {
        let transaction = ConversionTransaction(
            original: "ghbdtn",
            replacement: "привет",
            boundary: .space(count: 1),
            focus: focus,
            sourceLayoutID: "en",
            targetLayoutID: "ru",
            sequence: 8,
            automatic: true
        )

        let plan = EventReplacementPlan(transaction: transaction, deliveredKeyCount: 6)

        XCTAssertEqual(plan.backspaceCount, 6)
        XCTAssertEqual(plan.insertedText, "привет ")
    }

    func testExecutionGateRejectsOnlyCommittedDuplicate() {
        let transaction = ConversionTransaction(
            original: "ghbdtn",
            replacement: "привет",
            boundary: .space(count: 1),
            focus: focus,
            sourceLayoutID: "en",
            targetLayoutID: "ru",
            sequence: 9,
            automatic: true
        )
        var gate = ConversionExecutionGate()

        XCTAssertFalse(gate.isDuplicate(transaction))
        gate.recordCommitted(transaction)
        XCTAssertTrue(gate.isDuplicate(transaction))

        let nextTransaction = ConversionTransaction(
            original: "руддщ",
            replacement: "hello",
            boundary: .space(count: 1),
            focus: focus,
            sourceLayoutID: "ru",
            targetLayoutID: "en",
            sequence: 10,
            automatic: true
        )
        XCTAssertFalse(gate.isDuplicate(nextTransaction))
    }
}
