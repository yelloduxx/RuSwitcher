public struct TypedKey: Equatable, Sendable {
    public let keyCode: UInt16
    public let shift: Bool
    public let caps: Bool
    /// Unicode character produced by the event before any RuSwitcher conversion.
    public let producedCharacter: Character?
    /// Full Unicode payload. Dead keys, composed input and forwarded events may
    /// produce more than one UTF-16 code unit and must not be truncated.
    public let producedText: String?
    /// Input source active when this key was pressed. Capturing it avoids rebuilding
    /// a word with a layout that changed after the word had already been typed.
    public let sourceLayoutID: String?
    /// Screen Sharing forwards Unicode payloads with an unusable key code. `char`
    /// remains the marker for that path; local events use `producedCharacter` only.
    public var char: Character?
    public let forwardedText: String?

    public init(
        keyCode: UInt16,
        shift: Bool,
        caps: Bool,
        char: Character? = nil,
        producedCharacter: Character? = nil,
        producedText: String? = nil,
        forwardedText: String? = nil,
        sourceLayoutID: String? = nil
    ) {
        self.keyCode = keyCode
        self.shift = shift
        self.caps = caps
        self.char = char
        self.forwardedText = forwardedText ?? char.map(String.init)
        self.producedText = producedText ?? producedCharacter.map(String.init) ?? char.map(String.init)
        self.producedCharacter = producedCharacter ?? self.producedText?.first ?? char
        self.sourceLayoutID = sourceLayoutID
    }
}
