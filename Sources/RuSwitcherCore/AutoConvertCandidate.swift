public struct AutoConvertCandidate: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case directWord
        case trailingPunctuation
        case layoutLetterTail
    }

    public let typedRaw: String
    public let convertedRaw: String
    public let convertedWord: String
    public let suffix: String
    public let kind: Kind

    public var replacement: String { convertedWord + suffix }

    public init(typedRaw: String, convertedRaw: String, convertedWord: String, suffix: String, kind: Kind) {
        self.typedRaw = typedRaw
        self.convertedRaw = convertedRaw
        self.convertedWord = convertedWord
        self.suffix = suffix
        self.kind = kind
    }
}
