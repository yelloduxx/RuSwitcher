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

private struct Summary: Codable {
    let total: Int
    let passed: Int
    let failed: Int
    let elapsedMilliseconds: Int
    let workers: Int
    let failures: [Result]
}

private struct Options {
    var inputPath: String?
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
        case "--output": options.outputPath = value()
        case "--learn-output": options.learnOutputPath = value()
        case "--jobs": options.jobs = max(1, Int(value()) ?? 1)
        case "--limit": options.generatedLimit = max(1, Int(value()) ?? 2_500)
        case "--help":
            print("RuSwitcherSimulator [--input fixtures.jsonl] [--output report.json] [--learn-output rules.json] [--jobs N] [--limit N]")
            exit(0)
        default:
            FileHandle.standardError.write(Data("unknown argument: \(argument)\n".utf8))
            exit(64)
        }
        index += 1
    }
    return options
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

private func run() -> Never {
    let options = parseOptions()
    guard let model = LanguageModelStore.bundled else {
        FileHandle.standardError.write(Data("language model unavailable\n".utf8))
        exit(70)
    }

    let fixtures: [Fixture]
    do {
        fixtures = try options.inputPath.map(loadJSONL) ?? builtInFixtures(model: model, limit: options.generatedLimit)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(65)
    }

    let started = Date()
    let results = ResultStore(count: fixtures.count)
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
    group.wait()

    let completed = results.completed()
    let failures = completed.filter { !$0.passed }
    let summary = Summary(
        total: completed.count,
        passed: completed.count - failures.count,
        failed: failures.count,
        elapsedMilliseconds: Int(Date().timeIntervalSince(started) * 1_000),
        workers: options.jobs,
        failures: Array(failures.prefix(100))
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

    exit(failures.isEmpty ? 0 : 1)
}

run()
