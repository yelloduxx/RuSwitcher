import Foundation

public enum LayoutRankerRisk: String, Codable, CaseIterable, Hashable, Sendable {
    case standard
    case punctuation
    case punctuationShort
    case punctuationBothKnown
    case punctuationAmbiguous
    case punctuationOOV
    case oov
    case short
    case bothKnown
    case protected
}

public struct LayoutRankerContext: Sendable {
    public let typed: String
    public let converted: String
    public let currentLanguage: String
    public let targetLanguage: String
    public let contextWords: [String]
    public let languageBelief: LanguageBelief
    public let capsLock: Bool
    public let physicalStrokes: [PhysicalKeyStroke]?

    public init(
        typed: String,
        converted: String,
        currentLanguage: String,
        targetLanguage: String,
        contextWords: [String],
        languageBelief: LanguageBelief,
        capsLock: Bool = false,
        physicalStrokes: [PhysicalKeyStroke]? = nil
    ) {
        self.typed = typed
        self.converted = converted
        self.currentLanguage = currentLanguage
        self.targetLanguage = targetLanguage
        self.contextWords = contextWords
        self.languageBelief = languageBelief
        self.capsLock = capsLock
        self.physicalStrokes = physicalStrokes
    }
}

public struct LayoutRankerItem: Equatable, Sendable {
    public let hypothesis: LayoutHypothesis
    public let features: [Double]
    public let risk: LayoutRankerRisk

    public init(hypothesis: LayoutHypothesis, features: [Double], risk: LayoutRankerRisk) {
        self.hypothesis = hypothesis
        self.features = features
        self.risk = risk
    }
}

public enum LayoutRankerFeatureSchema {
    private static let channelHashBuckets = 16
    private static let characterHashBuckets = 32
    private static let contextHashBuckets = 32

    public static let version = 8
    public static let names: [String] = [
        "bias", "isLiteral", "isDirect", "isTrailingPunctuation", "isLayoutLetterTail",
        "isWrappingPunctuation", "candidateLanguageRU", "currentLanguageRU", "sourceLength",
        "candidateLength", "sourceWordKnown", "sourceWordScore", "sourceExtended",
        "sourceCharacterScore", "candidateWordKnown", "candidateWordScore", "candidateExtended",
        "candidateCharacterScore", "characterAdvantage", "sourceFrequentLexicon",
        "candidateFrequentLexicon", "candidateBelief", "beliefAdvantage", "phraseKnown",
        "phraseScore", "compoundKnown", "compoundScore", "bothKnown", "isShort", "isSingle",
        "prefixLength", "suffixLength", "preservesTypedSuffix", "usesTargetPunctuation",
        "isFullOpposite", "preservesFullSourcePrefix", "preservesFullSourceSuffix",
        "usesFullTargetPrefix", "usesFullTargetSuffix", "fullOppositeKnown",
        "preservedSuffixKnown", "targetPunctuationKnown", "suffixTerminal",
        "suffixSeparator", "suffixWrapper", "suffixOtherDecoration",
        "channelLiteralFraction", "channelOppositeFraction", "channelSharedFraction",
        "channelTransitions",
    ]
        + (0..<characterHashBuckets).map { "candidateENCharHash\($0)" }
        + (0..<characterHashBuckets).map { "candidateRUCharHash\($0)" }
        + (0..<contextHashBuckets).map { "candidateENContextHash\($0)" }
        + (0..<contextHashBuckets).map { "candidateRUContextHash\($0)" }
        + (0..<channelHashBuckets).map { "literalKeyPairHash\($0)" }
        + (0..<channelHashBuckets).map { "oppositeKeyPairHash\($0)" }
        + [
        "channelCost", "contextSameLanguageRatio", "lastContextSameLanguage",
        "sourceScriptMatches", "candidateScriptMatches", "sourceShapeProtected",
        "candidateShapeProtected", "capsLock", "englishSourceFrequent",
        "englishSourceDictionary", "englishSourcePlausible", "englishSourceUnlikely",
    ]

