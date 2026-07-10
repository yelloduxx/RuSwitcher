import AppKit
import ApplicationServices
import CoreGraphics
import RuSwitcherCore

enum SelectedTextConversionOutcome: Equatable {
    case none
    case converted
    case failed
}

/// Конвертация текста между раскладками
@MainActor
final class TextConverter {
    private var lastConvertedCount = 0
    private var lastBoundaryCount = 0
    private var savedClipboardItems: [NSPasteboardItem]?
    private var clipboardRestoreWork: DispatchWorkItem?
    private var isConverting = false
    /// Очередь для инжекта нажатий буферного движка — чтобы usleep не блокировал
    /// main-поток, на котором висит event tap (иначе тап голодает → лаги/потери нажатий).
    nonisolated private let injectQueue = DispatchQueue(label: "com.ruswitcher.inject", qos: .userInteractive)

    // Состояние движка перепечатки (буфер нажатий → юникод-вставка)
    private var lastOriginal = ""
    private var lastConverted = ""
    private var lastWasBuffer = false
    private(set) var lastTransaction: ConversionTransaction?
    private(set) var lastLearningPair: (original: String, converted: String)?
    private(set) var lastManualTargetLayoutID: String?

    /// Создаёт CGEventSource с маркером, чтобы KeyboardMonitor игнорировал наши события
    nonisolated private func makeSource() -> CGEventSource? {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = kRuSwitcherEventMarker
        return source
    }

