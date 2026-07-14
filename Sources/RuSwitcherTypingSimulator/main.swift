import Foundation
import RuSwitcherCore

private struct Phase: Codable, Sendable {
    let sourceLanguage: String
    let text: String
}

private struct Fixture: Codable, Sendable {
    let name: String
    let phases: [Phase]
    let expectedText: String
    let expectedTransactions: Int?
}

private enum ExpectedVerdict: String, Codable, Sendable {
    case switchLayout = "switch"
    case keep
}

private struct PhraseStep: Codable, Sendable {
    let typed: String
    let manualLanguage: String?
    let separator: String
    let expected: ExpectedVerdict
    let expectedResolved: String
}

private struct PhraseFixture: Codable, Sendable {
    let id: String
    let initialLanguage: String
    let steps: [PhraseStep]
    let expectedText: String
}

private struct TokenTrace: Codable, Sendable {
    let typedText: String
    let resolvedText: String
    let typedLength: Int
    let replacementLength: Int
    let sourceLanguage: String
    let targetLanguage: String
    let verdict: String
    let reason: String
    let backspaceCount: Int
}

private struct Report: Codable, Sendable {
    let simulator: String
    let engine: String
    let fixture: String
    let passed: Bool
    let expectedText: String
    let actualText: String
    let transactionCount: Int
    let duplicateTransactionCount: Int
    let traces: [TokenTrace]
}

private struct BatchFailure: Codable, Sendable {
    let fixture: String
    let expectedText: String
    let actualText: String
    let expectedTransactions: Int
    let actualTransactions: Int
}

private struct BatchSummary: Codable, Sendable {
    let simulator: String
    let engine: String
    let passed: Bool
    let fixtureTotal: Int
    let fixturePassed: Int
    let fixtureFailed: Int
    let tokenTotal: Int
    let expectedTransactions: Int
    let actualTransactions: Int
    let duplicateTransactionCount: Int
    let elapsedMilliseconds: Int
    let workers: Int
    let failures: [BatchFailure]
}

private enum SimulatorEngine: String {
    case v3
    case v31 = "v3.1"

    var mode: V3LayoutEngineMode { self == .v31 ? .active : .baseline }
    var needsRanker: Bool { self == .v31 }
}

private final class BatchReportStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Report?]

    init(count: Int) {
        values = Array(repeating: nil, count: count)
    }

    func set(_ report: Report, at index: Int) {
        lock.lock()
        values[index] = report
        lock.unlock()
    }

    func completed() -> [Report] {
        lock.lock()
        defer { lock.unlock() }
        return values.compactMap(\.self)
    }
}

private struct VirtualEditor {
    private(set) var text = ""

    mutating func type(_ value: String) {
        text += value
    }

    mutating func apply(_ plan: EventReplacementPlan) {
        for _ in 0..<plan.backspaceCount where !text.isEmpty {
            text.removeLast()
        }
        text += plan.insertedText
    }
}

private struct HeadlessTypingSession {
    private let model: LanguageModelStore
    private let ranker: LayoutRankerModel?
    private let engine: SimulatorEngine
    private let focus = FocusedElementIdentity(
        processID: 1,
        bundleID: "com.ruswitcher.typing-simulator",
        identifier: "virtual-editor"
    )
    private var input = InputSession()
    private var editor = VirtualEditor()
    private var gate = ConversionExecutionGate()
    private var traces: [TokenTrace] = []
    private var transactionCount = 0
    private var duplicateTransactionCount = 0

    init(model: LanguageModelStore, ranker: LayoutRankerModel?, engine: SimulatorEngine) {
        self.model = model
        self.ranker = ranker
        self.engine = engine
    }

    mutating func type(_ phase: Phase) {
        for character in phase.text {
            switch character {
            case " ":
                finishToken(boundary: .space(count: 1), sourceLanguage: phase.sourceLanguage)
            case "\n":
                finishToken(boundary: .enter, sourceLanguage: phase.sourceLanguage)
            case "\t":
                finishToken(boundary: .tab, sourceLanguage: phase.sourceLanguage)
            default:
                let value = String(character)
                editor.type(value)
                input.handle(.printable(TypedKey(
                    keyCode: keyCode(for: character, language: phase.sourceLanguage),
                    shift: character.isUppercase,
                    caps: false,
                    producedText: value,
                    sourceLayoutID: "simulated.\(phase.sourceLanguage)"
                )))
            }
        }
    }

    func report(for fixture: Fixture) -> Report {
        Report(
            simulator: "headless-physical-event-stream",
            engine: engine.rawValue,
            fixture: fixture.name,
            passed: editor.text == fixture.expectedText
                && duplicateTransactionCount == 0
                && fixture.expectedTransactions.map { $0 == transactionCount } != false,
            expectedText: fixture.expectedText,
            actualText: editor.text,
            transactionCount: transactionCount,
            duplicateTransactionCount: duplicateTransactionCount,
            traces: traces
        )
    }

