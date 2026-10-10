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
        // FreeDV RADE decoder. Its sources (vendor/) are fetched by scripts/fetch-rade.sh and not checked in;
        // without them the target builds as a stub and RADE mode is hidden.
        .target(
            name: "CRADE",
            path: "Sources/CRADE",
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("."),
                .headerSearchPath("vendor/opus/dnn"),
                .headerSearchPath("vendor/opus/celt"),
                .headerSearchPath("vendor/opus/include"),
                .headerSearchPath("vendor/opus"),
                .headerSearchPath("vendor/rade"),
                // Third-party code, compiled as-is.
                .unsafeFlags(["-w", "-O2"]),
            ]
        ),
        .target(name: "SDRCore", dependencies: ["CSDRplay", "CRADE"], path: "Sources/SDRCore"),
        .executableTarget(name: "Kymara", dependencies: [
            "SDRCore",
            .product(name: "Sparkle", package: "Sparkle"),
        ], path: "Sources/Kymara"),
        .testTarget(name: "SDRCoreTests", dependencies: ["SDRCore"], path: "Tests/SDRCoreTests",
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "KymaraTests", dependencies: ["Kymara"], path: "Tests/KymaraTests"),
    ],
    swiftLanguageModes: [.v5]
)
