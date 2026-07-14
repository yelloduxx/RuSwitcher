import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private struct HIDMonitorStatus: Codable {
    let processID: Int32
    let monitoringActive: Bool
    let accessibilityTrusted: Bool
    let listenEventAccess: Bool
    let postEventAccess: Bool
    let postedAutomaticReplacementCount: Int
    let verifiedAutomaticReplacementCount: Int
    let postedManualReplacementCount: Int
    let verifiedManualReplacementCount: Int
    let manualOutcome: String?
}

@MainActor
enum HIDMonitorProbe {
    private static var retainedDelegate: HIDMonitorProbeDelegate?

    static func run(statusPath: String) -> Never {
        let app = NSApplication.shared
        let delegate = HIDMonitorProbeDelegate(statusPath: statusPath)
        retainedDelegate = delegate
        app.delegate = delegate
        app.run()
        exit(0)
    }
}

@MainActor
private final class HIDMonitorProbeDelegate: NSObject, NSApplicationDelegate {
    private let statusPath: String
    private let productionDelegate = AppDelegate()
    private var monitoringActive = false
    private var statusTimer: Timer?

    init(statusPath: String) {
        self.statusPath = statusPath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsManager.shared
        settings.autoSwitchEnabled = true
        settings.autoConvert = false
        settings.triggerKey = "shift"
        settings.triggerRightOnly = false
        settings.triggerDoubleTap = true
        settings.remoteDesktopMode = false
        settings.deniedWords = []
        settings.alwaysConvertWords = []
        monitoringActive = productionDelegate.startHIDProbeMonitoring()
        writeStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeStatus() }
        }
    }

    private func writeStatus() {
        let status = HIDMonitorStatus(
            processID: ProcessInfo.processInfo.processIdentifier,
            monitoringActive: monitoringActive,
            accessibilityTrusted: AXIsProcessTrusted(),
            listenEventAccess: CGPreflightListenEventAccess(),
            postEventAccess: CGPreflightPostEventAccess(),
            postedAutomaticReplacementCount: productionDelegate.postedAutomaticReplacementCount,
            verifiedAutomaticReplacementCount: productionDelegate.verifiedAutomaticReplacementCount,
            postedManualReplacementCount: productionDelegate.postedManualReplacementCount,
            verifiedManualReplacementCount: productionDelegate.verifiedManualReplacementCount,
            manualOutcome: productionDelegate.lastManualReplacementOutcomeCode
        )
        guard let data = try? JSONEncoder().encode(status) else { return }
        try? data.write(to: URL(fileURLWithPath: statusPath), options: .atomic)
    }
}
