// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kymara",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Kymara", targets: ["Kymara"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        .target(name: "CSDRplay", path: "Sources/CSDRplay"),
        .target(name: "SDRCore", dependencies: ["CSDRplay"], path: "Sources/SDRCore"),
        .executableTarget(name: "Kymara", dependencies: [
            "SDRCore",
            .product(name: "Sparkle", package: "Sparkle"),
        ], path: "Sources/Kymara"),
        .testTarget(name: "SDRCoreTests", dependencies: ["SDRCore"], path: "Tests/SDRCoreTests"),
        .testTarget(name: "KymaraTests", dependencies: ["Kymara"], path: "Tests/KymaraTests"),
    ],
    swiftLanguageModes: [.v5]
)
