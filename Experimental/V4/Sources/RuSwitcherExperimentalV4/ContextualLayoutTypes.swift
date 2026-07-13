import Foundation
import RuSwitcherCore

public struct ContextSnapshot: Equatable, Sendable {
    public static let maximumTokens = InputContextLimits.maximumTokens
    public static let maximumUTF8Bytes = InputContextLimits.maximumUTF8Bytes

    public let text: String
    public let tokenLanguages: [String?]
    public let activeLayoutID: String?
    public let focus: FocusedElementIdentity
    public let editRevision: UInt64

    public init(
        tokens: [InputContextToken],
        axPrefix: String? = nil,
        activeLayoutID: String?,
        focus: FocusedElementIdentity,
        editRevision: UInt64
    ) {
        let recent = Array(tokens.suffix(Self.maximumTokens))
        let internalText = recent.map(\.text).joined(separator: " ")
        let combined = [axPrefix, internalText]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " ")
        text = Self.utf8Suffix(combined, limit: Self.maximumUTF8Bytes)
        tokenLanguages = recent.map(\.language)
        self.activeLayoutID = activeLayoutID
        self.focus = focus
        self.editRevision = editRevision
    }

    private static func utf8Suffix(_ text: String, limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var result = ""
        var count = 0
        for character in text.reversed() {
            let bytes = String(character).utf8.count
            guard count + bytes <= limit else { break }
            result.insert(character, at: result.startIndex)
            count += bytes
        }
        return result
    }
}

public enum SmartEngineV4Mode: String, Codable, Equatable, Sendable {
    case off
    case shadow
    case active
}

public enum V4Outcome: String, Equatable, Sendable {
    case keep
    case switchToHypothesis
    case abstain
    case fallbackV3
}

public struct V4Evaluation: Sendable {
    public let outcome: V4Outcome
    public let selectedIndex: Int
    public let probabilities: [Double]
    public let confidenceMargin: Double
    public let evidence: [DecoderEvidence]
    public let latencyMilliseconds: Double
    public let featureDelta: [Float]?
    public let fallback: LayoutDecoderEvaluation

    public var selectedHypothesisProbability: Double {
        probabilities.indices.contains(selectedIndex) ? probabilities[selectedIndex] : 0
    }

    public init(
        outcome: V4Outcome,
        selectedIndex: Int,
        probabilities: [Double],
        confidenceMargin: Double,
        evidence: [DecoderEvidence],
        latencyMilliseconds: Double,
        featureDelta: [Float]?,
        fallback: LayoutDecoderEvaluation
    ) {
        self.outcome = outcome
        self.selectedIndex = selectedIndex
        self.probabilities = probabilities
        self.confidenceMargin = confidenceMargin
        self.evidence = evidence
        self.latencyMilliseconds = latencyMilliseconds
        self.featureDelta = featureDelta
        self.fallback = fallback
    }
}

public struct ContextualModelManifest: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let modelVersion: String
    public let modelSHA256: String
    public let maximumBytes: Int
    public let maximumCandidates: Int
    public let featureCount: Int
    public let embeddingSize: Int
    public let temperature: Double
    public let minimumProbability: Double
    public let minimumMargin: Double
    public let bothKnownProbability: Double
    public let bothKnownMargin: Double
    public let learningRate: Float
    public let l2: Float
}

public struct ContextualModelOutput: Sendable {
    public let logits: [Float]
    public let embeddings: [[Float]]
    public let latencyMilliseconds: Double

    public init(logits: [Float], embeddings: [[Float]], latencyMilliseconds: Double) {
        self.logits = logits
        self.embeddings = embeddings
        self.latencyMilliseconds = latencyMilliseconds
    }
}

public protocol ContextualLayoutScoring: Sendable {
    var manifest: ContextualModelManifest { get }
    func score(byteIDs: [[Int32]], features: [[Float]]) throws -> ContextualModelOutput
}
