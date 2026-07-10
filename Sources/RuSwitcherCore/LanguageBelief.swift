import Foundation

/// A tiny two-state Bayesian-style filter for the user's recent typing
/// language. The log odds decay toward neutral, so a deliberate code switch
/// recovers quickly without discarding useful phrase context immediately.
public struct LanguageBelief: Equatable, Sendable {
    private var russianLogOdds: Double

    public static let neutral = LanguageBelief()

    public init(russianLogOdds: Double = 0) {
        self.russianLogOdds = min(8, max(-8, russianLogOdds))
    }

    public mutating func observe(language: String?, weight: Double = 1) {
        russianLogOdds *= 0.72
        guard let language else { return }
        switch LocalLanguageModel.canonical(language) {
        case "ru": russianLogOdds += 1.35 * max(0, weight)
        case "en": russianLogOdds -= 1.35 * max(0, weight)
        default: break
        }
        russianLogOdds = min(8, max(-8, russianLogOdds))
    }

    public func probability(language: String) -> Double {
        let ru = 1 / (1 + exp(-russianLogOdds))
        switch LocalLanguageModel.canonical(language) {
        case "ru": return ru
        case "en": return 1 - ru
        default: return 0.5
        }
    }

    public func score(language: String) -> Double {
        (probability(language: language) - 0.5) * 5.0
    }
}
