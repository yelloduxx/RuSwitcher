import Foundation

public enum V3LayoutEngineMode: String, Codable, Sendable {
    case baseline
    case shadow
    case active
}

public struct V3LayoutEngineEvaluation: Equatable, Sendable {
    public let selected: LayoutDecoderEvaluation
    public let baseline: LayoutDecoderEvaluation
    public let learned: LayoutDecoderEvaluation?
    public let mode: V3LayoutEngineMode

    public var disagrees: Bool {
        guard let learned else { return false }
        return learned.decision.verdict != baseline.decision.verdict
            || learned.decision.candidate.replacement != baseline.decision.candidate.replacement
    }

    public init(
        selected: LayoutDecoderEvaluation,
        baseline: LayoutDecoderEvaluation,
        learned: LayoutDecoderEvaluation?,
        mode: V3LayoutEngineMode
    ) {
        self.selected = selected
        self.baseline = baseline
        self.learned = learned
        self.mode = mode
    }
}

/// The production V3 decision surface. The learned ranker only chooses among
/// deterministic physical-key hypotheses; V3 safety and user rules remain
/// authoritative, and a missing or invalid ranker falls back to the baseline.
public enum V3LayoutEngine {
    private static let maximumBoundaryCharacterPenalty = 1.5
    private static let minimumUnknownBoundaryCharacterAdvantage = 0.25

    public static func evaluate(
        typed: String,
        converted: String,
        currentLanguage: String,
        targetLanguage: String,
        capsLock: Bool,
        contextWords: [String],
        languageBelief: LanguageBelief,
        integrity: EditorIntegrity = .clean,
        policy: AutoConvertPolicy,
        adaptiveBias: (String, String) -> Double = { _, _ in 0 },
        isConfirmed: (String, String) -> Bool = { _, _ in false },
        physicalStrokes: [PhysicalKeyStroke]? = nil,
        model: LanguageModelStore,
        ranker: LayoutRankerModel?,
        mode: V3LayoutEngineMode
    ) -> V3LayoutEngineEvaluation {
        let baseline = LayoutDecoder.evaluate(
            typed: typed,
            converted: converted,
            currentLanguage: currentLanguage,
            targetLanguage: targetLanguage,
            capsLock: capsLock,
            contextWords: contextWords,
            languageBelief: languageBelief,
            integrity: integrity,
            policy: policy,
            adaptiveBias: adaptiveBias,
            isConfirmed: isConfirmed,
            physicalStrokes: physicalStrokes,
            model: model
        )
        guard mode != .baseline, let ranker else {
            return V3LayoutEngineEvaluation(
                selected: baseline,
                baseline: baseline,
                learned: nil,
                mode: .baseline
            )
        }

        let items = LayoutRankerFeatureSchema.extract(
            context: LayoutRankerContext(
                typed: typed,
                converted: converted,
                currentLanguage: currentLanguage,
                targetLanguage: targetLanguage,
                contextWords: contextWords,
                languageBelief: languageBelief,
                capsLock: capsLock,
                physicalStrokes: physicalStrokes
            ),
            model: model
        )
        let prediction = ranker.predict(items: items)
        let ranked = learnedEvaluation(
            prediction: prediction,
            items: items,
            fallback: baseline
        )
        let learned = mandatoryBaselineDecision(
            baseline,
            ranked: ranked,
            typed: typed,
            converted: converted,
            currentLanguage: currentLanguage,
            targetLanguage: targetLanguage,
            contextWords: contextWords,
            languageBelief: languageBelief,
            model: model
        )
            ? baseline
            : ranked
        return V3LayoutEngineEvaluation(
            selected: mode == .active ? learned : baseline,
            baseline: baseline,
            learned: learned,
            mode: mode
        )
    }

