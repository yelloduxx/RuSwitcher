import Foundation
import RuSwitcherCore
import ServiceManagement

/// Централизованное хранение настроек через UserDefaults
/// Настройки приложения. Свойства thread-safe через UserDefaults.
final class SettingsManager: @unchecked Sendable {
    struct LearnedCorrectionsImportResult {
        let imported: Int
        let added: Int
        let total: Int
    }

    static let shared = SettingsManager()
    static let learningResetNotification = Notification.Name("com.ruswitcher.learningReset")

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let autoSwitch = "com.ruswitcher.autoSwitch"
        static let layout1ID = "com.ruswitcher.layout1ID"
        static let layout2ID = "com.ruswitcher.layout2ID"
        static let debugLog = "com.ruswitcher.debugLog"
        static let skippedVersion = "com.ruswitcher.skippedVersion"
        static let lastUpdateCheck = "com.ruswitcher.lastUpdateCheck"
        static let launchAtLogin = "com.ruswitcher.launchAtLogin"
        static let checkUpdatesEnabled = "com.ruswitcher.checkUpdatesEnabled"
        static let interfaceLanguage = "com.ruswitcher.interfaceLanguage"
        static let permissionsWereGranted = "com.ruswitcher.permissionsWereGranted"
        static let launchAtLoginAsked = "com.ruswitcher.launchAtLoginAsked"
        static let perAppLayout = "com.ruswitcher.perAppLayout"
        static let triggerKey = "com.ruswitcher.triggerKey"
        static let triggerRightOnly = "com.ruswitcher.triggerRightOnly"
        static let triggerDoubleTap = "com.ruswitcher.triggerDoubleTap"
        static let autoConvert = "com.ruswitcher.autoConvert"
        static let remoteDesktopMode = "com.ruswitcher.remoteDesktopMode"
        static let showRemoteDesktopBeta = "com.ruswitcher.showRemoteDesktopBeta"
        static let autoConvertOffered = "com.ruswitcher.autoConvertOffered"
        static let keySound = "com.ruswitcher.keySound"
        static let caretFlag = "com.ruswitcher.caretFlag"
        static let monochromeIcon = "com.ruswitcher.monochromeIcon"
        static let deniedAppsAdded = "com.ruswitcher.deniedAppsAdded"
        static let deniedAppsRemoved = "com.ruswitcher.deniedAppsRemoved"
        static let deniedWords = "com.ruswitcher.deniedWords"
        static let alwaysConvertWords = "com.ruswitcher.alwaysConvertWords"
        static let adaptiveRules = "com.ruswitcher.adaptiveRules.v1"
        static let smartEngineV2 = "com.ruswitcher.smartEngineV2"
        static let smartEngineV3 = "com.ruswitcher.smartEngineV3"
        static let smartEngineV4Mode = "com.ruswitcher.smartEngineV4Mode"
        static let personalizationAdapterV4 = "com.ruswitcher.personalizationAdapterV4"
        static let shareAnonymousStatistics = "com.ruswitcher.shareAnonymousStatistics"
    }

    private init() {}

    // MARK: - Properties

    var autoSwitchEnabled: Bool {
        get { defaults.object(forKey: Keys.autoSwitch) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.autoSwitch) }
    }

    /// ID первой раскладки (пустая строка = авто-определение)
    var layout1ID: String {
        get { defaults.string(forKey: Keys.layout1ID) ?? "" }
        set { defaults.set(newValue, forKey: Keys.layout1ID) }
    }

    /// ID второй раскладки (пустая строка = авто-определение)
    var layout2ID: String {
        get { defaults.string(forKey: Keys.layout2ID) ?? "" }
        set { defaults.set(newValue, forKey: Keys.layout2ID) }
    }

    var debugLogEnabled: Bool {
        get { defaults.bool(forKey: Keys.debugLog) }
        set { defaults.set(newValue, forKey: Keys.debugLog) }
    }

    var skippedVersion: String {
        get { defaults.string(forKey: Keys.skippedVersion) ?? "" }
        set { defaults.set(newValue, forKey: Keys.skippedVersion) }
    }

    var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Keys.lastUpdateCheck) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastUpdateCheck) }
    }

    var launchAtLogin: Bool {
        get { defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: Keys.launchAtLogin)
            let enabled = newValue
            DispatchQueue.main.async {
                self.doUpdateLoginItem(enabled: enabled)
            }
        }
    }

    /// Авто-проверка обновлений при запуске (дефолт: включено).
    /// На ручную проверку через меню не влияет.
    var checkUpdatesEnabled: Bool {
        get { defaults.object(forKey: Keys.checkUpdatesEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.checkUpdatesEnabled) }
    }

    /// Язык интерфейса (пустая строка = авто-определение по системе)
    var interfaceLanguage: String {
        get { defaults.string(forKey: Keys.interfaceLanguage) ?? "" }
        set {
            defaults.set(newValue, forKey: Keys.interfaceLanguage)
            L10n.reloadLanguage()
        }
    }

    /// Флаг: разрешения были ранее выданы (для определения сброса после обновления)
    var permissionsWereGranted: Bool {
        get { defaults.bool(forKey: Keys.permissionsWereGranted) }
        set { defaults.set(newValue, forKey: Keys.permissionsWereGranted) }
    }

    var launchAtLoginAsked: Bool {
        get { defaults.bool(forKey: Keys.launchAtLoginAsked) }
        set { defaults.set(newValue, forKey: Keys.launchAtLoginAsked) }
    }

    var perAppLayout: Bool {
        get { defaults.bool(forKey: Keys.perAppLayout) }
        set { defaults.set(newValue, forKey: Keys.perAppLayout) }
    }

    // MARK: - Триггер конвертации

    /// Клавиша-триггер: "option" | "command" | "control" | "shift" | "capsLock".
    /// Дефолт — option (как было до 2.3, поведение не меняется).
    var triggerKey: String {
        get { defaults.string(forKey: Keys.triggerKey) ?? "option" }
        set { defaults.set(newValue, forKey: Keys.triggerKey) }
    }

    /// Реагировать только на правую клавишу модификатора (для option/command/control/shift).
    var triggerRightOnly: Bool {
        get { defaults.bool(forKey: Keys.triggerRightOnly) }
        set { defaults.set(newValue, forKey: Keys.triggerRightOnly) }
    }

    /// Двойной тап вместо одиночного.
    var triggerDoubleTap: Bool {
        get { defaults.bool(forKey: Keys.triggerDoubleTap) }
        set { defaults.set(newValue, forKey: Keys.triggerDoubleTap) }
    }

    /// Caps Lock как триггер требует consume-tap (чтобы подавить переключение регистра).
    var triggerIsCapsLock: Bool { triggerKey == "capsLock" }

    /// Автоматическая конвертация «на лету» (детект неправильной раскладки на границе
    /// слова). Отдельный флаг от autoSwitchEnabled (тот гейтит РУЧНОЙ триггер).
    /// По умолчанию ВЫКЛ — точность важнее, не делаем ничего без явного включения.
    var autoConvert: Bool {
        get { defaults.bool(forKey: Keys.autoConvert) }
        set { defaults.set(newValue, forKey: Keys.autoConvert) }
    }

    /// Hidden rollback switch for the new engine. It defaults to enabled; support can
    /// temporarily disable it with `defaults` without replacing the application.
    var smartEngineV2: Bool {
        get {
            if defaults.object(forKey: Keys.smartEngineV2) == nil { return true }
            return defaults.bool(forKey: Keys.smartEngineV2)
        }
        set { defaults.set(newValue, forKey: Keys.smartEngineV2) }
    }

    var smartEngineV3: Bool {
        get {
            if defaults.object(forKey: Keys.smartEngineV3) == nil { return true }
            return defaults.bool(forKey: Keys.smartEngineV3)
        }
        set { defaults.set(newValue, forKey: Keys.smartEngineV3) }
    }

    var smartEngineV4Mode: SmartEngineV4Mode {
        get {
            guard let raw = defaults.string(forKey: Keys.smartEngineV4Mode),
                  let mode = SmartEngineV4Mode(rawValue: raw) else { return .shadow }
            return mode
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.smartEngineV4Mode) }
    }

    func personalizationAdapter(for manifest: ContextualModelManifest) -> PersonalizationAdapter {
        guard let data = defaults.data(forKey: Keys.personalizationAdapterV4),
              var adapter = try? JSONDecoder().decode(PersonalizationAdapter.self, from: data) else {
            return PersonalizationAdapter(
                modelVersion: manifest.modelVersion,
                embeddingSize: manifest.embeddingSize
            )
        }
        adapter.migrate(modelVersion: manifest.modelVersion, embeddingSize: manifest.embeddingSize)
        return adapter
    }

    func savePersonalizationAdapter(_ adapter: PersonalizationAdapter) {
        guard let data = try? JSONEncoder().encode(adapter) else { return }
        defaults.set(data, forKey: Keys.personalizationAdapterV4)
    }

    /// Opt-in only. Payloads contain aggregate counters, never typed text or app IDs.
    var shareAnonymousStatistics: Bool {
        get { defaults.bool(forKey: Keys.shareAnonymousStatistics) }
        set { defaults.set(newValue, forKey: Keys.shareAnonymousStatistics) }
    }

    /// issue #10: показывать флаг раскладки у текстовой каретки (бета). По умолчанию ВЫКЛ.
    var caretFlag: Bool {
        get { defaults.bool(forKey: Keys.caretFlag) }
        set { defaults.set(newValue, forKey: Keys.caretFlag) }
    }

    /// Режим работы через удалённый рабочий стол (Apple Screen Sharing и т.п.).
    /// При включении: tap поднимается на session-уровень (видит проброшенные
    /// нажатия), и инстанс «уступает удалёнке», если в фокусе клиент удалёнки.
    var remoteDesktopMode: Bool {
        get { defaults.bool(forKey: Keys.remoteDesktopMode) }
        set { defaults.set(newValue, forKey: Keys.remoteDesktopMode) }
    }

    /// Показывать ли тумблер «Режим удалённого стола» (видимая бета в 2.5). По умолчанию
    /// ВКЛючён; спрятать можно явно: `defaults write com.ruswitcher.app com.ruswitcher.showRemoteDesktopBeta -bool NO`.
    var showRemoteDesktopBeta: Bool {
        get {
            // Нет записи в defaults → считаем включённым (дефолт ON для 2.5).
            if defaults.object(forKey: Keys.showRemoteDesktopBeta) == nil { return true }
            return defaults.bool(forKey: Keys.showRemoteDesktopBeta)
        }
        set { defaults.set(newValue, forKey: Keys.showRemoteDesktopBeta) }
    }

    /// Предлагали ли уже автозамену при первом запуске (онбординг показывается один раз).
    var autoConvertOffered: Bool {
        get { defaults.bool(forKey: Keys.autoConvertOffered) }
        set { defaults.set(newValue, forKey: Keys.autoConvertOffered) }
    }

    /// issue #7: звук раскладки на первой букве после смены раскладки. По умолчанию OFF.
    var keySound: Bool {
        get { defaults.bool(forKey: Keys.keySound) }
        set { defaults.set(newValue, forKey: Keys.keySound) }
    }

    /// Иконка меню-бара в системном стиле: монохромная плашка «РУ/EN» (template)
    /// вместо цветного флага-эмодзи. По умолчанию OFF — флаг привычнее.
    var monochromeIcon: Bool {
        get { defaults.bool(forKey: Keys.monochromeIcon) }
        set { defaults.set(newValue, forKey: Keys.monochromeIcon) }
    }

    /// Приложения, где авто-конверсия выключена. Эффективный список = дефолты минус
    /// явно удалённые пользователем плюс явно добавленные. Так новые дефолты из будущих
    /// версий подхватываются автоматически, а правки пользователя сохраняются.
    var deniedApps: [String] {
        get {
            let removed = Set(defaults.stringArray(forKey: Keys.deniedAppsRemoved) ?? [])
            let added = defaults.stringArray(forKey: Keys.deniedAppsAdded) ?? []
            var result = AutoSwitchPolicy.defaultDeniedApps.filter { !removed.contains($0) }
            for a in added where !result.contains(a) { result.append(a) }
            return result
        }
        set {
            let defaultsSet = Set(AutoSwitchPolicy.defaultDeniedApps)
            let newSet = Set(newValue)
            let removed = AutoSwitchPolicy.defaultDeniedApps.filter { !newSet.contains($0) }
            let added = newValue.filter { !defaultsSet.contains($0) }
            defaults.set(removed, forKey: Keys.deniedAppsRemoved)
            defaults.set(added, forKey: Keys.deniedAppsAdded)
        }
    }

    /// Слова, которые авто-конверсия никогда не трогает.
    var deniedWords: [String] {
        get { defaults.stringArray(forKey: Keys.deniedWords) ?? [] }
        set { defaults.set(newValue, forKey: Keys.deniedWords) }
    }
    var deniedWordsSet: Set<String> { Set(deniedWords.map { $0.lowercased() }) }

    /// Слова, которые авто-конверсия переключает всегда (даже если их нет в словаре).
    var alwaysConvertWords: [String] {
        get { defaults.stringArray(forKey: Keys.alwaysConvertWords) ?? [] }
        set { defaults.set(newValue, forKey: Keys.alwaysConvertWords) }
    }
    var alwaysConvertWordsSet: Set<String> { Set(alwaysConvertWords.map { $0.lowercased() }) }

    var adaptiveRuleBook: AdaptiveRuleBook {
        get {
            guard let data = defaults.data(forKey: Keys.adaptiveRules),
                  let book = try? JSONDecoder().decode(AdaptiveRuleBook.self, from: data) else {
                return AdaptiveRuleBook()
            }
            return book
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Keys.adaptiveRules)
        }
    }

    func adaptiveBias(original: String, converted: String, appBundleID: String?) -> Double {
        adaptiveRuleBook.bias(original: original, converted: converted, appBundleID: appBundleID)
    }

    func isAdaptiveConfirmed(original: String, converted: String, appBundleID: String?) -> Bool {
        adaptiveRuleBook.isConfirmed(original: original, converted: converted, appBundleID: appBundleID)
    }

    func recordAdaptivePositive(original: String, converted: String, appBundleID: String?) {
        var book = adaptiveRuleBook
        book.recordPositive(original: original, converted: converted, appBundleID: appBundleID)
        adaptiveRuleBook = book
    }

    func recordAdaptiveNegative(original: String, converted: String, appBundleID: String?) {
        var book = adaptiveRuleBook
        book.recordNegative(original: original, converted: converted, appBundleID: appBundleID)
        adaptiveRuleBook = book
    }

    func recordAdaptiveConfirmed(original: String, converted: String) {
        var book = adaptiveRuleBook
        // Explicit manual intent is portable across applications. Undo removes
        // confirmation before adding an app-scoped negative signal.
        book.recordConfirmed(original: original, converted: converted, appBundleID: nil)
        adaptiveRuleBook = book
    }

    func clearAdaptiveRules() {
        defaults.removeObject(forKey: Keys.adaptiveRules)
        defaults.removeObject(forKey: Keys.personalizationAdapterV4)
        NotificationCenter.default.post(name: Self.learningResetNotification, object: nil)
    }

    func exportLearnedCorrections() throws -> Data {
        try LearnedCorrectionsArchive(ruleBook: adaptiveRuleBook).encoded()
    }

    func importLearnedCorrections(_ data: Data) throws -> LearnedCorrectionsImportResult {
        let importedBook = try LearnedCorrectionsArchive.decode(data).ruleBook
        var current = adaptiveRuleBook
        let previousRules = current.rules
        current.merge(importedBook)
        adaptiveRuleBook = current
        let added = current.rules.filter { rule in
            !previousRules.contains {
                $0.original == rule.original
                    && $0.converted == rule.converted
                    && $0.appBundleID == rule.appBundleID
            }
        }.count
        return LearnedCorrectionsImportResult(
            imported: importedBook.rules.count,
            added: added,
            total: current.rules.count
        )
    }

    var donateURL: String { "https://boosty.to/ruswitcher" }
    var contactEmail: String { "xrashid@gmail.com" }

    // MARK: - GitHub coordinates (единственный источник — чтобы при переименовании
    // репозитория правка была в одном месте)
    static let githubOwner = "rashn"
    static let githubRepo = "RuSwitcher"
    static var githubURL: String { "https://github.com/\(githubOwner)/\(githubRepo)" }
    /// Team ID (Apple Developer), которым подписаны релизы. Используется для
    /// пиннинга подписи при авто-обновлении.
    static let developerTeamID = "9GEWCZ59HK"
    static func releaseDMGURL(version: String) -> String {
        "\(githubURL)/releases/download/v\(version)/\(githubRepo)-\(version).dmg"
    }

    // MARK: - Login Item

    private func doUpdateLoginItem(enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
                rslog("Login item registered")
            } else {
                try service.unregister()
                rslog("Login item unregistered")
            }
        } catch {
            rslog("Login item error: \(error)")
        }
    }

    /// Текущий статус автозапуска (может отличаться от настройки)
    var loginItemStatus: SMAppService.Status {
        SMAppService.mainApp.status
    }
}
