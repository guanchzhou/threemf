// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "threemf",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ThreeMFCore", targets: ["ThreeMFCore"]),
        .executable(name: "threemf-cli", targets: ["ThreeMFCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "ThreeMFCore",
            dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")],
            path: "Sources/Shared"
        ),
        .executableTarget(
            name: "ThreeMFCLI",
            dependencies: ["ThreeMFCore"],
            path: "Sources/CLI"
        ),
        .testTarget(
            name: "ThreeMFCoreTests",
            dependencies: ["ThreeMFCore"],
            path: "Tests"
        ),
    ]
)
