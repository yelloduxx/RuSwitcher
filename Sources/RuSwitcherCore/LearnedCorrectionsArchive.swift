import Foundation

public enum LearnedCorrectionsArchiveError: LocalizedError, Equatable {
    case fileTooLarge
    case invalidFormat
    case unsupportedVersion(Int)
    case tooManyRules
    case invalidRule

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "The learned-corrections file is too large."
        case .invalidFormat:
            return "This is not a RuSwitcher learned-corrections file."
        case let .unsupportedVersion(version):
            return "Learned-corrections format version \(version) is not supported."
        case .tooManyRules:
            return "The learned-corrections file contains too many rules."
        case .invalidRule:
            return "The learned-corrections file contains an invalid rule."
        }
    }
}

public struct LearnedCorrectionsArchive: Codable, Equatable, Sendable {
    public static let formatName = "RuSwitcherLearnedCorrections"
    public static let currentFormatVersion = 1
    public static let maximumFileSize = 5 * 1_024 * 1_024
    public static let maximumRuleCount = 2_000

    public let format: String
    public let formatVersion: Int
    public let exportedAt: Date
    public let modelVersion: Int
    public let rules: [AdaptiveRule]

    public init(ruleBook: AdaptiveRuleBook, exportedAt: Date = Date()) {
        format = Self.formatName
        formatVersion = Self.currentFormatVersion
        self.exportedAt = exportedAt
        modelVersion = ruleBook.modelVersion
        rules = ruleBook.rules
    }

    public var ruleBook: AdaptiveRuleBook {
        AdaptiveRuleBook(rules: rules, modelVersion: modelVersion)
    }

    public func encoded() throws -> Data {
        try Self.validate(self)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> LearnedCorrectionsArchive {
        guard data.count <= maximumFileSize else {
            throw LearnedCorrectionsArchiveError.fileTooLarge
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive: LearnedCorrectionsArchive
        do {
            archive = try decoder.decode(LearnedCorrectionsArchive.self, from: data)
        } catch let error as LearnedCorrectionsArchiveError {
            throw error
        } catch {
            throw LearnedCorrectionsArchiveError.invalidFormat
        }
        try validate(archive)
        return archive
    }

    private static func validate(_ archive: LearnedCorrectionsArchive) throws {
        guard archive.format == formatName else {
            throw LearnedCorrectionsArchiveError.invalidFormat
        }
        guard archive.formatVersion == currentFormatVersion else {
            throw LearnedCorrectionsArchiveError.unsupportedVersion(archive.formatVersion)
        }
        guard archive.rules.count <= maximumRuleCount else {
            throw LearnedCorrectionsArchiveError.tooManyRules
        }
        guard archive.rules.allSatisfy(isValid) else {
            throw LearnedCorrectionsArchiveError.invalidRule
        }
    }

    private static func isValid(_ rule: AdaptiveRule) -> Bool {
        let originals = [rule.original, rule.converted]
        guard originals.allSatisfy({
            !$0.isEmpty
                && $0.count <= 256
                && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }) else { return false }
        guard rule.positiveCount >= 0, rule.positiveCount <= 1_000_000,
              rule.negativeCount >= 0, rule.negativeCount <= 1_000_000 else { return false }
        return rule.appBundleID.map { !$0.isEmpty && $0.count <= 256 } ?? true
    }
}
