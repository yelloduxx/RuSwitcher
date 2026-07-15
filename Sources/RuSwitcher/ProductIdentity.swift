import Foundation

/// Parallel-install identity for the Claude comparison line (generic AX
/// capability detection, see AGENTS.md "claude/generic-ax-fallback").
/// Built on top of Grok AX build 108; keeps Accessibility / Input Monitoring /
/// defaults / login items from colliding with Lab, author, Grok or Codex apps.
enum ProductIdentity {
    static let displayName = "RuSwitcher Claude"
    static let shortName = "RuSwitcherClaude"
    static let bundleIdentifier = "com.ruswitcher.claude"
    static let logDirectoryName = "RuSwitcherClaude"
    static let logFileName = "ruswitcher-claude.log"
    /// Stable across builds so synthetic events never feed back into the tap.
    /// Shared with Lab/AX/author so parallel installs do not re-ingest each other.
    static let eventMarker: Int64 = 0x5255_5300 // 'RUS\0'
    /// Fresh installs start with double-Shift (matches Lab/AX habit).
    static let defaultTriggerKey = "shift"
    static let defaultTriggerDoubleTap = true

    static var logFilePath: String {
        NSHomeDirectory() + "/Library/Logs/\(logDirectoryName)/\(logFileName)"
    }
}
