// swift-tools-version:5.9
import PackageDescription

// Four layers, each one unable to reach the one above it — which is the point.
//
//   OpenSmartPenCore    the domain: strokes, books, pens, git. Foundation only.
//   OpenSmartPenUI      every window and view. Knows the domain, knows nothing of the pen SDK.
//   OpenSmartPen        the app: the pen SDK, the wiring, the menubar.
//   OpenSmartPenDesign  fixtures and the design window. Nothing else can import it, so none of it
//                     can end up in the shipped app by accident.
let package = Package(
    name: "OpenSmartPen",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "opensmartpen", targets: ["OpenSmartPen"]),
        .executable(name: "opensmartpen-design", targets: ["OpenSmartPenDesignApp"]),
        .library(name: "OpenSmartPenCore", targets: ["OpenSmartPenCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/NeoSmartpen/iOS-SDK3.0.git", exact: "1.1.5"),
        // The updater of a packaged release. Only the app target links it.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        // Telemetry. Only the app target links these: the domain and the UI speak to a small
        // protocol of our own (`Telemetry` in OpenSmartPenCore) and know nothing of the SDK.
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift-core.git", from: "2.6.0"),
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift.git", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "OpenSmartPenCore",
            path: "Sources/OpenSmartPenCore"
        ),
        .target(
            name: "OpenSmartPenUI",
            dependencies: ["OpenSmartPenCore"],
            path: "Sources/OpenSmartPenUI"
        ),
        .executableTarget(
            name: "OpenSmartPen",
            dependencies: [
                "OpenSmartPenCore",
                "OpenSmartPenUI",
                .product(name: "NISDK3", package: "iOS-SDK3.0"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetryProtocolExporterHTTP", package: "opentelemetry-swift"),
                .product(name: "PersistenceExporter", package: "opentelemetry-swift"),
            ],
            path: "Sources/OpenSmartPen"
        ),
        // A library rather than only an executable: fixtures a test target can also reach.
        .target(
            name: "OpenSmartPenDesign",
            dependencies: ["OpenSmartPenCore", "OpenSmartPenUI"],
            path: "Sources/OpenSmartPenDesign"
        ),
        .executableTarget(
            name: "OpenSmartPenDesignApp",
            dependencies: ["OpenSmartPenDesign"],
            path: "Sources/OpenSmartPenDesignApp"
        ),
        .testTarget(
            name: "OpenSmartPenCoreTests",
            // The UI layer too, for one thing only: the page image. It is the one piece of drawing
            // whose output nobody looks at — it goes to a model — so it is the one that has to be
            // checked by a test rather than by eye.
            dependencies: ["OpenSmartPenCore", "OpenSmartPenUI"],
            path: "Tests/OpenSmartPenCoreTests"
        ),
    ]
)
