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

enum ManualSuffixReplacementOutcome: Equatable {
    case verified
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
    private static let concealedPasteboardType = NSPasteboard.PasteboardType(
        "org.nspasteboard.ConcealedType"
    )
    private var savedClipboardItems: [NSPasteboardItem]?
    private var clipboardRestoreWork: DispatchWorkItem?
    private var clipboardTemporaryChangeCount: Int?
    private var isConverting = false
    nonisolated private let manualQueue = DispatchQueue(label: "com.ruswitcher.manual-ax", qos: .userInitiated)
    nonisolated private let focusedElementResolver: NativeFocusedEditableResolver

    private final class SelectionSnapshot: @unchecked Sendable {
        let processID: pid_t
        let identifier: String
        let range: CFRange
        let text: String

        init(processID: pid_t, identifier: String, range: CFRange, text: String) {
            self.processID = processID
            self.identifier = identifier
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

    private final class SuffixCompletionBox: @unchecked Sendable {
        let callback: (ManualSuffixReplacementOutcome) -> Void

        init(_ callback: @escaping (ManualSuffixReplacementOutcome) -> Void) {
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
    var canReconvert: Bool {
        !isConverting && lastWasBuffer && !lastConverted.isEmpty
    }

    init(focusedElementResolver: NativeFocusedEditableResolver) {
        self.focusedElementResolver = focusedElementResolver
    }

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
            let result = self.readSelection(processID: processID)
            Task { @MainActor [weak self] in
                self?.handleSelectionRead(
                    result,
                    allowClipboardFallback: allowClipboardFallback,
                    completion: completion
                )
            }
        }
    }

    /// Replaces the exact text immediately before the caret through AX. Unlike
    /// Backspace + Unicode event posting, this cannot leave a half-deleted word
    /// when an application drops the insertion event.
    func replaceFocusedSuffix(
        expected: String,
        replacement: String,
        focus: FocusedElementIdentity,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        completion: @escaping (ManualSuffixReplacementOutcome) -> Void
    ) {
        guard !expected.isEmpty, !replacement.isEmpty, isCurrent() else {
            completion(.failed)
            return
        }
        isConverting = true
        let completion = SuffixCompletionBox(completion)
        if CommandLine.arguments.contains("--force-synthetic-input-fallback") {
            finishFocusedSuffixReplacement(
                .unchanged,
                expected: expected,
                replacement: replacement,
                focus: focus,
                isCurrent: isCurrent,
                completion: completion
            )
            return
        }
        if focus.processID == ProcessInfo.processInfo.processIdentifier {
            let verification = setAndVerifyFocusedSuffix(
                expected: expected,
                replacement: replacement,
                focus: focus,
                pollForDelayedCommit: false
            )
            finishFocusedSuffixReplacement(
                verification,
                expected: expected,
                replacement: replacement,
                focus: focus,
                isCurrent: isCurrent,
                completion: completion
            )
            return
        }
        manualQueue.async { [weak self] in
            guard let self else { return }
            let verification = self.setAndVerifyFocusedSuffix(
                expected: expected,
                replacement: replacement,
                focus: focus,
                pollForDelayedCommit: true
            )
            Task { @MainActor [weak self] in
                self?.finishFocusedSuffixReplacement(
                    verification,
                    expected: expected,
                    replacement: replacement,
                    focus: focus,
                    isCurrent: isCurrent,
                    completion: completion
                )
            }
        }
    }

    private func finishFocusedSuffixReplacement(
        _ verification: ReplacementVerification,
        expected: String,
        replacement: String,
        focus: FocusedElementIdentity,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        completion: SuffixCompletionBox
    ) {
        switch verification {
        case .match:
            completion.callback(.verified)
        case .unchanged, .unavailable:
            // AX dark or set failed — still attempt event replacement so manual
            // double-Shift works outside perfect Accessibility editors.
            replaceFocusedSuffixViaSyntheticInput(
                expected: expected,
                replacement: replacement,
                focus: focus,
                isCurrent: isCurrent,
                completion: completion
            )
        case .mismatch:
            isConverting = false
            completion.callback(.failed)
        }
    }

    private func replaceFocusedSuffixViaSyntheticInput(
        expected: String,
        replacement: String,
        focus: FocusedElementIdentity,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        completion: SuffixCompletionBox
    ) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID,
              !expected.isEmpty,
              isCurrent() else {
            isConverting = false
            completion.callback(.failed)
            return
        }

        let resolved = resolveSyntheticPair(
            expected: expected,
            replacement: replacement,
            focus: focus
        )
        guard let resolved else {
            isConverting = false
            completion.callback(.failed)
            return
        }

        // Backspace then Unicode — not Shift+Left selection (duplicates in many apps).
        let deleteCount = resolved.expected.count
        guard deleteCount > 0,
              postBackspaces(count: deleteCount, to: focus.processID),
              postUnicodeText(resolved.replacement, to: focus.processID) else {
            isConverting = false
            completion.callback(.failed)
            return
        }
        isConverting = false
        completion.callback(.postedUnverified)
    }

