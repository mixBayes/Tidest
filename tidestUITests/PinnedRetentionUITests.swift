import XCTest

final class PinnedRetentionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testNativePinsKeepOpenItemsAndRemoveClosedItemsWhenCancelled() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-pinned", "--ui-preview-count=3", "--ui-preview-language=zh-Hans"]
        app.launch()
        defer { app.terminate() }
        app.activate()

        let pins = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "pinnedRetain-"))
        waitForCount(3, in: pins)
        let openButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pinnedOpen-"))
        waitForCount(3, in: openButtons)
        XCTAssertTrue(openButtons.allElementsBoundByIndex.allSatisfy(\.isEnabled))
        XCTAssertTrue(openButtons.allElementsBoundByIndex.contains { $0.label.contains("已关闭") })
        assertVisibleCount(3, in: app)
        let ordered = pins.allElementsBoundByIndex.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(ordered.count, 3)
        let closedPin = try XCTUnwrap(ordered.first)
        let openPin = try XCTUnwrap(ordered.dropFirst().first)
        let closedID = closedPin.identifier
        let openID = openPin.identifier
        XCTAssertNotEqual(closedID, openID)
        assertPin(closedPin, retained: true)
        assertPin(openPin, retained: false)
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value == %@", "已关闭", "已关闭"))
            .firstMatch.exists)
        saveScreenshot(app, name: "常驻窗口 · 三个原生图钉与已关闭项目")

        // A live window remains in the shelf when retention is enabled or
        // cancelled. The preview updates memory only and never controls apps.
        openPin.click()
        let enabledPin = app.descendants(matching: .any)[openID]
        assertPin(enabledPin, retained: true)
        waitForCount(3, in: pins)
        assertVisibleCount(3, in: app)
        saveScreenshot(app, name: "常驻窗口 · 保留已开启")

        enabledPin.click()
        assertPin(app.descendants(matching: .any)[openID], retained: false)
        waitForCount(3, in: pins)
        assertVisibleCount(3, in: app)
        saveScreenshot(app, name: "常驻窗口 · 活窗口取消保留后仍在列表")

        // A saved item whose window is already closed disappears as soon as
        // the user cancels retention, leaving the two running-window items.
        app.descendants(matching: .any)[closedID].click()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == NO"),
                                                object: app.descendants(matching: .any)[closedID])
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 3), .completed)
        waitForCount(2, in: pins)
        assertVisibleCount(2, in: app)
        XCTAssertTrue(app.descendants(matching: .any)[openID].exists)
        saveScreenshot(app, name: "常驻窗口 · 已关闭项目取消保留后移除")
    }

    @MainActor
    func testHeaderEntersKeyboardLoopAndEscapeClosesShelf() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-pinned", "--ui-preview-count=3", "--ui-preview-language=zh-Hans"]
        app.launch()
        defer { app.terminate() }
        // The shelf is a nonactivating panel. Establish the test app as the
        // foreground app before XCTest resolves its temporary header element.
        app.activate()
        let header = app.descendants(matching: .any)["pinnedShelfHeader"]
        XCTAssertTrue(header.waitForExistence(timeout: 3))
        header.click()
        // This explicit header click enters the shelf's native key-view loop.
        // Return calls the first row's normal open action; preview mode only
        // highlights the row, so the native buttons remain available to Tab.
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pinnedOpen-")).count, 3)
        app.typeKey(.escape, modifierFlags: [])
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == NO"), object: header)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 3), .completed)
    }

    @MainActor
    private func assertPin(_ pin: XCUIElement, retained: Bool,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(pin.waitForExistence(timeout: 3), file: file, line: line)
        let expectedLabel = retained ? "取消保留" : "保留"
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let pin = object as? XCUIElement, pin.label == expectedLabel, pin.isEnabled else { return false }
            if let value = pin.value as? NSNumber { return value.boolValue == retained }
            if let value = pin.value as? String {
                return (retained ? ["1", "on", "true"] : ["0", "off", "false"]).contains(value.lowercased())
            }
            return pin.isSelected == retained
        }, object: pin)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed, file: file, line: line)
        XCTAssertTrue(pin.isHittable, file: file, line: line)
    }

    @MainActor
    private func waitForCount(_ count: Int, in pins: XCUIElementQuery,
                              file: StaticString = #filePath, line: UInt = #line) {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in pins.count == count }, object: pins)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed, file: file, line: line)
    }

    @MainActor
    private func assertVisibleCount(_ count: Int, in app: XCUIApplication,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let text = String(count)
        let headerCount = app.staticTexts
            .matching(NSPredicate(format: "label == %@ OR value == %@", text, text)).firstMatch
        XCTAssertTrue(headerCount.waitForExistence(timeout: 3), file: file, line: line)
    }

    @MainActor
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
