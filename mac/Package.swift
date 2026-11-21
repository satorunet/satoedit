// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "Hinoki",
    platforms: [.macOS(.v11)],
    dependencies: [
        // 自動アップデート (MIT License)。2.10 からは macOS 12 以上になるので 2.9 系
        .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMinor(from: "2.9.6")),
    ],
    targets: [
        .target(name: "HinokiCore", path: "Sources/HinokiCore"),
        .executableTarget(name: "Hinoki", dependencies: ["HinokiCore", .product(name: "Sparkle", package: "Sparkle")], path: "Sources/Hinoki",
                          // この Mac の SDK には Sparkle の見出しが使う NS_SWIFT_SENDABLE がないので空にする (注釈だけなので動きは変わらない)
                          swiftSettings: [.unsafeFlags(["-Xcc", "-DNS_SWIFT_SENDABLE="])],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "HinokiCoreTests", dependencies: ["HinokiCore"], path: "Tests/HinokiCoreTests"),
    ]
)
