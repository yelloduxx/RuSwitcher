import Foundation

struct CorpusPair: Decodable {
    let id: String
    let en: String
    let ru: String
}

struct FeatureSchemaDocument: Codable {
    let formatVersion: Int
    let featureSchemaVersion: Int
    let featureNames: [String]
    let risks: [String]
}

struct StoredRankingExample: Codable {
    let id: String
    let category: String
    let expectedIndices: [Int]
    let expectedSwitch: Bool
    let risks: [String]
    let features: [[Float]]
    let baselineCorrect: Bool
    let baselineSwitched: Bool
}

struct GenerationSummary: Codable {
    let split: String
    let inputRecords: Int
    let sampledRecords: Int
    let examples: Int
    let skippedMissingPath: Int
    let skippedAmbiguousTarget: Int
    let skippedProtectedTarget: Int
    let categories: [String: Int]
    let expectedKeep: Int
    let expectedSwitch: Int
    let baselineCorrect: Int
    let featureSchemaVersion: Int
    let featureCount: Int
    let uniqueFeatureGroups: Int
    let conflictingFeatureGroups: Int
    let conflictingExamples: Int
    let conflictPairs: [String: Int]
}

struct MetricBucket: Codable {
    var total = 0
    var correct = 0
    var expectedSwitch = 0
    var switchedCorrectly = 0
    var falsePositives = 0
    var wrongReplacements = 0
    var safeMisses = 0
    var abstained = 0
    var baselineCorrect = 0

    var accuracy: Double { total == 0 ? 1 : Double(correct) / Double(total) }
    var recall: Double { expectedSwitch == 0 ? 1 : Double(switchedCorrectly) / Double(expectedSwitch) }
    var falsePositiveRate: Double {
        let clean = total - expectedSwitch
        return clean == 0 ? 0 : Double(falsePositives) / Double(clean)
    }
}

struct EvaluationReport: Codable {
    let modelVersion: String
    let total: MetricBucket
    let byCategory: [String: MetricBucket]
    let byRisk: [String: MetricBucket]
    let rawTopOne: MetricBucket
    let rawByCategory: [String: MetricBucket]
    let rawByRisk: [String: MetricBucket]
    let cleanFalsePositiveUpper95: Double
    let wrongReplacementUpper95: Double
    let baselineAccuracy: Double
    let modelAccuracy: Double
    let gates: [String: Bool]
}

struct RawPrediction {
    let winner: Int
    let probabilities: [Double]
    let margin: Double
    let risk: String
}

struct CalibrationRecord {
    let logits: [Double]
    let expectedIndices: Set<Int>
    let expectedSwitch: Bool
    let risks: [String]
    let category: String
    let baselineCorrect: Bool
}

struct JSONLineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var reachedEOF = false

    init(path: String) throws {
        handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    }

    mutating func next() throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0a) {
                var line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.last == 0x0d { line.removeLast() }
                if line.isEmpty { continue }
                return line
            }
            if reachedEOF {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll(keepingCapacity: false) }
                var line = buffer
                if line.last == 0x0d { line.removeLast() }
                return line.isEmpty ? nil : line
            }
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty {
                reachedEOF = true
            } else {
                buffer.append(chunk)
            }
        }
    }

    func close() throws {
        try handle.close()
    }
}

final class AtomicJSONLineWriter {
    private let destination: URL
    private let temporary: URL
    private let handle: FileHandle
    private let encoder = JSONEncoder()
    private var finished = false

    init(path: String) throws {
        destination = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        _ = FileManager.default.createFile(atPath: temporary.path, contents: nil)
        handle = try FileHandle(forWritingTo: temporary)
    }

    func write<T: Encodable>(_ value: T) throws {
        let data = try encoder.encode(value)
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0a]))
    }

    func finish() throws {
        guard !finished else { return }
        try handle.synchronize()
        try handle.close()
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        finished = true
    }

    deinit {
        try? handle.close()
        if !finished { try? FileManager.default.removeItem(at: temporary) }
    }
}

func stableHash(_ value: String) -> UInt64 {
    value.utf8.reduce(0xcbf29ce484222325) { partial, byte in
        (partial ^ UInt64(byte)) &* 0x100000001b3
    }
}

func writeJSON<T: Encodable>(_ value: T, path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
}

func roundedFloat(_ value: Double) -> Float {
    Float((value * 1_000_000).rounded() / 1_000_000)
}

func softmax(_ logits: [Double], temperature: Double) -> [Double] {
    guard let maximum = logits.map({ $0 / temperature }).max() else { return [] }
    let values = logits.map { exp($0 / temperature - maximum) }
    let total = max(values.reduce(0, +), .leastNonzeroMagnitude)
    return values.map { $0 / total }
}

func rawPrediction(
    logits: [Double],
    risks: [String],
    temperature: Double
) -> RawPrediction {
    let probabilities = softmax(logits, temperature: temperature)
    let ordered = probabilities.indices.sorted { probabilities[$0] > probabilities[$1] }
    let winner = ordered.first ?? 0
    let runnerUp = ordered.count > 1 ? probabilities[ordered[1]] : 0
    return RawPrediction(
        winner: winner,
        probabilities: probabilities,
        margin: probabilities[winner] - runnerUp,
        risk: risks.indices.contains(winner) ? risks[winner] : "protected"
    )
}

func wilsonUpper95(successes: Int, total: Int) -> Double {
    guard total > 0 else { return 0 }
    let z = 1.959963984540054
    let n = Double(total)
    let proportion = Double(successes) / n
    let denominator = 1 + z * z / n
    let centre = proportion + z * z / (2 * n)
    let spread = z * sqrt((proportion * (1 - proportion) + z * z / (4 * n)) / n)
    return (centre + spread) / denominator
}
