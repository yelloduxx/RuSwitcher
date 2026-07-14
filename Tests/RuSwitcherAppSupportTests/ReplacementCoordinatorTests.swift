import XCTest
import RuSwitcherCore
@testable import RuSwitcherAppSupport

@MainActor
final class ReplacementCoordinatorTests: XCTestCase {
    func testPostingIsUnverifiedUntilReadbackMatches() {
        let reader = Reader(preflight: .match)
        let poster = Poster(result: true)
        let coordinator = NativeReplacementCoordinator(reader: reader, poster: poster)
        var completions: [ReplacementOutcome] = []
        let completionDelivered = expectation(description: "verification delivered asynchronously")

        let initial = coordinator.submit(request()) {
            completions.append($0)
            completionDelivered.fulfill()
        }

        XCTAssertEqual(initial, .postedUnverified)
        XCTAssertEqual(poster.plans.count, 1)
        XCTAssertTrue(completions.isEmpty)
        XCTAssertEqual(reader.validationDeadlines, [ReplacementTiming.preflightDeadlineMilliseconds])
        XCTAssertEqual(
            reader.verificationDeadlines,
            [ReplacementTiming.postedEventVerificationDeadlineMilliseconds]
        )

        reader.complete(.match)
        wait(for: [completionDelivered], timeout: 1)
        XCTAssertEqual(completions, [.verified])
    }

    func testAcceptedPostWithUnavailableReadbackNeverBecomesVerified() {
        let reader = Reader(preflight: .match)
        let coordinator = NativeReplacementCoordinator(reader: reader, poster: Poster(result: true))
        var completion: ReplacementOutcome?
        let completionDelivered = expectation(description: "unavailable delivered asynchronously")

        XCTAssertEqual(coordinator.submit(request()) {
            completion = $0
            completionDelivered.fulfill()
        }, .postedUnverified)
        reader.complete(.unavailable)
        wait(for: [completionDelivered], timeout: 1)

        XCTAssertEqual(completion, .postedUnverified)
    }

    func testAcceptedPostWithMismatchingReadbackFailsVerification() {
        let reader = Reader(preflight: .match)
        let poster = Poster(result: true)
        let coordinator = NativeReplacementCoordinator(reader: reader, poster: poster)
        var completion: ReplacementOutcome?
        let completionDelivered = expectation(description: "mismatch delivered asynchronously")

        XCTAssertEqual(coordinator.submit(request()) {
            completion = $0
            completionDelivered.fulfill()
        }, .postedUnverified)
        XCTAssertEqual(poster.plans.count, 1)

        reader.complete(.mismatch)
        wait(for: [completionDelivered], timeout: 1)

        XCTAssertEqual(completion, .failed(.verificationMismatch))
    }

    func testMismatchBeforePostingBlocksTransaction() {
        let reader = Reader(preflight: .mismatch)
        let poster = Poster(result: true)
        let coordinator = NativeReplacementCoordinator(reader: reader, poster: poster)

        let outcome = coordinator.submit(request()) { _ in XCTFail("must not verify") }

        XCTAssertEqual(outcome, .blocked(.expectedSuffixMismatch))
        XCTAssertTrue(poster.plans.isEmpty)
    }

    func testUnavailablePreflightAlwaysBlocksBeforePosting() {
        let reader = Reader(preflight: .unavailable)
        let poster = Poster(result: true)
        let coordinator = NativeReplacementCoordinator(reader: reader, poster: poster)

        XCTAssertEqual(
            coordinator.submit(request()) { _ in XCTFail("must not verify") },
            .blocked(.contextUnavailable)
        )
        XCTAssertTrue(poster.plans.isEmpty)
    }

    func testDuplicateTransactionIsNeverPostedTwice() {
        let reader = Reader(preflight: .match)
        let poster = Poster(result: true)
        let coordinator = NativeReplacementCoordinator(reader: reader, poster: poster)
        let request = request()

        XCTAssertEqual(coordinator.submit(request) { _ in }, .postedUnverified)
        XCTAssertEqual(coordinator.submit(request) { _ in }, .blocked(.duplicateTransaction))
        XCTAssertEqual(poster.plans.count, 1)
    }

