import Carbon
import XCTest
@testable import RuSwitcherAppSupport

final class KeyboardLayoutTranslationStateTests: XCTestCase {
    func testUSInternationalQuoteIsCommittedBySpace() throws {
        guard let layoutData = usInternationalLayoutData() else {
            throw XCTSkip("US International-PC is not installed")
        }
        var state = KeyboardLayoutTranslationState()

        XCTAssertEqual(
            state.translate(keyCode: 39, shift: true, capsLock: false, layoutData: layoutData),
            ""
        )
        XCTAssertEqual(
            state.translate(keyCode: 49, shift: false, capsLock: false, layoutData: layoutData),
            "\""
        )
        XCTAssertEqual(
            state.translate(keyCode: 0, shift: false, capsLock: false, layoutData: layoutData),
            "a"
        )
        XCTAssertEqual(
            state.translate(keyCode: 49, shift: false, capsLock: false, layoutData: layoutData),
            " "
        )
    }

    private func usInternationalLayoutData() -> Data? {
        guard let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first(where: { inputSourceID($0).contains("USInternational-PC") }),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    private func inputSourceID(_ source: TISInputSource) -> String {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}