    private func resolveSyntheticPair(
        expected: String,
        replacement: String,
        focus: FocusedElementIdentity
    ) -> (expected: String, replacement: String)? {
        var list = [(expected, replacement)]
        if expected.hasSuffix(" "), replacement.hasSuffix(" ") {
            list.append((String(expected.dropLast()), String(replacement.dropLast())))
        } else if !expected.hasSuffix(" "), !replacement.hasSuffix(" ") {
            list.append((expected + " ", replacement + " "))
        }

        var sawUnavailable = false
        for (exp, rep) in list {
            switch focusedSuffixProbe(exp, focus: focus, timeoutMilliseconds: 80) {
            case .match:
                return (exp, rep)
            case .mismatch:
                continue
            case .unavailable, .unchanged:
                sawUnavailable = true
            }
        }
        if sawUnavailable {
            return list[0]
        }
        return nil
    }

    nonisolated private func postBackspaces(count: Int, to processID: Int32) -> Bool {
        guard count > 0, let source = makeSource() else { return false }
        for _ in 0..<count {
            guard let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: KC.backspace,
                keyDown: true
            ), let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: KC.backspace,
                keyDown: false
            ) else { return false }
            down.postToPid(pid_t(processID))
            up.postToPid(pid_t(processID))
        }
        return true
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
        switch focusedElementResolver.withElement(
            processID: snapshot.processID,
            expectedIdentifier: snapshot.identifier,
            timeoutMilliseconds: 250,
            allowTreeSearch: true,
            operation: { lease -> ReplacementVerification in
                guard selectionMatches(snapshot, lease: lease) else {
                    return ReplacementVerification.mismatch
                }
                return setAndVerifySelectedText(
                    snapshot: snapshot,
                    replacement: replacement,
                    pollForDelayedCommit: pollForDelayedCommit,
                    lease: lease
                )
            }
        ) {
        case let .value(result):
            return result
        case .unavailable(.identifierMismatch):
            return .mismatch
        case .unavailable:
            return .unavailable
        }
    }

    nonisolated private func setAndVerifySelectedText(
        snapshot: SelectionSnapshot,
        replacement: String,
        pollForDelayedCommit: Bool,
        lease: NativeAXElementLease
    ) -> ReplacementVerification {
        let setResult = lease.setAttribute(
            kAXSelectedTextAttribute as CFString,
            value: replacement as CFString
        )
        guard setResult == .success else { return .unchanged }
        if !pollForDelayedCommit {
            return verifyReplacement(
                replacement,
                original: snapshot.text,
                originalRange: snapshot.range,
                lease: lease
            )
        }

        let deadline = Date().addingTimeInterval(0.25)
        var verification: ReplacementVerification = .unavailable
        repeat {
            verification = verifyReplacement(
                replacement,
                original: snapshot.text,
                originalRange: snapshot.range,
                lease: lease
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

    nonisolated private func readSelection(processID: pid_t) -> SelectionReadResult {
        switch focusedElementResolver.withElement(
            processID: processID,
            timeoutMilliseconds: 250,
            allowTreeSearch: true,
            operation: { lease -> SelectionReadResult in
                let rangeRead = lease.copyAttribute(kAXSelectedTextRangeAttribute as CFString)
                guard rangeRead.0 == .success, let rangeRaw = rangeRead.1,
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
                let textRead = lease.copyAttribute(kAXSelectedTextAttribute as CFString)
                guard textRead.0 == .success,
                      let text = textRead.1 as? String,
                      !text.isEmpty else {
                    return .fallback(selectionKnown: true, snapshot: nil)
                }
                return .selected(SelectionSnapshot(
                    processID: processID,
                    identifier: lease.identifier,
                    range: range,
                    text: text
                ))
            }
        ) {
        case let .value(result):
            return result
        case .unavailable:
            return .fallback(selectionKnown: false, snapshot: nil)
        }
    }

    nonisolated private func setAndVerifyFocusedSuffix(
        expected: String,
        replacement: String,
        focus: FocusedElementIdentity,
        pollForDelayedCommit: Bool
    ) -> ReplacementVerification {
        switch focusedElementResolver.withElement(
            processID: focus.processID,
            expectedIdentifier: focus.identifier,
            timeoutMilliseconds: 250,
            allowTreeSearch: true,
            operation: { lease -> ReplacementVerification in
                let rangeRead = lease.copyAttribute(kAXSelectedTextRangeAttribute as CFString)
                guard rangeRead.0 == .success, let rangeRaw = rangeRead.1,
                      CFGetTypeID(rangeRaw) == AXValueGetTypeID() else { return .unavailable }
                let rangeValue = unsafeDowncast(rangeRaw, to: AXValue.self)
                var caret = CFRange()
                guard AXValueGetType(rangeValue) == .cfRange,
                      AXValueGetValue(rangeValue, .cfRange, &caret),
                      caret.length == 0 else { return .mismatch }

                let expectedLength = expected.utf16.count
                guard caret.location >= expectedLength else { return .mismatch }
                var suffixRange = CFRange(
                    location: caret.location - expectedLength,
                    length: expectedLength
                )
                guard let suffixRangeValue = AXValueCreate(.cfRange, &suffixRange) else {
                    return .unavailable
                }
                let suffixRead = lease.copyParameterizedAttribute(
                    kAXStringForRangeParameterizedAttribute as CFString,
                    parameter: suffixRangeValue
                )
                guard suffixRead.0 == .success,
                      let actual = suffixRead.1 as? String else { return .unavailable }
                guard actual.precomposedStringWithCanonicalMapping
                        == expected.precomposedStringWithCanonicalMapping else { return .mismatch }

                guard lease.setAttribute(
                    kAXSelectedTextRangeAttribute as CFString,
                    value: suffixRangeValue
                ) == .success else { return .unchanged }

                let snapshot = SelectionSnapshot(
                    processID: focus.processID,
                    identifier: lease.identifier,
                    range: suffixRange,
                    text: expected
                )
                // Never call kAXSelectedText unless the selection is confirmed.
                // Setting it with an empty/wrong selection inserts and duplicates.
                guard selectionMatches(snapshot, lease: lease) else { return .unchanged }
                let verification = setAndVerifySelectedText(
                    snapshot: snapshot,
                    replacement: replacement,
                    pollForDelayedCommit: pollForDelayedCommit,
                    lease: lease
                )

                var finalRange = verification == .match
                    ? CFRange(location: suffixRange.location + replacement.utf16.count, length: 0)
                    : caret
                if let finalRangeValue = AXValueCreate(.cfRange, &finalRange) {
                    _ = lease.setAttribute(
                        kAXSelectedTextRangeAttribute as CFString,
                        value: finalRangeValue
                    )
                }
                return verification
            }
        ) {
        case let .value(result):
            return result
        case .unavailable(.identifierMismatch):
            return .mismatch
        case .unavailable:
            return .unavailable
        }
    }

    nonisolated private func selectionMatches(
        _ snapshot: SelectionSnapshot,
        lease: NativeAXElementLease
    ) -> Bool {
        let rangeRead = lease.copyAttribute(kAXSelectedTextRangeAttribute as CFString)
        guard rangeRead.0 == .success, let rangeRaw = rangeRead.1,
              CFGetTypeID(rangeRaw) == AXValueGetTypeID() else { return false }
        let rangeValue = unsafeDowncast(rangeRaw, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange,
              AXValueGetValue(rangeValue, .cfRange, &range) else { return false }
        guard range.location == snapshot.range.location,
              range.length == snapshot.range.length else { return false }
        let textRead = lease.copyAttribute(kAXSelectedTextAttribute as CFString)
        guard textRead.0 == .success, let text = textRead.1 as? String else { return false }
        return text.precomposedStringWithCanonicalMapping
            == snapshot.text.precomposedStringWithCanonicalMapping
    }

    nonisolated private func focusedSuffixProbe(
        _ expected: String,
        focus: FocusedElementIdentity,
        timeoutMilliseconds: Int
    ) -> ReplacementVerification {
        switch focusedElementResolver.withElement(
            processID: focus.processID,
            expectedIdentifier: focus.identifier,
            timeoutMilliseconds: timeoutMilliseconds,
            allowTreeSearch: true,
            operation: { lease -> ReplacementVerification in
                let rangeRead = lease.copyAttribute(kAXSelectedTextRangeAttribute as CFString)
                guard rangeRead.0 == .success, let rangeRaw = rangeRead.1,
                      CFGetTypeID(rangeRaw) == AXValueGetTypeID() else { return .unavailable }
                let rangeValue = unsafeDowncast(rangeRaw, to: AXValue.self)
                var caret = CFRange()
                guard AXValueGetType(rangeValue) == .cfRange,
                      AXValueGetValue(rangeValue, .cfRange, &caret),
                      caret.length == 0 else { return .mismatch }
                let expectedLength = expected.utf16.count
                guard caret.location >= expectedLength else { return .mismatch }
                var suffixRange = CFRange(
                    location: caret.location - expectedLength,
                    length: expectedLength
                )
                guard let suffixRangeValue = AXValueCreate(.cfRange, &suffixRange) else {
                    return .unavailable
                }
                let suffixRead = lease.copyParameterizedAttribute(
                    kAXStringForRangeParameterizedAttribute as CFString,
                    parameter: suffixRangeValue
                )
                guard suffixRead.0 == .success, let actual = suffixRead.1 as? String else {
                    return .unavailable
                }
                return actual.precomposedStringWithCanonicalMapping
                    == expected.precomposedStringWithCanonicalMapping
                    ? .match
                    : .mismatch
            }
        ) {
        case let .value(result):
            return result
        case .unavailable:
            return .unavailable
        }
    }

    nonisolated private func focusedSuffixMatches(
        _ expected: String,
        focus: FocusedElementIdentity,
        timeoutMilliseconds: Int
    ) -> Bool {
        focusedSuffixProbe(expected, focus: focus, timeoutMilliseconds: timeoutMilliseconds) == .match
    }

    nonisolated private func selectedTextMatches(
        _ expected: String,
        focus: FocusedElementIdentity,
        timeoutMilliseconds: Int
    ) -> Bool {
        switch focusedElementResolver.withElement(
            processID: focus.processID,
            expectedIdentifier: focus.identifier,
            timeoutMilliseconds: timeoutMilliseconds,
            allowTreeSearch: true,
            operation: { lease in
                let textRead = lease.copyAttribute(kAXSelectedTextAttribute as CFString)
                guard textRead.0 == .success, let text = textRead.1 as? String else { return false }
                return text.precomposedStringWithCanonicalMapping
                    == expected.precomposedStringWithCanonicalMapping
            }
        ) {
        case let .value(matched):
            return matched
        case .unavailable:
            return false
        }
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

    func recordPostedManualBuffer(
        _ conversion: BufferedManualConversion,
        transaction: ConversionTransaction
    ) {
        lastOriginal = transaction.originalTextForUndo
        lastConverted = transaction.insertedText
        lastLearningPair = (conversion.original, conversion.replacement)
        lastWasBuffer = true
        lastTransaction = transaction
        isConverting = false
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

    nonisolated private func postSelection(characterCount: Int, to processID: Int32) -> Bool {
        guard characterCount > 0, let source = makeSource() else { return false }
        guard let shiftDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: KC.leftShift,
            keyDown: true
        ) else { return false }
        shiftDown.flags = .maskShift
        shiftDown.postToPid(pid_t(processID))
        for _ in 0..<characterCount {
            guard let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: KC.left,
                keyDown: true
            ), let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: KC.left,
                keyDown: false
            ) else { return false }
            down.flags = .maskShift
            up.flags = .maskShift
            down.postToPid(pid_t(processID))
            up.postToPid(pid_t(processID))
        }
        guard let shiftUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: KC.leftShift,
            keyDown: false
        ) else { return false }
        shiftUp.flags = []
        shiftUp.postToPid(pid_t(processID))
        return true
    }

    nonisolated private func postUnicodeText(_ text: String, to processID: Int32) -> Bool {
        guard let source = makeSource(),
              let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: true
              ),
              let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: false
              ) else { return false }
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty else { return false }
        utf16.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
        }
        down.postToPid(pid_t(processID))
        up.postToPid(pid_t(processID))
        return true
    }

    nonisolated private func replacementEvents(for plan: EventReplacementPlan) -> [CGEvent]? {
        guard let source = makeSource() else { return nil }
        // Independent HID state for each key prevents some hosts from coalescing
        // rapid identical Backspaces into a single deletion (first char left over).
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
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

    /// Builds the next forced toggle without mutating the remembered pair.
    /// The caller commits it only after the targeted replacement was posted.
    func prepareReconversion(trailingSpaces: Int = 0) -> BufferedManualReconversion? {
        guard canReconvert else { return nil }
        // Do not set isConverting here — only once replaceFocusedSuffix actually
        // starts, otherwise a failed stage leaves canReconvert permanently false.
        let currentBody = lastConverted.trimmingCharacters(in: .whitespaces)
        let replacementBody = lastOriginal.trimmingCharacters(in: .whitespaces)
        guard !currentBody.isEmpty, !replacementBody.isEmpty else { return nil }

        // Match the word body first. Trailing spaces after auto-convert are
        // unreliable across editors (consumed vs replayed Space), and requiring
        // them caused reconversion to always mismatch and no-op.
        let spaceCount: Int
        if trailingSpaces > 0 {
            spaceCount = trailingSpaces
        } else if lastConverted.hasSuffix(" ") || lastOriginal.hasSuffix(" ") {
            spaceCount = 1
        } else if let transaction = lastTransaction, case .space = transaction.boundary {
            spaceCount = 1
        } else {
            spaceCount = 0
        }
        let spaces = String(repeating: " ", count: spaceCount)
        return BufferedManualReconversion(
            current: currentBody + spaces,
            replacement: replacementBody + spaces,
            targetLayoutID: lastTransaction?.sourceLayoutID
        )
    }

    func recordPostedReconversion(
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

    func discardTransactionIfCurrent(_ transaction: ConversionTransaction) {
        guard lastTransaction?.executionIdentity == transaction.executionIdentity else { return }
        clearState()
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

    nonisolated private func selectedText(from lease: NativeAXElementLease) -> String? {
        let read = lease.copyAttribute(kAXSelectedTextAttribute as CFString)
        guard read.0 == .success else { return nil }
        return read.1 as? String
    }

    nonisolated private func verifyReplacement(
        _ replacement: String,
        original: String,
        originalRange: CFRange,
        lease: NativeAXElementLease
    ) -> ReplacementVerification {
        var range = CFRange(location: originalRange.location, length: replacement.utf16.count)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return .unavailable }
        let read = lease.copyParameterizedAttribute(
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter: rangeValue
        )
        guard read.0 == .success, let actual = read.1 as? String else {
            guard let selected = selectedText(from: lease) else { return .unavailable }
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
        let item = transientPasteboardItem(text: replacement)
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
                let verified: ReplacementVerification
                switch self.focusedElementResolver.withElement(
                    processID: snapshot.processID,
                    expectedIdentifier: snapshot.identifier,
                    timeoutMilliseconds: 250,
                    allowTreeSearch: true,
                    operation: { lease in
                        self.verifyReplacement(
                            replacement,
                            original: text,
                            originalRange: snapshot.range,
                            lease: lease
                        )
                    }
                ) {
                case let .value(result):
                    verified = result
                case .unavailable:
                    verified = .unavailable
                }
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
        pasteboard.addTypes([
            Self.transientPasteboardType,
            Self.concealedPasteboardType,
        ], owner: nil)
        pasteboard.setData(Data(), forType: Self.transientPasteboardType)
        pasteboard.setData(Data(), forType: Self.concealedPasteboardType)
        clipboardTemporaryChangeCount = pasteboard.changeCount
    }

    private func transientPasteboardItem(text: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.transientPasteboardType)
        item.setData(Data(), forType: Self.concealedPasteboardType)
        return item
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
    private func scheduleClipboardRestore(after delay: TimeInterval = 2.0) {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
