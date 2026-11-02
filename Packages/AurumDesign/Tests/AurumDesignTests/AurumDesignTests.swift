import XCTest
import SwiftUI
import UIKit
@testable import AurumDesign

final class AurumDesignTests: XCTestCase {
    func testHexColourParsing() {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(Color(hex: "#C9A86A")).getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 201 / 255, accuracy: 0.01)
        XCTAssertEqual(g, 168 / 255, accuracy: 0.01)
        XCTAssertEqual(b, 106 / 255, accuracy: 0.01)
        XCTAssertEqual(a, 1, accuracy: 0.01)

        UIColor(Color(hex: "0B0B0C80")).getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(a, 128 / 255, accuracy: 0.01)
    }

    func testInvalidHexIsLoudMagenta() {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(Color(hex: "#nope")).getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 1, accuracy: 0.01)
        XCTAssertEqual(g, 0, accuracy: 0.01)
        XCTAssertEqual(b, 1, accuracy: 0.01)
    }

    func testBrandFallsBackToDefaults() {
        XCTAssertEqual(Brand.load(from: Bundle(for: Self.self)), .default)
    }

    func testBrandJSONMatchesDefaults() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Brand/brand.json")
        let brand = try JSONDecoder().decode(Brand.self, from: Data(contentsOf: url))
        XCTAssertEqual(brand, .default, "Brand.default must mirror Brand/brand.json")
    }

    func testEveryIconDrawsSomething() {
        for icon in AurumIcon.allCases {
            let path = icon.path(in: CGRect(x: 0, y: 0, width: 24, height: 24))
            XCTAssertFalse(path.isEmpty, icon.rawValue)
            XCTAssertTrue(CGRect(x: -1, y: -1, width: 26, height: 26).contains(path.boundingRect), "\(icon) leaves the 24 pt grid")
        }
    }

    func testContrastOfTextTokens() {
        // WCAG relative luminance contrast against the onyx background.
        func luminance(_ hex: String) -> Double {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(Color(hex: hex)).getRed(&r, green: &g, blue: &b, alpha: &a)
            func lin(_ c: CGFloat) -> Double {
                let c = Double(c)
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }
        let bg = luminance(Brand.default.colors.onyx)
        for hex in [Brand.default.colors.ivory, Brand.default.colors.ivoryDim, Brand.default.colors.stone, Brand.default.colors.champagne] {
            let ratio = (luminance(hex) + 0.05) / (bg + 0.05)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, hex)
        }
    }
}
