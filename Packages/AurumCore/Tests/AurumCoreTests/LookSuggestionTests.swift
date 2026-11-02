import XCTest
@testable import AurumCore

final class LookSuggestionTests: XCTestCase {
    func testBlackAndWhitePhotosGetNoir() throws {
        let catalog = try TestSupport.shippedCatalog()
        let look = LookSuggestion.suggest(for: ImageStats(luminance: 0.5, saturation: 0.02, warmth: 0), vibes: ["riviera"], catalog: catalog)
        XCTAssertEqual(look?.collection, "noir")
    }

    func testChosenVibeWinsForColourPhotos() throws {
        let catalog = try TestSupport.shippedCatalog()
        let look = LookSuggestion.suggest(for: ImageStats(luminance: 0.5, saturation: 0.3, warmth: 0.2), vibes: ["prism"], catalog: catalog)
        XCTAssertEqual(look?.collection, "prism")
    }

    func testWarmPhotoWithoutVibesGetsFilm() throws {
        let catalog = try TestSupport.shippedCatalog()
        let look = LookSuggestion.suggest(for: ImageStats(luminance: 0.5, saturation: 0.3, warmth: 0.2), vibes: [], catalog: catalog)
        XCTAssertEqual(look?.collection, "film-analog")
    }

    func testOnlyFreeLooksAreSuggested() throws {
        let catalog = try TestSupport.shippedCatalog()
        for lum in stride(from: 0.0, through: 1.0, by: 0.1) {
            let look = LookSuggestion.suggest(for: ImageStats(luminance: lum, saturation: 0.3, warmth: 0), vibes: ["seasons"], catalog: catalog)
            XCTAssertEqual(look?.tier, .free)
        }
    }
}
