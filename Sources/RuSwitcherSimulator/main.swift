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
    let verdict: String
    let resolved: String
    let passed: Bool
}

private struct PhraseResult: Codable, Sendable {
    let id: String
    let passed: Bool
    let expectedText: String
    let actualText: String
    let steps: [PhraseStepResult]
}

private struct Summary: Codable {
    let total: Int
    let passed: Int
    let failed: Int
    let phraseTotal: Int
    let phrasePassed: Int
    let elapsedMilliseconds: Int
    let workers: Int
    let failures: [Result]
    let phraseFailures: [PhraseResult]
    let phraseSamples: [PhraseResult]
}

private struct Options {
    var inputPath: String?
    var phraseInputPath: String?
    var outputPath: String?
    var learnOutputPath: String?
    var jobs = max(1, ProcessInfo.processInfo.activeProcessorCount)
    var generatedLimit = 2_500
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
        case "--learn-output": options.learnOutputPath = value()
        case "--jobs": options.jobs = max(1, Int(value()) ?? 1)
        case "--limit": options.generatedLimit = max(1, Int(value()) ?? 2_500)
        case "--help":
            print("RuSwitcherSimulator [--input words.jsonl] [--phrase-input phrases.jsonl] [--output report.json] [--learn-output rules.json] [--jobs N] [--limit N]")
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
            guard SmartTokenizer.languageHint(for: mistyped) == configuration.source,
                  model.wordLogProbability(
                    SmartTokenizer.lexicalCore(of: mistyped),
                    language: configuration.source
                  ) == nil else { continue }
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
    ]
    var generated = regressions
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
            // Two real words on the same physical keys are intrinsically ambiguous.
            // Production deliberately keeps the literal form unless the user has
            // explicitly taught that pair.
            guard model.wordLogProbability(
                SmartTokenizer.lexicalCore(of: mistyped),
                language: current
            ) == nil else { continue }
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

private func evaluate(_ fixture: Fixture, model: LanguageModelStore) -> Result {
    var belief = LanguageBelief.neutral
    let contextLanguage = fixture.context.last.flatMap(SmartTokenizer.languageHint)
    if let contextLanguage {
        belief.observe(language: contextLanguage)
        belief.observe(language: contextLanguage)
    }
    let evaluation = LayoutDecoder.evaluate(
        typed: fixture.typed,
        converted: KeyMapping.convert(fixture.typed),
        currentLanguage: fixture.currentLanguage,
        targetLanguage: fixture.targetLanguage,
        capsLock: false,
        contextWords: fixture.context,
        languageBelief: belief,
        policy: .empty,
        model: model
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
        margin: evaluation.confidenceMargin,
        reason: String(describing: evaluation.decision.reason)
    )
}

private func evaluatePhrase(_ fixture: PhraseFixture, model: LanguageModelStore) -> PhraseResult {
    var currentLanguage = fixture.initialLanguage
    var context: [String] = []
    var belief = LanguageBelief.neutral
    var output = ""
    var stepResults: [PhraseStepResult] = []

    for step in fixture.steps {
        if let manualLanguage = step.manualLanguage { currentLanguage = manualLanguage }
        let targetLanguage = currentLanguage == "ru" ? "en" : "ru"
        let evaluation = LayoutDecoder.evaluate(
            typed: step.typed,
            converted: KeyMapping.convert(step.typed),
            currentLanguage: currentLanguage,
            targetLanguage: targetLanguage,
            capsLock: step.typed == step.typed.uppercased() && step.typed != step.typed.lowercased(),
            contextWords: context,
            languageBelief: belief,
            policy: .empty,
            model: model
        )
        let switched = evaluation.decision.verdict == .switchToConverted
        let resolved = switched ? evaluation.decision.candidate.replacement : step.typed
        let resolvedLanguage = switched ? targetLanguage : currentLanguage
        let expectedSwitch = step.expected == .switchLayout
        let passed = switched == expectedSwitch && resolved == step.expectedResolved
        stepResults.append(PhraseStepResult(
            typed: step.typed,
            sourceLanguage: currentLanguage,
            verdict: String(describing: evaluation.decision.verdict),
            resolved: resolved,
            passed: passed
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

    let fixtures: [Fixture]
    let phraseFixtures: [PhraseFixture]
    do {
        fixtures = try options.inputPath.map(loadJSONL) ?? builtInFixtures(model: model, limit: options.generatedLimit)
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
            results.set(evaluate(fixtures[index], model: model), at: index)
            semaphore.signal()
            group.leave()
        }
    }
    for index in phraseFixtures.indices {
        semaphore.wait()
        group.enter()
        queue.async {
            phraseResults.set(evaluatePhrase(phraseFixtures[index], model: model), at: index)
            semaphore.signal()
            group.leave()
        }
    }
    group.wait()

    let completed = results.completed()
    let failures = completed.filter { !$0.passed }
    let completedPhrases = phraseResults.completed()
    let phraseFailures = completedPhrases.filter { !$0.passed }
    let summary = Summary(
        total: completed.count + completedPhrases.count,
        passed: completed.count - failures.count + completedPhrases.count - phraseFailures.count,
        failed: failures.count + phraseFailures.count,
        phraseTotal: completedPhrases.count,
        phrasePassed: completedPhrases.count - phraseFailures.count,
        elapsedMilliseconds: Int(Date().timeIntervalSince(started) * 1_000),
        workers: options.jobs,
        failures: Array(failures.prefix(100)),
        phraseFailures: phraseFailures,
        phraseSamples: Array(completedPhrases.prefix(6))
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let report = try! encoder.encode(summary)
    if let outputPath = options.outputPath {
        try! report.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
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
        try! data.write(to: URL(fileURLWithPath: learnOutputPath), options: .atomic)
    }

    exit(failures.isEmpty && phraseFailures.isEmpty ? 0 : 1)
}

run()
