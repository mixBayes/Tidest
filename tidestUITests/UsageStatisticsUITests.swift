import XCTest

final class UsageStatisticsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testEmptyStatistics() {
        let app = launchStatistics()
        defer { app.terminate() }
        XCTAssertEqual(app.staticTexts["statisticsToday"].value as? String, "0")
        XCTAssertEqual(app.staticTexts["statisticsTotal"].value as? String, "0")
        XCTAssertTrue(app.staticTexts["最近 7 天"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["statisticsChart"].exists)
        saveScreenshot(app, name: "statistics-empty")
        app.buttons["statisticsExplanation"].click()
        XCTAssertTrue(app.descendants(matching: .any)["statisticsExplanationPanel"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["取消、失败或只打开面板，不计入次数。"].exists)
        saveScreenshot(app, name: "statistics-explanation")
    }

    @MainActor
    func testDarkStatistics() {
        let app = launchStatistics(sample: true, dark: true)
        defer { app.terminate() }
        XCTAssertEqual(app.staticTexts["statisticsToday"].value as? String, "21")
        saveScreenshot(app, name: "statistics-dark")
    }

    @MainActor
    func testSampleCountsAndEverySupportedLanguageFitTheWindow() {
        for (language, title) in [("zh-Hans", "使用统计"), ("zh-Hant", "使用統計"),
                                  ("en", "Usage Statistics"), ("ja", "使用状況"), ("ko", "사용 통계")] {
            let app = launchStatistics(language: language, sample: true)
            defer { app.terminate() }
            XCTAssertTrue(app.windows[title].exists)
            XCTAssertEqual(app.staticTexts["statisticsToday"].value as? String, "21")
            XCTAssertEqual(app.staticTexts["statisticsTotal"].value as? String, "97")
            XCTAssertTrue(app.windows[title].frame.contains(app.staticTexts["statisticsSelectedDay"].frame))
            if language == "zh-Hans" {
                let chart = app.descendants(matching: .any)["statisticsChart"]
                chart.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).hover()
                let selected = app.staticTexts["statisticsSelectedDay"]
                expectation(for: NSPredicate { _, _ in
                    (selected.value as? String)?.contains("8 次") == true
                }, evaluatedWith: nil)
                waitForExpectations(timeout: 3)
            }
            saveScreenshot(app, name: "statistics-\(language)")
        }
    }

    @MainActor
    private func launchStatistics(language: String = "zh-Hans", sample: Bool = false, dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-statistics", "--ui-preview-language=\(language)"]
        if sample { app.launchArguments.append("--ui-preview-statistics-sample") }
        if dark { app.launchArguments.append("--ui-preview-dark") }
        app.launch()
        app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["usageStatisticsPanel"].waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        XCTAssertLessThanOrEqual(window.frame.height, 400)
        let explanation = app.buttons["statisticsExplanation"]
        XCTAssertTrue(explanation.exists)
        XCTAssertTrue(window.frame.contains(explanation.frame))
        XCTAssertLessThanOrEqual(window.frame.maxY - explanation.frame.maxY, 24)
        return app
    }

    @MainActor
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        app.activate()
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
