import XCTest

final class tidestUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }
    @MainActor
    func testAccessibilityIsRequiredBeforeStarting() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-accessibility", "--ui-preview-language=zh-Hans"]
        app.launch()
        XCTAssertTrue(app.staticTexts["允许切换窗口"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["grantAccessibility"].exists)
        XCTAssertTrue(app.buttons["quitPermissionGuide"].exists)
        XCTAssertFalse(app.buttons["closePermissionGuide"].exists)
        XCTAssertFalse(app.buttons["skipScreenCapture"].exists)
        XCTAssertTrue(app.staticTexts["找到 Tidest，打开旁边的开关"].exists)
        XCTAssertTrue(app.staticTexts["回到这里，会自动检查是否开启"].exists)
        saveScreenshot(app, name: "辅助功能引导")
    }
    @MainActor
    func testScreenPreviewsCanBeEnabledLater() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-screen", "--ui-preview-language=zh-Hans"]
        app.launch()
        XCTAssertTrue(app.staticTexts["显示窗口预览"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.checkBoxes["suppressScreenCaptureReminder"].exists)
        XCTAssertTrue(app.staticTexts["找到 Tidest，打开旁边的开关"].exists)
        saveScreenshot(app, name: "窗口预览引导")
        app.buttons["skipScreenCapture"].click()
        XCTAssertTrue(app.staticTexts["开始使用 Tidest"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["现在可以切换窗口。"].exists)
        XCTAssertTrue(app.staticTexts["startUsingShortcut"].exists)
        XCTAssertFalse(app.buttons["grantScreenCapture"].exists)
        XCTAssertFalse(app.buttons["quitPermissionGuide"].exists)
        saveScreenshot(app, name: "暂不开启预览后 · 开始切换窗口")
        app.buttons["closePermissionGuide"].click()
        XCTAssertFalse(app.descendants(matching: .any)["permissionGuide"].waitForExistence(timeout: 2))
    }
    @MainActor
    func testFinderWindowsAreSeparateAndOptionTabCycles() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-switcher", "--ui-preview-language=zh-Hans"]
        app.launch()
        app.activate()
        let selected = app.staticTexts["selectedWindowTitle"]
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        XCTAssertEqual(selected.value as? String, "文稿")
        saveScreenshot(app, name: "Finder 多窗口书页效果")
        for expected in ["下载", "项目资料", "图片", "归档", "文稿"] {
            app.typeKey(.tab, modifierFlags: .option)
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: selected)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 2), .completed)
        }
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(selected.waitForExistence(timeout: 1))
    }
    @MainActor
    func testPreviewImagesFollowSelectionWithArrows() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-switcher", "--ui-preview-thumbnails", "--ui-preview-language=zh-Hans"]
        app.launch()
        let selected = app.staticTexts["selectedWindowTitle"]
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        XCTAssertEqual(selected.value as? String, "文稿")
        let baseHeight = app.buttons["windowCard-0"].frame.height
        assertSelectedCard(app, index: 0, aspectRatio: 2.0, baseHeight: baseHeight)
        let first = app.buttons["windowCard-0"].frame
        var previousX = first.maxX
        for index in 1...2 {
            let frame = app.buttons["windowCard-\(index)"].frame
            XCTAssertGreaterThanOrEqual(frame.minX, previousX - 1)
            previousX = frame.minX
        }
        for index in 3...4 {
            XCTAssertLessThanOrEqual(app.buttons["windowCard-\(index)"].frame.maxX, first.minX + 1)
        }
        XCTAssertLessThan(app.buttons["windowCard-1"].frame.width, first.width / 2)
        saveScreenshot(app, name: "原始比例截图与书页倾斜")

        for (index, title, ratio) in [(1, "下载", 400.0 / 700), (2, "项目资料", 1.6), (3, "图片", 1.0), (4, "归档", 1200.0 / 450), (0, "文稿", 2.0)] {
            app.buttons["下一个窗口"].click()
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", title), object: selected)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 2), .completed)
            assertSelectedCard(app, index: index, aspectRatio: ratio, baseHeight: baseHeight)
            if [3, 4, 1].contains(index) { saveScreenshot(app, name: "\(title) · 同高自然比例") }
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testPreviewRefreshReplacesImagesSilently() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-switcher", "--ui-preview-thumbnails", "--ui-preview-refresh", "--ui-preview-language=zh-Hans"]
        app.launch()
        let selected = app.staticTexts["selectedWindowTitle"]
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        let card = app.buttons["windowCard-0"]
        let initialFrame = card.frame
        let initialImage = card.screenshot().pngRepresentation
        XCTAssertEqual(app.progressIndicators.count, 0)
        saveScreenshot(app, name: "静默刷新前")
        // The sample updates after five seconds without requesting screen access.
        Thread.sleep(forTimeInterval: 6)
        XCTAssertEqual(selected.value as? String, "文稿")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "windowCard-")).count, 5)
        XCTAssertEqual(app.progressIndicators.count, 0)
        XCTAssertFalse(app.staticTexts["正在读取窗口…"].exists)
        XCTAssertEqual(card.frame, initialFrame)
        XCTAssertNotEqual(card.screenshot().pngRepresentation, initialImage)
        saveScreenshot(app, name: "静默刷新后 · 保持选择与位置")
        app.typeKey(.escape, modifierFlags: [])
    }
    @MainActor
    func testManyFinderWindowsFitFullScreenMargins() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-switcher", "--ui-preview-thumbnails", "--ui-preview-count=20", "--ui-preview-language=zh-Hans"]
        app.launch()
        XCTAssertTrue(app.staticTexts["selectedWindowTitle"].waitForExistence(timeout: 5))
        let overlay = app.dialogs["Tidest 窗口切换"]
        XCTAssertTrue(overlay.exists)
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "windowCard-"))
        XCTAssertEqual(cards.count, 20)
        for card in cards.allElementsBoundByIndex {
            XCTAssertGreaterThanOrEqual(card.frame.minX, overlay.frame.minX + 99)
            XCTAssertLessThanOrEqual(card.frame.maxX, overlay.frame.maxX - 99)
        }
        saveScreenshot(app, name: "20 个不同形状窗口全屏效果")
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testTwentyTiledWindowsStayReadableAndRevealTheLastWindow() {
        assertTiledWindows(count: 20)
    }

    @MainActor
    func testOneHundredFiftyTiledWindowsKeepTheirSizeAndRevealTheLastWindow() {
        assertTiledWindows(count: 150)
    }

    @MainActor
    private func assertTiledWindows(count: Int) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-switcher", "--ui-preview-tiled", "--ui-preview-thumbnails",
                               "--ui-preview-count=\(count)", "--ui-preview-language=zh-Hans"]
        app.launch()
        let selected = app.staticTexts["selectedWindowTitle"]
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        // Start with an explicit hover: this flow measures geometry and
        // keyboard reveal, rather than the pointer left by another UI test.
        app.activate()
        app.buttons["windowCard-0"].hover()
        let firstSelected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "文稿"), object: selected)
        XCTAssertEqual(XCTWaiter.wait(for: [firstSelected], timeout: 2), .completed)
        XCTAssertEqual(selected.value as? String, "文稿")
        XCTAssertLessThan(selected.frame.height, 20)
        XCTAssertGreaterThanOrEqual(selected.frame.minY, app.buttons["windowCard-0"].frame.maxY)
        XCTAssertTrue(app.staticTexts["switcherSelectionInstructions"].exists)
        let viewport = app.scrollViews.firstMatch
        XCTAssertTrue(viewport.exists)
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "windowCard-"))
        XCTAssertEqual(cards.count, count)
        let viewportFrame = viewport.frame
        let ratios: [CGFloat] = [2.0, 400.0 / 700, 1.6, 1.0, 1200.0 / 450]
        let initialHeight = app.buttons["windowCard-2"].frame.height
        let initialWideSize = app.buttons["windowCard-4"].frame.size
        var visible: [(index: Int, frame: CGRect)] = []
        // Offscreen controls can make XCUI retry expensive hit tests. Inspect
        // only a small sample by stable IDs; geometry tests cover all 150 cards.
        for index in 0..<min(count, 12) {
            let frame = app.buttons["windowCard-\(index)"].frame
            if !frame.isEmpty && viewportFrame.contains(frame) { visible.append((index, frame)) }
        }
        XCTAssertGreaterThan(visible.count, 1)
        for pair in zip(visible, visible.dropFirst()) {
            if abs(pair.0.frame.midY - pair.1.frame.midY) < 1 {
                XCTAssertGreaterThan(pair.1.frame.minX, pair.0.frame.maxX)
            } else {
                XCTAssertGreaterThan(pair.1.frame.midY, pair.0.frame.midY)
            }
        }
        for (index, card) in visible.enumerated() {
            XCTAssertGreaterThan(card.frame.width, 0)
            XCTAssertLessThanOrEqual(card.frame.width, min(560, viewportFrame.width - 72) + 1)
            XCTAssertGreaterThanOrEqual(card.frame.height, 100)
            XCTAssertLessThanOrEqual(card.frame.height, 310)
            if ratios[card.index % ratios.count] <= 2 {
                XCTAssertEqual(card.frame.height, initialHeight, accuracy: 1)
            } else {
                XCTAssertLessThanOrEqual(card.frame.height, initialHeight + 1)
            }
            XCTAssertEqual(card.frame.width / card.frame.height, ratios[card.index % ratios.count], accuracy: 0.01)
            for other in visible.dropFirst(index + 1) {
                XCTAssertFalse(card.frame.intersects(other.frame), "Tiled window cards overlap")
            }
        }
        saveScreenshot(app, name: "平铺 · \(count) 个窗口与原始截图比例")

        // Verify keyboard reveal without mouse travel preselecting screenshots
        // on the way to the navigation button.
        app.typeKey(.leftArrow, modifierFlags: [])
        let lastSelected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "归档 \(count)"), object: selected)
        XCTAssertEqual(XCTWaiter.wait(for: [lastSelected], timeout: 3), .completed)
        let lastCard = app.buttons["windowCard-\(count - 1)"]
        let revealed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            lastCard.isHittable && viewport.frame.contains(lastCard.frame)
        }, object: lastCard)
        XCTAssertEqual(XCTWaiter.wait(for: [revealed], timeout: 3), .completed)
        XCTAssertEqual(lastCard.frame.width / lastCard.frame.height, ratios[(count - 1) % ratios.count], accuracy: 0.01)
        // Compare the same original aspect ratio, since very wide screenshots
        // are scaled down together in width and height to fit the viewport.
        XCTAssertEqual(lastCard.frame.width, initialWideSize.width, accuracy: 1)
        XCTAssertEqual(lastCard.frame.height, initialWideSize.height, accuracy: 1)
        XCTAssertLessThanOrEqual(lastCard.frame.width, min(560, viewport.frame.width - 72) + 1)
        saveScreenshot(app, name: "平铺 · 自动滚到第 \(count) 个窗口")
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    private func assertSelectedCard(_ app: XCUIApplication, index: Int, aspectRatio: Double, baseHeight: CGFloat) {
        let selectedFrame = app.buttons["windowCard-\(index)"].frame
        let overlay = app.dialogs["Tidest 窗口切换"].frame
        XCTAssertEqual(selectedFrame.height, baseHeight, accuracy: 1)
        XCTAssertEqual(selectedFrame.width / selectedFrame.height, aspectRatio, accuracy: 0.01)
        XCTAssertEqual(selectedFrame.midX, overlay.midX, accuracy: 1)
        for card in app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "windowCard-")).allElementsBoundByIndex {
            XCTAssertGreaterThanOrEqual(card.frame.minX, overlay.minX + 99)
            XCTAssertLessThanOrEqual(card.frame.maxX, overlay.maxX - 99)
        }
        XCTAssertEqual(app.progressIndicators.count, 0)
    }
    @MainActor
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
