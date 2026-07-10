import Foundation

public struct LanguageModelMetadata: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let modelVersion: String
    public let source: String
    public let sourceRevision: String
    public let license: String
    public let wordCounts: [String: Int]
}

public struct LanguageModelThresholds: Codable, Equatable, Sendable {
    public let short: Double
    public let russianContext: Double
    public let neutral: Double
    public let englishContext: Double
    public let compoundBonus: Double
    public let confirmedBonus: Double
}

public enum LanguageModelError: Error, Equatable {
    case missingResource
    case invalidHeader
    case unsupportedVersion(Int)
    case invalidDirectory
    case checksumMismatch
    case missingSection(Int)
    case invalidSection(Int)
}

/// Immutable, memory-mapped model. JSON is used only inside individually
/// checksummed binary sections; runtime lookups use native dictionaries.
public final class LanguageModelStore: @unchecked Sendable {
    private enum Section: UInt16, CaseIterable {
        case metadata = 1
        case ruWords = 2
        case enWords = 3
        case ruCharacters = 4
        case enCharacters = 5
        case ruBigrams = 6
        case enBigrams = 7
        case ruTrigrams = 8
        case enTrigrams = 9
        case productive = 10
        case thresholds = 11
    }

    public static var bundledResourceURL: URL? {
        Bundle.main.url(forResource: "language-model-v1", withExtension: "bin")
            ?? Bundle.module.url(forResource: "language-model-v1", withExtension: "bin")
    }

    public static let bundled: LanguageModelStore? = {
        guard let url = bundledResourceURL else {
            return nil
        }
        return try? LanguageModelStore(contentsOf: url)
    }()

    public let metadata: LanguageModelMetadata
    public let thresholds: LanguageModelThresholds
    public let productiveRussianParts: Set<String>
    public let productiveRussianSuffixes: Set<String>

    private let words: [String: [String: Double]]
    private let characters: [String: [String: Double]]
    private let bigrams: [String: [String: Double]]
    private let trigrams: [String: [String: Double]]

    public convenience init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        try self.init(data: data)
    }

    public init(data: Data) throws {
        guard data.count >= 20,
              String(data: data.prefix(4), encoding: .ascii) == "RSLM" else {
            throw LanguageModelError.invalidHeader
        }
        let version = Int(Self.readUInt16(data, at: 4))
        guard version == 1 else { throw LanguageModelError.unsupportedVersion(version) }
        let count = Int(Self.readUInt16(data, at: 6))
        let payloadLength = Int(Self.readUInt32(data, at: 8))
        let checksum = Self.readUInt64(data, at: 12)
        let directoryEnd = 20 + count * 12
        guard count > 0, directoryEnd <= data.count, data.count - directoryEnd == payloadLength else {
            throw LanguageModelError.invalidDirectory
        }
        let payload = data[directoryEnd...]
        guard Self.fnv1a64(payload) == checksum else { throw LanguageModelError.checksumMismatch }

        var sectionData: [Section: Data] = [:]
        for index in 0..<count {
            let base = 20 + index * 12
            guard let kind = Section(rawValue: Self.readUInt16(data, at: base)) else { continue }
            let offset = Int(Self.readUInt32(data, at: base + 4))
            let length = Int(Self.readUInt32(data, at: base + 8))
            guard offset >= 0, length >= 0, offset + length <= payloadLength else {
                throw LanguageModelError.invalidDirectory
            }
            let start = directoryEnd + offset
            sectionData[kind] = data.subdata(in: start..<(start + length))
        }

        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: T.Type, section: Section) throws -> T {
            guard let value = sectionData[section] else {
                throw LanguageModelError.missingSection(Int(section.rawValue))
            }
            do { return try decoder.decode(type, from: value) }
            catch { throw LanguageModelError.invalidSection(Int(section.rawValue)) }
        }

        metadata = try decode(LanguageModelMetadata.self, section: .metadata)
        thresholds = try decode(LanguageModelThresholds.self, section: .thresholds)
        let productive: [String] = try decode([String].self, section: .productive)
        productiveRussianParts = Set(productive.filter { !$0.hasPrefix("-") })
        productiveRussianSuffixes = Set(productive.compactMap { value in
            value.hasPrefix("-") ? String(value.dropFirst()) : nil
        })
        words = [
            "ru": try decode([String: Double].self, section: .ruWords),
            "en": try decode([String: Double].self, section: .enWords),
        ]
        characters = [
            "ru": try decode([String: Double].self, section: .ruCharacters),
            "en": try decode([String: Double].self, section: .enCharacters),
        ]
        bigrams = [
            "ru": try decode([String: Double].self, section: .ruBigrams),
            "en": try decode([String: Double].self, section: .enBigrams),
        ]
        trigrams = [
            "ru": try decode([String: Double].self, section: .ruTrigrams),
            "en": try decode([String: Double].self, section: .enTrigrams),
        ]
    }

    public func contains(_ word: String, language: String) -> Bool {
        wordLogProbability(word, language: language) != nil
    }

    public func wordLogProbability(_ word: String, language: String) -> Double? {
        words[Self.canonical(language)]?[Self.normalize(word)]
    }

    /// Deterministic frequency order used by offline quality gates. The app
    /// itself never enumerates the model in the event-tap path.
    public func trainingWords(language: String, limit: Int? = nil) -> [String] {
        let ranked = (words[Self.canonical(language)] ?? [:])
            .sorted {
                if $0.value == $1.value { return $0.key < $1.key }
                return $0.value > $1.value
            }
            .map(\.key)
        guard let limit else { return ranked }
        return Array(ranked.prefix(max(0, limit)))
    }

    public func characterLogProbability(_ word: String, language: String) -> Double {
        let normalized = Self.normalize(word)
        guard !normalized.isEmpty, let model = characters[Self.canonical(language)] else { return -16 }
        let padded = Array("^" + normalized + "$")
        var total = 0.0
        var count = 0
        for size in 2...5 where padded.count >= size {
            for index in 0...(padded.count - size) {
                total += model[String(padded[index..<(index + size)])] ?? -16
                count += 1
            }
        }
        return count == 0 ? -16 : total / Double(count)
    }

    public func phraseLogProbability(context: [String], candidate: String, language: String) -> Double? {
        let lang = Self.canonical(language)
        let normalizedCandidate = Self.normalize(candidate)
        let normalizedContext = context.map(Self.normalize).filter { !$0.isEmpty }
        if normalizedContext.count >= 2 {
            let key = (Array(normalizedContext.suffix(2)) + [normalizedCandidate]).joined(separator: "\u{1f}")
            if let score = trigrams[lang]?[key] { return score }
        }
        if let previous = normalizedContext.last {
            return bigrams[lang]?[[previous, normalizedCandidate].joined(separator: "\u{1f}")]
        }
        return nil
    }

    private static func canonical(_ language: String) -> String {
        LocalLanguageModel.canonical(language)
    }

    private static func normalize(_ text: String) -> String {
        FrequentWordLexicon.normalize(text)
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << UInt32($1 * 8) }
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << UInt64($1 * 8) }
    }

    private static func fnv1a64(_ data: Data.SubSequence) -> UInt64 {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in data {
            value ^= UInt64(byte)
            value = value &* 0x100000001b3
        }
        return value
    }
}
