import XCTest

@MainActor
final class FitnessExportUITests: XCTestCase {
    func testIndexRefreshSelectionAndAnalysisFlow() {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-mock-empty-index", "-app.language", "it"]
        app.launch()
        app.openLibraryTab()

        XCTAssertTrue(app.buttons["index.refresh.button"].waitForExistence(timeout: 2))
        app.buttons["index.refresh.button"].tap()

        let runningChip = app.buttons["activity.running.chip"]
        XCTAssertTrue(runningChip.waitForExistence(timeout: 2))

        let selectVisibleButton = app.buttons["selection.selectVisible.button"]
        let selectionReady = expectation(
            for: NSPredicate(format: "isEnabled == true"), evaluatedWith: selectVisibleButton)
        wait(for: [selectionReady], timeout: 3)
        selectVisibleButton.tap()

        let analyzeButton = app.buttons["analyze.button"]
        let enabledExpectation = expectation(
            for: NSPredicate(format: "isEnabled == true"), evaluatedWith: analyzeButton)
        wait(for: [enabledExpectation], timeout: 2)
        analyzeButton.tap()

        let regenerateButton = app.buttons["analysis.regenerate.button"]
        XCTAssertTrue(regenerateButton.waitForExistence(timeout: 3))
        regenerateButton.tap()

        let copyButton = app.buttons["analysis.copy.button"]
        XCTAssertTrue(copyButton.waitForExistence(timeout: 3))
        copyButton.tap()

        XCTAssertTrue(app.staticTexts["analysis.copied.label"].waitForExistence(timeout: 2))

        let exportButton = app.buttons["analysis.exportFit.button"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 2))
        exportButton.tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10))
    }
}

extension XCUIApplication {

    func openLibraryTab() {
        let tab = tabBars.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Archivio", "Library"))
            .firstMatch
        if tab.waitForExistence(timeout: 5) {
            tab.tap()
        }
    }
}