    public static func extract(
        context: LayoutRankerContext,
        model: LanguageModelStore
    ) -> [LayoutRankerItem] {
        let current = LanguageCode.canonical(context.currentLanguage)
        let target = LanguageCode.canonical(context.targetLanguage)
        let sourceShape = SmartTokenizer.shape(of: context.typed)
        let sourceCore = normalize(sourceShape.lexicalCore)
        let sourceWordScore = model.wordLogProbability(sourceCore, language: current)
        let sourceExtended = extended(sourceCore, language: current, model: model)
        let sourceKnown = sourceWordScore != nil || sourceExtended
        let sourceCharacter = model.characterLogProbability(sourceCore, language: current)
        let sourceFrequent = FrequentWordLexicon.contains(sourceCore, language: current)
        let convertedShape = SmartTokenizer.shape(of: context.converted)
        let englishSource = current == "en"
            ? EnglishSourceClassifier.classify(sourceCore, model: model)
            : nil
        let contextLanguages = context.contextWords.compactMap(SmartTokenizer.languageHint)
            .map(LanguageCode.canonical)
        let resolvedStrokes = context.physicalStrokes
            ?? PhysicalKeyStroke.aligned(typed: context.typed, converted: context.converted)

        let items = PhysicalKeyLattice.hypotheses(
            typed: context.typed,
            converted: context.converted,
            strokes: context.physicalStrokes
        ).map { hypothesis in
            let candidateLanguage = hypothesis.isLiteral ? current : target
            let candidateRaw = hypothesis.isLiteral
                ? context.typed
                : (hypothesis.candidate?.convertedWord ?? hypothesis.lexicalCore)
            let candidateShape = SmartTokenizer.shape(of: hypothesis.text)
            let candidateCore = normalize(SmartTokenizer.lexicalCore(of: candidateRaw))
            let candidateWordScore = model.wordLogProbability(candidateCore, language: candidateLanguage)
            let candidateExtended = extended(candidateCore, language: candidateLanguage, model: model)
            let candidateKnown = candidateWordScore != nil || candidateExtended
            let candidateCharacter = model.characterLogProbability(candidateCore, language: candidateLanguage)
            let candidateFrequent = FrequentWordLexicon.contains(candidateCore, language: candidateLanguage)
            let phraseScore = model.phraseLogProbability(
                context: context.contextWords,
                candidate: candidateCore,
                language: candidateLanguage
            )
            let compound = hypothesis.isLiteral || candidateWordScore != nil
                ? nil
                : CompoundWordAnalyzer.analyze(candidateCore, language: candidateLanguage, model: model)
            let bothKnown = !hypothesis.isLiteral && sourceKnown && candidateKnown
            let candidate = hypothesis.candidate
            let prefix = candidate?.prefix ?? sourceShape.prefix
            let suffix = candidate?.suffix ?? sourceShape.suffix
            let preservesTypedSuffix = candidate.map {
                !$0.suffix.isEmpty && $0.typedRaw.hasSuffix($0.suffix)
            } ?? false
            let usesTargetPunctuation = candidate.map {
                !$0.suffix.isEmpty
                    && $0.convertedRaw.hasSuffix($0.suffix)
                    && !$0.typedRaw.hasSuffix($0.suffix)
            } ?? false
            let isFullOpposite = !hypothesis.isLiteral && hypothesis.text == context.converted
            let preservesFullSourcePrefix = candidate.map {
                !sourceShape.prefix.isEmpty && $0.prefix == sourceShape.prefix
            } ?? false
            let preservesFullSourceSuffix = candidate.map {
                !sourceShape.suffix.isEmpty && $0.suffix == sourceShape.suffix
            } ?? false
            let usesFullTargetPrefix = candidate.map {
                !convertedShape.prefix.isEmpty && $0.prefix == convertedShape.prefix
            } ?? false
            let usesFullTargetSuffix = candidate.map {
                !convertedShape.suffix.isEmpty && $0.suffix == convertedShape.suffix
            } ?? false
            let suffixClass = punctuationClass(suffix)
            let channel = channelFeatures(hypothesis: hypothesis, strokes: resolvedStrokes)
            let characterHashes = characterHashes(candidateCore, language: candidateLanguage)
            let contextHashes = contextHashes(
                context.contextWords,
                candidate: candidateCore,
                language: candidateLanguage
            )
            let candidateProbability = context.languageBelief.probability(language: candidateLanguage)
            let sourceProbability = context.languageBelief.probability(language: current)
            let sameContextCount = contextLanguages.count(where: { $0 == candidateLanguage })
            let sameContextRatio = contextLanguages.isEmpty
                ? 0.5
                : Double(sameContextCount) / Double(contextLanguages.count)
            let sourceScriptMatches = SmartTokenizer.languageHint(for: sourceCore)
                .map { LanguageCode.canonical($0) == current } ?? false
            let candidateScriptMatches = SmartTokenizer.languageHint(for: candidateCore)
                .map { LanguageCode.canonical($0) == candidateLanguage } ?? false

            var features = [
                1,
                hypothesis.isLiteral ? 1 : 0,
                hypothesis.kind == .directConversion ? 1 : 0,
                hypothesis.kind == .trailingPunctuation ? 1 : 0,
                hypothesis.kind == .layoutLetterTail ? 1 : 0,
                hypothesis.kind == .wrappingPunctuation ? 1 : 0,
                candidateLanguage == "ru" ? 1 : 0,
                current == "ru" ? 1 : 0,
                normalizedLength(sourceCore),
                normalizedLength(candidateCore),
                sourceWordScore == nil ? 0 : 1,
                normalizedLogScore(sourceWordScore),
                sourceExtended ? 1 : 0,
                normalizedLogScore(sourceCharacter),
                candidateWordScore == nil ? 0 : 1,
                normalizedLogScore(candidateWordScore),
                candidateExtended ? 1 : 0,
                normalizedLogScore(candidateCharacter),
                clamp((candidateCharacter - sourceCharacter) / 8, minimum: -1, maximum: 1),
                sourceFrequent ? 1 : 0,
                candidateFrequent ? 1 : 0,
                candidateProbability,
                candidateProbability - sourceProbability,
                phraseScore == nil ? 0 : 1,
                normalizedLogScore(phraseScore),
                compound == nil ? 0 : 1,
                min(1, max(0, (compound?.score ?? 0) / 20)),
                bothKnown ? 1 : 0,
                candidateCore.count <= 2 ? 1 : 0,
                candidateCore.count == 1 ? 1 : 0,
                min(1, Double(prefix.count) / 10),
                min(1, Double(suffix.count) / 10),
                preservesTypedSuffix ? 1 : 0,
                usesTargetPunctuation ? 1 : 0,
                isFullOpposite ? 1 : 0,
                preservesFullSourcePrefix ? 1 : 0,
                preservesFullSourceSuffix ? 1 : 0,
                usesFullTargetPrefix ? 1 : 0,
                usesFullTargetSuffix ? 1 : 0,
                isFullOpposite && candidateKnown ? 1 : 0,
                preservesTypedSuffix && candidateKnown ? 1 : 0,
                usesTargetPunctuation && candidateKnown ? 1 : 0,
                suffixClass == .terminal ? 1 : 0,
                suffixClass == .separator ? 1 : 0,
                suffixClass == .wrapper ? 1 : 0,
                suffixClass == .other ? 1 : 0,
                channel.literalFraction,
                channel.oppositeFraction,
                channel.sharedFraction,
                channel.transitions,
            ]
            features.append(contentsOf: characterHashes.english)
            features.append(contentsOf: characterHashes.russian)
            features.append(contentsOf: contextHashes.english)
            features.append(contentsOf: contextHashes.russian)
            features.append(contentsOf: channel.literalHashes)
            features.append(contentsOf: channel.oppositeHashes)
            features.append(contentsOf: [
                clamp(hypothesis.channelCost * 8, minimum: -1, maximum: 1),
                sameContextRatio,
                contextLanguages.last == candidateLanguage ? 1 : 0,
                sourceScriptMatches ? 1 : 0,
                candidateScriptMatches ? 1 : 0,
                sourceShape.kind.blocksAutomaticConversion ? 1 : 0,
                candidateShape.kind.blocksAutomaticConversion ? 1 : 0,
                context.capsLock ? 1 : 0,
                englishSource == .frequent ? 1 : 0,
                englishSource == .dictionary ? 1 : 0,
                englishSource == .plausibleOOV ? 1 : 0,
                englishSource == .unlikely ? 1 : 0,
            ])
            precondition(features.count == names.count)
            return LayoutRankerItem(
                hypothesis: hypothesis,
                features: features,
                risk: risk(
                    hypothesis: hypothesis,
                    sourceShape: sourceShape,
                    candidateShape: candidateShape,
                    candidateLength: candidateCore.count,
                    candidateKnown: candidateKnown,
                    bothKnown: bothKnown
                )
            )
        }
        let uniqueItems = deduplicated(items)
        let targetTexts = Set(uniqueItems.compactMap { item in
            item.hypothesis.isLiteral ? nil : item.hypothesis.text
        })
        guard targetTexts.count > 1 else { return uniqueItems }
        return uniqueItems.map { item in
            guard !item.hypothesis.isLiteral else { return item }
            return LayoutRankerItem(
                hypothesis: item.hypothesis,
                features: item.features,
                risk: .punctuationAmbiguous
            )
        }
    }

