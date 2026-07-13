import Foundation

public enum LanguageCode {
    public static func canonical(_ language: String) -> String {
        let prefix = String(language.lowercased().prefix(2))
        switch prefix {
        case "uk", "be", "bg": return "ru"
        case "de", "fr", "es", "pt", "pl": return "en"
        default: return prefix
        }
    }
}
