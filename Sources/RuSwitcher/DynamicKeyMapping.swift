import Carbon
import Foundation
import RuSwitcherAppSupport
import RuSwitcherCore

/// Динамический маппинг keycode↔символ для любой пары раскладок через UCKeyTranslate
enum DynamicKeyMapping {
    /// Кэш маппинга: ключ = "layoutID1→layoutID2"
    nonisolated(unsafe) private static var mapCache: [String: [Character: Character]] = [:]

    /// Все keycodes для букв/знаков (0-50 покрывает основную клавиатуру)
    private static let allKeycodes: [UInt16] = Array(0...50)

    // MARK: - Public API

    /// Получить символ для keycode в конкретной раскладке
    static func characterForKeycode(_ keycode: UInt16, layout: TISInputSource) -> Character? {
        guard let layoutData = layoutDataForSource(layout) else { return nil }
        return translateKeycode(keycode, layoutData: layoutData, shift: false)
    }

    /// Returns the physical stroke sequence that produces a literal character.
    /// International layouts use dead keys for characters such as straight
    /// quotes, so the sequence may include Space to commit the dead key.
    static func physicalKeys(for character: Character, layout: TISInputSource) -> [(keyCode: UInt16, shift: Bool)]? {
        guard let layoutData = layoutDataForSource(layout) else { return nil }
        for shift in [false, true] {
            for keyCode in allKeycodes where translateKeycode(
                keyCode,
                layoutData: layoutData,
                shift: shift
            ) == character {
                guard let deadKeySequence = deadKeySequenceIfNeeded(
                    keyCode: keyCode,
                    shift: shift,
                    character: character,
                    layoutData: layoutData
                ) else {
                    return [(keyCode, shift)]
                }
                return deadKeySequence
            }
        }
        return nil
    }

    /// Проверяет, является ли keycode "буквой" в любой из двух раскладок
    static func isLetterKeycode(_ keycode: UInt16) -> Bool {
        let settings = SettingsManager.shared
        let layouts = LayoutSwitcher.installedLayouts()

        // Пробуем с настроенными раскладками
        for layout in layouts {
            let id = LayoutSwitcher.sourceID(layout)
            if id == settings.layout1ID || id == settings.layout2ID || settings.layout1ID.isEmpty {
                if characterForKeycode(keycode, layout: layout) != nil {
                    return true
                }
            }
        }

        // Fallback на статическую таблицу
        return KeyMapping.keycodeToEN[keycode] != nil
    }

    /// Построить маппинг между двумя раскладками
    static func buildMap(from source: TISInputSource, to target: TISInputSource) -> [Character: Character] {
        let sourceID = LayoutSwitcher.sourceID(source)
        let targetID = LayoutSwitcher.sourceID(target)
        let cacheKey = "\(sourceID)→\(targetID)"

        if let cached = mapCache[cacheKey] {
            return cached
        }

        guard let sourceData = layoutDataForSource(source),
              let targetData = layoutDataForSource(target) else {
            return [:]
        }

        var map: [Character: Character] = [:]

        for keycode in allKeycodes {
            // Без shift
            if let sourceChar = translateKeycode(keycode, layoutData: sourceData, shift: false),
               let targetChar = translateKeycode(keycode, layoutData: targetData, shift: false),
               sourceChar != targetChar {
                map[sourceChar] = targetChar
            }
            // С shift
            if let sourceChar = translateKeycode(keycode, layoutData: sourceData, shift: true),
               let targetChar = translateKeycode(keycode, layoutData: targetData, shift: true),
               sourceChar != targetChar {
                map[sourceChar] = targetChar
            }
        }

        mapCache[cacheKey] = map
        return map
    }

    /// Конвертирует текст из текущей раскладки в целевую
    static func convert(_ text: String) -> String {
        let settings = SettingsManager.shared
        let layouts = LayoutSwitcher.installedLayouts()
        let currentID = LayoutSwitcher.currentLayoutID()

        // Определяем source и target раскладки (авто-детект — общий с LayoutSwitcher)
        let layout1ID = settings.layout1ID.isEmpty ? LayoutSwitcher.autoDetectID1(from: layouts) : settings.layout1ID
        let layout2ID = settings.layout2ID.isEmpty ? LayoutSwitcher.autoDetectID2(from: layouts) : settings.layout2ID

        guard let source = layouts.first(where: { LayoutSwitcher.sourceID($0) == currentID }),
              let targetID = (currentID == layout1ID) ? layout2ID : layout1ID as String?,
              let target = layouts.first(where: { LayoutSwitcher.sourceID($0) == targetID }) else {
            // Fallback на статический маппинг
            rslog("DynamicKeyMapping: fallback to static mapping")
            return KeyMapping.convert(text)
        }

        let map = buildMap(from: source, to: target)

        if map.isEmpty {
            rslog("DynamicKeyMapping: empty map, fallback to static")
            return KeyMapping.convert(text)
        }

        return String(text.map { map[$0] ?? $0 })
    }

