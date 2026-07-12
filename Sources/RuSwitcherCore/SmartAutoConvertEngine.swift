import Foundation

public struct SmartAutoConvertEvaluation: Equatable, Sendable {
    public let decision: AutoConvertDecision
    public let literalScore: Double
    public let convertedScore: Double
    public let confidenceMargin: Double

    public init(decision: AutoConvertDecision, literalScore: Double, convertedScore: Double) {
        self.decision = decision
        self.literalScore = literalScore
        self.convertedScore = convertedScore
        self.confidenceMargin = convertedScore - literalScore
    }
}

public enum SmartAutoConvertEngine {
    public static func evaluate(
        typed: String,
        converted: String,
        currentLanguage: String,
        targetLanguage: String,
        capsLock: Bool,
        contextWords: [String],
        languageState: TypingLanguageState = .neutral,
        policy: AutoConvertPolicy,
        adaptiveBias: (String, String) -> Double = { _, _ in 0 },
        isValidWord: (String, String) -> Bool
    ) -> SmartAutoConvertEvaluation {
        let candidates = AutoConvertCandidateGenerator.candidates(typed: typed, converted: converted)
        let currentCore = SmartTokenizer.lexicalCore(of: typed)
        let currentValid = isValidWord(currentCore, currentLanguage)

        let evaluations = candidates.map { candidate in
            evaluateCandidate(
                candidate,
                currentLanguage: currentLanguage,
                targetLanguage: targetLanguage,
                capsLock: capsLock,
                contextWords: contextWords,
                languageState: languageState,
                policy: policy,
                adaptiveBias: adaptiveBias(typed, candidate.replacement),
                currentValid: currentValid,
                convertedValid: isValidWord(candidate.convertedWord, targetLanguage)
            )
        }

        return evaluations.max { lhs, rhs in
            if lhs.decision.verdict == .switchToConverted, rhs.decision.verdict != .switchToConverted { return false }
            if lhs.decision.verdict != .switchToConverted, rhs.decision.verdict == .switchToConverted { return true }
            return lhs.convertedScore < rhs.convertedScore
        } ?? fallback(typed: typed, converted: converted)
    }