    private mutating func finishToken(boundary: InputBoundary, sourceLanguage: String) {
        guard let snapshot = input.snapshot(boundary: boundary, focus: focus) else {
            editor.type(boundary.text)
            input.handle(.boundary(boundary))
            return
        }
        let typed = snapshot.producedText ?? snapshot.keys.compactMap(\.producedText).joined()
        let targetLanguage = sourceLanguage == "ru" ? "en" : "ru"
        let engineEvaluation = V3LayoutEngine.evaluate(
            typed: typed,
            converted: KeyMapping.convert(typed),
            currentLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            capsLock: snapshot.keys.contains(where: \.caps),
            contextWords: snapshot.context.map(\.text),
            languageBelief: snapshot.languageBelief,
            policy: .empty,
            model: model,
            ranker: ranker,
            mode: engine.mode
        )
        let evaluation = engineEvaluation.selected

        let replacement = evaluation.decision.candidate.replacement
        var backspaceCount = 0
        if evaluation.decision.verdict == .switchToConverted {
            let transaction = ConversionTransaction(
                original: typed,
                replacement: replacement,
                boundary: boundary,
                focus: focus,
                sourceLayoutID: snapshot.sourceLayoutID,
                targetLayoutID: "simulated.\(targetLanguage)",
                sequence: snapshot.sequence,
                editRevision: snapshot.editRevision,
                expectedOriginalSuffix: typed,
                automatic: true
            )
            if gate.isDuplicate(transaction) {
                duplicateTransactionCount += 1
            } else {
                let plan = EventReplacementPlan(
                    transaction: transaction,
                    deliveredKeyCount: snapshot.deliveredKeyCount
                )
                backspaceCount = plan.backspaceCount
                editor.apply(plan)
                gate.recordCommitted(transaction)
                transactionCount += 1
            }
            let staged = input.stageCompletion(
                resolvedText: replacement,
                language: targetLanguage,
                wasConverted: true
            )
            _ = input.confirmStagedCompletion(
                resolvedText: replacement,
                language: targetLanguage,
                wasConverted: true,
                expectedSequence: staged
            )
        } else {
            editor.type(boundary.text)
            input.complete(
                resolvedText: typed,
                language: sourceLanguage,
                wasConverted: false
            )
        }

        traces.append(TokenTrace(
            typedText: typed,
            resolvedText: evaluation.decision.verdict == .switchToConverted ? replacement : typed,
            typedLength: typed.count,
            replacementLength: replacement.count,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            verdict: String(describing: evaluation.decision.verdict),
            reason: String(describing: evaluation.decision.reason),
            backspaceCount: backspaceCount
        ))
    }

    private func keyCode(for character: Character, language: String) -> UInt16 {
        let lowered = Character(String(character).lowercased())
        let mapping = language == "ru" ? KeyMapping.keycodeToRU : KeyMapping.keycodeToEN
        return mapping.first(where: { $0.value == lowered })?.key ?? 0
    }
}

private func argument(after name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          CommandLine.arguments.indices.contains(index + 1) else { return nil }
    return CommandLine.arguments[index + 1]
}

private func normalizedEventSeparator(_ value: String) -> String {
    value == "\\t" ? "\t" : value
}

private func loadPhraseFixtures(_ path: String) throws -> [Fixture] {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    return try text.split(whereSeparator: \.isNewline).enumerated().map { line, value in
        let phrase: PhraseFixture
        do {
            phrase = try JSONDecoder().decode(PhraseFixture.self, from: Data(value.utf8))
        } catch {
            throw NSError(
                domain: "RuSwitcherTypingSimulator",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "invalid phrase JSONL at line \(line + 1)"]
            )
        }

        var currentLanguage = phrase.initialLanguage
        var phases: [Phase] = []
        phases.reserveCapacity(phrase.steps.count)
        for (index, step) in phrase.steps.enumerated() {
            let sourceLanguage = step.manualLanguage ?? currentLanguage
            var separator = normalizedEventSeparator(step.separator)
            if index == phrase.steps.count - 1, separator.isEmpty {
                // Production converts only at a boundary. A final sentinel Space
                // makes the corpus token complete without changing its semantics.
                separator = " "
            }
            phases.append(Phase(
                sourceLanguage: sourceLanguage,
                text: step.typed + separator
            ))
            if step.expected == .switchLayout {
                currentLanguage = sourceLanguage == "ru" ? "en" : "ru"
            } else {
                currentLanguage = sourceLanguage
            }
        }

        var expectedText = phrase.expectedText.replacingOccurrences(of: "\\t", with: "\t")
        if phrase.steps.last?.separator.isEmpty == true {
            expectedText += " "
        }
        return Fixture(
            name: phrase.id,
            phases: phases,
            expectedText: expectedText,
            expectedTransactions: phrase.steps.count { $0.expected == .switchLayout }
        )
    }
}

private func simulate(
    _ fixture: Fixture,
    model: LanguageModelStore,
    ranker: LayoutRankerModel?,
    engine: SimulatorEngine
) -> Report {
    var session = HeadlessTypingSession(model: model, ranker: ranker, engine: engine)
    for phase in fixture.phases {
        session.type(phase)
    }
    return session.report(for: fixture)
}

