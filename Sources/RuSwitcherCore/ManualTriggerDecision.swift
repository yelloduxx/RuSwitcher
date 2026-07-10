public enum ConversionOutcome: Equatable, Sendable {
    case converted
    case switchedOnly
    case blocked
}

public enum ManualTriggerDecision {
    public static func shouldSwitchLayout(after outcome: ConversionOutcome, allowSwitchedOnly: Bool = true) -> Bool {
        switch outcome {
        case .converted:
            return true
        case .switchedOnly:
            return allowSwitchedOnly
        case .blocked:
            return false
        }
    }
}
