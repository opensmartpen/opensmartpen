// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BrainioPen",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "brainio-pen", targets: ["BrainioPen"]),
        .library(name: "BrainioPenCore", targets: ["BrainioPenCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/NeoSmartpen/iOS-SDK3.0.git", exact: "1.1.5"),
    ],
    targets: [
        .target(
            name: "BrainioPenCore",
            path: "Sources/BrainioPenCore"
        ),
        .executableTarget(
            name: "BrainioPen",
            dependencies: [
                "BrainioPenCore",
                .product(name: "NISDK3", package: "iOS-SDK3.0"),
            ],
            path: "Sources/BrainioPen"
        ),
        .testTarget(
            name: "BrainioPenCoreTests",
            dependencies: ["BrainioPenCore"],
            path: "Tests/BrainioPenCoreTests"
        ),
    ]
)
