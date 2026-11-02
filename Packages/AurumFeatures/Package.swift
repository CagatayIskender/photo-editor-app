// swift-tools-version:5.9
import PackageDescription

/// AurumFeatures holds the screens: onboarding, Salon, picker, Vault, the
/// Studio with its tool sheets, export and the membership paywall. Each
/// screen keeps its logic in a view model that tests drive without UI.
let package = Package(
    name: "AurumFeatures",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "AurumFeatures", targets: ["AurumFeatures"])
    ],
    dependencies: [
        .package(path: "../AurumCore"),
        .package(path: "../AurumDesign"),
        .package(path: "../AurumRender"),
        .package(path: "../AurumServices")
    ],
    targets: [
        .target(name: "AurumFeatures", dependencies: ["AurumCore", "AurumDesign", "AurumRender", "AurumServices"]),
        .testTarget(name: "AurumFeaturesTests", dependencies: ["AurumFeatures"])
    ]
)
