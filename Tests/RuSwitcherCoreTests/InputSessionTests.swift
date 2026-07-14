import XCTest
@testable import RuSwitcherCore

final class InputSessionTests: XCTestCase {
    func testTextBoundariesReplayOnlyInsideCommittedTransaction() {
        XCTAssertTrue(InputBoundary.space(count: 1).shouldConsumeOriginalEvent)
        XCTAssertEqual(InputBoundary.space(count: 1).replayText, " ")
        XCTAssertTrue(InputBoundary.enter.shouldConsumeOriginalEvent)
        XCTAssertEqual(InputBoundary.enter.replayText, "\n")
        XCTAssertTrue(InputBoundary.tab.shouldConsumeOriginalEvent)
        XCTAssertEqual(InputBoundary.tab.replayText, "\t")
        XCTAssertFalse(InputBoundary.punctuation(",").shouldConsumeOriginalEvent)
        XCTAssertEqual(InputBoundary.punctuation(",").replayText, "")
    }

    func testStagedCompletionProvidesProvisionalContextWithoutDuplication() {
        var session = InputSession()
        session.append(TypedKey(keyCode: 5, shift: false, caps: false, char: "g"))

        let stagedSequence = session.stageCompletion(
            resolvedText: "привет",
            language: "ru",
            wasConverted: true
        )
        XCTAssertTrue(session.hasPendingStagedCompletion)

        XCTAssertTrue(session.currentKeys.isEmpty)
        XCTAssertEqual(session.context.map(\.text), ["привет"])
        XCTAssertTrue(session.confirmStagedCompletion(
            resolvedText: "привет",
            language: "ru",
            wasConverted: true,
            expectedSequence: stagedSequence
        ))
        XCTAssertFalse(session.hasPendingStagedCompletion)
        XCTAssertEqual(session.context.map(\.text), ["привет"])
    }

    func testProvisionalContextSurvivesImmediateNextInput() {
        var session = InputSession()
        session.append(TypedKey(keyCode: 5, shift: false, caps: false, char: "g"))
        let stagedSequence = session.stageCompletion(
            resolvedText: "проверили",
            language: "ru",
            wasConverted: true
        )
        session.append(TypedKey(keyCode: 0, shift: false, caps: false, char: "a"))

        XCTAssertFalse(session.hasPendingStagedCompletion)
        XCTAssertFalse(session.confirmStagedCompletion(
            resolvedText: "привет",
            language: "ru",
            wasConverted: true,
            expectedSequence: stagedSequence
        ))
        XCTAssertEqual(session.context.map(\.text), ["проверили"])
        XCTAssertEqual(session.snapshot(
            boundary: .space(count: 1),
            focus: .init(processID: 1, bundleID: "test")
        )?.context.map(\.text), ["проверили"])
    }

    func testUnverifiedCompletionClearsPendingMarkerWithoutDuplicatingContext() {
        var session = InputSession()
        session.append(TypedKey(keyCode: 5, shift: false, caps: false, char: "g"))
        let stagedSequence = session.stageCompletion(
            resolvedText: "проверка",
            language: "ru",
            wasConverted: true
        )

        XCTAssertTrue(session.hasPendingStagedCompletion)
        XCTAssertTrue(session.finishUnverifiedStagedCompletion(
            expectedSequence: stagedSequence
        ))
        XCTAssertFalse(session.hasPendingStagedCompletion)
        XCTAssertEqual(session.context.map(\.text), ["проверка"])
        XCTAssertFalse(session.finishUnverifiedStagedCompletion(
            expectedSequence: stagedSequence
        ))
    }

    func testManualStagingWithoutResolvedTextDoesNotInventContext() {
        var session = InputSession()
        session.append(TypedKey(keyCode: 5, shift: false, caps: false, char: "g"))

        session.stageCompletion()

        XCTAssertTrue(session.context.isEmpty)
    }
    private let focus = FocusedElementIdentity(processID: 42, bundleID: "test.app")

    func testSnapshotDoesNotChangeAfterNextTokenStarts() throws {
        var session = InputSession(contextLimit: 5)
        session.append(TypedKey(keyCode: 4, shift: false, caps: false, producedCharacter: "h", sourceLayoutID: "en"))
        session.append(TypedKey(keyCode: 14, shift: false, caps: false, producedCharacter: "e", sourceLayoutID: "en"))

        let snapshot = try XCTUnwrap(session.snapshot(boundary: .space(count: 1), focus: focus))
        session.complete(resolvedText: "he", language: "en", wasConverted: false)
        session.append(TypedKey(keyCode: 37, shift: false, caps: false, producedCharacter: "l", sourceLayoutID: "en"))

        XCTAssertEqual(snapshot.keys.compactMap(\.producedCharacter), ["h", "e"])
        XCTAssertEqual(session.currentKeys.compactMap(\.producedCharacter), ["l"])
    }

    func testSessionKeepsFiveResolvedContextTokens() {
        var session = InputSession(contextLimit: 5)
        for index in 0..<7 {
            session.append(TypedKey(keyCode: 0, shift: false, caps: false, producedCharacter: "a"))
            session.complete(resolvedText: "word\(index)", language: "en", wasConverted: index == 6)
        }

        XCTAssertEqual(session.context.map(\.text), ["word2", "word3", "word4", "word5", "word6"])
        XCTAssertTrue(session.context.last?.wasConverted == true)
    }

    func testMixedCapturedLayoutsHaveNoSingleSourceLayout() throws {
        let snapshot = TokenSnapshot(
            keys: [
                TypedKey(keyCode: 0, shift: false, caps: false, sourceLayoutID: "en"),
                TypedKey(keyCode: 1, shift: false, caps: false, sourceLayoutID: "ru"),
            ],
            context: [],
            boundary: .space(count: 1),
            focus: focus,
            sequence: 2
        )
        XCTAssertNil(snapshot.sourceLayoutID)
    }
}
