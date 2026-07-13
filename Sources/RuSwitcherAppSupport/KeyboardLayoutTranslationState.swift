import Carbon
import Foundation

/// Stateful physical-key translation matching macOS dead-key composition.
/// CGEvent taps run before AppKit applies this composition, so the raw event
/// Unicode cannot distinguish a real Space from Space committing a quote.
public struct KeyboardLayoutTranslationState {
    private var deadKeyState: UInt32 = 0

    public init() {}

    public mutating func reset() {
        deadKeyState = 0
    }

    public mutating func translate(
        keyCode: UInt16,
        shift: Bool,
        capsLock: Bool,
        layoutData: Data,
        keyboardType: UInt32 = UInt32(LMGetKbdType())
    ) -> String? {
        var characters = [UniChar](repeating: 0, count: 8)
        var length = 0
        var modifierState: UInt32 = shift ? (UInt32(shiftKey >> 8) & 0xff) : 0
        if capsLock {
            modifierState |= UInt32(alphaLock >> 8) & 0xff
        }

        let status = layoutData.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let pointer = rawBuffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return -1
            }
            return UCKeyTranslate(
                pointer,
                keyCode,
                UInt16(kUCKeyActionDown),
                modifierState,
                keyboardType,
                0,
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
