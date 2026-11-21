// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "Hinoki",
    platforms: [.macOS(.v11)],
    targets: [
        .target(name: "HinokiCore", path: "Sources/HinokiCore"),
        .executableTarget(name: "Hinoki", dependencies: ["HinokiCore"], path: "Sources/Hinoki"),
        .testTarget(name: "HinokiCoreTests", dependencies: ["HinokiCore"], path: "Tests/HinokiCoreTests"),
    ]
)
