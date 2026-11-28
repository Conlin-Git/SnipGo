// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SnipGo",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "SnipCore", path: "Sources/SnipCore"),
        .executableTarget(name: "SnipGo", dependencies: ["SnipCore"], path: "Sources/SnipGo"),
        .testTarget(name: "SnipGoTests", dependencies: ["SnipGo"]),
        .testTarget(name: "SnipCoreTests", dependencies: ["SnipCore"], path: "Tests/SnipCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
