import Foundation
import RuSwitcherCore

private enum ExpectedVerdict: String, Codable {
    case switchLayout = "switch"
    case keep
}

private struct Fixture: Codable, Sendable {
    let id: String
    let typed: String
    let currentLanguage: String
    let targetLanguage: String
    let context: [String]
    let expected: ExpectedVerdict
    let expectedReplacement: String?
}

private struct Result: Codable, Sendable {
    let id: String
    let typed: String
    let passed: Bool
    let expected: String
    let expectedReplacement: String?
    let actual: String
    let replacement: String
    let margin: Double
    let reason: String
    let latencyMicroseconds: Double
}

private struct PhraseStep: Codable, Sendable {
    let typed: String
    let manualLanguage: String?
    let separator: String
    let expected: ExpectedVerdict
    let expectedResolved: String

    init(
        _ typed: String,
        manualLanguage: String? = nil,
        separator: String = " ",
        expected: ExpectedVerdict = .keep,
        expectedResolved: String? = nil
    ) {
        self.typed = typed
        self.manualLanguage = manualLanguage
        self.separator = separator
        self.expected = expected
        self.expectedResolved = expectedResolved ?? typed
    }
}

private struct PhraseFixture: Codable, Sendable {
    let id: String
    let initialLanguage: String
    let steps: [PhraseStep]
    let expectedText: String
}

private struct PhraseStepResult: Codable, Sendable {
    let typed: String
    let sourceLanguage: String
    let expectedVerdict: String
    let actualVerdict: String
    let expectedResolved: String
    let actualResolved: String
    let passed: Bool
    let latencyMicroseconds: Double
}

private struct PhraseResult: Codable, Sendable {
    let id: String
    let passed: Bool
    let expectedText: String
    let actualText: String
    let steps: [PhraseStepResult]
}

private struct Summary: Codable {
    let engine: String
    let total: Int
    let passed: Int
    let failed: Int
    let phraseTotal: Int
    let phrasePassed: Int
    let elapsedMilliseconds: Int
    let workers: Int
    let latencyP50Microseconds: Double
    let latencyP95Microseconds: Double
    let latencyP99Microseconds: Double
    let latencyMaxMicroseconds: Double
    let failures: [Result]
    let phraseFailures: [PhraseResult]
    let phraseSamples: [PhraseResult]
}

private enum SimulatorEngine: String {
    case v3
    case v31Shadow = "v3.1-shadow"
    case v31 = "v3.1"

    var mode: V3LayoutEngineMode {
        switch self {
        case .v3: return .baseline
        case .v31Shadow: return .shadow
        case .v31: return .active
        }
    }

    var needsRanker: Bool { self != .v3 }
}

private struct Options {
    var inputPath: String?
    var phraseInputPath: String?
    var outputPath: String?
    var phraseResultsPath: String?
    var learnOutputPath: String?
    var jobs = max(1, ProcessInfo.processInfo.activeProcessorCount)
    var generatedLimit = 2_500
    var engine = SimulatorEngine.v3
}

private final class ResultStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Result?]

    init(count: Int) {
        values = Array(repeating: nil, count: count)
    }

    func set(_ result: Result, at index: Int) {
        lock.lock()
        values[index] = result
        lock.unlock()
    }

    func completed() -> [Result] {
        lock.lock()
        defer { lock.unlock() }
        return values.compactMap { $0 }
    }
}

private final class PhraseResultStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PhraseResult?]

    init(count: Int) {
        values = Array(repeating: nil, count: count)
    }

    func set(_ result: PhraseResult, at index: Int) {
        lock.lock()
        values[index] = result
        lock.unlock()
    }

    func completed() -> [PhraseResult] {
        lock.lock()
        defer { lock.unlock() }
        return values.compactMap { $0 }
    }
}

