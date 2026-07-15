import XCTest
@testable import RuSwitcherAppSupport

final class FocusedEditableResolverTests: XCTestCase {
    func testCanonicalEditableElementResolvesWithoutTraversal() {
        let field = Node("field", focused: true, editable: true)
        let backend = TreeBackend(canonical: .value(field), root: field)
        let resolver = FocusedEditableResolver(backend: backend)

        let result = resolver.resolve(
            processID: 42,
            timeoutMilliseconds: 20,
            allowTreeSearch: false
        )

        assertResolved(result, identifier: "field", source: .canonical)
        XCTAssertEqual(backend.searchRootCalls, 0)
    }

    func testNestedFocusedFieldIsWarmedAndThenUsedFromCache() {
        let field = Node("nested-field", focused: true, editable: true)
        var parent = field
        for index in (0..<30).reversed() {
            parent = Node("group-\(index)", children: [parent])
        }
        let root = Node("window", children: [parent])
        let backend = TreeBackend(
            canonical: .unavailable(.noFocusedElement),
            root: root
        )
        let resolver = FocusedEditableResolver(
            backend: backend,
            maximumTraversalNodes: 100,
            maximumTraversalDepth: 40
        )

        let warmed = resolver.resolve(
            processID: 42,
            timeoutMilliseconds: 100,
            allowTreeSearch: true
        )
        assertResolved(warmed, identifier: "nested-field", source: .nested)

        backend.canonical = .unavailable(.timedOut)
        let hot = resolver.resolve(
            processID: 42,
            expectedIdentifier: "nested-field",
            timeoutMilliseconds: 4,
            allowTreeSearch: false
        )
        assertResolved(hot, identifier: "nested-field", source: .cached)
        XCTAssertEqual(backend.canonicalCalls, 1)
    }

    func testHotPathDoesNotTraverseWhenFocusIsUnavailable() {
        let root = Node("window")
        let backend = TreeBackend(
            canonical: .unavailable(.noFocusedElement),
            root: root
        )
        let resolver = FocusedEditableResolver(backend: backend)

        let result = resolver.resolve(
            processID: 42,
            timeoutMilliseconds: 4,
            allowTreeSearch: false
        )

        assertUnavailable(result, expected: .noFocusedElement)
        XCTAssertEqual(backend.searchRootCalls, 0)
    }

    func testStaleCachedElementNeverAuthorizesReplacement() {
        let field = Node("field", focused: true, editable: true)
        let backend = TreeBackend(canonical: .value(field), root: field)
        let resolver = FocusedEditableResolver(backend: backend)
        _ = resolver.resolve(
            processID: 42,
            timeoutMilliseconds: 20,
            allowTreeSearch: false
        )

        field.focused = false
        backend.canonical = .unavailable(.noFocusedElement)
        let result = resolver.resolve(
            processID: 42,
            expectedIdentifier: "field",
            timeoutMilliseconds: 4,
            allowTreeSearch: false
        )

        assertUnavailable(result, expected: .noFocusedElement)
        XCTAssertNil(resolver.cachedIdentifier(processID: 42))
    }

    func testExpectedIdentifierMismatchBlocksCachedElement() {
        let field = Node("new-field", focused: true, editable: true)
        let backend = TreeBackend(canonical: .value(field), root: field)
        let resolver = FocusedEditableResolver(backend: backend)
        _ = resolver.resolve(
            processID: 42,
            timeoutMilliseconds: 20,
            allowTreeSearch: false
        )

        let result = resolver.resolve(
            processID: 42,
            expectedIdentifier: "old-field",
            timeoutMilliseconds: 4,
            allowTreeSearch: false
        )

        assertUnavailable(result, expected: .identifierMismatch)
    }

    func testTimedOutTraversalDoesNotPopulateCache() {
        let root = Node("window")
        let backend = TreeBackend(
            canonical: .unavailable(.noFocusedElement),
            root: root
        )
        backend.focusFailures[root.identifier] = .timedOut
        let resolver = FocusedEditableResolver(backend: backend)

        let result = resolver.resolve(
            processID: 42,
            timeoutMilliseconds: 100,
            allowTreeSearch: true
        )

        assertUnavailable(result, expected: .timedOut)
        XCTAssertNil(resolver.cachedIdentifier(processID: 42))
    }

