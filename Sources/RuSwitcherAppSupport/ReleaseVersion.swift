import Foundation

public struct ReleaseVersion: Equatable, Comparable, Sendable {
    public let version: String
    public let build: Int

    public init(version: String, build: Int) {
        self.version = version
        self.build = build
    }

    public var identifier: String { "\(version)+\(build)" }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let left = numericParts(lhs.version)
        let right = numericParts(rhs.version)
        for index in 0..<max(left.count, right.count) {
            let leftPart = index < left.count ? left[index] : 0
            let rightPart = index < right.count ? right[index] : 0
            if leftPart != rightPart { return leftPart < rightPart }
        }
        return lhs.build < rhs.build
    }

    public func matchesSkipIdentifier(_ value: String) -> Bool {
        value == identifier
    }

    private static func numericParts(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }
}
