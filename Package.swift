// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Still",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "StillCore", targets: ["StillCore"]),
        .executable(name: "still", targets: ["StillDesktop"]),
        .executable(name: "still-cli", targets: ["StillCLI"]),
        .executable(name: "still-checks", targets: ["StillChecks"])
    ],
    targets: [
        .target(name: "StillCore"),
        .executableTarget(
            name: "StillDesktop",
            dependencies: ["StillCore"]
        ),
        .executableTarget(
            name: "StillCLI",
            dependencies: ["StillCore"]
        ),
        .executableTarget(
            name: "StillChecks",
            dependencies: ["StillCore"]
        ),
        .testTarget(
            name: "StillCoreTests",
            dependencies: ["StillCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)
