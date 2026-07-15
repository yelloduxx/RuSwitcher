import Foundation

/// Parallel-install identity for this experimental branch.
/// Distinct from production (`com.ruswitcher.app`) and Lab (`com.ruswitcher.lab`)
/// so Accessibility / Input Monitoring / defaults / login items do not collide.
enum ProductIdentity {
    static let displayName = "RuSwitcher AX"
    static let shortName = "RuSwitcherAX"
    static let bundleIdentifier = "com.ruswitcher.ax"
    static let logDirectoryName = "RuSwitcherAX"
    /// Distinct synthetic-event marker so another RuSwitcher instance can ignore us.
    static let eventMarker: Int64 = 0x5255_5341 // 'RUSA'
}
