import XCTest

@MainActor
final class LanguageUITests: XCTestCase {
    func testEnglishScreens() { check(language: "en", library: "Library", settings: "Settings", done: "Done") }
    func testItalianScreens() { check(language: "it", library: "Archivio", settings: "Impostazioni", done: "Fine") }

    func testLanguageSelectionPersistsAcrossLaunches() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        app.openLibraryTab()
        app.buttons["settings.button"].tap()
        app.buttons["settings.language"].tap()
        app.buttons["Italiano"].tap()
        XCTAssertTrue(app.navigationBars["Impostazioni"].waitForExistence(timeout: 5))
        app.buttons["settings.language"].tap()
        app.buttons["English"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 10))
        app.terminate()
    }

    private func check(language: String, library: String, settings: String, done: String) {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-app.language", language]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons[library].waitForExistence(timeout: 10))
        attach("training-\(language)")
        app.tabBars.buttons[library].tap()
        XCTAssertTrue(app.buttons["settings.button"].waitForExistence(timeout: 5))
        attach("library-\(language)")
        app.buttons["settings.button"].tap()
        XCTAssertTrue(app.navigationBars[settings].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[done].exists)
        attach("settings-\(language)")
        app.swipeUp()
        attach("settings-scroll-\(language)")
        app.buttons[done].tap()
        XCTAssertTrue(app.buttons["trends.button"].waitForExistence(timeout: 5))
        app.buttons["trends.button"].tap()
        attach("trends-\(language)")
        app.terminate()
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
