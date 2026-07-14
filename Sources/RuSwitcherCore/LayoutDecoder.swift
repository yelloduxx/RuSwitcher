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
    private static let maximumBoundaryCharacterPenalty = 1.5

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
        model: LanguageModelStore
    ) -> LayoutDecoderEvaluation {
        let generated = AutoConvertCandidateGenerator.candidates(
            typed: typed,
            converted: converted,
            strokes: physicalStrokes
        )
        if !typed.contains(where: \.isLetter) {
            let candidate = generated.first ?? AutoConvertCandidate(
                typedRaw: typed,
                convertedRaw: converted,
                convertedWord: converted,
                suffix: "",
                kind: .directWord
            )
            return fixed(candidate, verdict: .keep, reason: .blockedCodeLike, evidence: [.blockedCode])
        }
        let targetCanonical = LanguageCode.canonical(targetLanguage)
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
        let confirmedCandidates = generated.filter { candidate in
            isConfirmed(typed, candidate.replacement)
        }
        let competitiveSpellingCandidates = spellingCandidates.filter { candidate in
            guard !frequentCandidates.isEmpty else { return true }
            return isPlausibleWholeLayoutSpellingCandidate(
                candidate,
                over: frequentCandidates,
                targetLanguage: targetCanonical,
                model: model
            )
        }
        // Frequency evidence dominates spelling-only membership, which in turn
        // dominates character-only interpretations of the same physical keys.
        let candidates: [AutoConvertCandidate]
        if !confirmedCandidates.isEmpty {
            candidates = confirmedCandidates
        } else if !frequentCandidates.isEmpty {
            candidates = generated.filter {
                frequentCandidates.contains($0)
                    || competitiveSpellingCandidates.contains($0)
            }
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
        let selected = evaluations.max { lhs, rhs in
            if lhs.decision.verdict == .switchToConverted, rhs.decision.verdict != .switchToConverted { return false }
            if lhs.decision.verdict != .switchToConverted, rhs.decision.verdict == .switchToConverted { return true }
            // Reject an unmatched leading quote before phrase evidence.
            // Trailing punctuation stays below lexical evidence because `b[`
            // can legitimately mean `и[` rather than the full-key path `их`.
            let lhsLeadingStructure = leadingWrapperStructureScore(lhs.decision.candidate)
            let rhsLeadingStructure = leadingWrapperStructureScore(rhs.decision.candidate)
            if lhsLeadingStructure != rhsLeadingStructure {
                return lhsLeadingStructure < rhsLeadingStructure
            }
            if prefersWholeLayoutPath(
                lhs.decision.candidate,
                over: rhs.decision.candidate,
                targetLanguage: targetCanonical,
                model: model
            ) {
                return false
            }
            if prefersWholeLayoutPath(
                rhs.decision.candidate,
                over: lhs.decision.candidate,
                targetLanguage: targetCanonical,
                model: model
            ) {
                return true
            }
            let lhsHasPhraseEvidence = lhs.evidence.contains(.phraseContext)
            let rhsHasPhraseEvidence = rhs.evidence.contains(.phraseContext)
            if lhsHasPhraseEvidence != rhsHasPhraseEvidence {
                return !lhsHasPhraseEvidence && rhsHasPhraseEvidence
            }
            let lhsCore = punctuationComparableCore(of: lhs.decision.candidate.replacement)
            let rhsCore = punctuationComparableCore(of: rhs.decision.candidate.replacement)
            let lhsDecoration = trailingDecoration(of: lhs.decision.candidate.replacement)
            let rhsDecoration = trailingDecoration(of: rhs.decision.candidate.replacement)
            if lhsCore == rhsCore,
               max(lhsDecoration.count, rhsDecoration.count) > 1 {
                let lhsPunctuationScore = punctuationSequenceScore(lhsDecoration)
                let rhsPunctuationScore = punctuationSequenceScore(rhsDecoration)
                if lhsPunctuationScore != rhsPunctuationScore {
                    return lhsPunctuationScore < rhsPunctuationScore
                }
            }
            let lhsStructure = punctuationStructureScore(lhs.decision.candidate)
            let rhsStructure = punctuationStructureScore(rhs.decision.candidate)
            if lhsStructure != rhsStructure {
                return lhsStructure < rhsStructure
            }
            let lhsUsesTranslatedSuffix = usesTranslatedPunctuationSuffix(lhs.decision.candidate)
            let rhsUsesTranslatedSuffix = usesTranslatedPunctuationSuffix(rhs.decision.candidate)
            if lhsUsesTranslatedSuffix != rhsUsesTranslatedSuffix {
                return !lhsUsesTranslatedSuffix && rhsUsesTranslatedSuffix
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
        if shouldAbstainFromAmbiguousHybrid(
            selected,
            evaluations: evaluations,
            targetLanguage: targetCanonical,
            model: model
        ) {
            return fallback(typed: typed, converted: converted)
        }
        return selected
    }

    private static func preservedDecorationCount(_ candidate: AutoConvertCandidate) -> Int {
        candidate.prefix.count + candidate.suffix.count
    }

    private static func preservesTypedSuffix(_ candidate: AutoConvertCandidate) -> Bool {
        !candidate.suffix.isEmpty && candidate.typedRaw.hasSuffix(candidate.suffix)
    }

    /// When the same physical key is punctuation in both layouts, its target
    /// interpretation belongs to the converted token. Literal preservation is
    /// still preferred when the other layout would turn punctuation into a
    /// letter, as in `ghbdtn,` -> `привет,`.
    private static func usesTranslatedPunctuationSuffix(_ candidate: AutoConvertCandidate) -> Bool {
        guard !candidate.suffix.isEmpty,
              candidate.convertedRaw.hasSuffix(candidate.suffix),
              !candidate.typedRaw.hasSuffix(candidate.suffix) else { return false }
        let typedSuffix = Array(candidate.typedRaw.suffix(candidate.suffix.count))
        let targetSuffix = Array(candidate.suffix)
        guard typedSuffix.count == targetSuffix.count,
              typedSuffix.allSatisfy(isDecoration),
              targetSuffix.allSatisfy(isDecoration) else { return false }
        if targetSuffix.count == 1 { return true }
        let differences = typedSuffix.indices.filter { typedSuffix[$0] != targetSuffix[$0] }
        guard differences == [targetSuffix.count - 1] else { return false }
        return targetSuffix.dropLast().allSatisfy(isClosingWrapper)
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
        let currentCanonical = LanguageCode.canonical(currentLanguage)
        let targetCanonical = LanguageCode.canonical(targetLanguage)
        let targetKnownForShape = model.wordLogProbability(converted, language: targetCanonical)
        let targetExtendedEnglish = targetCanonical == "en" && model.isExtendedEnglishWord(converted)
        let targetExtendedRussian = targetCanonical == "ru" && model.isExtendedRussianWord(converted)

        if integrity != .clean {
            return fixed(baseCandidate, verdict: .keep, reason: .blockedEditing, evidence: [.blockedEditing])
        }
        if policy.neverConvert.contains(typed) || policy.neverConvert.contains(converted) {
            return fixed(baseCandidate, verdict: .keep, reason: .blockedNever, evidence: [.blockedNever])
        }
        if literal.isEmpty {
            return fixed(baseCandidate, verdict: .keep, reason: .blockedCodeLike, evidence: [.blockedCode])
        }
        if SmartTokenizer.isSocialIdentifier(candidate.typedRaw) {
            return fixed(baseCandidate, verdict: .keep, reason: .blockedCodeLike, evidence: [.blockedCode])
        }
        let wholeTargetSocialIdentifier = convertedShape.kind == .identifier
            && SmartTokenizer.isSocialIdentifier(candidate.replacement)
            && candidate.replacement == candidate.convertedRaw
            && shape.kind == .lexical
            && (targetKnownForShape != nil || targetExtendedEnglish || targetExtendedRussian)
        let sourceShapeIsProtected = shape.kind.blocksAutomaticConversion
            && !(convertedShape.kind == .lexical
                && (targetKnownForShape != nil || targetExtendedEnglish || targetExtendedRussian))
        if SmartTokenizer.isSingleUppercaseLetter(candidate.typedRaw)
            || sourceShapeIsProtected
            || (convertedShape.kind.blocksAutomaticConversion
                && !wholeTargetSocialIdentifier
                && candidate.kind != .trailingPunctuation
                && candidate.kind != .wrappingPunctuation) {
            return fixed(baseCandidate, verdict: .keep, reason: .blockedCodeLike, evidence: [.blockedCode])
        }

        let always = policy.alwaysConvert.contains(converted)
        if always {
            return fixed(baseCandidate, verdict: .switchToConverted, reason: .alwaysConvert, evidence: [.frequent])
        }
        if literal.count == 1,
           FrequentWordLexicon.contains(literal, language: currentCanonical) {
            return fixed(baseCandidate, verdict: .keep, reason: .keepCurrentWord, evidence: [.frequent])
        }
        if confirmed {
            return fixed(baseCandidate, verdict: .switchToConverted, reason: .confirmedByUser, evidence: [.confirmedByUser])
        }
        if adaptiveBias <= -10 {
            return fixed(baseCandidate, verdict: .keep, reason: .blockedLearned, evidence: [.blockedContext])
        }

        let sourceKnown = model.wordLogProbability(literal, language: currentCanonical)
        let sourceExtendedRussian = currentCanonical == "ru" && model.isExtendedRussianWord(literal)
        let targetKnown = targetKnownForShape
        let targetLexicallyKnown = targetKnown != nil || targetExtendedEnglish || targetExtendedRussian
        let characterAdvantage = model.characterLogProbability(converted, language: targetCanonical)
            - model.characterLogProbability(literal, language: currentCanonical)
        if currentCanonical == "en", targetCanonical == "ru",
           SmartTokenizer.isTitleCaseLexicalWord(candidate.typedRaw),
           SmartTokenizer.languageHint(for: literal).map(LanguageCode.canonical) == currentCanonical,
           !targetLexicallyKnown,
           characterAdvantage < model.thresholds.russianOOVNeutral {
            // Unknown proper and product names are common in mixed prose. Keep
            // them unless the opposite hypothesis has independent lexical
            // evidence. OOV layout mistakes remain eligible after confirmation.
            return fixed(
                baseCandidate,
                verdict: .keep,
                reason: .blockedContext,
                evidence: [.codeSwitch, .blockedContext]
            )
        }
        let recentLanguages = contextWords.suffix(4).compactMap(SmartTokenizer.languageHint)
            .map(LanguageCode.canonical)
        let recentEnglishCount = recentLanguages.count(where: { $0 == "en" })
        let recentRussianCount = recentLanguages.count(where: { $0 == "ru" })
        let lastTwoTokensAreEnglish = recentLanguages.suffix(2).count == 2
            && recentLanguages.suffix(2).allSatisfy({ $0 == "en" })
        let frequentEnglishTargetBeatsWeakSource = targetCanonical == "en"
            && targetKnown != nil
            && FrequentWordLexicon.contains(converted, language: targetCanonical)
            && (sourceKnown == nil || (literal.count <= 2 && lastTwoTokensAreEnglish))
            && (!sourceExtendedRussian
                || (recentEnglishCount > 0 && recentEnglishCount >= recentRussianCount))
        let directConsumesLeadingPunctuation = targetCanonical == "ru"
            && targetExtendedRussian
            && candidate.prefix.isEmpty
            && candidate.typedRaw.first.map(Self.isPunctuation) == true
        let englishSourceConfidence: EnglishSourceConfidence? = currentCanonical == "en" && targetCanonical == "ru"
            ? (directConsumesLeadingPunctuation
                ? .unlikely
                : EnglishSourceClassifier.classify(literal, model: model))
            : nil
        let strongScriptMismatch = ScriptMismatchHeuristics.hasStrongMismatch(
            typed: candidate.typedRaw,
            converted: converted,
            targetLanguage: targetLanguage
        )
        let strongExtendedEnglishTarget = currentCanonical == "ru"
            && targetExtendedEnglish
            && converted.count >= 4
            && sourceKnown == nil
            && characterAdvantage >= model.thresholds.englishTargetCharacterAdvantage
        let strongExtendedRussianTarget = currentCanonical == "en"
            && targetExtendedRussian
            && sourceKnown == nil
            && englishSourceConfidence == .unlikely
        let compound = sourceKnown == nil
            ? CompoundWordAnalyzer.analyze(converted, language: targetCanonical, model: model)
            : nil
        if literal.count >= 2,
           sourceKnown != nil || sourceExtendedRussian,
           targetKnown != nil || targetExtendedEnglish || targetExtendedRussian,
           !frequentEnglishTargetBeatsWeakSource {
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
        if literal.count >= 2, sourceExtendedRussian, !frequentEnglishTargetBeatsWeakSource {
            return fixed(
                baseCandidate,
                verdict: .keep,
                reason: .keepCurrentWord,
                evidence: [.russianSourceDictionary]
            )
        }
        if currentCanonical == "en", targetCanonical == "ru",
           sourceKnown == nil,
           targetKnown == nil,
           !targetExtendedRussian,
           compound == nil,
           characterAdvantage <= 0 {
            return fixed(
                baseCandidate,
                verdict: .keep,
                reason: .keepCurrentWord,
                evidence: [.characterModel, .codeSwitch, .blockedContext]
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
        if frequentEnglishTargetBeatsWeakSource {
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
        if sourceHint.map({ LanguageCode.canonical($0) == currentCanonical }) == true { literalScore += 1.2 }
        if targetHint.map({ LanguageCode.canonical($0) == targetCanonical }) == true { convertedScore += 1.2 }
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

        if converted.count == 1, targetCanonical == "ru" {
            let hasRecentRussianContext = recentLanguages.contains("ru")
            let lastTokenIsEnglish = recentLanguages.last == "en"
            if lastTokenIsEnglish, !hasRecentRussianContext, targetProbability < 0.55 {
                return fixed(baseCandidate, verdict: .keep, reason: .blockedContext, evidence: [.blockedContext])
            }
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

    private static func prefersWholeLayoutPath(
        _ candidate: AutoConvertCandidate,
        over alternative: AutoConvertCandidate,
        targetLanguage: String,
        model: LanguageModelStore
    ) -> Bool {
        guard candidate.replacement == candidate.convertedRaw,
              alternative.replacement != alternative.convertedRaw else { return false }
        let fullCore = FrequentWordLexicon.normalize(
            SmartTokenizer.lexicalCore(of: candidate.convertedWord)
        )
        let alternativeCore = FrequentWordLexicon.normalize(
            SmartTokenizer.lexicalCore(of: alternative.convertedWord)
        )
        guard !fullCore.isEmpty else { return false }

        let fullTier = lexicalEvidenceTier(fullCore, language: targetLanguage, model: model)
        let alternativeTier = lexicalEvidenceTier(
            alternativeCore,
            language: targetLanguage,
            model: model
        )
        guard fullTier > 0 else { return false }

        if fullCore == alternativeCore {
            if SmartTokenizer.isSocialIdentifier(candidate.replacement) { return true }
            let fullStructure = punctuationStructureScore(
                prefix: SmartTokenizer.shape(of: candidate.replacement).prefix,
                suffix: SmartTokenizer.shape(of: candidate.replacement).suffix
            )
            let alternativeStructure = punctuationStructureScore(
                prefix: SmartTokenizer.shape(of: alternative.replacement).prefix,
                suffix: SmartTokenizer.shape(of: alternative.replacement).suffix
            )
            return fullStructure > alternativeStructure
        }
        if fullTier > alternativeTier { return true }

        let differsByOneBoundaryLetter = fullCore.count == alternativeCore.count + 1
            && (fullCore.hasPrefix(alternativeCore) || fullCore.hasSuffix(alternativeCore))
        if differsByOneBoundaryLetter, fullTier == 2, alternativeTier == 3,
           fullCore.count >= 3 {
            return true
        }
        if differsByOneBoundaryLetter, fullTier == alternativeTier,
           fullCore.count == 2, alternativeCore.count == 1,
           alternative.suffix.allSatisfy({ ".,;:".contains($0) }) {
            return true
        }
        return false
    }

    /// Extended dictionaries use compact probabilistic membership. When a
    /// frequent punctuation-preserving interpretation exists, require the
    /// character model to corroborate a spelling-only whole-layout path. This
    /// keeps inflected words eligible without trusting Bloom-filter collisions
    /// such as a bracket or semicolon interpreted as an extra letter.
    private static func isPlausibleWholeLayoutSpellingCandidate(
        _ candidate: AutoConvertCandidate,
        over frequentCandidates: [AutoConvertCandidate],
        targetLanguage: String,
        model: LanguageModelStore
    ) -> Bool {
        guard candidate.replacement == candidate.convertedRaw else { return false }
        let fullCore = FrequentWordLexicon.normalize(
            SmartTokenizer.lexicalCore(of: candidate.convertedWord)
        )
        guard fullCore.count >= 3 else { return false }

        let alternatives = frequentCandidates.compactMap { alternative -> String? in
            let core = FrequentWordLexicon.normalize(
                SmartTokenizer.lexicalCore(of: alternative.convertedWord)
            )
            guard core != fullCore,
                  fullCore.count == core.count + 1,
                  fullCore.hasPrefix(core) || fullCore.hasSuffix(core) else {
                return nil
            }
            return core
        }
        guard !alternatives.isEmpty else { return false }

        let fullScore = model.characterLogProbability(fullCore, language: targetLanguage)
        let bestAlternativeScore = alternatives.map {
            model.characterLogProbability($0, language: targetLanguage)
        }.max() ?? -.infinity
        return fullScore - bestAlternativeScore >= -maximumBoundaryCharacterPenalty
    }

    private static func shouldAbstainFromAmbiguousHybrid(
        _ selected: LayoutDecoderEvaluation,
        evaluations: [LayoutDecoderEvaluation],
        targetLanguage: String,
        model: LanguageModelStore
    ) -> Bool {
        guard selected.decision.verdict == .switchToConverted,
              selected.decision.candidate.replacement
                != selected.decision.candidate.convertedRaw,
              !selected.evidence.contains(.phraseContext),
              let whole = evaluations.first(where: {
                  $0.decision.candidate.replacement == $0.decision.candidate.convertedRaw
              }),
              !whole.evidence.contains(.phraseContext) else { return false }

        let selectedCore = FrequentWordLexicon.normalize(
            SmartTokenizer.lexicalCore(of: selected.decision.candidate.convertedWord)
        )
        let wholeCore = FrequentWordLexicon.normalize(
            SmartTokenizer.lexicalCore(of: whole.decision.candidate.convertedWord)
        )
        guard selectedCore != wholeCore,
              lexicalEvidenceTier(selectedCore, language: targetLanguage, model: model) == 3,
              lexicalEvidenceTier(wholeCore, language: targetLanguage, model: model) == 3 else {
            return false
        }
        let selectedCharacterScore = model.characterLogProbability(
            selectedCore,
            language: targetLanguage
        )
        let wholeCharacterScore = model.characterLogProbability(
            wholeCore,
            language: targetLanguage
        )
        guard wholeCharacterScore - selectedCharacterScore
                >= -maximumBoundaryCharacterPenalty else {
            return false
        }
        return !prefersWholeLayoutPath(
            whole.decision.candidate,
            over: selected.decision.candidate,
            targetLanguage: targetLanguage,
            model: model
        )
    }

    private static func lexicalEvidenceTier(
        _ word: String,
        language: String,
        model: LanguageModelStore
    ) -> Int {
        if model.wordLogProbability(word, language: language) != nil
            || FrequentWordLexicon.contains(word, language: language) {
            return 3
        }
        if language == "en", model.isExtendedEnglishWord(word) { return 2 }
        if language == "ru", model.isExtendedRussianWord(word) { return 2 }
        return 0
    }

    private static func isPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains)
    }

    private static func isDecoration(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0)
                || "&^$@#".unicodeScalars.contains($0)
        }
    }

    private static func isClosingWrapper(_ character: Character) -> Bool {
        ")]}>\"'»”’".contains(character)
    }

    private static func punctuationStructureScore(_ candidate: AutoConvertCandidate) -> Int {
        punctuationStructureScore(prefix: candidate.prefix, suffix: candidate.suffix)
    }

    private static func punctuationStructureScore(prefix: String, suffix: String) -> Int {
        let openingOnly = "([{<«„“‘"
        let closingOnly = ")]}>»”’"
        if suffix.contains(where: openingOnly.contains) { return -3 }
        if prefix.contains(where: closingOnly.contains) { return -3 }

        let pairs: [(Character, Character)] = [
            ("(", ")"), ("[", "]"), ("{", "}"), ("<", ">"),
            ("«", "»"), ("„", "”"), ("“", "”"), ("‘", "’"),
            ("\"", "\""), ("'", "'"),
        ]
        if pairs.contains(where: { opening, closing in
            prefix.contains(opening) && suffix.contains(closing)
        }) {
            return 2
        }
        if prefix.contains(where: { openingOnly.contains($0) || $0 == "\"" || $0 == "'" }) {
            return -1
        }
        return 0
    }

    private static func leadingWrapperStructureScore(_ candidate: AutoConvertCandidate) -> Int {
        let pairs: [(Character, Character)] = [
            ("(", ")"), ("[", "]"), ("{", "}"), ("<", ">"),
            ("«", "»"), ("„", "”"), ("“", "”"), ("‘", "’"),
            ("\"", "\""), ("'", "'"),
        ]
        for (opening, closing) in pairs where candidate.prefix.contains(opening) {
            if !candidate.suffix.contains(closing) { return -1 }
        }
        return 0
    }

    private static func trailingDecoration(of text: String) -> String {
        String(text.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
    }

    private static func punctuationComparableCore(of text: String) -> String {
        let withoutPrefix = text.drop(while: { !$0.isLetter && !$0.isNumber })
        return FrequentWordLexicon.normalize(
            String(withoutPrefix.reversed().drop(while: { !$0.isLetter && !$0.isNumber }).reversed())
        )
    }

    /// Rank punctuation shapes independently of the word. This disambiguates
    /// physical-key paths such as `&!` -> `?!` and `///` -> `...` without
    /// forcing translation when the user already typed a natural `?!` suffix.
    private static func punctuationSequenceScore(_ suffix: String) -> Int {
        switch suffix {
        case "...": return 10
        case "?!", "!?": return 9
        case "!!", "??": return 8
        case ".", ",", "?", "!", ";", ":": return 6
        default:
            if suffix.contains("&") || suffix.contains("/") || suffix.contains("\\") {
                return -3
            }
            if suffix.contains(",!") || suffix.contains(",?") { return -2 }
            return suffix.allSatisfy { ".!?".contains($0) } ? 4 : 0
        }
    }
}
