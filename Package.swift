// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuSwitcher",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RuSwitcherCore", targets: ["RuSwitcherCore"]),
        .executable(name: "RuSwitcher", targets: ["RuSwitcher"]),
        .executable(name: "RuSwitcherSimulator", targets: ["RuSwitcherSimulator"]),
        .executable(name: "RuSwitcherTypingSimulator", targets: ["RuSwitcherTypingSimulator"]),
        .executable(name: "RuSwitcherModelTool", targets: ["RuSwitcherModelTool"]),
    ],
    targets: [
        .target(
            name: "RuSwitcherCore",
            path: "Sources/RuSwitcherCore",
            resources: [
                .process("Resources/language-model-v1.bin"),
                .process("Resources/layout-ranker-v1.json"),
            ]
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
            dependencies: ["RuSwitcherCore"],
            path: "Sources/RuSwitcherSimulator"
        ),
        .executableTarget(
            name: "RuSwitcherTypingSimulator",
            dependencies: ["RuSwitcherCore"],
            path: "Sources/RuSwitcherTypingSimulator"
        ),
        .executableTarget(
            name: "RuSwitcherModelTool",
            dependencies: ["RuSwitcherCore"],
            path: "Sources/RuSwitcherModelTool"
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
        )
    ]
)
