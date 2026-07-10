import XCTest
@testable import RuSwitcherCore

final class KeyTextReconcilerTests: XCTestCase {
    func testProducedUnicodeReversesStaleCapturedLayout() {
        let result = KeyTextReconciler.reconcile(
            reconstructedOriginal: "гыуб",
            reconstructedConverted: "use,",
            producedText: "use,"
        )
        XCTAssertEqual(result.original, "use,")
        XCTAssertEqual(result.converted, "гыуб")
        XCTAssertTrue(result.sourceWasOpposite)
    }

    func testMatchingCapturedLayoutKeepsDirection() {
        let result = KeyTextReconciler.reconcile(
            reconstructedOriginal: "use,",
            reconstructedConverted: "гыуб",
            producedText: "use,"
        )
        XCTAssertEqual(result.original, "use,")
        XCTAssertEqual(result.converted, "гыуб")
        XCTAssertFalse(result.sourceWasOpposite)
    }
}
