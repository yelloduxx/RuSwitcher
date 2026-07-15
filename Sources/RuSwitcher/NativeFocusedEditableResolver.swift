import ApplicationServices
import Foundation
import RuSwitcherAppSupport

enum NativeFocusedElementOperation<Value> {
    case value(Value)
    case unavailable(FocusedEditableLookupFailure)
}

struct NativeAXElementLease {
    let element: AXUIElement
    let identifier: String
    let source: FocusedEditableLookupSource
    private let deadlineNanoseconds: UInt64

    init(
        element: AXUIElement,
        identifier: String,
        source: FocusedEditableLookupSource,
        deadlineNanoseconds: UInt64
    ) {
        self.element = element
        self.identifier = identifier
        self.source = source
        self.deadlineNanoseconds = deadlineNanoseconds
    }

    func copyAttribute(_ attribute: CFString) -> (AXError, AnyObject?) {
        guard configureTimeout() else { return (.cannotComplete, nil) }
        var raw: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, attribute, &raw)
        return (error, raw)
    }

    func copyParameterizedAttribute(
        _ attribute: CFString,
        parameter: CFTypeRef
    ) -> (AXError, AnyObject?) {
        guard configureTimeout() else { return (.cannotComplete, nil) }
        var raw: AnyObject?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            attribute,
            parameter,
            &raw
        )
        return (error, raw)
    }

    func setAttribute(_ attribute: CFString, value: CFTypeRef) -> AXError {
        guard configureTimeout() else { return .cannotComplete }
        return AXUIElementSetAttributeValue(element, attribute, value)
    }

    private func configureTimeout() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadlineNanoseconds else { return false }
        let remaining = Float(deadlineNanoseconds - now) / 1_000_000_000
        return AXUIElementSetMessagingTimeout(element, max(0.001, remaining)) == .success
    }
}

final class NativeFocusedEditableResolver: @unchecked Sendable {
    private let engine = FocusedEditableResolver(backend: NativeAccessibilityTree())
    private let warmQueue = DispatchQueue(
        label: "com.ruswitcher.ax-focused-resolver",
        qos: .userInitiated
    )
    private let pendingLock = NSLock()
    private var pendingProcessIDs: Set<Int32> = []
    private let processLocksLock = NSLock()
    private var processLocks: [Int32: NSLock] = [:]

    func resolve(
        processID: Int32,
        expectedIdentifier: String? = nil,
        timeoutMilliseconds: Int,
        allowTreeSearch: Bool = false
    ) -> FocusedEditableLookup<AXUIElement> {
        let deadline = Date().addingTimeInterval(Double(max(1, timeoutMilliseconds)) / 1_000)
        let processLock = lock(for: processID)
        guard processLock.lock(before: deadline) else { return .unavailable(.timedOut) }
        defer { processLock.unlock() }
        return engine.resolve(
            processID: processID,
            expectedIdentifier: expectedIdentifier,
            timeoutMilliseconds: remainingMilliseconds(until: deadline),
            allowTreeSearch: allowTreeSearch
        )
    }

    func withElement<Value>(
        processID: Int32,
        expectedIdentifier: String? = nil,
        timeoutMilliseconds: Int,
        allowTreeSearch: Bool = false,
        operation: (NativeAXElementLease) -> Value
    ) -> NativeFocusedElementOperation<Value> {
        let timeout = max(1, timeoutMilliseconds)
        let deadlineDate = Date().addingTimeInterval(Double(timeout) / 1_000)
        let deadlineNanoseconds = DispatchTime.now().uptimeNanoseconds
            &+ UInt64(timeout) * 1_000_000
        let processLock = lock(for: processID)
        guard processLock.lock(before: deadlineDate) else { return .unavailable(.timedOut) }
        defer { processLock.unlock() }

        let lookup = engine.resolve(
            processID: processID,
            expectedIdentifier: expectedIdentifier,
            timeoutMilliseconds: remainingMilliseconds(until: deadlineDate),
            allowTreeSearch: allowTreeSearch
        )
        switch lookup {
        case let .resolved(resolution):
            let lease = NativeAXElementLease(
                element: resolution.element,
                identifier: resolution.identifier,
                source: resolution.source,
                deadlineNanoseconds: deadlineNanoseconds
            )
            return .value(operation(lease))
        case let .unavailable(failure):
            return .unavailable(failure)
        }
    }

    func cachedIdentifier(processID: Int32) -> String? {
        engine.cachedIdentifier(processID: processID)
    }

    /// Tree traversal is never performed from the event callback. The first
    /// printable key schedules a coalesced warm-up; boundary-time validation then
    /// reuses the focused element and only reads the exact suffix.
    func prefetch(processID: Int32) {
        guard processID > 0 else { return }
        pendingLock.lock()
        let inserted = pendingProcessIDs.insert(processID).inserted
        pendingLock.unlock()
        guard inserted else { return }

        warmQueue.async { [weak self] in
            guard let self else { return }
            _ = self.resolve(
                processID: processID,
                timeoutMilliseconds: 120,
                allowTreeSearch: true
            )
            self.pendingLock.lock()
            self.pendingProcessIDs.remove(processID)
            self.pendingLock.unlock()
        }
    }

    func invalidate(processID: Int32? = nil) {
        engine.invalidate(processID: processID)
    }

