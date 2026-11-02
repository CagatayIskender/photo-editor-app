import XCTest

/// The core promise: import, apply a look and export in under ten seconds.
final class AurumUITests: XCTestCase {
    func testImportApplyExportUnderTenSeconds() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTesting"]
        app.launch()

        // Onboarding: three taps.
        for _ in 0..<3 {
            let button = app.buttons["onboarding.primary"]
            if button.waitForExistence(timeout: 2) { button.tap() }
        }

        let start = Date()
        app.buttons["tab.create"].tap()
        let cell = app.buttons["picker.cell.0"]
        XCTAssertTrue(cell.waitForExistence(timeout: 3))
        cell.tap()
        let export = app.buttons["studio.export"]
        XCTAssertTrue(export.waitForExistence(timeout: 3))
        // A free look is already suggested, so exporting is allowed straight away.
        export.tap()
        let save = app.buttons["export.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        save.tap()
        XCTAssertTrue(app.staticTexts["Saved to Photos"].waitForExistence(timeout: 6))
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }
}
