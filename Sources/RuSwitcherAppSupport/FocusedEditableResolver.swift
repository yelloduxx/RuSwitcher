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
        guard hasTime(until: deadline) else { return .unavailable(.timedOut) }

        if let cached = cachedElement(processID: processID, now: nowNanoseconds()),
           expectedIdentifier == nil || expectedIdentifier == cached.identifier {
            switch backend.isFocused(
                cached.element,
                timeoutMilliseconds: remainingMilliseconds(until: deadline)
            ) {
            case .value(true):
                guard hasTime(until: deadline) else { return .unavailable(.timedOut) }
                // Cached elements were proven editable before storage. The live
                // focused check plus the caller's exact range/suffix read is the
                // bounded hot-path validation.
                return .resolved(FocusedEditableResolution(
                    element: cached.element,
                    identifier: cached.identifier,
                    source: .cached
                ))
            case .value(false):
                guard hasTime(until: deadline) else { return .unavailable(.timedOut) }
                removeCachedElement(processID: processID, identifier: cached.identifier)
            case let .unavailable(failure):
                guard hasTime(until: deadline) else { return .unavailable(.timedOut) }
                if !allowTreeSearch { return .unavailable(failure) }
                removeCachedElement(processID: processID, identifier: cached.identifier)
            }
        }

        guard hasTime(until: deadline) else { return .unavailable(.timedOut) }
        let canonical = backend.canonicalFocusedElement(
            processID: processID,
            timeoutMilliseconds: remainingMilliseconds(until: deadline)
        )
        guard hasTime(until: deadline) else { return .unavailable(.timedOut) }
        switch canonical {
        case let .value(element):
            switch backend.isEditable(
                element,
                timeoutMilliseconds: remainingMilliseconds(until: deadline)
            ) {
            case .value(true):
                guard hasTime(until: deadline) else { return .unavailable(.timedOut) }
                let identifier = backend.identifier(
                    for: element,
                    timeoutMilliseconds: remainingMilliseconds(until: deadline)
                )
                guard hasTime(until: deadline) else { return .unavailable(.timedOut) }
                guard expectedIdentifier == nil || expectedIdentifier == identifier else {
                    return .unavailable(.identifierMismatch)
                }
                store(
                    element,
                    identifier: identifier,
                    processID: processID
                )
                return .resolved(FocusedEditableResolution(
                    element: element,
                    identifier: identifier,
                    source: .canonical
                ))
            case .value(false):
                if !allowTreeSearch { return .unavailable(.noEditableElement) }
            case let .unavailable(failure):
                guard hasTime(until: deadline) else { return .unavailable(.timedOut) }
                if failure == .timedOut || !allowTreeSearch {
                    return .unavailable(failure)
                }
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
        var visited: Set<ObjectIdentifier> = []
        var index = 0
        var candidate: (element: Backend.Element, identifier: String)?
        var sawIdentifierMismatch = false
        var sawTimedOutBranch = false
        traversal: while index < queue.count, index < maximumTraversalNodes {
            guard remainingMilliseconds(until: deadlineNanoseconds) > 0 else {
                sawTimedOutBranch = true
                break traversal
            }
            let node = queue[index]
            index += 1
            guard visited.insert(ObjectIdentifier(node.element)).inserted else { continue }

            let focused = backend.isFocused(
                node.element,
                timeoutMilliseconds: remainingMilliseconds(until: deadlineNanoseconds)
            )
            guard hasTime(until: deadlineNanoseconds) else {
                sawTimedOutBranch = true
                break traversal
            }
            if case .value(true) = focused {
                let editable = backend.isEditable(
                    node.element,
                    timeoutMilliseconds: remainingMilliseconds(until: deadlineNanoseconds)
                )
                guard hasTime(until: deadlineNanoseconds) else {
                    sawTimedOutBranch = true
                    break traversal
                }
                if case .value(true) = editable {
                    let identifier = backend.identifier(
                        for: node.element,
                        timeoutMilliseconds: remainingMilliseconds(until: deadlineNanoseconds)
                    )
                    guard hasTime(until: deadlineNanoseconds) else {
                        sawTimedOutBranch = true
                        break traversal
                    }
                    if let expectedIdentifier, expectedIdentifier != identifier {
                        sawIdentifierMismatch = true
                    } else if let existing = candidate,
                              existing.element !== node.element {
                        return .unavailable(.ambiguousFocusedElements)
                    } else {
                        candidate = (node.element, identifier)
                    }
                }
            } else if case let .unavailable(failure) = focused, failure == .timedOut {
                sawTimedOutBranch = true
            }

            guard node.depth < maximumTraversalDepth else { continue }
            switch backend.children(
                of: node.element,
                timeoutMilliseconds: remainingMilliseconds(until: deadlineNanoseconds)
            ) {
            case let .value(children):
                guard hasTime(until: deadlineNanoseconds) else {
                    sawTimedOutBranch = true
                    break traversal
                }
                queue.append(contentsOf: children.map {
                    PendingNode(element: $0, depth: node.depth + 1)
                })
            case let .unavailable(failure):
                guard hasTime(until: deadlineNanoseconds) else {
                    sawTimedOutBranch = true
                    break traversal
                }
                if failure == .timedOut { sawTimedOutBranch = true }
            }
        }
        if let candidate {
            store(
                candidate.element,
                identifier: candidate.identifier,
                processID: processID
            )
            return .resolved(FocusedEditableResolution(
                element: candidate.element,
                identifier: candidate.identifier,
                source: .nested
            ))
        }
        if index < queue.count || sawTimedOutBranch {
            return .unavailable(.timedOut)
        }
        if sawIdentifierMismatch { return .unavailable(.identifierMismatch) }
        return .unavailable(.noEditableElement)
    }

    private func remainingMilliseconds(until deadline: UInt64) -> Int {
        let now = nowNanoseconds()
        guard now < deadline else { return 0 }
        return max(1, Int((deadline - now + 999_999) / 1_000_000))
    }

    private func hasTime(until deadline: UInt64) -> Bool {
        nowNanoseconds() < deadline
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
        processID: Int32
    ) {
        lock.lock(); defer { lock.unlock() }
        cache[processID] = CachedElement(
            element: element,
            identifier: identifier,
            storedAtNanoseconds: nowNanoseconds()
        )
    }

    private func removeCachedElement(processID: Int32, identifier: String) {
        lock.lock(); defer { lock.unlock() }
        guard cache[processID]?.identifier == identifier else { return }
        cache.removeValue(forKey: processID)
    }
}
