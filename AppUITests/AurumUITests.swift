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
        let create = app.buttons["tab.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5), "No Create tab. Screen:\n\(app.debugDescription)")
        create.tap()
        let cell = app.buttons["picker.cell.0"]
        XCTAssertTrue(cell.waitForExistence(timeout: 3), "No picker cell. Screen:\n\(app.debugDescription)")
        cell.tap()
        let export = app.buttons["studio.export"]
        XCTAssertTrue(export.waitForExistence(timeout: 3), "No Studio export button. Screen:\n\(app.debugDescription)")
        // A free look is already suggested, so exporting is allowed straight away.
        export.tap()
        let save = app.buttons["export.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 3), "No export save button. Screen:\n\(app.debugDescription)")
        save.tap()
        XCTAssertTrue(app.staticTexts["Saved to Photos"].waitForExistence(timeout: 6), "Not saved. Screen:\n\(app.debugDescription)")
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }
}
