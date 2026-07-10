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
    case neuralContext
    case codeSwitch
    case punctuationPath
    case personalized
    case abstained
    case englishSourceFrequent
    case englishSourceDictionary
    case englishSourcePlausible
    case englishSourceUnlikely
    case englishTargetDictionary
    case russianSourceDictionary
    case russianTargetDictionary
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
        let targetCanonical = LocalLanguageModel.canonical(targetLanguage)
        func candidateWord(_ candidate: AutoConvertCandidate) -> String {
            FrequentWordLexicon.normalize(
                SmartTokenizer.lexicalCore(of: candidate.convertedWord)
            )
        }
        let frequentCandidates = generated.filter { candidate in
            let word = candidateWord(candidate)
            return model.wordLogProbability(word, language: targetCanonical) != nil
                || FrequentWordLexicon.contains(word, language: targetCanonical)
        }
        let spellingCandidates = generated.filter { candidate in
            let word = candidateWord(candidate)
            return (targetCanonical == "en" && model.isExtendedEnglishWord(word))
                || (targetCanonical == "ru" && model.isExtendedRussianWord(word))
        }
        // Frequency evidence dominates spelling-only membership, which in turn
        // dominates character-only interpretations of the same physical keys.
        let candidates: [AutoConvertCandidate]
        if !frequentCandidates.isEmpty {
            candidates = frequentCandidates
        } else if !spellingCandidates.isEmpty {
            candidates = spellingCandidates
        } else {
            candidates = generated
        }
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
            let lhsHasPhraseEvidence = lhs.evidence.contains(.phraseContext)
            let rhsHasPhraseEvidence = rhs.evidence.contains(.phraseContext)
            if lhsHasPhraseEvidence != rhsHasPhraseEvidence {
                return !lhsHasPhraseEvidence && rhsHasPhraseEvidence
            }
            let lhsPreservesTypedSuffix = preservesTypedSuffix(lhs.decision.candidate)
            let rhsPreservesTypedSuffix = preservesTypedSuffix(rhs.decision.candidate)
            if lhsPreservesTypedSuffix != rhsPreservesTypedSuffix {
                return !lhsPreservesTypedSuffix && rhsPreservesTypedSuffix
            }
            if lhsPreservesTypedSuffix {
                let lhsDecoration = preservedDecorationCount(lhs.decision.candidate)
                let rhsDecoration = preservedDecorationCount(rhs.decision.candidate)
                if lhsDecoration != rhsDecoration {
                    return lhsDecoration < rhsDecoration
                }
            }
            if abs(lhs.convertedScore - rhs.convertedScore) > 0.000_001 {
                return lhs.convertedScore < rhs.convertedScore
            }
            return preservedDecorationCount(lhs.decision.candidate)
                < preservedDecorationCount(rhs.decision.candidate)
        } ?? fallback(typed: typed, converted: converted)
    }

    private static func preservedDecorationCount(_ candidate: AutoConvertCandidate) -> Int {
        candidate.prefix.count + candidate.suffix.count
    }

    private static func preservesTypedSuffix(_ candidate: AutoConvertCandidate) -> Bool {
        !candidate.suffix.isEmpty && candidate.typedRaw.hasSuffix(candidate.suffix)
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
        let converted = FrequentWordLexicon.normalize(
            SmartTokenizer.lexicalCore(of: candidate.convertedWord)
        )
        let shape = SmartTokenizer.shape(of: candidate.typedRaw)
        let convertedShape = SmartTokenizer.shape(of: candidate.replacement)
        let baseCandidate = candidate
        let currentCanonical = LocalLanguageModel.canonical(currentLanguage)
        let targetCanonical = LocalLanguageModel.canonical(targetLanguage)
        let targetKnownForShape = model.wordLogProbability(converted, language: targetCanonical)
        let targetExtendedEnglish = targetCanonical == "en" && model.isExtendedEnglishWord(converted)
        let targetExtendedRussian = targetCanonical == "ru" && model.isExtendedRussianWord(converted)

        if integrity != .clean {
            return fixed(baseCandidate, verdict: .keep, reason: .blockedEditing, evidence: [.blockedEditing])
        }
        if policy.neverConvert.contains(typed) || policy.neverConvert.contains(converted) {
            return fixed(baseCandidate, verdict: .keep, reason: .blockedNever, evidence: [.blockedNever])
        }
        let sourceShapeIsProtected = shape.kind.blocksAutomaticConversion
            && !(convertedShape.kind == .lexical
                && (targetKnownForShape != nil || targetExtendedEnglish || targetExtendedRussian))
        if Self.isSingleUppercaseLatin(candidate.typedRaw)
            || sourceShapeIsProtected
            || (convertedShape.kind.blocksAutomaticConversion
                && candidate.kind != .trailingPunctuation
                && candidate.kind != .wrappingPunctuation) {
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
        let sourceExtendedRussian = currentCanonical == "ru" && model.isExtendedRussianWord(literal)
        let targetKnown = targetKnownForShape
        let directConsumesLeadingPunctuation = targetCanonical == "ru"
            && targetExtendedRussian
            && candidate.prefix.isEmpty
            && candidate.typedRaw.first.map(Self.isPunctuation) == true
        let englishSourceConfidence: EnglishSourceConfidence? = currentCanonical == "en" && targetCanonical == "ru"
            ? (directConsumesLeadingPunctuation
                ? .unlikely
                : EnglishSourceClassifier.classify(literal, model: model))
            : nil
        let strongScriptMismatch = LayoutDetector.hasStrongScriptMismatch(
            typed: candidate.typedRaw,
            converted: converted,
            targetLang: targetLanguage
        )
        let characterAdvantage = model.characterLogProbability(converted, language: targetCanonical)
            - model.characterLogProbability(literal, language: currentCanonical)
        let strongExtendedEnglishTarget = currentCanonical == "ru"
            && targetExtendedEnglish
            && converted.count >= 4
            && sourceKnown == nil
            && characterAdvantage >= model.thresholds.englishTargetCharacterAdvantage
        let strongExtendedRussianTarget = currentCanonical == "en"
            && targetExtendedRussian
            && sourceKnown == nil
            && englishSourceConfidence == .unlikely
        if literal.count >= 2,
           sourceKnown != nil || sourceExtendedRussian,
           targetKnown != nil || targetExtendedEnglish || targetExtendedRussian {
            return fixed(baseCandidate, verdict: .keep, reason: .blockedContext, evidence: [.blockedContext])
        }
        if literal.count >= 2, englishSourceConfidence == .frequent {
            return fixed(
                baseCandidate,
                verdict: .keep,
                reason: .keepCurrentWord,
                evidence: [.englishSourceFrequent]
            )
        }
        if literal.count >= 2, englishSourceConfidence == .dictionary {
            return fixed(
                baseCandidate,
                verdict: .keep,
                reason: .keepCurrentWord,
                evidence: [.englishSourceDictionary]
            )
        }
        if literal.count >= 2, sourceExtendedRussian {
            return fixed(
                baseCandidate,
                verdict: .keep,
                reason: .keepCurrentWord,
                evidence: [.russianSourceDictionary]
            )
        }
        if directConsumesLeadingPunctuation, strongExtendedRussianTarget {
            return fixed(
                baseCandidate,
                verdict: .switchToConverted,
                reason: .frequentWord,
                evidence: [.russianTargetDictionary, .punctuationPath]
            )
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
        let currentBeliefScore = languageBelief.score(language: currentCanonical)
        let targetBeliefScore = languageBelief.score(language: targetCanonical)
        literalScore += currentBeliefScore
        convertedScore += targetBeliefScore + adaptiveBias

        if currentCanonical == "en", targetCanonical == "ru",
           sourceKnown == nil, targetKnown == nil,
           strongScriptMismatch, converted.count >= 6,
           characterAdvantage >= model.thresholds.russianOOVEnglishLong {
            convertedScore += max(0, currentBeliefScore - targetBeliefScore)
        }
        if strongExtendedEnglishTarget {
            // A stale Russian context should not suppress an exact English
            // spelling when the physical Cyrillic form is clearly implausible.
            convertedScore += max(0, currentBeliefScore - targetBeliefScore)
        }
        if strongExtendedRussianTarget {
            convertedScore += max(0, currentBeliefScore - targetBeliefScore)
        }

        if sourceKnown != nil { literalScore += 2.2 }
        if englishSourceConfidence == .plausibleOOV {
            literalScore += model.thresholds.englishSourcePlausibleBonus
            evidence.append(.englishSourcePlausible)
        } else if englishSourceConfidence == .unlikely {
            evidence.append(.englishSourceUnlikely)
        }
        if targetKnown != nil {
            convertedScore += 3.0
            evidence.append(.frequent)
        } else if strongExtendedEnglishTarget {
            convertedScore += 3.0
            evidence.append(.englishTargetDictionary)
        } else if strongExtendedRussianTarget {
            convertedScore += 3.0
            evidence.append(.russianTargetDictionary)
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
        if candidate.kind == .trailingPunctuation || candidate.kind == .wrappingPunctuation {
            convertedScore += 0.35
            if !candidate.suffix.isEmpty,
               Self.preservesTypedSuffix(candidate),
               candidate.suffix.allSatisfy({ ".!?".contains($0) }) {
                convertedScore += min(1.5, Double(candidate.suffix.count) * 0.5)
            }
        }
        if capsLock { literalScore += 1.0 }

        let targetProbability = languageBelief.probability(language: targetCanonical)
        let currentProbability = languageBelief.probability(language: currentCanonical)
        var threshold: Double
        if converted.count <= 2 {
            threshold = model.thresholds.short
        } else if targetProbability >= 0.68 {
            threshold = model.thresholds.russianContext
        } else if currentProbability >= 0.68 {
            threshold = model.thresholds.englishContext
        } else {
            threshold = model.thresholds.neutral
        }

        if currentCanonical == "en", targetCanonical == "ru",
           sourceKnown == nil, targetKnown == nil, strongScriptMismatch {
            if currentProbability < 0.62 {
                threshold = min(threshold, model.thresholds.russianOOVNeutral)
            } else if converted.count >= 6 {
                threshold = min(threshold, model.thresholds.russianOOVEnglishLong)
            }
        }

        if converted.count == 1,
           contextWords.last.flatMap(SmartTokenizer.languageHint).map({ LocalLanguageModel.canonical($0) == "en" }) == true,
           targetCanonical == "ru" {
            return fixed(baseCandidate, verdict: .keep, reason: .blockedContext, evidence: [.blockedContext])
        }
        if currentCanonical == "ru", targetCanonical == "en",
           sourceKnown == nil, targetKnown == nil, !strongExtendedEnglishTarget {
            // Unknown English words can still be clear layout mistakes (афиду →
            // fable). Permit them only when the character model has a strong
            // advantage and the recent language state is not distinctly Russian.
            let characterAdvantage = model.characterLogProbability(converted, language: targetCanonical)
                - model.characterLogProbability(literal, language: currentCanonical)
            if converted.count < 5
                || characterAdvantage < model.thresholds.englishTargetCharacterAdvantage
                || currentProbability >= 0.62 {
                return fixed(baseCandidate, verdict: .keep, reason: .blockedContext, evidence: [.blockedContext])
            }
        }

        let margin = convertedScore - literalScore
        let hasLexicalEvidence = targetKnown != nil
            || strongExtendedEnglishTarget
            || strongExtendedRussianTarget
            || compound != nil
            || strongScriptMismatch
        let verdict: LayoutVerdict = margin >= threshold && hasLexicalEvidence ? .switchToConverted : (sourceKnown != nil ? .keep : .undecided)
        let reason: AutoConvertDecisionReason
        if verdict == .switchToConverted {
            if compound != nil && targetKnown == nil { reason = .compound }
            else if evidence.contains(.phraseContext) { reason = .phraseContext }
            else if targetKnown != nil || strongExtendedEnglishTarget || strongExtendedRussianTarget {
                reason = converted.count <= 3 ? .frequentShort : .frequentWord
            }
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

    private static func isPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
    }
}
