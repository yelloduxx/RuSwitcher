import AppKit
import ApplicationServices
import Foundation
import RuSwitcherAppSupport
import RuSwitcherCore

/// Read-only AX safety probe. It never changes the selected range or value.
/// A strict deadline prevents a slow application from starving the event tap.
final class FocusedTextContextReader: FocusedTextContextReading, FocusedTextReplacing, @unchecked Sendable {
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

    private final class ReplacementCallbackBox: @unchecked Sendable {
        let callback: (ReplacementOutcome) -> Void

        init(_ callback: @escaping (ReplacementOutcome) -> Void) {
            self.callback = callback
        }
    }

    private let queue = DispatchQueue(label: "com.ruswitcher.ax-context", qos: .userInteractive)
    private let replacementQueue = DispatchQueue(
        label: "com.ruswitcher.ax-replacement",
        qos: .userInitiated
    )
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
        if let until = disabledUntil[key], until > Date() { return .unavailable }

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
            disabledUntil[key] = Date().addingTimeInterval(30)
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

    @MainActor
    func replaceSuffix(
        original: String,
        replacement: String,
        focus: FocusedElementIdentity,
        deadlineMilliseconds: Int,
        completion: @escaping (ReplacementOutcome) -> Void
    ) {
        guard !original.isEmpty else {
            completion(.blocked(.expectedSuffixMismatch))
            return
        }
        if focus.processID == ProcessInfo.processInfo.processIdentifier,
           let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            completion(Self.replaceLocalSuffix(
                original: original,
                replacement: replacement,
                editor: editor
            ))
            return
        }

