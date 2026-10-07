// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SDRConsole",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SDRConsole", targets: ["SDRConsole"]),
    ],
    targets: [
        .target(name: "SDRCore", path: "Sources/SDRCore"),
        .executableTarget(name: "SDRConsole", dependencies: ["SDRCore"], path: "Sources/SDRConsole"),
        .testTarget(name: "SDRCoreTests", dependencies: ["SDRCore"], path: "Tests/SDRCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
