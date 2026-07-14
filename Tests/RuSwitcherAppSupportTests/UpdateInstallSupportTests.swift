import Foundation
import XCTest
@testable import RuSwitcherAppSupport

final class UpdateInstallSupportTests: XCTestCase {
    func testReleaseMetadataAcceptsStringAndNumericBuilds() throws {
        let stringData = Data(#"{"version":"4.0.0","build":"89","url":"https://example.invalid"}"#.utf8)
        let numericData = Data(#"{"version":"4.0.0","build":89,"url":"https://example.invalid"}"#.utf8)

        let stringMetadata = try JSONDecoder().decode(UpdateReleaseMetadata.self, from: stringData)
        let numericMetadata = try JSONDecoder().decode(UpdateReleaseMetadata.self, from: numericData)

        XCTAssertEqual(try stringMetadata.validatedReleaseVersion(), ReleaseVersion(version: "4.0.0", build: 89))
        XCTAssertEqual(try numericMetadata.validatedReleaseVersion(), ReleaseVersion(version: "4.0.0", build: 89))
    }

    func testReleaseMetadataRejectsMalformedVersionBuildAndDigest() throws {
        let badVersion = UpdateReleaseMetadata(version: "4.latest", build: "89", url: "https://example.invalid")
        let badBuild = UpdateReleaseMetadata(version: "4.0.0", build: "zero", url: "https://example.invalid")
        let missingDigest = UpdateReleaseMetadata(version: "4.0.0", build: "89", url: "https://example.invalid")
        let badDigest = UpdateReleaseMetadata(
            version: "4.0.0",
            build: "89",
            url: "https://example.invalid",
            sha256: "not-a-digest"
        )
        let uppercaseDigest = UpdateReleaseMetadata(
            version: "4.0.0",
            build: "89",
            url: "https://example.invalid",
            sha256: String(repeating: "A", count: 64)
        )

        assertThrows(try badVersion.validatedReleaseVersion(), equals: .invalidVersion)
        assertThrows(try badBuild.validatedReleaseVersion(), equals: .invalidBuild)
        assertThrows(try missingDigest.validatedSHA256(), equals: .missingSHA256)
        assertThrows(try badDigest.validatedSHA256(), equals: .invalidSHA256)
        XCTAssertEqual(try uppercaseDigest.validatedSHA256(), String(repeating: "a", count: 64))
    }

    func testInfoPlistReaderDoesNotCacheRepeatedMountPath() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("RuSwitcher.app", isDirectory: true)

        try writeInfoPlist(appURL: appURL, version: "4.0.0", build: "88")
        XCTAssertEqual(
            try ReleaseBundleInfoReader.read(appURL: appURL),
            ReleaseBundleInfo(bundleIdentifier: "ru.rashn.RuSwitcher", version: "4.0.0", build: 88)
        )

        try writeInfoPlist(appURL: appURL, version: "4.0.1", build: "89")
        XCTAssertEqual(
            try ReleaseBundleInfoReader.read(appURL: appURL),
            ReleaseBundleInfo(bundleIdentifier: "ru.rashn.RuSwitcher", version: "4.0.1", build: 89)
        )
    }

    func testBundleValidatorChecksIdentifierVersionAndBuildSeparately() throws {
        let expected = ReleaseVersion(version: "4.0.0", build: 89)
        let valid = ReleaseBundleInfo(
            bundleIdentifier: "ru.rashn.RuSwitcher",
            version: "4.0.0",
            build: 89
        )
        XCTAssertNoThrow(try ReleaseBundleValidator.validate(
            valid,
            expectedBundleIdentifier: "ru.rashn.RuSwitcher",
            expectedRelease: expected
        ))

        assertBundleValidation(
            ReleaseBundleInfo(bundleIdentifier: "invalid.bundle", version: "4.0.0", build: 89),
            expected: expected,
            error: .bundleIdentifierMismatch
        )
        assertBundleValidation(
            ReleaseBundleInfo(bundleIdentifier: "ru.rashn.RuSwitcher", version: "4.0.1", build: 89),
            expected: expected,
            error: .versionMismatch
        )
        assertBundleValidation(
            ReleaseBundleInfo(bundleIdentifier: "ru.rashn.RuSwitcher", version: "4.0.0", build: 90),
            expected: expected,
            error: .buildMismatch
        )
    }

    func testInstallWorkspacesAreUniqueAndContainedInRequestedDirectory() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try UpdateInstallWorkspace.create(in: root)
        let second = try UpdateInstallWorkspace.create(in: root)

        XCTAssertNotEqual(first.root, second.root)
        XCTAssertEqual(first.root.deletingLastPathComponent(), root)
        XCTAssertEqual(first.diskImage.deletingLastPathComponent(), first.root)
        XCTAssertEqual(first.mountPoint.deletingLastPathComponent(), first.root)
        XCTAssertEqual(first.stagingDirectory.deletingLastPathComponent(), first.root)
    }

