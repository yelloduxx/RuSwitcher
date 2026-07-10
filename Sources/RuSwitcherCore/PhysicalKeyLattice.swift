import Foundation

public struct LayoutHypothesis: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case literal
        case directConversion
        case trailingPunctuation
        case layoutLetterTail
        case wrappingPunctuation
    }

    public let text: String
    public let lexicalCore: String
    public let suffix: String
    public let kind: Kind
    public let channelCost: Double
    public let candidate: AutoConvertCandidate?

    public var isLiteral: Bool { kind == .literal }

    public init(
        text: String,
        lexicalCore: String,
        suffix: String,
        kind: Kind,
        channelCost: Double,
        candidate: AutoConvertCandidate?
    ) {
        self.text = text
        self.lexicalCore = lexicalCore
        self.suffix = suffix
        self.kind = kind
        self.channelCost = channelCost
        self.candidate = candidate
    }
}

public enum PhysicalKeyLattice {
    public static let maximumHypotheses = 6

    public static func hypotheses(typed: String, converted: String) -> [LayoutHypothesis] {
        var result = [LayoutHypothesis(
            text: typed,
            lexicalCore: SmartTokenizer.lexicalCore(of: typed),
            suffix: SmartTokenizer.shape(of: typed).suffix,
            kind: .literal,
            channelCost: 0,
            candidate: nil
        )]
        var seen = Set([typed.precomposedStringWithCanonicalMapping])

        for candidate in AutoConvertCandidateGenerator.candidates(typed: typed, converted: converted) {
            let text = candidate.replacement.precomposedStringWithCanonicalMapping
            guard seen.insert(text).inserted else { continue }
            let kind: LayoutHypothesis.Kind
            let cost: Double
            switch candidate.kind {
            case .directWord:
                kind = .directConversion
                cost = -0.08
            case .trailingPunctuation:
                kind = .trailingPunctuation
                cost = -0.12
            case .layoutLetterTail:
                kind = .layoutLetterTail
                cost = -0.10
            case .wrappingPunctuation:
                kind = .wrappingPunctuation
                cost = -0.11
            }
            result.append(LayoutHypothesis(
                text: text,
                lexicalCore: SmartTokenizer.lexicalCore(of: candidate.convertedWord),
                suffix: candidate.suffix,
                kind: kind,
                channelCost: cost,
                candidate: candidate
            ))
            if result.count == maximumHypotheses { break }
        }
        return result
    }
}