    private enum PunctuationClass {
        case none
        case terminal
        case separator
        case wrapper
        case other
    }

    private struct ChannelFeatures {
        var literalFraction = 0.0
        var oppositeFraction = 0.0
        var sharedFraction = 0.0
        var transitions = 0.0
        var literalHashes = Array(repeating: 0.0, count: channelHashBuckets)
        var oppositeHashes = Array(repeating: 0.0, count: channelHashBuckets)
    }

    private struct CharacterHashes {
        var english = Array(repeating: 0.0, count: characterHashBuckets)
        var russian = Array(repeating: 0.0, count: characterHashBuckets)
    }

    private struct ContextHashes {
        var english = Array(repeating: 0.0, count: contextHashBuckets)
        var russian = Array(repeating: 0.0, count: contextHashBuckets)
    }

    private enum ChannelChoice {
        case literal
        case opposite
        case shared
        case unknown
    }

    private static func channelFeatures(
        hypothesis: LayoutHypothesis,
        strokes: [PhysicalKeyStroke]?
    ) -> ChannelFeatures {
        guard let strokes else { return ChannelFeatures() }
        let output = Array(hypothesis.text)
        guard output.count == strokes.count else { return ChannelFeatures() }
        var result = ChannelFeatures()
        var choices: [ChannelChoice] = []
        var boundaryCount = 0
        for (index, stroke) in strokes.enumerated() {
            let literal = Array(stroke.literal)
            let opposite = Array(stroke.opposite)
            guard literal.count == 1, opposite.count == 1 else { return ChannelFeatures() }
            let isBoundary = isBoundaryCharacter(literal[0]) || isBoundaryCharacter(opposite[0])
            guard isBoundary else { continue }
            boundaryCount += 1
            let choice: ChannelChoice
            if literal[0] == opposite[0], output[index] == literal[0] {
                choice = .shared
                result.sharedFraction += 1
            } else if output[index] == literal[0] {
                choice = .literal
                result.literalFraction += 1
                result.literalHashes[keyPairBucket(stroke)] += 1
            } else if output[index] == opposite[0] {
                choice = .opposite
                result.oppositeFraction += 1
                result.oppositeHashes[keyPairBucket(stroke)] += 1
            } else {
                choice = .unknown
            }
            choices.append(choice)
        }
        guard boundaryCount > 0 else { return result }
        let denominator = Double(boundaryCount)
        result.literalFraction /= denominator
        result.oppositeFraction /= denominator
        result.sharedFraction /= denominator
        result.literalHashes = result.literalHashes.map { $0 / denominator }
        result.oppositeHashes = result.oppositeHashes.map { $0 / denominator }
        let stateful = choices.filter { $0 == .literal || $0 == .opposite }
        if stateful.count > 1 {
            let changes = zip(stateful, stateful.dropFirst()).count(where: { $0 != $1 })
            result.transitions = Double(changes) / Double(stateful.count - 1)
        }
        return result
    }

