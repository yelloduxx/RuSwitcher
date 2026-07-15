import AppKit
import ApplicationServices
import Foundation
import RuSwitcherAppSupport
import RuSwitcherCore

/// Read-only AX safety probe. It never changes the selected range or value.
/// A strict deadline prevents a slow application from starving the event tap.
final class FocusedTextContextReader: FocusedTextContextReading, @unchecked Sendable {
    private static let timeoutCooldown: TimeInterval = 1

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TextContextValidation?

        func set(_ newValue: TextContextValidation) {
            lock.lock(); defer { lock.unlock() }
            value = newValue
        }

        func get() -> TextContextValidation? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    private final class CallbackBox: @unchecked Sendable {
        let callback: (TextContextValidation) -> Void

        init(_ callback: @escaping (TextContextValidation) -> Void) {
            self.callback = callback
        }
    }

    private let validationQueue = DispatchQueue(
        label: "com.ruswitcher.ax-validation",
        qos: .userInteractive
    )
    private let verificationQueue = DispatchQueue(
        label: "com.ruswitcher.ax-verification",
        qos: .userInitiated
    )
    private let focusedElementResolver: NativeFocusedEditableResolver
    private var disabledUntil: [String: Date] = [:]

    init(focusedElementResolver: NativeFocusedEditableResolver) {
        self.focusedElementResolver = focusedElementResolver
    }

    @MainActor
    func preflightDeadlineMilliseconds(for focus: FocusedElementIdentity) -> Int {
        ReplacementTiming.preflightDeadlineMilliseconds(
            isWarm: focusedElementResolver.cachedIdentifier(processID: focus.processID) != nil
        )
    }

    @MainActor
    func validate(
        expectedSuffix: String,
        focus: FocusedElementIdentity,
        deadlineMilliseconds: Int = 4
    ) -> TextContextValidation {
        guard !expectedSuffix.isEmpty else { return .unavailable }
        if focus.processID == ProcessInfo.processInfo.processIdentifier {
            if let actual = readLocalSuffix(utf16Length: expectedSuffix.utf16.count) {
                return actual.precomposedStringWithCanonicalMapping
                    == expectedSuffix.precomposedStringWithCanonicalMapping ? .match : .mismatch
            }
            return readAndCompare(
                expectedSuffix: expectedSuffix,
                focus: focus,
                timeoutMilliseconds: deadlineMilliseconds
            )
        }
        let key = Self.focusKey(focus)
        let isWarm = focusedElementResolver.cachedIdentifier(processID: focus.processID) != nil
        if let until = disabledUntil[key] {
            // A warm cache is allowed to retry immediately: Ghostty-class apps
            // often timeout once and then answer from the warmed element.
            if until > Date(), !isWarm {
                return .unavailable
            }
            disabledUntil.removeValue(forKey: key)
        }

        let effectiveDeadline = max(
            1,
            isWarm
                ? max(deadlineMilliseconds, ReplacementTiming.warmPreflightDeadlineMilliseconds)
                : deadlineMilliseconds
        )
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        validationQueue.async { [self] in
            let first = readAndCompare(
                expectedSuffix: expectedSuffix,
                focus: focus,
                timeoutMilliseconds: max(1, effectiveDeadline - 1)
            )
            if first == .mismatch {
                // Short tokens can reach the boundary before WebKit/Electron has
                // published the last character through AX. Retry once inside the
                // existing deadline; a real cursor/focus mismatch remains blocked.
                usleep(750)
                box.set(readAndCompare(
                    expectedSuffix: expectedSuffix,
                    focus: focus,
                    timeoutMilliseconds: max(1, effectiveDeadline - 1)
                ))
            } else {
                box.set(first)
            }
            semaphore.signal()
        }
        let timeout = DispatchTime.now() + .milliseconds(effectiveDeadline)
        guard semaphore.wait(timeout: timeout) == .success, let result = box.get() else {
            disabledUntil[key] = Date().addingTimeInterval(Self.timeoutCooldown)
            rslog("ax_probe_timeout")
            return .unavailable
        }
        if result == .match {
            disabledUntil.removeValue(forKey: key)
        }
        return result
    }

