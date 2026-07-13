import Foundation

public struct AdaptiveRule: Codable, Equatable, Sendable {
    public let original: String
    public let converted: String
    public let appBundleID: String?
    public var positiveCount: Int
    public var negativeCount: Int
    public var confirmed: Bool
    public var applicationException: Bool
    public var lastUsed: Date

    public init(
        original: String,
        converted: String,
        appBundleID: String? = nil,
        positiveCount: Int = 0,
        negativeCount: Int = 0,
        confirmed: Bool = false,
        applicationException: Bool = false,
        lastUsed: Date = Date()
    ) {
        self.original = FrequentWordLexicon.normalize(original)
        self.converted = FrequentWordLexicon.normalize(converted)
        self.appBundleID = appBundleID
        self.positiveCount = positiveCount
        self.negativeCount = negativeCount
        self.confirmed = confirmed
        self.applicationException = applicationException
        self.lastUsed = lastUsed
    }

    private enum CodingKeys: String, CodingKey {
        case original, converted, appBundleID, positiveCount, negativeCount, confirmed
        case applicationException, lastUsed
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        original = FrequentWordLexicon.normalize(try values.decode(String.self, forKey: .original))
        converted = FrequentWordLexicon.normalize(try values.decode(String.self, forKey: .converted))
        appBundleID = try values.decodeIfPresent(String.self, forKey: .appBundleID)
        positiveCount = try values.decodeIfPresent(Int.self, forKey: .positiveCount) ?? 0
        negativeCount = try values.decodeIfPresent(Int.self, forKey: .negativeCount) ?? 0
        confirmed = try values.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
        applicationException = try values.decodeIfPresent(Bool.self, forKey: .applicationException) ?? false
        lastUsed = try values.decodeIfPresent(Date.self, forKey: .lastUsed) ?? Date()
    }

    public func matchesPair(original: String, converted: String) -> Bool {
        self.original == FrequentWordLexicon.normalize(original)
            && self.converted == FrequentWordLexicon.normalize(converted)
    }

    public func matches(original: String, converted: String, appBundleID: String?) -> Bool {
        matchesPair(original: original, converted: converted)
            && (self.appBundleID == nil || self.appBundleID == appBundleID)
    }

    public var bias: Double {
        Double(min(positiveCount, 5) - min(negativeCount, 5)) * 2.5
    }
}

public struct AdaptiveRuleBook: Codable, Equatable, Sendable {
    public private(set) var rules: [AdaptiveRule]
    public private(set) var modelVersion: Int

    public init(rules: [AdaptiveRule] = [], modelVersion: Int = 6) {
        self.rules = rules
        self.modelVersion = modelVersion
        migrateLegacyScopesIfNeeded()
        migrateLegacyBackspaceFeedbackIfNeeded()
    }

