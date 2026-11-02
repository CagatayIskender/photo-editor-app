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
        var last = start
        var timings: [String] = []
        func mark(_ step: String) {
            let now = Date()
            let line = String(format: "%@ %.2fs (total %.2fs)", step, now.timeIntervalSince(last), now.timeIntervalSince(start))
            print("AURUM-TIMING " + line)
            timings.append(line)
            last = now
        }
        let create = app.buttons["tab.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5), "No Create tab. Screen:\n\(app.debugDescription)")
        create.tap()
        mark("create tab")
        let cell = app.buttons["picker.cell.0"]
        XCTAssertTrue(cell.waitForExistence(timeout: 3), "No picker cell. Screen:\n\(app.debugDescription)")
        mark("picker shown")
        cell.tap()
        let export = app.buttons["studio.export"]
        XCTAssertTrue(export.waitForExistence(timeout: 3), "No Studio export button. Screen:\n\(app.debugDescription)")
        mark("studio shown")
        // A free look is already suggested, so exporting is allowed straight away.
        export.tap()
        let save = app.buttons["export.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 3), "No export save button. Screen:\n\(app.debugDescription)")
        mark("export sheet shown")
        save.tap()
        XCTAssertTrue(app.staticTexts["Saved to Photos"].waitForExistence(timeout: 6), "Not saved. Screen:\n\(app.debugDescription)")
        mark("saved")
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "Steps: " + timings.joined(separator: "; "))
    }
}
