import Foundation

public enum DecoderEvidence: Equatable, Sendable {
    case frequent
    case characterModel
    case phraseContext
    case compound(segmentLengths: [Int])
    case confirmedByUser
    case blockedCode
    case blockedNever
    case blockedEditing
    case blockedContext
}

public struct LayoutDecoderEvaluation: Equatable, Sendable {
    public let decision: AutoConvertDecision
    public let literalScore: Double
    public let convertedScore: Double
    public let threshold: Double
    public let evidence: [DecoderEvidence]

    public var confidenceMargin: Double { convertedScore - literalScore }

    public init(
        decision: AutoConvertDecision,
        literalScore: Double,
        convertedScore: Double,
        threshold: Double,
        evidence: [DecoderEvidence]
    ) {
        self.decision = decision
        self.literalScore = literalScore
        self.convertedScore = convertedScore
        self.threshold = threshold
        self.evidence = evidence
    }
}

public enum LayoutDecoder {
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
        model: LanguageModelStore
    ) -> LayoutDecoderEvaluation {
        let generated = AutoConvertCandidateGenerator.candidates(typed: typed, converted: converted)
        // A physical punctuation key may be a real letter in the target layout.
        // When the full direct conversion is already a known word (помощью,
        // приветствую), punctuation alternatives must not truncate it.
        let direct = generated.first { $0.suffix.isEmpty }
        let directIsKnown = direct.flatMap {
            model.wordLogProbability(
                FrequentWordLexicon.normalize($0.convertedWord),
                language: LocalLanguageModel.canonical(targetLanguage)
            )
        } != nil
        let candidates = directIsKnown ? direct.map { [$0] } ?? generated : generated
        let evaluations = candidates.map { candidate in
            evaluateCandidate(
                candidate,
                currentLanguage: currentLanguage,
                targetLanguage: targetLanguage,
                capsLock: capsLock,
                contextWords: contextWords,
                languageBelief: languageBelief,
                integrity: integrity,
                policy: policy,
                adaptiveBias: adaptiveBias(typed, candidate.replacement),
                confirmed: isConfirmed(typed, candidate.replacement),
                model: model
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
        languageBelief: LanguageBelief,
        integrity: EditorIntegrity,
        policy: AutoConvertPolicy,
        adaptiveBias: Double,
        confirmed: Bool,
        model: LanguageModelStore
    ) -> LayoutDecoderEvaluation {
        let typed = FrequentWordLexicon.normalize(candidate.typedRaw)
        let literal = SmartTokenizer.lexicalCore(of: typed)
        let converted = FrequentWordLexicon.normalize(candidate.convertedWord)
        let shape = SmartTokenizer.shape(of: candidate.typedRaw)
        let convertedShape = SmartTokenizer.shape(of: candidate.replacement)
        let baseCandidate = candidate
        let currentCanonical = LocalLanguageModel.canonical(currentLanguage)
        let targetCanonical = LocalLanguageModel.canonical(targetLanguage)
        let targetKnownForShape = model.wordLogProbability(converted, language: targetCanonical)

        if integrity != .clean {
            return fixed(baseCandidate, verdict: .keep, reason: .blockedEditing, evidence: [.blockedEditing])
        }
        if policy.neverConvert.contains(typed) || policy.neverConvert.contains(converted) {
            return fixed(baseCandidate, verdict: .keep, reason: .blockedNever, evidence: [.blockedNever])
        }
        let sourceShapeIsProtected = shape.kind.blocksAutomaticConversion
            && !(convertedShape.kind == .lexical && targetKnownForShape != nil)
        if Self.isSingleUppercaseLatin(candidate.typedRaw)
            || sourceShapeIsProtected
            || (convertedShape.kind.blocksAutomaticConversion && candidate.kind != .trailingPunctuation) {
            return fixed(baseCandidate, verdict: .keep, reason: .blockedCodeLike, evidence: [.blockedCode])
        }

        let always = policy.alwaysConvert.contains(converted)
        if always {
            return fixed(baseCandidate, verdict: .switchToConverted, reason: .alwaysConvert, evidence: [.frequent])
        }
        if adaptiveBias <= -10 {
            return fixed(baseCandidate, verdict: .keep, reason: .blockedLearned, evidence: [.blockedContext])
        }
        if confirmed {
            return fixed(baseCandidate, verdict: .switchToConverted, reason: .confirmedByUser, evidence: [.confirmedByUser])
        }

        let sourceKnown = model.wordLogProbability(literal, language: currentCanonical)
        let targetKnown = targetKnownForShape
        if literal.count >= 2, sourceKnown != nil, targetKnown != nil {
            return fixed(baseCandidate, verdict: .keep, reason: .blockedContext, evidence: [.blockedContext])
        }
        // A compound is evidence only when the literal hypothesis is not itself a
        // known word. This protects ordinary English prose from productive Russian
        // prefix decompositions that happen to share the same physical keys.
        let compound = sourceKnown == nil
            ? CompoundWordAnalyzer.analyze(converted, language: targetCanonical, model: model)
            : nil
        var evidence: [DecoderEvidence] = []

        var literalScore = Self.lexicalScore(literal, language: currentCanonical, known: sourceKnown, model: model)
        var convertedScore = Self.lexicalScore(converted, language: targetCanonical, known: targetKnown, model: model)
        literalScore += languageBelief.score(language: currentCanonical)
        convertedScore += languageBelief.score(language: targetCanonical) + adaptiveBias

        if sourceKnown != nil { literalScore += 2.2 }
        if targetKnown != nil {
            convertedScore += 3.0
            evidence.append(.frequent)
        } else {
            evidence.append(.characterModel)
        }

        if let score = model.phraseLogProbability(context: contextWords, candidate: literal, language: currentCanonical) {
            literalScore += max(0, 3.2 + score * 0.45)
        }
        if let score = model.phraseLogProbability(context: contextWords, candidate: converted, language: targetCanonical) {
            convertedScore += max(0, 3.8 + score * 0.45)
            evidence.append(.phraseContext)
        }
        if let compound {
            convertedScore += model.thresholds.compoundBonus + min(4, compound.score * 0.18)
            evidence.append(.compound(segmentLengths: compound.segments.map(\.count)))
        }

        let sourceHint = SmartTokenizer.languageHint(for: literal)
        let targetHint = SmartTokenizer.languageHint(for: converted)
        if sourceHint.map({ LocalLanguageModel.canonical($0) == currentCanonical }) == true { literalScore += 1.2 }
        if targetHint.map({ LocalLanguageModel.canonical($0) == targetCanonical }) == true { convertedScore += 1.2 }
        if candidate.kind == .trailingPunctuation { convertedScore += 0.35 }
        if capsLock { literalScore += 1.0 }

        let targetProbability = languageBelief.probability(language: targetCanonical)
        let currentProbability = languageBelief.probability(language: currentCanonical)
        let threshold: Double
        if converted.count <= 2 {
            threshold = model.thresholds.short
        } else if targetProbability >= 0.68 {
            threshold = model.thresholds.russianContext
        } else if currentProbability >= 0.68 {
            threshold = model.thresholds.englishContext
        } else {
            threshold = model.thresholds.neutral
        }

        if converted.count == 1,
           contextWords.last.flatMap(SmartTokenizer.languageHint).map({ LocalLanguageModel.canonical($0) == "en" }) == true,
           targetCanonical == "ru" {
            return fixed(baseCandidate, verdict: .keep, reason: .blockedContext, evidence: [.blockedContext])
        }
        if currentCanonical == "ru", targetCanonical == "en",
           sourceKnown == nil, targetKnown == nil {
            // An unknown Cyrillic word must never flip to unknown Latin text on
            // character/script plausibility alone.
            return fixed(baseCandidate, verdict: .keep, reason: .blockedContext, evidence: [.blockedContext])
        }

        let margin = convertedScore - literalScore
        let hasLexicalEvidence = targetKnown != nil || compound != nil
            || LayoutDetector.hasStrongScriptMismatch(typed: candidate.typedRaw, converted: converted, targetLang: targetLanguage)
        let verdict: LayoutVerdict = margin >= threshold && hasLexicalEvidence ? .switchToConverted : (sourceKnown != nil ? .keep : .undecided)
        let reason: AutoConvertDecisionReason
        if verdict == .switchToConverted {
            if compound != nil && targetKnown == nil { reason = .compound }
            else if evidence.contains(.phraseContext) { reason = .phraseContext }
            else if targetKnown != nil { reason = converted.count <= 3 ? .frequentShort : .frequentWord }
            else { reason = .characterModel }
        } else {
            reason = verdict == .keep ? .keepCurrentWord : .undecided
        }
        return LayoutDecoderEvaluation(
            decision: AutoConvertDecision(verdict: verdict, reason: reason, candidate: candidate),
            literalScore: literalScore,
            convertedScore: convertedScore,
            threshold: threshold,
            evidence: evidence
        )
    }

    private static func lexicalScore(
        _ word: String,
        language: String,
        known: Double?,
        model: LanguageModelStore
    ) -> Double {
        let character = 13.0 + model.characterLogProbability(word, language: language)
        guard let known else { return character }
        return character + 7.5 + known * 0.55
    }

    private static func fixed(
        _ candidate: AutoConvertCandidate,
        verdict: LayoutVerdict,
        reason: AutoConvertDecisionReason,
        evidence: [DecoderEvidence]
    ) -> LayoutDecoderEvaluation {
        LayoutDecoderEvaluation(
            decision: AutoConvertDecision(verdict: verdict, reason: reason, candidate: candidate),
            literalScore: verdict == .switchToConverted ? 0 : 100,
            convertedScore: verdict == .switchToConverted ? 100 : 0,
            threshold: 0,
            evidence: evidence
        )
    }

    private static func fallback(typed: String, converted: String) -> LayoutDecoderEvaluation {
        let candidate = AutoConvertCandidate(
            typedRaw: typed,
            convertedRaw: converted,
            convertedWord: converted,
            suffix: "",
            kind: .directWord
        )
        return fixed(candidate, verdict: .undecided, reason: .undecided, evidence: [])
    }

    private static func isSingleUppercaseLatin(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        guard letters.count == 1, let character = letters.first else { return false }
        return character.isUppercase && character.unicodeScalars.allSatisfy { (0x41...0x5A).contains(Int($0.value)) }
    }
}