private func parseOptions() -> Options {
    var options = Options()
    var index = 1
    while index < CommandLine.arguments.count {
        let argument = CommandLine.arguments[index]
        func value() -> String {
            guard index + 1 < CommandLine.arguments.count else {
                FileHandle.standardError.write(Data("missing value for \(argument)\n".utf8))
                exit(64)
            }
            index += 1
            return CommandLine.arguments[index]
        }
        switch argument {
        case "--input": options.inputPath = value()
        case "--phrase-input": options.phraseInputPath = value()
        case "--output": options.outputPath = value()
        case "--phrase-results": options.phraseResultsPath = value()
        case "--learn-output": options.learnOutputPath = value()
        case "--jobs": options.jobs = max(1, Int(value()) ?? 1)
        case "--limit": options.generatedLimit = max(1, Int(value()) ?? 2_500)
        case "--engine":
            let raw = value()
            guard let engine = SimulatorEngine(rawValue: raw) else {
                FileHandle.standardError.write(Data("unknown engine: \(raw)\n".utf8))
                exit(64)
            }
            options.engine = engine
        case "--help":
            print("RuSwitcherSimulator [--engine v3|v3.1-shadow|v3.1] [--input words.jsonl] [--phrase-input phrases.jsonl] [--output report.json] [--phrase-results results.jsonl] [--learn-output rules.json] [--jobs N] [--limit N]")
            exit(0)
        default:
            FileHandle.standardError.write(Data("unknown argument: \(argument)\n".utf8))
            exit(64)
        }
        index += 1
    }
    return options
}

private func loadPhraseJSONL(_ path: String) throws -> [PhraseFixture] {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    return try text.split(whereSeparator: \.isNewline).enumerated().map { line, value in
        do {
            return try JSONDecoder().decode(PhraseFixture.self, from: Data(value.utf8))
        } catch {
            throw NSError(
                domain: "RuSwitcherSimulator",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "invalid phrase JSONL at line \(line + 1): \(error)"]
            )
        }
    }
}

private func writeFile(_ data: Data, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
}

private func hasKnownTypedPunctuationAlternative(
    typed: String,
    intended: String,
    targetLanguage: String,
    model: LanguageModelStore
) -> Bool {
    AutoConvertCandidateGenerator.candidates(
        typed: typed,
        converted: KeyMapping.convert(typed)
    ).contains { candidate in
        guard candidate.replacement != intended,
              !candidate.suffix.isEmpty,
              candidate.typedRaw.hasSuffix(candidate.suffix) else { return false }
        let word = FrequentWordLexicon.normalize(
            SmartTokenizer.lexicalCore(of: candidate.convertedWord)
        )
        return model.wordLogProbability(word, language: targetLanguage) != nil
            || FrequentWordLexicon.contains(word, language: targetLanguage)
            || (targetLanguage == "en" && model.isExtendedEnglishWord(word))
            || (targetLanguage == "ru" && model.isExtendedRussianWord(word))
    }
}

