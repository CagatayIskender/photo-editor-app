// swift-tools-version:5.9
import PackageDescription

/// AurumCore holds the platform-agnostic heart of the app: the edit graph,
/// undo history, look recipes, export rules and preset links.
/// It must not import UIKit, SwiftUI, CoreImage or any Apple-only framework,
/// so that it builds and tests on Linux CI.
let package = Package(
    name: "AurumCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "AurumCore", targets: ["AurumCore"])
    ],
    targets: [
        .target(name: "AurumCore"),
        .testTarget(
            name: "AurumCoreTests",
            dependencies: ["AurumCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
