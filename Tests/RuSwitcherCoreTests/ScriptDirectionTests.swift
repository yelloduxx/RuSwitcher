import XCTest
@testable import RuSwitcherCore

final class ScriptDirectionTests: XCTestCase {
    func testDirectionUsesSelectedTextInsteadOfActiveLayout() {
        XCTAssertEqual(ScriptDirection.dominant(in: "ghbdtn"), .latinToCyrillic)
        XCTAssertEqual(ScriptDirection.dominant(in: "привет"), .cyrillicToLatin)
    }

    func testPunctuationDoesNotChangeDirection() {
        XCTAssertEqual(ScriptDirection.dominant(in: "ghbdtn, world!"), .latinToCyrillic)
    }

    func testMixedScriptSelectionIsAmbiguous() {
        XCTAssertNil(ScriptDirection.dominant(in: "plan план"))
        XCTAssertNil(ScriptDirection.dominant(in: "123 --"))
    }
}