private func builtInPhraseFixtures(model: LanguageModelStore, limit: Int) -> [PhraseFixture] {
    var fixtures = [
        PhraseFixture(
            id: "ru-en-wrong-ru",
            initialLanguage: "ru",
            steps: [
                PhraseStep("это"),
                PhraseStep("обычный"),
                PhraseStep("use,", manualLanguage: "en"),
                PhraseStep("ghbdtn", expected: .switchLayout, expectedResolved: "привет"),
                PhraseStep("и"),
                PhraseStep("текст", separator: ""),
            ],
            expectedText: "это обычный use, привет и текст"
        ),
        PhraseFixture(
            id: "en-ru-wrong-en",
            initialLanguage: "en",
            steps: [
                PhraseStep("this"),
                PhraseStep("feature"),
                PhraseStep("привет", manualLanguage: "ru"),
                PhraseStep("руддщ", expected: .switchLayout, expectedResolved: "hello"),
                PhraseStep("world", separator: ""),
            ],
            expectedText: "this feature привет hello world"
        ),
        PhraseFixture(
            id: "protected-plan-b",
            initialLanguage: "ru",
            steps: [
                PhraseStep("сегодня"),
                PhraseStep("plan", manualLanguage: "en"),
                PhraseStep("B"),
                PhraseStep("готов", manualLanguage: "ru", separator: ""),
            ],
            expectedText: "сегодня plan B готов"
        ),
        PhraseFixture(
            id: "punctuation-and-language-return",
            initialLanguage: "en",
            steps: [
                PhraseStep("ghbdtn,", expected: .switchLayout, expectedResolved: "привет,"),
                PhraseStep("мир"),
                PhraseStep("use,", manualLanguage: "en", separator: ""),
            ],
            expectedText: "привет, мир use,"
        ),
        PhraseFixture(
            id: "unknown-compound-in-sentence",
            initialLanguage: "ru",
            steps: [
                PhraseStep("новая"),
                PhraseStep("cegthcgbyf", manualLanguage: "en", expected: .switchLayout, expectedResolved: "суперспина"),
                PhraseStep("работает", separator: ""),
            ],
            expectedText: "новая суперспина работает"
        ),
        PhraseFixture(
            id: "long-layout-letter-and-english",
            initialLanguage: "en",
            steps: [
                PhraseStep("htdjk.wbz", expected: .switchLayout, expectedResolved: "революция"),
                PhraseStep("началась"),
                PhraseStep("online", manualLanguage: "en", separator: ""),
            ],
            expectedText: "революция началась online"
        ),
        PhraseFixture(
            id: "both-known-english-here",
            initialLanguage: "en",
            steps: [
                PhraseStep("put"),
                PhraseStep("it"),
                PhraseStep("here", separator: ""),
            ],
            expectedText: "put it here"
        ),
        PhraseFixture(
            id: "both-known-russian-hand",
            initialLanguage: "ru",
            steps: [
                PhraseStep("подними"),
                PhraseStep(
                    "here",
                    manualLanguage: "en",
                    separator: "",
                    expected: .keep,
                    expectedResolved: "here"
                ),
            ],
            expectedText: "подними here"
        ),
        PhraseFixture(
            id: "both-known-ambiguous-abstain",
            initialLanguage: "ru",
            steps: [
                PhraseStep("это"),
                PhraseStep("here", manualLanguage: "en", separator: ""),
            ],
            expectedText: "это here"
        ),
        PhraseFixture(
            id: "extended-english-inside-russian",
            initialLanguage: "ru",
            steps: [
                PhraseStep("обсудим"),
                PhraseStep("codex", manualLanguage: "en"),
                PhraseStep("и", manualLanguage: "ru"),
                PhraseStep("cyst", manualLanguage: "en", separator: ""),
            ],
            expectedText: "обсудим codex и cyst"
        ),
        PhraseFixture(
            id: "unknown-russian-words-in-sentence",
            initialLanguage: "ru",
            steps: [
                PhraseStep("нужно"),
                PhraseStep("ghjnthtnm", manualLanguage: "en", expected: .switchLayout, expectedResolved: "протереть"),
                PhraseStep("и"),
                PhraseStep("pflybwf", manualLanguage: "en", expected: .switchLayout, expectedResolved: "задница"),
                PhraseStep("gblh", manualLanguage: "en", separator: "", expected: .switchLayout, expectedResolved: "пидр"),
            ],
            expectedText: "нужно протереть и задница пидр"
        ),
    ]

    let generatedPerDirection = min(500, max(1, limit / 5))
    let configurations: [(source: String, target: String, targetContext: [String], sourceContext: [String])] = [
        ("en", "ru", ["это", "новый"], ["this", "new"]),
        ("ru", "en", ["this", "new"], ["это", "новый"]),
    ]
    for configuration in configurations {
        var added = 0
        for intended in model.trainingWords(language: configuration.target, limit: limit) where intended.count >= 2 {
            let mistyped = KeyMapping.convert(intended)
            let sourceCore = SmartTokenizer.lexicalCore(of: mistyped)
            guard SmartTokenizer.languageHint(for: mistyped) == configuration.source,
                  !hasKnownTypedPunctuationAlternative(
                    typed: mistyped,
                    intended: intended,
                    targetLanguage: configuration.target,
                    model: model
                  ),
                  model.wordLogProbability(
                    sourceCore,
                    language: configuration.source
                  ) == nil,
                  configuration.source != "ru"
                    || !model.isExtendedRussianWord(sourceCore),
                  configuration.source != "en"
                    || EnglishSourceClassifier.classify(sourceCore, model: model) == .unlikely
                  else { continue }
            let steps = [
                PhraseStep(configuration.targetContext[0]),
                PhraseStep(configuration.targetContext[1]),
                PhraseStep(configuration.sourceContext[0], manualLanguage: configuration.source),
                PhraseStep(configuration.sourceContext[1]),
                PhraseStep(mistyped, separator: "", expected: .switchLayout, expectedResolved: intended),
            ]
            fixtures.append(PhraseFixture(
                id: "generated-\(configuration.target)-\(added)",
                initialLanguage: configuration.target,
                steps: steps,
                expectedText: (configuration.targetContext + configuration.sourceContext + [intended]).joined(separator: " ")
            ))
            added += 1
            if added == generatedPerDirection { break }
        }
    }
    return fixtures
}

