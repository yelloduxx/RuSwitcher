import Foundation

public struct AdaptiveRule: Codable, Equatable, Sendable {
    public let original: String
    public let converted: String
    public let appBundleID: String?
    public var positiveCount: Int
    public var negativeCount: Int
    public var confirmed: Bool
    public var lastUsed: Date

    public init(
        original: String,
        converted: String,
        appBundleID: String? = nil,
        positiveCount: Int = 0,
        negativeCount: Int = 0,
        confirmed: Bool = false,
        lastUsed: Date = Date()
    ) {
        self.original = FrequentWordLexicon.normalize(original)
        self.converted = FrequentWordLexicon.normalize(converted)
        self.appBundleID = appBundleID
        self.positiveCount = positiveCount
        self.negativeCount = negativeCount
        self.confirmed = confirmed
        self.lastUsed = lastUsed
    }

    private enum CodingKeys: String, CodingKey {
        case original, converted, appBundleID, positiveCount, negativeCount, confirmed, lastUsed
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        original = FrequentWordLexicon.normalize(try values.decode(String.self, forKey: .original))
        converted = FrequentWordLexicon.normalize(try values.decode(String.self, forKey: .converted))
        appBundleID = try values.decodeIfPresent(String.self, forKey: .appBundleID)
        positiveCount = try values.decodeIfPresent(Int.self, forKey: .positiveCount) ?? 0
        negativeCount = try values.decodeIfPresent(Int.self, forKey: .negativeCount) ?? 0
        confirmed = try values.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
        lastUsed = try values.decodeIfPresent(Date.self, forKey: .lastUsed) ?? Date()
    }

    public func matches(original: String, converted: String, appBundleID: String?) -> Bool {
        self.original == FrequentWordLexicon.normalize(original)
            && self.converted == FrequentWordLexicon.normalize(converted)
            && (self.appBundleID == nil || self.appBundleID == appBundleID)
    }

    public var bias: Double {
        Double(min(positiveCount, 5) - min(negativeCount, 5)) * 2.5
    }
}

public struct AdaptiveRuleBook: Codable, Equatable, Sendable {
    public private(set) var rules: [AdaptiveRule]
    public private(set) var modelVersion: Int

    public init(rules: [AdaptiveRule] = [], modelVersion: Int = 3) {
        self.rules = rules
        self.modelVersion = modelVersion
    }

    private enum CodingKeys: String, CodingKey { case rules, modelVersion }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rules = try values.decodeIfPresent([AdaptiveRule].self, forKey: .rules) ?? []
        modelVersion = try values.decodeIfPresent(Int.self, forKey: .modelVersion) ?? 3
    }

    public func bias(original: String, converted: String, appBundleID: String?) -> Double {
        rules
            .filter { $0.matches(original: original, converted: converted, appBundleID: appBundleID) }
            .map(\.bias)
            .reduce(0, +)
    }

    public func isConfirmed(original: String, converted: String, appBundleID: String?) -> Bool {
        rules.contains {
            $0.confirmed && $0.matches(original: original, converted: converted, appBundleID: appBundleID)
        }
    }

    public mutating func recordPositive(original: String, converted: String, appBundleID: String?) {
        update(original: original, converted: converted, appBundleID: appBundleID, positive: true)
    }

    public mutating func recordNegative(original: String, converted: String, appBundleID: String?) {
        for index in rules.indices where rules[index].matches(
            original: original,
            converted: converted,
            appBundleID: appBundleID
        ) {
            rules[index].confirmed = false
        }
        update(original: original, converted: converted, appBundleID: appBundleID, positive: false)
    }

    public mutating func recordConfirmed(original: String, converted: String, appBundleID: String? = nil) {
        if let index = rules.firstIndex(where: {
            $0.matches(original: original, converted: converted, appBundleID: appBundleID)
                && $0.appBundleID == appBundleID
        }) {
            rules[index].confirmed = true
            rules[index].positiveCount += 1
            rules[index].lastUsed = Date()
        } else {
            rules.append(AdaptiveRule(
                original: original,
                converted: converted,
                appBundleID: appBundleID,
                positiveCount: 1,
                confirmed: true
            ))
        }
        prune()
    }

    private mutating func update(original: String, converted: String, appBundleID: String?, positive: Bool) {
        if let index = rules.firstIndex(where: {
            $0.matches(original: original, converted: converted, appBundleID: appBundleID)
                && $0.appBundleID == appBundleID
        }) {
            if positive {
                rules[index].positiveCount += 1
            } else {
                rules[index].negativeCount += 1
                rules[index].confirmed = false
            }
            rules[index].lastUsed = Date()
        } else {
            rules.append(AdaptiveRule(
                original: original,
                converted: converted,
                appBundleID: appBundleID,
                positiveCount: positive ? 1 : 0,
                negativeCount: positive ? 0 : 1
            ))
        }
        prune()
    }

    private mutating func prune() {
        let cutoff = Date().addingTimeInterval(-365 * 24 * 60 * 60)
        rules.removeAll { $0.lastUsed < cutoff && $0.positiveCount + $0.negativeCount <= 1 }
        if rules.count > 2_000 {
            rules.sort { $0.lastUsed > $1.lastUsed }
            rules.removeLast(rules.count - 2_000)
        }
    }
}