private func encoded<T: Encodable>(_ value: T, pretty: Bool = true) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    return try encoder.encode(value)
}

private func write(_ data: Data, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
}

private func runSingle(
    inputPath: String,
    model: LanguageModelStore,
    ranker: LayoutRankerModel?,
    engine: SimulatorEngine
) throws -> Never {
    let fixture = try JSONDecoder().decode(
        Fixture.self,
        from: Data(contentsOf: URL(fileURLWithPath: inputPath))
    )
    let report = simulate(fixture, model: model, ranker: ranker, engine: engine)
    let data = try encoded(report)
    if let outputPath = argument(after: "--output") { try write(data, to: outputPath) }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(report.passed ? 0 : 1)
}

private func runBatch(
    inputPath: String,
    model: LanguageModelStore,
    ranker: LayoutRankerModel?,
    engine: SimulatorEngine
) throws -> Never {
    let fixtures = try loadPhraseFixtures(inputPath)
    let workers = max(1, Int(argument(after: "--jobs") ?? "")
        ?? ProcessInfo.processInfo.activeProcessorCount)
    let started = ContinuousClock.now
    let store = BatchReportStore(count: fixtures.count)
    let queue = DispatchQueue(
        label: "com.ruswitcher.typing-simulator.batch",
        attributes: .concurrent
    )
    let group = DispatchGroup()
    let semaphore = DispatchSemaphore(value: workers)

    for index in fixtures.indices {
        semaphore.wait()
        group.enter()
        queue.async {
            store.set(simulate(
                fixtures[index],
                model: model,
                ranker: ranker,
                engine: engine
            ), at: index)
            semaphore.signal()
            group.leave()
        }
    }
    group.wait()

    let reports = store.completed()
    let failed = reports.filter { !$0.passed }
    let expectedTransactions = fixtures.compactMap(\.expectedTransactions).reduce(0, +)
    let elapsed = started.duration(to: .now)
    let elapsedMilliseconds = Int(
        Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15
    )
    let summary = BatchSummary(
        simulator: "headless-physical-event-stream",
        engine: engine.rawValue,
        passed: failed.isEmpty,
        fixtureTotal: reports.count,
        fixturePassed: reports.count - failed.count,
        fixtureFailed: failed.count,
        tokenTotal: reports.reduce(0) { $0 + $1.traces.count },
        expectedTransactions: expectedTransactions,
        actualTransactions: reports.reduce(0) { $0 + $1.transactionCount },
        duplicateTransactionCount: reports.reduce(0) { $0 + $1.duplicateTransactionCount },
        elapsedMilliseconds: elapsedMilliseconds,
        workers: workers,
        failures: Array(zip(fixtures, reports).compactMap { fixture, report in
            guard !report.passed else { return nil }
            return BatchFailure(
                fixture: fixture.name,
                expectedText: report.expectedText,
                actualText: report.actualText,
                expectedTransactions: fixture.expectedTransactions ?? 0,
                actualTransactions: report.transactionCount
            )
        }.prefix(100))
    )

    let data = try encoded(summary)
    if let outputPath = argument(after: "--output") { try write(data, to: outputPath) }
    if let resultsPath = argument(after: "--results") {
        let lines = try reports.map { String(decoding: try encoded($0, pretty: false), as: UTF8.self) }
        try write(Data((lines.joined(separator: "\n") + "\n").utf8), to: resultsPath)
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(summary.passed ? 0 : 1)
}

private func run() throws -> Never {
    guard let model = LanguageModelStore.bundled else {
        FileHandle.standardError.write(Data("V3 language model unavailable\n".utf8))
        exit(70)
    }
    let engineRaw = argument(after: "--engine") ?? "v3"
    guard let engine = SimulatorEngine(rawValue: engineRaw) else {
        FileHandle.standardError.write(Data("unknown engine: \(engineRaw)\n".utf8))
        exit(64)
    }
    let ranker: LayoutRankerModel?
    if engine.needsRanker, let path = argument(after: "--ranker-path") {
        ranker = try LayoutRankerModel(contentsOf: URL(fileURLWithPath: path))
    } else {
        ranker = engine.needsRanker ? LayoutRankerModel.bundled : nil
    }
    if engine.needsRanker, ranker == nil {
        FileHandle.standardError.write(Data("V3.1 layout ranker unavailable\n".utf8))
        exit(70)
    }
    if let inputPath = argument(after: "--input") {
        try runSingle(inputPath: inputPath, model: model, ranker: ranker, engine: engine)
    }
    if let inputPath = argument(after: "--phrase-input") {
        try runBatch(inputPath: inputPath, model: model, ranker: ranker, engine: engine)
    }
    FileHandle.standardError.write(Data(
        "usage: RuSwitcherTypingSimulator (--input fixture.json | --phrase-input phrases.jsonl) [--engine v3|v3.1] [--ranker-path model.json] [--jobs N] [--output report.json] [--results results.jsonl]\n".utf8
    ))
    exit(64)
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("typing simulator failed: \(error.localizedDescription)\n".utf8))
    exit(70)
}