    @MainActor
    private func readLocalSuffix(utf16Length: Int) -> String? {
        guard utf16Length > 0,
              let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return nil }
        let selection = editor.selectedRange()
        guard selection.length == 0, selection.location >= utf16Length else { return nil }
        return (editor.string as NSString).substring(
            with: NSRange(location: selection.location - utf16Length, length: utf16Length)
        )
    }

    func verify(
        expectedSuffix: String,
        focus: FocusedElementIdentity,
        deadlineMilliseconds: Int,
        completion: @escaping (TextContextValidation) -> Void
    ) {
        let callback = CallbackBox(completion)
        verificationQueue.async { [self] in
            let deadline = Date().addingTimeInterval(Double(max(1, deadlineMilliseconds)) / 1_000)
            var result: TextContextValidation = .unavailable
            repeat {
                let remaining = max(1, Int(deadline.timeIntervalSinceNow * 1_000))
                result = readAndCompare(
                    expectedSuffix: expectedSuffix,
                    focus: focus,
                    timeoutMilliseconds: min(4, remaining)
                )
                if result == .match { break }
                if Date() < deadline { usleep(1_000) }
            } while Date() < deadline
            DispatchQueue.main.async { callback.callback(result) }
        }
    }

    private func readAndCompare(
        expectedSuffix: String,
        focus: FocusedElementIdentity,
        timeoutMilliseconds: Int
    ) -> TextContextValidation {
        let first = focusedElementResolver.withElement(
            processID: focus.processID,
            expectedIdentifier: focus.identifier,
            timeoutMilliseconds: timeoutMilliseconds,
            allowTreeSearch: false,
            operation: { lease in
                compareSuffix(expectedSuffix, lease: lease)
            }
        )
        switch first {
        case let .value(result):
            return result
        case let .unavailable(failure):
            // Stale cached focus identity must not hard-block auto conversion.
            // Retry once without the expected identifier, then treat remaining
            // identity issues as unavailable (post may still be allowed).
            if failure == .identifierMismatch, focus.identifier != nil {
                rslog("ax_identifier_mismatch")
                switch focusedElementResolver.withElement(
                    processID: focus.processID,
                    expectedIdentifier: nil,
                    timeoutMilliseconds: timeoutMilliseconds,
                    allowTreeSearch: false,
                    operation: { lease in
                        compareSuffix(expectedSuffix, lease: lease)
                    }
                ) {
                case let .value(result):
                    return result
                case let .unavailable(retryFailure):
                    logLookupFailure(retryFailure)
                    return .unavailable
                }
            }
            logLookupFailure(failure)
            return .unavailable
        }
    }

    private func compareSuffix(
        _ expectedSuffix: String,
        lease: NativeAXElementLease
    ) -> TextContextValidation {
        let rangeRead = lease.copyAttribute(kAXSelectedTextRangeAttribute as CFString)
        guard rangeRead.0 == .success, let rangeRaw = rangeRead.1,
          CFGetTypeID(rangeRaw) == AXValueGetTypeID() else {
            if rangeRead.0 == .cannotComplete {
                rslog("ax_timeout")
            } else {
                rslog("ax_no_range")
            }
            return .unavailable
        }
        let rangeValue = unsafeDowncast(rangeRaw, to: AXValue.self)
        var caret = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange,
              AXValueGetValue(rangeValue, .cfRange, &caret) else {
            rslog("ax_range_invalid")
            return .unavailable
        }
        guard caret.length == 0 else {
            rslog("ax_suffix_mismatch")
            return .mismatch
        }

        let expectedLength = expectedSuffix.utf16.count
        guard caret.location >= expectedLength else {
            rslog("ax_suffix_mismatch")
            return .mismatch
        }
        var suffixRange = CFRange(location: caret.location - expectedLength, length: expectedLength)
        guard let suffixValue = AXValueCreate(.cfRange, &suffixRange) else { return .unavailable }
        let suffixRead = lease.copyParameterizedAttribute(
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter: suffixValue
        )
        guard suffixRead.0 == .success, let actual = suffixRead.1 as? String else {
            if suffixRead.0 == .cannotComplete {
                rslog("ax_timeout")
            } else {
                rslog("ax_no_string_for_range")
            }
            return .unavailable
        }
        let matches = actual.precomposedStringWithCanonicalMapping
            == expectedSuffix.precomposedStringWithCanonicalMapping
        if !matches { rslog("ax_suffix_mismatch") }
        return matches ? .match : .mismatch
    }

    private func logLookupFailure(_ failure: FocusedEditableLookupFailure) {
        switch failure {
        case .noFocusedElement:
            rslog("ax_no_focused")
        case .noEditableElement:
            rslog("ax_no_editable")
        case .ambiguousFocusedElements:
            rslog("ax_ambiguous_focused")
        case .timedOut:
            rslog("ax_timeout")
        case .identifierMismatch:
            rslog("ax_identifier_mismatch")
        }
    }

    private static func focusKey(_ focus: FocusedElementIdentity) -> String {
        "\(focus.processID):\(focus.identifier ?? "*")"
    }
}