    private enum CodingKeys: String, CodingKey { case rules, modelVersion }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rules = try values.decodeIfPresent([AdaptiveRule].self, forKey: .rules) ?? []
        modelVersion = try values.decodeIfPresent(Int.self, forKey: .modelVersion) ?? 3
        migrateLegacyScopesIfNeeded()
        migrateLegacyBackspaceFeedbackIfNeeded()
    }

    public func bias(original: String, converted: String, appBundleID: String?) -> Double {
        if hasApplicationException(original: original, converted: converted, appBundleID: appBundleID) {
            return -12
        }
        return rules
            .filter {
                !$0.applicationException
                    && $0.matches(original: original, converted: converted, appBundleID: appBundleID)
            }
            .map(\.bias)
            .reduce(0, +)
    }

    public func isConfirmed(original: String, converted: String, appBundleID: String?) -> Bool {
        guard !hasApplicationException(
            original: original,
            converted: converted,
            appBundleID: appBundleID
        ) else { return false }
        return rules.contains {
            $0.confirmed && $0.matches(original: original, converted: converted, appBundleID: appBundleID)
        }
    }

    public func hasApplicationException(
        original: String,
        converted: String,
        appBundleID: String?
    ) -> Bool {
        guard let appBundleID else { return false }
        return rules.contains {
            $0.applicationException
                && $0.appBundleID == appBundleID
                && $0.matchesPair(original: original, converted: converted)
        }
    }

    /// Accepted corrections are portable. Application scope is reserved only for
    /// an explicit reversal of a global correction.
    public mutating func recordPositive(original: String, converted: String) {
        update(original: original, converted: converted, appBundleID: nil, positive: true)
    }

    public mutating func recordNegative(original: String, converted: String, appBundleID: String?) {
        if let appBundleID, hasGlobalConfirmation(original: original, converted: converted) {
            setApplicationException(
                original: original,
                converted: converted,
                appBundleID: appBundleID
            )
            return
        }
        if appBundleID == nil {
            for index in rules.indices where rules[index].appBundleID == nil
                && rules[index].matchesPair(original: original, converted: converted) {
                rules[index].confirmed = false
            }
        }
        update(original: original, converted: converted, appBundleID: appBundleID, positive: false)
    }

    public mutating func recordConfirmed(
        original: String,
        converted: String,
        clearingExceptionFor appBundleID: String? = nil
    ) {
        if let index = rules.firstIndex(where: {
            $0.matchesPair(original: original, converted: converted) && $0.appBundleID == nil
        }) {
            rules[index].confirmed = true
            rules[index].applicationException = false
            rules[index].positiveCount += 1
            rules[index].lastUsed = Date()
        } else {
            rules.append(AdaptiveRule(
                original: original,
                converted: converted,
                positiveCount: 1,
                confirmed: true
            ))
        }
        if let appBundleID {
            rules.removeAll {
                $0.appBundleID == appBundleID
                    && $0.matchesPair(original: original, converted: converted)
            }
        }
        modelVersion = 6
        prune()
    }

    /// A manual correction normally confirms a portable pair. When the user
    /// manually reverses an already learned global pair, keep the global rule and
    /// create an exception for this application instead.
    public mutating func recordManualCorrection(
        original: String,
        converted: String,
        appBundleID: String?
    ) {
        if let appBundleID,
           hasGlobalConfirmation(original: converted, converted: original) {
            setApplicationException(
                original: converted,
                converted: original,
                appBundleID: appBundleID
            )
            return
        }
        recordConfirmed(
            original: original,
            converted: converted,
            clearingExceptionFor: appBundleID
        )
    }

    /// Merges a portable backup without multiplying counters when the same file is
    /// imported more than once.
    public mutating func merge(_ imported: AdaptiveRuleBook) {
        for importedRule in imported.rules {
            if let index = rules.firstIndex(where: {
                $0.original == importedRule.original
                    && $0.converted == importedRule.converted
                    && $0.appBundleID == importedRule.appBundleID
            }) {
                rules[index].positiveCount = max(rules[index].positiveCount, importedRule.positiveCount)
                rules[index].negativeCount = max(rules[index].negativeCount, importedRule.negativeCount)
                rules[index].confirmed = rules[index].confirmed || importedRule.confirmed
                rules[index].applicationException = rules[index].applicationException
                    || importedRule.applicationException
                rules[index].lastUsed = max(rules[index].lastUsed, importedRule.lastUsed)
            } else {
                rules.append(importedRule)
            }
        }
        modelVersion = max(modelVersion, imported.modelVersion)
        migrateLegacyScopesIfNeeded()
        prune()
    }

    private func hasGlobalConfirmation(original: String, converted: String) -> Bool {
        rules.contains {
            $0.appBundleID == nil
                && $0.matchesPair(original: original, converted: converted)
                && $0.confirmed
        }
    }

    private mutating func setApplicationException(
        original: String,
        converted: String,
        appBundleID: String
    ) {
        if let index = rules.firstIndex(where: {
            $0.appBundleID == appBundleID
                && $0.matchesPair(original: original, converted: converted)
        }) {
            rules[index].confirmed = false
            rules[index].applicationException = true
            rules[index].negativeCount += 1
            rules[index].lastUsed = Date()
        } else {
            rules.append(AdaptiveRule(
                original: original,
                converted: converted,
                appBundleID: appBundleID,
                negativeCount: 1,
                applicationException: true
            ))
        }
        modelVersion = 6
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

    private mutating func migrateLegacyScopesIfNeeded() {
        guard modelVersion < 4 else { return }
        let legacy = rules
        var migrated = legacy.filter { $0.appBundleID == nil }

        for rule in legacy where rule.appBundleID != nil && (rule.positiveCount > 0 || rule.confirmed) {
            if let index = migrated.firstIndex(where: {
                $0.appBundleID == nil
                    && $0.original == rule.original
                    && $0.converted == rule.converted
            }) {
                migrated[index].positiveCount = max(migrated[index].positiveCount, rule.positiveCount)
                migrated[index].confirmed = migrated[index].confirmed || rule.confirmed
                migrated[index].lastUsed = max(migrated[index].lastUsed, rule.lastUsed)
            } else {
                migrated.append(AdaptiveRule(
                    original: rule.original,
                    converted: rule.converted,
                    positiveCount: rule.positiveCount,
                    confirmed: rule.confirmed,
                    lastUsed: rule.lastUsed
                ))
            }
        }

        for rule in legacy where rule.appBundleID != nil && rule.negativeCount > 0 {
            let globallyLearned = migrated.contains {
                $0.appBundleID == nil
                    && $0.original == rule.original
                    && $0.converted == rule.converted
                    && ($0.confirmed || $0.positiveCount > 0)
            }
            migrated.append(AdaptiveRule(
                original: rule.original,
                converted: rule.converted,
                appBundleID: rule.appBundleID,
                negativeCount: rule.negativeCount,
                applicationException: globallyLearned,
                lastUsed: rule.lastUsed
            ))
        }
        rules = migrated
        modelVersion = 4
    }

    /// Version 4 treated one accepted automatic correction as sufficient for a
    /// permanent application exception. In practice the first Backspace usually
    /// deleted the replayed space, so these weak exceptions caused random misses.
    /// Keep their counters as soft app-local feedback, but reserve a hard
    /// exception for pairs confirmed manually at the global scope.
    private mutating func migrateLegacyBackspaceFeedbackIfNeeded() {
        guard modelVersion < 6 else { return }
        let confirmedGlobalPairs = Set(rules.compactMap { rule -> String? in
            guard rule.appBundleID == nil, rule.confirmed else { return nil }
            return "\(rule.original)\u{1f}\(rule.converted)"
        })
        rules.removeAll { rule in
            guard rule.appBundleID != nil else { return false }
            let pair = "\(rule.original)\u{1f}\(rule.converted)"
            return !confirmedGlobalPairs.contains(pair)
                && rule.positiveCount == 0
                && rule.negativeCount > 0
        }
        modelVersion = 6
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
