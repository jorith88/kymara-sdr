// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kymara",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Kymara", targets: ["Kymara"]),
    ],
    targets: [
        .target(name: "SDRCore", path: "Sources/SDRCore"),
        .executableTarget(name: "Kymara", dependencies: ["SDRCore"], path: "Sources/Kymara"),
        .testTarget(name: "SDRCoreTests", dependencies: ["SDRCore"], path: "Tests/SDRCoreTests"),
        .testTarget(name: "KymaraTests", dependencies: ["Kymara"], path: "Tests/KymaraTests"),
    ],
    swiftLanguageModes: [.v5]
)
