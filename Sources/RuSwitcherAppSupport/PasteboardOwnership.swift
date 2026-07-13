import Foundation

public struct PasteboardItem: Equatable, Sendable {
    public let type: String
    public let data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

public struct PasteboardSnapshot: Equatable, Sendable {
    public let changeCount: Int
    public let items: [PasteboardItem]

    public init(changeCount: Int, items: [PasteboardItem]) {
        self.changeCount = changeCount
        self.items = items
    }
}

public protocol PasteboardManaging: AnyObject {
    var changeCount: Int { get }
    func snapshot() -> PasteboardSnapshot
    func replace(with items: [PasteboardItem])
}

public final class PasteboardOwnership {
    private var originalSnapshot: PasteboardSnapshot?
    private var ownedChangeCount: Int?

    public init() {}

    public func captureIfNeeded(from pasteboard: PasteboardManaging) {
        if originalSnapshot == nil {
            originalSnapshot = pasteboard.snapshot()
        }
    }

    public func markTemporaryWrite(changeCount: Int) {
        ownedChangeCount = changeCount
    }

    @discardableResult
    public func restoreIfOwned(to pasteboard: PasteboardManaging) -> Bool {
        guard let originalSnapshot, let ownedChangeCount,
              pasteboard.changeCount == ownedChangeCount else {
            clear()
            return false
        }
        pasteboard.replace(with: originalSnapshot.items)
        clear()
        return true
    }

    public func clear() {
        originalSnapshot = nil
        ownedChangeCount = nil
    }
}
