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

    private static func focusKey(_ focus: FocusedElementIdentity) -> String {
        "\(focus.processID):\(focus.identifier ?? "*")"
    }
}
