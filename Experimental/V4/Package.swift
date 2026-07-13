// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuSwitcherV4Research",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "RuSwitcherExperimentalV4",
            dependencies: [
                .product(name: "RuSwitcherCore", package: "ruswitch"),
            ],
            resources: [
                .process("Resources/layout-model-v4.json"),
                .copy("Resources/LayoutRerankerV4.mlmodelc"),
            ],
            linkerSettings: [.linkedFramework("CoreML")]
        ),
        .testTarget(
            name: "RuSwitcherExperimentalV4Tests",
            dependencies: [
                "RuSwitcherExperimentalV4",
                .product(name: "RuSwitcherCore", package: "ruswitch"),
            ]
        ),
    ]
)
