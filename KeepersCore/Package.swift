// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KeepersCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "KeepersCore", targets: ["KeepersCore"]),
        .executable(name: "keepers-eval", targets: ["keepers-eval"]),
    ],
    targets: [
        .target(name: "KeepersCore"),
        .executableTarget(name: "keepers-eval", dependencies: ["KeepersCore"]),
        .testTarget(name: "KeepersCoreTests", dependencies: ["KeepersCore"]),
    ]
)
