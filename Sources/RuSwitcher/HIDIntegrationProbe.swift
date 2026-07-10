import AppKit
import Carbon
import CoreGraphics
import Foundation

private struct HIDProbeResult: Codable {
    let scenario: String
    let text: String
    let layoutID: String
    let postEventAccess: Bool
}

private struct HIDProbeScenario {
    struct Phase {
        let sourceLanguage: String
        let keyCodes: [CGKeyCode]
        let producedText: String?

        init(sourceLanguage: String, keyCodes: [CGKeyCode], producedText: String? = nil) {
            self.sourceLanguage = sourceLanguage
            self.keyCodes = keyCodes
            self.producedText = producedText
        }
    }

    let name: String
    let phases: [Phase]

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
        default:
            return nil
        }
    }
}

@MainActor
enum HIDIntegrationProbe {
    private static var retainedDelegate: HIDProbeDelegate?

    static func run(scenarioName: String, resultPath: String?) -> Never {
        guard let scenario = HIDProbeScenario.named(scenarioName) else {
            FileHandle.standardError.write(Data("unknown HID probe scenario\n".utf8))
            exit(64)
        }
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
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        originalLayoutID = LayoutSwitcher.currentLayoutID()
        guard let firstPhase = scenario.phases.first,
              selectLayout(language: firstPhase.sourceLanguage) else {
            finish(text: "<layout-unavailable>")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.postPhysicalKeys()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.finish(text: self.textView.string)
        }
    }

    private func postPhysicalKeys() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        source.userData = 0x52535445 // RSTE: deliberately not RuSwitcher's synthetic marker.
        for phase in scenario.phases {
            guard selectLayout(language: phase.sourceLanguage) else { continue }
            usleep(80_000)
            let producedCharacters = phase.producedText.map(Array.init)
            for (index, keyCode) in phase.keyCodes.enumerated() {
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
                if let character = producedCharacters?[safe: index] {
                    let utf16 = Array(String(character).utf16)
                    utf16.withUnsafeBufferPointer { buffer in
                        keyDown?.keyboardSetUnicodeString(
                            stringLength: buffer.count,
                            unicodeString: buffer.baseAddress
                        )
                    }
                }
                keyDown?.post(tap: .cghidEventTap)
                usleep(12_000)
                CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)
                usleep(18_000)
            }
            usleep(120_000)
        }
    }

    private func finish(text: String) {
        let resultingLayoutID = LayoutSwitcher.currentLayoutID()
        if !originalLayoutID.isEmpty { LayoutSwitcher.switchTo(layoutID: originalLayoutID) }
        let result = HIDProbeResult(
            scenario: scenario.name,
            text: text,
            layoutID: resultingLayoutID,
            postEventAccess: CGPreflightPostEventAccess()
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
        let layouts = LayoutSwitcher.installedLayouts()
        let source: TISInputSource?
        if targetLanguage == "en" {
            source = layouts.first {
                let id = LayoutSwitcher.sourceID($0)
                return LayoutSwitcher.languageCode($0).map { String($0.lowercased().prefix(2)) } == "en"
                    && (id.contains("ABC") || id.contains("US") || id.contains("British"))
            } ?? layouts.first {
                LayoutSwitcher.languageCode($0).map { String($0.lowercased().prefix(2)) } == "en"
            }
        } else {
            source = layouts.first {
                LayoutSwitcher.languageCode($0).map { String($0.lowercased().prefix(2)) } == targetLanguage
            }
        }
        guard let source else { return false }
        TISEnableInputSource(source)
        guard TISSelectInputSource(source) == noErr else { return false }
        let expectedID = LayoutSwitcher.sourceID(source)
        for _ in 0..<50 {
            if LayoutSwitcher.currentLayoutID() == expectedID { return true }
            usleep(10_000)
        }
        return false
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
