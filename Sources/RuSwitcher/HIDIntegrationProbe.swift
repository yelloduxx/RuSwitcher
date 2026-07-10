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
}

private struct HIDProbeScenario {
    struct Phase {
        let sourceLanguage: String
        let keyCodes: [CGKeyCode]
        let producedText: String?
        let typedText: String?

        init(sourceLanguage: String, keyCodes: [CGKeyCode], producedText: String? = nil) {
            self.sourceLanguage = sourceLanguage
            self.keyCodes = keyCodes
            self.producedText = producedText
            self.typedText = nil
        }

        init(sourceLanguage: String, typedText: String) {
            self.sourceLanguage = sourceLanguage
            self.keyCodes = []
            self.producedText = nil
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

    init(name: String, phases: [Phase], manualLearningSource: String? = nil) {
        self.name = name
        self.phases = phases
        self.manualLearningSource = manualLearningSource
    }

    static func named(_ name: String) -> HIDProbeScenario? {
        switch name {
        case "use-comma":
            return HIDProbeScenario(name: name, phases: [Phase(sourceLanguage: "en", keyCodes: [32, 1, 14, 43, 49])])
        case "use-comma-no-boundary":
            return HIDProbeScenario(name: name, phases: [Phase(sourceLanguage: "en", keyCodes: [32, 1, 14, 43])])
        case "use-comma-after-russian":
            return HIDProbeScenario(name: name, phases: [
                Phase(sourceLanguage: "en", keyCodes: [5, 40, 3, 16, 49]), // gkfy -> план
                Phase(sourceLanguage: "en", keyCodes: [32, 1, 14, 43], producedText: "use,"),
            ])
        case "revolution":
            return HIDProbeScenario(name: name, phases: [Phase(sourceLanguage: "en", keyCodes: [4, 17, 2, 38, 40, 47, 13, 11, 6, 49])])
        case "privetulki":
            return HIDProbeScenario(name: name, phases: [Phase(sourceLanguage: "en", keyCodes: [5, 4, 11, 2, 17, 45, 14, 40, 46, 15, 11, 49])])
        case "hello-from-russian":
            return HIDProbeScenario(name: name, phases: [Phase(sourceLanguage: "ru", keyCodes: [4, 14, 37, 37, 31, 49])])
        case "use-comma-from-russian":
            return HIDProbeScenario(name: name, phases: [Phase(sourceLanguage: "ru", keyCodes: [32, 1, 14, 43, 49])])
        case "fable-from-russian":
            return HIDProbeScenario(name: name, phases: [Phase(sourceLanguage: "ru", keyCodes: [3, 0, 11, 37, 14, 49])])
        case "wipe-from-english":
            return HIDProbeScenario(name: name, phases: [Phase(sourceLanguage: "en", keyCodes: [5, 4, 38, 45, 17, 4, 17, 45, 46, 49])])
        case "butt-from-english":
            return HIDProbeScenario(name: name, phases: [Phase(sourceLanguage: "en", keyCodes: [35, 3, 37, 16, 11, 13, 3, 49])])
        case "slur-from-english":
            return HIDProbeScenario(name: name, phases: [Phase(sourceLanguage: "en", keyCodes: [5, 11, 37, 4, 49])])
        case "cyst-stays-english":
            return HIDProbeScenario(name: name, phases: [Phase(sourceLanguage: "en", keyCodes: [8, 16, 1, 17, 49])])
        case "juju-stays-english":
            return HIDProbeScenario(name: name, phases: [Phase(sourceLanguage: "en", keyCodes: [38, 32, 38, 32, 49])])
        case "codex-stays-english":
            return HIDProbeScenario(name: name, phases: [Phase(sourceLanguage: "en", keyCodes: [8, 31, 2, 14, 7, 49])])
        case "loosen-from-russian":
            return HIDProbeScenario(name: name, phases: [Phase(sourceLanguage: "ru", keyCodes: [37, 31, 31, 1, 14, 45, 49])])
        case "hello-comma-from-russian":
            return HIDProbeScenario(name: name, phases: [Phase(sourceLanguage: "ru", keyCodes: [4, 14, 37, 37, 31, 43, 49])])
        case "world-period-from-russian":
            return HIDProbeScenario(name: name, phases: [Phase(sourceLanguage: "ru", keyCodes: [13, 31, 15, 37, 2, 47, 49])])
        case "privet-period-from-english":
            return HIDProbeScenario(name: name, phases: [Phase(sourceLanguage: "en", keyCodes: [5, 4, 11, 2, 17, 45, 47, 49])])
        case "manual-learning-double-shift":
            let source = "qazwsxedc"
            return HIDProbeScenario(
                name: name,
                phases: [Phase(sourceLanguage: "en", typedText: source + " ")],
                manualLearningSource: source
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
    let producedCharacter: Character?
}

private struct HIDProbePlannedPhase {
    let sourceLanguage: String
    let strokes: [HIDProbeStroke]
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

    static func run(fixturePath: String, resultPath: String?) -> Never {
        let scenario: HIDProbeScenario
        do {
            scenario = try HIDProbeScenario.fixture(at: fixturePath)
        } catch {
            FileHandle.standardError.write(Data("invalid HID probe fixture: \(error)\n".utf8))
            exit(64)
        }
        run(scenario: scenario, resultPath: resultPath)
    }

    private static func run(scenario: HIDProbeScenario, resultPath: String?) -> Never {
        let app = NSApplication.shared
        let delegate = HIDProbeDelegate(scenario: scenario, resultPath: resultPath)
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

    init(scenario: HIDProbeScenario, resultPath: String?) {
        self.scenario = scenario
        self.resultPath = resultPath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        textView.enabledTextCheckingTypes = 0
        textView.isContinuousSpellCheckingEnabled = false
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        originalLayoutID = LayoutSwitcher.currentLayoutID()
        if let source = scenario.manualLearningSource {
            startManualLearningProbe(source: source)
            return
        }
        guard let firstPhase = scenario.phases.first,
              selectLayout(language: firstPhase.sourceLanguage) else {
            finish(text: "<layout-unavailable>")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.postPhysicalKeys()
        }
    }

    private func startManualLearningProbe(source: String) {
        guard selectLayout(language: "en") else {
            finish(text: "<layout-unavailable>")
            return
        }
        textView.string = source
        textView.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.postDoubleShift()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.manualObservedText = self.textView.string
            self.textView.string = ""
            self.textView.setSelectedRange(NSRange(location: 0, length: 0))
            self.window?.makeFirstResponder(self.textView)
            self.postPhysicalKeys()
        }
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
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
        guard window?.isKeyWindow == true, window?.firstResponder === textView else {
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
            let strokes: [HIDProbeStroke]
            if let typedText = phase.typedText {
                guard let planned = physicalStrokes(for: typedText, language: phase.sourceLanguage) else {
                    finish(text: "<unmappable-fixture-text>")
                    return
                }
                strokes = planned
            } else {
                let producedCharacters = phase.producedText.map(Array.init)
                strokes = phase.keyCodes.enumerated().map { index, keyCode in
                    HIDProbeStroke(
                        keyCode: keyCode,
                        shift: false,
                        producedCharacter: producedCharacters?[safe: index]
                    )
                }
            }
            phases.append(HIDProbePlannedPhase(sourceLanguage: phase.sourceLanguage, strokes: strokes))
        }
        didPostKeys = true
        eventSource = source
        plannedPhases = phases
        postPhase(at: 0)
    }

    private func postPhase(at phaseIndex: Int) {
        guard plannedPhases.indices.contains(phaseIndex) else {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.postStroke(phaseIndex: phaseIndex, strokeIndex: 0)
        }
    }

    private func postStroke(phaseIndex: Int, strokeIndex: Int) {
        guard plannedPhases.indices.contains(phaseIndex), let source = eventSource else { return }
        let phase = plannedPhases[phaseIndex]
        guard phase.strokes.indices.contains(strokeIndex) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.postPhase(at: phaseIndex + 1)
            }
            return
        }
        let stroke = phase.strokes[strokeIndex]
        if stroke.shift {
            let shiftDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 56,
                keyDown: true
            )
            shiftDown?.flags = [.maskShift]
            shiftDown?.post(tap: .cghidEventTap)
        }
        let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: stroke.keyCode,
            keyDown: true
        )
        if stroke.shift { keyDown?.flags = [.maskShift] }
        if let producedCharacter = stroke.producedCharacter {
            let utf16 = Array(String(producedCharacter).utf16)
            utf16.withUnsafeBufferPointer { buffer in
                keyDown?.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
            }
        }
        keyDown?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            guard let self, let source = self.eventSource else { return }
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: stroke.keyCode,
                keyDown: false
            )
            if stroke.shift { keyUp?.flags = [.maskShift] }
            keyUp?.post(tap: .cghidEventTap)
            if stroke.shift {
                CGEvent(
                    keyboardEventSource: source,
                    virtualKey: 56,
                    keyDown: false
                )?.post(tap: .cghidEventTap)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { [weak self] in
                self?.postStroke(phaseIndex: phaseIndex, strokeIndex: strokeIndex + 1)
            }
        }
    }

    private func finish(text: String) {
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
            }
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

    private func physicalStrokes(for text: String, language: String) -> [HIDProbeStroke]? {
        guard let layout = inputSource(for: language) else { return nil }
        return text.map { character in
            physicalStroke(for: character, layout: layout)
        }.reduce(into: Optional<[HIDProbeStroke]>([])) { result, stroke in
            guard result != nil, let stroke else {
                result = nil
                return
            }
            result?.append(stroke)
        }
    }

    private func physicalStroke(for character: Character, layout: TISInputSource) -> HIDProbeStroke? {
        if character == " " { return HIDProbeStroke(keyCode: 49, shift: false, producedCharacter: nil) }
        if character == "\t" { return HIDProbeStroke(keyCode: 48, shift: false, producedCharacter: nil) }
        if character == "\n" { return HIDProbeStroke(keyCode: 36, shift: false, producedCharacter: nil) }
        guard let physical = DynamicKeyMapping.physicalKey(for: character, layout: layout) else { return nil }
        return HIDProbeStroke(
            keyCode: CGKeyCode(physical.keyCode),
            shift: physical.shift,
            producedCharacter: nil
        )
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

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
