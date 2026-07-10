public struct AutoConvertCandidate: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case directWord
        case trailingPunctuation
        case layoutLetterTail
        case wrappingPunctuation
    }

    public let typedRaw: String
    public let convertedRaw: String
    public let prefix: String
    public let convertedWord: String
    public let suffix: String
    public let kind: Kind

    public var replacement: String { prefix + convertedWord + suffix }

    public init(
        typedRaw: String,
        convertedRaw: String,
        prefix: String = "",
        convertedWord: String,
        suffix: String,
        kind: Kind
    ) {
        self.typedRaw = typedRaw
        self.convertedRaw = convertedRaw
        self.prefix = prefix
        self.convertedWord = convertedWord
        self.suffix = suffix
        self.kind = kind
    }
}