    /// Manual selection is old document text, so the currently active layout is
    /// not a reliable source direction. Infer it from the dominant script and map
    /// using the configured layout pair.
    static func convertSelectedText(_ text: String) -> (
        converted: String,
        sourceLanguage: String,
        targetLanguage: String,
        targetLayoutID: String?
    )? {
        guard text.contains(where: \.isLetter) else { return nil }
        let direction = ScriptDirection.dominant(in: text)
        let dominant = direction?.sourceLanguage

        let layouts = LayoutSwitcher.installedLayouts()
        let settings = SettingsManager.shared
        let id1 = settings.layout1ID.isEmpty ? LayoutSwitcher.autoDetectID1(from: layouts) : settings.layout1ID
        let id2 = settings.layout2ID.isEmpty ? LayoutSwitcher.autoDetectID2(from: layouts) : settings.layout2ID
        let pair = [id1, id2].compactMap { id -> (String, TISInputSource)? in
            guard let source = layouts.first(where: { LayoutSwitcher.sourceID($0) == id }),
                  let language = LayoutSwitcher.languageCode(source) else { return nil }
            return (String(language.lowercased().prefix(2)), source)
        }
        let sourceEntry = dominant.flatMap { language in pair.first(where: { $0.0 == language }) }
            ?? pair.first(where: { LayoutSwitcher.sourceID($0.1) == LayoutSwitcher.currentLayoutID() })
        guard let sourceEntry,
              let targetEntry = pair.first(where: { LayoutSwitcher.sourceID($0.1) != LayoutSwitcher.sourceID(sourceEntry.1) }) else {
            let sourceLanguage = dominant ?? (SmartTokenizer.languageHint(for: text) ?? "en")
            let targetLanguage = sourceLanguage == "ru" ? "en" : "ru"
            return (KeyMapping.convert(text), sourceLanguage, targetLanguage, nil)
        }
        let map = buildMap(from: sourceEntry.1, to: targetEntry.1)
        guard !map.isEmpty else { return nil }
        return (
            String(text.map { map[$0] ?? $0 }).precomposedStringWithCanonicalMapping,
            sourceEntry.0,
            targetEntry.0,
            LayoutSwitcher.sourceID(targetEntry.1)
        )
    }

    /// Очистить кэш (при смене раскладок в настройках)
    static func clearCache() {
        mapCache.removeAll()
    }

    /// Returns what the same physical key would produce in the configured opposite
    /// layout. Used to distinguish real punctuation from a wrong-layout letter.
    static func oppositeCharacterForKeycode(
        _ keycode: UInt16,
        shift: Bool,
        caps: Bool,
        sourceLayoutID: String?
    ) -> Character? {
        let settings = SettingsManager.shared
        let layouts = LayoutSwitcher.installedLayouts()
        let sourceID = sourceLayoutID ?? LayoutSwitcher.currentLayoutID()
        let layout1ID = settings.layout1ID.isEmpty ? LayoutSwitcher.autoDetectID1(from: layouts) : settings.layout1ID
        let layout2ID = settings.layout2ID.isEmpty ? LayoutSwitcher.autoDetectID2(from: layouts) : settings.layout2ID
        let targetID = sourceID == layout1ID ? layout2ID : layout1ID
        guard let target = layouts.first(where: { LayoutSwitcher.sourceID($0) == targetID }),
              let targetData = layoutDataForSource(target) else { return nil }
        return translateKeycode(keycode, layoutData: targetData, shift: shift, caps: caps)
    }