private func loadJSONL(_ path: String) throws -> [Fixture] {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    return try text.split(whereSeparator: \.isNewline).enumerated().map { line, value in
        do {
            return try JSONDecoder().decode(Fixture.self, from: Data(value.utf8))
        } catch {
            throw NSError(
                domain: "RuSwitcherSimulator",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "invalid JSONL at line \(line + 1): \(error)"]
            )
        }
    }
}

private func builtInFixtures(model: LanguageModelStore, limit: Int) -> [Fixture] {
    let regressions = [
        Fixture(id: "short-i", typed: "b", currentLanguage: "en", targetLanguage: "ru", context: ["мы"], expected: .switchLayout, expectedReplacement: "и"),
        Fixture(id: "plan-B", typed: "B", currentLanguage: "en", targetLanguage: "ru", context: ["plan"], expected: .keep, expectedReplacement: nil),
        Fixture(id: "use-comma", typed: "use,", currentLanguage: "en", targetLanguage: "ru", context: ["plan"], expected: .keep, expectedReplacement: nil),
        Fixture(id: "revolution", typed: "htdjk.wbz", currentLanguage: "en", targetLanguage: "ru", context: ["это"], expected: .switchLayout, expectedReplacement: "революция"),
        Fixture(id: "privetulki", typed: "ghbdtnekmrb", currentLanguage: "en", targetLanguage: "ru", context: ["это"], expected: .switchLayout, expectedReplacement: "приветульки"),
        Fixture(id: "superback", typed: "cegthcgbyf", currentLanguage: "en", targetLanguage: "ru", context: ["это"], expected: .switchLayout, expectedReplacement: "суперспина"),
        Fixture(id: "hello", typed: "руддщ", currentLanguage: "ru", targetLanguage: "en", context: ["this"], expected: .switchLayout, expectedReplacement: "hello"),
        Fixture(id: "reverse-comma", typed: "гыуб", currentLanguage: "ru", targetLanguage: "en", context: ["this"], expected: .switchLayout, expectedReplacement: "use,"),
        Fixture(id: "unknown-english", typed: "афиду", currentLanguage: "ru", targetLanguage: "en", context: ["this"], expected: .switchLayout, expectedReplacement: "fable"),
        Fixture(id: "keep-put-it-here", typed: "here", currentLanguage: "en", targetLanguage: "ru", context: ["put", "it"], expected: .keep, expectedReplacement: nil),
        Fixture(
            id: "switch-pick-up-hand",
            typed: "here",
            currentLanguage: "en",
            targetLanguage: "ru",
            context: ["подними"],
            expected: .keep,
            expectedReplacement: nil
        ),
        Fixture(id: "keep-ambiguous-here", typed: "here", currentLanguage: "en", targetLanguage: "ru", context: ["это"], expected: .keep, expectedReplacement: nil),
        Fixture(id: "extended-en-cyst", typed: "cyst", currentLanguage: "en", targetLanguage: "ru", context: ["это", "текст"], expected: .keep, expectedReplacement: nil),
        Fixture(id: "extended-en-juju", typed: "juju", currentLanguage: "en", targetLanguage: "ru", context: ["это", "текст"], expected: .keep, expectedReplacement: nil),
        Fixture(id: "extended-en-codex", typed: "codex", currentLanguage: "en", targetLanguage: "ru", context: ["это", "текст"], expected: .keep, expectedReplacement: nil),
        Fixture(id: "oov-ru-wipe", typed: "ghjnthtnm", currentLanguage: "en", targetLanguage: "ru", context: ["нужно"], expected: .switchLayout, expectedReplacement: "протереть"),
        Fixture(id: "oov-ru-butt", typed: "pflybwf", currentLanguage: "en", targetLanguage: "ru", context: ["болит"], expected: .switchLayout, expectedReplacement: "задница"),
        Fixture(id: "oov-ru-slur", typed: "gblh", currentLanguage: "en", targetLanguage: "ru", context: ["он"], expected: .switchLayout, expectedReplacement: "пидр"),
    ]
    var generated = regressions
    var generatedUnknownEnglish = 0
    for stem in model.trainingWords(language: "en", limit: min(limit, 1_000)) {
        for suffix in ["able", "less", "ish", "like"] {
            let intended = stem + suffix
            let mistyped = KeyMapping.convert(intended)
            let advantage = model.characterLogProbability(intended, language: "en")
                - model.characterLogProbability(mistyped, language: "ru")
            guard intended.count >= 5,
                  model.wordLogProbability(intended, language: "en") == nil,
                  model.wordLogProbability(mistyped, language: "ru") == nil,
                  advantage >= 2.2 else { continue }
            generated.append(Fixture(
                id: "generated-unknown-en-\(generatedUnknownEnglish)",
                typed: mistyped,
                currentLanguage: "ru",
                targetLanguage: "en",
                context: ["this", "text"],
                expected: .switchLayout,
                expectedReplacement: intended
            ))
            generatedUnknownEnglish += 1
            if generatedUnknownEnglish == 250 { break }
        }
        if generatedUnknownEnglish == 250 { break }
    }
    for (current, target, context) in [("en", "ru", ["это", "текст"]), ("ru", "en", ["this", "text"])] {
        for word in model.trainingWords(language: current, limit: limit) {
            generated.append(Fixture(
                id: "literal-\(current)-\(generated.count)",
                typed: word,
                currentLanguage: current,
                targetLanguage: target,
                context: context,
                expected: .keep,
                expectedReplacement: nil
            ))
        }
        for intended in model.trainingWords(language: target, limit: limit) where intended.count >= 2 {
            let mistyped = KeyMapping.convert(intended)
            guard SmartTokenizer.languageHint(for: mistyped) == current else { continue }
            guard !hasKnownTypedPunctuationAlternative(
                typed: mistyped,
                intended: intended,
                targetLanguage: target,
                model: model
            ) else { continue }
            let sourceCore = SmartTokenizer.lexicalCore(of: mistyped)
            // Two real words on the same physical keys are intrinsically ambiguous.
            // Production deliberately keeps the literal form unless the user has
            // explicitly taught that pair.
            guard model.wordLogProbability(
                sourceCore,
                language: current
            ) == nil,
                current != "ru" || !model.isExtendedRussianWord(sourceCore),
                current != "en"
                    || EnglishSourceClassifier.classify(sourceCore, model: model) == .unlikely
            else { continue }
            generated.append(Fixture(
                id: "wrong-\(current)-\(generated.count)",
                typed: mistyped,
                currentLanguage: current,
                targetLanguage: target,
                context: context,
                expected: .switchLayout,
                expectedReplacement: intended
            ))
        }
    }
    return generated
}

