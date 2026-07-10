import Foundation

public enum ScriptDirection: Equatable, Sendable {
    case latinToCyrillic
    case cyrillicToLatin

    public static func dominant(in text: String, threshold: Double = 0.8) -> ScriptDirection? {
        let letters = text.filter(\.isLetter)
        guard !letters.isEmpty else { return nil }

        let latinCount = letters.filter { character in
            character.unicodeScalars.allSatisfy {
                (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value)
            }
        }.count
        let cyrillicCount = letters.filter { character in
            character.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) }
        }.count
        let total = Double(letters.count)

        if Double(latinCount) / total >= threshold { return .latinToCyrillic }
        if Double(cyrillicCount) / total >= threshold { return .cyrillicToLatin }
        return nil
    }

    public var sourceLanguage: String {
        switch self {
        case .latinToCyrillic: "en"
        case .cyrillicToLatin: "ru"
        }
    }

    public var targetLanguage: String {
        switch self {
        case .latinToCyrillic: "ru"
        case .cyrillicToLatin: "en"
        }
    }
}
