import XCTest

@MainActor
final class ScreenshotTests: XCTestCase {
    func testCaptureMainScreens() throws {
        guard let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !directory.isEmpty else {
            throw XCTSkip("SCREENSHOT_DIR non impostata")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-app.language", "it"]
        app.launch()

        save(app, "training", in: directory)
        app.openLibraryTab()

        XCTAssertTrue(app.buttons["selection.selectVisible.button"].waitForExistence(timeout: 5))
        save(app, "library", in: directory)

        app.buttons["selection.selectVisible.button"].tap()
        save(app, "library-selected", in: directory)

        let detailButton = app.buttons["workout.detail.button"].firstMatch
        XCTAssertTrue(detailButton.waitForExistence(timeout: 3))
        detailButton.tap()
        XCTAssertTrue(app.staticTexts["Passo per km"].waitForExistence(timeout: 5))
        save(app, "detail", in: directory)
        app.swipeUp()
        save(app, "detail-2", in: directory)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let intervalsButton = app.buttons.matching(identifier: "workout.detail.button").element(boundBy: 1)
        XCTAssertTrue(intervalsButton.waitForExistence(timeout: 3))
        intervalsButton.tap()
        XCTAssertTrue(app.staticTexts["Intervalli"].waitForExistence(timeout: 5))
        save(app, "detail-intervals", in: directory)
        app.swipeUp()
        save(app, "detail-intervals-2", in: directory)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(app.buttons["trends.button"].waitForExistence(timeout: 3))
        app.buttons["trends.button"].tap()
        XCTAssertTrue(app.staticTexts["Volume"].waitForExistence(timeout: 5))
        sleep(2)
        save(app, "trends", in: directory)
        app.swipeUp()
        save(app, "trends-2", in: directory)
        app.swipeUp()
        save(app, "trends-3", in: directory)
        app.buttons["Tutto"].tap()
        sleep(2)
        app.swipeDown()
        app.swipeDown()
        save(app, "trends-all", in: directory)
        app.swipeUp()
        save(app, "trends-all-2", in: directory)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(app.buttons["analyze.button"].waitForExistence(timeout: 3))
        app.buttons["analyze.button"].tap()
        XCTAssertTrue(app.buttons["analysis.regenerate.button"].waitForExistence(timeout: 5))
        sleep(1)
        save(app, "analysis", in: directory)
        app.buttons["Chiudi"].tap()

        XCTAssertTrue(app.buttons["settings.button"].waitForExistence(timeout: 3))
        app.buttons["settings.button"].tap()
        XCTAssertTrue(app.buttons["Fine"].waitForExistence(timeout: 3))
        save(app, "settings", in: directory)
        app.buttons["Fine"].tap()
    }

    private func save(_ app: XCUIApplication, _ name: String, in directory: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        do {
            try data.write(to: url)
        } catch {
            XCTFail("Impossibile salvare \(name): \(error)")
        }
    }
}
