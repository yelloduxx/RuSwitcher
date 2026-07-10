import AppKit
import CoreGraphics
import Foundation
import RuSwitcherCore

/// Маркер для симулированных событий — KeyboardMonitor их игнорирует
let kRuSwitcherEventMarker: Int64 = 0x52555300

/// Выделенная очередь для файлового I/O лога — чтобы запись на диск не блокировала
/// поток обработки событий (event tap висит на главном run loop, а лог пишется
/// для каждого нажатия при включённом debug).
private let rsLogQueue = DispatchQueue(label: "com.ruswitcher.log")

func rslog(_ msg: String) {
    // Thread-safe: читаем UserDefaults напрямую (без MainActor)
    guard UserDefaults.standard.bool(forKey: "com.ruswitcher.debugLog") else { return }

    let line = "\(Date()): \(msg)\n"
    rsLogQueue.async {
        let logDir = NSHomeDirectory() + "/Library/Logs/RuSwitcher"
        let path = logDir + "/ruswitcher.log"

        // Создаём директорию если нет
        if !FileManager.default.fileExists(atPath: logDir) {
            try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        }

        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            // Ротация: если > 5MB — обрезаем
            if handle.offsetInFile > 5_000_000 {
                handle.truncateFile(atOffset: 0)
                handle.write("--- Log rotated ---\n".data(using: .utf8)!)
            }
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
        }
    }
}

/// Конфигурация клавиши-триггера (читается из настроек, кэшируется в KeyboardMonitor).
struct TriggerConfig {
    enum Kind {
        case modifier(mask: CGEventFlags, left: UInt16, right: UInt16)
        /// Комбо из двух модификаторов (например ⌘+⇧). Детект по флагам: оба зажаты без
        /// посторонних → отпущены все без клавиш между. Сторона (left/right) не важна.
        case combo(CGEventFlags, CGEventFlags)
        case capsLock
    }
    let kind: Kind
    let rightOnly: Bool
    let doubleTap: Bool

    var isCapsLock: Bool { if case .capsLock = kind { return true } else { return false } }

    static func current() -> TriggerConfig {
        let s = SettingsManager.shared
        let kind: Kind
        switch s.triggerKey {
        case "command": kind = .modifier(mask: .maskCommand, left: KC.leftCommand, right: KC.rightCommand)
        case "control": kind = .modifier(mask: .maskControl, left: KC.leftControl, right: KC.rightControl)
        case "shift":   kind = .modifier(mask: .maskShift,   left: KC.leftShift,   right: KC.rightShift)
        // Комбо двух модификаторов (issue #12: привычный по Windows стиль Alt+Shift и т.п.).
        case "command+shift":  kind = .combo(.maskCommand, .maskShift)
        case "control+shift":  kind = .combo(.maskControl, .maskShift)
        case "command+option": kind = .combo(.maskCommand, .maskAlternate)
        case "control+option": kind = .combo(.maskControl, .maskAlternate)
        // ТЕХДОЛГ: нативный Caps Lock убран из UI (нестабилен — HID-дебаунс/тоггл,
        // нужен HID-драйвер уровня Karabiner). Код consume-пути оставлен на будущее.
        case "capsLock": kind = .capsLock
        default:        kind = .modifier(mask: .maskAlternate, left: KC.leftOption, right: KC.rightOption)
        }
        return TriggerConfig(kind: kind, rightOnly: s.triggerRightOnly, doubleTap: s.triggerDoubleTap)
    }
}

final class KeyboardMonitor: @unchecked Sendable {
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var inputSession = InputSession(contextLimit: 5)
    private var observedFrontmostProcessID: pid_t?

    /// Длина текущего набираемого слова
    var currentWordLength: Int { inputSession.currentKeys.count }
    /// Длина слова до последнего пробела
    private(set) var wordBeforeBoundaryLength = 0
    /// Сколько пробелов после слова (только пробелы, не enter/стрелки)
    private(set) var boundaryCount = 0
    /// Были ли реальные нажатия после последней конвертации?
    private(set) var keysTypedSinceConversion = true
    var shouldReconvert: Bool { !keysTypedSinceConversion }

