import XCTest

final class AboutUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testDownloadWaitsForConfirmationAndLaterKeepsRestartAvailable() {
        let app = launchAbout(outcome: "available")
        XCTAssertTrue(app.dialogs["updatePrompt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Tidest 2.0.9 已可下载，是否现在下载？"].exists)
        app.dialogs["updatePrompt"].buttons["稍后"].click()
        XCTAssertEqual(status(app), "发现新版本 2.0.9")
        XCTAssertTrue(app.buttons["downloadUpdate"].exists)
        app.buttons["downloadUpdate"].click()
        XCTAssertTrue(app.buttons["cancelUpdateDownload"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.progressIndicators["updateDownloadProgress"].exists)
        saveScreenshot(app, name: "关于 · 应用内下载")
        XCTAssertTrue(app.dialogs["updateReadyPrompt"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.dialogs["updateReadyPrompt"].buttons["重启并更新"].exists)
        saveScreenshot(app, name: "更新 · 重启确认")
        app.dialogs["updateReadyPrompt"].buttons["稍后"].click()
        XCTAssertTrue(app.buttons["restartAndUpdate"].exists)
        XCTAssertFalse(app.buttons["downloadUpdate"].exists)
        saveScreenshot(app, name: "关于 · 稍后仍可重启更新")
        app.buttons["restartAndUpdate"].click()
        XCTAssertEqual(status(app), "正在重启并更新…")
    }

    @MainActor
    func testClosingAboutDuringDownloadKeepsProgressAndAllowsCancellation() {
        let app = launchAbout(outcome: "downloading")
        XCTAssertTrue(app.dialogs["updatePrompt"].waitForExistence(timeout: 5))
        app.dialogs["updatePrompt"].buttons["下载"].click()
        XCTAssertTrue(app.buttons["cancelUpdateDownload"].waitForExistence(timeout: 2))
        app.windows["关于 Tidest"].buttons[XCUIIdentifierCloseWindow].click()
        openAboutFromMenu(app)
        XCTAssertTrue(app.buttons["cancelUpdateDownload"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.dialogs["updatePrompt"].exists)
        app.buttons["cancelUpdateDownload"].click()
        XCTAssertFalse(app.buttons["cancelUpdateDownload"].exists)
        XCTAssertFalse(app.progressIndicators["updateDownloadProgress"].exists)
        XCTAssertTrue(app.buttons["checkForUpdates"].isEnabled)
    }

    @MainActor
    func testCheckingShowsSpinnerAndDisablesRepeatedChecks() {
        let app = launchAbout(outcome: "checking")
        XCTAssertTrue(app.activityIndicators["updateProgress"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["checkForUpdates"].isEnabled)
        XCTAssertFalse(app.buttons["downloadUpdate"].exists)
        saveScreenshot(app, name: "关于 · 正在检查")
    }

    @MainActor
    func testFailedCheckStaysInAboutAndAllowsRetry() {
        let app = launchAbout(outcome: "failed")
        let failed = NSPredicate { _, _ in self.status(app) == "暂时无法检查更新，请稍后重试。" }
        expectation(for: failed, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["checkForUpdates"].isEnabled)
        XCTAssertFalse(app.buttons["downloadUpdate"].exists)
        app.buttons["checkForUpdates"].click()
        XCTAssertTrue(app.activityIndicators["updateProgress"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testFailedDownloadReturnsToAboutAndAllowsAnotherCheck() {
        let app = launchAbout(outcome: "download-failed")
        XCTAssertTrue(app.dialogs["updatePrompt"].waitForExistence(timeout: 5))
        app.dialogs["updatePrompt"].buttons["下载"].click()
        let failed = NSPredicate { _, _ in self.status(app) == "更新未完成，请稍后重试。你可以继续使用当前版本。" }
        expectation(for: failed, evaluatedWith: nil)
        waitForExpectations(timeout: 8)
        XCTAssertFalse(app.dialogs["updatePrompt"].exists)
        XCTAssertTrue(app.buttons["checkForUpdates"].isEnabled)
        XCTAssertTrue(app.windows["关于 Tidest"].isHittable)
    }

    @MainActor
    func testMenuReopeningAboutKeepsTheAvailableUpdate() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-settings", "--ui-preview-language=zh-Hans", "--ui-preview-update=available"]
        app.launch()
        XCTAssertTrue(app.windows["设置"].waitForExistence(timeout: 5))
        app.windows["设置"].buttons[XCUIIdentifierCloseWindow].click()
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()

        openAboutFromMenu(app)
        XCTAssertTrue(app.windows["关于 Tidest"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.dialogs["updatePrompt"].waitForExistence(timeout: 5))
        app.dialogs["updatePrompt"].buttons["稍后"].click()
        app.windows["关于 Tidest"].buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertFalse(app.windows["关于 Tidest"].exists)

        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        openAboutFromMenu(app)
        XCTAssertTrue(app.windows["关于 Tidest"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["downloadUpdate"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.dialogs["updatePrompt"].exists, "Reopening must preserve the pending update")
        saveScreenshot(app, name: "关于 · 从菜单首次打开与重开")
    }

    @MainActor
    func testAboutMenuWorksWhilePermissionGuideIsOpen() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-accessibility", "--ui-preview-language=zh-Hans", "--ui-preview-update=available"]
        app.launch()
        XCTAssertTrue(app.buttons["grantAccessibility"].waitForExistence(timeout: 5))

        openAboutFromMenu(app)
        XCTAssertTrue(app.windows["关于 Tidest"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.dialogs["updatePrompt"].waitForExistence(timeout: 5))
        app.dialogs["updatePrompt"].buttons["稍后"].click()
        XCTAssertTrue(app.windows["关于 Tidest"].isHittable)
    }

    @MainActor
    private func launchAbout(outcome: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-about", "--ui-preview-language=zh-Hans", "--ui-preview-update=\(outcome)"]
        app.launch()
        XCTAssertTrue(app.windows["关于 Tidest"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func openAboutFromMenu(_ app: XCUIApplication) {
        // Activate before opening the menu. XCTest otherwise activates while
        // clicking the menu item, which closes a menu opened by an inactive app.
        app.activate()
        let icon = app.descendants(matching: .any)["tidestMenuBarIcon"]
        XCTAssertTrue(icon.waitForExistence(timeout: 3), app.debugDescription)
        icon.click()
        let about = app.menuItems["showAbout"]
        XCTAssertTrue(about.waitForExistence(timeout: 3), app.debugDescription)
        about.click()
    }

    @MainActor
    private func status(_ app: XCUIApplication) -> String {
        app.staticTexts["updateStatus"].value as? String ?? ""
    }

    @MainActor
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        app.activate()
        let target: XCUIElement
        if app.dialogs["updateReadyPrompt"].exists {
            target = app.dialogs["updateReadyPrompt"]
        } else if app.dialogs["updatePrompt"].exists {
            target = app.dialogs["updatePrompt"]
        } else {
            target = app.windows["关于 Tidest"]
        }
        let attachment = XCTAttachment(screenshot: target.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if target.elementType == .dialog {
            let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screen.name = name + " · 屏幕位置"
            screen.lifetime = .keepAlways
            add(screen)
        }
    }
}