    func testManualReplacementUsesVerifiedTextMutationInsteadOfKeyEvents() {
        let reader = Reader(preflight: .match)
        let poster = Poster(result: true)
        let replacer = TextReplacer()
        let coordinator = NativeReplacementCoordinator(
            reader: reader,
            poster: poster,
            textReplacer: replacer
        )
        var completion: ReplacementOutcome?
        let completionDelivered = expectation(description: "manual completion delivered asynchronously")

        let initial = coordinator.submit(request(automatic: false)) {
            completion = $0
            completionDelivered.fulfill()
        }

        XCTAssertEqual(initial, .postedUnverified)
        XCTAssertTrue(poster.plans.isEmpty)
        XCTAssertEqual(replacer.requests.count, 1)
        XCTAssertEqual(replacer.requests[0].original, "ghbdtn ")
        XCTAssertEqual(replacer.requests[0].replacement, "привет ")
        replacer.complete(.verified)
        XCTAssertNil(completion)
        wait(for: [completionDelivered], timeout: 1)
        XCTAssertEqual(completion, .verified)
    }

    func testManualReplacementWithoutAtomicReplacerIsBlockedBeforeKeyEvents() {
        let reader = Reader(preflight: .match)
        let poster = Poster(result: true)
        let coordinator = NativeReplacementCoordinator(reader: reader, poster: poster)

        XCTAssertEqual(
            coordinator.submit(request(automatic: false)) { _ in XCTFail("must not complete") },
            .blocked(.contextUnavailable)
        )
        XCTAssertTrue(poster.plans.isEmpty)
    }

    private func request(automatic: Bool = true) -> ReplacementRequest {
        let focus = FocusedElementIdentity(processID: 42, bundleID: "test.host", identifier: "field")
        return ReplacementRequest(
            transaction: ConversionTransaction(
                original: "ghbdtn",
                replacement: "привет",
                boundary: .space(count: 1),
                focus: focus,
                sourceLayoutID: "en",
                targetLayoutID: "ru",
                sequence: 7,
                editRevision: 3,
                expectedOriginalSuffix: automatic ? "ghbdtn" : "ghbdtn ",
                automatic: automatic
            ),
            deliveredKeyCount: 6,
            currentFocus: focus,
            currentRevision: 3
        )
    }
}

@MainActor
private final class TextReplacer: FocusedTextReplacing {
    struct Request {
        let original: String
        let replacement: String
        let focus: FocusedElementIdentity
        let deadlineMilliseconds: Int
    }

    var requests: [Request] = []
    private var completion: ((ReplacementOutcome) -> Void)?

    func replaceSuffix(
        original: String,
        replacement: String,
        focus: FocusedElementIdentity,
        deadlineMilliseconds: Int,
        completion: @escaping (ReplacementOutcome) -> Void
    ) {
        requests.append(Request(
            original: original,
            replacement: replacement,
            focus: focus,
            deadlineMilliseconds: deadlineMilliseconds
        ))
        self.completion = completion
    }

    func complete(_ outcome: ReplacementOutcome) {
        completion?(outcome)
    }
}

private final class Reader: FocusedTextContextReading {
    let preflight: TextContextValidation
    private(set) var validationDeadlines: [Int] = []
    private(set) var verificationDeadlines: [Int] = []
    private var completion: ((TextContextValidation) -> Void)?

    init(preflight: TextContextValidation) { self.preflight = preflight }

    func validate(expectedSuffix: String, focus: FocusedElementIdentity, deadlineMilliseconds: Int) -> TextContextValidation {
        validationDeadlines.append(deadlineMilliseconds)
        return preflight
    }

    func verify(expectedSuffix: String, focus: FocusedElementIdentity, deadlineMilliseconds: Int, completion: @escaping (TextContextValidation) -> Void) {
        verificationDeadlines.append(deadlineMilliseconds)
        self.completion = completion
    }

    func complete(_ result: TextContextValidation) { completion?(result) }
}

@MainActor
private final class Poster: KeyboardEventPosting {
    let result: Bool
    var plans: [EventReplacementPlan] = []

    init(result: Bool) { self.result = result }

    func post(_ plan: EventReplacementPlan, to processID: Int32) -> Bool {
        plans.append(plan)
        return result
    }
}