    /// Нажатия набираемого слова — для движка перепечатки (без буфера обмена)
    var currentWordKeys: [TypedKey] { inputSession.currentKeys }
    /// Нажатия слова перед последней границей-пробелом
    private(set) var prevWordKeys: [TypedKey] = []
    /// Фронтмост-приложение на момент границы слова — чтобы авто-путь не перепечатал
    /// в другое поле, если фокус уехал (Cmd-Tab/Spotlight) без клика/Tab.
    private(set) var prevWordBundleID: String?
    /// issue #7: взводится при смене раскладки → на первой букве играем звук раскладки.
    var soundArmed = false

    private var onAltTap: (() -> Void)?
    private var onAltReconvert: (() -> Void)?
    /// Авто-конвертация получает неизменяемый снимок прямо на границе токена.
    /// Возвращаемое значение сообщает active event tap, нужно ли пропустить границу.
    var onTokenCompleted: ((TokenSnapshot, CGEventTapProxy) -> TokenHandlingResult)?
    /// Immediate editing of the last automatic correction is a local negative
    /// learning signal. Repeated signals make the rule persistent.
    var onCorrectionEdited: (() -> Void)?
    var onEditingInvalidated: (() -> Void)?
    /// issue #10: любой ввод/клик пользователя — чтобы спрятать флаг у каретки во время печати.
    var onUserInput: (() -> Void)?
    /// issue #10: включена ли фича флага-у-каретки. Гейтит диспатч onUserInput на горячем пути,
    /// чтобы при выключенной фиче (по умолчанию) не будить main-очередь на каждом нажатии.
    var caretFlagEnabled = false

    // Конфиг триггера (кэш; обновляется в start/reconfigure)
    private var triggerConfig = TriggerConfig.current()

    // Детект соло-тапа модификатора
    private var triggerArmed = false
    private var triggerPressTime: Date?
    // Для двойного тапа
    private var lastTapTime: Date?
    private let tapWindow: TimeInterval = 0.4

    func start(
        onAltTap: @escaping () -> Void,
        onAltReconvert: @escaping () -> Void
    ) -> Bool {
        self.onAltTap = onAltTap
        self.onAltReconvert = onAltReconvert

        let precheck = CGPreflightListenEventAccess()
        rslog("Preflight check = \(precheck)")
        if !precheck {
            rslog("Requesting access...")
            CGRequestListenEventAccess()
        }

        triggerConfig = TriggerConfig.current()
        rslog("Attempting to create event tap... (trigger=\(SettingsManager.shared.triggerKey) capsLock=\(triggerConfig.isCapsLock))")
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)

        // Smart auto-conversion consumes a space only when it is replayed as part of
        // one ordered conversion transaction. Otherwise the tap remains listen-only.
        let needsActiveTap = triggerConfig.isCapsLock || SettingsManager.shared.autoConvert
        let options: CGEventTapOptions = needsActiveTap ? .defaultTap : .listenOnly

        // Режим удалённого стола: session-уровень видит проброшенные Screen Sharing
        // нажатия (они инжектятся через CGEventPost, а HID-tap их не видит).
        let tapLocation: CGEventTapLocation =
            SettingsManager.shared.remoteDesktopMode ? .cgSessionEventTap : .cghidEventTap
        rslog("Tap location: \(SettingsManager.shared.remoteDesktopMode ? "session (remote desktop)" : "hid")")

