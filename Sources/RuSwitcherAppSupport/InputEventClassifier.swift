import RuSwitcherCore

public enum InputEventDisposition: Equatable, Sendable {
    case suppress
    case track(InputEvent)
}

public enum SpaceKeyDisposition: Equatable, Sendable {
    case notSpaceKey
    case boundary
    case textComposition
}

public enum InputEventClassifier {
    /// A physical Space key is not necessarily a text boundary. On dead-key
    /// layouts, Space can commit a quote or accent and the event's Unicode
    /// payload contains that character instead of whitespace.
    public static func classifySpaceKey(
        isSpaceKey: Bool,
        producedText: String?
    ) -> SpaceKeyDisposition {
        guard isSpaceKey else { return .notSpaceKey }
        guard let producedText, !producedText.isEmpty else {
            return .boundary
        }
        return producedText == " " ? .boundary : .textComposition
    }

    public static func classifyRemoteAutorepeat(
        activeTap: Bool,
        key: TypedKey
    ) -> InputEventDisposition {
        activeTap ? .suppress : .track(.printable(key))
    }
}
