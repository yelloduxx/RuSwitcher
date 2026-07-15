import AppKit
import ApplicationServices
import Foundation
import RuSwitcherAppSupport
import RuSwitcherCore

/// Read-only AX safety probe. It never changes the selected range or value.
/// A strict deadline prevents a slow application from starving the event tap.
final class FocusedTextContextReader: FocusedTextContextReading, @unchecked Sendable {
    private static let timeoutCooldown: TimeInterval = 1

    private struct CachedPrefix {
        let text: String
        let capturedAt: Date
    }

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

    private let queue = DispatchQueue(label: "com.ruswitcher.ax-context", qos: .userInteractive)
    private var disabledUntil: [String: Date] = [:]
    private let cacheLock = NSLock()
    private var prefixCache: [String: CachedPrefix] = [:]

    func cachedPrefix(for focus: FocusedElementIdentity, maximumAge: TimeInterval = 2) -> String? {
        let key = Self.focusKey(focus)
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard let cached = prefixCache[key], Date().timeIntervalSince(cached.capturedAt) <= maximumAge else {
            prefixCache.removeValue(forKey: key)
            return nil
        }
        return cached.text
    }

    /// Refreshes context for the next token. The event callback never waits for this
    /// read, and the cache is scoped to the focused AX element.
    func prefetchPrefix(for focus: FocusedElementIdentity) {
        let key = Self.focusKey(focus)
        queue.async { [weak self] in
            guard let self, let text = Self.readPrefix(focus: focus, timeoutMilliseconds: 20) else { return }
            self.cacheLock.lock()
            self.prefixCache[key] = CachedPrefix(text: text, capturedAt: Date())
            if self.prefixCache.count > 64 {
                self.prefixCache = [key: CachedPrefix(text: text, capturedAt: Date())]
            }
            self.cacheLock.unlock()
        }
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
            return Self.readAndCompare(
                expectedSuffix: expectedSuffix,
                focus: focus,
                timeoutMilliseconds: deadlineMilliseconds
            )
        }
        let key = Self.focusKey(focus)
        if let until = disabledUntil[key] {
            if until > Date() { return .unavailable }
            disabledUntil.removeValue(forKey: key)
        }

        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        queue.async {
            let first = Self.readAndCompare(
                expectedSuffix: expectedSuffix,
                focus: focus,
                timeoutMilliseconds: max(1, deadlineMilliseconds - 1)
            )
            if first == .mismatch {
                // Short tokens can reach the boundary before WebKit/Electron has
                // published the last character through AX. Retry once inside the
                // existing deadline; a real cursor/focus mismatch remains blocked.
                usleep(750)
                box.set(Self.readAndCompare(
                    expectedSuffix: expectedSuffix,
                    focus: focus,
                    timeoutMilliseconds: max(1, deadlineMilliseconds - 1)
                ))
            } else {
                box.set(first)
            }
            semaphore.signal()
        }
        let timeout = DispatchTime.now() + .milliseconds(max(1, deadlineMilliseconds))
        guard semaphore.wait(timeout: timeout) == .success, let result = box.get() else {
            disabledUntil[key] = Date().addingTimeInterval(Self.timeoutCooldown)
            rslog("ax_probe_timeout")
            return .unavailable
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
        queue.async {
            let deadline = Date().addingTimeInterval(Double(max(1, deadlineMilliseconds)) / 1_000)
            var result: TextContextValidation = .unavailable
            repeat {
                let remaining = max(1, Int(deadline.timeIntervalSinceNow * 1_000))
                result = Self.readAndCompare(
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

    private static func readAndCompare(
        expectedSuffix: String,
        focus: FocusedElementIdentity,
        timeoutMilliseconds: Int
    ) -> TextContextValidation {
        let app = AXUIElementCreateApplication(focus.processID)
        AXUIElementSetMessagingTimeout(app, Float(max(1, timeoutMilliseconds)) / 1_000)
        var focusedRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRaw
        ) == .success, let focusedRaw,
          CFGetTypeID(focusedRaw) == AXUIElementGetTypeID() else { return .unavailable }
        let element = unsafeDowncast(focusedRaw, to: AXUIElement.self)

        if let expectedIdentifier = focus.identifier {
            if expectedIdentifier.hasPrefix("axhash:") {
                guard expectedIdentifier == "axhash:\(CFHash(element))" else { return .mismatch }
            } else {
                var identifierRaw: AnyObject?
                guard AXUIElementCopyAttributeValue(
                    element,
                    kAXIdentifierAttribute as CFString,
                    &identifierRaw
                ) == .success,
                identifierRaw as? String == expectedIdentifier else { return .mismatch }
            }
        }

        var rangeRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRaw
        ) == .success, let rangeRaw,
          CFGetTypeID(rangeRaw) == AXValueGetTypeID() else { return .unavailable }
        let rangeValue = unsafeDowncast(rangeRaw, to: AXValue.self)
        var caret = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange,
              AXValueGetValue(rangeValue, .cfRange, &caret) else { return .unavailable }
        guard caret.length == 0 else { return .mismatch }

        let expectedLength = expectedSuffix.utf16.count
        guard caret.location >= expectedLength else { return .mismatch }
        var suffixRange = CFRange(location: caret.location - expectedLength, length: expectedLength)
        guard let suffixValue = AXValueCreate(.cfRange, &suffixRange) else { return .unavailable }
        var suffixRaw: AnyObject?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            suffixValue,
            &suffixRaw
        )
        guard error == .success, let actual = suffixRaw as? String else { return .unavailable }
        return actual.precomposedStringWithCanonicalMapping
            == expectedSuffix.precomposedStringWithCanonicalMapping ? .match : .mismatch
    }

    private static func readPrefix(
        focus: FocusedElementIdentity,
        timeoutMilliseconds: Int
    ) -> String? {
        guard let element = focusedElement(
            matching: focus,
            timeoutMilliseconds: timeoutMilliseconds
        ) else { return nil }
        var rangeRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRaw
        ) == .success, let rangeRaw,
          CFGetTypeID(rangeRaw) == AXValueGetTypeID() else { return nil }
        let rangeValue = unsafeDowncast(rangeRaw, to: AXValue.self)
        var caret = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange,
              AXValueGetValue(rangeValue, .cfRange, &caret),
              caret.length == 0 else { return nil }

        let length = min(caret.location, InputContextLimits.maximumUTF8Bytes)
        var prefixRange = CFRange(location: caret.location - length, length: length)
        guard let prefixValue = AXValueCreate(.cfRange, &prefixRange) else { return nil }
        var prefixRaw: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            prefixValue,
            &prefixRaw
        ) == .success else { return nil }
        return prefixRaw as? String
    }

    private static func focusedElement(
        matching focus: FocusedElementIdentity,
        timeoutMilliseconds: Int
    ) -> AXUIElement? {
        let app = AXUIElementCreateApplication(focus.processID)
        AXUIElementSetMessagingTimeout(app, Float(max(1, timeoutMilliseconds)) / 1_000)
        var focusedRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRaw
        ) == .success, let focusedRaw,
          CFGetTypeID(focusedRaw) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(focusedRaw, to: AXUIElement.self)
        if let expectedIdentifier = focus.identifier {
            if expectedIdentifier.hasPrefix("axhash:") {
                guard expectedIdentifier == "axhash:\(CFHash(element))" else { return nil }
            } else {
                var identifierRaw: AnyObject?
                guard AXUIElementCopyAttributeValue(
                    element,
                    kAXIdentifierAttribute as CFString,
                    &identifierRaw
                ) == .success,
                identifierRaw as? String == expectedIdentifier else { return nil }
            }
        }
        return element
    }

    private static func focusKey(_ focus: FocusedElementIdentity) -> String {
        "\(focus.processID):\(focus.identifier ?? "*")"
    }
}
