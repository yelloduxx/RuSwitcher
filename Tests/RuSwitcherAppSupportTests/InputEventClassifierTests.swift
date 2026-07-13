import XCTest
import RuSwitcherCore
@testable import RuSwitcherAppSupport

final class InputEventClassifierTests: XCTestCase {
    func testSpaceKeyUsesProducedTextInsteadOfPhysicalKeyCodeAlone() {
        XCTAssertEqual(
            InputEventClassifier.classifySpaceKey(isSpaceKey: true, producedText: " "),
            .boundary
        )
        XCTAssertEqual(
            InputEventClassifier.classifySpaceKey(isSpaceKey: true, producedText: nil),
            .boundary
        )
        XCTAssertEqual(
            InputEventClassifier.classifySpaceKey(isSpaceKey: true, producedText: "\""),
            .textComposition
        )
        XCTAssertEqual(
            InputEventClassifier.classifySpaceKey(isSpaceKey: true, producedText: "'"),
            .textComposition
        )
        XCTAssertEqual(
            InputEventClassifier.classifySpaceKey(isSpaceKey: false, producedText: " "),
            .notSpaceKey
        )
    }

    func testRemoteAutorepeatIsSuppressedForActiveTap() {
        XCTAssertEqual(
            InputEventClassifier.classifyRemoteAutorepeat(activeTap: true, key: key()),
            .suppress
        )
    }

    func testRemoteAutorepeatIsTrackedForListenOnlyTap() {
        XCTAssertEqual(
            InputEventClassifier.classifyRemoteAutorepeat(activeTap: false, key: key()),
            .track(.printable(key()))
        )
    }

    private func key() -> TypedKey {
        TypedKey(keyCode: 0, shift: false, caps: false, char: "ф", producedCharacter: "ф")
    }
}
