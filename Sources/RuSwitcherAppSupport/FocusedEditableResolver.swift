import Foundation

public enum FocusedEditableLookupFailure: Equatable, Sendable {
    case noFocusedElement
    case noEditableElement
    case ambiguousFocusedElements
    case timedOut
    case identifierMismatch
}

public enum FocusedEditableLookupSource: Equatable, Sendable {
    case cached
    case canonical
    case nested
}

public enum AccessibilityTreeRead<Value> {
    case value(Value)
    case unavailable(FocusedEditableLookupFailure)
}

public struct FocusedEditableResolution<Element> {
    public let element: Element
    public let identifier: String
    public let source: FocusedEditableLookupSource

    public init(
        element: Element,
        identifier: String,
        source: FocusedEditableLookupSource
    ) {
        self.element = element
        self.identifier = identifier
        self.source = source
    }
}

public enum FocusedEditableLookup<Element> {
    case resolved(FocusedEditableResolution<Element>)
    case unavailable(FocusedEditableLookupFailure)
}

public protocol FocusedEditableTreeAccessing {
    associatedtype Element: AnyObject

    func prepare(processID: Int32, timeoutMilliseconds: Int)
    func canonicalFocusedElement(
        processID: Int32,
        timeoutMilliseconds: Int
    ) -> AccessibilityTreeRead<Element>
    func searchRoot(
        processID: Int32,
        timeoutMilliseconds: Int
    ) -> AccessibilityTreeRead<Element>
    func children(
        of element: Element,
        timeoutMilliseconds: Int
    ) -> AccessibilityTreeRead<[Element]>
    func isFocused(
        _ element: Element,
        timeoutMilliseconds: Int
    ) -> AccessibilityTreeRead<Bool>
    func isEditable(
        _ element: Element,
        timeoutMilliseconds: Int
    ) -> AccessibilityTreeRead<Bool>
    func identifier(
        for element: Element,
        timeoutMilliseconds: Int
    ) -> String
}

/// Resolves the actual editable AX descendant while keeping the hot path bounded.
/// A background warm-up may traverse the tree; boundary-time lookups use only the
/// canonical focused element or a previously validated cache entry.
public final class FocusedEditableResolver<Backend: FocusedEditableTreeAccessing>: @unchecked Sendable {
    private struct CachedElement {
        let element: Backend.Element
        let identifier: String
        let editableVerified: Bool
        let storedAtNanoseconds: UInt64
    }

    private struct PendingNode {
        let element: Backend.Element
        let depth: Int
    }

    private let backend: Backend
    private let maximumTraversalNodes: Int
    private let maximumTraversalDepth: Int
    private let cacheLifetimeNanoseconds: UInt64
    private let nowNanoseconds: @Sendable () -> UInt64
    private let lock = NSLock()
    private var cache: [Int32: CachedElement] = [:]

    public init(
        backend: Backend,
        maximumTraversalNodes: Int = 1_500,
        maximumTraversalDepth: Int = 48,
        cacheLifetimeMilliseconds: Int = 30_000,
        nowNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.backend = backend
        self.maximumTraversalNodes = max(1, maximumTraversalNodes)
        self.maximumTraversalDepth = max(1, maximumTraversalDepth)
        self.cacheLifetimeNanoseconds = UInt64(max(1, cacheLifetimeMilliseconds)) * 1_000_000
        self.nowNanoseconds = nowNanoseconds
    }

    public func resolve(
        processID: Int32,
        expectedIdentifier: String? = nil,
        timeoutMilliseconds: Int,
        allowTreeSearch: Bool
    ) -> FocusedEditableLookup<Backend.Element> {
        guard processID > 0 else { return .unavailable(.noFocusedElement) }
        let timeout = max(1, timeoutMilliseconds)
        let startedAt = nowNanoseconds()
        let deadline = startedAt &+ UInt64(timeout) * 1_000_000
        backend.prepare(processID: processID, timeoutMilliseconds: timeout)

        if let cached = cachedElement(processID: processID, now: startedAt) {
            guard expectedIdentifier == nil || expectedIdentifier == cached.identifier else {
                return .unavailable(.identifierMismatch)
            }
            switch backend.isFocused(
                cached.element,
                timeoutMilliseconds: remainingMilliseconds(until: deadline)
            ) {
            case .value(true) where !allowTreeSearch || cached.editableVerified:
                return .resolved(FocusedEditableResolution(
                    element: cached.element,
                    identifier: cached.identifier,
                    source: .cached
                ))
            case .value(true):
                switch backend.isEditable(
                    cached.element,
                    timeoutMilliseconds: remainingMilliseconds(until: deadline)
                ) {
                case .value(true):
                    store(
                        cached.element,
                        identifier: cached.identifier,
                        editableVerified: true,
                        processID: processID
                    )
                    return .resolved(FocusedEditableResolution(
                        element: cached.element,
                        identifier: cached.identifier,
                        source: .cached
                    ))
                case .value(false):
                    removeCachedElement(processID: processID, identifier: cached.identifier)
                case let .unavailable(failure):
                    return .unavailable(failure)
                }
            case .value(false):
                removeCachedElement(processID: processID, identifier: cached.identifier)
            case let .unavailable(failure):
                if !allowTreeSearch { return .unavailable(failure) }
                removeCachedElement(processID: processID, identifier: cached.identifier)
            }
        }

        let canonical = backend.canonicalFocusedElement(
            processID: processID,
            timeoutMilliseconds: remainingMilliseconds(until: deadline)
        )
        switch canonical {
        case let .value(element):
            let identifier = backend.identifier(
                for: element,
                timeoutMilliseconds: remainingMilliseconds(until: deadline)
            )
            guard expectedIdentifier == nil || expectedIdentifier == identifier else {
                return .unavailable(.identifierMismatch)
            }
            if !allowTreeSearch {
                store(
                    element,
                    identifier: identifier,
                    editableVerified: false,
                    processID: processID
                )
                return .resolved(FocusedEditableResolution(
                    element: element,
                    identifier: identifier,
                    source: .canonical
                ))
            }
            switch backend.isEditable(
                element,
                timeoutMilliseconds: remainingMilliseconds(until: deadline)
            ) {
            case .value(true):
                store(
                    element,
                    identifier: identifier,
                    editableVerified: true,
                    processID: processID
                )
                return .resolved(FocusedEditableResolution(
                    element: element,
                    identifier: identifier,
                    source: .canonical
                ))
            case .value(false):
                break
            case let .unavailable(failure):
                if failure == .timedOut { return .unavailable(failure) }
            }
        case let .unavailable(failure):
            if !allowTreeSearch { return .unavailable(failure) }
        }

        guard allowTreeSearch else { return .unavailable(.noEditableElement) }
        guard remainingMilliseconds(until: deadline) > 0 else {
            return .unavailable(.timedOut)
        }
        return searchNested(
            processID: processID,
            expectedIdentifier: expectedIdentifier,
            deadlineNanoseconds: deadline
        )
    }

