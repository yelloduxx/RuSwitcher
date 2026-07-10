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

        let shape = SmartTokenizer.shape(of: typed)
        if !shape.lexicalCore.isEmpty, !shape.prefix.isEmpty {
            let typedCharacters = Array(typed)
            let prefixCount = shape.prefix.count
            let remainder = Array(typedCharacters.dropFirst(prefixCount))
            let maximumPreservedSuffix = min(3, remainder.count)
            for suffixLength in 0...maximumPreservedSuffix {
                let suffixCharacters = remainder.suffix(suffixLength)
                guard suffixLength == 0 || suffixCharacters.allSatisfy(isTrailingPunctuation) else {
                    continue
                }
                let coreCharacters = remainder.dropLast(suffixLength)
                guard !coreCharacters.isEmpty else { continue }
                let candidate = AutoConvertCandidate(
                    typedRaw: typed,
                    convertedRaw: converted,
                    prefix: shape.prefix,
                    convertedWord: KeyMapping.convert(String(coreCharacters)),
                    suffix: String(suffixCharacters),
                    kind: .wrappingPunctuation
                )
                if !result.contains(candidate) { result.append(candidate) }
            }
        }

        let typedChars = Array(typed)
        let convertedChars = Array(converted)
        let maxSuffix = min(3, typedChars.count, convertedChars.count)
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

        // In the reverse RU→EN direction a Cyrillic letter may live on an
        // English punctuation key: гыуб → use,. Treat punctuation produced only
        // after conversion as a suffix candidate too.
        for suffixLength in 1...maxSuffix {
            let convertedSuffix = convertedChars.suffix(suffixLength)
            guard convertedSuffix.allSatisfy(isTrailingPunctuation) else { continue }
            let convertedWordChars = convertedChars.dropLast(suffixLength)
            guard !convertedWordChars.isEmpty else { continue }
            let candidate = AutoConvertCandidate(
                typedRaw: typed,
                convertedRaw: converted,
                convertedWord: String(convertedWordChars),
                suffix: String(convertedSuffix),
                kind: .trailingPunctuation
            )
            if !result.contains(candidate) { result.append(candidate) }
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
        let word = FrequentWordLexicon.normalize(
            SmartTokenizer.lexicalCore(of: candidate.convertedWord)
        )
        if isValidWord(word, targetLanguage) || FrequentWordLexicon.contains(word, language: targetLanguage) {
            return 10_000 + word.count
        }
        if LayoutDetector.hasStrongScriptMismatch(typed: candidate.typedRaw, converted: word, targetLang: targetLanguage) {
            return 1_000 + word.count
        }
        return word.count
    }
}
