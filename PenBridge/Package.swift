// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PenBridge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "penbridge", targets: ["PenBridge"]),
        .library(name: "PenBridgeCore", targets: ["PenBridgeCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/NeoSmartpen/iOS-SDK3.0.git", exact: "1.1.5"),
    ],
    targets: [
        .target(
            name: "PenBridgeCore",
            path: "Sources/PenBridgeCore"
        ),
        .executableTarget(
            name: "PenBridge",
            dependencies: [
                "PenBridgeCore",
                .product(name: "NISDK3", package: "iOS-SDK3.0"),
            ],
            path: "Sources/PenBridge"
        ),
        .testTarget(
            name: "PenBridgeCoreTests",
            dependencies: ["PenBridgeCore"],
            path: "Tests/PenBridgeCoreTests"
        ),
    ]
)
