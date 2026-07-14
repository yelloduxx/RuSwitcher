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
        let learned = mandatoryBaselineDecision(baseline, typed: typed)
            ? baseline
            : learnedEvaluation(
                prediction: prediction,
                items: items,
                fallback: baseline
            )
        return V3LayoutEngineEvaluation(
            selected: mode == .active ? learned : baseline,
            baseline: baseline,
            learned: learned,
            mode: mode
        )
    }

    private static func mandatoryBaselineDecision(
        _ baseline: LayoutDecoderEvaluation,
        typed: String
    ) -> Bool {
        // The learned layer is a calibrated resolver for V3 uncertainty, not a
        // second decoder. Preserve every conclusive V3 switch/keep so a model
        // cannot replace a correct punctuation path with another lattice path.
        guard baseline.decision.verdict == .undecided else { return true }
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
