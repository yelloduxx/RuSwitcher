import AppKit
import Carbon
import CoreGraphics
import Foundation
import RuSwitcherCore

private struct HIDProbeResult: Codable {
    let scenario: String
    let text: String
    let layoutID: String
    let postEventAccess: Bool
    let manualText: String?
    let learningConfirmed: Bool?
    let pasteboardChangeCountDelta: Int
    let postedAutomaticReplacementCount: Int
    let verifiedAutomaticReplacementCount: Int
    let unexpectedInputEventCount: Int
    let layoutMismatchStrokes: [String]
    let boundaryDeliveryTimeouts: [Int]
}

private struct HIDProbeScenario {
    struct Phase {
        let sourceLanguage: String
        let typedText: String

        init(sourceLanguage: String, typedText: String) {
            self.sourceLanguage = sourceLanguage
            self.typedText = typedText
        }
    }

    private struct Fixture: Decodable {
        struct FixturePhase: Decodable {
            let sourceLanguage: String
            let text: String
        }

        let name: String
        let phases: [FixturePhase]
    }

    let name: String
    let phases: [Phase]
    let manualLearningSource: String?
    let triggerAfterTyping: Bool
    let autoConvertEnabled: Bool

    init(
        name: String,
        phases: [Phase],
        manualLearningSource: String? = nil,
        triggerAfterTyping: Bool = false,
        autoConvertEnabled: Bool = true
    ) {
        self.name = name
        self.phases = phases
        self.manualLearningSource = manualLearningSource
        self.triggerAfterTyping = triggerAfterTyping
        self.autoConvertEnabled = autoConvertEnabled
    }

    static func named(_ name: String) -> HIDProbeScenario? {
        switch name {
        case "manual-learning-double-shift":
            let source = "qazwsxedc"
            return HIDProbeScenario(
                name: name,
                phases: [Phase(sourceLanguage: "en", typedText: source + " ")],
                manualLearningSource: source
            )
        case "manual-buffer-double-shift":
            return HIDProbeScenario(
                name: name,
                phases: [
                    Phase(sourceLanguage: "ru", typedText: "сегодня я "),
                    Phase(sourceLanguage: "en", typedText: "ghbdtn"),
                ],
                triggerAfterTyping: true
            )
        case "manual-previous-word-double-shift":
            return HIDProbeScenario(
                name: name,
                phases: [
                    Phase(sourceLanguage: "ru", typedText: "сегодня я "),
                    Phase(sourceLanguage: "en", typedText: "ghbdtn "),
                ],
                triggerAfterTyping: true,
                autoConvertEnabled: false
            )
        default:
            return nil
        }
    }

    static func fixture(at path: String) throws -> HIDProbeScenario {
        let fixture = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: path))
        )
        guard !fixture.phases.isEmpty else {
            throw NSError(
                domain: "RuSwitcher.HIDProbe",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "HID fixture has no phases"]
            )
        }
        return HIDProbeScenario(
            name: fixture.name,
            phases: fixture.phases.map {
                Phase(sourceLanguage: $0.sourceLanguage, typedText: $0.text)
            }
        )
    }
}

private struct HIDProbeStroke {
    let keyCode: CGKeyCode
    let shift: Bool
}

private struct HIDProbePlannedPhase {
    let sourceLanguage: String
    let strokes: [HIDProbeStroke]
    let trailingBoundary: Character?
}

@MainActor
enum HIDIntegrationProbe {
    private static var retainedDelegate: HIDProbeDelegate?

    static func run(scenarioName: String, resultPath: String?) -> Never {
        guard let scenario = HIDProbeScenario.named(scenarioName) else {
            FileHandle.standardError.write(Data("unknown HID probe scenario\n".utf8))
            exit(64)
        }
        run(scenario: scenario, resultPath: resultPath)
    }

    static func run(
        fixturePath: String,
        resultPath: String?,
        startProductionMonitoring: Bool = true
    ) -> Never {
        let scenario: HIDProbeScenario
        do {
            scenario = try HIDProbeScenario.fixture(at: fixturePath)
        } catch {
            FileHandle.standardError.write(Data("invalid HID probe fixture: \(error)\n".utf8))
            exit(64)
        }
        run(
            scenario: scenario,
            resultPath: resultPath,
            startProductionMonitoring: startProductionMonitoring
        )
    }

