// swift-tools-version:5.9
import PackageDescription

/// AurumDesign: the "Quiet Luxury" design system. Tokens, type, icons and
/// reusable SwiftUI components. No business logic lives here.
let package = Package(
    name: "AurumDesign",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "AurumDesign", targets: ["AurumDesign"])
    ],
    targets: [
        .target(name: "AurumDesign"),
        .testTarget(name: "AurumDesignTests", dependencies: ["AurumDesign"])
    ]
)
