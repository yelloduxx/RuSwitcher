import Foundation

public enum ContextualLayoutDecoder {
    private static let featureCount = 12
    private static let padID: Int32 = 0
    private static let bosID: Int32 = 257
    private static let separatorID: Int32 = 258
    private static let eosID: Int32 = 259

    public static func evaluate(
        typed: String,
        converted: String,
        currentLanguage: String,
        targetLanguage: String,
        capsLock: Bool,
        context: ContextSnapshot,
        languageBelief: LanguageBelief,
        integrity: EditorIntegrity,
        policy: AutoConvertPolicy,
        adaptiveBias: (String, String) -> Double = { _, _ in 0 },
        isConfirmed: (String, String) -> Bool = { _, _ in false },
        lexicalModel: LanguageModelStore,
        scorer: ContextualLayoutScoring?,
        adapter: PersonalizationAdapter?,
        maximumLatencyMilliseconds: Double = 4
    ) -> V4Evaluation {
        let fallback = LayoutDecoder.evaluate(
            typed: typed,
            converted: converted,
            currentLanguage: currentLanguage,
            targetLanguage: targetLanguage,
            capsLock: capsLock,
            contextWords: context.text.split(whereSeparator: \.isWhitespace).map(String.init),
            languageBelief: languageBelief,
            integrity: integrity,
            policy: policy,
            adaptiveBias: adaptiveBias,
            isConfirmed: isConfirmed,
            model: lexicalModel
        )
        let hypotheses = PhysicalKeyLattice.hypotheses(typed: typed, converted: converted)
        guard let scorer, hypotheses.count > 1 else {
            return fallbackEvaluation(fallback)
        }
        if fallback.evidence.contains(.blockedNever)
            || fallback.evidence.contains(.blockedCode)
            || fallback.evidence.contains(.blockedEditing)
            || (fallback.evidence.contains(.blockedContext)
                && LocalLanguageModel.canonical(currentLanguage) == "ru"
                && LocalLanguageModel.canonical(targetLanguage) == "en") {
            return V4Evaluation(
                outcome: .keep,
                selectedIndex: 0,
                probabilities: [1],
                confidenceMargin: 1,
                evidence: fallback.evidence,
                latencyMilliseconds: 0,
                featureDelta: nil,
                fallback: fallback
            )
        }

        let current = LocalLanguageModel.canonical(currentLanguage)
        let target = LocalLanguageModel.canonical(targetLanguage)
        let literalCore = SmartTokenizer.lexicalCore(of: typed)
        let literalKnown = isLexicallyKnown(literalCore, language: current, model: lexicalModel)
        let targetKnown = hypotheses.dropFirst().contains {
            isLexicallyKnown($0.lexicalCore, language: target, model: lexicalModel)
        }
        let targetKnownLongEnoughForAmbiguity = hypotheses.dropFirst().contains {
            $0.lexicalCore.count >= 4
                && isLexicallyKnown($0.lexicalCore, language: target, model: lexicalModel)
        }

        // V4 is a conservative reranker during rollout. A confident V3 switch keeps
        // its recall, while a known literal never becomes unknown target gibberish.
        // The neural model is allowed to resolve both-known and genuinely OOV cases.
        if fallback.decision.verdict == .switchToConverted {
            return fallbackEvaluation(fallback)
        }
        if literalKnown && (!targetKnown || !targetKnownLongEnoughForAmbiguity) {
            return V4Evaluation(
                outcome: .keep,
                selectedIndex: 0,
                probabilities: [1],
                confidenceMargin: 1,
                evidence: fallback.evidence,
                latencyMilliseconds: 0,
                featureDelta: nil,
                fallback: fallback
            )
        }
        let encoded = hypotheses.map { encode(context: context.text, candidate: $0.text, limit: scorer.manifest.maximumBytes) }
        let features = hypotheses.map { hypothesis in
            featureVector(
                hypothesis: hypothesis,
                current: current,
                target: target,
                literalKnown: literalKnown,
                belief: languageBelief,
                lexicalModel: lexicalModel
            )
        }
        let paddedIDs = encoded + Array(
            repeating: Array(repeating: padID, count: scorer.manifest.maximumBytes),
            count: max(0, scorer.manifest.maximumCandidates - encoded.count)
        )
        let paddedFeatures = features + Array(
            repeating: Array(repeating: 0, count: featureCount),
            count: max(0, scorer.manifest.maximumCandidates - features.count)
        )
        guard let output = try? scorer.score(byteIDs: paddedIDs, features: paddedFeatures) else {
            return fallbackEvaluation(fallback)
        }
        guard output.latencyMilliseconds <= maximumLatencyMilliseconds else {
            return fallbackEvaluation(fallback)
        }
        var scores = Array(output.logits.prefix(hypotheses.count)).enumerated().map { index, value in
            Double(value) + hypotheses[index].channelCost
        }
        if let adapter, output.embeddings.count >= hypotheses.count,
           let literalEmbedding = output.embeddings.first {
            for index in 1..<scores.count {
                let delta = zip(output.embeddings[index], literalEmbedding).map(-)
                scores[index] += Double(adapter.score(delta))
            }
        }
        let probabilities = softmax(scores, temperature: scorer.manifest.temperature)
        let ranked = probabilities.indices.sorted { probabilities[$0] > probabilities[$1] }
        guard let best = ranked.first else { return fallbackEvaluation(fallback) }
        let second = ranked.dropFirst().first.map { probabilities[$0] } ?? 0
        let margin = probabilities[best] - second
        let selectedKnown = isLexicallyKnown(
            hypotheses[best].lexicalCore,
            language: target,
            model: lexicalModel
        )
        let bothKnown = best > 0 && literalKnown && selectedKnown
        let probabilityThreshold = bothKnown
            ? scorer.manifest.bothKnownProbability
            : scorer.manifest.minimumProbability
        let marginThreshold = bothKnown
            ? scorer.manifest.bothKnownMargin
            : scorer.manifest.minimumMargin
        let featureDelta: [Float]? = best > 0 && output.embeddings.count > best
            ? zip(output.embeddings[best], output.embeddings[0]).map(-)
            : nil

        if best == 0 {
            return V4Evaluation(
                outcome: .keep,
                selectedIndex: 0,
                probabilities: probabilities,
                confidenceMargin: margin,
                evidence: [.neuralContext] + (isCodeSwitch(context) ? [.codeSwitch] : []),
                latencyMilliseconds: output.latencyMilliseconds,
                featureDelta: nil,
                fallback: fallback
            )
        }
        if bothKnown {
            return V4Evaluation(
                outcome: .abstain,
                selectedIndex: best,
                probabilities: probabilities,
                confidenceMargin: margin,
                evidence: [.neuralContext, .abstained],
                latencyMilliseconds: output.latencyMilliseconds,
                featureDelta: featureDelta,
                fallback: fallback
            )
        }
        guard probabilities[best] >= probabilityThreshold, margin >= marginThreshold else {
            return V4Evaluation(
                outcome: .abstain,
                selectedIndex: best,
                probabilities: probabilities,
                confidenceMargin: margin,
                evidence: [.neuralContext, .abstained],
                latencyMilliseconds: output.latencyMilliseconds,
                featureDelta: featureDelta,
                fallback: fallback
            )
        }
        var evidence: [DecoderEvidence] = [.neuralContext]
        if hypotheses[best].kind == .trailingPunctuation
            || hypotheses[best].kind == .wrappingPunctuation {
            evidence.append(.punctuationPath)
        }
        if isCodeSwitch(context) { evidence.append(.codeSwitch) }
        if adapter.map({ abs($0.score(featureDelta ?? [])) > 0.01 }) == true { evidence.append(.personalized) }
        return V4Evaluation(
            outcome: .switchToHypothesis,
            selectedIndex: best,
            probabilities: probabilities,
            confidenceMargin: margin,
            evidence: evidence,
            latencyMilliseconds: output.latencyMilliseconds,
            featureDelta: featureDelta,
            fallback: fallback
        )
    }

