import Foundation
import RuSwitcherCore

struct GenerateOptions {
    let input: String
    let output: String
    let summary: String
    let split: String
    let pairModulo: UInt64
    let pairRemainder: UInt64
    let maxExamples: Int?
}

private struct Scenario {
    let id: String
    let category: String
    let typed: String
    let intended: String
    let currentLanguage: String
    let targetLanguage: String
    let context: [String]
    let expectedSwitch: Bool
}

final class ExampleGenerator {
    private let languageModel: LanguageModelStore
    private let decoder = JSONDecoder()

    init(languageModel: LanguageModelStore) {
        self.languageModel = languageModel
    }

    func run(options: GenerateOptions) throws -> GenerationSummary {
        precondition(options.pairModulo > 0)
        var reader = try JSONLineReader(path: options.input)
        let writer = try AtomicJSONLineWriter(path: options.output)
        var inputRecords = 0
        var sampledRecords = 0
        var examples = 0
        var skippedMissingPath = 0
        var skippedAmbiguousTarget = 0
        var skippedProtectedTarget = 0
        var categories: [String: Int] = [:]
        var expectedKeep = 0
        var expectedSwitch = 0
        var baselineCorrect = 0
        var featureLabels: [FeatureDigest: LabelObservation] = [:]
        var conflictingFeatureGroups: Set<FeatureDigest> = []
        var conflictingExamples = 0
        var conflictPairs: [String: Int] = [:]

        while let line = try reader.next() {
            inputRecords += 1
            let pair = try decoder.decode(CorpusPair.self, from: line)
            let hash = stableHash(pair.id)
            guard hash % options.pairModulo == options.pairRemainder else { continue }
            sampledRecords += 1

            var scenarios = scenariosForSentence(
                pair.en,
                foreignSentence: pair.ru,
                language: "en",
                pairID: pair.id,
                seed: hash
            )
            scenarios += scenariosForSentence(
                pair.ru,
                foreignSentence: pair.en,
                language: "ru",
                pairID: pair.id,
                seed: hash &+ 0x9e3779b97f4a7c15
            )
            if hash % 32 == 0, let protected = protectedScenario(pair: pair, hash: hash) {
                scenarios.append(protected)
            }

            for scenario in scenarios {
                let outcome = makeExample(scenario)
                guard case let .example(example) = outcome else {
                    if case .ambiguousTarget = outcome {
                        skippedAmbiguousTarget += 1
                    } else if case .protectedTarget = outcome {
                        skippedProtectedTarget += 1
                    } else {
                        skippedMissingPath += 1
                    }
                    continue
                }
                try writer.write(example)
                examples += 1
                categories[scenario.category, default: 0] += 1
                if scenario.expectedSwitch { expectedSwitch += 1 } else { expectedKeep += 1 }
                if example.baselineCorrect { baselineCorrect += 1 }
                let digest = FeatureDigest(example: example)
                let observation = LabelObservation(example: example)
                if let previous = featureLabels[digest], previous.label != observation.label {
                    conflictingFeatureGroups.insert(digest)
                    conflictingExamples += 1
                    let pair = "\(previous.category).\(previous.label.description)->"
                        + "\(observation.category).\(observation.label.description)"
                    conflictPairs[pair, default: 0] += 1
                } else {
                    featureLabels[digest] = observation
                }
                if let maximum = options.maxExamples, examples >= maximum { break }
            }
            if let maximum = options.maxExamples, examples >= maximum { break }
        }
        try reader.close()
        try writer.finish()

        let summary = GenerationSummary(
            split: options.split,
            inputRecords: inputRecords,
            sampledRecords: sampledRecords,
            examples: examples,
            skippedMissingPath: skippedMissingPath,
            skippedAmbiguousTarget: skippedAmbiguousTarget,
            skippedProtectedTarget: skippedProtectedTarget,
            categories: categories,
            expectedKeep: expectedKeep,
            expectedSwitch: expectedSwitch,
            baselineCorrect: baselineCorrect,
            featureSchemaVersion: LayoutRankerFeatureSchema.version,
            featureCount: LayoutRankerFeatureSchema.names.count,
            uniqueFeatureGroups: featureLabels.count,
            conflictingFeatureGroups: conflictingFeatureGroups.count,
            conflictingExamples: conflictingExamples,
            conflictPairs: conflictPairs
        )
        try writeJSON(summary, path: options.summary)
        return summary
    }

