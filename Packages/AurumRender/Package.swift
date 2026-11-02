// swift-tools-version:5.9
import PackageDescription

/// AurumRender turns an `EditDocument` into pixels with Core Image on Metal.
/// The same compiled filter graph renders the live preview (from a
/// screen-size proxy) and the full-resolution export.
let package = Package(
    name: "AurumRender",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "AurumRender", targets: ["AurumRender"])
    ],
    dependencies: [
        .package(path: "../AurumCore")
    ],
    targets: [
        .target(name: "AurumRender", dependencies: ["AurumCore"]),
        .testTarget(name: "AurumRenderTests", dependencies: ["AurumRender"])
    ]
)