    private static func characterHashes(_ word: String, language: String) -> CharacterHashes {
        let normalized = normalize(word)
        guard !normalized.isEmpty else { return CharacterHashes() }
        let characters = Array("^" + normalized + "$")
        var values = Array(repeating: 0.0, count: characterHashBuckets)
        var count = 0
        for length in 2...5 where characters.count >= length {
            for start in 0...(characters.count - length) {
                let hash = stableFeatureHash(String(characters[start..<(start + length)]))
                let bucket = Int(hash % UInt64(characterHashBuckets))
                values[bucket] += hash & 0x8000_0000_0000_0000 == 0 ? 1 : -1
                count += 1
            }
        }
        if count > 0 {
            let scale = 1 / sqrt(Double(count))
            values = values.map { $0 * scale }
        }
        var result = CharacterHashes()
        if LanguageCode.canonical(language) == "en" {
            result.english = values
        } else if LanguageCode.canonical(language) == "ru" {
            result.russian = values
        }
        return result
    }

    private static func contextHashes(
        _ context: [String],
        candidate: String,
        language: String
    ) -> ContextHashes {
        let words = context.suffix(2).map {
            normalize(SmartTokenizer.lexicalCore(of: $0))
        }.filter { !$0.isEmpty }
        guard !words.isEmpty, !candidate.isEmpty else { return ContextHashes() }
        var values = Array(repeating: 0.0, count: contextHashBuckets)
        for length in 1...words.count {
            let phrase = words.suffix(length).joined(separator: "\u{1f}")
                + "\u{1e}" + candidate
            let hash = stableFeatureHash(phrase)
            let bucket = Int(hash % UInt64(contextHashBuckets))
            values[bucket] += hash & 0x8000_0000_0000_0000 == 0 ? 1 : -1
        }
        let scale = 1 / sqrt(Double(words.count))
        values = values.map { $0 * scale }
        var result = ContextHashes()
        if LanguageCode.canonical(language) == "en" {
            result.english = values
        } else if LanguageCode.canonical(language) == "ru" {
            result.russian = values
        }
        return result
    }