        let callback = ReplacementCallbackBox(completion)
        replacementQueue.async {
            let outcome = Self.replaceExternalSuffix(
                original: original,
                replacement: replacement,
                focus: focus,
                deadlineMilliseconds: deadlineMilliseconds
            )
            DispatchQueue.main.async { callback.callback(outcome) }
        }
    }

    private static func readAndCompare(
        expectedSuffix: String,
        focus: FocusedElementIdentity,
        timeoutMilliseconds: Int
    ) -> TextContextValidation {
        guard let element = focusedElement(
            matching: focus,
            timeoutMilliseconds: timeoutMilliseconds
        ), let caret = selectedRange(from: element) else { return .unavailable }
        guard caret.length == 0 else { return .mismatch }

        let expectedLength = expectedSuffix.utf16.count
        guard caret.location >= expectedLength else { return .mismatch }
        let suffixRange = CFRange(location: caret.location - expectedLength, length: expectedLength)
        guard let actual = text(in: suffixRange, from: element) else { return .unavailable }
        return actual.precomposedStringWithCanonicalMapping
            == expectedSuffix.precomposedStringWithCanonicalMapping ? .match : .mismatch
    }

    @MainActor
    private static func replaceLocalSuffix(
        original: String,
        replacement: String,
        editor: NSTextView
    ) -> ReplacementOutcome {
        let caret = editor.selectedRange()
        let originalLength = original.utf16.count
        guard caret.length == 0, caret.location >= originalLength else {
            return .blocked(.expectedSuffixMismatch)
        }
        let range = NSRange(location: caret.location - originalLength, length: originalLength)
        guard (editor.string as NSString).substring(with: range)
            .precomposedStringWithCanonicalMapping
            == original.precomposedStringWithCanonicalMapping,
              let storage = editor.textStorage else {
            return .blocked(.expectedSuffixMismatch)
        }
        storage.replaceCharacters(in: range, with: replacement)
        editor.setSelectedRange(NSRange(
            location: range.location + replacement.utf16.count,
            length: 0
        ))
        let verificationRange = NSRange(
            location: range.location,
            length: replacement.utf16.count
        )
        guard NSMaxRange(verificationRange) <= (editor.string as NSString).length,
              (editor.string as NSString).substring(with: verificationRange)
                .precomposedStringWithCanonicalMapping
                == replacement.precomposedStringWithCanonicalMapping else {
            return .failed(.verificationMismatch)
        }
        return .verified
    }

    private static func replaceExternalSuffix(
        original: String,
        replacement: String,
        focus: FocusedElementIdentity,
        deadlineMilliseconds: Int
    ) -> ReplacementOutcome {
        let timeout = max(1, deadlineMilliseconds)
        let deadline = Date().addingTimeInterval(Double(timeout) / 1_000)
        guard let element = focusedElement(matching: focus, deadline: deadline),
              configureTimeout(on: element, deadline: deadline),
              let caret = selectedRange(from: element), caret.length == 0 else {
            return .blocked(.invalidFocus)
        }
        let originalLength = original.utf16.count
        guard caret.location >= originalLength else {
            return .blocked(.expectedSuffixMismatch)
        }
        let originalRange = CFRange(
            location: caret.location - originalLength,
            length: originalLength
        )
        guard text(in: originalRange, from: element, deadline: deadline)?
            .precomposedStringWithCanonicalMapping
            == original.precomposedStringWithCanonicalMapping else {
            return .blocked(.expectedSuffixMismatch)
        }
        guard configureTimeout(on: element, deadline: deadline),
              setSelectedRange(originalRange, on: element) else {
            return .blocked(.contextUnavailable)
        }
        guard configureTimeout(on: element, deadline: deadline),
              AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                replacement as CFString
              ) == .success else {
            AXUIElementSetMessagingTimeout(element, 0.01)
            _ = setSelectedRange(CFRange(location: caret.location, length: 0), on: element)
            return .failed(.verificationMismatch)
        }

        let replacementRange = CFRange(
            location: originalRange.location,
            length: replacement.utf16.count
        )
        repeat {
            if text(in: replacementRange, from: element, deadline: deadline)?
                .precomposedStringWithCanonicalMapping
                == replacement.precomposedStringWithCanonicalMapping {
                if configureTimeout(on: element, deadline: deadline) {
                    _ = setSelectedRange(
                        CFRange(
                            location: replacementRange.location + replacementRange.length,
                            length: 0
                        ),
                        on: element
                    )
                }
                return .verified
            }
            if Date() < deadline { usleep(5_000) }
        } while Date() < deadline

        // Never leave the editor with RuSwitcher's temporary suffix selection.
        AXUIElementSetMessagingTimeout(element, 0.01)
        _ = setSelectedRange(CFRange(location: caret.location, length: 0), on: element)
        return .failed(.verificationMismatch)
    }

    private static func readPrefix(
        focus: FocusedElementIdentity,
        timeoutMilliseconds: Int
    ) -> String? {
        guard let element = focusedElement(
            matching: focus,
            timeoutMilliseconds: timeoutMilliseconds
        ) else { return nil }
        guard let caret = selectedRange(from: element), caret.length == 0 else { return nil }

        let length = min(caret.location, InputContextLimits.maximumUTF8Bytes)
        let prefixRange = CFRange(location: caret.location - length, length: length)
        return text(in: prefixRange, from: element)
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
        AXUIElementSetMessagingTimeout(element, Float(max(1, timeoutMilliseconds)) / 1_000)
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

    private static func focusedElement(
        matching focus: FocusedElementIdentity,
        deadline: Date
    ) -> AXUIElement? {
        let app = AXUIElementCreateApplication(focus.processID)
        guard configureTimeout(on: app, deadline: deadline) else { return nil }
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
                guard configureTimeout(on: element, deadline: deadline) else { return nil }
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

    @discardableResult
    private static func configureTimeout(on element: AXUIElement, deadline: Date) -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return false }
        AXUIElementSetMessagingTimeout(element, Float(max(0.001, remaining)))
        return true
    }

    private static func selectedRange(from element: AXUIElement) -> CFRange? {
        var rangeRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRaw
        ) == .success, let rangeRaw,
          CFGetTypeID(rangeRaw) == AXValueGetTypeID() else { return nil }
        let rangeValue = unsafeDowncast(rangeRaw, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange,
              AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func setSelectedRange(_ range: CFRange, on element: AXUIElement) -> Bool {
        var mutableRange = range
        guard let value = AXValueCreate(.cfRange, &mutableRange) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        ) == .success
    }

    private static func text(
        in range: CFRange,
        from element: AXUIElement,
        deadline: Date? = nil
    ) -> String? {
        var mutableRange = range
        if deadline.map({ configureTimeout(on: element, deadline: $0) }) ?? true,
           let rangeValue = AXValueCreate(.cfRange, &mutableRange) {
            var textRaw: AnyObject?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                rangeValue,
                &textRaw
            ) == .success, let text = textRaw as? String {
                return text
            }
        }

        if let deadline, !configureTimeout(on: element, deadline: deadline) {
            return nil
        }
        var valueRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRaw
        ) == .success, let value = valueRaw as? String else { return nil }
        let nsValue = value as NSString
        guard range.location >= 0, range.length >= 0,
              range.location <= nsValue.length,
              range.length <= nsValue.length - range.location else { return nil }
        return nsValue.substring(with: NSRange(location: range.location, length: range.length))
    }

    private static func focusKey(_ focus: FocusedElementIdentity) -> String {
        "\(focus.processID):\(focus.identifier ?? "*")"
    }
}
