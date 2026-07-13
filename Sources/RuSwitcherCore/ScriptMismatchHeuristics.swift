import Foundation

public enum ScriptMismatchHeuristics {
    public static func hasStrongMismatch(
        typed: String,
        converted: String,
        targetLanguage: String
    ) -> Bool {
        let target = LanguageCode.canonical(targetLanguage)
        let typedLetters = Array(typed.unicodeScalars.filter { CharacterSet.letters.contains($0) })
        let convertedLetters = Array(converted.unicodeScalars.filter { CharacterSet.letters.contains($0) })
        guard typedLetters.count >= 4, convertedLetters.count >= 4 else { return false }

        switch target {
        case "ru", "uk", "be", "bg":
            return ratio(typedLetters, in: .latin) >= 0.8
                && ratio(convertedLetters, in: .cyrillic) >= 0.8
        case "en", "de", "fr", "es", "pt", "pl":
            return ratio(typedLetters, in: .cyrillic) >= 0.8
                && ratio(convertedLetters, in: .latin) >= 0.8
        default:
            return false
        }
    }

    private enum Script {
        case latin
        case cyrillic
    }

    private static func ratio(_ scalars: [UnicodeScalar], in script: Script) -> Double {
        guard !scalars.isEmpty else { return 0 }
        let matching = scalars.count { scalar in
            switch script {
            case .latin:
                return (0x0041...0x005A).contains(Int(scalar.value))
                    || (0x0061...0x007A).contains(Int(scalar.value))
            case .cyrillic:
                return (0x0400...0x04FF).contains(Int(scalar.value))
            }
        }
        return Double(matching) / Double(scalars.count)
    }
}