    private static func mandatoryBaselineDecision(
        _ baseline: LayoutDecoderEvaluation,
        ranked: LayoutDecoderEvaluation,
        typed: String,
        converted: String,
        currentLanguage: String,
        targetLanguage: String,
        contextWords: [String],
        languageBelief: LanguageBelief,
        model: LanguageModelStore
    ) -> Bool {
        // A calibrated ranker may refine a conclusive switch only from a mixed
        // punctuation path to the complete opposite-layout path. It still
        // cannot turn a conclusive keep into a replacement or suppress a
        // confirmed conversion.
        if baseline.decision.verdict == .switchToConverted {
            return !mayRefineToWholeLayoutPath(
                baseline: baseline,
                ranked: ranked,
                converted: converted,
                targetLanguage: targetLanguage,
                model: model
            )
        }
        guard baseline.decision.verdict == .undecided else { return true }
        let shape = SmartTokenizer.shape(of: typed)
        if shape.kind.blocksAutomaticConversion { return true }
        let current = LanguageCode.canonical(currentLanguage)
        let target = LanguageCode.canonical(targetLanguage)
        if current == "en", target == "ru" {
            if !shape.prefix.isEmpty, !shape.suffix.isEmpty { return true }
            if SmartTokenizer.isTitleCaseLexicalWord(typed) {
                let recent = contextWords.suffix(4).compactMap(SmartTokenizer.languageHint)
                    .map(LanguageCode.canonical)
                let targetCount = recent.count(where: { $0 == target })
                let currentCount = recent.count(where: { $0 == current })
                if targetCount <= currentCount
                    || languageBelief.probability(language: target) < 0.62 {
                    return true
                }
            }
        }
        switch baseline.decision.reason {
        case .blockedNever, .blockedCodeLike, .blockedLearned, .blockedEditing,
             .alwaysConvert, .confirmedByUser:
            return true
        case .keepCurrentWord:
            return SmartTokenizer.lexicalCore(of: typed).filter(\.isLetter).count == 1
        default:
            return false
        }
    }

    private static func mayRefineToWholeLayoutPath(
        baseline: LayoutDecoderEvaluation,
        ranked: LayoutDecoderEvaluation,
        converted: String,
        targetLanguage: String,
        model: LanguageModelStore
    ) -> Bool {
        let baselineReplacement = baseline.decision.candidate.replacement
        guard ranked.decision.verdict == .switchToConverted,
              baselineReplacement != converted,
              ranked.decision.candidate.replacement == converted else {
            return false
        }

        let baselineCore = FrequentWordLexicon.normalize(
            SmartTokenizer.lexicalCore(of: baselineReplacement)
        )
        let fullCore = FrequentWordLexicon.normalize(
            SmartTokenizer.lexicalCore(of: converted)
        )
        guard !fullCore.isEmpty else { return false }
        if fullCore == baselineCore { return true }

        let target = LanguageCode.canonical(targetLanguage)
        let fullKnown = model.wordLogProbability(fullCore, language: target) != nil
            || (target == "en" && model.isExtendedEnglishWord(fullCore))
            || (target == "ru" && model.isExtendedRussianWord(fullCore))
        let fullCharacter = model.characterLogProbability(fullCore, language: target)
        let baselineCharacter = model.characterLogProbability(baselineCore, language: target)
        let characterAdvantage = fullCharacter - baselineCharacter
        if fullKnown {
            return characterAdvantage >= -maximumBoundaryCharacterPenalty
        }
        return characterAdvantage >= minimumUnknownBoundaryCharacterAdvantage
    }

    private static func learnedEvaluation(
        prediction: LayoutRankerPrediction,
        items: [LayoutRankerItem],
        fallback: LayoutDecoderEvaluation
    ) -> LayoutDecoderEvaluation {
        guard items.indices.contains(prediction.winnerIndex) else { return fallback }
        let winner = items[prediction.winnerIndex]
        let candidate = winner.hypothesis.candidate ?? fallback.decision.candidate
        let literalIndex = items.firstIndex(where: { $0.hypothesis.isLiteral }) ?? 0
        let literalScore = prediction.probabilities.indices.contains(literalIndex)
            ? prediction.probabilities[literalIndex]
            : 1
        let convertedScore = items.indices
            .filter { !items[$0].hypothesis.isLiteral }
            .compactMap { prediction.probabilities.indices.contains($0) ? prediction.probabilities[$0] : nil }
            .max() ?? 0
        var evidence: [DecoderEvidence] = [.characterModel]
        if winner.hypothesis.kind == .trailingPunctuation
            || winner.hypothesis.kind == .layoutLetterTail
            || winner.hypothesis.kind == .wrappingPunctuation {
            evidence.append(.punctuationPath)
        }

        let verdict: LayoutVerdict
        let reason: AutoConvertDecisionReason
        switch prediction.action {
        case .switchLayout:
            guard winner.hypothesis.candidate != nil else { return fallback }
            verdict = .switchToConverted
            reason = .characterModel
        case .keep:
            verdict = .keep
            reason = .keepCurrentWord
        case .abstain:
            verdict = .undecided
            reason = .undecided
            evidence.append(.abstained)
        }
        return LayoutDecoderEvaluation(
            decision: AutoConvertDecision(
                verdict: verdict,
                reason: reason,
                candidate: candidate
            ),
            literalScore: literalScore,
            convertedScore: convertedScore,
            threshold: prediction.threshold,
            evidence: evidence
        )
    }
}