    /// Проверяет, что текущий фокусированный элемент — редактируемое текстовое поле
    private func isFocusedElementEditable() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var focusedRaw: AnyObject?
        let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRaw)
        guard err == .success, let focused = focusedRaw else {
            rslog("editable: no focused element")
            return false
        }

        let element = focused as! AXUIElement

        // Проверяем роль
        var roleRaw: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRaw)
        let role = (roleRaw as? String) ?? ""

        // Текстовые роли
        let textRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"]
        if textRoles.contains(role) {
            // Дополнительно: не read-only?
            var editableRaw: AnyObject?
            let editErr = AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editableRaw)
            // Если атрибут отсутствует — считаем editable (у AXWebArea его может не быть)
            if editErr == .success, let editable = editableRaw as? Bool {
                rslog("editable: role=\(role) editable=\(editable)")
                return editable
            }
            rslog("editable: role=\(role) (no AXEditable attr, assuming yes)")
            return true
        }

        rslog("editable: role=\(role) — not a text field")
        return false
    }

    // MARK: - Public API

    func convertSelectedText() -> SelectedTextConversionOutcome {
        guard !isConverting else { return .failed }
        isConverting = true
        defer { isConverting = false }

        guard let app = NSWorkspace.shared.frontmostApplication else { return .none }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRaw: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(
            axApp,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRaw
        )
        if focusResult == .success, let focusedRaw {
            let element = focusedRaw as! AXUIElement
            var rangeRaw: AnyObject?
            if AXUIElementCopyAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                &rangeRaw
            ) == .success, let rangeRaw {
                let rangeValue = rangeRaw as! AXValue
                var range = CFRange()
                if AXValueGetType(rangeValue) == .cfRange,
                   AXValueGetValue(rangeValue, .cfRange, &range),
                   range.length == 0 {
                    return .none
                }
                if range.length > 0 {
                    guard let text = selectedText(from: element) else {
                        return convertSelectionViaClipboard(selectionKnown: true)
                    }
                    guard let conversion = DynamicKeyMapping.convertSelectedText(text) else {
                        rslog("manual selection: ambiguous-script len=\(text.count)")
                        return .failed
                    }
                    lastManualTargetLayoutID = conversion.targetLayoutID
                    let replacement = manualReplacement(
                        typed: text,
                        converted: conversion.converted,
                        targetLanguage: conversion.targetLanguage
                    )
                    lastLearningPair = (text, replacement)
                    let setResult = AXUIElementSetAttributeValue(
                        element,
                        kAXSelectedTextAttribute as CFString,
                        replacement as CFString
                    )
                    if setResult == .success {
                        let verified = verifyReplacement(
                            replacement,
                            originalRange: range,
                            element: element
                        )
                        rslog("manual selection: strategy=ax len=\(text.count) verified=\(verified)")
                        lastConvertedCount = replacement.count
                        lastBoundaryCount = 0
                        lastWasBuffer = false
                        return .converted
                    }
                    return convertSelectionViaClipboard(selectionKnown: true)
                }
            }
        }
        return convertSelectionViaClipboard(selectionKnown: false)
    }

    /// Движок перепечатки: стираем набранное и впечатываем конвертированное через
    /// юникод-вставку — без буфера обмена и без выделения (работает в Atom/Electron).
    /// Падает на clipboard-движок, если буфера нет (текст выделен мышью) или
    /// раскладки не определились.
    func convert(wordKeys: [TypedKey], prevWordKeys: [TypedKey], boundaryCount: Int) -> ConversionOutcome {
        let keys: [TypedKey]
        let trailingSpaces: Int
        if !wordKeys.isEmpty {
            keys = wordKeys; trailingSpaces = 0
        } else if !prevWordKeys.isEmpty {
            keys = prevWordKeys; trailingSpaces = boundaryCount
        } else {
            // нет буфера — возможно, выделен мышью старый текст: пусть решает clipboard
            return convertViaClipboard(wordLength: 0, prevWordLength: 0, boundaryCount: 0)
        }

        guard let pair = DynamicKeyMapping.convertKeys(keys) else {
            rslog("buffer convert: layouts not resolved — fallback to clipboard")
            return convertViaClipboard(wordLength: wordKeys.count, prevWordLength: prevWordKeys.count, boundaryCount: boundaryCount)
        }

        guard !isConverting else { return .blocked }
        isConverting = true

        let replacement = manualReplacement(
            typed: pair.original,
            converted: pair.converted,
            sourceLayoutID: keys.first?.sourceLayoutID
        )
        let spaces = String(repeating: " ", count: trailingSpaces)
        let bsCount = keys.count + trailingSpaces
        let insert = replacement + spaces
        lastOriginal = pair.original + spaces
        lastConverted = replacement + spaces
        lastLearningPair = (pair.original, replacement)
        lastWasBuffer = true
        rslog("buffer convert: \(keys.count) keys (+\(trailingSpaces) sp)")

        // Инжект — вне main, чтобы usleep не голодал event tap.
        injectQueue.async { [weak self] in
            guard let self else { return }
            self.backspace(bsCount)
            usleep(20_000)
            self.insertText(insert)
            Task { @MainActor in self.isConverting = false }
        }
        return .converted
    }

    /// Авто-конвертация с уже выбранным кандидатом: detector может решить, что
    /// хвостовая клавиша была пунктуацией, а не буквой раскладки (`ghbdtn,` → `привет,`).
    func convert(candidate: AutoConvertCandidate, keyCount: Int, trailingSpaces: Int) -> Bool {
        guard keyCount > 0 else { return false }
        guard !isConverting else { return false }
        isConverting = true

        let spaces = String(repeating: " ", count: trailingSpaces)
        let bsCount = keyCount + trailingSpaces
        let insert = candidate.replacement + spaces
        lastOriginal = candidate.typedRaw + spaces
        lastConverted = insert
        lastLearningPair = (candidate.typedRaw, candidate.replacement)
        lastWasBuffer = true
        rslog("buffer auto convert: keys=\(keyCount) suffix=\(candidate.suffix.count) kind=\(candidate.kind)")

        injectQueue.async { [weak self] in
            guard let self else { return }
            self.backspace(bsCount)
            usleep(20_000)
            self.insertText(insert)
            Task { @MainActor in self.isConverting = false }
        }
        return true
    }

    /// Executes while the active event tap still owns the boundary event. Backspaces,
    /// replacement and (for spaces) the consumed boundary are posted as one ordered
    /// sequence before another physical event can be observed by RuSwitcher.
    func execute(
        _ transaction: ConversionTransaction,
        keyCount: Int,
        proxy _: CGEventTapProxy
    ) -> Bool {
        guard keyCount > 0, !isConverting else { return false }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier == transaction.focus.processID,
              front.bundleIdentifier == transaction.focus.bundleID else {
            rslog("transaction: focus validation failed")
            return false
        }

        let plan = EventReplacementPlan(
            transaction: transaction,
            deliveredKeyCount: keyCount
        )
        guard let events = replacementEvents(for: plan) else {
            rslog("transaction: could not create event plan")
            return false
        }

        isConverting = true
        recordCommittedTransaction(transaction)
        for event in events {
            event.postToPid(pid_t(transaction.focus.processID))
        }
        for character in plan.replayText where character == " " {
            postKey(keyCode: KC.space, to: transaction.focus.processID)
        }
        isConverting = false
        rslog("transaction: targeted events posted count=\(events.count) boundary=\(transaction.boundary)")
        return true
    }

    private func postKey(keyCode: UInt16, to processID: Int32) {
        guard let source = makeSource(),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.postToPid(pid_t(processID))
        up.postToPid(pid_t(processID))
    }

    nonisolated private func replacementEvents(for plan: EventReplacementPlan) -> [CGEvent]? {
        guard let source = makeSource() else { return nil }
        var events: [CGEvent] = []
        events.reserveCapacity(plan.backspaceCount * 2 + 2)
        for _ in 0..<plan.backspaceCount {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: KC.backspace, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: KC.backspace, keyDown: false) else {
                return nil
            }
            events.append(down)
            events.append(up)
        }
        guard !plan.replacementText.isEmpty,
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return nil
        }
        let utf16 = Array(plan.replacementText.utf16)
        utf16.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        events.append(down)
        events.append(up)
        return events
    }

    func recordCommittedTransaction(_ transaction: ConversionTransaction) {
        lastTransaction = transaction
        lastLearningPair = (transaction.original, transaction.replacement)
        lastOriginal = transaction.originalTextForUndo
        lastConverted = transaction.insertedText
        lastWasBuffer = true
    }

    /// Повторная конвертация (второй триггер) — на тот движок, которым делали последнюю.
    func reconvert(trailingSpaces: Int = 0) -> Bool {
        guard !isConverting else { return false }
        if lastWasBuffer {
            guard !lastConverted.isEmpty else { return false }
            isConverting = true
            rslog("buffer reconvert")
            let extraSpaces: Int
            if let transaction = lastTransaction, case .punctuation = transaction.boundary {
                extraSpaces = max(0, trailingSpaces)
            } else {
                extraSpaces = 0
            }
            let spaces = String(repeating: " ", count: extraSpaces)
            let current = lastConverted + spaces
            let insert = lastOriginal + spaces
            let bsCount = current.count
            lastOriginal = current
            lastConverted = insert
            lastTransaction = nil
            injectQueue.async { [weak self] in
                guard let self else { return }
                self.backspace(bsCount)
                usleep(20_000)
                self.insertText(insert)
                Task { @MainActor in self.isConverting = false }
            }
            return true
        }
        return reconvertViaClipboard()
    }

    /// Конвертация через буфер обмена (фолбэк: выделенный мышью текст и т.п.).
    /// Сначала проверяет выделение, потом пробует слово по счётчику.
    func convertViaClipboard(wordLength: Int, prevWordLength: Int, boundaryCount: Int) -> ConversionOutcome {
        guard !isConverting else {
            rslog("convert: skipped — already converting")
            return .blocked
        }
        isConverting = true
        lastWasBuffer = false
        defer { isConverting = false }

        if !isFocusedElementEditable() {
            rslog("convert: element may not be editable, trying anyway")
        }
        let pasteboard = NSPasteboard.general
        cancelClipboardRestore()
        savedClipboardItems = snapshotPasteboard(pasteboard)

        var conversionSucceeded = false
        defer {
            // Любой ранний выход без успеха обязан вернуть буфер пользователю —
            // иначе clipboard остаётся пустым или с конвертированным текстом.
            if !conversionSucceeded { restoreClipboardNow() }
        }

        // --- Попытка 1: уже есть выделенный текст? ---
        if let text = tryCopy(pasteboard) {
            rslog("convert: selection len=\(text.count)")
            let rawConverted = DynamicKeyMapping.convert(text).precomposedStringWithCanonicalMapping
            let converted = manualReplacement(typed: text, converted: rawConverted, sourceLayoutID: nil)
            lastLearningPair = (text, converted)
            pasteText(converted, pasteboard: pasteboard)
            // Курсор остаётся в конце вставленного текста — не пере-выделяем,
            // чтобы следующий ввод не затёр результат. Для reconvert используется
            // унифицированный путь через selectBack(lastConvertedCount).
            lastConvertedCount = converted.count
            lastBoundaryCount = 0
            conversionSucceeded = true
            scheduleClipboardRestore()
            return .converted
        }

        // --- Попытка 2: выделяем слово по счётчику ---
        let charCount: Int
        let usedBoundary: Int

        if wordLength > 0 {
            charCount = wordLength
            usedBoundary = 0
        } else if prevWordLength > 0 {
            moveLeft(boundaryCount)
            charCount = prevWordLength
            usedBoundary = boundaryCount
        } else {
            rslog("convert: nothing to convert (wordLen=\(wordLength) prevLen=\(prevWordLength))")
            return .switchedOnly
        }

        rslog("convert: selecting \(charCount) chars (boundary=\(usedBoundary))")
        selectBack(charCount)
        usleep(50_000)

        guard let text = tryCopy(pasteboard) else {
            rslog("convert: copy failed")
            simKey(keyCode: KC.right, flags: []) // снять выделение
            moveRight(usedBoundary)
            return .switchedOnly
        }

        rslog("convert: word len=\(text.count)")
        let rawConverted = DynamicKeyMapping.convert(text).precomposedStringWithCanonicalMapping
        let converted = manualReplacement(typed: text, converted: rawConverted, sourceLayoutID: nil)
        lastLearningPair = (text, converted)
        pasteText(converted, pasteboard: pasteboard)

        moveRight(usedBoundary)

        lastConvertedCount = converted.count
        lastBoundaryCount = usedBoundary
        conversionSucceeded = true
        scheduleClipboardRestore()
        return .converted
    }

    /// Повторная конвертация через буфер обмена (фолбэк).
    private func reconvertViaClipboard() -> Bool {
        guard !isConverting else {
            rslog("reconvert: skipped — already converting")
            return false
        }
        isConverting = true
        defer { isConverting = false }

        rslog("reconvert: lastCount=\(lastConvertedCount) boundary=\(lastBoundaryCount)")
        guard lastConvertedCount > 0 else { return false }

        let pasteboard = NSPasteboard.general
        // Отменяем отложенное восстановление clipboard — мы ещё работаем
        cancelClipboardRestore()

        moveLeft(lastBoundaryCount)

        selectBack(lastConvertedCount)
        usleep(80_000)  // дать приложению обработать выделение

        guard let text = tryCopy(pasteboard) else {
            rslog("reconvert: copy failed, count=\(lastConvertedCount)")
            simKey(keyCode: KC.right, flags: [])
            moveRight(lastBoundaryCount)
            scheduleClipboardRestore()
            return false
        }

        rslog("reconvert: len=\(text.count) → converting")
        let converted = DynamicKeyMapping.convert(text).precomposedStringWithCanonicalMapping
        pasteText(converted, pasteboard: pasteboard)

        moveRight(lastBoundaryCount)

        lastConvertedCount = converted.count
        scheduleClipboardRestore()
        return true
    }

    func clearState() {
        lastConvertedCount = 0
        lastBoundaryCount = 0
        lastOriginal = ""
        lastConverted = ""
        lastWasBuffer = false
        lastTransaction = nil
        lastLearningPair = nil
        lastManualTargetLayoutID = nil
    }

    // MARK: - Private

    private func manualReplacement(typed: String, converted: String, sourceLayoutID: String?) -> String {
        let langs = sourceLayoutID.flatMap(LayoutSwitcher.languagePair(sourceLayoutID:))
            ?? LayoutSwitcher.currentAndOppositeLanguage()
        guard let targetLanguage = langs?.opposite else { return converted }
        return manualReplacement(typed: typed, converted: converted, targetLanguage: targetLanguage)
    }

    private func manualReplacement(typed: String, converted: String, targetLanguage: String) -> String {
        return AutoConvertCandidateGenerator.bestCandidate(
            typed: typed,
            converted: converted,
            targetLanguage: targetLanguage,
            isValidWord: { word, language in
                !word.isEmpty && Dict.isAvailable(language) && Dict.isValidWord(word, lang: language)
            }
        )?.replacement ?? converted
    }

    private func selectedText(from element: AXUIElement) -> String? {
        var textRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &textRaw
        ) == .success else { return nil }
        return textRaw as? String
    }

    private func verifyReplacement(
        _ replacement: String,
        originalRange: CFRange,
        element: AXUIElement
    ) -> Bool {
        var range = CFRange(location: originalRange.location, length: replacement.utf16.count)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return false }
        var textRaw: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &textRaw
        ) == .success, let actual = textRaw as? String else { return false }
        return actual.precomposedStringWithCanonicalMapping
            == replacement.precomposedStringWithCanonicalMapping
    }

    private func convertSelectionViaClipboard(selectionKnown: Bool) -> SelectedTextConversionOutcome {
        let pasteboard = NSPasteboard.general
        cancelClipboardRestore()
        savedClipboardItems = snapshotPasteboard(pasteboard)
        guard let text = tryCopy(pasteboard) else {
            restoreClipboardNow()
            rslog("manual selection: clipboard copy failed known=\(selectionKnown)")
            return selectionKnown ? .failed : .none
        }
        guard let conversion = DynamicKeyMapping.convertSelectedText(text) else {
            restoreClipboardNow()
            return .failed
        }
        lastManualTargetLayoutID = conversion.targetLayoutID
        let replacement = manualReplacement(
            typed: text,
            converted: conversion.converted,
            targetLanguage: conversion.targetLanguage
        )
        lastLearningPair = (text, replacement)
        pasteText(replacement, pasteboard: pasteboard)
        lastConvertedCount = replacement.count
        lastBoundaryCount = 0
        lastWasBuffer = false
        scheduleClipboardRestore()
        rslog("manual selection: strategy=clipboard len=\(text.count)")
        return .converted
    }

    /// Стирает n символов (Backspace × n) — для движка перепечатки.
    nonisolated private func backspace(_ n: Int) {
        for _ in 0..<n {
            simKey(keyCode: KC.backspace, flags: [])
            usleep(3_000)
        }
    }

    /// Впечатывает строку напрямую (юникод-вставка), без буфера обмена.
    nonisolated private func insertText(_ text: String) {
        guard !text.isEmpty, let source = makeSource() else { return }
        let utf16 = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        // Text input belongs to keyDown. Attaching the same Unicode payload to
        // keyUp makes some WebKit/Electron controls insert it a second time.
        utf16.withUnsafeBufferPointer { buf in
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Вставляет текст через Cmd+V и ждёт завершения
    private func pasteText(_ text: String, pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        simKey(keyCode: KC.letterV, flags: .maskCommand) // Cmd+V
        usleep(150_000) // 150мс — дать приложению вставить текст и обновить курсор
    }

    /// Отменяет отложенное восстановление clipboard
    private func cancelClipboardRestore() {
        clipboardRestoreWork?.cancel()
        clipboardRestoreWork = nil
    }

    /// Немедленно возвращает буфер обмена пользователю (для путей-неудач).
    private func restoreClipboardNow() {
        cancelClipboardRestore()
        guard let saved = savedClipboardItems else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
        savedClipboardItems = nil
    }

    /// Сбрасывает отложенное восстановление немедленно — вызывается перед
    /// завершением приложения, чтобы не потерять буфер в 2-секундном окне.
    func flushPendingClipboardRestore() {
        guard clipboardRestoreWork != nil else { return }
        restoreClipboardNow()
    }

    /// Планирует восстановление clipboard через 2 секунды
    /// (если за это время придёт reconvert — отменится и перепланируется)
    private func scheduleClipboardRestore() {
        cancelClipboardRestore()
        let saved = self.savedClipboardItems
        let work = DispatchWorkItem { [weak self] in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if let saved, !saved.isEmpty {
                pasteboard.writeObjects(saved)
            }
            self?.savedClipboardItems = nil
            rslog("clipboard restored (\(saved?.count ?? 0) items)")
        }
        clipboardRestoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// Делает глубокую копию всех pasteboard items (со всеми типами данных).
    /// Это нужно потому, что NSPasteboardItem становится невалидным после
    /// pasteboard.clearContents() — поэтому копируем data по каждому типу
    /// в новые NSPasteboardItem.
    private func snapshotPasteboard(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.map { oldItem in
            let newItem = NSPasteboardItem()
            for type in oldItem.types {
                if let data = oldItem.data(forType: type) {
                    newItem.setData(data, forType: type)
                }
            }
            return newItem
        }
    }

    /// Копирует выделенный текст. Делает до 3 попыток (Cmd+C не всегда срабатывает с первого раза)
    private func tryCopy(_ pasteboard: NSPasteboard) -> String? {
        for attempt in 0..<3 {
            // Очищаем буфер перед копированием — гарантирует что changeCount изменится
            pasteboard.clearContents()
            let oldCount = pasteboard.changeCount

            simKey(keyCode: KC.letterC, flags: .maskCommand) // Cmd+C
            usleep(attempt == 0 ? 80_000 : 120_000)

            if pasteboard.changeCount != oldCount,
               let text = pasteboard.string(forType: .string),
               !text.isEmpty {
                return text
            }
            usleep(50_000) // пауза перед retry
        }
        return nil
    }

    /// Выделяет N символов влево (Shift+Left × N)
    nonisolated private func selectBack(_ count: Int) {
        for _ in 0..<count {
            simKey(keyCode: KC.left, flags: .maskShift)
            usleep(3_000)
        }
    }

    /// Сдвигает курсор влево на N символов
    nonisolated private func moveLeft(_ count: Int) {
        for _ in 0..<count {
            simKey(keyCode: KC.left, flags: [])
            usleep(3_000)
        }
    }

    /// Сдвигает курсор вправо на N символов (восстановление границ-пробелов)
    nonisolated private func moveRight(_ count: Int) {
        for _ in 0..<count {
            simKey(keyCode: KC.right, flags: [])
            usleep(3_000)
        }
    }

    /// Симулирует нажатие клавиши с маркером (чтобы наш monitor игнорировал)
    nonisolated private func simKey(keyCode: UInt16, flags: CGEventFlags) {
        guard let source = makeSource() else { return }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }

        keyDown.flags = flags
        keyUp.flags = flags

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
