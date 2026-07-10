import AppKit
import ApplicationServices
import RuSwitcherCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let healthItemTag = 742
    private var statusItem: NSStatusItem!
    private let keyboardMonitor = KeyboardMonitor()
    private let textConverter = TextConverter()
    private lazy var conversionCoordinator = ConversionCoordinator(eventReplacer: textConverter)
    private let languageModel = LanguageModelStore.bundled
    private let textContextReader = FocusedTextContextReader()
    private var languageBeliefs: [String: LanguageBelief] = [:]
    private let settingsController = SettingsWindowController()
    private let perAppLayoutManager = PerAppLayoutManager()
    private var permissionCheckTimer: Timer?
    private var iconRefreshTimer: Timer?
    private var updateCheckTimer: Timer?   // периодическая авто-проверка обновлений, пока приложение работает
    private var monitoringActive = false
    private var caretIndicator: CaretIndicator?   // issue #10: флаг у каретки (бета, по умолчанию OFF)
    private var lastFlagShown: String?            // идентичность раскладки для детекта смены (не title!)
    private var badgeCache: [String: NSImage] = [:]  // монохромные плашки, чтобы не перерисовывать 2с-опросом

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SettingsManager.shared.smartEngineV3, let languageModel {
            rslog("engine: v3 model=\(languageModel.metadata.modelVersion) format=\(languageModel.metadata.formatVersion)")
        } else {
            rslog("engine: v2-fallback modelUnavailable=\(languageModel == nil)")
        }
        setupStatusItem()
        setupSettingsCallbacks()
        syncLoginItem()
        runPermissionWizard()
        UpdateChecker.checkOnLaunch()
        // Периодическая авто-проверка обновлений, пока приложение работает (не только на старте).
        // Тикает каждые 6ч; сам запрос к GitHub не чаще раза в сутки (троттл в UpdateChecker) и
        // уважает настройку «Автоматически проверять обновления» (её можно снять, чтобы отключить).
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in UpdateChecker.checkPeriodic() }
        }
    }

    private func setupSettingsCallbacks() {
        settingsController.onAutoSwitchChanged = { [weak self] _ in
            // Не адресуем пункт по индексу: с 2.5.0 item(at: 0) — строка версии, а со списком
            // раскладок индексы вообще динамические. Пересборка — как у соседних колбэков.
            self?.rebuildMenu()
        }
        settingsController.onPerAppLayoutChanged = { [weak self] enabled in
            guard let self else { return }
            if enabled {
                self.startPerAppLayout()
            } else {
                self.perAppLayoutManager.stop()
            }
        }
        settingsController.onLanguageChanged = { [weak self] in
            self?.rebuildMenu()
        }
        settingsController.onTriggerChanged = { [weak self] in
            self?.reconfigureTap()
        }
        settingsController.onAutoConvertChanged = { [weak self] _ in
            self?.rebuildMenu()  // синхронизировать галочку в меню
            self?.reconfigureTap() // active tap нужен для атомарной replay-транзакции
        }
        settingsController.onRemoteDesktopChanged = { [weak self] _ in
            self?.reconfigureTap()  // уровень tap зависит от режима
            self?.rebuildMenu()
        }
        settingsController.onCaretFlagChanged = { [weak self] _ in
            self?.rebuildMenu()          // синхронизировать галочку в меню
            self?.syncCaretIndicator()   // создать/снести индикатор + обновить гейт onUserInput
        }
    }

    // MARK: - Learn-from-undo (предложить добавить слово в never-convert)

    private struct AutoLearningEvent {
        let original: String
        let converted: String
        let appBundleID: String?
        let at: Date
    }

    private var lastAutoConverted: AutoLearningEvent?
    private var sessionNegativePairs: Set<String> = []

    private func learningKey(original: String, converted: String, appBundleID: String?) -> String {
        [
            FrequentWordLexicon.normalize(original),
            FrequentWordLexicon.normalize(converted),
            appBundleID ?? "*",
        ].joined(separator: "\u{1f}")
    }

    private func learnFromUndo() {
        guard let last = lastAutoConverted, Date().timeIntervalSince(last.at) < 20 else { return }
        lastAutoConverted = nil
        sessionNegativePairs.insert(learningKey(
            original: last.original,
            converted: last.converted,
            appBundleID: last.appBundleID
        ))
        SettingsManager.shared.recordAdaptiveNegative(
            original: last.original,
            converted: last.converted,
            appBundleID: last.appBundleID
        )
        rslog("learn: negative originalLen=\(last.original.count) convertedLen=\(last.converted.count)")
    }

    private func reinforcePreviousCorrectionIfNeeded() {
        guard let last = lastAutoConverted else { return }
        lastAutoConverted = nil
        SettingsManager.shared.recordAdaptivePositive(
            original: last.original,
            converted: last.converted,
            appBundleID: last.appBundleID
        )
        rslog("learn: positive originalLen=\(last.original.count) convertedLen=\(last.converted.count)")
    }

    private func startPerAppLayout() {
        perAppLayoutManager.onLayoutRestored = { [weak self] in
            self?.keyboardMonitor.markConverted()
            self?.textConverter.clearState()
            self?.updateStatusIcon()
        }
        perAppLayoutManager.start()
    }

    // MARK: - Login Item Sync

    /// Синхронизирует состояние автозагрузки с системой при старте.
    /// Если галочка включена, но Login Item потерян (переустановка/обновление) — перерегистрирует.
    /// Если галочка выключена, но Login Item есть — снимает.
    private func syncLoginItem() {
        let settings = SettingsManager.shared
        let wanted = settings.launchAtLogin
        let status = settings.loginItemStatus

        rslog("Login item sync: wanted=\(wanted) status=\(status.rawValue)")

        if wanted && status != .enabled {
            // Галочка стоит, но Login Item не активен — перерегистрируем
            rslog("Re-registering login item...")
            settings.launchAtLogin = true  // setter вызовет doUpdateLoginItem
        } else if !wanted && status == .enabled {
            // Галочка снята, но Login Item активен — убираем
            rslog("Unregistering stale login item...")
            settings.launchAtLogin = false
        }
    }

    // MARK: - Permission Wizard

    private func runPermissionWizard(interactive: Bool = false) {
        let acc = AXIsProcessTrusted()
        let inp = CGPreflightListenEventAccess()
        rslog("Permissions: accessibility=\(acc) inputMonitoring=\(inp)")

        if acc && inp {
            // Запоминаем что разрешения были даны
            SettingsManager.shared.permissionsWereGranted = true
            if !monitoringActive { startMonitoring() }
            // Ручная проверка из меню должна давать видимый отклик.
            if interactive { showPermissionsOKAlert() }
            return
        }

        // Проверяем: разрешения были раньше, а теперь сброшены (обновление)
        if SettingsManager.shared.permissionsWereGranted {
            rslog("Permissions were previously granted — reset detected after update")
            SettingsManager.shared.permissionsWereGranted = false
            showPermissionsResetAlert()
            return
        }

        // Первый запуск — обычный визард
        if acc {
            showStep_InputMonitoring()
            return
        }

        showStep_Accessibility()
    }

    /// Подтверждение при ручной проверке, когда все разрешения уже выданы
    private func showPermissionsOKAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.permissionsOkTitle
        alert.informativeText = L10n.permissionsOkText
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Уведомление о сбросе разрешений после обновления
    private func showPermissionsResetAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.wizardPermissionsResetTitle
        alert.informativeText = L10n.wizardPermissionsResetText
        alert.addButton(withTitle: "OK")
        alert.runModal()

        // Сбрасываем старые записи через tccutil
        resetPermissions()

        // Запрашиваем заново
        showStep_Accessibility()
    }

    /// Сбрасывает старые записи разрешений для нашего bundle ID
    private func resetPermissions() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.ruswitcher.app"
        rslog("Resetting TCC entries for \(bundleID)")

        for service in ["Accessibility", "ListenEvent"] {
            let reset = Process()
            reset.launchPath = "/usr/bin/tccutil"
            reset.arguments = ["reset", service, bundleID]
            try? reset.run()
            reset.waitUntilExit()
        }

        rslog("TCC entries reset done")
    }

    private func showStep_Accessibility() {
        // AXIsProcessTrustedWithOptions с prompt=true показывает системный диалог
        // и добавляет программу в список Accessibility автоматически
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true as CFBoolean] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if AXIsProcessTrusted() {
                    rslog("Accessibility granted!")
                    self.permissionCheckTimer?.invalidate()
                    self.permissionCheckTimer = nil
                    self.showStep_InputMonitoring()
                }
            }
        }
    }

    private func showStep_InputMonitoring() {
        // CGRequestListenEventAccess() показывает системный диалог и добавляет
        // программу в список Input Monitoring автоматически
        let preflightOK = CGPreflightListenEventAccess()
        rslog("Preflight check = \(preflightOK)")

        if preflightOK {
            // Уже есть — сразу запускаем
            SettingsManager.shared.permissionsWereGranted = true
            startMonitoring()
            return
        }

        rslog("Requesting access...")
        CGRequestListenEventAccess()

        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if CGPreflightListenEventAccess() {
                    rslog("Input Monitoring granted! Restarting...")
                    SettingsManager.shared.permissionsWereGranted = true
                    self.permissionCheckTimer?.invalidate()
                    self.permissionCheckTimer = nil
                    self.restartApp()
                }
            }
        }
    }

    private func restartApp() {
        rslog("Restarting from: \(Bundle.main.bundlePath)")
        AppRelauncher.relaunch()
    }

    // MARK: - Start Monitoring

    private func startMonitoring() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil

        if !keyboardMonitor.start(
            onAltTap: { [weak self] in
                guard let self else { return }
                guard SettingsManager.shared.autoSwitchEnabled else { return }
                if AutoSwitchPolicy.shouldDeferToRemoteClient {
                    // Удалёнка: текст конвертит офисный инстанс по реальным проброшенным символам
                    // (Fix №6). А здесь меняем СВОЮ раскладку — чтобы дальнейший ввод пошёл уже
                    // в правильной раскладке и не пришлось конвертить каждое слово.
                    LayoutSwitcher.switchToOpposite()
                    self.updateStatusIcon()
                    rslog("trigger: local layout switched, conversion handled by controlled instance")
                    return
                }
                let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                if AutoSwitchPolicy.secureInputActive {
                    rslog("trigger: blocked secure-input")
                    return
                }
                switch self.textConverter.convertSelectedText() {
                case .converted:
                    self.finishManualConversion(
                        frontID: frontID,
                        targetLayoutID: self.textConverter.lastManualTargetLayoutID
                    )
                    return
                case .failed:
                    rslog("trigger: selected-text conversion failed; layout unchanged")
                    return
                case .none:
                    break
                }
                let keys = self.keyboardMonitor.currentWordKeys
                let prevKeys = self.keyboardMonitor.prevWordKeys
                let bc = self.keyboardMonitor.boundaryCount
                if keys.isEmpty, prevKeys.isEmpty, self.keyboardMonitor.shouldReconvert {
                    if self.textConverter.reconvert(trailingSpaces: bc) {
                        self.keyboardMonitor.markConverted()
                        LayoutSwitcher.switchToOpposite()
                        self.updateStatusIcon()
                        self.learnFromUndo()
                    }
                    return
                }
                let outcome = self.textConverter.convert(wordKeys: keys, prevWordKeys: prevKeys, boundaryCount: bc)
                let allowSwitchedOnly = !AutoSwitchPolicy.isDeniedApp(frontID)
                if ManualTriggerDecision.shouldSwitchLayout(after: outcome, allowSwitchedOnly: allowSwitchedOnly) {
                    if outcome == .converted {
                        self.finishManualConversion(frontID: frontID, targetLayoutID: nil)
                    } else {
                        self.keyboardMonitor.markConverted()
                        LayoutSwitcher.switchToOpposite()
                        self.updateStatusIcon()
                    }
                    if outcome == .switchedOnly { rslog("trigger: switched layout only") }
                } else if outcome == .switchedOnly {
                    rslog("trigger: switched-only blocked denied-app \(frontID ?? "?")")
                }
            },
            onAltReconvert: { [weak self] in
                guard let self else { return }
                guard SettingsManager.shared.autoSwitchEnabled else { return }
                if AutoSwitchPolicy.shouldDeferToRemoteClient {
                    // Удалёнка: текст конвертит офисный инстанс по реальным проброшенным символам
                    // (Fix №6). А здесь меняем СВОЮ раскладку — чтобы дальнейший ввод пошёл уже
                    // в правильной раскладке и не пришлось конвертить каждое слово.
                    LayoutSwitcher.switchToOpposite()
                    self.updateStatusIcon()
                    rslog("trigger: local layout switched, conversion handled by controlled instance")
                    return
                }
                if self.textConverter.reconvert(trailingSpaces: self.keyboardMonitor.boundaryCount) {
                    self.keyboardMonitor.markConverted()
                    LayoutSwitcher.switchToOpposite()
                    self.updateStatusIcon()
                    self.learnFromUndo()
                }
            }
        ) {
            rslog("Event tap failed - will retry in 5s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.startMonitoring()
            }
            return
        }

        monitoringActive = true
        keyboardMonitor.onTokenCompleted = { [weak self] snapshot, proxy in
            self?.handleAutoConvert(snapshot, proxy: proxy) ?? .passThrough
        }
        keyboardMonitor.onCorrectionEdited = { [weak self] in
            self?.learnFromUndo()
        }
        keyboardMonitor.onEditingInvalidated = { [weak self] in
            self?.textConverter.clearState()
            self?.lastAutoConverted = nil
        }
        keyboardMonitor.onUserInput = { [weak self] in self?.caretIndicator?.userTyped() }  // issue #10
        updateStatusIcon()        // сначала выставляем флаг меню-бара, пока индикатора ещё нет
        syncCaretIndicator()      // затем создаём индикатор — без стартового ложного «попа»
        // Страховка к issue #9: системное уведомление о смене раскладки ненадёжно
        // (особенно через удалённый стол — на той машине оно часто не доходит), поэтому
        // флаг «застревает». Постоянный лёгкий опрос держит иконку в синхроне с системой.
        iconRefreshTimer?.invalidate()
        iconRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatusIcon() }
        }
        rslog("Monitoring started successfully")

        if SettingsManager.shared.perAppLayout {
            startPerAppLayout()
        }

        // Предлагаем автозагрузку и автозамену при первом запуске (по разу)
        offerLaunchAtLoginIfNeeded()
        offerAutoConvertIfNeeded()
    }

    private func finishManualConversion(frontID: String?, targetLayoutID: String?) {
        keyboardMonitor.markConverted()
        if let targetLayoutID {
            LayoutSwitcher.switchTo(layoutID: targetLayoutID)
        } else {
            LayoutSwitcher.switchToOpposite()
        }
        updateStatusIcon()
        guard let pair = textConverter.lastLearningPair else {
            lastAutoConverted = nil
            return
        }
        if SmartTokenizer.kind(of: pair.original) == .lexical,
           SmartTokenizer.kind(of: pair.converted) == .lexical {
            SettingsManager.shared.recordAdaptiveConfirmed(
                original: pair.original,
                converted: pair.converted
            )
            sessionNegativePairs.remove(learningKey(
                original: pair.original,
                converted: pair.converted,
                appBundleID: frontID
            ))
            rslog("learn: confirmed originalLen=\(pair.original.count) convertedLen=\(pair.converted.count)")
        }
        lastAutoConverted = AutoLearningEvent(
            original: pair.original,
            converted: pair.converted,
            appBundleID: frontID,
            at: Date()
        )
    }

    /// Smart auto-conversion runs synchronously while the active event tap owns the
    /// boundary. It only consumes a space after the complete replacement transaction
    /// has been posted; every early exit passes the original event through unchanged.
    private func handleAutoConvert(
        _ snapshot: TokenSnapshot,
        proxy: CGEventTapProxy
    ) -> TokenHandlingResult {
        rslog("auto: fired")
        // Reaching the next completed token without Backspace/Undo is a soft
        // positive signal for the previous correction.
        reinforcePreviousCorrectionIfNeeded()
        guard SettingsManager.shared.autoSwitchEnabled else { rslog("auto: bail master-off"); return .passThrough }
        guard SettingsManager.shared.autoConvert else { rslog("auto: bail flag-off"); return .passThrough }
        guard !AutoSwitchPolicy.secureInputActive else { rslog("auto: bail secure-input"); return .passThrough }
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        // Удалёнка: НЕ выходим сразу — прогоняем детектор по своему (чистому) буферу, и при
        // «не той раскладке» переключаем СВОЮ раскладку (конверсию делает инстанс на той стороне).
        let deferToRemote = SettingsManager.shared.remoteDesktopMode && AutoSwitchPolicy.isRemoteDesktopClient(frontID)
        if AutoSwitchPolicy.isDeniedApp(frontID) { rslog("auto: bail denied-app \(frontID ?? "?")"); return .passThrough }
        guard snapshot.focus.bundleID == frontID, snapshot.focus.processID == frontPID else {
            rslog("auto: bail focus-changed"); return .passThrough
        }

        let keys = snapshot.keys
        guard !keys.isEmpty else { rslog("auto: bail empty-keys"); return .passThrough }
        guard let pair = DynamicKeyMapping.convertKeys(keys) else { rslog("auto: bail convertKeys-nil"); return .passThrough }
        if AutoSwitchPolicy.isDeniedWord(pair.original, pair.converted) {
            rslog("auto: bail denied-word")
            return TokenHandlingResult(
                consumeBoundary: false,
                resolvedText: pair.original,
                resolvedLanguage: SmartTokenizer.languageHint(for: pair.original),
                wasConverted: false
            )
        }

        // Язык для детектора. Для проброшенного через удалёнку текста (все символы — char)
        // направление определяем по СКРИПТУ набранного, а не по раскладке офисной машины:
        // на офисе раскладка может не соответствовать тому, что напечатали на контроллере,
        // и тогда decide ошибочно даёт keep (это и есть «авто в удалёнке не работает»).
        let langs: (current: String, opposite: String)
        if keys.allSatisfy({ $0.char != nil }) {
            let typedIsCyrillic = pair.original.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
            langs = typedIsCyrillic ? ("ru", "en") : ("en", "ru")
        } else if let sourceLayoutID = snapshot.sourceLayoutID,
                  let l = LayoutSwitcher.languagePair(sourceLayoutID: sourceLayoutID) {
            langs = l
        } else {
            rslog("auto: bail langs-nil"); return .passThrough
        }

        let targetLang = langs.opposite
        let contextWords = snapshot.context.map(\.text)
        let beliefKey = self.beliefKey(for: snapshot.focus)
        let languageBelief = languageBeliefs[beliefKey] ?? snapshot.languageBelief
        let capsLock = keys.contains { $0.caps }
        let policy = AutoConvertPolicy(
            neverConvert: SettingsManager.shared.deniedWordsSet,
            alwaysConvert: SettingsManager.shared.alwaysConvertWordsSet
        )
        let isValidWord: (String, String) -> Bool = { word, lang in
            !word.isEmpty && Dict.isAvailable(lang) && Dict.isValidWord(word, lang: lang)
        }
        let languagePair = Set([String(langs.current.lowercased().prefix(2)), String(targetLang.lowercased().prefix(2))])
        let decision: AutoConvertDecision
        let confidenceMargin: Double
        let evidenceDescription: String
        if SettingsManager.shared.smartEngineV3,
           languagePair == Set(["en", "ru"]),
           let languageModel {
            let evaluation = LayoutDecoder.evaluate(
                typed: pair.original,
                converted: pair.converted,
                currentLanguage: langs.current,
                targetLanguage: targetLang,
                capsLock: capsLock,
                contextWords: contextWords,
                languageBelief: languageBelief,
                integrity: snapshot.integrity,
                policy: policy,
                adaptiveBias: { original, converted in
                    let persisted = SettingsManager.shared.adaptiveBias(
                        original: original,
                        converted: converted,
                        appBundleID: frontID
                    )
                    let sessionPenalty = self.sessionNegativePairs.contains(self.learningKey(
                        original: original,
                        converted: converted,
                        appBundleID: frontID
                    )) ? -12.0 : 0.0
                    return persisted + sessionPenalty
                },
                isConfirmed: { original, converted in
                    SettingsManager.shared.isAdaptiveConfirmed(
                        original: original,
                        converted: converted,
                        appBundleID: frontID
                    )
                },
                model: languageModel
            )
            decision = evaluation.decision
            confidenceMargin = evaluation.confidenceMargin
            evidenceDescription = evaluation.evidence.map(String.init(describing:)).joined(separator: ",")
        } else if SettingsManager.shared.smartEngineV2, languagePair == Set(["en", "ru"]) {
            let evaluation = SmartAutoConvertEngine.evaluate(
                typed: pair.original,
                converted: pair.converted,
                currentLanguage: langs.current,
                targetLanguage: targetLang,
                capsLock: capsLock,
                contextWords: contextWords,
                languageState: snapshot.languageState,
                policy: policy,
                adaptiveBias: { original, converted in
                    let persisted = SettingsManager.shared.adaptiveBias(
                        original: original,
                        converted: converted,
                        appBundleID: frontID
                    )
                    let sessionPenalty = self.sessionNegativePairs.contains(self.learningKey(
                        original: original,
                        converted: converted,
                        appBundleID: frontID
                    )) ? -12.0 : 0.0
                    return persisted + sessionPenalty
                },
                isValidWord: isValidWord
            )
            decision = evaluation.decision
            confidenceMargin = evaluation.confidenceMargin
            evidenceDescription = "v2"
        } else {
            let candidate = AutoConvertCandidateGenerator.bestCandidate(
                typed: pair.original,
                converted: pair.converted,
                targetLanguage: targetLang,
                isValidWord: isValidWord
            ) ?? AutoConvertCandidate(
                typedRaw: pair.original,
                convertedRaw: pair.converted,
                convertedWord: pair.converted,
                suffix: "",
                kind: .directWord
            )
            decision = LayoutDetector.decide(
                candidate: candidate,
                currentLang: langs.current,
                otherLang: targetLang,
                capsLock: capsLock,
                policy: policy,
                isCurrentWordValid: isValidWord(SmartTokenizer.lexicalCore(of: pair.original), langs.current),
                isConvertedWordValid: isValidWord(candidate.convertedWord, targetLang),
                context: AutoConvertContext(previousWord: contextWords.last)
            )
            confidenceMargin = decision.verdict == .switchToConverted ? 1 : -1
            evidenceDescription = "fallback"
        }
        let candidate = decision.candidate
        rslog("auto: len=\(pair.original.count) ctx=\(contextWords.count) rev=\(snapshot.editRevision) \(langs.current)/\(targetLang) verdict=\(decision.verdict) reason=\(decision.reason) evidence=\(evidenceDescription) kind=\(candidate.kind) wordLen=\(candidate.convertedWord.count) suffix=\(candidate.suffix.count) margin=\(String(format: "%.2f", confidenceMargin))")
        guard decision.verdict == .switchToConverted else {
            let finalizeToken: Bool
            if case .punctuation = snapshot.boundary, decision.verdict == .undecided {
                // It may be a layout letter inside an unfinished unknown word. Keep
                // collecting until a non-ambiguous boundary arrives.
                finalizeToken = false
            } else {
                finalizeToken = true
            }
            if finalizeToken {
                observeLanguage(langs.current, converted: false, key: beliefKey)
            }
            return TokenHandlingResult(
                consumeBoundary: false,
                finalizeToken: finalizeToken,
                resolvedText: pair.original,
                resolvedLanguage: langs.current,
                wasConverted: false
            )
        }

        if deferToRemote {
            // Удалёнка: текст конвертит офисный инстанс по реальным проброшенным символам.
            // Здесь меняем СВОЮ раскладку — чтобы дальнейший ввод пошёл уже в правильной.
            LayoutSwitcher.switchToOpposite()
            updateStatusIcon()
            observeLanguage(targetLang, converted: true, key: beliefKey)
            rslog("auto: local layout switched, conversion handled by controlled instance")
            return TokenHandlingResult(
                consumeBoundary: false,
                resolvedText: candidate.replacement,
                resolvedLanguage: targetLang,
                wasConverted: true
            )
        }

        let undeliveredCount = snapshot.boundary.isIncludedInTokenKeys ? 1 : 0
        let expectedSuffix = String(pair.original.dropLast(undeliveredCount))
        let validation = textContextReader.validate(
            expectedSuffix: expectedSuffix,
            focus: snapshot.focus
        )
        rslog("auto: ax-validation=\(validation) expectedLen=\(expectedSuffix.count)")
        if validation == .mismatch || (validation == .unavailable && snapshot.integrity != .clean) {
            return TokenHandlingResult(
                consumeBoundary: false,
                resolvedText: pair.original,
                resolvedLanguage: langs.current,
                wasConverted: false,
                invalidateSession: true
            )
        }

        let targetLayoutID = oppositeLayoutID(for: snapshot.sourceLayoutID)
        let transaction = ConversionTransaction(
            original: pair.original,
            replacement: candidate.replacement,
            boundary: snapshot.boundary,
            focus: snapshot.focus,
            sourceLayoutID: snapshot.sourceLayoutID,
            targetLayoutID: targetLayoutID,
            sequence: snapshot.sequence,
            editRevision: snapshot.editRevision,
            expectedOriginalSuffix: expectedSuffix,
            automatic: true
        )
        rslog("auto: transaction keys=\(keys.count) consume=\(snapshot.boundary.shouldConsumeOriginalEvent)")
        let execution = conversionCoordinator.execute(
            transaction,
            keyCount: snapshot.deliveredKeyCount,
            proxy: proxy
        )
        if execution == .committed {
            if let targetLayoutID {
                LayoutSwitcher.switchTo(layoutID: targetLayoutID)
            } else {
                LayoutSwitcher.switchToOpposite()
            }
            updateStatusIcon()
            observeLanguage(targetLang, converted: true, key: beliefKey)
            lastAutoConverted = AutoLearningEvent(
                original: pair.original,
                converted: candidate.replacement,
                appBundleID: frontID,
                at: Date()
            )
            return TokenHandlingResult(
                consumeBoundary: snapshot.boundary.shouldConsumeOriginalEvent,
                resolvedText: candidate.replacement,
                resolvedLanguage: targetLang,
                wasConverted: true
            )
        }
        if execution == .alreadyCommitted {
            return TokenHandlingResult(
                consumeBoundary: snapshot.boundary.shouldConsumeOriginalEvent,
                resolvedText: candidate.replacement,
                resolvedLanguage: targetLang,
                wasConverted: false
            )
        }
        return TokenHandlingResult(
            consumeBoundary: false,
            resolvedText: pair.original,
            resolvedLanguage: langs.current,
            wasConverted: false
        )
    }

    private func beliefKey(for focus: FocusedElementIdentity) -> String {
        [focus.bundleID ?? "?", String(focus.processID), focus.identifier ?? "*"].joined(separator: "\u{1f}")
    }

    private func observeLanguage(_ language: String, converted: Bool, key: String) {
        var belief = languageBeliefs[key] ?? .neutral
        belief.observe(language: language, weight: converted ? 1.4 : 1.0)
        languageBeliefs[key] = belief
        if languageBeliefs.count > 100 {
            languageBeliefs.removeAll(keepingCapacity: true)
            languageBeliefs[key] = belief
        }
    }

    private func oppositeLayoutID(for sourceLayoutID: String?) -> String? {
        guard let sourceLayoutID else { return nil }
        let settings = SettingsManager.shared
        let layouts = LayoutSwitcher.installedLayouts()
        let id1 = settings.layout1ID.isEmpty ? LayoutSwitcher.autoDetectID1(from: layouts) : settings.layout1ID
        let id2 = settings.layout2ID.isEmpty ? LayoutSwitcher.autoDetectID2(from: layouts) : settings.layout2ID
        return sourceLayoutID == id1 ? id2 : id1
    }

    /// Предлагает включить автозагрузку при первом запуске (один раз)
    private func offerLaunchAtLoginIfNeeded() {
        let settings = SettingsManager.shared
        guard !settings.launchAtLoginAsked else { return }
        settings.launchAtLoginAsked = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.wizardLaunchAtLoginTitle
        alert.informativeText = L10n.wizardLaunchAtLoginText
        alert.addButton(withTitle: L10n.wizardYes)
        alert.addButton(withTitle: L10n.wizardNo)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            settings.launchAtLogin = true
            rslog("User enabled launch at login")
        } else {
            rslog("User declined launch at login")
        }
    }

    /// Предлагает включить автозамену при первом запуске (один раз). Фича OFF по умолчанию,
    /// поэтому без явного предложения пользователь о ней не узнает.
    private func offerAutoConvertIfNeeded() {
        let settings = SettingsManager.shared
        guard !settings.autoConvertOffered else { return }
        settings.autoConvertOffered = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.onboardAutoConvertTitle
        alert.informativeText = L10n.onboardAutoConvertText
        alert.addButton(withTitle: L10n.wizardYes)
        alert.addButton(withTitle: L10n.wizardNo)

        if alert.runModal() == .alertFirstButtonReturn {
            settings.autoConvert = true
            rebuildMenu()  // синхронизировать галочку «Автоматическая конверсия» в меню
            rslog("User enabled auto-convert at onboarding")
        } else {
            rslog("User declined auto-convert at onboarding")
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuildMenu()
        // issue #9: иконка должна отражать раскладку и при СИСТЕМНОЙ смене (стандартный/
        // переопределённый хоткей), а не только при нашей конверсии. Слушаем системное
        // распределённое уведомление о смене источника ввода.
        // suspensionBehavior: .deliverImmediately — иначе для фонового menu-bar-приложения
        // распределённое уведомление коалесцируется/откладывается (App Nap / suspend), и
        // иконка после переключения глобусом 🌐 меняется с задержкой до нескольких секунд
        // (ждёт пробуждения или 2-секундного опроса). deliverImmediately обновляет флаг сразу.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemInputSourceChanged),
            name: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func systemInputSourceChanged() {
        updateStatusIcon()
        keyboardMonitor.soundArmed = true  // issue #7: следующая буква даст звук раскладки
    }

    /// Собирает меню статус-бара. Вызывается заново при смене языка интерфейса,
    /// иначе пункты меню остаются на старом языке.
    private func rebuildMenu() {
        let menu = NSMenu()

        // Строка версии (с dev-меткой для непубликуемых сборок) — чтобы было видно, какой билд.
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let devTag = Bundle.main.infoDictionary?["RSDevTag"] as? String ?? ""
        let verItem = NSMenuItem(title: "RuSwitcher \(ver)\(devTag)", action: nil, keyEquivalent: "")
        verItem.isEnabled = false
        menu.addItem(verItem)
        let healthItem = NSMenuItem(title: autoConversionHealthText(), action: nil, keyEquivalent: "")
        healthItem.isEnabled = false
        healthItem.tag = Self.healthItemTag
        menu.addItem(healthItem)
        menu.addItem(NSMenuItem.separator())

        // Список раскладок как в системном меню ввода: флаг + имя, галочка на текущей,
        // клик — переключение. Актуализируется в menuWillOpen при каждом открытии.
        for item in layoutMenuItems() { menu.addItem(item) }
        menu.addItem(NSMenuItem.separator())

        let autoItem = NSMenuItem(title: L10n.menuAutoSwitch, action: #selector(toggleAutoSwitch), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = SettingsManager.shared.autoSwitchEnabled ? .on : .off
        menu.addItem(autoItem)

        let autoConvertItem = NSMenuItem(title: L10n.menuAutoConvert, action: #selector(toggleAutoConvert), keyEquivalent: "")
        autoConvertItem.target = self
        autoConvertItem.state = SettingsManager.shared.autoConvert ? .on : .off
        menu.addItem(autoConvertItem)

        let keySoundItem = NSMenuItem(title: L10n.menuKeySound, action: #selector(toggleKeySound), keyEquivalent: "")
        keySoundItem.target = self
        keySoundItem.state = SettingsManager.shared.keySound ? .on : .off
        menu.addItem(keySoundItem)

        let caretFlagItem = NSMenuItem(title: L10n.menuCaretFlag, action: #selector(toggleCaretFlag), keyEquivalent: "")
        caretFlagItem.target = self
        caretFlagItem.state = SettingsManager.shared.caretFlag ? .on : .off
        menu.addItem(caretFlagItem)

        // Единый стиль меню-бара (Sequoia): монохромная плашка вместо цветного флага.
        let monoIconItem = NSMenuItem(title: L10n.menuMonoIcon, action: #selector(toggleMonoIcon), keyEquivalent: "")
        monoIconItem.target = self
        monoIconItem.state = SettingsManager.shared.monochromeIcon ? .on : .off
        menu.addItem(monoIconItem)

        // Режим удалённого стола отложен в 2.5 — тумблер скрыт за флагом (для тестирования).
        if SettingsManager.shared.showRemoteDesktopBeta {
            let remoteDesktopItem = NSMenuItem(title: L10n.menuRemoteDesktop, action: #selector(toggleRemoteDesktop), keyEquivalent: "")
            remoteDesktopItem.target = self
            remoteDesktopItem.state = SettingsManager.shared.remoteDesktopMode ? .on : .off
            menu.addItem(remoteDesktopItem)
        }

        menu.addItem(NSMenuItem.separator())

        let permItem = NSMenuItem(title: L10n.menuCheckPermissions, action: #selector(recheckPermissions), keyEquivalent: "")
        permItem.target = self
        menu.addItem(permItem)

        let settingsItem = NSMenuItem(title: L10n.menuSettings, action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(title: L10n.menuCheckUpdates, action: #selector(checkUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let donateItem = NSMenuItem(title: L10n.menuDonate, action: #selector(openDonate), keyEquivalent: "")
        donateItem.target = self
        menu.addItem(donateItem)

        let starItem = NSMenuItem(title: L10n.menuStarOnGithub, action: #selector(openGitHub), keyEquivalent: "")
        starItem.target = self
        menu.addItem(starItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: L10n.menuQuit, action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
        rslog("Menu (re)built with \(menu.items.count) items")
    }

    // MARK: - Layout list in menu

    /// Метка пунктов-раскладок, чтобы находить и обновлять их группу в меню.
    private static let layoutItemTag = 741

    /// Пункты списка раскладок: «флаг + локализованное имя», галочка на текущей.
    private func layoutMenuItems() -> [NSMenuItem] {
        let currentID = LayoutSwitcher.currentLayoutID()
        return LayoutSwitcher.installedLayouts().map { source in
            let id = LayoutSwitcher.sourceID(source)
            let badge = LayoutSwitcher.languageCode(source).map(Self.flagBadge(forLanguage:))
            let title = [badge, LayoutSwitcher.sourceName(source)].compactMap { $0 }.joined(separator: " ")
            let item = NSMenuItem(title: title, action: #selector(selectLayout(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = (id == currentID) ? .on : .off
            item.tag = Self.layoutItemTag
            return item
        }
    }

    /// Пересобирает группу раскладок при каждом открытии меню: состав и галочка должны
    /// отражать систему на момент клика (раскладки добавляют/удаляют в настройках ОС,
    /// а текущую меняют и мимо нас — системным хоткеем).
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        menu.items.first(where: { $0.tag == Self.healthItemTag })?.title = autoConversionHealthText()
        let insertAt = menu.items.firstIndex { $0.tag == Self.layoutItemTag } ?? 2
        for old in menu.items where old.tag == Self.layoutItemTag { menu.removeItem(old) }
        for (offset, item) in layoutMenuItems().enumerated() {
            menu.insertItem(item, at: insertAt + offset)
        }
    }

    @objc private func selectLayout(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              id != LayoutSwitcher.currentLayoutID() else { return }
        LayoutSwitcher.switchTo(layoutID: id)
        // Явная смена раскладки делает набранный буфер неактуальным — как при per-app restore.
        keyboardMonitor.markConverted()
        textConverter.clearState()
        updateStatusIcon()
    }

    func updateStatusIcon() {
        let flag = flagForCurrentLayout()
        // Каретку дёргаем ТОЛЬКО при реальной смене раскладки: updateStatusIcon зовётся ещё и
        // 2-секундным опросом-страховкой, иначе флаг у каретки выскакивал бы каждые 2с.
        // Сравниваем по флагу-идентичности, а не по title — в монохромном режиме title пуст.
        let changed = lastFlagShown != flag
        lastFlagShown = flag
        if SettingsManager.shared.monochromeIcon {
            statusItem.button?.title = ""
            statusItem.button?.image = badgeImage(for: currentBadgeLabel())
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = flag
        }
        statusItem.button?.toolTip = autoConversionHealthText()
        if changed { caretIndicator?.layoutChanged() }
    }

    private func autoConversionHealthText() -> String {
        guard SettingsManager.shared.autoSwitchEnabled, SettingsManager.shared.autoConvert else {
            return L10n.statusDisabled
        }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else { return L10n.statusPermissions }
        if AutoSwitchPolicy.secureInputActive { return L10n.statusSecureInput }
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if AutoSwitchPolicy.isDeniedApp(bundleID) { return L10n.statusDeniedApp }
        return L10n.statusActive
    }

    /// Подпись монохромной плашки — родная аббревиатура языка, как у системного индикатора.
    private func currentBadgeLabel() -> String {
        if let lang = LayoutSwitcher.currentLanguageCode()?.lowercased(), !lang.isEmpty {
            let code = String(lang.prefix(2))
            let labels: [String: String] = [
                "ru": "РУ", "en": "EN", "uk": "УК", "be": "БЕ",
                "de": "DE", "fr": "FR", "es": "ES", "it": "IT",
                "pt": "PT", "pl": "PL", "ja": "あ", "zh": "拼", "ko": "한",
                "he": "עב",   // иврит (3.0)
                "el": "ΕΛ", "bg": "БГ", "hy": "ՀԱ", "ka": "ქა",
            ]
            return labels[code] ?? code.uppercased()
        }
        // Язык раскладки недоступен — мягкий фолбэк по ID (как у flagForCurrentLayout).
        let id = LayoutSwitcher.currentLayoutID().lowercased()
        return (id.contains("russian") || id.hasSuffix(".ru")) ? "РУ" : "EN"
    }

    /// Монохромная плашка в стиле системного индикатора раскладки Sequoia: скруглённый
    /// прямоугольник с «выбитыми» буквами. Template-image — система сама красит её под
    /// светлый/тёмный меню-бар и пользовательский тинт.
    private func badgeImage(for label: String) -> NSImage {
        if let cached = badgeCache[label] { return cached }
        let font = NSFont.systemFont(ofSize: 10, weight: .bold)
        let textSize = label.size(withAttributes: [.font: font])
        let size = NSSize(width: max(ceil(textSize.width) + 8, 20), height: 15)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5).fill()
            // Буквы «выбиваются» из плашки (прозрачные), как у системного индикатора.
            NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
            label.draw(at: NSPoint(x: (rect.width - textSize.width) / 2,
                                   y: (rect.height - textSize.height) / 2),
                       withAttributes: [.font: font, .foregroundColor: NSColor.white])
            return true
        }
        image.isTemplate = true
        badgeCache[label] = image
        return image
    }

    /// Флаг текущей раскладки по коду языка (BCP-47), а не по подстроке в ID — иначе
    /// "Belarusian" ложно матчил "ru", а любая не-RU/EN пара показывалась как 🇺🇸.
    func flagForCurrentLayout() -> String {
        guard let lang = LayoutSwitcher.currentLanguageCode()?.lowercased(), !lang.isEmpty else {
            // Язык раскладки недоступен — мягкий фолбэк по ID.
            let id = LayoutSwitcher.currentLayoutID().lowercased()
            return (id.contains("russian") || id.hasSuffix(".ru")) ? "🇷🇺" : "🇺🇸"
        }
        return Self.flagBadge(forLanguage: lang)
    }

    /// Единый бейдж раскладки для иконки меню-бара и списка раскладок в меню:
    /// «🇷🇺» для известных языков, иначе код («EL»).
    private static func flagBadge(forLanguage lang: String) -> String {
        let code = String(lang.lowercased().prefix(2))
        let flags: [String: String] = [
            "ru": "🇷🇺", "en": "🇺🇸", "uk": "🇺🇦", "be": "🇧🇾",
            "de": "🇩🇪", "fr": "🇫🇷", "es": "🇪🇸", "it": "🇮🇹",
            "pt": "🇵🇹", "pl": "🇵🇱", "ja": "🇯🇵", "zh": "🇨🇳", "ko": "🇰🇷",
            "he": "🇮🇱",   // иврит (3.0). Арабский в 3.1 — глифом ع (флага нет), см. дизайн 3.0.
        ]
        return flags[code] ?? code.uppercased()
    }

    /// issue #10: создаёт/освобождает индикатор каретки по флагу настроек. Создаётся лениво,
    /// только когда фича включена И мониторинг запущен (нужны разрешения).
    private func syncCaretIndicator() {
        keyboardMonitor.caretFlagEnabled = SettingsManager.shared.caretFlag   // гейт диспатча onUserInput
        if SettingsManager.shared.caretFlag, monitoringActive {
            if caretIndicator == nil {
                let ci = CaretIndicator()
                ci.flagProvider = { [weak self] in self?.flagForCurrentLayout() ?? "" }
                caretIndicator = ci
            }
        } else {
            caretIndicator?.teardown()
            caretIndicator = nil
        }
    }

    // MARK: - Actions

    @objc private func toggleAutoSwitch(_ sender: NSMenuItem) {
        SettingsManager.shared.autoSwitchEnabled.toggle()
        let enabled = SettingsManager.shared.autoSwitchEnabled
        sender.state = enabled ? .on : .off
        settingsController.updateAutoSwitchState(enabled)
    }

    @objc private func toggleAutoConvert(_ sender: NSMenuItem) {
        SettingsManager.shared.autoConvert.toggle()
        sender.state = SettingsManager.shared.autoConvert ? .on : .off
    }

    @objc private func toggleKeySound(_ sender: NSMenuItem) {
        SettingsManager.shared.keySound.toggle()
        sender.state = SettingsManager.shared.keySound ? .on : .off
    }

    @objc private func toggleCaretFlag(_ sender: NSMenuItem) {
        SettingsManager.shared.caretFlag.toggle()
        sender.state = SettingsManager.shared.caretFlag ? .on : .off
        settingsController.updateCaretFlagState(SettingsManager.shared.caretFlag)
        syncCaretIndicator()   // создать/снести индикатор и обновить гейт onUserInput
    }

    @objc private func toggleMonoIcon(_ sender: NSMenuItem) {
        SettingsManager.shared.monochromeIcon.toggle()
        sender.state = SettingsManager.shared.monochromeIcon ? .on : .off
        updateStatusIcon()   // перерисовать в новом стиле сразу
    }

    @objc private func toggleRemoteDesktop(_ sender: NSMenuItem) {
        SettingsManager.shared.remoteDesktopMode.toggle()
        sender.state = SettingsManager.shared.remoteDesktopMode ? .on : .off
        reconfigureTap()  // уровень event tap зависит от режима
    }

    /// Пересоздаёт event tap и, если создание не удалось (например, session-tap отклонён),
    /// ретраит — иначе тумблер «вкл», а tap'а нет, и приложение молча не реагирует на триггер.
    private func reconfigureTap() {
        guard !keyboardMonitor.reconfigure() else { return }
        rslog("reconfigure failed (tap denied) — retry in 3s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.keyboardMonitor.reconfigure() == false { rslog("reconfigure retry failed") }
        }
    }

    @objc private func recheckPermissions() {
        runPermissionWizard(interactive: true)
    }

    @objc private func openSettings() {
        settingsController.showWindow()
    }

    @objc private func checkUpdates() {
        UpdateChecker.checkNow()
    }

    @objc private func openDonate() {
        if let url = URL(string: SettingsManager.shared.donateURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openGitHub() {
        if let url = URL(string: SettingsManager.githubURL) {
            NSWorkspace.shared.open(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Не теряем буфер обмена в 2-секундном окне отложенного восстановления
        // (актуально и при само-обновлении, которое завершает процесс).
        textConverter.flushPendingClipboardRestore()
    }

    @objc private func quit() {
        textConverter.flushPendingClipboardRestore()
        perAppLayoutManager.stop()
        keyboardMonitor.stop()
        NSApplication.shared.terminate(nil)
    }
}
