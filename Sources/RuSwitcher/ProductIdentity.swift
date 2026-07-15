import Foundation

/// Identity of this fork's separately installed production build.
enum ProductIdentity {
    static let displayName = "RuSwitcher Lab"
    static let shortName = "RuSwitcherLab"
    static let bundleIdentifier = "com.ruswitcher.lab"
    static let logDirectoryName = "RuSwitcherLab"
    /// Stable across builds so our synthetic events never feed back into the tap.
    static let eventMarker: Int64 = 0x5255_5300 // 'RUS\0'
    static let defaultTriggerKey = "shift"
    static let defaultTriggerDoubleTap = true
}
