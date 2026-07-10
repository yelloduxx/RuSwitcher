import Foundation

public enum LayoutVerdict: Equatable, Sendable {
    case switchToConverted
    case keep
    case undecided
}

public enum AutoConvertDecisionReason: Equatable, Sendable {
    case frequentShort
    case frequentWord
    case dictionary
    case scriptScore
    case characterModel
    case phraseContext
    case compound
    case confirmedByUser
    case blockedNever
    case blockedCodeLike
    case blockedContext
    case blockedLearned
    case blockedEditing
    case keepCurrentWord
    case alwaysConvert
    case undecided
}

public struct AutoConvertDecision: Equatable, Sendable {
    public let verdict: LayoutVerdict
    public let reason: AutoConvertDecisionReason
    public let candidate: AutoConvertCandidate
}

public struct AutoConvertPolicy: Equatable, Sendable {
    public let neverConvert: Set<String>
    public let alwaysConvert: Set<String>

    public static let empty = AutoConvertPolicy(neverConvert: [], alwaysConvert: [])

    public init(neverConvert: Set<String>, alwaysConvert: Set<String>) {
        self.neverConvert = neverConvert
        self.alwaysConvert = alwaysConvert
    }
}

public struct AutoConvertContext: Equatable, Sendable {
    public let previousWord: String?

    public static let empty = AutoConvertContext(previousWord: nil)

    public init(previousWord: String? = nil) {
        if let previousWord, !previousWord.isEmpty {
            self.previousWord = FrequentWordLexicon.normalize(previousWord)
        } else {
            self.previousWord = nil
        }
    }
}

public enum LayoutDetector {
    public static func decide(
        candidate: AutoConvertCandidate,
        currentLang: String,
        otherLang: String,
        capsLock: Bool,
        policy: AutoConvertPolicy,
        isCurrentWordValid: Bool,
        isConvertedWordValid: Bool,
        context: AutoConvertContext = .empty
    ) -> AutoConvertDecision {
        let typed = FrequentWordLexicon.normalize(candidate.typedRaw)
        let converted = FrequentWordLexicon.normalize(candidate.convertedWord)

        if policy.neverConvert.contains(typed) || policy.neverConvert.contains(converted) {
            return AutoConvertDecision(verdict: .keep, reason: .blockedNever, candidate: candidate)
        }
        if policy.alwaysConvert.contains(converted) {
            return AutoConvertDecision(verdict: .switchToConverted, reason: .alwaysConvert, candidate: candidate)
        }
        if isSingleUppercaseLatinLetter(candidate.typedRaw) {
            return AutoConvertDecision(verdict: .undecided, reason: .blockedCodeLike, candidate: candidate)
        }
        if !capsLock, isCodeLike(candidate.typedRaw) {
            return AutoConvertDecision(verdict: .undecided, reason: .blockedCodeLike, candidate: candidate)
        }
        if shouldBlockCyrillicToLatinInCyrillicContext(candidate: candidate, targetLang: otherLang, context: context) {
            return AutoConvertDecision(verdict: .keep, reason: .blockedContext, candidate: candidate)
        }
        if FrequentWordLexicon.contains(converted, language: otherLang) {
            if shouldBlockSingleLetterInLatinContext(candidate: candidate, converted: converted, targetLang: otherLang, context: context) {
                return AutoConvertDecision(verdict: .keep, reason: .blockedContext, candidate: candidate)
            }
            let reason: AutoConvertDecisionReason = converted.count <= 3 ? .frequentShort : .frequentWord
            return AutoConvertDecision(verdict: .switchToConverted, reason: reason, candidate: candidate)
        }
        if isCurrentWordValid || FrequentWordLexicon.contains(typed, language: currentLang) {
            return AutoConvertDecision(verdict: .keep, reason: .keepCurrentWord, candidate: candidate)
        }
        if isConvertedWordValid {
            return AutoConvertDecision(verdict: .switchToConverted, reason: .dictionary, candidate: candidate)
        }
        if allowsScriptScore(targetLang: otherLang),
           hasStrongScriptMismatch(typed: candidate.typedRaw, converted: converted, targetLang: otherLang) {
            return AutoConvertDecision(verdict: .switchToConverted, reason: .scriptScore, candidate: candidate)
        }
        return AutoConvertDecision(verdict: .undecided, reason: .undecided, candidate: candidate)
    }

