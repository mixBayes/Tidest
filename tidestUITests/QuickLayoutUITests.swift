import XCTest

final class QuickLayoutUITests: XCTestCase {
    @MainActor
    func testClickingATemplateCompletesPlacementAndClosesThePanel() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-layout", "--ui-preview-language=zh-Hans"]
        app.launch()
        let panel = app.descendants(matching: .any)["quickLayoutPanel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        app.buttons["quickLayout6"].click()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: 2),
                      "The placement highlight must disappear after the transition")
    }

    @MainActor
    func testNumberKeyCompletesPlacementAndRetainsTheSizeLimitTip() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-layout", "--ui-preview-layout-constrained", "--ui-preview-language=zh-Hans"]
        app.launch()
        let panel = app.descendants(matching: .any)["quickLayoutPanel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        app.typeKey("5", modifierFlags: [])
        XCTAssertTrue(panel.waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["受窗口大小限制，已尽量按所选位置排列。"].waitForExistence(timeout: 3))
    }
}
