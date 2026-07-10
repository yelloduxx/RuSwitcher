// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuSwitcher",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "RuSwitcherCore",
            path: "Sources/RuSwitcherCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "RuSwitcher",
            dependencies: ["RuSwitcherCore"],
            path: "Sources/RuSwitcher",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "RuSwitcherCoreTests",
            dependencies: ["RuSwitcherCore"],
            path: "Tests/RuSwitcherCoreTests"
        )
    ]
)
