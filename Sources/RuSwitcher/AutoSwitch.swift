import AppKit
import Carbon

/// Проверка слов по системному словарю (NSSpellChecker) — локально, без зависимостей,
/// без сети и без бандла данных. ~0.1мс на проверку, 40+ языков.
enum Dict {
    @MainActor private static let checker = NSSpellChecker.shared

    @MainActor static func isAvailable(_ lang: String) -> Bool {
        let two = String(lang.prefix(2))
        return checker.availableLanguages.contains { String($0.prefix(2)) == two }
    }

    /// true — слово есть в словаре языка (орфография корректна).
    @MainActor static func isValidWord(_ word: String, lang: String) -> Bool {
        let range = checker.checkSpelling(of: word, startingAt: 0, language: lang,
                                          wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return range.location == NSNotFound
    }
}

/// Hosts where Accessibility selection/`kAXSelectedText` is unreliable are
/// discovered at runtime, never by a hardcoded bundle-ID list. Two distinct
/// AX failure modes route here, from `TextConverter.finishFocusedSuffixReplacement`:
///
/// - AX reads fine but writing `kAXSelectedTextAttribute` **inserts** instead
///   of replacing (duplicate: converted + original). `recoverInsertedReplacement`
///   detects and self-heals this in place; once confirmed for a bundle ID, it is
///   remembered here so later conversions skip straight to Backspace+Unicode.
/// - AX cannot be read at all (`.unavailable`) — common for terminal emulators
///   that render their own glyph grid and expose little or no Accessibility
///   text API. There is nothing to learn or cache here: every attempt falls
///   through to Backspace+Unicode generically, and safety comes from the
///   caller's `isCurrent()` revision-freshness check, not from recognizing
///   the app in advance.
///
/// The learned set is process-lifetime only (not persisted): if a host's AX
/// implementation improves in a later version, RuSwitcher re-discovers that
/// after restart instead of being stuck with a stale preference.
final class ManualHostPolicy: @unchecked Sendable {
    static let shared = ManualHostPolicy()

    private let lock = NSLock()
    private var learnedKeyboardDeletionBundleIDs: Set<String> = []

    func prefersKeyboardDeletion(bundleID: String?) -> Bool {
        guard let id = bundleID, !id.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        return learnedKeyboardDeletionBundleIDs.contains(id)
    }

    /// Call only after confirming (not merely suspecting) that `bundleID`'s
    /// `kAXSelectedTextAttribute` write inserted rather than replaced.
    func learnPrefersKeyboardDeletion(bundleID: String?) {
        guard let id = bundleID, !id.isEmpty else { return }
        lock.lock()
        let isNew = learnedKeyboardDeletionBundleIDs.insert(id).inserted
        lock.unlock()
        if isNew { rslog("manual_host_learned_keyboard_deletion") }
    }
}

/// Политика безопасности авто-конвертации.
enum AutoSwitchPolicy {
    /// Активен ли защищённый ввод (поле пароля, Secure Keyboard Entry в терминале) —
    /// тогда авто-конвертацию НЕ делаем (приватность; пароль не трогаем).
    static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    /// Дефолтный список приложений, где авто выключено: терминалы, IDE, менеджеры
    /// паролей. Возвращается, пока пользователь не отредактировал список
    /// (см. SettingsManager.deniedApps). Запись с суффиксом "*" — префикс (весь вендор).
    static let defaultDeniedApps: [String] = [
        "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
        "io.alacritty", "com.github.wez.wezterm", "dev.warp.Warp-Stable", "co.zeit.hyper",
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.sublimetext.4", "com.todesktop.230313mzl4w4u92", "com.google.android.studio",
        "com.jetbrains.*",
        "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "org.keepassxc.keepassxc",
    ]

    /// Менеджеры паролей — несъёмные из списка в UI (безопасность).
    static let protectedApps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "org.keepassxc.keepassxc",
    ]

    static func isDeniedApp(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        // Менеджеры паролей — жёсткий, не зависящий от пользовательского списка гейт:
        // их нельзя разблокировать ни через UI, ни через рассинхрон дефолтов.
        if protectedApps.contains(id) { return true }
        for entry in SettingsManager.shared.deniedApps {
            if entry.hasSuffix("*") {
                if id.hasPrefix(String(entry.dropLast())) { return true }
            } else if entry == id {
                return true
            }
        }
        return false
    }

    /// Слово в списке never-convert (обе стороны пары, без регистра).
    static func isDeniedWord(_ typed: String, _ converted: String) -> Bool {
        let set = SettingsManager.shared.deniedWordsSet
        guard !set.isEmpty else { return false }
        return set.contains(typed.lowercased()) || set.contains(converted.lowercased())
    }

    /// Слово в списке always-convert — матчим по СКОНВЕРТИРОВАННОЙ (целевой) форме.
    /// В список кладётся «целевое» слово (что должно получиться), а не мусор раскладки —
    /// иначе правильно набранное слово конвертилось бы обратно (пинг-понг).
    static func isAlwaysConvert(_ converted: String) -> Bool {
        let set = SettingsManager.shared.alwaysConvertWordsSet
        guard !set.isEmpty else { return false }
        return set.contains(converted.lowercased())
    }

    /// Клиенты удалённого рабочего стола: когда такое окно в фокусе, текст живёт
    /// на ДРУГОЙ машине — наш инстанс должен молчать и уступить удалённому RuSwitcher.
    static let remoteClients: Set<String> = [
        "com.apple.ScreenSharing",   // Apple «Общий экран» / Screen Sharing.app
        "com.apple.RemoteDesktop",   // Apple Remote Desktop
    ]

    static func isRemoteDesktopClient(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return remoteClients.contains(id)
    }

    /// Правило «уступи удалёнке»: режим удалённого стола включён И в фокусе клиент
    /// удалёнки → этот инстанс ничего не делает (ни триггер, ни авто), чтобы не
    /// дублировать работу инстанса на контролируемой машине.
    static var shouldDeferToRemoteClient: Bool {
        guard SettingsManager.shared.remoteDesktopMode else { return false }
        return isRemoteDesktopClient(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }
}