    public static func selectedCandidate(
        from evaluation: V4Evaluation,
        typed: String,
        converted: String
    ) -> AutoConvertCandidate? {
        let hypotheses = PhysicalKeyLattice.hypotheses(typed: typed, converted: converted)
        guard hypotheses.indices.contains(evaluation.selectedIndex) else { return nil }
        return hypotheses[evaluation.selectedIndex].candidate
    }

    private static func encode(context: String, candidate: String, limit: Int) -> [Int32] {
        let candidateIDs = candidate.utf8.map { Int32($0) + 1 }
        let reserved = 3 + candidateIDs.count
        let contextIDs = context.utf8.suffix(max(0, limit - reserved)).map { Int32($0) + 1 }
        var result = [bosID] + contextIDs + [separatorID] + candidateIDs + [eosID]
        if result.count > limit { result = Array(result.suffix(limit)) }
        if result.count < limit { result += Array(repeating: padID, count: limit - result.count) }
        return result
    }

    private static func featureVector(
        hypothesis: LayoutHypothesis,
        current: String,
        target: String,
        literalKnown: Bool,
        belief: LanguageBelief,
        lexicalModel: LanguageModelStore
    ) -> [Float] {
        let targetKnown = isLexicallyKnown(hypothesis.lexicalCore, language: target, model: lexicalModel)
        let sourceCharacter = lexicalModel.characterLogProbability(hypothesis.lexicalCore, language: current)
        let targetCharacter = lexicalModel.characterLogProbability(hypothesis.lexicalCore, language: target)
        return [
            hypothesis.isLiteral ? 1 : 0,
            hypothesis.isLiteral ? 0 : 1,
            hypothesis.kind == .trailingPunctuation || hypothesis.kind == .wrappingPunctuation ? 1 : 0,
            hypothesis.kind == .layoutLetterTail ? 1 : 0,
            current == "ru" ? 1 : 0,
            target == "ru" ? 1 : 0,
            literalKnown ? 1 : 0,
            targetKnown ? 1 : 0,
            Float(max(-16, min(0, sourceCharacter)) / 16),
            Float(max(-16, min(0, targetCharacter)) / 16),
            Float(belief.probability(language: target) - belief.probability(language: current)),
            literalKnown && targetKnown ? 1 : 0,
        ]
    }