    public static func hasStrongScriptMismatch(typed: String, converted: String, targetLang: String) -> Bool {
        let target = String(targetLang.lowercased().prefix(2))
        let typedLetters = Array(typed.unicodeScalars.filter { CharacterSet.letters.contains($0) })
        let convertedLetters = Array(converted.unicodeScalars.filter { CharacterSet.letters.contains($0) })
        guard typedLetters.count >= 4, convertedLetters.count >= 4 else { return false }

        switch target {
        case "ru", "uk", "be", "bg":
            return ratio(typedLetters, in: .latin) >= 0.8 && ratio(convertedLetters, in: .cyrillic) >= 0.8
        case "en", "de", "fr", "es", "pt", "pl":
            return ratio(typedLetters, in: .cyrillic) >= 0.8 && ratio(convertedLetters, in: .latin) >= 0.8
        default:
            return false
        }
    }

    private enum Script {
        case latin
        case cyrillic
    }

    private static func shouldBlockSingleLetterInLatinContext(
        candidate: AutoConvertCandidate,
        converted: String,
        targetLang: String,
        context: AutoConvertContext
    ) -> Bool {
        guard isCyrillicTarget(targetLang), convertedLetters(converted).count == 1 else { return false }
        guard let previous = context.previousWord, dominantScript(previous) == .latin else { return false }
        return convertedLetters(candidate.typedRaw).count == 1
    }

    private static func shouldBlockCyrillicToLatinInCyrillicContext(
        candidate: AutoConvertCandidate,
        targetLang: String,
        context: AutoConvertContext
    ) -> Bool {
        guard isLatinTarget(targetLang) else { return false }
        guard dominantScript(candidate.typedRaw) == .cyrillic else { return false }
        guard let previous = context.previousWord else { return false }
        return dominantScript(previous) == .cyrillic
    }

    private static func allowsScriptScore(targetLang: String) -> Bool {
        isCyrillicTarget(targetLang)
    }

    private static func isCyrillicTarget(_ lang: String) -> Bool {
        switch String(lang.lowercased().prefix(2)) {
        case "ru", "uk", "be", "bg":
            return true
        default:
            return false
        }
    }

    private static func isLatinTarget(_ lang: String) -> Bool {
        switch String(lang.lowercased().prefix(2)) {
        case "en", "de", "fr", "es", "pt", "pl":
            return true
        default:
            return false
        }
    }

    private static func isSingleUppercaseLatinLetter(_ s: String) -> Bool {
        let letters = convertedLetters(s)
        guard letters.count == 1, let scalar = letters.first else { return false }
        return isLatin(scalar) && Character(scalar).isUppercase
    }

    private static func dominantScript(_ s: String) -> Script? {
        let letters = convertedLetters(s)
        guard !letters.isEmpty else { return nil }
        let latinCount = letters.filter(isLatin).count
        let cyrillicCount = letters.filter(isCyrillic).count
        if latinCount > cyrillicCount { return .latin }
        if cyrillicCount > latinCount { return .cyrillic }
        return nil
    }

    private static func convertedLetters(_ s: String) -> [UnicodeScalar] {
        Array(s.unicodeScalars.filter { CharacterSet.letters.contains($0) })
    }

    private static func isLatin(_ scalar: UnicodeScalar) -> Bool {
        (0x0041...0x005A).contains(Int(scalar.value)) || (0x0061...0x007A).contains(Int(scalar.value))
    }

    private static func isCyrillic(_ scalar: UnicodeScalar) -> Bool {
        (0x0400...0x04FF).contains(Int(scalar.value))
    }

    private static func ratio(_ scalars: [UnicodeScalar], in script: Script) -> Double {
        guard !scalars.isEmpty else { return 0 }
        let matching = scalars.filter { scalar in
            switch script {
            case .latin:
                return isLatin(scalar)
            case .cyrillic:
                return isCyrillic(scalar)
            }
        }
        return Double(matching.count) / Double(scalars.count)
    }

    private static func isCodeLike(_ s: String) -> Bool {
        if s.contains("://") || s.contains("@") { return true }
        if looksLikeDomainName(s) { return true }
        if s.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) { return true }
        if isAllCaps(s) { return true }
        for (i, c) in s.enumerated() where i > 0 && c.isUppercase { return true }
        var hasLatin = false
        var hasCyrillic = false
        for u in s.unicodeScalars {
            switch u.value {
            case 0x41...0x5A, 0x61...0x7A: hasLatin = true
            case 0x0400...0x04FF: hasCyrillic = true
            default: break
            }
        }
        return hasLatin && hasCyrillic
    }

    private static func looksLikeDomainName(_ s: String) -> Bool {
        let chars = Array(s)
        guard chars.count >= 3 else { return false }
        for index in chars.indices where chars[index] == "." {
            guard index > chars.startIndex, index < chars.index(before: chars.endIndex) else { continue }
            let before = chars[chars.index(before: index)]
            let after = chars[chars.index(after: index)]
            if before.isLetter && after.isLetter { return true }
        }
        return false
    }

    private static func isAllCaps(_ s: String) -> Bool {
        s == s.uppercased() && s != s.lowercased()
    }
}
