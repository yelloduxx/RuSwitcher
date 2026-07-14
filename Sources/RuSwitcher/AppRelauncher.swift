import AppKit
import Foundation

/// Единая точка перезапуска приложения.
/// Раньше эта последовательность была скопирована в AppDelegate и UpdateChecker.
@MainActor
enum AppRelauncher {
    /// Перезапускает приложение: открывает бандл заново и завершает текущий процесс.
    @discardableResult
    static func relaunch(
        bundlePath: String = Bundle.main.bundlePath,
        backupPath: String? = nil
    ) -> Bool {
        let task = Process()
        task.launchPath = "/bin/sh"
        if let backupPath {
            let script = """
            sleep 1
            if /usr/bin/open "$1"; then
                sleep 2
                /bin/rm -rf "$2"
                exit 0
            fi
            if [ -e "$2" ]; then
                /bin/rm -rf "$1"
                if /bin/mv "$2" "$1"; then
                    exec /usr/bin/open "$1"
                fi
            fi
            exit 1
            """
            task.arguments = [
                "-c", script, "ruswitcher-update-relaunch", bundlePath, backupPath,
            ]
        } else {
            task.arguments = [
                "-c", "sleep 1; exec /usr/bin/open \"$1\"", "ruswitcher-relaunch", bundlePath,
            ]
        }
        do {
            try task.run()
        } catch {
            return false
        }
        NSApplication.shared.terminate(nil)
        return true
    }
}