    private static func stableFeatureHash(_ value: String) -> UInt64 {
        value.utf8.reduce(0xcbf29ce484222325) { partial, byte in
            (partial ^ UInt64(byte)) &* 0x100000001b3
        }
    }

    private static func keyPairBucket(_ stroke: PhysicalKeyStroke) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in (stroke.literal + "\u{1f}" + stroke.opposite).utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return Int(hash % UInt64(channelHashBuckets))
    }

    private static func isBoundaryCharacter(_ character: Character) -> Bool {
        !character.isLetter && !character.isNumber && !character.isWhitespace
    }

    private static func punctuationClass(_ suffix: String) -> PunctuationClass {
        guard !suffix.isEmpty else { return .none }
        if suffix.allSatisfy({ ".!?…".contains($0) }) { return .terminal }
        if suffix.allSatisfy({ ",;:".contains($0) }) { return .separator }
        if suffix.allSatisfy({ ")]}>\"'»”’".contains($0) }) { return .wrapper }
        return .other
    }

    private static func deduplicated(_ items: [LayoutRankerItem]) -> [LayoutRankerItem] {
        var result: [LayoutRankerItem] = []
        var indexByText: [String: Int] = [:]
        for item in items {
            let text = item.hypothesis.text
            if let index = indexByText[text] {
                if representationScore(item) > representationScore(result[index]) {
                    result[index] = item
                }
            } else {
                indexByText[text] = result.count
                result.append(item)
            }
        }
        return result
    }

    private static func representationScore(_ item: LayoutRankerItem) -> Double {
        if item.hypothesis.isLiteral { return 10_000 }
        let knownIndex = names.firstIndex(of: "candidateWordKnown")!
        let extendedIndex = names.firstIndex(of: "candidateExtended")!
        let suffixIndex = names.firstIndex(of: "suffixLength")!
        let prefixIndex = names.firstIndex(of: "prefixLength")!
        return (item.risk == .protected ? 0 : 1_000)
            + item.features[knownIndex] * 100
            + item.features[extendedIndex] * 80
            + item.features[suffixIndex] * 10
            + item.features[prefixIndex] * 5
    }

    private static func risk(
        hypothesis: LayoutHypothesis,
        sourceShape: TokenShape,
        candidateShape: TokenShape,
        candidateLength: Int,
        candidateKnown: Bool,
        bothKnown: Bool
    ) -> LayoutRankerRisk {
        if hypothesis.isLiteral {
            if sourceShape.kind.blocksAutomaticConversion { return .protected }
        } else if candidateShape.kind.blocksAutomaticConversion
                    || (sourceShape.kind.blocksAutomaticConversion && !candidateKnown) {
            return .protected
        }
        switch hypothesis.kind {
        case .trailingPunctuation, .layoutLetterTail, .wrappingPunctuation:
            if bothKnown { return .punctuationBothKnown }
            if candidateLength <= 2 { return .punctuationShort }
            if !candidateKnown { return .punctuationOOV }
            return .punctuation
        case .literal, .directConversion:
            if bothKnown { return .bothKnown }
            if candidateLength <= 2 { return .short }
            if !hypothesis.isLiteral && !candidateKnown { return .oov }
            return .standard
        }
    }

    private static func extended(_ word: String, language: String, model: LanguageModelStore) -> Bool {
        switch LanguageCode.canonical(language) {
        case "en": return model.isExtendedEnglishWord(word)
        case "ru": return model.isExtendedRussianWord(word)
        default: return false
        }
    }

    private static func normalizedLength(_ word: String) -> Double {
        min(1, Double(word.count) / 32)
    }

    private static func normalizedLogScore(_ score: Double?) -> Double {
        guard let score else { return 0 }
        return (clamp(score, minimum: -16, maximum: 0) + 16) / 16
    }

    private static func normalize(_ text: String) -> String {
        FrequentWordLexicon.normalize(text)
    }

    private static func clamp(_ value: Double, minimum: Double, maximum: Double) -> Double {
        min(maximum, max(minimum, value))
    }
}

