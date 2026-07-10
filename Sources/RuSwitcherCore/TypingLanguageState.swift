import Foundation

public struct TypingLanguageState: Equatable, Sendable {
    private var englishEvidence: Double
    private var russianEvidence: Double

    public static let neutral = TypingLanguageState()

    public init(englishEvidence: Double = 0, russianEvidence: Double = 0) {
        self.englishEvidence = max(0, englishEvidence)
        self.russianEvidence = max(0, russianEvidence)
    }

    public mutating func observe(language: String?, weight: Double = 1) {
        englishEvidence *= 0.78
        russianEvidence *= 0.78
        guard let language else { return }
        switch LocalLanguageModel.canonical(language) {
        case "en": englishEvidence += max(0, weight)
        case "ru": russianEvidence += max(0, weight)
        default: break
        }
    }

    public func confidence(language: String) -> Double {
        let total = englishEvidence + russianEvidence
        guard total > 0 else { return 0.5 }
        switch LocalLanguageModel.canonical(language) {
        case "en": return englishEvidence / total
        case "ru": return russianEvidence / total
        default: return 0.5
        }
    }

    public func score(language: String) -> Double {
        (confidence(language: language) - 0.5) * 4.0
    }
}
