import Foundation

/// The two texts produced by one physical key under the active layout pair.
/// AppKit/Carbon code resolves these values; the decoder only reasons about
/// the resulting deterministic keyboard channel.
public struct PhysicalKeyStroke: Equatable, Sendable {
    public let literal: String
    public let opposite: String
    public let keyCode: UInt16?
    public let shift: Bool
    public let caps: Bool

    public init(
        literal: String,
        opposite: String,
        keyCode: UInt16? = nil,
        shift: Bool = false,
        caps: Bool = false
    ) {
        self.literal = literal.precomposedStringWithCanonicalMapping
        self.opposite = opposite.precomposedStringWithCanonicalMapping
        self.keyCode = keyCode
        self.shift = shift
        self.caps = caps
    }

    public static func aligned(typed: String, converted: String) -> [PhysicalKeyStroke]? {
        let literal = Array(typed.precomposedStringWithCanonicalMapping)
        let opposite = Array(converted.precomposedStringWithCanonicalMapping)
        guard literal.count == opposite.count else { return nil }
        return zip(literal, opposite).map {
            PhysicalKeyStroke(literal: String($0), opposite: String($1))
        }
    }
}

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
    public let kind: Kind
    public let channelCost: Double
    public let candidate: AutoConvertCandidate?

    public var isLiteral: Bool { kind == .literal }

    public init(
        text: String,
        lexicalCore: String,
        kind: Kind,
        channelCost: Double,
        candidate: AutoConvertCandidate?
    ) {
        self.text = text
        self.lexicalCore = lexicalCore
        self.kind = kind
        self.channelCost = channelCost
        self.candidate = candidate
    }
}

public enum PhysicalKeyLattice {
    /// A resource guard for pathological tokens with long punctuation runs.
    /// Normal prose produces two to eight paths.
    public static let maximumHypotheses = 64

    public static func candidates(
        typed: String,
        converted: String,
        strokes suppliedStrokes: [PhysicalKeyStroke]? = nil
    ) -> [AutoConvertCandidate] {
        let typed = typed.precomposedStringWithCanonicalMapping
        let converted = converted.precomposedStringWithCanonicalMapping
        let strokes = suppliedStrokes ?? PhysicalKeyStroke.aligned(typed: typed, converted: converted)
        guard let strokes, !strokes.isEmpty,
              strokes.map(\.literal).joined() == typed,
              strokes.map(\.opposite).joined() == converted else {
            return [directCandidate(typed: typed, converted: converted)]
        }

        var result: [AutoConvertCandidate] = []
        func append(_ candidate: AutoConvertCandidate) {
            guard !result.contains(candidate), result.count < maximumHypotheses - 1 else { return }
            result.append(candidate)
        }

        append(directCandidate(typed: typed, converted: converted))

        let literalPrefixCount = strokes.prefix {
            isBoundaryDecoration($0.literal, counterpart: $0.opposite)
        }.count
        let literalSuffixCount = strokes.reversed().prefix {
            isBoundaryDecoration($0.literal, counterpart: $0.opposite)
        }.count
        let oppositePrefixCount = strokes.prefix {
            isBoundaryDecoration($0.opposite, counterpart: $0.literal)
        }.count
        let oppositeSuffixCount = strokes.reversed().prefix {
            isBoundaryDecoration($0.opposite, counterpart: $0.literal)
        }.count

        // A boundary decoration may itself be a letter key in the other
        // layout. Enumerate every valid core boundary instead of assuming a
        // fixed punctuation length. The language scorer decides which core is
        // lexical: `ghbdtn,` keeps the comma, while the punctuation-looking
        // keys in `gkfn`;...` remain part of `платёж`.
        let prefixLengths = Array(0...literalPrefixCount)
        let suffixLengths = Array(0...literalSuffixCount)
        for prefixLength in prefixLengths {
            for suffixLength in suffixLengths {
                guard prefixLength > 0 || suffixLength > 0,
                      prefixLength + suffixLength < strokes.count else {
                    continue
                }
                append(candidate(
                    strokes: strokes,
                    typed: typed,
                    converted: converted,
                    literalPrefixCount: prefixLength,
                    literalSuffixCount: suffixLength,
                    kind: prefixLength > 0 ? .wrappingPunctuation : .trailingPunctuation
                ))
            }
        }

        // Keep punctuation produced by the target layout structurally separate
        // from its lexical core. The replacement text is unchanged, but the
        // ranker can distinguish `гыуб` -> `use,` from a layout-letter tail.
        if oppositeSuffixCount > 0, oppositeSuffixCount < strokes.count {
            let split = strokes.count - oppositeSuffixCount
            append(AutoConvertCandidate(
                typedRaw: typed,
                convertedRaw: converted,
                convertedWord: strokes[..<split].map(\.opposite).joined(),
                suffix: strokes[split...].map(\.opposite).joined(),
                kind: .trailingPunctuation
            ))

            // The leading wrapper can belong to the active layout while the
            // final punctuation belongs to the target layout.
            for prefixLength in prefixLengths.dropFirst() where prefixLength < split {
                append(AutoConvertCandidate(
                    typedRaw: typed,
                    convertedRaw: converted,
                    prefix: strokes[..<prefixLength].map(\.literal).joined(),
                    convertedWord: strokes[prefixLength..<split].map(\.opposite).joined(),
                    suffix: strokes[split...].map(\.opposite).joined(),
                    kind: .wrappingPunctuation
                ))
            }
        }

        if oppositePrefixCount > 0, oppositePrefixCount < strokes.count {
            append(AutoConvertCandidate(
                typedRaw: typed,
                convertedRaw: converted,
                prefix: strokes[..<oppositePrefixCount].map(\.opposite).joined(),
                convertedWord: strokes[oppositePrefixCount...].map(\.opposite).joined(),
                suffix: "",
                kind: .wrappingPunctuation
            ))
        }

        return result
    }

