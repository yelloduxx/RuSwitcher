import Foundation

public enum TokenKind: Equatable, Sendable {
    case lexical
    case url
    case email
    case numeric
    case identifier
    case mixedScript
    case empty

    public var blocksAutomaticConversion: Bool {
        switch self {
        case .url, .email, .numeric, .identifier, .mixedScript, .empty:
            return true
        case .lexical:
            return false
        }
    }
}

public struct TokenShape: Equatable, Sendable {
    public let raw: String
    public let prefix: String
    public let lexicalCore: String
    public let suffix: String
    public let kind: TokenKind

    public init(raw: String, prefix: String, lexicalCore: String, suffix: String, kind: TokenKind) {
        self.raw = raw
        self.prefix = prefix
        self.lexicalCore = lexicalCore
        self.suffix = suffix
        self.kind = kind
    }
}

public enum SmartTokenizer {
    private static let leadingPunctuation = CharacterSet(charactersIn: "([{<\"'«„“‘")
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,!?;:)]}>\"'»”’…_-—–")

    public static func shape(of raw: String) -> TokenShape {
        guard !raw.isEmpty else {
            return TokenShape(raw: raw, prefix: "", lexicalCore: "", suffix: "", kind: .empty)
        }

        let chars = Array(raw)
        var start = 0
        var end = chars.count
        while start < end, isMember(chars[start], in: leadingPunctuation) { start += 1 }
        while end > start, isMember(chars[end - 1], in: trailingPunctuation) { end -= 1 }

        let prefix = String(chars[..<start])
        let core = String(chars[start..<end])
        let suffix = String(chars[end...])
        return TokenShape(raw: raw, prefix: prefix, lexicalCore: core, suffix: suffix, kind: kind(of: raw, core: core))
    }

    public static func kind(of raw: String, core: String? = nil) -> TokenKind {
        let token = core ?? raw
        guard !token.isEmpty else { return .empty }
        let lower = raw.lowercased()
        if lower.contains("://") || lower.hasPrefix("www.") { return .url }
        if raw.contains("@"), raw.contains(".") { return .email }
        if token.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) || ".,-+/:%".unicodeScalars.contains($0) }) {
            return .numeric
        }
        if hasMixedScripts(token) { return .mixedScript }
        if looksLikeIdentifier(token) { return .identifier }
        return .lexical
    }

    public static func lexicalCore(of raw: String) -> String {
        shape(of: raw).lexicalCore
    }

    public static func languageHint(for text: String) -> String? {
        var latin = 0
        var cyrillic = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0041...0x005A, 0x0061...0x007A:
                latin += 1
            case 0x0400...0x04FF:
                cyrillic += 1
            default:
                break
            }
        }
        if latin > cyrillic { return "en" }
        if cyrillic > latin { return "ru" }
        return nil
    }

    private static func looksLikeIdentifier(_ raw: String) -> Bool {
        if raw.contains("/") || raw.contains("\\") || raw.contains("_") { return true }
        if raw.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) { return true }
        if raw.contains(".") {
            let pieces = raw.split(separator: ".", omittingEmptySubsequences: false)
            if pieces.count > 1, pieces.allSatisfy({ !$0.isEmpty }) { return true }
        }
        let letters = raw.filter(\.isLetter)
        if letters.count > 1, letters == letters.uppercased() { return true }
        for (index, char) in raw.enumerated() where index > 0 && char.isUppercase { return true }
        return false
    }

    private static func hasMixedScripts(_ text: String) -> Bool {
        var latin = false
        var cyrillic = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0041...0x005A, 0x0061...0x007A:
                latin = true
            case 0x0400...0x04FF:
                cyrillic = true
            default:
                break
            }
        }
        return latin && cyrillic
    }

    private static func isMember(_ char: Character, in set: CharacterSet) -> Bool {
        char.unicodeScalars.allSatisfy(set.contains)
    }
}
