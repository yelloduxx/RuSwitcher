import Foundation

public enum LocalLanguageModel {
    private static let extraTraining: [String: [String]] = [
        "ru": [
            "человек", "сказать", "говорить", "делать", "новый", "старый", "большой", "маленький",
            "русский", "английский", "сообщение", "предложение", "настройка", "раскладка", "исправление",
            "автоматический", "конвертация", "пользователь", "контекст", "редкий", "обычный", "пример",
            "результат", "вопрос", "ответ", "приветствовать", "интересный", "возможность", "информация",
        ],
        "en": [
            "person", "message", "sentence", "language", "layout", "keyboard", "automatic", "conversion",
            "context", "setting", "project", "program", "system", "result", "question", "answer", "example",
            "information", "different", "possible", "important", "should", "before", "between", "through",
            "computer", "application", "browser", "document", "selected", "change", "switch", "correct",
        ],
    ]

    private static let ngramsByLanguage: [String: Set<String>] = {
        var result: [String: Set<String>] = [:]
        for language in ["ru", "en"] {
            let words = FrequentWordLexicon.trainingWords(language: language) + (extraTraining[language] ?? [])
            var grams = Set<String>()
            for word in words {
                let padded = "^" + word.lowercased() + "$"
                let chars = Array(padded)
                for size in 2...3 where chars.count >= size {
                    for index in 0...(chars.count - size) {
                        grams.insert(String(chars[index..<(index + size)]))
                    }
                }
            }
            result[language] = grams
        }
        return result
    }()

    public static func wordScore(_ word: String, language: String) -> Double {
        let lang = canonical(language)
        let normalized = FrequentWordLexicon.normalize(word)
        guard !normalized.isEmpty else { return -4 }
        guard SmartTokenizer.languageHint(for: normalized).map({ canonical($0) == lang }) ?? true else {
            return -6
        }

        let frequency = FrequentWordLexicon.frequencyScore(normalized, language: lang)
        let padded = "^" + normalized + "$"
        let chars = Array(padded)
        guard chars.count >= 2, let known = ngramsByLanguage[lang] else { return frequency }

        var matches = 0
        var total = 0
        for size in 2...3 where chars.count >= size {
            for index in 0...(chars.count - size) {
                total += 1
                if known.contains(String(chars[index..<(index + size)])) { matches += 1 }
            }
        }
        let ngram = total == 0 ? 0 : Double(matches) / Double(total)
        return frequency + (ngram * 5.0) - ((1.0 - ngram) * 1.5)
    }

    public static func contextScore(words: [String], language: String) -> Double {
        let lang = canonical(language)
        let recent = words.suffix(5)
        guard !recent.isEmpty else { return 0 }
        var score = 0.0
        var weight = 1.0
        for word in recent.reversed() {
            let core = SmartTokenizer.lexicalCore(of: word)
            if let hint = SmartTokenizer.languageHint(for: core) {
                score += canonical(hint) == lang ? 1.8 * weight : -1.8 * weight
            }
            if FrequentWordLexicon.contains(core, language: lang) { score += 0.8 * weight }
            weight *= 0.75
        }
        return score
    }

    public static func canonical(_ language: String) -> String {
        let prefix = String(language.lowercased().prefix(2))
        switch prefix {
        case "uk", "be", "bg": return "ru"
        case "de", "fr", "es", "pt", "pl": return "en"
        default: return prefix
        }
    }
}