    public static func hypotheses(
        typed: String,
        converted: String,
        strokes: [PhysicalKeyStroke]? = nil
    ) -> [LayoutHypothesis] {
        let typed = typed.precomposedStringWithCanonicalMapping
        var result = [LayoutHypothesis(
            text: typed,
            lexicalCore: SmartTokenizer.lexicalCore(of: typed),
            kind: .literal,
            channelCost: 0,
            candidate: nil
        )]
        for candidate in candidates(typed: typed, converted: converted, strokes: strokes) {
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
                text: candidate.replacement,
                lexicalCore: SmartTokenizer.lexicalCore(of: candidate.convertedWord),
                kind: kind,
                channelCost: cost,
                candidate: candidate
            ))
        }
        return result
    }

    private static func directCandidate(typed: String, converted: String) -> AutoConvertCandidate {
        let sourceEndsInDecoration = typed.last.map { isDecoration(String($0)) } == true
        let targetEndsInDecoration = converted.last.map { isDecoration(String($0)) } == true
        return AutoConvertCandidate(
            typedRaw: typed,
            convertedRaw: converted,
            convertedWord: converted,
            suffix: "",
            kind: sourceEndsInDecoration && !targetEndsInDecoration ? .layoutLetterTail : .directWord
        )
    }

    private static func candidate(
        strokes: [PhysicalKeyStroke],
        typed: String,
        converted: String,
        literalPrefixCount: Int,
        literalSuffixCount: Int,
        kind: AutoConvertCandidate.Kind
    ) -> AutoConvertCandidate {
        let start = literalPrefixCount
        let end = strokes.count - literalSuffixCount
        return AutoConvertCandidate(
            typedRaw: typed,
            convertedRaw: converted,
            prefix: strokes[..<start].map(\.literal).joined(),
            convertedWord: strokes[start..<end].map(\.opposite).joined(),
            suffix: strokes[end...].map(\.literal).joined(),
            kind: kind
        )
    }

    private static func isDecoration(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0)
        }
    }

    private static func isBoundaryDecoration(_ text: String, counterpart: String) -> Bool {
        if isDecoration(text) { return true }
        guard text.allSatisfy({ !$0.isLetter && !$0.isNumber && !$0.isWhitespace }) else {
            return false
        }
        return isDecoration(counterpart)
    }
}