    private func scenariosForSentence(
        _ sentence: String,
        foreignSentence: String,
        language: String,
        pairID: String,
        seed: UInt64
    ) -> [Scenario] {
        let tokens = sentence.split(whereSeparator: \.isWhitespace).map(String.init)
        let eligible = tokens.indices.filter { isLexical(tokens[$0], language: language) }
        guard !eligible.isEmpty else { return [] }

        let primary = eligible[Int(seed % UInt64(eligible.count))]
        let rare = eligible.filter { index in
            let shape = SmartTokenizer.shape(of: tokens[index])
            let core = FrequentWordLexicon.normalize(shape.lexicalCore)
            return core.count <= 3
                || !shape.prefix.isEmpty
                || !shape.suffix.isEmpty
                || !isKnown(core, language: language)
        }
        let secondary = rare.isEmpty
            ? eligible[Int((seed >> 16) % UInt64(eligible.count))]
            : rare[Int((seed >> 16) % UInt64(rare.count))]
        var indices = [primary]
        if secondary != primary { indices.append(secondary) }
        let ambiguous = eligible.filter { index in
            isAmbiguousWholeLayoutTarget(tokens[index], language: language)
        }
        if !ambiguous.isEmpty {
            let index = ambiguous[Int((seed >> 32) % UInt64(ambiguous.count))]
            if !indices.contains(index) { indices.append(index) }
        }

        let target = language
        let current = language == "en" ? "ru" : "en"
        let foreignContext = Array(
            foreignSentence.split(whereSeparator: \.isWhitespace).suffix(4).map(String.init)
        )
        var result: [Scenario] = []
        for (ordinal, index) in indices.enumerated() {
            let intended = tokens[index]
            let intendedShape = SmartTokenizer.shape(of: intended)
            let context = Array(tokens[..<index].suffix(4))
            let baseID = "\(pairID)-\(language)-\(index)"
            result.append(Scenario(
                id: baseID + "-clean",
                category: "clean",
                typed: intended,
                intended: intended,
                currentLanguage: target,
                targetLanguage: current,
                context: context,
                expectedSwitch: false
            ))
            let physical = KeyMapping.convert(intended)
            if physical != intended,
               intendedShape.prefix.isEmpty,
               intendedShape.suffix.isEmpty {
                let category = isAmbiguousWholeLayoutTarget(intended, language: language)
                    ? "wrongPhysicalAmbiguous"
                    : "wrongPhysical"
                result.append(Scenario(
                    id: baseID + "-wrong",
                    category: category,
                    typed: physical,
                    intended: intended,
                    currentLanguage: current,
                    targetLanguage: target,
                    context: context,
                    expectedSwitch: true
                ))
            }
            if ordinal == 0, !foreignContext.isEmpty {
                result.append(Scenario(
                    id: baseID + "-code-switch",
                    category: "codeSwitchClean",
                    typed: intended,
                    intended: intended,
                    currentLanguage: target,
                    targetLanguage: current,
                    context: foreignContext,
                    expectedSwitch: false
                ))
            }

            let decorated = decoratedToken(
                from: intended,
                seed: seed &+ UInt64(index) &+ UInt64(ordinal * 31)
            )
            let decoratedShape = SmartTokenizer.shape(of: decorated)
            let decoratedPhysical = KeyMapping.convert(decorated)
            if decoratedPhysical != decorated {
                let category = hasCompetingPunctuationPath(
                    typed: decoratedPhysical,
                    intended: decorated
                ) ? "wrongTargetPunctuationAmbiguous" : "wrongTargetPunctuation"
                result.append(Scenario(
                    id: baseID + "-punctuation-target",
                    category: category,
                    typed: decoratedPhysical,
                    intended: decorated,
                    currentLanguage: current,
                    targetLanguage: target,
                    context: context,
                    expectedSwitch: true
                ))
            }
            let literalPunctuation = decoratedShape.prefix
                + KeyMapping.convert(decoratedShape.lexicalCore)
                + decoratedShape.suffix
            if literalPunctuation != decorated,
               literalPunctuation != decoratedPhysical {
                let category = hasCompetingPunctuationPath(
                    typed: literalPunctuation,
                    intended: decorated
                ) ? "wrongLiteralPunctuationAmbiguous" : "wrongLiteralPunctuation"
                result.append(Scenario(
                    id: baseID + "-punctuation-literal",
                    category: category,
                    typed: literalPunctuation,
                    intended: decorated,
                    currentLanguage: current,
                    targetLanguage: target,
                    context: context,
                    expectedSwitch: true
                ))
            }
        }
        return result
    }

