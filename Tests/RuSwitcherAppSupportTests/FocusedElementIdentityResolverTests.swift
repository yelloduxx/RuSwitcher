import XCTest
import RuSwitcherCore
@testable import RuSwitcherAppSupport

final class FocusedElementIdentityResolverTests: XCTestCase {
    func testDisabledAutoConvertNeverCallsIdentifierReader() {
        let reader = RecordingIdentifierReader(result: "field")
        let resolver = FocusedElementIdentityResolver(reader: reader)

        let focus = resolver.resolve(
            processID: 42,
            bundleID: "test.host",
            autoConvertEnabled: false
        )

        XCTAssertEqual(
            focus,
            FocusedElementIdentity(processID: 42, bundleID: "test.host")
        )
        XCTAssertEqual(reader.callCount, 0)
    }

    func testEnabledAutoConvertUsesDeadlineAndCannotBlockOnReader() {
        let readerStarted = expectation(description: "reader started")
        let reader = BlockingIdentifierReader(started: readerStarted)
        let resolver = FocusedElementIdentityResolver(reader: reader)
        let start = ContinuousClock.now

        let focus = resolver.resolve(
            processID: 42,
            bundleID: "test.host",
            autoConvertEnabled: true,
            deadlineMilliseconds: 4
        )
        let elapsed = start.duration(to: .now)

        wait(for: [readerStarted], timeout: 1)
        XCTAssertEqual(reader.timeoutMilliseconds, 4)
        XCTAssertNil(focus.identifier)
        XCTAssertLessThan(elapsed, .milliseconds(100))
        reader.release()
    }

    func testAsyncResolutionReturnsAtDeadlineWithoutBlockingCaller() {
        let readerStarted = expectation(description: "reader started")
        let completed = expectation(description: "async fallback completed")
        let reader = BlockingIdentifierReader(started: readerStarted)
        let resolver = FocusedElementIdentityResolver(reader: reader)
        let start = ContinuousClock.now
        let resolved = FocusCapture()

        resolver.resolveAsync(
            processID: 42,
            bundleID: "test.host",
            deadlineMilliseconds: 5
        ) {
            resolved.set($0)
            completed.fulfill()
        }
        let callElapsed = start.duration(to: .now)

        XCTAssertLessThan(callElapsed, .milliseconds(50))
        wait(for: [readerStarted, completed], timeout: 1)
        XCTAssertEqual(
            resolved.value,
            FocusedElementIdentity(processID: 42, bundleID: "test.host")
        )
        reader.release()
    }

    func testAsyncResolutionReturnsReaderIdentityWhenAvailable() {
        let reader = RecordingIdentifierReader(result: "field")
        let resolver = FocusedElementIdentityResolver(reader: reader)
        let completed = expectation(description: "identity resolved")
        let resolved = FocusCapture()

        resolver.resolveAsync(
            processID: 42,
            bundleID: "test.host",
            deadlineMilliseconds: 50
        ) {
            resolved.set($0)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
        XCTAssertEqual(
            resolved.value,
            FocusedElementIdentity(
                processID: 42,
                bundleID: "test.host",
                identifier: "field"
            )
        )
    }
}

private final class FocusCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FocusedElementIdentity?

    var value: FocusedElementIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: FocusedElementIdentity) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

private final class RecordingIdentifierReader: FocusedElementIdentifierReading, @unchecked Sendable {
    private let lock = NSLock()
    private let result: String?
    private var calls = 0

    init(result: String?) {
        self.result = result
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func identifier(processID: Int32, timeoutMilliseconds: Int) -> String? {
        lock.lock()
        calls += 1
        lock.unlock()
        return result
    }
}

private final class BlockingIdentifierReader: FocusedElementIdentifierReading, @unchecked Sendable {
    private let started: XCTestExpectation
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var observedTimeout: Int?

    init(started: XCTestExpectation) {
        self.started = started
    }

    var timeoutMilliseconds: Int? {
        lock.lock()
        defer { lock.unlock() }
        return observedTimeout
    }

    func identifier(processID: Int32, timeoutMilliseconds: Int) -> String? {
        lock.lock()
        observedTimeout = timeoutMilliseconds
        lock.unlock()
        started.fulfill()
        releaseSemaphore.wait()
        return "too-late"
    }

    func release() {
        releaseSemaphore.signal()
    }
}
