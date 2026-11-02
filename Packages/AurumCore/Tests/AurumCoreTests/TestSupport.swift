import Foundation
@testable import AurumCore

enum TestSupport {
    /// The repository root, found relative to this source file.
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AurumCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // AurumCore
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repo root
    }

    /// The real catalogue shipped with the app.
    static func shippedCatalog() throws -> LookCatalog {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Looks/catalog.json"))
        return try LookCatalog.decode(from: data)
    }

    static func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    /// A tiny catalogue with one free and one member look, for focused tests.
    static let smallCatalog = LookCatalog(
        collections: [
            LookCollection(id: "film", name: "Film", tagline: "t"),
            LookCollection(id: "noir", name: "Noir", tagline: "t")
        ],
        looks: [
            LookRecipe(id: "film.a", name: "Alpha", collection: "film", tier: .free, tags: ["warm"], params: LookParameters()),
            LookRecipe(id: "film.b", name: "Bravo", collection: "film", tier: .member, tags: ["warm", "grain"], params: LookParameters()),
            LookRecipe(id: "film.c", name: "Charlie", collection: "film", tier: .free, params: LookParameters()),
            LookRecipe(id: "noir.a", name: "Ink", collection: "noir", tier: .free, tags: ["monochrome"], params: LookParameters())
        ]
    )

    static func document(width: Int = 4000, height: Int = 3000) -> EditDocument {
        EditDocument(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            source: SourceAsset(localIdentifier: "asset-1", pixelSize: PixelSize(width: width, height: height)),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}
