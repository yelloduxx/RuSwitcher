import Foundation

public struct ConversionTransaction: Equatable, Sendable {
    public let original: String
    public let replacement: String
    public let expectedOriginalSuffix: String
    public let boundary: InputBoundary
    public let focus: FocusedElementIdentity
    public let sourceLayoutID: String?
    public let targetLayoutID: String?
    public let sequence: UInt64
    public let editRevision: UInt64
    public let createdAt: Date
    public let automatic: Bool

    public var insertedText: String {
        replacement + boundary.replayText
    }

    public var originalTextForUndo: String {
        original + boundary.replayText
    }

    /// Stable for one completed input token. The event tap may be re-enabled or a
    /// callback may be retried, but a transaction with the same identity must never
    /// be applied twice.
    public var executionIdentity: ConversionExecutionIdentity {
        ConversionExecutionIdentity(
            processID: focus.processID,
            elementIdentifier: focus.identifier,
            editRevision: editRevision,
            sequence: sequence
        )
    }

    public init(
        original: String,
        replacement: String,
        boundary: InputBoundary,
        focus: FocusedElementIdentity,
        sourceLayoutID: String?,
        targetLayoutID: String?,
        sequence: UInt64,
        editRevision: UInt64 = 0,
        expectedOriginalSuffix: String? = nil,
        createdAt: Date = Date(),
        automatic: Bool
    ) {
        self.original = original
        self.replacement = replacement
        self.expectedOriginalSuffix = expectedOriginalSuffix ?? original
        self.boundary = boundary
        self.focus = focus
        self.sourceLayoutID = sourceLayoutID
        self.targetLayoutID = targetLayoutID
        self.sequence = sequence
        self.editRevision = editRevision
        self.createdAt = createdAt
        self.automatic = automatic
    }
}

public struct ConversionExecutionIdentity: Hashable, Sendable {
    public let processID: Int32
    public let elementIdentifier: String?
    public let editRevision: UInt64
    public let sequence: UInt64

    public init(
        processID: Int32,
        elementIdentifier: String? = nil,
        editRevision: UInt64 = 0,
        sequence: UInt64
    ) {
        self.processID = processID
        self.elementIdentifier = elementIdentifier
        self.editRevision = editRevision
        self.sequence = sequence
    }
}

public struct ConversionExecutionGate: Equatable, Sendable {
    public private(set) var lastCommittedIdentity: ConversionExecutionIdentity?

    public init() {}

    public func isDuplicate(_ transaction: ConversionTransaction) -> Bool {
        lastCommittedIdentity == transaction.executionIdentity
    }

    public mutating func recordCommitted(_ transaction: ConversionTransaction) {
        lastCommittedIdentity = transaction.executionIdentity
    }
}

/// Pure description of the event-replay replacement. Keeping this as data makes
/// it impossible for the automatic path to introduce an intermediate selection,
/// and keeps insertion to exactly one text payload.
public struct EventReplacementPlan: Equatable, Sendable {
    public let backspaceCount: Int
    public let replacementText: String
    public let replayText: String

    public var insertedText: String { replacementText + replayText }

    public init(transaction: ConversionTransaction, deliveredKeyCount: Int) {
        backspaceCount = max(0, deliveredKeyCount)
        replacementText = transaction.replacement
        replayText = transaction.boundary.replayText
    }
}
