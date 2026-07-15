import AppKit
import Foundation
import RuSwitcherAppSupport

/// Проверяет наличие обновлений через GitHub
@MainActor
enum UpdateChecker {
    private static var versionURL: String {
        "https://raw.githubusercontent.com/\(SettingsManager.githubOwner)/\(SettingsManager.githubRepo)/main/version.json"
    }

    /// Структура JSON версии
    private struct VersionInfo: Decodable {
        let version: String
        let build: String
        let url: String
        let notes: String?
        let sha256: String?
    }

    /// Проверить при запуске (с задержкой 5 сек, не чаще раза в сутки).
    /// Отключается через настройку `checkUpdatesEnabled`. Ручная проверка (`checkNow`) работает всегда.
    static func checkOnLaunch() {
        guard shouldAutoCheck() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            Task { await check(silent: true) }
        }
    }

    /// Периодическая тихая авто-проверка, пока приложение работает (из таймера AppDelegate).
    /// Тот же троттл (не чаще раза в сутки) и та же настройка `checkUpdatesEnabled`, что и на старте,
    /// поэтому долго-живущий инстанс тоже ловит новые версии, а не только при перезапуске.
    static func checkPeriodic() {
        guard shouldAutoCheck() else { return }
        Task { await check(silent: true) }
    }

    /// Можно ли сейчас авто-проверять: включено в настройках И прошло ≥24ч с последней проверки.
    private static func shouldAutoCheck() -> Bool {
        let settings = SettingsManager.shared
        guard settings.checkUpdatesEnabled else { return false }
        if let lastCheck = settings.lastUpdateCheck,
           Date().timeIntervalSince(lastCheck) < 86400 {
            return false // Проверяли менее суток назад
        }
        return true
    }

    /// Проверить вручную (всегда показывает результат)
    static func checkNow() {
        Task { await check(silent: false) }
    }

    private static func check(silent: Bool) async {
        guard let url = URL(string: versionURL) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let info = try JSONDecoder().decode(VersionInfo.self, from: data)

            SettingsManager.shared.lastUpdateCheck = Date()

            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            let currentBuild = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
            guard let availableBuild = Int(info.build) else {
                throw UpdateMetadataError.invalidBuild
            }
            let available = ReleaseVersion(version: info.version, build: availableBuild)
            let current = ReleaseVersion(version: currentVersion, build: currentBuild)

            if available > current {
                if available.matchesSkipIdentifier(SettingsManager.shared.skippedVersion), silent {
                    return // Пользователь пропустил эту версию
                }
                await showUpdateAlert(info: info)
            } else if !silent {
                await showUpToDateAlert()
            }
        } catch {
            rslog("update_check_failed")
            if !silent {
                await showErrorAlert()
            }
        }
    }

    private static func showUpdateAlert(info: VersionInfo) async {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.updateAvailable
        alert.informativeText = "\(L10n.updateNewVersion) \(info.version) (\(info.build))\n\(info.notes ?? "")"
        alert.addButton(withTitle: L10n.updateInstallRestart)  // 1st
        alert.addButton(withTitle: L10n.updateDownload)         // 2nd
        alert.addButton(withTitle: L10n.updateSkip)             // 3rd
        alert.addButton(withTitle: L10n.updateLater)            // 4th

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            await installAndRestart(info: info)
        case .alertSecondButtonReturn:
            if let url = URL(string: info.url) {
                NSWorkspace.shared.open(url)
            }
        case .alertThirdButtonReturn:
            if let build = Int(info.build) {
                SettingsManager.shared.skippedVersion = ReleaseVersion(
                    version: info.version,
                    build: build
                ).identifier
            }
        default:
            break
        }
    }

    // MARK: - Install & Restart

    private static func installAndRestart(info: VersionInfo) async {
        let version = info.version
        guard let announcedBuild = Int(info.build), announcedBuild > 0 else {
            await showInstallError(L10n.updateVerifyFailed)
            return
        }

        // 0. Версия приходит из сети — не доверяем вслепую (попадёт в URL и в сравнение).
        guard version.range(of: "^[0-9]+(\\.[0-9]+){1,3}$", options: .regularExpression) != nil else {
            rslog("update_version_malformed")
            await showInstallError(L10n.updateVerifyFailed)
            return
        }

        // 0a. sha256 обязателен для установки на месте: молча подменять приложение
        //     keylogger-класса без проверки нельзя. Нет хэша — откат на загрузку
        //     в браузере, где работает Gatekeeper/нотаризация.
        guard let expectedSHA = info.sha256, !expectedSHA.isEmpty else {
            rslog("Update: no sha256 in version.json — falling back to browser download")
            if let url = URL(string: info.url) { NSWorkspace.shared.open(url) }
            return
        }
        guard SettingsManager.developerTeamID != nil else {
            rslog("update_developer_id_unavailable")
            if let url = URL(string: info.url) { NSWorkspace.shared.open(url) }
            return
        }

        guard let dmgURL = URL(string: SettingsManager.releaseDMGURL(version: version)) else {
            await showInstallError(L10n.updateDownloadFailed)
            return
        }

        let fm = FileManager.default
        let attemptRoot = fm.temporaryDirectory
            .appendingPathComponent("RuSwitcher-update-\(UUID().uuidString)", isDirectory: true)
        let tmpURL = attemptRoot.appendingPathComponent("update.dmg")
        let mountURL = attemptRoot.appendingPathComponent("mount", isDirectory: true)
        let stagingDir = attemptRoot.appendingPathComponent("staging", isDirectory: true)
        do {
            try fm.createDirectory(at: attemptRoot, withIntermediateDirectories: true)
            try fm.createDirectory(at: mountURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } catch {
            await showInstallError(L10n.updateInstallFailed)
            return
        }
        var mounted = false
        defer {
            if mounted { detach(mountPoint: mountURL.path) }
            try? fm.removeItem(at: attemptRoot)
        }

        // 1. Скачать
        rslog("update_download_started")
        do {
            let (downloadedURL, response) = try await URLSession.shared.download(from: dmgURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                await showInstallError(L10n.updateDownloadFailed)
                return
            }
            try fm.moveItem(at: downloadedURL, to: tmpURL)
        } catch {
            rslog("update_download_failed")
            await showInstallError(L10n.updateDownloadFailed)
            return
        }

        // 2. Проверить sha256 (обязательно)
        let actualSHA = sha256OfFile(at: tmpURL.path)
        guard actualSHA == expectedSHA else {
            rslog("update_checksum_mismatch")
            await showInstallError(L10n.updateVerifyFailed)
            return
        }
        rslog("Update: sha256 verified")

        // 3. Смонтировать DMG
        let mount = Process()
        mount.launchPath = "/usr/bin/hdiutil"
        mount.arguments = ["attach", tmpURL.path, "-nobrowse", "-readonly", "-mountpoint", mountURL.path]
        mount.standardOutput = FileHandle.nullDevice
        mount.standardError = FileHandle.nullDevice
        do {
            try mount.run()
            mount.waitUntilExit()
            guard mount.terminationStatus == 0 else {
                rslog("update_mount_failed")
                await showInstallError(L10n.updateInstallFailed)
                return
            }
            mounted = true
        } catch {
            rslog("update_mount_error")
            await showInstallError(L10n.updateInstallFailed)
            return
        }

        // 4. Найти .app в смонтированном томе
        guard let contents = try? fm.contentsOfDirectory(atPath: mountURL.path),
              let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
            rslog("Update: no .app found in mounted DMG")
            await showInstallError(L10n.updateInstallFailed)
            return
        }

        let sourceApp = mountURL.appendingPathComponent(appName)
        let currentApp = URL(fileURLWithPath: Bundle.main.bundlePath)

        // 5. ПРОВЕРКА ПОДПИСИ: единственная реальная защита от подмены кода.
        //    sha256 защищает лишь от битой загрузки — если подменить и DMG, и хэш,
        //    спасает только пиннинг Developer ID нашей команды.
        guard verifyNotarizedSignature(at: sourceApp.path) else {
            rslog("Update: signature/notarization check FAILED — aborting")
            await showInstallError(L10n.updateVerifyFailed)
            return
        }

        // 5a. Идентичность бандла: тот же bundle id и версия совпадает с заявленной.
        let mountedInfo = Bundle(url: sourceApp)?.infoDictionary
        let mountedID = mountedInfo?["CFBundleIdentifier"] as? String
        let mountedVersion = mountedInfo?["CFBundleShortVersionString"] as? String
        let mountedBuild = Int(mountedInfo?["CFBundleVersion"] as? String ?? "")
        guard mountedID == Bundle.main.bundleIdentifier else {
            rslog("update_bundle_id_mismatch")
            await showInstallError(L10n.updateVerifyFailed)
            return
        }
        guard mountedVersion == version else {
            rslog("update_bundle_version_mismatch")
            await showInstallError(L10n.updateVerifyFailed)
            return
        }
        guard mountedBuild == announcedBuild else {
            rslog("update_bundle_build_mismatch")
            await showInstallError(L10n.updateVerifyFailed)
            return
        }

        // 6. Скопировать .app с read-only тома DMG на тот же том, что и текущее
        //    приложение. replaceItemAt НЕ умеет переносить элемент напрямую с
        //    read-only тома DMG — именно это давало «Ошибку установки».
        let stagedApp = stagingDir.appendingPathComponent(appName)
        do {
            try fm.copyItem(at: sourceApp, to: stagedApp)
        } catch {
            rslog("update_staging_failed")
            await showInstallError(error.localizedDescription)
            return
        }
        guard verifyNotarizedSignature(at: stagedApp.path) else {
            rslog("update_staged_signature_failed")
            await showInstallError(L10n.updateVerifyFailed)
            return
        }

        // 7. Атомарно заменить .app из staging-копии (на одном томе — работает)
        do {
            _ = try fm.replaceItemAt(currentApp, withItemAt: stagedApp)
            rslog("Update: app replaced successfully")
        } catch {
            rslog("update_replace_failed")
            await showInstallError(error.localizedDescription)
            return
        }

        // 8. Перезапуск
        rslog("Update: restarting...")
        AppRelauncher.relaunch(bundlePath: currentApp.path)
    }

    /// Проверяет, что бандл подписан Developer ID нашей команды и проходит строгую
    /// проверку целостности (codesign --verify с пиннингом Team ID).
    private static func verifyNotarizedSignature(at path: String) -> Bool {
        guard let teamID = SettingsManager.developerTeamID, !teamID.isEmpty else {
            return false
        }
        let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        let process = Process()
        process.launchPath = "/usr/bin/codesign"
        process.arguments = ["--verify", "--deep", "--strict", "-R=\(requirement)", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return false }
            let gatekeeper = Process()
            gatekeeper.launchPath = "/usr/sbin/spctl"
            gatekeeper.arguments = ["--assess", "--type", "execute", "--verbose=2", path]
            gatekeeper.standardOutput = FileHandle.nullDevice
            gatekeeper.standardError = FileHandle.nullDevice
            try gatekeeper.run()
            gatekeeper.waitUntilExit()
            return gatekeeper.terminationStatus == 0
        } catch {
            rslog("update_signature_check_error")
            return false
        }
    }

    private static func sha256OfFile(at path: String) -> String? {
        let pipe = Pipe()
        let process = Process()
        process.launchPath = "/usr/bin/shasum"
        process.arguments = ["-a", "256", path]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            return output.split(separator: " ").first.map(String.init)
        } catch {
            return nil
        }
    }

    private static func showAlert(style: NSAlert.Style, title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func showInstallError(_ message: String) async {
        showAlert(style: .warning, title: L10n.updateInstallFailed, message: message)
    }

    private static func showUpToDateAlert() async {
        showAlert(style: .informational, title: L10n.updateUpToDate, message: L10n.updateLatestInstalled)
    }

    private static func showErrorAlert() async {
        showAlert(style: .warning, title: L10n.updateCheckFailed, message: L10n.updateCheckFailedDetail)
    }

    private static func detach(mountPoint: String) {
        let process = Process()
        process.launchPath = "/usr/bin/hdiutil"
        process.arguments = ["detach", mountPoint, "-quiet"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private enum UpdateMetadataError: Error { case invalidBuild }
}
