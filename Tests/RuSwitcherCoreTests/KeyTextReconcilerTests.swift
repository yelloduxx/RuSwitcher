import XCTest
@testable import RuSwitcherCore

final class KeyTextReconcilerTests: XCTestCase {
    func testProducedUnicodeReversesStaleCapturedLayout() {
        let strokes = PhysicalKeyStroke.aligned(typed: "гыуб", converted: "use,")
        let result = KeyTextReconciler.reconcile(
            reconstructedOriginal: "гыуб",
            reconstructedConverted: "use,",
            producedText: "use,",
            strokes: strokes
        )
        XCTAssertEqual(result.original, "use,")
        XCTAssertEqual(result.converted, "гыуб")
        XCTAssertTrue(result.sourceWasOpposite)
        XCTAssertEqual(result.strokes?.map(\.literal).joined(), "use,")
        XCTAssertEqual(result.strokes?.map(\.opposite).joined(), "гыуб")
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
