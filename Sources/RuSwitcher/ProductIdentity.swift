import Foundation

/// Parallel-install identity for this experimental branch.
/// Distinct from production (`com.ruswitcher.app`) and Lab (`com.ruswitcher.lab`)
/// so Accessibility / Input Monitoring / defaults / login items do not collide.
enum ProductIdentity {
    static let displayName = "RuSwitcher AX"
    static let shortName = "RuSwitcherAX"
    static let bundleIdentifier = "com.ruswitcher.ax"
    static let logDirectoryName = "RuSwitcherAX"
    /// Shared with existing RuSwitcher builds so parallel comparison installs do
    /// not feed each other's replacement events back into their event taps.
    static let eventMarker: Int64 = 0x5255_5300 // 'RUS\0'
    /// Fresh AX installs start with double-Shift (matches user Lab habit).
    static let defaultTriggerKey = "shift"
    static let defaultTriggerDoubleTap = true
}