        guard let tap = CGEvent.tapCreate(
            tap: tapLocation,
            place: .tailAppendEventTap,
            options: options,
            eventsOfInterest: mask,
            callback: keyboardCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            rslog("FAILED to create event tap - no permission")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        rslog("Event tap created and enabled successfully")
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Перезапускает tap с актуальным конфигом триггера. Нужен при смене настройки —
    /// особенно при переключении на/с Caps Lock, т.к. меняется режим tap (consume).
    @discardableResult
    func reconfigure() -> Bool {
        guard let t = onAltTap, let r = onAltReconvert else { return false }
        rslog("Reconfiguring trigger…")
        stop()
        return start(onAltTap: t, onAltReconvert: r)
    }

    func markConverted() {
        wordBeforeBoundaryLength = 0
        boundaryCount = 0
        prevWordKeys = []
        inputSession.reset()
        keysTypedSinceConversion = false
    }

    private func fullReset(invalidated: Bool = false) {
        wordBeforeBoundaryLength = 0
        boundaryCount = 0
        prevWordKeys = []
        if invalidated {
            inputSession.invalidate(clearContext: true)
        } else {
            inputSession.reset()
        }
    }

    private func completeToken(boundary: InputBoundary, proxy: CGEventTapProxy) -> TokenHandlingResult {
        guard !inputSession.currentKeys.isEmpty else { return .passThrough }
        let app = NSWorkspace.shared.frontmostApplication
        let focus = FocusedElementIdentity(
            processID: app?.processIdentifier ?? 0,
            bundleID: app?.bundleIdentifier,
            identifier: app.flatMap { focusedElementIdentifier(processID: $0.processIdentifier) }
        )
        guard let snapshot = inputSession.snapshot(boundary: boundary, focus: focus) else {
            return .passThrough
        }
        guard inputSession.beginCommit(expectedRevision: snapshot.editRevision) else {
            rslog("input-session: stale snapshot rejected rev=\(snapshot.editRevision)")
            inputSession.invalidate(clearContext: true)
            return .passThrough
        }

        let result = SettingsManager.shared.autoConvert
            ? (onTokenCompleted?(snapshot, proxy) ?? .passThrough)
            : .passThrough
        let resolved = result.resolvedText ?? snapshot.producedText
        if result.invalidateSession {
            inputSession.invalidate(clearContext: true)
        } else if result.finalizeToken {
            inputSession.complete(
                resolvedText: resolved,
                language: result.resolvedLanguage ?? resolved.flatMap(SmartTokenizer.languageHint),
                wasConverted: result.wasConverted
            )
        }
        if result.wasConverted { keysTypedSinceConversion = false }
        return result
    }

    private func focusedElementIdentifier(processID: pid_t) -> String? {
        let app = AXUIElementCreateApplication(processID)
        var focusedRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRaw
        ) == .success, let focusedRaw else { return nil }
        let element = focusedRaw as! AXUIElement
        var identifierRaw: AnyObject?
        if AXUIElementCopyAttributeValue(
            element,
            kAXIdentifierAttribute as CFString,
            &identifierRaw
        ) == .success, let identifier = identifierRaw as? String, !identifier.isEmpty {
            return identifier
        }
        return "axhash:\(CFHash(element))"
    }

    /// Сброс буфера при клике мышью — иначе backspace перепечатки сотрёт не то
    /// (курсор мог уехать в другое место).
    fileprivate func resetBuffersOnClick() {
        triggerArmed = false
        lastTapTime = nil
        keysTypedSinceConversion = true
        if caretFlagEnabled { DispatchQueue.main.async { [weak self] in self?.onUserInput?() } }   // issue #10: клик прячет флаг у каретки
        fullReset(invalidated: true)
        onEditingInvalidated?()
    }

    fileprivate func recoverAfterTapDisabled(reason: CGEventType) {
        rslog("Event tap recovered after disable type=\(reason.rawValue); input state reset")
        triggerArmed = false
        triggerPressTime = nil
        lastTapTime = nil
        keysTypedSinceConversion = true
        fullReset(invalidated: true)
        onEditingInvalidated?()
    }

    // MARK: - Event Handling