public struct LayoutRankerArtifact: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let modelVersion: String
    public let featureSchemaVersion: Int
    public let featureNames: [String]
    public let weights: [Double]
    public let hiddenWeights: [[Double]]?
    public let hiddenBias: [Double]?
    public let outputWeights: [Double]?
    public let temperature: Double
    public let thresholds: [String: Double]
    public let trainingManifestSHA256: String
    public let trainExamples: Int
    public let validationExamples: Int

    public init(
        formatVersion: Int = 1,
        modelVersion: String,
        featureSchemaVersion: Int,
        featureNames: [String],
        weights: [Double],
        hiddenWeights: [[Double]]? = nil,
        hiddenBias: [Double]? = nil,
        outputWeights: [Double]? = nil,
        temperature: Double,
        thresholds: [String: Double],
        trainingManifestSHA256: String,
        trainExamples: Int,
        validationExamples: Int
    ) {
        self.formatVersion = formatVersion
        self.modelVersion = modelVersion
        self.featureSchemaVersion = featureSchemaVersion
        self.featureNames = featureNames
        self.weights = weights
        self.hiddenWeights = hiddenWeights
        self.hiddenBias = hiddenBias
        self.outputWeights = outputWeights
        self.temperature = temperature
        self.thresholds = thresholds
        self.trainingManifestSHA256 = trainingManifestSHA256
        self.trainExamples = trainExamples
        self.validationExamples = validationExamples
    }

    public func logit(features: [Double]) -> Double {
        var result = zip(weights, features).reduce(0) { $0 + $1.0 * $1.1 }
        guard let hiddenWeights, let hiddenBias, let outputWeights else { return result }
        for hiddenIndex in hiddenWeights.indices {
            let activation = tanh(
                zip(hiddenWeights[hiddenIndex], features).reduce(hiddenBias[hiddenIndex]) {
                    $0 + $1.0 * $1.1
                }
            )
            result += outputWeights[hiddenIndex] * activation
        }
        return result
    }
}

public enum LayoutRankerAction: String, Codable, Sendable {
    case keep
    case switchLayout
    case abstain
}

public struct LayoutRankerPrediction: Equatable, Sendable {
    public let action: LayoutRankerAction
    public let winnerIndex: Int
    public let winnerProbability: Double
    public let winnerMargin: Double
    public let threshold: Double
    public let probabilities: [Double]

    public init(
        action: LayoutRankerAction,
        winnerIndex: Int,
        winnerProbability: Double,
        winnerMargin: Double,
        threshold: Double,
        probabilities: [Double]
    ) {
        self.action = action
        self.winnerIndex = winnerIndex
        self.winnerProbability = winnerProbability
        self.winnerMargin = winnerMargin
        self.threshold = threshold
        self.probabilities = probabilities
    }
}

