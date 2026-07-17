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

struct CaretWordConversion {
    let original: String
    let replacement: String
    let expectedSuffix: String
    let elementIdentifier: String
    let caretLocation: Int
    let sourceLayoutID: String?
    let targetLayoutID: String?
}

enum CaretWordPreparationOutcome {
    case conversion(CaretWordConversion)
    case noCandidate
    case busy
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
    sourceLayoutID: String?,
    targetLayoutID: String?
)

private struct CaretPrefix: Sendable {
    let text: String
    let beginsAtDocumentStart: Bool
    let elementIdentifier: String
    let caretLocation: Int
}

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
        /// Only used to teach `ManualHostPolicy` when a replacement turns out
        /// to insert instead of replace; not part of AX identity/matching.
        let bundleID: String?

        init(processID: pid_t, identifier: String, range: CFRange, text: String, bundleID: String? = nil) {
            self.processID = processID
            self.identifier = identifier
            self.range = range
            self.text = text
            self.bundleID = bundleID
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

    private final class CaretCompletionBox: @unchecked Sendable {
        let callback: (CaretWordPreparationOutcome) -> Void

        init(_ callback: @escaping (CaretWordPreparationOutcome) -> Void) {
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
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            isConverting = false
            completion(.none)
            return
        }
        let processID = frontmost.processIdentifier
        let bundleID = frontmost.bundleIdentifier
        let completion = ManualCompletionBox(completion)
        manualQueue.async { [weak self] in
            guard let self else { return }
            let result = self.readSelection(processID: processID, bundleID: bundleID)
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
    ///
    /// Hosts with unreliable AX selection (Ghostty, Codex, terminals) use
    /// targeted Backspace+Unicode instead: setting `kAXSelectedText` without a
    /// real selection inserts and duplicates (`converted` + original).
    func replaceFocusedSuffix(
        expected: String,
        replacement: String,
        focus: FocusedElementIdentity,
        expectedCaretLocation: Int? = nil,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        completion: @escaping (ManualSuffixReplacementOutcome) -> Void
    ) {
        guard !expected.isEmpty, !replacement.isEmpty, isCurrent() else {
            completion(.failed)
            return
        }
        isConverting = true
        let completion = SuffixCompletionBox(completion)
        if ManualHostPolicy.shared.prefersKeyboardDeletion(bundleID: focus.bundleID)
            || CommandLine.arguments.contains("--force-keyboard-deletion-fallback")
        {
            replaceFocusedSuffixViaKeyboardDeletion(
                expected: expected,
                replacement: replacement,
                focus: focus,
                expectedCaretLocation: expectedCaretLocation,
                isCurrent: isCurrent,
                completion: completion
            )
            return
        }
        if CommandLine.arguments.contains("--force-synthetic-input-fallback") {
            finishFocusedSuffixReplacement(
                .unchanged,
                expected: expected,
                replacement: replacement,
                focus: focus,
                expectedCaretLocation: expectedCaretLocation,
                isCurrent: isCurrent,
                completion: completion
            )
            return
        }
        if CommandLine.arguments.contains("--force-ax-unavailable-fallback") {
            finishFocusedSuffixReplacement(
                .unavailable,
                expected: expected,
                replacement: replacement,
                focus: focus,
                expectedCaretLocation: expectedCaretLocation,
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
                expectedCaretLocation: expectedCaretLocation,
                pollForDelayedCommit: false
            )
            finishFocusedSuffixReplacement(
                verification,
                expected: expected,
                replacement: replacement,
                focus: focus,
                expectedCaretLocation: expectedCaretLocation,
                isCurrent: isCurrent,
                completion: completion
            )
            return
        }
        // External hosts: convert the current/previous word by keyboard
        // (Backspace + Unicode), not by an AX `kAXSelectedText` write. Setting
        // that attribute over a *programmatically* created selection inserts
        // instead of replacing in Chromium/Electron (Claude desktop, VS Code)
        // and terminals, leaving the original word and duplicating text. The
        // keystroke path is the same mechanism the automatic converter already
        // uses successfully in those hosts, and it is gated by an AX suffix
        // probe plus the isCurrent()/frontmost recheck before deleting. A real,
        // user-made selection still takes the AX path in `readSelection`.
        replaceFocusedSuffixViaKeyboardDeletion(
            expected: expected,
            replacement: replacement,
            focus: focus,
            expectedCaretLocation: expectedCaretLocation,
            isCurrent: isCurrent,
            completion: completion
        )
    }

    private func finishFocusedSuffixReplacement(
        _ verification: ReplacementVerification,
        expected: String,
        replacement: String,
        focus: FocusedElementIdentity,
        expectedCaretLocation: Int?,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        completion: SuffixCompletionBox
    ) {
        switch verification {
        case .match:
            completion.callback(.verified)
        case .unchanged:
            if ManualHostPolicy.shared.prefersKeyboardDeletion(bundleID: focus.bundleID) {
                replaceFocusedSuffixViaKeyboardDeletion(
                    expected: expected,
                    replacement: replacement,
                    focus: focus,
                    expectedCaretLocation: expectedCaretLocation,
                    isCurrent: isCurrent,
                    completion: completion
                )
            } else {
                replaceFocusedSuffixViaSyntheticInput(
                    expected: expected,
                    replacement: replacement,
                    focus: focus,
                    expectedCaretLocation: expectedCaretLocation,
                    isCurrent: isCurrent,
                    completion: completion
                )
            }
        case .unavailable:
            // AX could not confirm the caret content at all — the common case
            // for terminal emulators that expose little or no Accessibility
            // text API. Do not give up: fall through to Backspace+Unicode for
            // ANY host here, not only ones pre-listed by bundle ID. Safety
            // comes from the isCurrent()/frontmost recheck immediately before
            // posting inside replaceFocusedSuffixViaKeyboardDeletion, not from
            // AX confirmation (which is exactly what is unavailable).
            replaceFocusedSuffixViaKeyboardDeletion(
                expected: expected,
                replacement: replacement,
                focus: focus,
                expectedCaretLocation: expectedCaretLocation,
                isCurrent: isCurrent,
                completion: completion
            )
        case .mismatch:
            // AX read successfully and confirmed the caret is NOT where
            // expected — a real, positive signal that state drifted. Keep
            // the text unchanged rather than guessing.
            isConverting = false
            completion.callback(.failed)
        }
    }

    /// Backspace + Unicode for hosts that cannot select-and-replace safely.
    /// Only posts after the expected suffix is still under the caret when AX
    /// can read it; pure TTY (AX unavailable) still posts using grapheme count.
    private func replaceFocusedSuffixViaKeyboardDeletion(
        expected: String,
        replacement: String,
        focus: FocusedElementIdentity,
        expectedCaretLocation: Int?,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        completion: SuffixCompletionBox
    ) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID,
              isCurrent() else {
            isConverting = false
            completion.callback(.failed)
            return
        }
        let probe = focusedSuffixProbe(
            expected,
            focus: focus,
            expectedCaretLocation: expectedCaretLocation,
            timeoutMilliseconds: 50
        )
        switch probe {
        case .mismatch:
            isConverting = false
            completion.callback(.failed)
            return
        case .match, .unchanged, .unavailable:
            break
        }
        // Re-check freshness right before the destructive Backspace burst.
        // The probe above is itself an AX round-trip (up to 50 ms); when it
        // returns .unavailable there is no content confirmation at all, so
        // this recheck — not AX — is the only thing standing between "safe"
        // and "delete whatever is actually under the caret now".
        guard isCurrent(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID else {
            isConverting = false
            completion.callback(.failed)
            return
        }

        // Prefer grapheme count for Backspace keys; utf16 length can over-delete
        // on some composed sequences, but EN/RU layout tokens are BMP.
        let backspaceCount = max(expected.count, expected.utf16.count)
        guard backspaceCount > 0,
              let source = makeSource() else {
            isConverting = false
            completion.callback(.failed)
            return
        }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        for _ in 0..<backspaceCount {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: KC.backspace, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: KC.backspace, keyDown: false)
            else {
                isConverting = false
                completion.callback(.failed)
                return
            }
            down.postToPid(pid_t(focus.processID))
            up.postToPid(pid_t(focus.processID))
        }
        guard postUnicodeText(replacement, to: focus.processID) else {
            isConverting = false
            completion.callback(.failed)
            return
        }
        rslog("manual_keyboard_deletion_posted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            guard isCurrent(),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID else {
                self.isConverting = false
                completion.callback(.failed)
                return
            }
            if self.focusedSuffixMatches(
                replacement,
                focus: focus,
                timeoutMilliseconds: 40
            ) {
                completion.callback(.verified)
            } else {
                // Terminals often cannot read back; treat as posted, never learn.
                completion.callback(.postedUnverified)
            }
        }
    }

    private func replaceFocusedSuffixViaSyntheticInput(
        expected: String,
        replacement: String,
        focus: FocusedElementIdentity,
        expectedCaretLocation: Int?,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        completion: SuffixCompletionBox
    ) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID,
              !expected.isEmpty,
              isCurrent(),
              focusedSuffixMatches(
                expected,
                focus: focus,
                expectedCaretLocation: expectedCaretLocation,
                timeoutMilliseconds: 50
              ) else {
            isConverting = false
            completion.callback(.failed)
            return
        }

        guard postSelection(characterCount: expected.count, to: focus.processID) else {
            isConverting = false
            completion.callback(.failed)
            return
        }
        let selectionDeadline = DispatchTime.now().uptimeNanoseconds + 90_000_000
        waitForSyntheticSelection(
            expected: expected,
            replacement: replacement,
            focus: focus,
            isCurrent: isCurrent,
            deadlineNanoseconds: selectionDeadline,
            completion: completion
        )
    }

    /// Targeted selection events are delivered asynchronously. Polling a few
    /// times avoids a fixed-delay race while preserving the exact-text safety
    /// check: Unicode is never posted unless the intended suffix is selected.
    private func waitForSyntheticSelection(
        expected: String,
        replacement: String,
        focus: FocusedElementIdentity,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        deadlineNanoseconds: UInt64,
        completion: SuffixCompletionBox
    ) {
        guard isCurrent(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID else {
            isConverting = false
            completion.callback(.failed)
            return
        }
        // Require a real non-empty selection range, not only SelectedText string.
        // Some Electron hosts echo the caret word as "selected" without selecting.
        if selectedRangeAndTextMatch(expected, focus: focus, timeoutMilliseconds: 12) {
            guard postUnicodeText(replacement, to: focus.processID) else {
                isConverting = false
                completion.callback(.failed)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self else { return }
                guard isCurrent(),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processID else {
                    self.isConverting = false
                    completion.callback(.failed)
                    return
                }
                completion.callback(.postedUnverified)
            }
            return
        }
        guard DispatchTime.now().uptimeNanoseconds < deadlineNanoseconds else {
            isConverting = false
            completion.callback(.failed)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { [weak self] in
            self?.waitForSyntheticSelection(
                expected: expected,
                replacement: replacement,
                focus: focus,
                isCurrent: isCurrent,
                deadlineNanoseconds: deadlineNanoseconds,
                completion: completion
            )
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
            let quick = verifyReplacement(
                replacement,
                original: snapshot.text,
                originalRange: snapshot.range,
                lease: lease
            )
            if quick == .match { return .match }
            if recoverInsertedReplacement(
                original: snapshot.text,
                replacement: replacement,
                originalRange: snapshot.range,
                bundleID: snapshot.bundleID,
                lease: lease
            ) {
                return .match
            }
            return quick
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
            if verification == .match { return .match }
            if verification == .mismatch {
                // Host inserted instead of replacing → converted+original at caret.
                if recoverInsertedReplacement(
                    original: snapshot.text,
                    replacement: replacement,
                    originalRange: snapshot.range,
                    bundleID: snapshot.bundleID,
                    lease: lease
                ) {
                    return .match
                }
                break
            }
            if Date() < deadline { usleep(5_000) }
        } while Date() < deadline
        return verification
    }

    /// When `kAXSelectedText` inserts at the selection start instead of replacing,
    /// the buffer becomes `replacement + original`. Collapse it back to `replacement`.
    nonisolated private func recoverInsertedReplacement(
        original: String,
        replacement: String,
        originalRange: CFRange,
        bundleID: String?,
        lease: NativeAXElementLease
    ) -> Bool {
        let combined = (replacement + original).precomposedStringWithCanonicalMapping
        let combinedLength = combined.utf16.count
        guard combinedLength > original.utf16.count else { return false }
        var probe = CFRange(location: originalRange.location, length: combinedLength)
        guard let probeValue = AXValueCreate(.cfRange, &probe) else { return false }
        let read = lease.copyParameterizedAttribute(
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter: probeValue
        )
        guard read.0 == .success,
              let actual = read.1 as? String,
              actual.precomposedStringWithCanonicalMapping == combined else { return false }
        // Confirmed (not merely suspected): this host's kAXSelectedTextAttribute
        // write inserted instead of replacing. Remember it so the next manual
        // conversion for this app skips straight to Backspace+Unicode instead
        // of duplicating text again first.
        ManualHostPolicy.shared.learnPrefersKeyboardDeletion(bundleID: bundleID)
        guard lease.setAttribute(
            kAXSelectedTextRangeAttribute as CFString,
            value: probeValue
        ) == .success else { return false }
        guard lease.setAttribute(
            kAXSelectedTextAttribute as CFString,
            value: replacement as CFString
        ) == .success else { return false }
        let verified = verifyReplacement(
            replacement,
            original: original,
            originalRange: originalRange,
            lease: lease
        )
        if verified == .match {
            rslog("manual_ax_insert_recovered")
            return true
        }
        return false
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

    nonisolated private func readSelection(processID: pid_t, bundleID: String?) -> SelectionReadResult {
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
                    text: text,
                    bundleID: bundleID
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
        expectedCaretLocation: Int?,
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
                if let expectedCaretLocation,
                   caret.location != expectedCaretLocation { return .mismatch }

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
                    text: expected,
                    bundleID: focus.bundleID
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

    nonisolated private func readTextBeforeCaret(
        focus: FocusedElementIdentity,
        maxUTF16Length: Int
    ) -> CaretPrefix? {
        switch focusedElementResolver.withElement(
            processID: focus.processID,
            expectedIdentifier: focus.identifier,
            timeoutMilliseconds: 250,
            allowTreeSearch: true,
            operation: { lease -> CaretPrefix? in
                let rangeRead = lease.copyAttribute(kAXSelectedTextRangeAttribute as CFString)
                guard rangeRead.0 == .success, let rangeRaw = rangeRead.1,
                      CFGetTypeID(rangeRaw) == AXValueGetTypeID() else { return nil }
                let rangeValue = unsafeDowncast(rangeRaw, to: AXValue.self)
                var caret = CFRange()
                guard AXValueGetType(rangeValue) == .cfRange,
                      AXValueGetValue(rangeValue, .cfRange, &caret),
                      caret.length == 0,
                      caret.location > 0 else { return nil }
                let length = min(max(1, maxUTF16Length), caret.location)
                var prefixRange = CFRange(location: caret.location - length, length: length)
                guard let prefixValue = AXValueCreate(.cfRange, &prefixRange) else { return nil }
                let textRead = lease.copyParameterizedAttribute(
                    kAXStringForRangeParameterizedAttribute as CFString,
                    parameter: prefixValue
                )
                guard textRead.0 == .success, let text = textRead.1 as? String else { return nil }
                guard !text.isEmpty else { return nil }
                return CaretPrefix(
                    text: text,
                    beginsAtDocumentStart: prefixRange.location == 0,
                    elementIdentifier: lease.identifier,
                    caretLocation: caret.location
                )
            }
        ) {
        case let .value(text):
            return text
        case .unavailable:
            return nil
        }
    }

    nonisolated private func focusedSuffixProbe(
        _ expected: String,
        focus: FocusedElementIdentity,
        expectedCaretLocation: Int? = nil,
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
                if let expectedCaretLocation,
                   caret.location != expectedCaretLocation { return .mismatch }
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
        expectedCaretLocation: Int? = nil,
        timeoutMilliseconds: Int
    ) -> Bool {
        focusedSuffixProbe(
            expected,
            focus: focus,
            expectedCaretLocation: expectedCaretLocation,
            timeoutMilliseconds: timeoutMilliseconds
        ) == .match
    }

    nonisolated private func selectedTextMatches(
        _ expected: String,
        focus: FocusedElementIdentity,
        timeoutMilliseconds: Int
    ) -> Bool {
        selectedRangeAndTextMatch(expected, focus: focus, timeoutMilliseconds: timeoutMilliseconds)
    }

    /// True only when AX reports a selection whose length and text both match.
    nonisolated private func selectedRangeAndTextMatch(
        _ expected: String,
        focus: FocusedElementIdentity,
        timeoutMilliseconds: Int
    ) -> Bool {
        let expectedLength = expected.utf16.count
        guard expectedLength > 0 else { return false }
        switch focusedElementResolver.withElement(
            processID: focus.processID,
            expectedIdentifier: focus.identifier,
            timeoutMilliseconds: timeoutMilliseconds,
            allowTreeSearch: true,
            operation: { lease in
                let rangeRead = lease.copyAttribute(kAXSelectedTextRangeAttribute as CFString)
                guard rangeRead.0 == .success, let rangeRaw = rangeRead.1,
                      CFGetTypeID(rangeRaw) == AXValueGetTypeID() else { return false }
                let rangeValue = unsafeDowncast(rangeRaw, to: AXValue.self)
                var range = CFRange()
                guard AXValueGetType(rangeValue) == .cfRange,
                      AXValueGetValue(rangeValue, .cfRange, &range),
                      range.length == expectedLength else { return false }
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
            // A genuinely separate source per Backspace pair, not just the
            // suppression filter: GPU terminals (Ghostty) coalesce identical
            // key events from one source posted back-to-back, eating the first
            // deletion and leaving the word's first character behind.
            guard let pairSource = makeSource(),
                  let down = CGEvent(keyboardEventSource: pairSource, virtualKey: KC.backspace, keyDown: true),
                  let up = CGEvent(keyboardEventSource: pairSource, virtualKey: KC.backspace, keyDown: false) else {
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

    /// Recovers the last token after focus/navigation cleared the physical-key
    /// buffer. AX work stays off the main/event-tap thread; replacement still
    /// performs a fresh identity and exact-suffix check.
    func prepareCaretWordConversion(
        focus: FocusedElementIdentity,
        completion: @escaping (CaretWordPreparationOutcome) -> Void
    ) {
        guard !isConverting else {
            completion(.busy)
            return
        }
        isConverting = true
        let completion = CaretCompletionBox(completion)
        manualQueue.async { [weak self] in
            guard let self else { return }
            let prefix = self.readTextBeforeCaret(focus: focus, maxUTF16Length: 96)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isConverting = false
                guard let prefix,
                      let parsed = CaretTokenParser.tokenBeforeCaret(
                        from: prefix.text,
                        tokenAtInputStartIsComplete: prefix.beginsAtDocumentStart
                      ),
                      let conversion = DynamicKeyMapping.convertSelectedText(parsed.word)
                else {
                    completion.callback(.noCandidate)
                    return
                }
                let replacement = self.manualReplacement(
                    typed: parsed.word,
                    converted: conversion.converted,
                    targetLanguage: conversion.targetLanguage
                )
                guard replacement != parsed.word else {
                    completion.callback(.noCandidate)
                    return
                }
                completion.callback(.conversion(CaretWordConversion(
                    original: parsed.word,
                    replacement: replacement,
                    expectedSuffix: parsed.word + parsed.trailingWhitespace,
                    elementIdentifier: prefix.elementIdentifier,
                    caretLocation: prefix.caretLocation,
                    sourceLayoutID: conversion.sourceLayoutID,
                    targetLayoutID: conversion.targetLayoutID
                )))
            }
        }
    }

    func recordPostedCaretWord(
        _ conversion: CaretWordConversion,
        transaction: ConversionTransaction
    ) {
        lastOriginal = transaction.originalTextForUndo
        lastConverted = transaction.insertedText
        lastLearningPair = (conversion.original, conversion.replacement)
        lastWasBuffer = true
        lastTransaction = transaction
        lastManualTargetLayoutID = conversion.targetLayoutID
        isConverting = false
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
        } else if let transaction = lastTransaction,
                  case let .space(count) = transaction.boundary {
            spaceCount = max(1, count)
        } else if lastConverted.hasSuffix(" ") || lastOriginal.hasSuffix(" ") {
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
