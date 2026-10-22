import XCTest

final class AboutUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testAutomaticCheckShowsVersionAndWaitsForDownloadConfirmation() {
        let app = launchAbout(outcome: "available")
        XCTAssertTrue(app.dialogs["updatePrompt"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.windows["关于 Tidest"].sheets.firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Tidest 2.0.4 已可下载，是否现在下载？"].exists)
        XCTAssertFalse(status(app).contains("已在浏览器中打开"))

        app.dialogs["updatePrompt"].buttons["稍后"].click()
        XCTAssertEqual(status(app), "发现新版本 2.0.4")
        XCTAssertFalse(app.dialogs["updatePrompt"].exists)

        app.buttons["checkForUpdates"].click()
        XCTAssertTrue(app.dialogs["updatePrompt"].waitForExistence(timeout: 5))
        saveScreenshot(app, name: "更新 · 独立下载确认窗口")
        app.dialogs["updatePrompt"].buttons["下载"].click()
        XCTAssertEqual(status(app), "已在浏览器中打开 2.0.4 的下载链接。")
        XCTAssertFalse(app.dialogs["updatePrompt"].exists)
        saveScreenshot(app, name: "关于 · 确认后打开下载")
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
        XCTAssertEqual(status(app), "无法打开下载链接，请稍后重试。")
        XCTAssertFalse(app.dialogs["updatePrompt"].exists)
        XCTAssertTrue(app.buttons["checkForUpdates"].isEnabled)
        XCTAssertTrue(app.windows["关于 Tidest"].isHittable)
    }

    @MainActor
    func testMenuOpensAboutOnFirstClickAndChecksAgainAfterClosing() {
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
        XCTAssertTrue(app.dialogs["updatePrompt"].waitForExistence(timeout: 5), "Reopening About must check again")
        app.dialogs["updatePrompt"].buttons["稍后"].click()
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
        let target = app.dialogs["updatePrompt"].exists ? app.dialogs["updatePrompt"] : app.windows["关于 Tidest"]
        if target.elementType == .dialog {
            target.buttons["下载"].hover()
        } else {
            app.buttons["checkForUpdates"].hover()
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