    fileprivate func handleKeyDown(
        keyCode: UInt16,
        flags: CGEventFlags,
        proxy: CGEventTapProxy,
        char: Character? = nil,
        producedCharacter: Character? = nil,
        producedText: String? = nil,
        sourceLayoutID: String? = nil
    ) -> Bool {
        let frontmostProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let previous = observedFrontmostProcessID,
           let current = frontmostProcessID,
           previous != current {
            rslog("input-session: frontmost process changed; state invalidated")
            keysTypedSinceConversion = true
            fullReset(invalidated: true)
            onEditingInvalidated?()
        }
        observedFrontmostProcessID = frontmostProcessID
        triggerArmed = false
        lastTapTime = nil
        let hadRecentCorrection = !keysTypedSinceConversion
        let passiveBoundaryAfterConversion = hadRecentCorrection
            && currentWordLength == 0
            && (keyCode == KC.space || keyCode == KC.enter || keyCode == KC.tab)
        let editsRecentCorrection = !keysTypedSinceConversion && keyCode == KC.backspace
        if !passiveBoundaryAfterConversion { keysTypedSinceConversion = true }
        if editsRecentCorrection { onCorrectionEdited?() }
        if caretFlagEnabled { DispatchQueue.main.async { [weak self] in self?.onUserInput?() } }   // issue #10: спрятать флаг при печати

        // Удалёнка: Screen Sharing шлёт проброшенные символы как keyCode 0 + юникод. Перехватываем
        // ТОЛЬКО в режиме удалённого стола. КРИТИЧНО: локально keyCode 0 — это обычная клавиша
        // 'a' (и 'ф' в ЙЦУКЕН), её нельзя глотать, иначе ломается локальная конверсия слов с
        // этими буквами. В локальном режиме сюда не заходим — буква идёт обычным путём ниже.
        if SettingsManager.shared.remoteDesktopMode, keyCode == 0 {
            // ⌘A/⌘C/⌘X и т.п. по удалёнке прилетают как символ 'a' (keyCode 0) с флагом Cmd.
            // НЕ копим их в буфер: иначе ⌘A добавляет лишнюю «ф» (keyCode 0 = 'ф' в ЙЦУКЕН)
            // и рушит выделение. Сбрасываем буфер — триггер уйдёт по clipboard-пути (выделение).
            // Локальный аналог этого guard — ниже, на ветке модификаторов (PR #13).
            let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate])
            if !modifiers.isEmpty { fullReset(invalidated: true); onEditingInvalidated?(); return false }
            if let ch = char { return handleForwardedChar(ch, proxy: proxy) }
            return false
        }

        // Структурные клавиши обрабатываем ВСЕГДА, даже если в flags остался
        // «грязный» модификатор (stale .maskAlternate и т.п.) — иначе счётчик
        // слова не сбрасывается и конвертация захватывает лишние символы.

        // Space is a non-ambiguous boundary; punctuation is handled below after its
        // physical key has been included in candidate generation.
        if keyCode == KC.space {
            if currentWordLength > 0 {
                wordBeforeBoundaryLength = currentWordLength
                boundaryCount = 1
                prevWordKeys = currentWordKeys
                prevWordBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                return completeToken(boundary: .space(count: 1), proxy: proxy).consumeBoundary
            } else {
                boundaryCount += 1
                inputSession.noteExternalEvent()
            }
            return false
        }

        // Enter and Tab are native app actions, so they are never consumed. The word
        // is still evaluated synchronously before the event is passed through.
        if keyCode == KC.enter || keyCode == KC.tab {
            if currentWordLength > 0 {
                wordBeforeBoundaryLength = currentWordLength
                prevWordKeys = currentWordKeys
                prevWordBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                _ = completeToken(boundary: keyCode == KC.enter ? .enter : .tab, proxy: proxy)
            }
            fullReset(invalidated: true)
            onEditingInvalidated?()
            // Native Enter/Tab may submit text or move focus, so an undo transaction
            // must never run against the next field.
            keysTypedSinceConversion = true
            return false
        }

        // Стрелки (Left…Up) — полный сброс
        if (keyCode >= KC.left && keyCode <= KC.up)
            || [KC.home, KC.end, KC.pageUp, KC.pageDown].contains(keyCode) {
            fullReset(invalidated: true)
            onEditingInvalidated?()
            return false
        }

        let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate])

        // Modified deletion changes an unknown number of characters in the target
        // editor. Treating it as one Backspace is the classic stale-buffer bug.
        if keyCode == KC.backspace || keyCode == KC.deleteForward {
            if !modifiers.isEmpty || keyCode == KC.deleteForward {
                inputSession.handle(.modifiedDeletion)
                wordBeforeBoundaryLength = 0
                boundaryCount = 0
                prevWordKeys = []
                onEditingInvalidated?()
            } else {
                inputSession.handle(.plainBackspace)
                if currentWordLength == 0 {
                    wordBeforeBoundaryLength = 0
                    boundaryCount = 0
                    prevWordKeys = []
                }
            }
            return false
        }

        // (Cmd+A, Cmd+C, Cmd+X и т.п.) могло изменить выделение — сбрасываем наш буфер.
        if !modifiers.isEmpty {
            let event: InputEvent
            if flags.contains(.maskCommand), keyCode == KC.letterZ {
                event = .undo
            } else if flags.contains(.maskCommand), [KC.letterA, KC.letterC, KC.letterV, KC.letterX].contains(keyCode) {
                event = .clipboardCommand
            } else {
                event = .navigation
            }
            if event == .undo, hadRecentCorrection { onCorrectionEdited?() }
            inputSession.handle(event)
            wordBeforeBoundaryLength = 0
            boundaryCount = 0
            prevWordKeys = []
            onEditingInvalidated?()
            return false
        }

        if KeyMapping.keycodeToEN[keyCode] != nil {
            inputSession.append(TypedKey(
                keyCode: keyCode,
                shift: flags.contains(.maskShift),
                caps: flags.contains(.maskAlphaShift),
                producedCharacter: producedCharacter,
                producedText: producedText,
                sourceLayoutID: sourceLayoutID
            ))
            wordBeforeBoundaryLength = 0
            boundaryCount = 0
            prevWordKeys = []
            playLayoutSoundIfArmed()
            if SettingsManager.shared.autoConvert,
               let producedCharacter,
               isTerminalPunctuation(producedCharacter),
               !PhysicalBoundaryPolicy.shouldDeferTerminalPunctuation(
                    produced: producedCharacter,
                    oppositeLayoutCharacter: DynamicKeyMapping.oppositeCharacterForKeycode(
                        keyCode,
                        shift: flags.contains(.maskShift),
                        caps: flags.contains(.maskAlphaShift),
                        sourceLayoutID: sourceLayoutID
                    )
               ),
               currentWordLength > 1 {
                wordBeforeBoundaryLength = currentWordLength
                prevWordKeys = currentWordKeys
                prevWordBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                return completeToken(boundary: .punctuation(String(producedCharacter)), proxy: proxy).consumeBoundary
            }
        } else {
            // Esc, F-клавиши, и т.д. — полный сброс
            fullReset(invalidated: true)
            onEditingInvalidated?()
        }
        return false
    }

    /// Обработка символа, проброшенного через удалённый стол (keyCode 0 + юникод).
    /// Работаем по самому символу: пробел — граница слова, backspace — откат,
    /// буква — кладём реальный символ в буфер (конверсия пойдёт по нему, см. convertKeys).
    private func handleForwardedChar(_ ch: Character, proxy: CGEventTapProxy) -> Bool {
        // Пробел — граница слова (как локальный keyCode space)
        if ch == " " {
            if currentWordLength > 0 {
                wordBeforeBoundaryLength = currentWordLength
                boundaryCount = 1
                prevWordKeys = currentWordKeys
                prevWordBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                return completeToken(boundary: .space(count: 1), proxy: proxy).consumeBoundary
            } else {
                boundaryCount += 1
                inputSession.noteExternalEvent()
            }
            return false
        }
        // Перенос строки / таб — полный сброс
        if ch == "\n" || ch == "\r" || ch == "\t" {
            fullReset(invalidated: true)
            onEditingInvalidated?()
            return false
        }
        // Backspace / Delete — откат одной буквы
        if ch == "\u{8}" || ch == "\u{7f}" {
            if currentWordLength > 0 {
                inputSession.handle(.plainBackspace)
            } else {
                fullReset(invalidated: true)
                onEditingInvalidated?()
            }
            return false
        }
        // Remote payload carries the actual character; punctuation is retained so
        // candidate generation can distinguish a suffix from a layout letter.
        if !ch.isWhitespace {
            inputSession.append(TypedKey(
                keyCode: 0,
                shift: ch.isUppercase,
                caps: false,
                char: ch,
                producedCharacter: ch
            ))
            wordBeforeBoundaryLength = 0
            boundaryCount = 0
            prevWordKeys = []
            playLayoutSoundIfArmed()
            let remoteOppositeCharacter: Character? = {
                let preceding = inputSession.currentKeys.dropLast().compactMap(\.char)
                let sourceLooksCyrillic = preceding.contains { character in
                    character.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
                }
                return sourceLooksCyrillic ? KeyMapping.ruToEn[ch] : KeyMapping.enToRu[ch]
            }()
            if SettingsManager.shared.autoConvert,
               isTerminalPunctuation(ch),
               !PhysicalBoundaryPolicy.shouldDeferTerminalPunctuation(
                    produced: ch,
                    oppositeLayoutCharacter: remoteOppositeCharacter
               ),
               currentWordLength > 1 {
                wordBeforeBoundaryLength = currentWordLength
                prevWordKeys = currentWordKeys
                prevWordBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                return completeToken(boundary: .punctuation(String(ch)), proxy: proxy).consumeBoundary
            }
            return false
        }
        return false
    }

    private func isTerminalPunctuation(_ char: Character) -> Bool {
        Set(".,!?;:)]}\"'»…”’").contains(char)
    }

    /// issue #7: на первой букве после смены раскладки даём короткий звук, зависящий от
    /// раскладки — слышно, в какой раскладке начал печатать. Опц., по умолчанию выключено.
    private func playLayoutSoundIfArmed() {
        guard soundArmed, SettingsManager.shared.keySound else { return }
        soundArmed = false
        let sources = LayoutSwitcher.installedLayouts()
        let id1 = SettingsManager.shared.layout1ID.isEmpty
            ? LayoutSwitcher.autoDetectID1(from: sources) : SettingsManager.shared.layout1ID
        let name = LayoutSwitcher.currentLayoutID() == id1 ? "Tink" : "Pop"
        NSSound(named: name)?.play()
    }

    /// Возвращает true, если событие надо «съесть» (только Caps Lock в consume-режиме).
    fileprivate func handleFlagsChanged(flags: CGEventFlags, keyCode: UInt16) -> Bool {
        switch triggerConfig.kind {
        case .capsLock:
            guard keyCode == KC.capsLock else { return false }
            // Caps Lock шлёт одно событие на нажатие. Используем как тап и съедаем,
            // чтобы не переключался регистр.
            registerTap()
            return true

        case let .modifier(mask, left, right):
            let accepted: Set<UInt16> = triggerConfig.rightOnly ? [right] : [left, right]
            let allMods: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            let otherMods = allMods.subtracting(mask)

            if flags.contains(mask) {
                // нажатие: армим только если это нужная клавиша и нет других модификаторов
                if accepted.contains(keyCode) && flags.intersection(otherMods).isEmpty {
                    triggerArmed = true
                    triggerPressTime = Date()
                } else {
                    triggerArmed = false  // не та сторона / комбо
                }
            } else {
                // отпускание: соло-тап нужной клавиши, быстро и без клавиш между
                if triggerArmed, accepted.contains(keyCode), let t = triggerPressTime,
                   Date().timeIntervalSince(t) < tapWindow {
                    registerTap()
                }
                triggerArmed = false
                triggerPressTime = nil
            }
            return false

        case let .combo(maskA, maskB):
            let both: CGEventFlags = [maskA, maskB]
            let allMods: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            let others = allMods.subtracting(both)
            if !flags.intersection(others).isEmpty {
                triggerArmed = false                 // зажат посторонний модификатор — не наш триггер
            } else if flags.contains(both) {
                triggerArmed = true                  // ровно оба нужных, без посторонних → армим
                triggerPressTime = Date()
            } else if flags.intersection(allMods).isEmpty {
                // всё отпущено: тап-комбо, если был армлен, быстро и без клавиш между
                if triggerArmed, let t = triggerPressTime, Date().timeIntervalSince(t) < tapWindow {
                    registerTap()
                }
                triggerArmed = false
                triggerPressTime = nil
            }
            // частичное состояние (зажат один из двух) — ждём, ничего не трогаем
            return false
        }
    }

    /// Учитывает одиночный/двойной тап и запускает конвертацию.
    private func registerTap() {
        if triggerConfig.doubleTap {
            if let last = lastTapTime, Date().timeIntervalSince(last) < tapWindow {
                lastTapTime = nil
                fireConversion()
            } else {
                lastTapTime = Date()  // ждём второй тап
            }
        } else {
            fireConversion()
        }
    }

    private func fireConversion() {
        rslog("trigger: CONVERT selection-first=1 undoEligible=\(!keysTypedSinceConversion)")
        DispatchQueue.main.async { [weak self] in self?.onAltTap?() }
    }
}

