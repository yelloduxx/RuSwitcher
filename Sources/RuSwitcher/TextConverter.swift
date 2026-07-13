import AppKit
import ApplicationServices
import CoreGraphics
import RuSwitcherAppSupport
import RuSwitcherCore

enum SelectedTextConversionOutcome: Equatable {
    case none
    case converted
    case postedUnverified
    case failed
}

struct BufferedManualConversion {
    let original: String
    let replacement: String
    let sourceLayoutID: String?
}

private enum ReplacementVerification: Sendable {
    case match
    case unchanged
    case mismatch
    case unavailable
}

private typealias SelectedTextConversion = (
    converted: String,
    sourceLanguage: String,
    targetLanguage: String,
    targetLayoutID: String?
)

/// Конвертация текста между раскладками
@MainActor
final class TextConverter {
    private static let transientPasteboardType = NSPasteboard.PasteboardType(
        "org.nspasteboard.TransientType"
    )
    private var savedClipboardItems: [NSPasteboardItem]?
    private var clipboardRestoreWork: DispatchWorkItem?
    private var clipboardTemporaryChangeCount: Int?
    private var isConverting = false
    /// Очередь для инжекта нажатий буферного движка — чтобы usleep не блокировал
    /// main-поток, на котором висит event tap (иначе тап голодает → лаги/потери нажатий).
    nonisolated private let injectQueue = DispatchQueue(label: "com.ruswitcher.inject", qos: .userInteractive)
    nonisolated private let manualQueue = DispatchQueue(label: "com.ruswitcher.manual-ax", qos: .userInitiated)

    private final class SelectionSnapshot: @unchecked Sendable {
        let processID: pid_t
        let element: AXUIElement
        let range: CFRange
        let text: String

        init(processID: pid_t, element: AXUIElement, range: CFRange, text: String) {
            self.processID = processID
            self.element = element
            self.range = range
            self.text = text
        }
    }

    private final class ManualCompletionBox: @unchecked Sendable {
        let callback: (SelectedTextConversionOutcome) -> Void

        init(_ callback: @escaping (SelectedTextConversionOutcome) -> Void) {
            self.callback = callback
        }
    }

    private enum SelectionReadResult: @unchecked Sendable {
        case none
        case selected(SelectionSnapshot)
        case fallback(selectionKnown: Bool, snapshot: SelectionSnapshot?)
    }

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

    // MARK: - Public API