private struct EngineDecision {
    let decision: AutoConvertDecision
    let margin: Double
    let latencyMicroseconds: Double
}

private func evaluateEngine(
    typed: String,
    currentLanguage: String,
    targetLanguage: String,
    context: [String],
    belief: LanguageBelief,
    model: LanguageModelStore,
    ranker: LayoutRankerModel?,
    engine: SimulatorEngine
) -> EngineDecision {
    let started = DispatchTime.now().uptimeNanoseconds
    let converted = KeyMapping.convert(typed)
    let evaluation = V3LayoutEngine.evaluate(
        typed: typed,
        converted: converted,
        currentLanguage: currentLanguage,
        targetLanguage: targetLanguage,
        capsLock: typed == typed.uppercased() && typed != typed.lowercased(),
        contextWords: context,
        languageBelief: belief,
        policy: .empty,
        model: model,
        ranker: ranker,
        mode: engine.mode
    )
    return EngineDecision(
        decision: evaluation.selected.decision,
        margin: evaluation.selected.confidenceMargin,
        latencyMicroseconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000
    )
}

private func evaluate(
    _ fixture: Fixture,
    model: LanguageModelStore,
    ranker: LayoutRankerModel?,
    engine: SimulatorEngine
) -> Result {
    var belief = LanguageBelief.neutral
    let contextLanguage = fixture.context.last.flatMap(SmartTokenizer.languageHint)
    if let contextLanguage {
        belief.observe(language: contextLanguage)
        belief.observe(language: contextLanguage)
    }
    let evaluation = evaluateEngine(
        typed: fixture.typed,
        currentLanguage: fixture.currentLanguage,
        targetLanguage: fixture.targetLanguage,
        context: fixture.context,
        belief: belief,
        model: model,
        ranker: ranker,
        engine: engine
    )
    let switched = evaluation.decision.verdict == .switchToConverted
    let expectedSwitch = fixture.expected == .switchLayout
    let replacement = evaluation.decision.candidate.replacement
    let passed = switched == expectedSwitch
        && (fixture.expectedReplacement == nil || fixture.expectedReplacement == replacement)
    return Result(
        id: fixture.id,
        typed: fixture.typed,
        passed: passed,
        expected: fixture.expected.rawValue,
        expectedReplacement: fixture.expectedReplacement,
        actual: String(describing: evaluation.decision.verdict),
        replacement: replacement,
        margin: evaluation.margin,
        reason: String(describing: evaluation.decision.reason),
        latencyMicroseconds: evaluation.latencyMicroseconds
    )
}