// MARK: - C Callback

private func keyboardCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo {
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            monitor.recoverAfterTapDisabled(reason: type)
            if let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passRetained(event)
    }

    // Игнорируем собственные симулированные события по маркеру
    if event.getIntegerValueField(.eventSourceUserData) == kRuSwitcherEventMarker {
        return Unmanaged.passRetained(event)
    }

    guard let userInfo else {
        return Unmanaged.passRetained(event)
    }

    let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .keyDown {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let remote = SettingsManager.shared.remoteDesktopMode
        // Удалёнка: игнорируем авто-повтор клавиш — латентность Screen Sharing рождает
        // ложные повторы (тот самый «фффффф»), засоряющие буфер конверсии.
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0, remote {
            return Unmanaged.passRetained(event)
        }
        // Capture the produced Unicode character for every local event. This is used
        // only as immutable context; physical-key conversion still uses the key code.
        var buf = [UniChar](repeating: 0, count: 4)
        var len = 0
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &buf)
        let producedText = len > 0 ? String(utf16CodeUnits: buf, count: len) : nil
        let producedChar = producedText?.first
        let forwardedChar = remote && keyCode == 0 ? producedChar : nil
        if let producedChar, remote, keyCode == 0, SettingsManager.shared.debugLogEnabled {
            let scalar = producedChar.unicodeScalars.first?.value ?? 0
            rslog("remote: forwarded char U+\(String(scalar, radix: 16))")
        }
        let consume = monitor.handleKeyDown(
            keyCode: keyCode,
            flags: event.flags,
            proxy: proxy,
            char: forwardedChar,
            producedCharacter: producedChar,
            producedText: producedText,
            sourceLayoutID: remote && keyCode == 0 ? nil : LayoutSwitcher.currentLayoutID()
        )
        if consume { return nil }
    } else if type == .flagsChanged {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if monitor.handleFlagsChanged(flags: event.flags, keyCode: keyCode) {
            return nil  // съедаем Caps Lock, чтобы не переключался регистр
        }
    } else if type == .leftMouseDown || type == .rightMouseDown {
        monitor.resetBuffersOnClick()
    }

    return Unmanaged.passRetained(event)
}
