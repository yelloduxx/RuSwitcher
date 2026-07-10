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
                .process("Resources/layout-model-v4.json"),
                .copy("Resources/LayoutRerankerV4.mlmodelc"),
            ],
            linkerSettings: [.linkedFramework("CoreML")]
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
        .executableTarget(
            name: "RuSwitcherSimulator",
            dependencies: ["RuSwitcherCore"],
            path: "Sources/RuSwitcherSimulator"
        ),
        .testTarget(
            name: "RuSwitcherCoreTests",
            dependencies: ["RuSwitcherCore"],
            path: "Tests/RuSwitcherCoreTests"
        )
    ]
)
