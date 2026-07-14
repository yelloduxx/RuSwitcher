import Foundation

public enum UpdateReleaseMetadataError: Error, Equatable, Sendable {
    case invalidVersion
    case invalidBuild
    case missingSHA256
    case invalidSHA256
}

public struct UpdateReleaseMetadata: Decodable, Equatable, Sendable {
    public let version: String
    public let build: String
    public let url: String
    public let notes: String?
    public let sha256: String?

    private enum CodingKeys: String, CodingKey {
        case version
        case build
        case url
        case notes
        case sha256
    }

    public init(
        version: String,
        build: String,
        url: String,
        notes: String? = nil,
        sha256: String? = nil
    ) {
        self.version = version
        self.build = build
        self.url = url
        self.notes = notes
        self.sha256 = sha256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        url = try container.decode(String.self, forKey: .url)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)

        if let stringBuild = try? container.decode(String.self, forKey: .build) {
            build = stringBuild
        } else {
            build = String(try container.decode(Int.self, forKey: .build))
        }
    }

    public func validatedReleaseVersion() throws -> ReleaseVersion {
        guard let numericBuild = Int(build) else {
            throw UpdateReleaseMetadataError.invalidBuild
        }
        guard let release = ReleaseVersion(validatingVersion: version, build: numericBuild) else {
            if numericBuild <= 0 {
                throw UpdateReleaseMetadataError.invalidBuild
            }
            throw UpdateReleaseMetadataError.invalidVersion
        }
        return release
    }

    public func validatedSHA256() throws -> String {
        guard let sha256, !sha256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UpdateReleaseMetadataError.missingSHA256
        }
        let normalized = sha256.lowercased()
        guard normalized.utf8.count == 64,
              normalized.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            throw UpdateReleaseMetadataError.invalidSHA256
        }
        return normalized
    }
}

public struct ReleaseBundleInfo: Equatable, Sendable {
    public let bundleIdentifier: String
    public let version: String
    public let build: Int

    public init(bundleIdentifier: String, version: String, build: Int) {
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
    }
}

public enum ReleaseBundleInfoError: Error, Equatable, Sendable {
    case unreadableInfoPlist
    case invalidInfoPlist
    case missingBundleIdentifier
    case missingVersion
    case invalidBuild
}

public enum ReleaseBundleInfoReader {
    public static func read(appURL: URL) throws -> ReleaseBundleInfo {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        let data: Data
        do {
            data = try Data(contentsOf: infoURL, options: .mappedIfSafe)
        } catch {
            throw ReleaseBundleInfoError.unreadableInfoPlist
        }

        let raw: [String: Any]
        do {
            guard let dictionary = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any] else {
                throw ReleaseBundleInfoError.invalidInfoPlist
            }
            raw = dictionary
        } catch let error as ReleaseBundleInfoError {
            throw error
        } catch {
            throw ReleaseBundleInfoError.invalidInfoPlist
        }

        guard let bundleIdentifier = raw["CFBundleIdentifier"] as? String,
              !bundleIdentifier.isEmpty else {
            throw ReleaseBundleInfoError.missingBundleIdentifier
        }
        guard let version = raw["CFBundleShortVersionString"] as? String,
              !version.isEmpty else {
            throw ReleaseBundleInfoError.missingVersion
        }

        let build: Int?
        if let stringBuild = raw["CFBundleVersion"] as? String {
            build = Int(stringBuild)
        } else if let numberBuild = raw["CFBundleVersion"] as? NSNumber {
            build = numberBuild.intValue
        } else {
            build = nil
        }
        guard let build, build > 0 else {
            throw ReleaseBundleInfoError.invalidBuild
        }

        return ReleaseBundleInfo(
            bundleIdentifier: bundleIdentifier,
            version: version,
            build: build
        )
    }
}

public enum ReleaseBundleValidationError: Error, Equatable, Sendable {
    case bundleIdentifierMismatch
    case versionMismatch
    case buildMismatch
}

public enum ReleaseBundleValidator {
    public static func validate(
        _ actual: ReleaseBundleInfo,
        expectedBundleIdentifier: String,
        expectedRelease: ReleaseVersion
    ) throws {
        guard actual.bundleIdentifier == expectedBundleIdentifier else {
            throw ReleaseBundleValidationError.bundleIdentifierMismatch
        }
        guard actual.version == expectedRelease.version else {
            throw ReleaseBundleValidationError.versionMismatch
        }
        guard actual.build == expectedRelease.build else {
            throw ReleaseBundleValidationError.buildMismatch
        }
    }
}

public struct UpdateInstallCleanupResult: Equatable, Sendable {
    public let detached: Bool
    public let removed: Bool

    public var succeeded: Bool { detached && removed }
}

public struct UpdateInstallFinalizationResult: Equatable, Sendable {
    public let cleanup: UpdateInstallCleanupResult
    public let relaunched: Bool

    public var succeeded: Bool { cleanup.succeeded && relaunched }
}

public struct UpdateInstallWorkspace: Equatable, Sendable {
    public let root: URL
    public let diskImage: URL
    public let mountPoint: URL
    public let stagingDirectory: URL