    private static func run(
        scenario: HIDProbeScenario,
        resultPath: String?,
        startProductionMonitoring: Bool = true
    ) -> Never {
        var textServiceOverrides = UserDefaults.standard.volatileDomain(
            forName: UserDefaults.argumentDomain
        )
        textServiceOverrides["NSAutomaticPeriodSubstitutionEnabled"] = false
        textServiceOverrides["NSAutomaticCapitalizationEnabled"] = false
        UserDefaults.standard.setVolatileDomain(
            textServiceOverrides,
            forName: UserDefaults.argumentDomain
        )
        let app = NSApplication.shared
        let delegate = HIDProbeDelegate(
            scenario: scenario,
            resultPath: resultPath,
            startProductionMonitoring: startProductionMonitoring
        )
        retainedDelegate = delegate
        app.delegate = delegate
        app.run()
        exit(0)
    }
}

@MainActor
private final class HIDProbeDelegate: NSObject, NSApplicationDelegate {
    private let scenario: HIDProbeScenario
    private let resultPath: String?
    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 180))
    private var window: NSWindow?
    private var originalLayoutID = ""
    private var didPostKeys = false
    private var eventSource: CGEventSource?
    private var plannedPhases: [HIDProbePlannedPhase] = []
    private var manualObservedText: String?
    private var layoutMismatchStrokes: [String] = []
    private var boundaryDeliveryTimeouts: [Int] = []
    private var didStartProductionMonitoring = false
    private var didPostTrailingTrigger = false
    private var initialPasteboardChangeCount = 0
    private var unexpectedInputEventCount = 0
    private var localEventMonitor: Any?
    private let productionDelegate = AppDelegate()
    private let startProductionMonitoring: Bool

    init(
        scenario: HIDProbeScenario,
        resultPath: String?,
        startProductionMonitoring: Bool = true
    ) {
        self.scenario = scenario
        self.resultPath = resultPath
        self.startProductionMonitoring = startProductionMonitoring
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        initialPasteboardChangeCount = NSPasteboard.general.changeCount
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 640, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "RuSwitcher HID Probe: \(scenario.name)"
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.enabledTextCheckingTypes = 0
        textView.isContinuousSpellCheckingEnabled = false
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let marker = event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
            if marker != 0x52535445, marker != kRuSwitcherEventMarker {
                self?.unexpectedInputEventCount += 1
            }
            return event
        }
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        self.window = window

        originalLayoutID = LayoutSwitcher.currentLayoutID()
        releaseModifiers()
        if let source = scenario.manualLearningSource {
            startManualLearningProbe(source: source)
            return
        }
        guard let firstPhase = scenario.phases.first,
              selectLayout(language: firstPhase.sourceLanguage) else {
            finish(text: "<layout-unavailable>")
            return
        }

        // Let any input queued before this probe drain before the production
        // monitor starts. The editor is cleared only after focus is stable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.prepareAutomatedInput()
        }
    }

    private func startManualLearningProbe(source: String) {
        guard selectLayout(language: "en") else {
            finish(text: "<layout-unavailable>")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.prepareManualLearningInput(source: source)
        }
    }

    private func prepareAutomatedInput(attempt: Int = 0) {
        guard focusProbeWindow(attempt: attempt) else { return }
        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        releaseModifiers()
        startProductionMonitoringIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.postPhysicalKeys()
        }
    }

    private func prepareManualLearningInput(source: String, attempt: Int = 0) {
        guard focusProbeWindow(attempt: attempt) else { return }
        textView.string = source
        textView.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))
        releaseModifiers()
        startProductionMonitoringIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.postDoubleShift()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard let self else { return }
            self.manualObservedText = self.textView.string
            self.textView.string = ""
            self.textView.setSelectedRange(NSRange(location: 0, length: 0))
            self.window?.makeFirstResponder(self.textView)
            self.postPhysicalKeys()
        }
    }

    private func focusProbeWindow(attempt: Int) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
        let focused = NSWorkspace.shared.frontmostApplication?.processIdentifier
            == ProcessInfo.processInfo.processIdentifier
            && window?.isKeyWindow == true
            && window?.firstResponder === textView
        guard !focused, attempt < 10 else {
            if !focused { finish(text: "<focus-unavailable>") }
            return focused
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            if self.scenario.manualLearningSource != nil {
                self.prepareManualLearningInput(
                    source: self.scenario.manualLearningSource ?? "",
                    attempt: attempt + 1
                )
            } else {
                self.prepareAutomatedInput(attempt: attempt + 1)
            }
        }
        return false
    }

    private func startProductionMonitoringIfNeeded() {
        guard startProductionMonitoring, !didStartProductionMonitoring else { return }
        didStartProductionMonitoring = true
        let settings = SettingsManager.shared
        settings.autoSwitchEnabled = true
        settings.autoConvert = scenario.autoConvertEnabled
        settings.triggerKey = "shift"
        settings.triggerRightOnly = false
        settings.triggerDoubleTap = true
        settings.remoteDesktopMode = false
        settings.deniedWords = []
        settings.alwaysConvertWords = []
        productionDelegate.startHIDProbeMonitoring()
    }

    private func postDoubleShift() {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            finish(text: "<event-source-unavailable>")
            return
        }
        source.userData = 0x52535445
        postShiftTap(source: source) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                self?.postShiftTap(source: source, completion: {})
            }
        }
    }

    private func postShiftTap(source: CGEventSource, completion: @escaping () -> Void) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: true)
        down?.flags = [.maskShift]
        down?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            let up = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: false)
            up?.flags = []
            up?.post(tap: .cghidEventTap)
            completion()
        }
    }

    private func postPhysicalKeys(attempt: Int = 0) {
        guard !didPostKeys else { return }
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
        let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        guard isFrontmost, window?.isKeyWindow == true, window?.firstResponder === textView else {
            if attempt < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.postPhysicalKeys(attempt: attempt + 1)
                }
            } else {
                finish(text: "<focus-unavailable>")
            }
            return
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            finish(text: "<event-source-unavailable>")
            return
        }
        source.userData = 0x52535445 // RSTE: deliberately not RuSwitcher's synthetic marker.
        var phases: [HIDProbePlannedPhase] = []
        for phase in scenario.phases {
            guard let strokes = physicalStrokes(
                for: phase.typedText,
                language: phase.sourceLanguage
            ) else {
                finish(text: "<unmappable-fixture-text>")
                return
            }
            let trailingBoundary = phase.typedText.last.flatMap { character in
                [" ", "\n", "\t"].contains(character) ? character : nil
            }
            phases.append(HIDProbePlannedPhase(
                sourceLanguage: phase.sourceLanguage,
                strokes: strokes,
                trailingBoundary: trailingBoundary
            ))
        }
        didPostKeys = true
        eventSource = source
        plannedPhases = phases
        postPhase(at: 0)
    }

    private func postPhase(at phaseIndex: Int) {
        guard plannedPhases.indices.contains(phaseIndex) else {
            if scenario.triggerAfterTyping, !didPostTrailingTrigger {
                didPostTrailingTrigger = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.postDoubleShift()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self else { return }
                    self.manualObservedText = self.textView.string
                    self.finish(text: self.textView.string)
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                self.finish(text: self.textView.string)
            }
            return
        }
        let phase = plannedPhases[phaseIndex]
        guard selectLayout(language: phase.sourceLanguage) else {
            finish(text: "<layout-unavailable>")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { [weak self] in
            self?.postStroke(phaseIndex: phaseIndex, strokeIndex: 0)
        }
    }

    private func postStroke(phaseIndex: Int, strokeIndex: Int) {
        guard plannedPhases.indices.contains(phaseIndex), let source = eventSource else { return }
        let phase = plannedPhases[phaseIndex]
        guard phase.strokes.indices.contains(strokeIndex) else {
            waitForBoundaryDelivery(phaseIndex: phaseIndex, attempt: 0)
            return
        }
        let stroke = phase.strokes[strokeIndex]
        if LayoutSwitcher.currentLanguageCode() != phase.sourceLanguage {
            layoutMismatchStrokes.append("\(phaseIndex):\(strokeIndex)")
        }
        let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: stroke.keyCode,
            keyDown: true
        )
        keyDown?.flags = stroke.shift ? [.maskShift] : []
        keyDown?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            guard let self, let source = self.eventSource else { return }
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: stroke.keyCode,
                keyDown: false
            )
            keyUp?.flags = stroke.shift ? [.maskShift] : []
            keyUp?.post(tap: .cghidEventTap)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { [weak self] in
                self?.postStroke(phaseIndex: phaseIndex, strokeIndex: strokeIndex + 1)
            }
        }
    }

    private func waitForBoundaryDelivery(phaseIndex: Int, attempt: Int) {
        guard plannedPhases.indices.contains(phaseIndex) else { return }
        let boundary = plannedPhases[phaseIndex].trailingBoundary
        if boundary == nil || textView.string.last == boundary {
            postPhase(at: phaseIndex + 1)
            return
        }
        guard attempt < 100 else {
            boundaryDeliveryTimeouts.append(phaseIndex)
            postPhase(at: phaseIndex + 1)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { [weak self] in
            self?.waitForBoundaryDelivery(phaseIndex: phaseIndex, attempt: attempt + 1)
        }
    }

    private func finish(text: String) {
        releaseModifiers()
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        let resultingLayoutID = LayoutSwitcher.currentLayoutID()
        if !originalLayoutID.isEmpty { LayoutSwitcher.switchTo(layoutID: originalLayoutID) }
        let result = HIDProbeResult(
            scenario: scenario.name,
            text: text,
            layoutID: resultingLayoutID,
            postEventAccess: CGPreflightPostEventAccess(),
            manualText: manualObservedText,
            learningConfirmed: scenario.manualLearningSource.map { source in
                SettingsManager.shared.isAdaptiveConfirmed(
                    original: source,
                    converted: KeyMapping.convert(source),
                    appBundleID: nil
                )
            },
            pasteboardChangeCountDelta: NSPasteboard.general.changeCount
                - initialPasteboardChangeCount,
            postedAutomaticReplacementCount: productionDelegate.postedAutomaticReplacementCount,
            verifiedAutomaticReplacementCount: productionDelegate.verifiedAutomaticReplacementCount,
            unexpectedInputEventCount: unexpectedInputEventCount,
            layoutMismatchStrokes: layoutMismatchStrokes,
            boundaryDeliveryTimeouts: boundaryDeliveryTimeouts
        )
        let data = try! JSONEncoder().encode(result)
        if let resultPath {
            try? data.write(to: URL(fileURLWithPath: resultPath), options: .atomic)
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        fflush(stdout)
        NSApp.terminate(nil)
    }

    private func selectLayout(language targetLanguage: String) -> Bool {
        guard let source = inputSource(for: targetLanguage) else { return false }
        TISEnableInputSource(source)
        guard TISSelectInputSource(source) == noErr else { return false }
        let expectedID = LayoutSwitcher.sourceID(source)
        for _ in 0..<50 {
            if LayoutSwitcher.currentLayoutID() == expectedID { return true }
            usleep(10_000)
        }
        return false
    }

    private func releaseModifiers() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        source.userData = 0x52535445
        for keyCode: CGKeyCode in [54, 55, 56, 57, 58, 59, 60, 61, 62] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            event?.flags = []
            event?.post(tap: .cghidEventTap)
        }
    }

    private func physicalStrokes(for text: String, language: String) -> [HIDProbeStroke]? {
        guard let layout = inputSource(for: language) else { return nil }
        return text.map { character -> [HIDProbeStroke]? in
            physicalStrokes(for: character, layout: layout)
        }.reduce(into: Optional<[HIDProbeStroke]>([])) { result, strokes in
            guard result != nil, let strokes else {
                result = nil
                return
            }
            result?.append(contentsOf: strokes)
        }
    }

    private func physicalStrokes(for character: Character, layout: TISInputSource) -> [HIDProbeStroke]? {
        if character == " " { return [HIDProbeStroke(keyCode: 49, shift: false)] }
        if character == "\t" { return [HIDProbeStroke(keyCode: 48, shift: false)] }
        if character == "\n" { return [HIDProbeStroke(keyCode: 36, shift: false)] }
        guard let physical = DynamicKeyMapping.physicalKeys(for: character, layout: layout) else { return nil }
        return physical.map {
            HIDProbeStroke(keyCode: CGKeyCode($0.keyCode), shift: $0.shift)
        }
    }

    private func inputSource(for targetLanguage: String) -> TISInputSource? {
        let layouts = LayoutSwitcher.installedLayouts()
        if targetLanguage == "en" {
            return layouts.first {
                let id = LayoutSwitcher.sourceID($0)
                return LayoutSwitcher.languageCode($0).map { String($0.lowercased().prefix(2)) } == "en"
                    && (id.contains("ABC") || id.contains("US") || id.contains("British"))
            } ?? layouts.first {
                LayoutSwitcher.languageCode($0).map { String($0.lowercased().prefix(2)) } == "en"
            }
        }
        return layouts.first {
            LayoutSwitcher.languageCode($0).map { String($0.lowercased().prefix(2)) } == targetLanguage
        }
    }
}
