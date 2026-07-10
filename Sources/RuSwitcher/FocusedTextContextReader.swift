import AppKit
import ApplicationServices
import Foundation
import RuSwitcherCore

enum TextContextValidation: Equatable {
    case match
    case mismatch
    case unavailable
}

/// Read-only AX safety probe. It never changes the selected range or value.
/// A strict deadline prevents a slow application from starving the event tap.
final class FocusedTextContextReader: @unchecked Sendable {
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
            guard let self, let text = Self.readPrefix(focus: focus) else { return }
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
        let key = Self.focusKey(focus)
        if let until = disabledUntil[key], until > Date() { return .unavailable }

        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        queue.async {
            box.set(Self.readAndCompare(expectedSuffix: expectedSuffix, focus: focus))
            semaphore.signal()
        }
        let timeout = DispatchTime.now() + .milliseconds(max(1, deadlineMilliseconds))
        guard semaphore.wait(timeout: timeout) == .success, let result = box.get() else {
            disabledUntil[key] = Date().addingTimeInterval(30)
            rslog("ax-probe: timeout len=\(expectedSuffix.count)")
            return .unavailable
        }
        return result
    }

    private static func readAndCompare(
        expectedSuffix: String,
        focus: FocusedElementIdentity
    ) -> TextContextValidation {
        let app = AXUIElementCreateApplication(focus.processID)
        var focusedRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRaw
        ) == .success, let focusedRaw else { return .unavailable }
        let element = focusedRaw as! AXUIElement

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
        ) == .success, let rangeRaw else { return .unavailable }
        let rangeValue = rangeRaw as! AXValue
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

    private static func readPrefix(focus: FocusedElementIdentity) -> String? {
        guard let element = focusedElement(matching: focus) else { return nil }
        var rangeRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRaw
        ) == .success, let rangeRaw else { return nil }
        let rangeValue = rangeRaw as! AXValue
        var caret = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange,
              AXValueGetValue(rangeValue, .cfRange, &caret),
              caret.length == 0 else { return nil }

        let length = min(caret.location, ContextSnapshot.maximumUTF8Bytes)
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

    private static func focusedElement(matching focus: FocusedElementIdentity) -> AXUIElement? {
        let app = AXUIElementCreateApplication(focus.processID)
        var focusedRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRaw
        ) == .success, let focusedRaw else { return nil }
        let element = focusedRaw as! AXUIElement
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
