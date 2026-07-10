import Foundation

public enum AnonymousUsageEvent: String, Codable, Sendable {
    case autoConverted
    case autoKept
    case autoUndecided
    case transactionFailed
    case manualConverted
    case correctionAccepted
    case correctionUndone
    case v4Evaluated
}

public struct AnonymousUsageStatistics: Codable, Equatable, Sendable {
    public private(set) var schemaVersion = 1
    public private(set) var startedAt: Date
    public private(set) var counters: [String: Int]

    public init(startedAt: Date = Date(), counters: [String: Int] = [:]) {
        self.startedAt = startedAt
        self.counters = counters
    }

    public mutating func record(
        _ event: AnonymousUsageEvent,
        languagePair: String? = nil,
        reason: String? = nil,
        tokenLength: Int? = nil
    ) {
        let pair = Self.safeComponent(languagePair, fallback: "none")
        let safeReason = Self.safeComponent(reason, fallback: "none")
        let bucket = tokenLength.map(Self.lengthBucket) ?? "none"
        let key = [event.rawValue, pair, safeReason, bucket].joined(separator: "|")
        counters[key, default: 0] += 1
    }

    public var eventCount: Int { counters.values.reduce(0, +) }

    public mutating func reset(at date: Date = Date()) {
        startedAt = date
        counters.removeAll(keepingCapacity: true)
    }

    public mutating func removeCounters(in uploaded: AnonymousUsageStatistics, at date: Date = Date()) {
        for (key, count) in uploaded.counters {
            let remaining = max(0, counters[key, default: 0] - count)
            if remaining == 0 {
                counters.removeValue(forKey: key)
            } else {
                counters[key] = remaining
            }
        }
        if counters.isEmpty { startedAt = date }
    }

    private static func lengthBucket(_ length: Int) -> String {
        switch max(0, length) {
        case 0...1: return "0-1"
        case 2...3: return "2-3"
        case 4...7: return "4-7"
        case 8...15: return "8-15"
        default: return "16+"
        }
    }

    private static func safeComponent(_ value: String?, fallback: String) -> String {
        guard let value else { return fallback }
        let safe = value.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
        let result = String(String.UnicodeScalarView(safe)).prefix(32)
        return result.isEmpty ? fallback : String(result)
    }
}
