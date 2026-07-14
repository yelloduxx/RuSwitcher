import AppKit
import ApplicationServices
import CoreGraphics
import RuSwitcherAppSupport
import RuSwitcherCore

enum SelectedTextConversionOutcome: Equatable {
    case none
    case unavailable
    case converted
    case postedUnverified
    case failed
}

struct BufferedManualConversion {
    let original: String
    let replacement: String
    let sourceLayoutID: String?
}

struct BufferedManualReconversion {
    let current: String
    let replacement: String
    let targetLayoutID: String?
}

private enum ReplacementVerification: Sendable {
    case match
    case unchanged
    case mismatch
    case unavailable
}

/// Конвертация текста между раскладками
@MainActor
final class TextConverter {
    private var isConverting = false
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
        case unavailable(selectionKnown: Bool)
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
                    completion: completion
                )
            }
        }
    }

    private func handleSelectionRead(
        _ result: SelectionReadResult,
        completion: ManualCompletionBox
    ) {
        switch result {
        case .none:
            isConverting = false
            completion.callback(.none)
        case let .unavailable(selectionKnown):
            isConverting = false
            completion.callback(selectionKnown ? .failed : .unavailable)
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
        guard selectionStillMatches(snapshot) else { return .mismatch }
        AXUIElementSetMessagingTimeout(snapshot.element, 0.25)
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
            lastLearningPair = nil
            isConverting = false
            completion.callback(.failed)
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
            return .unavailable(selectionKnown: false)
        }
        let element = unsafeDowncast(focusedRaw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var elementProcessID: pid_t = 0
        guard AXUIElementGetPid(element, &elementProcessID) == .success,
              elementProcessID == processID else {
            return .unavailable(selectionKnown: false)
        }
        var rangeRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRaw
        ) == .success, let rangeRaw,
          CFGetTypeID(rangeRaw) == AXValueGetTypeID() else {
            return .unavailable(selectionKnown: false)
        }
        let rangeValue = unsafeDowncast(rangeRaw, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange,
              AXValueGetValue(rangeValue, .cfRange, &range) else {
            return .unavailable(selectionKnown: false)
        }
        guard range.length > 0 else { return .none }
        var textRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &textRaw
        ) == .success, let text = textRaw as? String, !text.isEmpty else {
            return .unavailable(selectionKnown: true)
        }
        return .selected(SelectionSnapshot(
            processID: processID,
            element: element,
            range: range,
            text: text
        ))
    }

    nonisolated private func selectionStillMatches(_ snapshot: SelectionSnapshot) -> Bool {
        let app = AXUIElementCreateApplication(snapshot.processID)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var focusedRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRaw
        ) == .success, let focusedRaw,
          CFGetTypeID(focusedRaw) == AXUIElementGetTypeID() else { return false }
        let focused = unsafeDowncast(focusedRaw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(focused, 0.25)
        var processID: pid_t = 0
        guard AXUIElementGetPid(focused, &processID) == .success,
              processID == snapshot.processID,
              CFEqual(focused, snapshot.element) else { return false }

        var rangeRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRaw
        ) == .success, let rangeRaw,
          CFGetTypeID(rangeRaw) == AXValueGetTypeID() else { return false }
        let rangeValue = unsafeDowncast(rangeRaw, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange,
              AXValueGetValue(rangeValue, .cfRange, &range),
              range.location == snapshot.range.location,
              range.length == snapshot.range.length,
              selectedText(from: focused)?.precomposedStringWithCanonicalMapping
                == snapshot.text.precomposedStringWithCanonicalMapping else {
            return false
        }
        return true
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

    func prepareReconversion(trailingSpaces: Int = 0) -> BufferedManualReconversion? {
        guard !isConverting, lastWasBuffer, !lastConverted.isEmpty else { return nil }
        isConverting = true
        let extraSpaces: Int
        if let transaction = lastTransaction, case .punctuation = transaction.boundary {
            extraSpaces = max(0, trailingSpaces)
        } else {
            extraSpaces = 0
        }
        let spaces = String(repeating: " ", count: extraSpaces)
        return BufferedManualReconversion(
            current: lastConverted + spaces,
            replacement: lastOriginal + spaces,
            targetLayoutID: lastTransaction?.sourceLayoutID
        )
    }

    func recordVerifiedReconversion(
        _ reconversion: BufferedManualReconversion,
        transaction: ConversionTransaction
    ) {
        lastOriginal = reconversion.current
        lastConverted = reconversion.replacement
        lastTransaction = transaction
        lastWasBuffer = true
        isConverting = false
    }

    func cancelPendingReconversion() {
        isConverting = false
    }

    func clearState() {
        isConverting = false
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
