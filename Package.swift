// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AudiobookForge",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AudiobookForge", targets: ["AudiobookForge"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "AudiobookForge",
            dependencies: [],
            path: "AudiobookForge",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
