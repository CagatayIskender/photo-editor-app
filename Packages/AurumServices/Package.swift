// swift-tools-version:5.9
import PackageDescription

/// AurumServices: everything that talks to the outside world. Each service is
/// a protocol with a live implementation and an in-memory one for previews
/// and tests.
let package = Package(
    name: "AurumServices",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "AurumServices", targets: ["AurumServices"])
    ],
    dependencies: [
        .package(path: "../AurumCore")
    ],
    targets: [
        .target(name: "AurumServices", dependencies: ["AurumCore"]),
        .testTarget(name: "AurumServicesTests", dependencies: ["AurumServices"])
    ]
)
