import XCTest
@testable import AurumCore

final class LookCatalogTests: XCTestCase {
    /// Competitor, app and camera-brand terms that must never appear in our names.
    /// Mirrors the list in tools/generate_catalog.py.
    static let denyList = [
        "vsco", "huji", "dazz", "lightroom", "snapseed", "picsart", "prequel", "facetune",
        "kodak", "fuji", "polaroid", "ilford", "agfa", "instagram", "tiktok", "lomo",
        "portra", "ektar", "velvia", "tri-x", "hp5", "cinestill", "hasselblad", "leica"
    ]

    func testShippedCatalogHasOneHundredLooksInTenCollections() throws {
        let catalog = try TestSupport.shippedCatalog()
        XCTAssertEqual(catalog.looks.count, 100)
        XCTAssertEqual(catalog.collections.count, 10)
        for collection in catalog.collections {
            XCTAssertEqual(catalog.looks(in: collection.id).count, 10, collection.id)
        }
    }

    func testShippedCatalogHasThirtyFreeLooks() throws {
        let catalog = try TestSupport.shippedCatalog()
        XCTAssertEqual(catalog.looks.filter { $0.tier == .free }.count, 30)
    }

    func testNoNameUsesADeniedTerm() throws {
        let catalog = try TestSupport.shippedCatalog()
        let names = catalog.looks.map(\.name) + catalog.collections.map(\.name)
        for name in names {
            for term in Self.denyList {
                XCTAssertFalse(name.lowercased().contains(term), "\(name) contains \(term)")
            }
        }
    }

    func testParametersAreInRange() throws {
        let catalog = try TestSupport.shippedCatalog()
        for look in catalog.looks {
            let p = look.params
            for v in [p.exposure, p.contrast, p.highlights, p.shadows, p.saturation, p.vibrance, p.warmth, p.tint] {
                XCTAssertTrue((-1.0...1.0).contains(v), look.id)
            }
            for v in [p.fade, p.grain, p.vignette, p.lightLeak, p.bloom] {
                XCTAssertTrue((0.0...1.0).contains(v), look.id)
            }
            XCTAssertEqual(p.shadowsTint.count, 3, look.id)
            XCTAssertEqual(p.highlightsTint.count, 3, look.id)
        }
    }

    func testDuplicateIDsAreRejected() {
        var catalog = TestSupport.smallCatalog
        catalog.looks.append(catalog.looks[0])
        XCTAssertThrowsError(try catalog.validate()) { error in
            XCTAssertEqual(error as? LookCatalog.LoadError, .duplicateLookID("film.a"))
        }
    }

    func testUnknownCollectionIsRejected() {
        var catalog = TestSupport.smallCatalog
        catalog.looks.append(LookRecipe(id: "x.y", name: "X", collection: "missing", tier: .free, params: LookParameters()))
        XCTAssertThrowsError(try catalog.validate())
    }

    func testNeighbourWrapsWithinTheCollection() {
        let catalog = TestSupport.smallCatalog
        XCTAssertEqual(catalog.neighbour(of: "film.a", offset: 1)?.id, "film.b")
        XCTAssertEqual(catalog.neighbour(of: "film.c", offset: 1)?.id, "film.a")
        XCTAssertEqual(catalog.neighbour(of: "film.a", offset: -1)?.id, "film.c")
        XCTAssertEqual(catalog.neighbour(of: "noir.a", offset: 1)?.id, "noir.a")
        XCTAssertNil(catalog.neighbour(of: "nope", offset: 1))
    }

    func testSearchRanksNameMatchesFirst() {
        let results = TestSupport.smallCatalog.search("bravo warm")
        XCTAssertEqual(results.first?.id, "film.b")
        XCTAssertTrue(results.contains { $0.id == "film.a" })
    }

    func testSearchUsesSynonyms() {
        let results = TestSupport.smallCatalog.search("bw")
        XCTAssertEqual(results.map(\.id), ["noir.a"])
    }

    func testSearchFindsRealLooks() throws {
        let catalog = try TestSupport.shippedCatalog()
        XCTAssertFalse(catalog.search("warm film").isEmpty)
        XCTAssertFalse(catalog.search("90s").isEmpty)
        XCTAssertFalse(catalog.search("sparkle").isEmpty || catalog.search("glow").isEmpty)
    }

    func testEmptySearchReturnsEverything() {
        XCTAssertEqual(TestSupport.smallCatalog.search("  ").count, 4)
    }

    func testRefineOverridesApply() {
        var params = LookParameters()
        params.grain = 0.2
        let refined = params.applying(RefineOverrides(grain: 3, fade: 0.4))
        XCTAssertEqual(refined.grain, 1)
        XCTAssertEqual(refined.fade, 0.4)
        XCTAssertEqual(refined.vignette, 0)
    }

    func testMissingParametersDecodeToNeutral() throws {
        let json = #"{"warmth": 0.3}"#.data(using: .utf8)!
        let params = try JSONDecoder().decode(LookParameters.self, from: json)
        XCTAssertEqual(params.warmth, 0.3)
        XCTAssertEqual(params.grainSize, 1)
        XCTAssertEqual(params.highlightsTint, [1, 1, 1])
        XCTAssertFalse(params.monochrome)
    }
}