    func testCleanupDetachesBeforeRemovingWorkspace() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let workspace = try UpdateInstallWorkspace.create(in: base)
        try Data("download".utf8).write(to: workspace.diskImage)

        var detachCalled = false
        let result = workspace.cleanup(isMounted: true) { mountPoint in
            detachCalled = true
            XCTAssertEqual(mountPoint, workspace.mountPoint)
            XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.root.path))
            return true
        }

        XCTAssertTrue(detachCalled)
        XCTAssertEqual(result, UpdateInstallCleanupResult(detached: true, removed: true))
        XCTAssertTrue(result.succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.root.path))
    }

    func testFinalizerRelaunchesOnlyAfterDetachAndRemoval() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let workspace = try UpdateInstallWorkspace.create(in: base)
        var events: [String] = []

        let result = UpdateInstallFinalizer.finalize(
            workspace: workspace,
            isMounted: true,
            detach: { _ in
                events.append("detach")
                return true
            },
            relaunch: {
                XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.root.path))
                events.append("relaunch")
                return true
            }
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.cleanup.succeeded)
        XCTAssertTrue(result.relaunched)
        XCTAssertEqual(events, ["detach", "relaunch"])
    }

    func testFinalizerDoesNotRelaunchWhenDetachFails() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let workspace = try UpdateInstallWorkspace.create(in: base)
        var relaunched = false

        let result = UpdateInstallFinalizer.finalize(
            workspace: workspace,
            isMounted: true,
            detach: { _ in false },
            relaunch: {
                relaunched = true
                return true
            }
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(
            result.cleanup,
            UpdateInstallCleanupResult(detached: false, removed: false)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.root.path))
        XCTAssertFalse(relaunched)
    }

    func testFinalizerReportsRelaunchFailureAfterSuccessfulCleanup() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let workspace = try UpdateInstallWorkspace.create(in: base)

        let result = UpdateInstallFinalizer.finalize(
            workspace: workspace,
            isMounted: false,
            detach: { _ in XCTFail("unmounted workspace must not detach"); return false },
            relaunch: { false }
        )

        XCTAssertTrue(result.cleanup.succeeded)
        XCTAssertFalse(result.relaunched)
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.root.path))
    }

    func testApplicationInstallerKeepsBackupUntilRelaunch() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let current = root.appendingPathComponent("RuSwitcher.app", isDirectory: true)
        let staged = root.appendingPathComponent("staged/RuSwitcher.app", isDirectory: true)
        let candidate = root.appendingPathComponent(".candidate.app", isDirectory: true)
        let backup = root.appendingPathComponent(".backup.app", isDirectory: true)
        try writeMarker("old", to: current)
        try writeMarker("new", to: staged)

        let result = try UpdateApplicationInstaller.install(
            stagedApplication: staged,
            currentApplication: current,
            candidateApplication: candidate,
            backupApplication: backup,
            validate: { self.readMarker(from: $0) == "new" }
        )

        XCTAssertEqual(result, UpdateApplicationInstallResult(
            currentApplication: current.standardizedFileURL,
            backupApplication: backup.standardizedFileURL
        ))
        XCTAssertEqual(readMarker(from: current), "new")
        XCTAssertEqual(readMarker(from: backup), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
    }

    func testApplicationInstallerRollsBackFailedInstalledValidation() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let current = root.appendingPathComponent("RuSwitcher.app", isDirectory: true)
        let staged = root.appendingPathComponent("staged/RuSwitcher.app", isDirectory: true)
        let candidate = root.appendingPathComponent(".candidate.app", isDirectory: true)
        let backup = root.appendingPathComponent(".backup.app", isDirectory: true)
        try writeMarker("old", to: current)
        try writeMarker("new", to: staged)
        var validationCount = 0

        XCTAssertThrowsError(try UpdateApplicationInstaller.install(
            stagedApplication: staged,
            currentApplication: current,
            candidateApplication: candidate,
            backupApplication: backup,
            validate: { _ in
                validationCount += 1
                return validationCount == 1
            }
        )) { error in
            XCTAssertEqual(error as? UpdateApplicationInstallError, .installedValidationFailed)
        }

        XCTAssertEqual(readMarker(from: current), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
    }

    func testApplicationInstallerExplicitRollbackRestoresOldBundle() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let current = root.appendingPathComponent("RuSwitcher.app", isDirectory: true)
        let staged = root.appendingPathComponent("staged/RuSwitcher.app", isDirectory: true)
        let candidate = root.appendingPathComponent(".candidate.app", isDirectory: true)
        let backup = root.appendingPathComponent(".backup.app", isDirectory: true)
        try writeMarker("old", to: current)
        try writeMarker("new", to: staged)
        let result = try UpdateApplicationInstaller.install(
            stagedApplication: staged,
            currentApplication: current,
            candidateApplication: candidate,
            backupApplication: backup,
            validate: { self.readMarker(from: $0) == "new" }
        )

        XCTAssertTrue(UpdateApplicationInstaller.rollback(result))
        XCTAssertEqual(readMarker(from: current), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testApplicationInstallerRejectsExistingBackupWithoutMutation() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let current = root.appendingPathComponent("RuSwitcher.app", isDirectory: true)
        let staged = root.appendingPathComponent("staged/RuSwitcher.app", isDirectory: true)
        let candidate = root.appendingPathComponent(".candidate.app", isDirectory: true)
        let backup = root.appendingPathComponent(".backup.app", isDirectory: true)
        try writeMarker("old", to: current)
        try writeMarker("new", to: staged)
        try writeMarker("occupied", to: backup)

        XCTAssertThrowsError(try UpdateApplicationInstaller.install(
            stagedApplication: staged,
            currentApplication: current,
            candidateApplication: candidate,
            backupApplication: backup,
            validate: { _ in true }
        )) { error in
            XCTAssertEqual(error as? UpdateApplicationInstallError, .destinationAlreadyExists)
        }
        XCTAssertEqual(readMarker(from: current), "old")
        XCTAssertEqual(readMarker(from: backup), "occupied")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "RuSwitcherAppSupportTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func writeInfoPlist(appURL: URL, version: String, build: String) throws {
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let dictionary: [String: Any] = [
            "CFBundleIdentifier": "ru.rashn.RuSwitcher",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .xml,
            options: 0
        )
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"), options: .atomic)
    }

    private func writeMarker(_ marker: String, to application: URL) throws {
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)
        try Data(marker.utf8).write(
            to: application.appendingPathComponent("marker.txt"),
            options: .atomic
        )
    }

    private func readMarker(from application: URL) -> String? {
        guard let data = try? Data(contentsOf: application.appendingPathComponent("marker.txt")) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func assertThrows<T>(
        _ expression: @autoclosure () throws -> T,
        equals expected: UpdateReleaseMetadataError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? UpdateReleaseMetadataError, expected, file: file, line: line)
        }
    }

    private func assertBundleValidation(
        _ actual: ReleaseBundleInfo,
        expected: ReleaseVersion,
        error expectedError: ReleaseBundleValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ReleaseBundleValidator.validate(
                actual,
                expectedBundleIdentifier: "ru.rashn.RuSwitcher",
                expectedRelease: expected
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? ReleaseBundleValidationError, expectedError, file: file, line: line)
        }
    }
}