    public func cachedIdentifier(processID: Int32) -> String? {
        cachedElement(processID: processID, now: nowNanoseconds())?.identifier
    }

    public func invalidate(processID: Int32? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let processID {
            cache.removeValue(forKey: processID)
        } else {
            cache.removeAll(keepingCapacity: true)
        }
    }

    private func searchNested(
        processID: Int32,
        expectedIdentifier: String?,
        deadlineNanoseconds: UInt64
    ) -> FocusedEditableLookup<Backend.Element> {
        let rootRead = backend.searchRoot(
            processID: processID,
            timeoutMilliseconds: remainingMilliseconds(until: deadlineNanoseconds)
        )
        let root: Backend.Element
        switch rootRead {
        case let .value(value):
            root = value
        case let .unavailable(failure):
            return .unavailable(failure)
        }

        var queue = [PendingNode(element: root, depth: 0)]
        var index = 0
        var candidate: (element: Backend.Element, identifier: String)?
        var sawIdentifierMismatch = false
        while index < queue.count, index < maximumTraversalNodes {
            guard remainingMilliseconds(until: deadlineNanoseconds) > 0 else {
                return .unavailable(.timedOut)
            }
            let node = queue[index]
            index += 1

            let focused = backend.isFocused(
                node.element,
                timeoutMilliseconds: remainingMilliseconds(until: deadlineNanoseconds)
            )
            if case .value(true) = focused {
                let editable = backend.isEditable(
                    node.element,
                    timeoutMilliseconds: remainingMilliseconds(until: deadlineNanoseconds)
                )
                if case .value(true) = editable {
                    let identifier = backend.identifier(
                        for: node.element,
                        timeoutMilliseconds: remainingMilliseconds(until: deadlineNanoseconds)
                    )
                    if let expectedIdentifier, expectedIdentifier != identifier {
                        sawIdentifierMismatch = true
                    } else if let existing = candidate, existing.identifier != identifier {
                        return .unavailable(.ambiguousFocusedElements)
                    } else {
                        candidate = (node.element, identifier)
                    }
                }
            } else if case let .unavailable(failure) = focused, failure == .timedOut {
                return .unavailable(.timedOut)
            }

            guard node.depth < maximumTraversalDepth else { continue }
            switch backend.children(
                of: node.element,
                timeoutMilliseconds: remainingMilliseconds(until: deadlineNanoseconds)
            ) {
            case let .value(children):
                queue.append(contentsOf: children.map {
                    PendingNode(element: $0, depth: node.depth + 1)
                })
            case let .unavailable(failure):
                if failure == .timedOut { return .unavailable(.timedOut) }
            }
        }
        guard index == queue.count else { return .unavailable(.timedOut) }
        if let candidate {
            store(
                candidate.element,
                identifier: candidate.identifier,
                editableVerified: true,
                processID: processID
            )
            return .resolved(FocusedEditableResolution(
                element: candidate.element,
                identifier: candidate.identifier,
                source: .nested
            ))
        }
        if sawIdentifierMismatch { return .unavailable(.identifierMismatch) }
        return .unavailable(.noEditableElement)
    }

    private func remainingMilliseconds(until deadline: UInt64) -> Int {
        let now = nowNanoseconds()
        guard now < deadline else { return 0 }
        return max(1, Int((deadline - now + 999_999) / 1_000_000))
    }

    private func cachedElement(processID: Int32, now: UInt64) -> CachedElement? {
        lock.lock(); defer { lock.unlock() }
        guard let cached = cache[processID] else { return nil }
        guard now >= cached.storedAtNanoseconds,
              now - cached.storedAtNanoseconds <= cacheLifetimeNanoseconds else {
            cache.removeValue(forKey: processID)
            return nil
        }
        return cached
    }

    private func store(
        _ element: Backend.Element,
        identifier: String,
        editableVerified: Bool,
        processID: Int32
    ) {
        lock.lock(); defer { lock.unlock() }
        cache[processID] = CachedElement(
            element: element,
            identifier: identifier,
            editableVerified: editableVerified,
            storedAtNanoseconds: nowNanoseconds()
        )
    }

    private func removeCachedElement(processID: Int32, identifier: String) {
        lock.lock(); defer { lock.unlock() }
        guard cache[processID]?.identifier == identifier else { return }
        cache.removeValue(forKey: processID)
    }
}
