// swift-tools-version:5.9
import PackageDescription

// Four layers, each one unable to reach the one above it — which is the point.
//
//   BrainioPenCore    the domain: strokes, books, pens, git. Foundation only.
//   BrainioPenUI      every window and view. Knows the domain, knows nothing of the pen SDK.
//   BrainioPen        the app: the pen SDK, the wiring, the menubar.
//   BrainioPenDesign  fixtures and the design window. Nothing else can import it, so none of it
//                     can end up in the shipped app by accident.
let package = Package(
    name: "BrainioPen",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "brainio-pen", targets: ["BrainioPen"]),
        .executable(name: "brainio-pen-design", targets: ["BrainioPenDesignApp"]),
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
        .target(
            name: "BrainioPenUI",
            dependencies: ["BrainioPenCore"],
            path: "Sources/BrainioPenUI"
        ),
        .executableTarget(
            name: "BrainioPen",
            dependencies: [
                "BrainioPenCore",
                "BrainioPenUI",
                .product(name: "NISDK3", package: "iOS-SDK3.0"),
            ],
            path: "Sources/BrainioPen"
        ),
        // A library rather than only an executable: fixtures a test target can also reach.
        .target(
            name: "BrainioPenDesign",
            dependencies: ["BrainioPenCore", "BrainioPenUI"],
            path: "Sources/BrainioPenDesign"
        ),
        .executableTarget(
            name: "BrainioPenDesignApp",
            dependencies: ["BrainioPenDesign"],
            path: "Sources/BrainioPenDesignApp"
        ),
        .testTarget(
            name: "BrainioPenCoreTests",
            // The UI layer too, for one thing only: the page image. It is the one piece of drawing
            // whose output nobody looks at — it goes to a model — so it is the one that has to be
            // checked by a test rather than by eye.
            dependencies: ["BrainioPenCore", "BrainioPenUI"],
            path: "Tests/BrainioPenCoreTests"
        ),
    ]
)