    /// Конвертирует набранные keycodes в строки исходной и целевой раскладок —
    /// для движка перепечатки (не читаем поле, не трогаем буфер обмена).
    /// nil — если раскладки не определились; вызывающий безопасно пропускает замену.
    static func convertKeys(_ keys: [TypedKey]) -> ReconciledKeyText? {
        guard !keys.isEmpty else { return nil }
        // Удалёнка: символы проброшены через Screen Sharing (keyCode 0 + char). Конвертируем
        // по самому символу — направление RU↔EN определяет KeyMapping.convert по скрипту
        // (Cyrillic↔Latin), а не по раскладке локальной машины. Так офисный инстанс правильно
        // конвертит «руддщ»→«hello» независимо от того, какая раскладка активна на нём.
        if keys.allSatisfy({ $0.char != nil }) {
            let original = String(keys.compactMap { $0.char })
            let converted = KeyMapping.convert(original)
            return ReconciledKeyText(
                original: original,
                converted: converted,
                sourceWasOpposite: false,
                strokes: PhysicalKeyStroke.aligned(typed: original, converted: converted)
            )
        }
        let settings = SettingsManager.shared
        let layouts = LayoutSwitcher.installedLayouts()
        let capturedLayoutIDs = Set(keys.compactMap(\.sourceLayoutID))
        // Mixed-layout words are ambiguous by construction. Do not reconstruct them
        // against whichever layout happens to be active at decision time.
        if capturedLayoutIDs.count > 1 { return nil }
        let currentID = capturedLayoutIDs.first ?? LayoutSwitcher.currentLayoutID()
        let layout1ID = settings.layout1ID.isEmpty ? LayoutSwitcher.autoDetectID1(from: layouts) : settings.layout1ID
        let layout2ID = settings.layout2ID.isEmpty ? LayoutSwitcher.autoDetectID2(from: layouts) : settings.layout2ID

        guard let source = layouts.first(where: { LayoutSwitcher.sourceID($0) == currentID }),
              let targetID = (currentID == layout1ID) ? layout2ID : layout1ID as String?,
              let target = layouts.first(where: { LayoutSwitcher.sourceID($0) == targetID }),
              let sourceData = layoutDataForSource(source),
              let targetData = layoutDataForSource(target) else {
            return nil
        }

        var original = "", converted = ""
        var strokes: [PhysicalKeyStroke] = []
        for k in keys {
            guard let sc = translateKeycode(k.keyCode, layoutData: sourceData, shift: k.shift, caps: k.caps),
                  let tc = translateKeycode(k.keyCode, layoutData: targetData, shift: k.shift, caps: k.caps) else {
                return nil
            }
            original.append(sc)
            converted.append(tc)
            strokes.append(PhysicalKeyStroke(
                literal: String(sc),
                opposite: String(tc),
                keyCode: k.keyCode,
                shift: k.shift,
                caps: k.caps
            ))
        }
        let producedValues = keys.compactMap(\.producedText)
        let producedText = producedValues.count == keys.count ? producedValues.joined() : nil
        return KeyTextReconciler.reconcile(
            reconstructedOriginal: original,
            reconstructedConverted: converted,
            producedText: producedText,
            strokes: strokes
        )
    }

    // Авто-детект раскладок живёт в LayoutSwitcher (autoDetectID1/ID2).

    // MARK: - Private

    static func layoutDataForSource(_ source: TISInputSource) -> Data? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data
    }

    private static func translateKeycode(_ keycode: UInt16, layoutData: Data, shift: Bool, caps: Bool = false) -> Character? {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length: Int = 0

        var modifierKeyState: UInt32 = shift ? (UInt32(shiftKey >> 8) & 0xFF) : 0
        if caps { modifierKeyState |= UInt32(alphaLock >> 8) & 0xFF }

        let result = layoutData.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return -1
            }
            return UCKeyTranslate(
                ptr,
                keycode,
                UInt16(kUCKeyActionDown),
                modifierKeyState,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
        }

        guard result == noErr, length > 0 else { return nil }

        guard let scalar = UnicodeScalar(chars[0]) else { return nil }
        let char = Character(scalar)

        // Фильтруем контрольные символы
        if char.isNewline || char.asciiValue == 0 || chars[0] < 32 {
            return nil
        }

        return char
    }

    private static func deadKeySequenceIfNeeded(
        keyCode: UInt16,
        shift: Bool,
        character: Character,
        layoutData: Data
    ) -> [(keyCode: UInt16, shift: Bool)]? {
        var translation = KeyboardLayoutTranslationState()
        let first = translation.translate(
            keyCode: keyCode,
            shift: shift,
            capsLock: false,
            layoutData: layoutData
        )
        guard first?.isEmpty == true else { return nil }

        let committed = translation.translate(
            keyCode: 49,
            shift: false,
            capsLock: false,
            layoutData: layoutData
        )
        guard committed == String(character) else { return nil }
        return [(keyCode, shift), (49, false)]
    }
}