    public static func create(
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> UpdateInstallWorkspace {
        let root = temporaryDirectory.appendingPathComponent(
            "RuSwitcher-update-\(UUID().uuidString)",
            isDirectory: true
        )
        let workspace = UpdateInstallWorkspace(
            root: root,
            diskImage: root.appendingPathComponent("update.dmg", isDirectory: false),
            mountPoint: root.appendingPathComponent("mount", isDirectory: true),
            stagingDirectory: root.appendingPathComponent("staging", isDirectory: true)
        )

        do {
            try fileManager.createDirectory(at: workspace.mountPoint, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: workspace.stagingDirectory, withIntermediateDirectories: true)
            return workspace
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    public func cleanup(
        isMounted: Bool,
        fileManager: FileManager = .default,
        detach: (URL) -> Bool
    ) -> UpdateInstallCleanupResult {
        let detached = !isMounted || detach(mountPoint)
        guard detached else {
            return UpdateInstallCleanupResult(detached: false, removed: false)
        }
        do {
            if fileManager.fileExists(atPath: root.path) {
                try fileManager.removeItem(at: root)
            }
            return UpdateInstallCleanupResult(detached: detached, removed: true)
        } catch {
            return UpdateInstallCleanupResult(detached: detached, removed: false)
        }
    }
}

public enum UpdateInstallFinalizer {
    @discardableResult
    public static func finalize(
        workspace: UpdateInstallWorkspace,
        isMounted: Bool,
        fileManager: FileManager = .default,
        detach: (URL) -> Bool,
        relaunch: () -> Bool
    ) -> UpdateInstallFinalizationResult {
        let cleanup = workspace.cleanup(
            isMounted: isMounted,
            fileManager: fileManager,
            detach: detach
        )
        let relaunched = cleanup.succeeded && relaunch()
        return UpdateInstallFinalizationResult(
            cleanup: cleanup,
            relaunched: relaunched
        )
    }
}

public enum UpdateApplicationInstallError: Error, Equatable, Sendable {
    case invalidPaths
    case missingCurrentApplication
    case missingStagedApplication
    case destinationAlreadyExists
    case stagingFailed
    case candidateValidationFailed
    case backupFailed
    case replacementFailed
    case installedValidationFailed
    case rollbackFailed
}

public struct UpdateApplicationInstallResult: Equatable, Sendable {
    public let currentApplication: URL
    public let backupApplication: URL

    public init(currentApplication: URL, backupApplication: URL) {
        self.currentApplication = currentApplication
        self.backupApplication = backupApplication
    }
}

/// Installs a staged application through same-directory renames while retaining
/// the previous bundle until the caller has completed cleanup and relaunch.
public enum UpdateApplicationInstaller {
    public static func install(
        stagedApplication: URL,
        currentApplication: URL,
        candidateApplication: URL,
        backupApplication: URL,
        fileManager: FileManager = .default,
        validate: (URL) -> Bool
    ) throws -> UpdateApplicationInstallResult {
        let current = currentApplication.standardizedFileURL
        let candidate = candidateApplication.standardizedFileURL
        let backup = backupApplication.standardizedFileURL
        let parent = current.deletingLastPathComponent()
        guard candidate.deletingLastPathComponent() == parent,
              backup.deletingLastPathComponent() == parent,
              current != candidate,
              current != backup,
              candidate != backup else {
            throw UpdateApplicationInstallError.invalidPaths
        }
        guard fileManager.fileExists(atPath: current.path) else {
            throw UpdateApplicationInstallError.missingCurrentApplication
        }
        guard fileManager.fileExists(atPath: stagedApplication.path) else {
            throw UpdateApplicationInstallError.missingStagedApplication
        }
        guard !fileManager.fileExists(atPath: candidate.path),
              !fileManager.fileExists(atPath: backup.path) else {
            throw UpdateApplicationInstallError.destinationAlreadyExists
        }

        do {
            try fileManager.copyItem(at: stagedApplication, to: candidate)
        } catch {
            try? fileManager.removeItem(at: candidate)
            throw UpdateApplicationInstallError.stagingFailed
        }
        guard validate(candidate) else {
            try? fileManager.removeItem(at: candidate)
            throw UpdateApplicationInstallError.candidateValidationFailed
        }

        do {
            try fileManager.moveItem(at: current, to: backup)
        } catch {
            try? fileManager.removeItem(at: candidate)
            throw UpdateApplicationInstallError.backupFailed
        }

        do {
            try fileManager.moveItem(at: candidate, to: current)
        } catch {
            guard restore(
                currentApplication: current,
                backupApplication: backup,
                candidateApplication: candidate,
                fileManager: fileManager
            ) else {
                throw UpdateApplicationInstallError.rollbackFailed
            }
            throw UpdateApplicationInstallError.replacementFailed
        }

        guard validate(current) else {
            guard restore(
                currentApplication: current,
                backupApplication: backup,
                candidateApplication: candidate,
                fileManager: fileManager
            ) else {
                throw UpdateApplicationInstallError.rollbackFailed
            }
            throw UpdateApplicationInstallError.installedValidationFailed
        }

        return UpdateApplicationInstallResult(
            currentApplication: current,
            backupApplication: backup
        )
    }

    @discardableResult
    public static func rollback(
        _ result: UpdateApplicationInstallResult,
        fileManager: FileManager = .default
    ) -> Bool {
        restore(
            currentApplication: result.currentApplication,
            backupApplication: result.backupApplication,
            candidateApplication: nil,
            fileManager: fileManager
        )
    }

    private static func restore(
        currentApplication: URL,
        backupApplication: URL,
        candidateApplication: URL?,
        fileManager: FileManager
    ) -> Bool {
        do {
            if fileManager.fileExists(atPath: currentApplication.path) {
                try fileManager.removeItem(at: currentApplication)
            }
            guard fileManager.fileExists(atPath: backupApplication.path) else {
                return false
            }
            try fileManager.moveItem(at: backupApplication, to: currentApplication)
            if let candidateApplication,
               fileManager.fileExists(atPath: candidateApplication.path) {
                try fileManager.removeItem(at: candidateApplication)
            }
            return fileManager.fileExists(atPath: currentApplication.path)
                && !fileManager.fileExists(atPath: backupApplication.path)
        } catch {
            return false
        }
    }
}
