import Foundation

public enum AutoConvertCandidateGenerator {

    public static func candidates(typed: String, converted: String) -> [AutoConvertCandidate] {
        let directKind: AutoConvertCandidate.Kind = typed.last.map(isTrailingPunctuation) == true
            ? .layoutLetterTail
            : .directWord
        var result = [
            AutoConvertCandidate(
                typedRaw: typed,
                convertedRaw: converted,
                convertedWord: converted,
                suffix: "",
                kind: directKind
            )
        ]

        let typedChars = Array(typed)
        let convertedChars = Array(converted)
        let maxSuffix = min(2, typedChars.count, convertedChars.count)
        guard maxSuffix > 0 else { return result }

        for suffixLength in 1...maxSuffix {
            let suffixChars = typedChars.suffix(suffixLength)
            guard suffixChars.allSatisfy(isTrailingPunctuation) else { continue }
            let convertedWordChars = convertedChars.dropLast(suffixLength)
            guard !convertedWordChars.isEmpty else { continue }
            let suffix = String(suffixChars)
            result.append(
                AutoConvertCandidate(
                    typedRaw: typed,
                    convertedRaw: converted,
                    convertedWord: String(convertedWordChars),
                    suffix: suffix,
                    kind: .trailingPunctuation
                )
            )
        }
        return result
    }

    private static func isTrailingPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0)
        }
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
        let word = FrequentWordLexicon.normalize(candidate.convertedWord)
        if isValidWord(word, targetLanguage) || FrequentWordLexicon.contains(word, language: targetLanguage) {
            return 10_000 + word.count
        }
        if LayoutDetector.hasStrongScriptMismatch(typed: candidate.typedRaw, converted: word, targetLang: targetLanguage) {
            return 1_000 + word.count
        }
        return word.count
    }
}