private func evaluatePhrase(
    _ fixture: PhraseFixture,
    model: LanguageModelStore,
    ranker: LayoutRankerModel?,
    engine: SimulatorEngine
) -> PhraseResult {
    var currentLanguage = fixture.initialLanguage
    var context: [String] = []
    var belief = LanguageBelief.neutral
    var output = ""
    var stepResults: [PhraseStepResult] = []

    for step in fixture.steps {
        if let manualLanguage = step.manualLanguage { currentLanguage = manualLanguage }
        let targetLanguage = currentLanguage == "ru" ? "en" : "ru"
        let evaluation = evaluateEngine(
            typed: step.typed,
            currentLanguage: currentLanguage,
            targetLanguage: targetLanguage,
            context: context,
            belief: belief,
            model: model,
            ranker: ranker,
            engine: engine
        )
        let switched = evaluation.decision.verdict == .switchToConverted
        let resolved = switched ? evaluation.decision.candidate.replacement : step.typed
        let resolvedLanguage = switched ? targetLanguage : currentLanguage
        let expectedSwitch = step.expected == .switchLayout
        let passed = switched == expectedSwitch && resolved == step.expectedResolved
        stepResults.append(PhraseStepResult(
            typed: step.typed,
            sourceLanguage: currentLanguage,
            expectedVerdict: step.expected.rawValue,
            actualVerdict: String(describing: evaluation.decision.verdict),
            expectedResolved: step.expectedResolved,
            actualResolved: resolved,
            passed: passed,
            latencyMicroseconds: evaluation.latencyMicroseconds
        ))
        output += resolved + step.separator
        let contextToken = SmartTokenizer.lexicalCore(of: resolved)
        if !contextToken.isEmpty {
            context.append(contextToken)
            if context.count > 5 { context.removeFirst(context.count - 5) }
            belief.observe(language: resolvedLanguage, weight: switched ? 1.4 : 1.0)
        }
        if switched { currentLanguage = targetLanguage }
    }

    return PhraseResult(
        id: fixture.id,
        passed: output == fixture.expectedText && stepResults.allSatisfy(\.passed),
        expectedText: fixture.expectedText,
        actualText: output,
        steps: stepResults
    )
}