    private static func evaluateCandidate(
        _ candidate: AutoConvertCandidate,
        currentLanguage: String,
        targetLanguage: String,
        capsLock: Bool,
        contextWords: [String],
        languageState: TypingLanguageState,
        policy: AutoConvertPolicy,
        adaptiveBias: Double,
        currentValid: Bool,
        convertedValid: Bool
    ) -> SmartAutoConvertEvaluation {
        let typed = FrequentWordLexicon.normalize(candidate.typedRaw)
        let currentCore = SmartTokenizer.lexicalCore(of: typed)
        let convertedCore = FrequentWordLexicon.normalize(
            SmartTokenizer.lexicalCore(of: candidate.convertedWord)
        )
        let typedShape = SmartTokenizer.shape(of: candidate.typedRaw)
        let convertedShape = SmartTokenizer.shape(of: candidate.replacement)

        if policy.neverConvert.contains(typed) || policy.neverConvert.contains(convertedCore) {
            return fixed(candidate, verdict: .keep, reason: .blockedNever)
        }
        if policy.alwaysConvert.contains(convertedCore) {
            return fixed(candidate, verdict: .switchToConverted, reason: .alwaysConvert)
        }
        if adaptiveBias <= -10 {
            return fixed(candidate, verdict: .keep, reason: .blockedLearned)
        }
        if SmartTokenizer.isSingleUppercaseLetter(candidate.typedRaw) || typedShape.kind.blocksAutomaticConversion {
            return fixed(candidate, verdict: .keep, reason: .blockedCodeLike)
        }
        if convertedShape.kind.blocksAutomaticConversion
            && candidate.kind != .trailingPunctuation
            && candidate.kind != .wrappingPunctuation {
            return fixed(candidate, verdict: .keep, reason: .blockedCodeLike)
        }

        var literalScore = LocalLanguageModel.wordScore(currentCore, language: currentLanguage)
        var convertedScore = LocalLanguageModel.wordScore(convertedCore, language: targetLanguage) + adaptiveBias
        literalScore += LocalLanguageModel.contextScore(words: contextWords, language: currentLanguage)
        convertedScore += LocalLanguageModel.contextScore(words: contextWords, language: targetLanguage)
        literalScore += languageState.score(language: currentLanguage)
        convertedScore += languageState.score(language: targetLanguage)

        if currentValid { literalScore += 4.5 }
        if convertedValid { convertedScore += 5.5 }
        if FrequentWordLexicon.contains(currentCore, language: currentLanguage) { literalScore += 5 }
        if FrequentWordLexicon.contains(convertedCore, language: targetLanguage) { convertedScore += 6 }

        let sourceHint = SmartTokenizer.languageHint(for: currentCore)
        let targetHint = SmartTokenizer.languageHint(for: convertedCore)
        if sourceHint.map({ LocalLanguageModel.canonical($0) == LocalLanguageModel.canonical(currentLanguage) }) == true {
            literalScore += 1.5
        }
        if targetHint.map({ LocalLanguageModel.canonical($0) == LocalLanguageModel.canonical(targetLanguage) }) == true {
            convertedScore += 1.5
        }

        if candidate.kind == .trailingPunctuation || candidate.kind == .wrappingPunctuation {
            convertedScore += 0.4
        }
        if capsLock { literalScore += 1.0 }

        let previousLanguage = contextWords.last.flatMap(SmartTokenizer.languageHint)
        if convertedCore.count == 1,
           previousLanguage.map({ LocalLanguageModel.canonical($0) == "en" }) == true,
           LocalLanguageModel.canonical(targetLanguage) == "ru" {
            return fixed(candidate, verdict: .keep, reason: .blockedContext)
        }

        let margin = convertedScore - literalScore
        let targetFrequent = FrequentWordLexicon.contains(convertedCore, language: targetLanguage)
        let sourceFrequent = FrequentWordLexicon.contains(currentCore, language: currentLanguage)
        let threshold = convertedCore.count <= 2 ? 3.0 : 2.4

        let reason: AutoConvertDecisionReason
        if targetFrequent {
            reason = convertedCore.count <= 3 ? .frequentShort : .frequentWord
        } else if convertedValid {
            reason = .dictionary
        } else {
            reason = .scriptScore
        }

        if margin >= threshold,
           targetFrequent || convertedValid || strongMismatch(candidate, targetLanguage: targetLanguage) {
            return SmartAutoConvertEvaluation(
                decision: AutoConvertDecision(verdict: .switchToConverted, reason: reason, candidate: candidate),
                literalScore: literalScore,
                convertedScore: convertedScore
            )
        }

        let verdict: LayoutVerdict = currentValid || sourceFrequent || literalScore > convertedScore ? .keep : .undecided
        let keepReason: AutoConvertDecisionReason = verdict == .keep ? .keepCurrentWord : .undecided
        return SmartAutoConvertEvaluation(
            decision: AutoConvertDecision(verdict: verdict, reason: keepReason, candidate: candidate),
            literalScore: literalScore,
            convertedScore: convertedScore
        )
    }

    private static func strongMismatch(_ candidate: AutoConvertCandidate, targetLanguage: String) -> Bool {
        guard LocalLanguageModel.canonical(targetLanguage) == "ru" else { return false }
        return LayoutDetector.hasStrongScriptMismatch(
            typed: candidate.typedRaw,
            converted: candidate.convertedWord,
            targetLang: targetLanguage
        )
    }

    private static func fixed(
        _ candidate: AutoConvertCandidate,
        verdict: LayoutVerdict,
        reason: AutoConvertDecisionReason
    ) -> SmartAutoConvertEvaluation {
        let literal = verdict == .switchToConverted ? 0.0 : 100.0
        let converted = verdict == .switchToConverted ? 100.0 : 0.0
        return SmartAutoConvertEvaluation(
            decision: AutoConvertDecision(verdict: verdict, reason: reason, candidate: candidate),
            literalScore: literal,
            convertedScore: converted
        )
    }

    private static func fallback(typed: String, converted: String) -> SmartAutoConvertEvaluation {
        let candidate = AutoConvertCandidate(
            typedRaw: typed,
            convertedRaw: converted,
            convertedWord: converted,
            suffix: "",
            kind: .directWord
        )
        return fixed(candidate, verdict: .undecided, reason: .undecided)
    }

}
