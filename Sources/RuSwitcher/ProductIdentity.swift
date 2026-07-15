import Foundation

/// Parallel-install identity for the Grok AX line.
/// Built on top of Lab 105 conversion logic; keeps Accessibility / Input
/// Monitoring / defaults / login items from colliding with Lab or author apps.
enum ProductIdentity {
    static let displayName = "RuSwitcher AX"
    static let shortName = "RuSwitcherAX"
    static let bundleIdentifier = "com.ruswitcher.ax"
    static let logDirectoryName = "RuSwitcherAX"
    static let logFileName = "ruswitcher-ax.log"
    /// Stable across builds so synthetic events never feed back into the tap.
    /// Shared with Lab/author so parallel installs do not re-ingest each other.
    static let eventMarker: Int64 = 0x5255_5300 // 'RUS\0'
    /// Fresh AX installs start with double-Shift (matches Lab habit).
    static let defaultTriggerKey = "shift"
    static let defaultTriggerDoubleTap = true

    static var logFilePath: String {
        NSHomeDirectory() + "/Library/Logs/\(logDirectoryName)/\(logFileName)"
    }
}
