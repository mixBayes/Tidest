import XCTest

final class UsageGuideUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testTopicsManualStepsAndPlaybackControls() {
        let app = launchGuide(tiled: true)
        app.buttons["usagePlayback"].click()
        XCTAssertEqual(app.buttons["usagePlayback"].label, "继续播放")
        for topic in ["switching", "layout", "docking"] {
            app.buttons["usageTopic-\(topic)"].click()
            XCTAssertTrue(app.buttons["usageTopic-\(topic)"].isSelected)
            for step in 0..<3 {
                app.buttons["usageStep\(step)"].click()
                XCTAssertTrue(app.buttons["usageStep\(step)"].isSelected)
                XCTAssertEqual(app.buttons["usagePlayback"].label, "继续播放")
                saveScreenshot(app, name: "\(topic)-step\(step)")
            }
        }
        app.buttons["usageReplay"].click()
        XCTAssertTrue(app.buttons["usageStep0"].isSelected)
        XCTAssertEqual(app.buttons["usagePlayback"].label, "暂停")
        XCTAssertFalse(app.buttons["grantAccessibility"].exists)
        XCTAssertFalse(app.buttons["closePermissionGuide"].exists)
    }

    @MainActor
    func testAnimationAdvancesAndPauseKeepsTheSelectedStep() {
        let app = launchGuide()
        for topic in ["switching", "layout", "docking"] {
            app.buttons["usageTopic-\(topic)"].click()
            let completedStep = app.buttons["usageStep2"]
            expectation(for: NSPredicate { _, _ in completedStep.isSelected }, evaluatedWith: nil)
            waitForExpectations(timeout: 9)
            saveScreenshot(app, name: "\(topic)-autoplay-complete")
        }
        let secondStep = app.buttons["usageStep1"]
        app.buttons["usagePlayback"].click()
        app.buttons["usageStep1"].click()
        let nextStep = app.buttons["usageStep2"]
        let staysPaused = expectation(for: NSPredicate { _, _ in nextStep.isSelected }, evaluatedWith: nil)
        staysPaused.isInverted = true
        wait(for: [staysPaused], timeout: 3)
        XCTAssertTrue(secondStep.isSelected)
    }

    @MainActor
    func testScrubbingPausesAndResumesFromTheChosenPosition() {
        let app = launchGuide()
        let slider = app.sliders["usageProgress"]
        XCTAssertTrue(slider.exists)
        slider.adjust(toNormalizedSliderPosition: 0.45)
        XCTAssertEqual(app.buttons["usagePlayback"].label, "继续播放")
        XCTAssertTrue(app.buttons["usageStep1"].isSelected)
        XCTAssertEqual(progress(in: app), 45, accuracy: 3)

        slider.adjust(toNormalizedSliderPosition: 0.15)
        XCTAssertTrue(app.buttons["usageStep0"].isSelected)
        XCTAssertEqual(progress(in: app), 15, accuracy: 3)
        saveScreenshot(app, name: "scrub-backward")

        app.buttons["usagePlayback"].click()
        expectation(for: NSPredicate { _, _ in self.progress(in: app) > 22 }, evaluatedWith: nil)
        waitForExpectations(timeout: 4)
        slider.adjust(toNormalizedSliderPosition: 1)
        XCTAssertTrue(app.buttons["usageStep2"].isSelected)
        XCTAssertEqual(progress(in: app), 100, accuracy: 1)
        XCTAssertEqual(app.buttons["usagePlayback"].label, "继续播放")
        app.buttons["usageReplay"].click()
        XCTAssertLessThan(progress(in: app), 20)
        XCTAssertEqual(app.buttons["usagePlayback"].label, "暂停")
    }

    @MainActor
    func testLayoutCanBeScrubbedFromHiddenPanelThroughPlacement() {
        let app = launchGuide()
        app.buttons["usageTopic-layout"].click()
        let slider = app.sliders["usageProgress"]
        for (position, name) in [(0.0, "before-shortcut"), (0.2, "panel-open"),
                                 (0.5, "position-selected"), (0.71, "during-placement"),
                                 (1.0, "placement-complete")] {
            slider.adjust(toNormalizedSliderPosition: position)
            XCTAssertEqual(app.buttons["usagePlayback"].label, "继续播放")
            XCTAssertEqual(progress(in: app), position * 100, accuracy: 3)
            saveScreenshot(app, name: "layout-" + name)
        }
        app.buttons["usageTopic-switching"].click()
        XCTAssertEqual(app.buttons["usageStep1"].label, "2. 再按 Tab，快速切换窗口。")
        XCTAssertEqual(app.buttons["usageStep2"].label, "3. 松开按钮，将选中窗口置顶。")
    }

    @MainActor
    func testReducedMotionOffersManualStepsInEveryLanguage() {
        for language in ["zh-Hans", "zh-Hant", "en", "ja", "ko"] {
            let app = launchGuide(language: language, staticSteps: true)
            XCTAssertTrue(app.staticTexts["usageStaticSteps"].exists)
            XCTAssertFalse(app.buttons["usagePlayback"].exists)
            XCTAssertFalse(app.buttons["usageReplay"].exists)
            XCTAssertTrue(app.sliders["usageProgress"].exists)
            app.sliders["usageProgress"].adjust(toNormalizedSliderPosition: 0.5)
            XCTAssertTrue(app.buttons["usageStep1"].isSelected)
            for topic in ["switching", "layout", "docking"] {
                app.buttons["usageTopic-\(topic)"].click()
                for step in 0..<3 {
                    let button = app.buttons["usageStep\(step)"]
                    XCTAssertTrue(button.isHittable)
                    button.click()
                    XCTAssertTrue(button.isSelected)
                }
                saveScreenshot(app, name: "\(language)-\(topic)-static")
            }
            app.terminate()
        }
    }

    @MainActor
    private func progress(in app: XCUIApplication) -> Double {
        Double(app.sliders["usageProgress"].normalizedSliderPosition) * 100
    }

    @MainActor
    func testMenuOpensInstructionsWhilePermissionGuideIsOpen() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-accessibility", "--ui-preview-language=zh-Hans"]
        app.launch()
        XCTAssertTrue(app.buttons["grantAccessibility"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["tidestMenuBarIcon"].click()
        let menuItem = app.menuItems["showUsageGuide"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 3))
        menuItem.click()
        XCTAssertTrue(app.buttons["usageTopic-docking"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.windows["使用说明"].isHittable)
    }

    @MainActor
    private func launchGuide(language: String = "zh-Hans", staticSteps: Bool = false,
                             tiled: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-usage", "--ui-preview-language=\(language)"]
        if staticSteps { app.launchArguments.append("--ui-preview-usage-static") }
        if tiled { app.launchArguments.append("--ui-preview-tiled") }
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["usageTopic-switching"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "使用说明-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
