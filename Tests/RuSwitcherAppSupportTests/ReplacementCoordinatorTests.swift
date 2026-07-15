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

        let initial = coordinator.submit(request()) { completions.append($0) }

        XCTAssertEqual(initial, .postedUnverified)
        XCTAssertEqual(poster.plans.count, 1)
        XCTAssertTrue(completions.isEmpty)
        XCTAssertEqual(reader.validationDeadlines, [ReplacementTiming.preflightDeadlineMilliseconds])
        XCTAssertEqual(
            reader.verificationDeadlines,
            [ReplacementTiming.postedEventVerificationDeadlineMilliseconds]
        )

        reader.complete(.match)
        XCTAssertEqual(completions, [.verified])
    }

    func testAcceptedPostWithUnavailableReadbackNeverBecomesVerified() {
        let reader = Reader(preflight: .match)
        let coordinator = NativeReplacementCoordinator(reader: reader, poster: Poster(result: true))
        var completion: ReplacementOutcome?

        XCTAssertEqual(coordinator.submit(request()) { completion = $0 }, .postedUnverified)
        reader.complete(.unavailable)

        XCTAssertEqual(completion, .postedUnverified)
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

    private func request() -> ReplacementRequest {
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
                expectedOriginalSuffix: "ghbdtn",
                automatic: true
            ),
            deliveredKeyCount: 6,
            currentFocus: focus,
            currentRevision: 3
        )
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
