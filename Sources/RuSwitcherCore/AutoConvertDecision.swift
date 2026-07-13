public enum LayoutVerdict: Equatable, Sendable {
    case switchToConverted
    case keep
    case undecided
}

public enum AutoConvertDecisionReason: Equatable, Sendable {
    case frequentShort
    case frequentWord
    case dictionary
    case scriptScore
    case characterModel
    case phraseContext
    case compound
    case confirmedByUser
    case blockedNever
    case blockedCodeLike
    case blockedContext
    case blockedLearned
    case blockedEditing
    case keepCurrentWord
    case alwaysConvert
    case undecided
}

public struct AutoConvertDecision: Equatable, Sendable {
    public let verdict: LayoutVerdict
    public let reason: AutoConvertDecisionReason
    public let candidate: AutoConvertCandidate

    public init(
        verdict: LayoutVerdict,
        reason: AutoConvertDecisionReason,
        candidate: AutoConvertCandidate
    ) {
        self.verdict = verdict
        self.reason = reason
        self.candidate = candidate
    }
}

public struct AutoConvertPolicy: Equatable, Sendable {
    public let neverConvert: Set<String>
    public let alwaysConvert: Set<String>

    public static let empty = AutoConvertPolicy(neverConvert: [], alwaysConvert: [])

    public init(neverConvert: Set<String>, alwaysConvert: Set<String>) {
        self.neverConvert = neverConvert
        self.alwaysConvert = alwaysConvert
    }
}
