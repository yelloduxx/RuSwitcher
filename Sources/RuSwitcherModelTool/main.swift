import Foundation
import RuSwitcherCore

private struct Arguments {
    let command: String
    let values: [String: String]
    let flags: Set<String>

    init() {
        let raw = Array(CommandLine.arguments.dropFirst())
        command = raw.first ?? "help"
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var index = 1
        while index < raw.count {
            let key = raw[index]
            guard key.hasPrefix("--") else {
                index += 1
                continue
            }
            if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                values[key] = raw[index + 1]
                index += 2
            } else {
                flags.insert(key)
                index += 1
            }
        }
        self.values = values
        self.flags = flags
    }

    func required(_ key: String) throws -> String {
        guard let value = values[key] else {
            throw NSError(domain: "RuSwitcherModelTool", code: 64, userInfo: [
                NSLocalizedDescriptionKey: "missing required option \(key)"
            ])
        }
        return value
    }

    func integer(_ key: String, default fallback: Int) -> Int {
        values[key].flatMap(Int.init) ?? fallback
    }

    func double(_ key: String, default fallback: Double) -> Double {
        values[key].flatMap(Double.init) ?? fallback
    }
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

private func usage() {
    print("""
    RuSwitcherModelTool generate --input corpus.jsonl --output examples.jsonl --summary summary.json --split train [--pair-modulo 32] [--pair-remainder 0]
    RuSwitcherModelTool schema --output feature-schema.json
    RuSwitcherModelTool train --train train.jsonl --validation validation.jsonl --output layout-ranker-v1.json --report report.json --manifest-sha256 HASH [--epochs 5] [--enforce-validation-gates]
    RuSwitcherModelTool recalibrate --validation validation.jsonl --model layout-ranker-v1.json --output layout-ranker-v1.json --report report.json
    RuSwitcherModelTool evaluate --examples test.jsonl --model layout-ranker-v1.json --output report.json [--enforce-gates]
    """)
}

do {
    let arguments = Arguments()
    guard let languageModel = LanguageModelStore.bundled else {
        throw LanguageModelError.missingResource
    }
    switch arguments.command {
    case "schema":
        let schema = FeatureSchemaDocument(
            formatVersion: 1,
            featureSchemaVersion: LayoutRankerFeatureSchema.version,
            featureNames: LayoutRankerFeatureSchema.names,
            risks: LayoutRankerRisk.allCases.map(\.rawValue)
        )
        try writeJSON(schema, path: try arguments.required("--output"))
        try printJSON(schema)

    case "generate":
        let modulo = max(1, arguments.integer("--pair-modulo", default: 32))
        let remainder = arguments.integer("--pair-remainder", default: 0)
        guard remainder >= 0, remainder < modulo else {
            throw NSError(domain: "RuSwitcherModelTool", code: 64, userInfo: [
                NSLocalizedDescriptionKey: "pair remainder must be inside modulo"
            ])
        }
        let options = GenerateOptions(
            input: try arguments.required("--input"),
            output: try arguments.required("--output"),
            summary: try arguments.required("--summary"),
            split: arguments.values["--split"] ?? "unknown",
            pairModulo: UInt64(modulo),
            pairRemainder: UInt64(remainder),
            maxExamples: arguments.values["--max-examples"].flatMap(Int.init)
        )
        try printJSON(ExampleGenerator(languageModel: languageModel).run(options: options))

    case "train":
        let output = try arguments.required("--output")
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: output).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let options = TrainOptions(
            train: try arguments.required("--train"),
            validation: try arguments.required("--validation"),
            output: output,
            report: try arguments.required("--report"),
            manifestSHA256: try arguments.required("--manifest-sha256"),
            modelVersion: arguments.values["--model-version"] ?? "2026.07-v3.1-ranker-2",
            epochs: max(1, arguments.integer("--epochs", default: 5)),
            learningRate: arguments.double("--learning-rate", default: 0.12),
            l2: arguments.double("--l2", default: 0.000_01)
        )
        let report = try RankerTrainer().train(options: options)
        try printJSON(report)
        if arguments.flags.contains("--enforce-validation-gates"),
           report.validation.gates.values.contains(false) {
            exit(1)
        }

    case "evaluate":
        let model = try LayoutRankerModel(
            contentsOf: URL(fileURLWithPath: try arguments.required("--model"))
        )
        let report = try RankerTrainer().evaluate(
            examples: try arguments.required("--examples"),
            artifact: model.artifact,
            output: try arguments.required("--output")
        )
        try printJSON(report)
        if arguments.flags.contains("--enforce-gates"), report.gates.values.contains(false) {
            exit(1)
        }

    case "recalibrate":
        let model = try LayoutRankerModel(
            contentsOf: URL(fileURLWithPath: try arguments.required("--model"))
        )
        let report = try RankerTrainer().recalibrate(
            validation: try arguments.required("--validation"),
            artifact: model.artifact,
            outputModel: try arguments.required("--output"),
            outputReport: try arguments.required("--report")
        )
        try printJSON(report)
        if arguments.flags.contains("--enforce-gates"), report.gates.values.contains(false) {
            exit(1)
        }

    case "help", "--help", "-h":
        usage()

    default:
        usage()
        throw NSError(domain: "RuSwitcherModelTool", code: 64, userInfo: [
            NSLocalizedDescriptionKey: "unknown command \(arguments.command)"
        ])
    }
} catch {
    FileHandle.standardError.write(Data("RuSwitcherModelTool: \(error)\n".utf8))
    exit(1)
}
