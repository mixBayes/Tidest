import XCTest

final class MultiWindowLayoutUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testFourStartingCardsAndBlankEditor() {
        let app = launch()
        XCTAssertEqual(regions(app).count, 2)
        app.buttons["multiLayoutLayouts"].click()
        let starts = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "multiLayoutStart-"))
        XCTAssertEqual(starts.count, 4)
        XCTAssertFalse(app.buttons["multiLayoutApply"].isEnabled)
        app.buttons["multiLayoutBlank"].click()
        XCTAssertEqual(regions(app).count, 1)
        revealSplit(region: 0, edge: "left", in: app).click()
        XCTAssertEqual(regions(app).count, 2)
        revealSplit(region: 0, edge: "bottom", in: app).click()
        XCTAssertEqual(regions(app).count, 3)
        moreAction("multiLayoutMerge", in: app)
        XCTAssertEqual(regions(app).count, 2)
        moreAction("multiLayoutUndoDraft", in: app)
        XCTAssertEqual(regions(app).count, 3)
    }

    @MainActor
    func testHoverMovesControlsInsteadOfKeepingThemOnTheClickedRegion() {
        let app = launch()
        let left = app.buttons["multiLayoutRegion-0"]
        let right = app.buttons["multiLayoutRegion-1"]
        left.hover()
        XCTAssertTrue(app.buttons["multiLayoutDelete-0"].waitForExistence(timeout: 2))
        XCTAssertEqual(splitButtons(app).count, 0)
        XCTAssertTrue(revealSplit(region: 0, edge: "left", in: app).isHittable)
        left.click()
        XCTAssertTrue(app.textFields["multiLayoutWindowSearch"].waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])
        right.hover()
        XCTAssertTrue(app.buttons["multiLayoutDelete-1"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["multiLayoutDelete-0"].exists)
        XCTAssertFalse(app.buttons["multiLayoutSplit-0-left"].exists)
        XCTAssertEqual(splitButtons(app).count, 0)
        keepScreenshot("edge-guides-buttons-hidden", in: app)
    }

    @MainActor
    func testOnlyNearbyEdgeButtonAppearsAndRetractsWhenLeaving() {
        let app = launch()
        for edge in ["left", "top", "right", "bottom"] {
            let button = revealSplit(region: 1, edge: edge, in: app)
            XCTAssertEqual(splitButtons(app).count, 1)
            XCTAssertTrue(button.isHittable)
            if edge == "left" {
                keepScreenshot("rounded-button-nearby", in: app)
                button.hover()
                XCTAssertTrue(button.exists)
                keepScreenshot("rounded-button-highlighted", in: app)
            }
            app.buttons["multiLayoutRegion-1"].hover()
            XCTAssertEqual(splitButtons(app).count, 0)
        }
    }

    @MainActor
    func testDeletePreservesOtherWindowAndUndoRestoresBothRegions() {
        let app = launch()
        assign(region: 0, windowIndex: 0, in: app)
        assign(region: 1, windowIndex: 1, in: app)
        app.buttons["multiLayoutRegion-0"].hover()
        let delete = app.buttons["multiLayoutDelete-0"]
        let card = app.descendants(matching: .any)["multiLayoutCard-0"].firstMatch
        XCTAssertTrue(card.frame.contains(delete.frame), "Delete must stay inside the central card")
        delete.click()
        XCTAssertEqual(regions(app).count, 1)
        XCTAssertFalse(app.textFields["multiLayoutWindowSearch"].exists)
        XCTAssertTrue(app.buttons["multiLayoutRegion-0"].label.contains("示例窗口 2"))
        XCTAssertTrue(app.buttons["multiLayoutApply"].isEnabled)
        app.buttons["multiLayoutRegion-0"].hover()
        XCTAssertFalse(app.buttons["multiLayoutDelete-0"].exists)
        moreAction("multiLayoutUndoDraft", in: app)
        XCTAssertEqual(regions(app).count, 2)
        XCTAssertTrue(app.buttons["multiLayoutRegion-0"].label.contains("示例窗口 1"))
        XCTAssertTrue(app.buttons["multiLayoutRegion-1"].label.contains("示例窗口 2"))
        XCTAssertTrue(app.buttons["multiLayoutApply"].isEnabled)
    }

    @MainActor
    func testSharedEdgeButtonSplitsOnlyItsHoveredRegion() {
        let app = launch()
        let originalLeft = app.buttons["multiLayoutRegion-0"].frame
        let originalRight = app.buttons["multiLayoutRegion-1"].frame
        revealSplit(region: 1, edge: "left", in: app).click()
        XCTAssertEqual(regions(app).count, 3)
        XCTAssertEqual(app.buttons["multiLayoutRegion-0"].frame, originalLeft)
        let middle = app.buttons["multiLayoutRegion-1"].frame
        let right = app.buttons["multiLayoutRegion-2"].frame
        XCTAssertEqual(middle.minX, originalRight.minX, accuracy: 1)
        XCTAssertEqual(middle.maxX, right.minX, accuracy: 1)
        XCTAssertEqual(right.maxX, originalRight.maxX, accuracy: 1)
        XCTAssertFalse(app.textFields["multiLayoutWindowSearch"].exists)
    }

    @MainActor
    func testDraggingDividerKeepsRegionsTiled() {
        let app = launch()
        let left = app.buttons["multiLayoutRegion-0"]
        let right = app.buttons["multiLayoutRegion-1"]
        let originalLeft = left.frame
        let originalRight = right.frame
        let start = left.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.7))
        let end = start.withOffset(CGVector(dx: -originalLeft.width * 0.3, dy: 0))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertLessThan(left.frame.width, originalLeft.width - 30)
        XCTAssertEqual(left.frame.minX, originalLeft.minX, accuracy: 1)
        XCTAssertEqual(left.frame.maxX, right.frame.minX, accuracy: 1)
        XCTAssertEqual(right.frame.maxX, originalRight.maxX, accuracy: 1)
        XCTAssertEqual(left.frame.height, originalLeft.height, accuracy: 1)
        XCTAssertEqual(right.frame.height, originalRight.height, accuracy: 1)
    }

    @MainActor
    func testSearchEnterOnlyChoosesWindowAndEscapeReturnsBeforeCancelling() {
        let app = launch()
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
    func testSearchResultsKeepTheirWindowNamesAndClickTargets() {
        let app = launch()
        app.buttons["multiLayoutRegion-0"].click()
        let search = app.textFields["multiLayoutWindowSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 2))
        search.click()
        search.typeText("示例窗口 2")
        let result = app.buttons["multiLayoutWindow-0"]
        XCTAssertTrue(result.label.contains("示例窗口 2"), result.label)
        search.typeKey("a", modifierFlags: .command)
        search.typeText("示例窗口 3")
        XCTAssertTrue(result.label.contains("示例窗口 3"), result.label)
        result.click()
        XCTAssertFalse(search.exists)
        XCTAssertTrue(app.buttons["multiLayoutRegion-0"].label.contains("示例窗口 3"))
    }

    @MainActor
    func testFinalWindowReturnCannotApplyWithoutASeparateConfirmation() {
        let app = launch()
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
        assign(region: 0, windowIndex: 0, in: app)
        app.buttons["multiLayoutRegion-1"].click()
        XCTAssertTrue(app.buttons["multiLayoutWindow-0"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["multiLayoutWindow-0"].isEnabled)
        XCTAssertTrue(app.buttons["multiLayoutWindow-0"].label.contains("已分配到区域 1"))
    }

    @MainActor
    func testTemplateNamingReturnDoesNotApplyAndSavedTemplateContainsNoAssignments() {
        let app = launch()
        assign(region: 0, windowIndex: 0, in: app)
        moreAction("multiLayoutSaveTemplate", in: app)
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
        assign(region: 0, windowIndex: 0, in: app)
        assign(region: 1, windowIndex: 1, in: app)
        app.buttons["multiLayoutApply"].click()
        XCTAssertTrue(app.buttons["multiLayoutRetry"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["已排列"].exists)
        XCTAssertTrue(app.staticTexts["窗口尺寸受限，请调整区域后重试。"].exists)
        app.buttons["multiLayoutRetry"].click()
        XCTAssertFalse(app.buttons["multiLayoutApply"].waitForExistence(timeout: 1))
    }

    @MainActor
    private func revealSplit(region: Int, edge: String, in app: XCUIApplication) -> XCUIElement {
        let cell = app.buttons["multiLayoutRegion-\(region)"]
        let anchor: CGVector
        let inset: CGVector
        switch edge {
        case "left": anchor = CGVector(dx: 0, dy: 0.5); inset = CGVector(dx: 36, dy: 0)
        case "right": anchor = CGVector(dx: 1, dy: 0.5); inset = CGVector(dx: -36, dy: 0)
        case "top": anchor = CGVector(dx: 0.5, dy: 0); inset = CGVector(dx: 0, dy: 36)
        default: anchor = CGVector(dx: 0.5, dy: 1); inset = CGVector(dx: 0, dy: -36)
        }
        cell.coordinate(withNormalizedOffset: anchor).withOffset(inset).hover()
        let button = app.buttons["multiLayoutSplit-\(region)-\(edge)"]
        XCTAssertTrue(button.waitForExistence(timeout: 2))
        return button
    }

    @MainActor
    private func splitButtons(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "multiLayoutSplit-"))
    }

    @MainActor
    private func keepScreenshot(_ name: String, in app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func launch(partial: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-multi-layout", "--ui-preview-language=zh-Hans"]
        if partial { app.launchArguments.append("--ui-preview-multi-layout-partial") }
        app.launch()
        app.activate()
        let appeared = app.buttons["multiLayoutRegion-0"].waitForExistence(timeout: 5)
        if !appeared {
            print(app.debugDescription)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertTrue(appeared)
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
    private func moreAction(_ identifier: String, in app: XCUIApplication) {
        app.menuButtons["multiLayoutMore"].click()
        app.menuItems[identifier].click()
    }

    @MainActor
    private func regions(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "multiLayoutRegion-"))
    }
}