private func run() -> Never {
    let options = parseOptions()
    guard let model = LanguageModelStore.bundled else {
        FileHandle.standardError.write(Data("language model unavailable\n".utf8))
        exit(70)
    }
    let ranker = options.engine.needsRanker ? LayoutRankerModel.bundled : nil
    if options.engine.needsRanker, ranker == nil {
        FileHandle.standardError.write(Data("layout ranker unavailable\n".utf8))
        exit(70)
    }
    let fixtures: [Fixture]
    let phraseFixtures: [PhraseFixture]
    do {
        fixtures = try options.inputPath.map(loadJSONL)
            ?? builtInFixtures(model: model, limit: options.generatedLimit)
        phraseFixtures = try options.phraseInputPath.map(loadPhraseJSONL)
            ?? builtInPhraseFixtures(model: model, limit: options.generatedLimit)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(65)
    }

    let started = Date()
    let results = ResultStore(count: fixtures.count)
    let phraseResults = PhraseResultStore(count: phraseFixtures.count)
    let queue = DispatchQueue(label: "com.ruswitcher.simulator", attributes: .concurrent)
    let group = DispatchGroup()
    let semaphore = DispatchSemaphore(value: options.jobs)
    for index in fixtures.indices {
        semaphore.wait()
        group.enter()
        queue.async {
            results.set(evaluate(
                fixtures[index],
                model: model,
                ranker: ranker,
                engine: options.engine
            ), at: index)
            semaphore.signal()
            group.leave()
        }
    }
    for index in phraseFixtures.indices {
        semaphore.wait()
        group.enter()
        queue.async {
            phraseResults.set(evaluatePhrase(
                phraseFixtures[index],
                model: model,
                ranker: ranker,
                engine: options.engine
            ), at: index)
            semaphore.signal()
            group.leave()
        }
    }
    group.wait()

    let completed = results.completed()
    let failures = completed.filter { !$0.passed }
    let completedPhrases = phraseResults.completed()
    let phraseFailures = completedPhrases.filter { !$0.passed }
    let latencies = (
        completed.map(\.latencyMicroseconds)
            + completedPhrases.flatMap { $0.steps.map(\.latencyMicroseconds) }
    ).sorted()
    let summary = Summary(
        engine: options.engine.rawValue,
        total: completed.count + completedPhrases.count,
        passed: completed.count - failures.count + completedPhrases.count - phraseFailures.count,
        failed: failures.count + phraseFailures.count,
        phraseTotal: completedPhrases.count,
        phrasePassed: completedPhrases.count - phraseFailures.count,
        elapsedMilliseconds: Int(Date().timeIntervalSince(started) * 1_000),
        workers: options.jobs,
        latencyP50Microseconds: percentile(latencies, quantile: 0.50),
        latencyP95Microseconds: percentile(latencies, quantile: 0.95),
        latencyP99Microseconds: percentile(latencies, quantile: 0.99),
        latencyMaxMicroseconds: latencies.last ?? 0,
        failures: Array(failures.prefix(100)),
        phraseFailures: phraseFailures,
        phraseSamples: Array(completedPhrases.prefix(6))
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let report = try! encoder.encode(summary)
    do {
        if let outputPath = options.outputPath {
            try writeFile(report, to: outputPath)
        }
        if let phraseResultsPath = options.phraseResultsPath {
            let lines = completedPhrases.map { String(decoding: try! JSONEncoder().encode($0), as: UTF8.self) }
            try writeFile(Data((lines.joined(separator: "\n") + "\n").utf8), to: phraseResultsPath)
        }
    } catch {
        FileHandle.standardError.write(Data("unable to write report: \(error.localizedDescription)\n".utf8))
        exit(74)
    }
    FileHandle.standardOutput.write(report)
    FileHandle.standardOutput.write(Data("\n".utf8))

    if let learnOutputPath = options.learnOutputPath {
        var book = AdaptiveRuleBook()
        for (fixture, result) in zip(fixtures, completed)
            where !result.passed && fixture.expected == .switchLayout {
            book.recordConfirmed(
                original: fixture.typed,
                converted: fixture.expectedReplacement ?? KeyMapping.convert(fixture.typed)
            )
        }
        let data = try! encoder.encode(book)
        do {
            try writeFile(data, to: learnOutputPath)
        } catch {
            FileHandle.standardError.write(Data("unable to write learned rules: \(error.localizedDescription)\n".utf8))
            exit(74)
        }
    }

    exit(failures.isEmpty && phraseFailures.isEmpty ? 0 : 1)
}

private func percentile(_ sorted: [Double], quantile: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let index = Int((Double(sorted.count - 1) * quantile).rounded(.up))
    return sorted[min(sorted.count - 1, max(0, index))]
}

run()