    private func lock(for processID: Int32) -> NSLock {
        processLocksLock.lock(); defer { processLocksLock.unlock() }
        if let existing = processLocks[processID] { return existing }
        let created = NSLock()
        processLocks[processID] = created
        return created
    }

    private func remainingMilliseconds(until deadline: Date) -> Int {
        max(1, Int(deadline.timeIntervalSinceNow * 1_000))
    }
}

private struct NativeAccessibilityTree: FocusedEditableTreeAccessing {
    typealias Element = AXUIElement

    func prepare(processID: Int32, timeoutMilliseconds: Int) {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, Float(max(1, timeoutMilliseconds)) / 1_000)
    }

    func canonicalFocusedElement(
        processID: Int32,
        timeoutMilliseconds: Int
    ) -> AccessibilityTreeRead<AXUIElement> {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, Float(max(1, timeoutMilliseconds)) / 1_000)
        return elementAttribute(app, kAXFocusedUIElementAttribute as CFString)
    }

    func searchRoot(
        processID: Int32,
        timeoutMilliseconds: Int
    ) -> AccessibilityTreeRead<AXUIElement> {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, Float(max(1, timeoutMilliseconds)) / 1_000)
        switch elementAttribute(app, kAXFocusedWindowAttribute as CFString) {
        case let .value(window):
            return .value(window)
        case .unavailable:
            return .value(app)
        }
    }

    func children(
        of element: AXUIElement,
        timeoutMilliseconds: Int
    ) -> AccessibilityTreeRead<[AXUIElement]> {
        configureTimeout(element, timeoutMilliseconds: timeoutMilliseconds)
        var raw: AnyObject?
        let error = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &raw
        )
        if error == .noValue || error == .attributeUnsupported {
            return .value([])
        }
        guard error == .success else { return .unavailable(failure(for: error)) }
        return .value(raw as? [AXUIElement] ?? [])
    }

    func isFocused(
        _ element: AXUIElement,
        timeoutMilliseconds: Int
    ) -> AccessibilityTreeRead<Bool> {
        configureTimeout(element, timeoutMilliseconds: timeoutMilliseconds)
        var raw: AnyObject?
        let error = AXUIElementCopyAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            &raw
        )
        if error == .noValue || error == .attributeUnsupported {
            return .value(false)
        }
        guard error == .success else { return .unavailable(failure(for: error)) }
        return .value((raw as? Bool) == true)
    }

    func isEditable(
        _ element: AXUIElement,
        timeoutMilliseconds: Int
    ) -> AccessibilityTreeRead<Bool> {
        configureTimeout(element, timeoutMilliseconds: timeoutMilliseconds)
        var roleRaw: AnyObject?
        let roleError = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleRaw
        )
        guard roleError == .success, let role = roleRaw as? String else {
            return roleError == .cannotComplete
                ? .unavailable(.timedOut)
                : .value(false)
        }
        let editableRoles: Set<String> = [
            kAXTextAreaRole as String,
            kAXTextFieldRole as String,
            kAXComboBoxRole as String,
        ]
        guard editableRoles.contains(role) else { return .value(false) }

        configureTimeout(element, timeoutMilliseconds: timeoutMilliseconds)
        var rangeRaw: AnyObject?
        let rangeError = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRaw
        )
        if rangeError == .noValue || rangeError == .attributeUnsupported {
            return .value(false)
        }
        guard rangeError == .success, let rangeRaw,
              CFGetTypeID(rangeRaw) == AXValueGetTypeID() else {
            return rangeError == .success
                ? .value(false)
                : .unavailable(failure(for: rangeError))
        }

        configureTimeout(element, timeoutMilliseconds: timeoutMilliseconds)
        var namesRaw: CFArray?
        let namesError = AXUIElementCopyParameterizedAttributeNames(element, &namesRaw)
        if namesError == .noValue || namesError == .attributeUnsupported {
            return .value(false)
        }
        guard namesError == .success else {
            return .unavailable(failure(for: namesError))
        }
        let names = namesRaw as? [String] ?? []
        return .value(names.contains(kAXStringForRangeParameterizedAttribute as String))
    }

    func identifier(for element: AXUIElement, timeoutMilliseconds: Int) -> String {
        configureTimeout(element, timeoutMilliseconds: timeoutMilliseconds)
        let elementHash = CFHash(element)
        var raw: AnyObject?
        if AXUIElementCopyAttributeValue(
            element,
            kAXIdentifierAttribute as CFString,
            &raw
        ) == .success,
           let identifier = raw as? String,
           !identifier.isEmpty {
            return "axid:\(CFHash(identifier as CFString))|axhash:\(elementHash)"
        }
        return "axhash:\(elementHash)"
    }

    private func elementAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> AccessibilityTreeRead<AXUIElement> {
        var raw: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, attribute, &raw)
        guard error == .success, let raw,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return .unavailable(failure(for: error))
        }
        return .value(unsafeDowncast(raw, to: AXUIElement.self))
    }

    private func failure(for error: AXError) -> FocusedEditableLookupFailure {
        switch error {
        case .cannotComplete:
            return .timedOut
        case .noValue, .attributeUnsupported:
            return .noFocusedElement
        default:
            return .noEditableElement
        }
    }

    private func configureTimeout(_ element: AXUIElement, timeoutMilliseconds: Int) {
        AXUIElementSetMessagingTimeout(
            element,
            Float(max(1, timeoutMilliseconds)) / 1_000
        )
    }
}
