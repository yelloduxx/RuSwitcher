import XCTest
@testable import RuSwitcherAppSupport

final class PasteboardOwnershipTests: XCTestCase {
    func testRestorePreservesClipboardCopiedByUserAfterTemporaryWrite() {
        let manager = FakePasteboard(changeCount: 10, items: [.init(type: "public.text", data: Data("old".utf8))])
        let owner = PasteboardOwnership()
        owner.captureIfNeeded(from: manager)
        manager.replace(with: [.init(type: "public.text", data: Data("temporary".utf8))])
        owner.markTemporaryWrite(changeCount: manager.changeCount)

        manager.replace(with: [.init(type: "public.text", data: Data("new-user-copy".utf8))])

        XCTAssertFalse(owner.restoreIfOwned(to: manager))
        XCTAssertEqual(String(data: manager.items[0].data, encoding: .utf8), "new-user-copy")
    }

    func testRepeatedCaptureKeepsFirstUserSnapshot() {
        let manager = FakePasteboard(changeCount: 1, items: [.init(type: "public.text", data: Data("first".utf8))])
        let owner = PasteboardOwnership()
        owner.captureIfNeeded(from: manager)
        manager.replace(with: [.init(type: "public.text", data: Data("temporary".utf8))])
        owner.markTemporaryWrite(changeCount: manager.changeCount)

        owner.captureIfNeeded(from: manager)
        XCTAssertTrue(owner.restoreIfOwned(to: manager))
        XCTAssertEqual(String(data: manager.items[0].data, encoding: .utf8), "first")
    }
}

private final class FakePasteboard: PasteboardManaging {
    private(set) var changeCount: Int
    private(set) var items: [PasteboardItem]

    init(changeCount: Int, items: [PasteboardItem]) {
        self.changeCount = changeCount
        self.items = items
    }

    func snapshot() -> PasteboardSnapshot { PasteboardSnapshot(changeCount: changeCount, items: items) }

    func replace(with items: [PasteboardItem]) {
        self.items = items
        changeCount += 1
    }
}