    func testBoundaryPreflightDeadlineStaysBelowEventCallbackBudget() {
        XCTAssertEqual(ReplacementTiming.preflightDeadlineMilliseconds, 4)
        XCTAssertLessThan(ReplacementTiming.preflightDeadlineMilliseconds, 5)
    }

    func testCachedElementSurvivesSlowCanonicalOnHotPath() {
        let field = Node("nested-field", focused: true, editable: true)
        let root = Node("window", children: [field])
        let backend = TreeBackend(
            canonical: .unavailable(.noFocusedElement),
            root: root
        )
        let resolver = FocusedEditableResolver(backend: backend)
        assertResolved(
            resolver.resolve(processID: 7, timeoutMilliseconds: 50, allowTreeSearch: true),
            identifier: "nested-field",
            source: .nested
        )

        backend.canonical = .unavailable(.timedOut)
        backend.canonicalDelayMilliseconds = 50
        let hot = resolver.resolve(
            processID: 7,
            expectedIdentifier: "nested-field",
            timeoutMilliseconds: 4,
            allowTreeSearch: false
        )
        assertResolved(hot, identifier: "nested-field", source: .cached)
        XCTAssertEqual(backend.canonicalCalls, 1)
    }

    func testLateCanonicalSuccessIsRejectedAndNeverCached() {
        let clock = TestClock()
        let field = Node("field", focused: true, editable: true)
        let backend = TreeBackend(canonical: .value(field), root: field)
        backend.clock = clock
        backend.canonicalAdvanceNanoseconds = 5_000_000
        let resolver = FocusedEditableResolver(backend: backend, nowNanoseconds: clock.now)

        let result = resolver.resolve(
            processID: 42,
            timeoutMilliseconds: 4,
            allowTreeSearch: false
        )

        assertUnavailable(result, expected: .timedOut)
        XCTAssertEqual(backend.editableCalls, 0)
        XCTAssertNil(resolver.cachedIdentifier(processID: 42))
    }

    func testLateCachedFocusSuccessCannotAuthorizeHotPath() {
        let clock = TestClock()
        let field = Node("field", focused: true, editable: true)
        let backend = TreeBackend(canonical: .value(field), root: field)
        backend.clock = clock
        let resolver = FocusedEditableResolver(backend: backend, nowNanoseconds: clock.now)
        assertResolved(
            resolver.resolve(processID: 42, timeoutMilliseconds: 20, allowTreeSearch: false),
            identifier: "field",
            source: .canonical
        )
        backend.focusAdvanceNanoseconds = 5_000_000

        let result = resolver.resolve(
            processID: 42,
            expectedIdentifier: "field",
            timeoutMilliseconds: 4,
            allowTreeSearch: false
        )

        assertUnavailable(result, expected: .timedOut)
    }

    func testExpiredCacheCannotSupplySnapshotIdentity() {
        let clock = TestClock()
        let first = Node("field-a", focused: true, editable: true)
        let second = Node("field-b", focused: true, editable: true)
        let backend = TreeBackend(canonical: .value(first), root: first)
        let resolver = FocusedEditableResolver(
            backend: backend,
            cacheLifetimeMilliseconds: 10,
            nowNanoseconds: clock.now
        )
        assertResolved(
            resolver.resolve(processID: 42, timeoutMilliseconds: 20, allowTreeSearch: false),
            identifier: "field-a",
            source: .canonical
        )

        first.focused = false
        backend.canonical = .value(second)
        clock.advance(nanoseconds: 11_000_000)
        let stale = resolver.resolve(
            processID: 42,
            expectedIdentifier: "field-a",
            timeoutMilliseconds: 20,
            allowTreeSearch: false
        )

        assertUnavailable(stale, expected: .identifierMismatch)
        XCTAssertNil(resolver.cachedIdentifier(processID: 42))
        assertResolved(
            resolver.resolve(processID: 42, timeoutMilliseconds: 20, allowTreeSearch: false),
            identifier: "field-b",
            source: .canonical
        )
    }

    func testCacheIsOnlyAHintWhenExpectedFieldHasChanged() {
        let first = Node("field-a", focused: true, editable: true)
        let second = Node("field-b", focused: true, editable: true)
        let backend = TreeBackend(canonical: .value(first), root: first)
        let resolver = FocusedEditableResolver(backend: backend)
        _ = resolver.resolve(processID: 42, timeoutMilliseconds: 20, allowTreeSearch: false)

        first.focused = false
        backend.canonical = .value(second)
        let result = resolver.resolve(
            processID: 42,
            expectedIdentifier: "field-b",
            timeoutMilliseconds: 20,
            allowTreeSearch: false
        )

        assertResolved(result, identifier: "field-b", source: .canonical)
    }

