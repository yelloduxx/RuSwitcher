import Foundation

public enum EnglishSourceConfidence: String, Equatable, Sendable {
    case frequent
    case dictionary
    case plausibleOOV
    case unlikely
}

public enum EnglishSourceClassifier {
    public static func classify(_ word: String, model: LanguageModelStore) -> EnglishSourceConfidence {
        let normalized = FrequentWordLexicon.normalize(SmartTokenizer.lexicalCore(of: word))
        guard normalized.count >= 2 else { return .unlikely }
        if model.wordLogProbability(normalized, language: "en") != nil { return .frequent }
        if model.isExtendedEnglishWord(normalized) { return .dictionary }
        if model.characterLogProbability(normalized, language: "en")
            >= model.thresholds.englishSourceCharacterFloor {
            return .plausibleOOV
        }
        return .unlikely
    }
}
