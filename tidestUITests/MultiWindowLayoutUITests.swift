import XCTest

final class MultiWindowLayoutUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testFourStartingCardsAndBlankEditor() {
        let app = launch()
        let starts = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "multiLayoutStart-"))
        XCTAssertEqual(starts.count, 4)
        XCTAssertFalse(app.buttons["multiLayoutApply"].isEnabled)
        app.buttons["multiLayoutBlank"].click()
        XCTAssertEqual(regions(app).count, 1)
        app.buttons["multiLayoutSplitColumns"].click()
        XCTAssertEqual(regions(app).count, 2)
        app.buttons["multiLayoutSplitRows"].click()
        XCTAssertEqual(regions(app).count, 3)
        app.buttons["multiLayoutMerge"].click()
        XCTAssertEqual(regions(app).count, 2)
        app.buttons["multiLayoutUndoDraft"].click()
        XCTAssertEqual(regions(app).count, 3)
    }

    @MainActor
    func testSearchEnterOnlyChoosesWindowAndEscapeReturnsBeforeCancelling() {
        let app = launch()
        app.buttons["multiLayoutStart-columns"].click()
        app.buttons["multiLayoutRegion-0"].click()
        let search = app.textFields["multiLayoutWindowSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 2))
        search.click()
        search.typeText("Finder")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(search.exists)
        XCTAssertTrue(app.buttons["multiLayoutRegion-0"].exists)
        XCTAssertFalse(app.buttons["multiLayoutApply"].isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["multiLayoutResults"].firstMatch.exists)
        app.buttons["multiLayoutRegion-1"].click()
        XCTAssertTrue(app.textFields["multiLayoutWindowSearch"].waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.textFields["multiLayoutWindowSearch"].exists)
        XCTAssertTrue(app.buttons["multiLayoutApply"].exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.buttons["multiLayoutApply"].waitForExistence(timeout: 1))
    }

    @MainActor
    func testFinalWindowReturnCannotApplyWithoutASeparateConfirmation() {
        let app = launch()
        app.buttons["multiLayoutStart-columns"].click()
        assign(region: 0, windowIndex: 0, in: app)
        assign(region: 1, windowIndex: 1, in: app, keyboard: true)
        XCTAssertTrue(app.buttons["multiLayoutApply"].isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["multiLayoutResults"].firstMatch.exists)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["multiLayoutConfirming"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["multiLayoutApply"].exists)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(app.buttons["multiLayoutApply"].waitForExistence(timeout: 1))
    }

    @MainActor
    func testOccupiedWindowIsMarkedAndCannotBeAssignedTwice() {
        let app = launch()
        app.buttons["multiLayoutStart-columns"].click()
        assign(region: 0, windowIndex: 0, in: app)
        app.buttons["multiLayoutRegion-1"].click()
        XCTAssertTrue(app.buttons["multiLayoutWindow-0"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["multiLayoutWindow-0"].isEnabled)
        XCTAssertTrue(app.staticTexts["已分配到区域 1"].exists)
    }

    @MainActor
    func testTemplateNamingReturnDoesNotApplyAndSavedTemplateContainsNoAssignments() {
        let app = launch()
        app.buttons["multiLayoutStart-columns"].click()
        assign(region: 0, windowIndex: 0, in: app)
        app.buttons["multiLayoutSaveTemplate"].click()
        let name = app.textFields["multiLayoutTemplateName"]
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        name.click()
        name.typeText("Test layout")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["multiLayoutApply"].exists)
        XCTAssertFalse(app.buttons["multiLayoutApply"].isEnabled)
        app.buttons["multiLayoutConfirmSaveTemplate"].click()
        XCTAssertFalse(name.waitForExistence(timeout: 1))
        XCTAssertTrue(app.buttons["multiLayoutRegion-0"].exists)
    }

    @MainActor
    func testPartialFailureShowsPerWindowResultsAndOnlyFailedWindowCanRetry() {
        let app = launch(partial: true)
        app.buttons["multiLayoutStart-columns"].click()
        assign(region: 0, windowIndex: 0, in: app)
        assign(region: 1, windowIndex: 1, in: app)
        app.buttons["multiLayoutApply"].click()
        XCTAssertTrue(app.buttons["multiLayoutRetry"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["已排列"].exists)
        XCTAssertTrue(app.staticTexts["窗口尺寸受限，请调整区域后重试。"].exists)
        XCTAssertTrue(app.buttons["multiLayoutUndoApplication"].isEnabled)
        app.buttons["multiLayoutRetry"].click()
        XCTAssertFalse(app.buttons["multiLayoutApply"].waitForExistence(timeout: 1))
    }

    @MainActor
    private func launch(partial: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-multi-layout", "--ui-preview-language=zh-Hans"]
        if partial { app.launchArguments.append("--ui-preview-multi-layout-partial") }
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["multiLayoutBlank"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func assign(region: Int, windowIndex: Int, in app: XCUIApplication, keyboard: Bool = false) {
        app.buttons["multiLayoutRegion-\(region)"].click()
        let choice = app.buttons["multiLayoutWindow-\(windowIndex)"]
        XCTAssertTrue(choice.waitForExistence(timeout: 2))
        if keyboard {
            for _ in 0..<8 {
                if choice.isSelected { break }
                app.typeKey(.downArrow, modifierFlags: [])
            }
            app.typeKey(.return, modifierFlags: [])
        } else { choice.click() }
        XCTAssertFalse(app.textFields["multiLayoutWindowSearch"].waitForExistence(timeout: 1))
    }

    @MainActor
    private func regions(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "multiLayoutRegion-"))
    }
}
