import Carbon
import Foundation

/// Управление раскладками через TIS API
enum LayoutSwitcher {
    /// Возвращает ID текущей раскладки
    static func currentLayoutID() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return ""
        }
        return sourceID(source)
    }

    /// Код языка ТЕКУЩЕЙ раскладки (BCP-47, например "ru"/"en"). nil если недоступен.
    /// Надёжнее парсинга ID: тот же признак, что использует сама ОС.
    static func currentLanguageCode() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return languageCode(source)
    }

    /// Переключает на противоположную раскладку (из настроенной пары)
    static func switchToOpposite() {
        let current = currentLayoutID()
        let settings = SettingsManager.shared
        let sources = installedLayouts()

        let id1 = settings.layout1ID.isEmpty ? autoDetectID1(from: sources) : settings.layout1ID
        let id2 = settings.layout2ID.isEmpty ? autoDetectID2(from: sources) : settings.layout2ID

        let targetID = (current == id1) ? id2 : id1

        if let target = sources.first(where: { sourceID($0) == targetID }) {
            TISEnableInputSource(target)
            TISSelectInputSource(target)
        }
    }

    /// Переключает на конкретную раскладку по точному ID
    static func switchTo(layoutID: String) {
        let sources = installedLayouts()
        if let target = sources.first(where: { sourceID($0) == layoutID }) {
            TISEnableInputSource(target)
            TISSelectInputSource(target)
        }
    }

    /// Все установленные раскладки
    static func installedLayouts() -> [TISInputSource] {
        let conditions: CFDictionary = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsSelectCapable as String: true as Any,
        ] as CFDictionary

        guard let list = TISCreateInputSourceList(conditions, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list
    }

    /// ID раскладки (например "com.apple.keylayout.Russian")
    static func sourceID(_ source: TISInputSource) -> String {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return ""
        }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    /// Локализованное имя раскладки (например "Русская")
    static func sourceName(_ source: TISInputSource) -> String {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else {
            return sourceID(source)
        }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    /// Код языка раскладки (BCP-47, например "ru", "en"), из kTISPropertyInputSourceLanguages
    static func languageCode(_ source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
            return nil
        }
        let langs = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String]
        return langs?.first
    }

    /// Коды языков текущей и противоположной раскладок (для авто-детекта раскладки).
    static func currentAndOppositeLanguage() -> (current: String, opposite: String)? {
        languagePair(sourceLayoutID: currentLayoutID())
    }

    /// Language pair for the layout captured with a token. The current system
    /// layout may already have changed by the time a token is evaluated.
    static func languagePair(sourceLayoutID: String) -> (current: String, opposite: String)? {
        let settings = SettingsManager.shared
        let sources = installedLayouts()
        let id1 = settings.layout1ID.isEmpty ? autoDetectID1(from: sources) : settings.layout1ID
        let id2 = settings.layout2ID.isEmpty ? autoDetectID2(from: sources) : settings.layout2ID
        let targetID = (sourceLayoutID == id1) ? id2 : id1
        guard let cur = sources.first(where: { sourceID($0) == sourceLayoutID }),
              let tgt = sources.first(where: { sourceID($0) == targetID }),
              let curLang = languageCode(cur), let tgtLang = languageCode(tgt) else {
            return nil
        }
        return (curLang, tgtLang)
    }

    // MARK: - Auto-detect

    /// Авто-определение «английской» раскладки (используется и из DynamicKeyMapping).
    static func autoDetectID1(from sources: [TISInputSource]) -> String {
        // Prefer an actual English keyboard layout. Matching only by an ID
        // fragment can miss layouts whose localized name differs.
        for source in sources {
            let id = sourceID(source)
            if normalizedLanguageCode(source) == "en",
               (id.contains("ABC") || id.contains("US") || id.contains("British")) {
                return id
            }
        }
        if let english = sources.first(where: { normalizedLanguageCode($0) == "en" }) {
            return sourceID(english)
        }
        return sources.first.map { sourceID($0) } ?? ""
    }

    /// Auto-detect the Russian side of RuSwitcher's production EN/RU pair.
    /// Falling back to the first non-English input source used to select Chinese
    /// IMEs on Macs where they precede Russian in the system source list.
    static func autoDetectID2(from sources: [TISInputSource]) -> String {
        let id1 = autoDetectID1(from: sources)
        if let russian = sources.first(where: { normalizedLanguageCode($0) == "ru" }) {
            return sourceID(russian)
        }
        for source in sources {
            let id = sourceID(source)
            if id != id1, normalizedLanguageCode(source) != "en" {
                return id
            }
        }
        return ""
    }

    private static func normalizedLanguageCode(_ source: TISInputSource) -> String? {
        languageCode(source).map { String($0.lowercased().prefix(2)) }
    }
}
