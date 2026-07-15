import Foundation
import RuSwitcherCore

public enum TextContextValidation: Equatable, Sendable {
    case match
    case mismatch
    case unavailable
}

public enum ReplacementBlockReason: Equatable, Sendable {
    case invalidFocus
    case staleRevision
    case expectedSuffixMismatch
    case contextUnavailable
    case duplicateTransaction
    case secureInput
    case deniedApplication
}

public enum ReplacementFailure: Equatable, Sendable {
    case eventPostFailed
    case verificationMismatch
}

public enum ReplacementOutcome: Equatable, Sendable {
    case verified
    case postedUnverified
    case switchedOnly
    case blocked(ReplacementBlockReason)
    case failed(ReplacementFailure)
}

public enum ReplacementTiming {
    /// Cold boundary: no validated focused editable in the resolver cache yet.
    public static let preflightDeadlineMilliseconds = 4
    /// Warm boundary: a focused editable was already resolved for this process.
    /// Ghostty-class AX latency often needs ~5–15 ms just for range/string reads.
    public static let warmPreflightDeadlineMilliseconds = 16
    public static let postedEventVerificationDeadlineMilliseconds = 120

    public static func preflightDeadlineMilliseconds(isWarm: Bool) -> Int {
        isWarm ? warmPreflightDeadlineMilliseconds : preflightDeadlineMilliseconds
    }
}

public struct ReplacementRequest: Equatable, Sendable {
    public let transaction: ConversionTransaction
    public let deliveredKeyCount: Int
    public let currentFocus: FocusedElementIdentity
    public let currentRevision: UInt64
    /// When true, a missing AX context still posts the replacement (event path).
    /// Used for automatic conversion: blocking on dark AX made auto dead in
    /// Notes/Telegram/etc. Mismatch still blocks.
    public let allowUnavailablePreflight: Bool

    public init(
        transaction: ConversionTransaction,
        deliveredKeyCount: Int,
        currentFocus: FocusedElementIdentity,
        currentRevision: UInt64,
        allowUnavailablePreflight: Bool = false
    ) {
        self.transaction = transaction
        self.deliveredKeyCount = deliveredKeyCount
        self.currentFocus = currentFocus
        self.currentRevision = currentRevision
        self.allowUnavailablePreflight = allowUnavailablePreflight
    }
}

public protocol FocusedTextContextReading: AnyObject {
    @MainActor
    func preflightDeadlineMilliseconds(for focus: FocusedElementIdentity) -> Int

    @MainActor
    func validate(
        expectedSuffix: String,
        focus: FocusedElementIdentity,
        deadlineMilliseconds: Int
    ) -> TextContextValidation

    func verify(
        expectedSuffix: String,
        focus: FocusedElementIdentity,
        deadlineMilliseconds: Int,
        completion: @escaping (TextContextValidation) -> Void
    )
}

@MainActor
public protocol SelectedTextReplacing: AnyObject {
    func replaceSelectedText(
        with replacement: String,
        completion: @escaping (ReplacementOutcome) -> Void
    )
}

@MainActor
public protocol KeyboardEventPosting: AnyObject {
    func post(_ plan: EventReplacementPlan, to processID: Int32) -> Bool
}

@MainActor
public protocol KeyboardLayoutSwitching: AnyObject {
    func switchTo(layoutID: String?)
}

@MainActor
public protocol ReplacementCoordinating: AnyObject {
    @discardableResult
    func submit(
        _ request: ReplacementRequest,
        completion: @escaping (ReplacementOutcome) -> Void
    ) -> ReplacementOutcome
}

@MainActor
public final class NativeReplacementCoordinator: ReplacementCoordinating {
    private let reader: FocusedTextContextReading
    private let poster: KeyboardEventPosting
    private let lock = NSLock()
    private var committedIdentities: [ConversionExecutionIdentity] = []

    public init(reader: FocusedTextContextReading, poster: KeyboardEventPosting) {
        self.reader = reader
        self.poster = poster
    }

    @discardableResult
    public func submit(
        _ request: ReplacementRequest,
        completion: @escaping (ReplacementOutcome) -> Void
    ) -> ReplacementOutcome {
        let transaction = request.transaction
        guard transaction.focus == request.currentFocus else {
            return .blocked(.invalidFocus)
        }
        guard transaction.editRevision == request.currentRevision else {
            return .blocked(.staleRevision)
        }

        lock.lock()
        let duplicate = committedIdentities.contains(transaction.executionIdentity)
        lock.unlock()
        guard !duplicate else { return .blocked(.duplicateTransaction) }

        let preflightDeadline = reader.preflightDeadlineMilliseconds(for: transaction.focus)
        let preflight = reader.validate(
            expectedSuffix: transaction.expectedOriginalSuffix,
            focus: transaction.focus,
            deadlineMilliseconds: preflightDeadline
        )
        guard preflight != .mismatch else {
            return .blocked(.expectedSuffixMismatch)
        }
        guard preflight != .unavailable || request.allowUnavailablePreflight else {
            return .blocked(.contextUnavailable)
        }

        let plan = EventReplacementPlan(
            transaction: transaction,
            deliveredKeyCount: request.deliveredKeyCount
        )
        guard poster.post(plan, to: transaction.focus.processID) else {
            return .failed(.eventPostFailed)
        }

        lock.lock()
        committedIdentities.append(transaction.executionIdentity)
        if committedIdentities.count > 64 {
            committedIdentities.removeFirst(committedIdentities.count - 64)
        }
        lock.unlock()

        let expected = transaction.replacement + transaction.boundary.replayText
        reader.verify(
            expectedSuffix: expected,
            focus: transaction.focus,
            deadlineMilliseconds: ReplacementTiming.postedEventVerificationDeadlineMilliseconds
        ) { result in
            switch result {
            case .match:
                completion(.verified)
            case .unavailable:
                completion(.postedUnverified)
            case .mismatch:
                completion(.failed(.verificationMismatch))
            }
        }
        return .postedUnverified
    }
}
