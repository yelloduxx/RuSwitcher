// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuSwitcher",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "RuSwitcherCore",
            path: "Sources/RuSwitcherCore",
            resources: [
                .process("Resources/language-model-v1.bin"),
            ]
        ),
        .target(
            name: "RuSwitcherExperimentalV4",
            dependencies: ["RuSwitcherCore"],
            path: "Sources/RuSwitcherExperimentalV4",
            resources: [
                .process("Resources/layout-model-v4.json"),
                .copy("Resources/LayoutRerankerV4.mlmodelc"),
            ],
            linkerSettings: [.linkedFramework("CoreML")]
        ),
        .target(
            name: "RuSwitcherAppSupport",
            dependencies: ["RuSwitcherCore"],
            path: "Sources/RuSwitcherAppSupport",
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .executableTarget(
            name: "RuSwitcher",
            dependencies: ["RuSwitcherCore", "RuSwitcherAppSupport"],
            path: "Sources/RuSwitcher",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .executableTarget(
            name: "RuSwitcherSimulator",
            dependencies: ["RuSwitcherCore", "RuSwitcherExperimentalV4"],
            path: "Sources/RuSwitcherSimulator"
        ),
        .testTarget(
            name: "RuSwitcherCoreTests",
            dependencies: ["RuSwitcherCore"],
            path: "Tests/RuSwitcherCoreTests"
        ),
        .testTarget(
            name: "RuSwitcherAppSupportTests",
            dependencies: ["RuSwitcherAppSupport", "RuSwitcherCore"],
            path: "Tests/RuSwitcherAppSupportTests"
        ),
        .testTarget(
            name: "RuSwitcherExperimentalV4Tests",
            dependencies: ["RuSwitcherCore", "RuSwitcherExperimentalV4"],
            path: "Tests/RuSwitcherExperimentalV4Tests"
        )
    ]
)
