import Foundation
import RuSwitcherCore

/// Reads the focused AX element identifier. Implementations must apply the
/// supplied timeout to every AX message they send.
public protocol FocusedElementIdentifierReading: AnyObject, Sendable {
    func identifier(processID: Int32, timeoutMilliseconds: Int) -> String?
}

/// Keeps AX work off the event-tap callback and bounds how long the callback
/// can wait for focus identity. A timeout preserves the existing nil-identifier
/// fallback without blocking the input stream.
public final class FocusedElementIdentityResolver: @unchecked Sendable {
    public static let eventTapDeadlineMilliseconds = ReplacementTiming.preflightDeadlineMilliseconds

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?

        func set(_ value: String?) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func get() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class AsyncResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private let completion: @Sendable (FocusedElementIdentity) -> Void

        init(completion: @escaping @Sendable (FocusedElementIdentity) -> Void) {
            self.completion = completion
        }

        func finish(_ focus: FocusedElementIdentity) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            lock.unlock()
            completion(focus)
        }
    }

    private let reader: any FocusedElementIdentifierReading
    private let queue = DispatchQueue(
        label: "com.ruswitcher.ax-focus-identity",
        qos: .userInteractive,
        attributes: .concurrent
    )

    public init(reader: any FocusedElementIdentifierReading) {
        self.reader = reader
    }

    public func resolve(
        processID: Int32,
        bundleID: String?,
        autoConvertEnabled: Bool,
        deadlineMilliseconds: Int = FocusedElementIdentityResolver.eventTapDeadlineMilliseconds
    ) -> FocusedElementIdentity {
        guard autoConvertEnabled else {
            return FocusedElementIdentity(processID: processID, bundleID: bundleID)
        }

        let deadline = max(1, deadlineMilliseconds)
        let box = ResultBox()
        let completion = DispatchSemaphore(value: 0)
        queue.async { [reader] in
            box.set(reader.identifier(
                processID: processID,
                timeoutMilliseconds: deadline
            ))
            completion.signal()
        }

        let waitResult = completion.wait(
            timeout: .now() + .milliseconds(deadline)
        )
        let identifier = waitResult == .success ? box.get() : nil
        return FocusedElementIdentity(
            processID: processID,
            bundleID: bundleID,
            identifier: identifier
        )
    }

    public func resolveAsync(
        processID: Int32,
        bundleID: String?,
        deadlineMilliseconds: Int,
        completion: @escaping @Sendable (FocusedElementIdentity) -> Void
    ) {
        let deadline = max(1, deadlineMilliseconds)
        let result = AsyncResultBox(completion: completion)
        queue.async { [reader] in
            result.finish(FocusedElementIdentity(
                processID: processID,
                bundleID: bundleID,
                identifier: reader.identifier(
                    processID: processID,
                    timeoutMilliseconds: deadline
                )
            ))
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(deadline)) {
            result.finish(FocusedElementIdentity(
                processID: processID,
                bundleID: bundleID
            ))
        }
    }
}