    private static func softmax(_ values: [Double], temperature: Double) -> [Double] {
        guard let maximum = values.max() else { return [] }
        let safeTemperature = max(0.05, temperature)
        let exponents = values.map { exp(($0 - maximum) / safeTemperature) }
        let total = exponents.reduce(0, +)
        return total > 0 ? exponents.map { $0 / total } : Array(repeating: 0, count: values.count)
    }

    private static func isCodeSwitch(_ context: ContextSnapshot) -> Bool {
        Set(context.tokenLanguages.compactMap { $0.map(LocalLanguageModel.canonical) }).count > 1
    }

    private static func isLexicallyKnown(
        _ word: String,
        language: String,
        model: LanguageModelStore
    ) -> Bool {
        model.wordLogProbability(word, language: language) != nil
            || (language == "en" && model.isExtendedEnglishWord(word))
            || (language == "ru" && model.isExtendedRussianWord(word))
    }

    private static func fallbackEvaluation(_ fallback: LayoutDecoderEvaluation) -> V4Evaluation {
        V4Evaluation(
            outcome: .fallbackV3,
            selectedIndex: 0,
            probabilities: [],
            confidenceMargin: fallback.confidenceMargin,
            evidence: fallback.evidence,
            latencyMilliseconds: 0,
            featureDelta: nil,
            fallback: fallback
        )
    }
}
