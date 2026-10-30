import XCTest

final class TiledInteractionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testHoverPreselectsGapPreservesKeyboardWinsAndClickCommits() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-switcher", "--ui-preview-tiled", "--ui-preview-thumbnails",
                               "--ui-preview-count=20", "--ui-preview-language=zh-Hans"]
        app.launch()
        let panel = app.dialogs["Tidest 切换窗口"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        app.activate()

        let document = app.buttons["windowCard-0"]
        let viewport = app.scrollViews.firstMatch
        XCTAssertTrue(viewport.frame.contains(document.frame))
        // Establish the pointer's position before asserting mouse selection;
        // the launch may inherit a pointer over any preview from a prior test.
        document.hover()
        assertSelection(app, title: "文稿", index: 0)
        XCTAssertTrue(panel.exists, "Hover must select without committing")
        saveScreenshot(panel, name: "平铺 · 鼠标指向文稿并预选")

        let documentFrame = document.frame
        // Find the next screenshot in this same row among a small visible sample.
        let neighbor = try XCTUnwrap((1..<6).map { app.buttons["windowCard-\($0)"].frame }
            .filter { abs($0.midY - documentFrame.midY) < 2 && $0.minX > documentFrame.maxX }
            .min { $0.minX < $1.minX })
        let gap = CGPoint(x: (documentFrame.maxX + neighbor.minX) / 2, y: documentFrame.midY)
        XCTAssertTrue(viewport.frame.contains(gap))
        coordinate(in: panel, at: gap).hover()
        assertSelection(app, title: "文稿", index: 0)
        XCTAssertTrue(panel.exists)

        // Keep the pointer over the old screenshot while the keyboard chooses
        // another one; view updates alone must not simulate new mouse movement.
        document.hover()
        app.typeKey(.rightArrow, modifierFlags: [])
        assertSelection(app, title: "下载", index: 1)
        XCTAssertFalse(app.buttons["windowCard-0"].isSelected)
        XCTAssertTrue(panel.exists)
        saveScreenshot(panel, name: "平铺 · 鼠标静止时键盘选择下载")
        assertSelection(app, title: "下载", index: 1)

        let project = app.buttons["windowCard-2"]
        project.hover()
        assertSelection(app, title: "项目资料", index: 2)
        XCTAssertTrue(panel.exists)
        saveScreenshot(panel, name: "平铺 · 再次移动鼠标恢复预选")
        project.click()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == NO"), object: panel)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 2), .completed)
        XCTAssertFalse(app.staticTexts["selectedWindowTitle"].exists)
    }

    @MainActor
    private func assertSelection(_ app: XCUIApplication, title: String, index: Int,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let selected = app.staticTexts["selectedWindowTitle"]
        let titleChanged = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", title), object: selected)
        XCTAssertEqual(XCTWaiter.wait(for: [titleChanged], timeout: 2), .completed, file: file, line: line)
        let selectedCard = app.buttons["windowCard-\(index)"]
        let highlighted = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            (object as? XCUIElement)?.isSelected == true
        }, object: selectedCard)
        XCTAssertEqual(XCTWaiter.wait(for: [highlighted], timeout: 2), .completed, file: file, line: line)
        XCTAssertGreaterThanOrEqual(selected.frame.minY, selectedCard.frame.maxY, file: file, line: line)
        XCTAssertLessThan(selected.frame.height, 20, file: file, line: line)
    }

    @MainActor
    private func coordinate(in panel: XCUIElement, at point: CGPoint) -> XCUICoordinate {
        panel.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - panel.frame.minX, dy: point.y - panel.frame.minY))
    }

    @MainActor
    private func saveScreenshot(_ panel: XCUIElement, name: String) {
        let attachment = XCTAttachment(screenshot: panel.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