    func testTwoFocusedEditableDescendantsAreRejectedAsAmbiguous() {
        let first = Node("duplicate-id", focused: true, editable: true)
        let second = Node("duplicate-id", focused: true, editable: true)
        let root = Node("window", children: [first, second])
        let backend = TreeBackend(canonical: .unavailable(.noFocusedElement), root: root)
        let resolver = FocusedEditableResolver(backend: backend)

        let result = resolver.resolve(
            processID: 42,
            timeoutMilliseconds: 20,
            allowTreeSearch: true
        )

        assertUnavailable(result, expected: .ambiguousFocusedElements)
        XCTAssertNil(resolver.cachedIdentifier(processID: 42))
    }

    private func assertResolved(
        _ result: FocusedEditableLookup<Node>,
        identifier: String,
        source: FocusedEditableLookupSource,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .resolved(resolution) = result else {
            return XCTFail("expected resolved element", file: file, line: line)
        }
        XCTAssertEqual(resolution.identifier, identifier, file: file, line: line)
        XCTAssertEqual(resolution.source, source, file: file, line: line)
    }

    private func assertUnavailable(
        _ result: FocusedEditableLookup<Node>,
        expected: FocusedEditableLookupFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .unavailable(actual) = result else {
            return XCTFail("expected unavailable result", file: file, line: line)
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}

private final class Node {
    let identifier: String
    var focused: Bool
    var editable: Bool
    var children: [Node]

    init(
        _ identifier: String,
        focused: Bool = false,
        editable: Bool = false,
        children: [Node] = []
    ) {
        self.identifier = identifier
        self.focused = focused
        self.editable = editable
        self.children = children
    }
}

private final class TreeBackend: FocusedEditableTreeAccessing {
    typealias Element = Node

    var canonical: AccessibilityTreeRead<Node>
    let root: Node
    var focusFailures: [String: FocusedEditableLookupFailure] = [:]
    var canonicalDelayMilliseconds = 0
    var clock: TestClock?
    var canonicalAdvanceNanoseconds: UInt64 = 0
    var focusAdvanceNanoseconds: UInt64 = 0
    private(set) var canonicalCalls = 0
    private(set) var searchRootCalls = 0
    private(set) var editableCalls = 0

    init(canonical: AccessibilityTreeRead<Node>, root: Node) {
        self.canonical = canonical
        self.root = root
    }

    func prepare(processID: Int32, timeoutMilliseconds: Int) {}

    func canonicalFocusedElement(
        processID: Int32,
        timeoutMilliseconds: Int
    ) -> AccessibilityTreeRead<Node> {
        canonicalCalls += 1
        clock?.advance(nanoseconds: canonicalAdvanceNanoseconds)
        if canonicalDelayMilliseconds > 0 {
            usleep(UInt32(canonicalDelayMilliseconds) * 1_000)
        }
        return canonical
    }

    func searchRoot(
        processID: Int32,
        timeoutMilliseconds: Int
    ) -> AccessibilityTreeRead<Node> {
        searchRootCalls += 1
        return .value(root)
    }

    func children(
        of element: Node,
        timeoutMilliseconds: Int
    ) -> AccessibilityTreeRead<[Node]> {
        .value(element.children)
    }

    func isFocused(
        _ element: Node,
        timeoutMilliseconds: Int
    ) -> AccessibilityTreeRead<Bool> {
        clock?.advance(nanoseconds: focusAdvanceNanoseconds)
        if let failure = focusFailures[element.identifier] {
            return .unavailable(failure)
        }
        return .value(element.focused)
    }

    func isEditable(
        _ element: Node,
        timeoutMilliseconds: Int
    ) -> AccessibilityTreeRead<Bool> {
        editableCalls += 1
        return .value(element.editable)
    }

    func identifier(for element: Node, timeoutMilliseconds: Int) -> String {
        element.identifier
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1

    func now() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(nanoseconds: UInt64) {
        lock.lock(); defer { lock.unlock() }
        value &+= nanoseconds
    }
}
