import XCTest

final class UpdateReminderUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testBackgroundReminderOpensAboutWithoutStartingDownloadAndBadgeRemains() {
        let app = launchBackground(reset: true)
        let tip = app.buttons["openUpdateFromReminder"]
        XCTAssertTrue(tip.waitForExistence(timeout: 5))
        XCTAssertFalse(app.windows["关于 Tidest"].exists)
        XCTAssertFalse(app.dialogs["updatePrompt"].exists)
        XCTAssertEqual(icon(app).label, "Tidest，有新版本")
        saveScreenshot(tip, name: "更新 · 每个版本一次的提示")
        tip.click()
        XCTAssertTrue(app.windows["关于 Tidest"].waitForExistence(timeout: 3))
        XCTAssertFalse(tip.exists)
        XCTAssertTrue(app.buttons["downloadUpdate"].exists)
        XCTAssertFalse(app.dialogs["updatePrompt"].exists)
        XCTAssertFalse(app.buttons["cancelUpdateDownload"].exists)
        XCTAssertEqual(icon(app).label, "Tidest，有新版本")
        app.activate()
        icon(app).click()
        let about = app.menuItems["showAbout"]
        XCTAssertTrue(about.waitForExistence(timeout: 3))
        XCTAssertTrue(about.label.contains("有新版本"))
        saveScreenshot(about, name: "菜单 · 关于后显示升级图标")
    }

    @MainActor
    func testSameVersionDoesNotShowReminderAfterRelaunchButNewVersionDoes() {
        let app = launchBackground(reset: true)
        XCTAssertTrue(app.buttons["openUpdateFromReminder"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = arguments(reset: false)
        app.launch()
        XCTAssertTrue(icon(app).waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["openUpdateFromReminder"].waitForExistence(timeout: 2))
        XCTAssertEqual(icon(app).label, "Tidest，有新版本")
        app.terminate()
        app.launchArguments = arguments(reset: false, outcome: "background-newer")
        app.launch()
        XCTAssertTrue(app.buttons["openUpdateFromReminder"].waitForExistence(timeout: 5))
        app.buttons["openUpdateFromReminder"].click()
        XCTAssertTrue(app.staticTexts["发现新版本 2.0.10"].exists)
    }

    @MainActor
    func testReminderDoesNotTakeFocusAndIconClickClosesItToOpenMenu() {
        let app = launchBackground(reset: true)
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(app.buttons["openUpdateFromReminder"].waitForExistence(timeout: 5))
        XCTAssertEqual(finder.state, .runningForeground)
        app.activate()
        icon(app).click()
        XCTAssertFalse(app.buttons["openUpdateFromReminder"].exists)
        XCTAssertTrue(app.menuItems["showAbout"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.windows["关于 Tidest"].exists)
        XCTAssertEqual(icon(app).label, "Tidest，有新版本")
        saveScreenshot(icon(app), name: "菜单栏 · 图标角落的升级标记")
    }

    @MainActor
    private func launchBackground(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments(reset: reset)
        app.launch()
        return app
    }

    private func arguments(reset: Bool, outcome: String = "background") -> [String] {
        var result = ["--ui-preview-update-reminder", "--ui-preview-language=zh-Hans", "--ui-preview-update=\(outcome)"]
        if reset { result.append("--ui-preview-reset-update-reminders") }
        return result
    }

    @MainActor
    private func icon(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["tidestMenuBarIcon"]
    }

    @MainActor
    private func saveScreenshot(_ target: XCUIElement, name: String) {
        let attachment = XCTAttachment(screenshot: target.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
