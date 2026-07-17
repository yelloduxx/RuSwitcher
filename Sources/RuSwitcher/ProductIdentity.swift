import Foundation

/// Production product identity for RuSwitcher Pro on `main`.
/// Bundle ID, logs, defaults domain and Accessibility grants are tied to this
/// identity — changing it requires re-granting permissions on install.
enum ProductIdentity {
    static let displayName = "RuSwitcher Pro"
    static let shortName = "RuSwitcherPro"
    static let bundleIdentifier = "com.ruswitcher.pro"
    static let logDirectoryName = "RuSwitcherPro"
    static let logFileName = "ruswitcher-pro.log"
    /// Stable across builds so synthetic events never feed back into the tap.
    static let eventMarker: Int64 = 0x5255_5300 // 'RUS\0'
    /// Fresh installs start with double-Shift.
    static let defaultTriggerKey = "shift"
    static let defaultTriggerDoubleTap = true

    static var logFilePath: String {
        NSHomeDirectory() + "/Library/Logs/\(logDirectoryName)/\(logFileName)"
    }
}
