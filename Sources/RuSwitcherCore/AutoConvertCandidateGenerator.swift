import Foundation

public enum AutoConvertCandidateGenerator {

    public static func candidates(
        typed: String,
        converted: String,
        strokes: [PhysicalKeyStroke]? = nil
    ) -> [AutoConvertCandidate] {
        PhysicalKeyLattice.candidates(typed: typed, converted: converted, strokes: strokes)
    }

    public static func bestCandidate(
        typed: String,
        converted: String,
        targetLanguage: String,
        isValidWord: (String, String) -> Bool
    ) -> AutoConvertCandidate? {
        candidates(typed: typed, converted: converted)
            .max { lhs, rhs in
                score(lhs, targetLanguage: targetLanguage, isValidWord: isValidWord)
                    < score(rhs, targetLanguage: targetLanguage, isValidWord: isValidWord)
            }
    }

    private static func score(
        _ candidate: AutoConvertCandidate,
        targetLanguage: String,
        isValidWord: (String, String) -> Bool
    ) -> Int {
        let word = FrequentWordLexicon.normalize(
            SmartTokenizer.lexicalCore(of: candidate.convertedWord)
        )
        if isValidWord(word, targetLanguage) || FrequentWordLexicon.contains(word, language: targetLanguage) {
            return 10_000 + word.count
        }
        if ScriptMismatchHeuristics.hasStrongMismatch(
            typed: candidate.typedRaw,
            converted: word,
            targetLanguage: targetLanguage
        ) {
            return 1_000 + word.count
        }
        return word.count
    }
}