    private func hasCompetingPunctuationPath(typed: String, intended: String) -> Bool {
        let intendedCore = FrequentWordLexicon.normalize(SmartTokenizer.lexicalCore(of: intended))
        return PhysicalKeyLattice.hypotheses(
            typed: typed,
            converted: KeyMapping.convert(typed)
        ).contains { hypothesis in
            !hypothesis.isLiteral
                && hypothesis.text != intended
                && FrequentWordLexicon.normalize(hypothesis.lexicalCore) == intendedCore
        }
    }

    private func isAmbiguousWholeLayoutTarget(_ intended: String, language: String) -> Bool {
        let shape = SmartTokenizer.shape(of: intended)
        guard shape.prefix.isEmpty, shape.suffix.isEmpty else { return false }
        let typed = KeyMapping.convert(intended)
        guard typed != intended else { return false }
        let intendedCore = FrequentWordLexicon.normalize(shape.lexicalCore)
        guard isKnown(intendedCore, language: language) else { return false }
        return PhysicalKeyLattice.hypotheses(
            typed: typed,
            converted: intended
        ).contains { hypothesis in
            guard !hypothesis.isLiteral, hypothesis.text != intended else { return false }
            let core = FrequentWordLexicon.normalize(hypothesis.lexicalCore)
            return core != intendedCore && isKnown(core, language: language)
        }
    }

    private enum ExampleOutcome {
        case example(StoredRankingExample)
        case missingPath
        case ambiguousTarget
        case protectedTarget
    }

    private func makeExample(_ scenario: Scenario) -> ExampleOutcome {
        let converted = KeyMapping.convert(scenario.typed)
        var belief = LanguageBelief.neutral
        for token in scenario.context {
            belief.observe(language: SmartTokenizer.languageHint(for: token))
        }
        let context = LayoutRankerContext(
            typed: scenario.typed,
            converted: converted,
            currentLanguage: scenario.currentLanguage,
            targetLanguage: scenario.targetLanguage,
            contextWords: scenario.context,
            languageBelief: belief,
            capsLock: scenario.typed == scenario.typed.uppercased()
                && scenario.typed != scenario.typed.lowercased(),
            physicalStrokes: PhysicalKeyStroke.aligned(typed: scenario.typed, converted: converted)
        )
        let items = LayoutRankerFeatureSchema.extract(context: context, model: languageModel)
        let expectedIndices = scenario.expectedSwitch
            ? items.indices.filter { items[$0].hypothesis.text == scenario.intended }
            : [0]
        guard !expectedIndices.isEmpty else { return .missingPath }
        // Hard safety blockers are part of the product contract. A candidate
        // that can only be reached through a protected path must not be labelled
        // as an expected automatic switch, otherwise training and evaluation
        // ask the ranker to violate the runtime policy.
        if scenario.expectedSwitch,
           expectedIndices.allSatisfy({ items[$0].risk == .protected }) {
            return .protectedTarget
        }
        if scenario.expectedSwitch,
           scenario.context.isEmpty,
           hasMultipleKnownTargetCores(items: items, expectedIndices: expectedIndices) {
            return .ambiguousTarget
        }

        let baseline = LayoutDecoder.evaluate(
            typed: scenario.typed,
            converted: converted,
            currentLanguage: scenario.currentLanguage,
            targetLanguage: scenario.targetLanguage,
            capsLock: context.capsLock,
            contextWords: scenario.context,
            languageBelief: belief,
            policy: .empty,
            physicalStrokes: context.physicalStrokes,
            model: languageModel
        )
        let baselineSwitched = baseline.decision.verdict == .switchToConverted
        let baselineCorrect = scenario.expectedSwitch
            ? baselineSwitched && baseline.decision.candidate.replacement == scenario.intended
            : !baselineSwitched
        return .example(StoredRankingExample(
            id: scenario.id,
            category: scenario.category,
            expectedIndices: expectedIndices,
            expectedSwitch: scenario.expectedSwitch,
            risks: items.map { $0.risk.rawValue },
            features: items.map { $0.features.map(roundedFloat) },
            baselineCorrect: baselineCorrect,
            baselineSwitched: baselineSwitched
        ))
    }

    private func hasMultipleKnownTargetCores(
        items: [LayoutRankerItem],
        expectedIndices: [Int]
    ) -> Bool {
        let known = items.indices.filter { index in
            guard !items[index].hypothesis.isLiteral else { return false }
            let core = FrequentWordLexicon.normalize(items[index].hypothesis.lexicalCore)
            return isKnown(core, language: SmartTokenizer.languageHint(for: core) ?? "")
        }
        let cores = Set(known.map {
            FrequentWordLexicon.normalize(items[$0].hypothesis.lexicalCore)
        })
        return cores.count > 1 && expectedIndices.contains(where: known.contains)
    }

