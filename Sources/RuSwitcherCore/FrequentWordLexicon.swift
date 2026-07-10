import Foundation

public enum FrequentWordLexicon {
    private static let rankedWordsByLanguage: [String: [String]] = [
        "ru": [
            "и", "в", "не", "на", "я", "с", "что", "а", "по", "это", "он", "как", "к", "у",
            "же", "за", "то", "но", "мы", "вы", "из", "от", "так", "для", "о", "бы", "или", "если",
            "да", "нет", "есть", "был", "она", "они", "его", "ее", "ещё", "уже", "только", "можно",
            "нужно", "будет", "когда", "где", "кто", "почему", "чтобы", "тоже", "очень", "все", "всё",
            "мой", "моя", "ваш", "наш", "ты", "мне", "вам", "нас", "их", "до", "при", "без", "над",
            "под", "про", "между", "после", "перед", "раз", "два", "три", "день", "время", "работа",
            "текст", "слово", "язык", "план", "программа", "система", "проект", "файл", "код", "данные",
            "привет", "приветствую", "спасибо", "пожалуйста", "хорошо", "сейчас", "потом", "сегодня",
        ],
        "en": [
            "the", "be", "to", "of", "and", "a", "in", "that", "have", "i", "it", "for", "not", "on",
            "with", "he", "as", "you", "do", "at", "this", "but", "his", "by", "from", "they", "we",
            "say", "her", "she", "or", "an", "will", "my", "one", "all", "would", "there", "their", "what",
            "so", "up", "out", "if", "about", "who", "get", "which", "go", "me", "when", "make", "can",
            "like", "time", "no", "just", "him", "know", "take", "people", "into", "year", "your", "good",
            "some", "could", "them", "see", "other", "than", "then", "now", "look", "only", "come", "its",
            "over", "think", "also", "back", "after", "use", "two", "how", "our", "work", "first", "well",
            "way", "even", "new", "want", "because", "these", "give", "day", "most", "us", "hello", "plan",
        ],
    ]

    private static let wordsByLanguage: [String: Set<String>] = rankedWordsByLanguage.mapValues(Set.init)

    public static func contains(_ word: String, language: String) -> Bool {
        let lang = String(language.lowercased().prefix(2))
        let normalized = normalize(word)
        return wordsByLanguage[lang]?.contains(normalized) ?? false
    }

    /// A small bundled frequency prior. It intentionally complements, rather than
    /// replaces, the system dictionary and the character language model.
    public static func frequencyScore(_ word: String, language: String) -> Double {
        let lang = String(language.lowercased().prefix(2))
        let normalized = normalize(word)
        guard let words = rankedWordsByLanguage[lang],
              let index = words.firstIndex(of: normalized) else { return 0 }
        let rank = Double(index + 1)
        return max(1.5, 8.0 - log2(rank + 1))
    }

    public static func trainingWords(language: String) -> [String] {
        rankedWordsByLanguage[String(language.lowercased().prefix(2))] ?? []
    }

    public static func normalize(_ word: String) -> String {
        word.lowercased().precomposedStringWithCanonicalMapping
    }
}