    func convertSelectedText(
        allowClipboardFallback: Bool = true,
        completion: @escaping (SelectedTextConversionOutcome) -> Void
    ) {
        guard !isConverting else {
            completion(.failed)
            return
        }
        isConverting = true
        guard let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            isConverting = false
            completion(.none)
            return
        }
        let completion = ManualCompletionBox(completion)
        manualQueue.async { [weak self] in
            guard let self else { return }
            let result = Self.readSelection(processID: processID)
            Task { @MainActor [weak self] in
                self?.handleSelectionRead(
                    result,
                    allowClipboardFallback: allowClipboardFallback,
                    completion: completion
                )
            }
        }
    }

    private func handleSelectionRead(
        _ result: SelectionReadResult,
        allowClipboardFallback: Bool,
        completion: ManualCompletionBox
    ) {
        switch result {
        case .none:
            isConverting = false
            completion.callback(.none)
        case let .fallback(selectionKnown, snapshot):
            guard allowClipboardFallback else {
                isConverting = false
                completion.callback(.none)
                return
            }
            convertSelectionViaClipboardAsync(
                selectionKnown: selectionKnown,
                snapshot: snapshot,
                completion: completion
            )
        case let .selected(snapshot):
            guard let conversion = DynamicKeyMapping.convertSelectedText(snapshot.text) else {
                isConverting = false
                completion.callback(.failed)
                return
            }
            let replacement = manualReplacement(
                typed: snapshot.text,
                converted: conversion.converted,
                targetLanguage: conversion.targetLanguage
            )
            if snapshot.processID == ProcessInfo.processInfo.processIdentifier {
                // AX dispatches an in-process NSTextView mutation directly into AppKit.
                // AppKit requires that mutation on its main queue and traps otherwise.
                finishSelectedTextReplacement(
                    verification: setAndVerifySelectedText(
                        snapshot: snapshot,
                        replacement: replacement,
                        pollForDelayedCommit: false
                    ),
                    snapshot: snapshot,
                    replacement: replacement,
                    targetLayoutID: conversion.targetLayoutID,
                    completion: completion
                )
            } else {
                manualQueue.async { [weak self] in
                    guard let self else { return }
                    let verification = self.setAndVerifySelectedText(
                        snapshot: snapshot,
                        replacement: replacement,
                        pollForDelayedCommit: true
                    )
                    Task { @MainActor [weak self] in
                        self?.finishSelectedTextReplacement(
                            verification: verification,
                            snapshot: snapshot,
                            replacement: replacement,
                            targetLayoutID: conversion.targetLayoutID,
                            completion: completion
                        )
                    }
                }
            }
        }
    }

    nonisolated private func setAndVerifySelectedText(
        snapshot: SelectionSnapshot,
        replacement: String,
        pollForDelayedCommit: Bool
    ) -> ReplacementVerification {
        let setResult = AXUIElementSetAttributeValue(
            snapshot.element,
            kAXSelectedTextAttribute as CFString,
            replacement as CFString
        )
        guard setResult == .success else { return .unchanged }
        if !pollForDelayedCommit {
            return verifyReplacement(
                replacement,
                original: snapshot.text,
                originalRange: snapshot.range,
                element: snapshot.element
            )
        }

        let deadline = Date().addingTimeInterval(0.25)
        var verification: ReplacementVerification = .unavailable
        repeat {
            verification = verifyReplacement(
                replacement,
                original: snapshot.text,
                originalRange: snapshot.range,
                element: snapshot.element
            )
            if verification == .match || verification == .mismatch { break }
            if Date() < deadline { usleep(5_000) }
        } while Date() < deadline
        return verification
    }

    private func finishSelectedTextReplacement(
        verification: ReplacementVerification,
        snapshot: SelectionSnapshot,
        replacement: String,
        targetLayoutID: String?,
        completion: ManualCompletionBox
    ) {
        switch verification {
        case .match:
            lastManualTargetLayoutID = targetLayoutID
            lastLearningPair = (snapshot.text, replacement)
            lastWasBuffer = false
            isConverting = false
            completion.callback(.converted)
        case .unchanged:
            convertSelectionViaClipboardAsync(
                selectionKnown: true,
                snapshot: snapshot,
                completion: completion
            )
        case .mismatch, .unavailable:
            lastLearningPair = nil
            isConverting = false
            completion.callback(.failed)
        }
    }

    nonisolated private static func readSelection(processID: pid_t) -> SelectionReadResult {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var focusedRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRaw
        ) == .success, let focusedRaw,
          CFGetTypeID(focusedRaw) == AXUIElementGetTypeID() else {
            return .fallback(selectionKnown: false, snapshot: nil)
        }
        let element = unsafeDowncast(focusedRaw, to: AXUIElement.self)
        var rangeRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRaw
        ) == .success, let rangeRaw,
          CFGetTypeID(rangeRaw) == AXValueGetTypeID() else {
            return .fallback(selectionKnown: false, snapshot: nil)
        }
        let rangeValue = unsafeDowncast(rangeRaw, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange,
              AXValueGetValue(rangeValue, .cfRange, &range) else {
            return .fallback(selectionKnown: false, snapshot: nil)
        }
        guard range.length > 0 else { return .none }
        var textRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &textRaw
        ) == .success, let text = textRaw as? String, !text.isEmpty else {
            return .fallback(selectionKnown: true, snapshot: nil)
        }
        return .selected(SelectionSnapshot(
            processID: processID,
            element: element,
            range: range,
            text: text
        ))
    }

    func prepareBufferedConversion(keys: [TypedKey]) -> BufferedManualConversion? {
        guard let pair = DynamicKeyMapping.convertKeys(keys) else { return nil }
        let replacement = manualReplacement(
            typed: pair.original,
            converted: pair.converted,
            sourceLayoutID: keys.first?.sourceLayoutID
        )
        return BufferedManualConversion(
            original: pair.original,
            replacement: replacement,
            sourceLayoutID: keys.first?.sourceLayoutID
        )
    }

    func recordVerifiedManualBuffer(
        _ conversion: BufferedManualConversion,
        transaction: ConversionTransaction
    ) {
        lastOriginal = transaction.originalTextForUndo
        lastConverted = transaction.insertedText
        lastLearningPair = (conversion.original, conversion.replacement)
        lastWasBuffer = true
        lastTransaction = transaction
    }

    nonisolated private func postKey(keyCode: UInt16, to processID: Int32) -> Bool {
        guard let source = makeSource(),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        down.postToPid(pid_t(processID))
        up.postToPid(pid_t(processID))
        return true
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
        return false
    }

    func clearState() {
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

    nonisolated private func selectedText(from element: AXUIElement) -> String? {
        var textRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &textRaw
        ) == .success else { return nil }
        return textRaw as? String
    }

    nonisolated private func verifyReplacement(
        _ replacement: String,
        original: String,
        originalRange: CFRange,
        element: AXUIElement
    ) -> ReplacementVerification {
        var range = CFRange(location: originalRange.location, length: replacement.utf16.count)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return .unavailable }
        var textRaw: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &textRaw
        ) == .success, let actual = textRaw as? String else {
            guard let selected = selectedText(from: element) else { return .unavailable }
            let normalized = selected.precomposedStringWithCanonicalMapping
            if normalized == replacement.precomposedStringWithCanonicalMapping { return .match }
            if normalized == original.precomposedStringWithCanonicalMapping { return .unchanged }
            return .unavailable
        }
        let normalized = actual.precomposedStringWithCanonicalMapping
        if normalized == replacement.precomposedStringWithCanonicalMapping { return .match }
        if normalized == original.precomposedStringWithCanonicalMapping { return .unchanged }
        return .mismatch
    }

    private func convertSelectionViaClipboardAsync(
        selectionKnown: Bool,
        snapshot: SelectionSnapshot?,
        completion: ManualCompletionBox
    ) {
        let pasteboard = NSPasteboard.general
        cancelClipboardRestore()
        if savedClipboardItems == nil {
            savedClipboardItems = snapshotPasteboard(pasteboard)
        }
        attemptClipboardCopy(
            attempt: 0,
            selectionKnown: selectionKnown,
            snapshot: snapshot,
            completion: completion
        )
    }

    private func attemptClipboardCopy(
        attempt: Int,
        selectionKnown: Bool,
        snapshot: SelectionSnapshot?,
        completion: ManualCompletionBox
    ) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        clipboardTemporaryChangeCount = pasteboard.changeCount
        let clearedCount = pasteboard.changeCount
        simKey(keyCode: KC.letterC, flags: .maskCommand)
        pollClipboardCopy(
            clearedCount: clearedCount,
            deadline: Date().addingTimeInterval(attempt == 0 ? 0.08 : 0.12),
            attempt: attempt,
            selectionKnown: selectionKnown,
            snapshot: snapshot,
            completion: completion
        )
    }

    private func pollClipboardCopy(
        clearedCount: Int,
        deadline: Date,
        attempt: Int,
        selectionKnown: Bool,
        snapshot: SelectionSnapshot?,
        completion: ManualCompletionBox
    ) {
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount != clearedCount,
           let text = pasteboard.string(forType: .string), !text.isEmpty,
           let conversion = DynamicKeyMapping.convertSelectedText(text) {
            markPasteboardTransient(pasteboard)
            finishClipboardConversion(
                text: text,
                conversion: conversion,
                snapshot: snapshot,
                completion: completion
            )
            return
        }
        if Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { [weak self] in
                self?.pollClipboardCopy(
                    clearedCount: clearedCount,
                    deadline: deadline,
                    attempt: attempt,
                    selectionKnown: selectionKnown,
                    snapshot: snapshot,
                    completion: completion
                )
            }
            return
        }
        if attempt < 2 {
            attemptClipboardCopy(
                attempt: attempt + 1,
                selectionKnown: selectionKnown,
                snapshot: snapshot,
                completion: completion
            )
        } else {
            isConverting = false
            restoreClipboardNow()
            completion.callback(selectionKnown ? .failed : .none)
        }
    }

    private func finishClipboardConversion(
        text: String,
        conversion: SelectedTextConversion,
        snapshot: SelectionSnapshot?,
        completion: ManualCompletionBox
    ) {
        let replacement = manualReplacement(
            typed: text,
            converted: conversion.converted,
            targetLanguage: conversion.targetLanguage
        )
        let pasteboard = NSPasteboard.general
        let item = NSPasteboardItem()
        item.setString(replacement, forType: .string)
        item.setData(Data(), forType: Self.transientPasteboardType)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        clipboardTemporaryChangeCount = pasteboard.changeCount
        simKey(keyCode: KC.letterV, flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            guard let snapshot else {
                self.lastLearningPair = nil
                self.lastManualTargetLayoutID = nil
                self.isConverting = false
                self.scheduleClipboardRestore()
                completion.callback(.postedUnverified)
                return
            }
            self.manualQueue.async { [weak self] in
                guard let self else { return }
                let verified = self.verifyReplacement(
                    replacement,
                    original: text,
                    originalRange: snapshot.range,
                    element: snapshot.element
                )
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if verified == .match {
                        self.lastManualTargetLayoutID = conversion.targetLayoutID
                        self.lastLearningPair = (text, replacement)
                        self.lastWasBuffer = false
                        self.isConverting = false
                        self.scheduleClipboardRestore()
                        completion.callback(.converted)
                    } else {
                        self.lastLearningPair = nil
                        self.lastManualTargetLayoutID = nil
                        self.isConverting = false
                        self.restoreClipboardNow()
                        completion.callback(.failed)
                    }
                }
            }
        }
    }

    private func markPasteboardTransient(_ pasteboard: NSPasteboard) {
        pasteboard.addTypes([Self.transientPasteboardType], owner: nil)
        pasteboard.setData(Data(), forType: Self.transientPasteboardType)
        clipboardTemporaryChangeCount = pasteboard.changeCount
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
        if let owned = clipboardTemporaryChangeCount,
           pasteboard.changeCount != owned {
            savedClipboardItems = nil
            clipboardTemporaryChangeCount = nil
            return
        }
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
        savedClipboardItems = nil
        clipboardTemporaryChangeCount = nil
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
            guard let self else { return }
            guard let owned = self.clipboardTemporaryChangeCount,
                  pasteboard.changeCount == owned else {
                self.savedClipboardItems = nil
                self.clipboardTemporaryChangeCount = nil
                return
            }
            pasteboard.clearContents()
            if let saved, !saved.isEmpty {
                pasteboard.writeObjects(saved)
            }
            self.savedClipboardItems = nil
            self.clipboardTemporaryChangeCount = nil
            rslog("clipboard_restored")
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

extension TextConverter: KeyboardEventPosting {
    func post(_ plan: EventReplacementPlan, to processID: Int32) -> Bool {
        guard let events = replacementEvents(for: plan) else { return false }
        for event in events {
            event.postToPid(pid_t(processID))
        }
        for character in plan.replayText {
            let keyCode: UInt16
            switch character {
            case " ": keyCode = KC.space
            case "\n": keyCode = KC.enter
            case "\t": keyCode = KC.tab
            default: continue
            }
            guard postKey(keyCode: keyCode, to: processID) else { return false }
        }
        return true
    }
}