    private func decoratedToken(from token: String, seed: UInt64) -> String {
        let original = SmartTokenizer.shape(of: token)
        if !original.prefix.isEmpty || !original.suffix.isEmpty { return token }
        let mark = Self.punctuationDistribution[Int(seed % 100)]
        switch Int((seed >> 8) % 100) {
        case 75..<85: return "\"" + original.lexicalCore + mark + "\""
        case 85..<93: return "(" + original.lexicalCore + mark + ")"
        case 93..<100: return "«" + original.lexicalCore + mark + "»"
        default: return original.lexicalCore + mark
        }
    }

    // Fixed before train/validation generation. Common terminal marks dominate;
    // rarer multi-mark and separator paths remain represented for robustness.
    private static let punctuationDistribution: [String] =
        Array(repeating: ",", count: 28)
        + Array(repeating: ".", count: 24)
        + Array(repeating: "?", count: 14)
        + Array(repeating: "!", count: 12)
        + Array(repeating: ";", count: 8)
        + Array(repeating: ":", count: 6)
        + Array(repeating: "?!", count: 4)
        + Array(repeating: "...", count: 4)

    private func protectedScenario(pair: CorpusPair, hash: UInt64) -> Scenario? {
        guard let core = pair.en.split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .map({ SmartTokenizer.lexicalCore(of: $0).lowercased() })
            .first(where: { $0.count >= 3 && $0.allSatisfy({ $0.isLetter }) }) else {
            return nil
        }
        let token: String
        switch hash % 8 {
        case 0: token = "https://\(core).example/path"
        case 1: token = "\(core)@example.com"
        case 2: token = "\(core)_value"
        case 3: token = "\(core)2.0"
        case 4: token = "@\(core)dev"
        case 5: token = "#\(core)topic"
        case 6: token = "«\(core)»"
        default: token = "(\(core))"
        }
        let foreignContext = Array(
            pair.ru.split(whereSeparator: \.isWhitespace).suffix(4).map(String.init)
        )
        return Scenario(
            id: pair.id + "-protected",
            category: "protectedClean",
            typed: token,
            intended: token,
            currentLanguage: "en",
            targetLanguage: "ru",
            context: foreignContext.isEmpty ? ["контекст"] : foreignContext,
            expectedSwitch: false
        )
    }

    private func isLexical(_ token: String, language: String) -> Bool {
        let shape = SmartTokenizer.shape(of: token)
        let core = shape.lexicalCore
        guard shape.kind == .lexical,
              1...40 ~= core.count,
              core.contains(where: \.isLetter) else { return false }
        return SmartTokenizer.languageHint(for: core).map(LanguageCode.canonical) == language
    }

    private func isKnown(_ word: String, language: String) -> Bool {
        if languageModel.wordLogProbability(word, language: language) != nil { return true }
        return language == "en"
            ? languageModel.isExtendedEnglishWord(word)
            : languageModel.isExtendedRussianWord(word)
    }
}

private struct FeatureDigest: Hashable {
    private let first: UInt64
    private let second: UInt64

    init(example: StoredRankingExample) {
        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x9e3779b97f4a7c15
        func mix(_ byte: UInt8) {
            first = (first ^ UInt64(byte)) &* 0x100000001b3
            second ^= UInt64(byte) &+ 0x9e3779b97f4a7c15 &+ (second << 6) &+ (second >> 2)
        }
        for (row, risk) in zip(example.features, example.risks) {
            mix(0xfd)
            for feature in row {
                var bits = feature.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { bytes in
                    bytes.forEach(mix)
                }
            }
            mix(0xfe)
            risk.utf8.forEach(mix)
        }
        self.first = first
        self.second = second
    }
}

private struct ExpectedLabel: Equatable {
    let switchLayout: Bool
    let indices: [Int]

    init(example: StoredRankingExample) {
        switchLayout = example.expectedSwitch
        indices = example.expectedIndices.sorted()
    }

    var description: String {
        switchLayout ? "switch-\(indices.map(String.init).joined(separator: ","))" : "keep"
    }
}

private struct LabelObservation {
    let label: ExpectedLabel
    let category: String

    init(example: StoredRankingExample) {
        label = ExpectedLabel(example: example)
        category = example.category
    }
}