public enum LayoutRankerError: Error, Equatable {
    case unsupportedFormat(Int)
    case incompatibleFeatures
    case invalidWeights
    case invalidTemperature
    case missingThreshold(LayoutRankerRisk)
}

public final class LayoutRankerModel: @unchecked Sendable {
    public static var bundledResourceURL: URL? {
        Bundle.main.url(forResource: "layout-ranker-v1", withExtension: "json")
            ?? Bundle.module.url(forResource: "layout-ranker-v1", withExtension: "json")
    }

    public static let bundled: LayoutRankerModel? = {
        guard let url = bundledResourceURL else { return nil }
        return try? LayoutRankerModel(contentsOf: url)
    }()

    public let artifact: LayoutRankerArtifact

    public convenience init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public convenience init(data: Data) throws {
        let artifact = try JSONDecoder().decode(LayoutRankerArtifact.self, from: data)
        try self.init(artifact: artifact)
    }

    public init(artifact: LayoutRankerArtifact) throws {
        guard artifact.formatVersion == 1 || artifact.formatVersion == 2 else {
            throw LayoutRankerError.unsupportedFormat(artifact.formatVersion)
        }
        guard artifact.featureSchemaVersion == LayoutRankerFeatureSchema.version,
              artifact.featureNames == LayoutRankerFeatureSchema.names else {
            throw LayoutRankerError.incompatibleFeatures
        }
        guard artifact.weights.count == artifact.featureNames.count,
              artifact.weights.allSatisfy(\.isFinite) else {
            throw LayoutRankerError.invalidWeights
        }
        if artifact.formatVersion == 2 {
            guard let hiddenWeights = artifact.hiddenWeights,
                  let hiddenBias = artifact.hiddenBias,
                  let outputWeights = artifact.outputWeights,
                  !hiddenWeights.isEmpty,
                  hiddenWeights.count <= 32,
                  hiddenBias.count == hiddenWeights.count,
                  outputWeights.count == hiddenWeights.count,
                  hiddenWeights.allSatisfy({
                      $0.count == artifact.featureNames.count && $0.allSatisfy(\.isFinite)
                  }),
                  hiddenBias.allSatisfy(\.isFinite),
                  outputWeights.allSatisfy(\.isFinite) else {
                throw LayoutRankerError.invalidWeights
            }
        } else if artifact.hiddenWeights != nil
                    || artifact.hiddenBias != nil
                    || artifact.outputWeights != nil {
            throw LayoutRankerError.invalidWeights
        }
        guard artifact.temperature.isFinite, artifact.temperature > 0 else {
            throw LayoutRankerError.invalidTemperature
        }
        for risk in LayoutRankerRisk.allCases {
            guard artifact.thresholds[risk.rawValue]?.isFinite == true else {
                throw LayoutRankerError.missingThreshold(risk)
            }
        }
        self.artifact = artifact
    }

    public func predict(items: [LayoutRankerItem]) -> LayoutRankerPrediction {
        guard !items.isEmpty else {
            return LayoutRankerPrediction(
                action: .keep,
                winnerIndex: 0,
                winnerProbability: 1,
                winnerMargin: 1,
                threshold: 1,
                probabilities: [1]
            )
        }
        let logits = items.map { artifact.logit(features: $0.features) / artifact.temperature }
        let maximum = logits.max() ?? 0
        let exponentials = logits.map { exp($0 - maximum) }
        let total = exponentials.reduce(0, +)
        let probabilities = exponentials.map { $0 / max(total, .leastNonzeroMagnitude) }
        let ordered = probabilities.indices.sorted { probabilities[$0] > probabilities[$1] }
        let winner = ordered[0]
        let runnerUp = ordered.count > 1 ? probabilities[ordered[1]] : 0
        let margin = probabilities[winner] - runnerUp
        let risk = items[winner].risk
        let threshold = artifact.thresholds[risk.rawValue] ?? 1
        let action: LayoutRankerAction
        if winner == 0 {
            action = .keep
        } else if risk == .protected || margin < threshold {
            action = .abstain
        } else {
            action = .switchLayout
        }
        return LayoutRankerPrediction(
            action: action,
            winnerIndex: winner,
            winnerProbability: probabilities[winner],
            winnerMargin: margin,
            threshold: threshold,
            probabilities: probabilities
        )
    }
}
