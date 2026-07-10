import XCTest
@testable import RuSwitcherCore

final class EditStateMachineTests: XCTestCase {
    private func key(_ character: Character, code: UInt16 = 0) -> TypedKey {
        TypedKey(
            keyCode: code,
            shift: character.isUppercase,
            caps: false,
            producedCharacter: character,
            producedText: String(character),
            sourceLayoutID: "en"
        )
    }

    func testEraseWholeTokenSpaceThenNewTokenHasNoPhantomWord() {
        var session = InputSession()
        for character in "cegthcgbyf" { session.handle(.printable(key(character))) }
        for _ in "cegthcgbyf" { session.handle(.plainBackspace) }
        XCTAssertTrue(session.currentKeys.isEmpty)
        if case .idle = session.state {} else { XCTFail("expected idle") }

        session.handle(.boundary(.space(count: 1)))
        for character in "ghbdtn" { session.handle(.printable(key(character))) }
        let snapshot = session.snapshot(
            boundary: .space(count: 1),
            focus: FocusedElementIdentity(processID: 1, bundleID: "test")
        )
        XCTAssertEqual(snapshot?.producedText, "ghbdtn")
        XCTAssertEqual(snapshot?.integrity, .clean)
    }

    func testModifiedDeletionInvalidatesAndFreshTypingStartsCleanRevision() {
        var session = InputSession()
        session.handle(.printable(key("a")))
        let oldRevision = session.editRevision
        session.handle(.modifiedDeletion)
        XCTAssertEqual(session.integrity, .invalidated)
        XCTAssertGreaterThan(session.editRevision, oldRevision)
        XCTAssertNil(session.snapshot(boundary: .space(count: 1), focus: .init(processID: 1, bundleID: "test")))

        session.handle(.printable(key("g")))
        XCTAssertEqual(session.integrity, .clean)
        XCTAssertEqual(session.currentKeys.count, 1)
    }

    func testNavigationClipboardUndoAndTapRecoveryInvalidate() {
        for event in [InputEvent.navigation, .clipboardCommand, .undo, .focusChanged, .tapRecovered] {
            var session = InputSession()
            session.handle(.printable(key("g")))
            session.handle(event)
            XCTAssertEqual(session.integrity, .invalidated)
            XCTAssertTrue(session.currentKeys.isEmpty)
        }
    }

    func testSnapshotRevisionCannotBeginCommitAfterEdit() throws {
        var session = InputSession()
        session.handle(.printable(key("g")))
        let snapshot = try XCTUnwrap(session.snapshot(
            boundary: .space(count: 1),
            focus: .init(processID: 1, bundleID: "test")
        ))
        session.handle(.plainBackspace)
        XCTAssertFalse(session.beginCommit(expectedRevision: snapshot.editRevision))
    }
}
