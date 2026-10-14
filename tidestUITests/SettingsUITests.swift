import XCTest

final class SettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testWindowTabIsDefaultAndGeneralContainsLanguageAndPermissions() {
        let app = launchSettings(language: "zh-Hans")
        let initialWindowSize = app.windows["设置"].frame.size
        assertWindowSize(app, title: "设置", matches: initialWindowSize)
        let carousel = app.buttons["displayModeCarousel"]
        let tiled = app.buttons["displayModeTiled"]
        XCTAssertTrue(carousel.exists)
        XCTAssertTrue(tiled.exists)
        XCTAssertEqual(carousel.label, "横向预览")
        XCTAssertEqual(tiled.label, "平铺预览")
        XCTAssertGreaterThanOrEqual(carousel.frame.width, 160)
        XCTAssertGreaterThanOrEqual(carousel.frame.height, 80)
        XCTAssertGreaterThanOrEqual(tiled.frame.width, 160)
        XCTAssertGreaterThanOrEqual(tiled.frame.height, 80)
        assertDisplayMode(app, selectedIdentifier: "displayModeCarousel")
        XCTAssertTrue(app.staticTexts["窗口切换"].exists)
        XCTAssertTrue(app.staticTexts["窗口切换快捷键"].exists)
        XCTAssertTrue(app.staticTexts["快速布局"].exists)
        XCTAssertTrue(app.staticTexts["窗口停靠"].exists)
        XCTAssertTrue(app.buttons["layoutShortcutRecorder"].exists)
        XCTAssertFalse(picker(app, identifier: "languagePicker").exists)
        XCTAssertFalse(app.buttons["accessibilityPermissionSettings"].exists)
        saveScreenshot(app, name: "设置 · 窗口")

        selectSettingsTab("通用", in: app)
        XCTAssertTrue(picker(app, identifier: "languagePicker").exists)
        XCTAssertFalse(carousel.exists)
        assertWindowSize(app, title: "设置", matches: initialWindowSize)
        let accessibility = app.buttons["accessibilityPermissionSettings"]
        let capture = app.buttons["screenCapturePermissionSettings"]
        scrollTo(accessibility, in: app)
        assertPermissionStatus(app, identifier: "accessibilityPermissionStatus", isGranted: false)
        assertPermissionStatus(app, identifier: "screenCapturePermissionStatus", isGranted: false)
        XCTAssertTrue(app.staticTexts["辅助功能 · 必需"].exists)
        XCTAssertTrue(app.staticTexts["屏幕录制 · 可选"].exists)
        XCTAssertTrue(app.staticTexts["用于切换、布局和停靠窗口"].exists)
        XCTAssertTrue(app.staticTexts["用于显示窗口预览"].exists)
        XCTAssertFalse(app.switches["accessibilityPermissionSwitch"].exists)
        XCTAssertFalse(app.checkBoxes["accessibilityPermissionSwitch"].exists)
        XCTAssertFalse(app.switches["screenCapturePermissionSwitch"].exists)
        XCTAssertFalse(app.checkBoxes["screenCapturePermissionSwitch"].exists)
        accessibility.click()
        scrollTo(capture, in: app)
        capture.click()
        assertPermissionStatus(app, identifier: "accessibilityPermissionStatus", isGranted: false)
        assertPermissionStatus(app, identifier: "screenCapturePermissionStatus", isGranted: false)
        XCTAssertTrue(app.windows["设置"].isHittable)
        assertWindowSize(app, title: "设置", matches: initialWindowSize)
        saveScreenshot(app, name: "设置 · 通用与真实权限状态")

        XCTAssertFalse(app.staticTexts["appVersion"].exists)
        XCTAssertFalse(app.buttons["checkForUpdates"].exists)
        selectSettingsTab("窗口", in: app)
        XCTAssertTrue(carousel.exists)
        assertWindowSize(app, title: "设置", matches: initialWindowSize)
    }

    @MainActor
    func testAboutIsASeparateWindow() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-about", "--ui-preview-language=zh-Hans"]
        app.launch()
        XCTAssertTrue(app.windows["关于 Tidest"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Tidest"].exists)
        let version = app.staticTexts["appVersion"]
        XCTAssertTrue(version.waitForExistence(timeout: 2))
        let versionText = version.value as? String
        XCTAssertNotNil(versionText, "Version static text: \(version.debugDescription)")
        XCTAssertNotNil(versionText?.range(of: #"^版本\s+\d+(\.\d+)*$"#, options: .regularExpression))
        let update = app.buttons["checkForUpdates"]
        XCTAssertTrue(update.exists)
        XCTAssertTrue(update.label.contains("检查更新"))
        XCTAssertTrue(update.isEnabled)
        saveScreenshot(app, name: "关于 Tidest · 版本")
    }

    @MainActor
    func testGrantedPreviewSettingsActionsKeepSystemPermissionStatus() {
        let app = launchSettings(language: "zh-Hans", additionalArguments: [
            "--ui-preview-granted-accessibility", "--ui-preview-granted-screen"
        ])
        selectSettingsTab("通用", in: app)
        let accessibility = app.buttons["accessibilityPermissionSettings"]
        let capture = app.buttons["screenCapturePermissionSettings"]
        scrollTo(accessibility, in: app)
        assertPermissionStatus(app, identifier: "accessibilityPermissionStatus", isGranted: true)
        assertPermissionStatus(app, identifier: "screenCapturePermissionStatus", isGranted: true)
        XCTAssertTrue(accessibility.isEnabled)
        accessibility.click()
        scrollTo(capture, in: app)
        XCTAssertTrue(capture.isEnabled)
        capture.click()
        assertPermissionStatus(app, identifier: "accessibilityPermissionStatus", isGranted: true)
        assertPermissionStatus(app, identifier: "screenCapturePermissionStatus", isGranted: true)
        XCTAssertTrue(app.windows["设置"].isHittable)
        saveScreenshot(app, name: "设置 · 已授权仍可管理权限")
    }

    @MainActor
    func testLanguageAndDisplayModeChangeImmediately() {
        let app = launchSettings(language: "en")
        XCTAssertTrue(app.windows["Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Display mode"].exists)
        selectSettingsTab("General", in: app)
        let languagePicker = picker(app, identifier: "languagePicker")
        assertSelection("English", picker: languagePicker)
        let languageMenu = openPickerMenu("languagePicker", in: app)
        XCTAssertTrue(languageMenu.menuItems["English"].waitForExistence(timeout: 2))
        saveMenuDiagnostics(languageMenu, app: app)
        for language in ["简体中文", "繁體中文", "English", "日本語", "한국어"] {
            XCTAssertTrue(languageMenu.menuItems[language].exists)
        }
        XCTAssertEqual(languageMenu.menuItems.count, 5)
        XCTAssertFalse(languageMenu.menuItems["System default"].exists)
        XCTAssertFalse(languageMenu.menuItems["跟随系统"].exists)
        app.typeKey(.escape, modifierFlags: [])
        selectSettingsTab("Windows", in: app)
        XCTAssertEqual(app.buttons["displayModeCarousel"].label, "Horizontal preview")
        XCTAssertEqual(app.buttons["displayModeTiled"].label, "Tile preview")
        clickDisplayMode(app, identifier: "displayModeTiled")
        assertDisplayMode(app, selectedIdentifier: "displayModeTiled")
        clickDisplayMode(app, identifier: "displayModeCarousel")
        assertDisplayMode(app, selectedIdentifier: "displayModeCarousel")
        saveScreenshot(app, name: "Settings · English")

        selectSettingsTab("General", in: app)
        selectOption("日本語", from: "languagePicker", in: app)
        XCTAssertTrue(app.windows["設定"].waitForExistence(timeout: 3))
        selectSettingsTab("ウインドウ", in: app)
        XCTAssertTrue(app.staticTexts["表示モード"].exists)
        XCTAssertEqual(app.buttons["displayModeCarousel"].label, "横並びプレビュー")
        XCTAssertEqual(app.buttons["displayModeTiled"].label, "タイルプレビュー")
        assertDisplayMode(app, selectedIdentifier: "displayModeCarousel")
        saveScreenshot(app, name: "設定 · 日本語へ即時切り替え")

        selectSettingsTab("一般", in: app)
        selectOption("简体中文", from: "languagePicker", in: app)
        XCTAssertTrue(app.windows["设置"].waitForExistence(timeout: 3))
        selectSettingsTab("窗口", in: app)
        XCTAssertTrue(app.staticTexts["显示模式"].exists)
        XCTAssertEqual(app.buttons["displayModeCarousel"].label, "横向预览")
        XCTAssertEqual(app.buttons["displayModeTiled"].label, "平铺预览")
        assertDisplayMode(app, selectedIdentifier: "displayModeCarousel")
        saveScreenshot(app, name: "设置 · 简体中文即时切换")
    }

    @MainActor
    func testQuickLayoutShortcutRecordingAndConflictsUseCurrentSettings() {
        let app = launchSettings(language: "zh-Hans")
        let layout = app.buttons["layoutShortcutRecorder"]
        let resetLayout = app.buttons["resetLayoutShortcut"]
        scrollTo(layout, in: app)
        XCTAssertTrue(layout.label.contains("Option + Q"))
        XCTAssertFalse(resetLayout.isEnabled)
        layout.click()
        app.typeKey("l", modifierFlags: [])
        XCTAssertTrue(app.staticTexts["layoutShortcutMessage"].waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(layout.label.contains("Option + Q"))

        recordShortcut("l", modifiers: .option, identifier: "layoutShortcutRecorder", in: app)
        XCTAssertTrue(layout.label.contains("Option + L"))
        XCTAssertTrue(resetLayout.isEnabled)
        saveScreenshot(app, name: "设置 · 自定义快速布局快捷键")

        recordShortcut("l", modifiers: .option, identifier: "shortcutRecorder", in: app)
        XCTAssertTrue(app.buttons["shortcutRecorder"].label.contains("Option + Tab"))
        XCTAssertTrue(app.staticTexts["这个快捷键用于快速布局，请选择其他快捷键。"].exists)
        recordShortcut("l", modifiers: .option, identifier: "pinShortcutRecorder", in: app)
        XCTAssertTrue(app.buttons["pinShortcutRecorder"].label.contains("Option + W"))
        XCTAssertTrue(app.staticTexts["这个快捷键用于快速布局，请选择其他快捷键。"].exists)

        recordShortcut(XCUIKeyboardKey.tab.rawValue, modifiers: .option, identifier: "layoutShortcutRecorder", in: app)
        XCTAssertTrue(layout.label.contains("Option + L"))
        XCTAssertTrue(app.staticTexts["这个快捷键用于窗口切换，请选择其他快捷键。"].exists)
        recordShortcut("w", modifiers: .option, identifier: "layoutShortcutRecorder", in: app)
        XCTAssertTrue(layout.label.contains("Option + L"))
        XCTAssertTrue(app.staticTexts["这个快捷键用于拾取窗口，请选择其他快捷键。"].exists)

        // Option + Q becomes available when layout moves to another shortcut.
        recordShortcut("q", modifiers: .option, identifier: "shortcutRecorder", in: app)
        XCTAssertTrue(app.buttons["shortcutRecorder"].label.contains("Option + Q"))
        scrollTo(resetLayout, in: app)
        resetLayout.click()
        XCTAssertTrue(layout.label.contains("Option + L"))
        scrollTo(app.buttons["resetShortcut"], in: app)
        app.buttons["resetShortcut"].click()

        recordShortcut("q", modifiers: .option, identifier: "pinShortcutRecorder", in: app)
        XCTAssertTrue(app.buttons["pinShortcutRecorder"].label.contains("Option + Q"))
        scrollTo(resetLayout, in: app)
        resetLayout.click()
        XCTAssertTrue(layout.label.contains("Option + L"))
        scrollTo(app.buttons["resetPinShortcut"], in: app)
        app.buttons["resetPinShortcut"].click()
        scrollTo(resetLayout, in: app)
        resetLayout.click()
        XCTAssertTrue(layout.label.contains("Option + Q"))
        XCTAssertFalse(resetLayout.isEnabled)
    }

    @MainActor
    func testChangingTabsCancelsShortcutRecording() {
        let app = launchSettings(language: "zh-Hans")
        for identifier in ["shortcutRecorder", "layoutShortcutRecorder", "pinShortcutRecorder"] {
            let recorder = app.buttons[identifier]
            scrollTo(recorder, in: app)
            let originalLabel = recorder.label
            recorder.click()
            XCTAssertTrue(app.staticTexts["按 Esc 取消"].waitForExistence(timeout: 2))
            selectSettingsTab("通用", in: app)
            selectSettingsTab("窗口", in: app)
            XCTAssertEqual(recorder.label, originalLabel)
            XCTAssertFalse(app.staticTexts["按 Esc 取消"].exists)
        }
    }

    @MainActor
    func testShortcutRecordingCancelValidationAndReset() {
        let app = launchSettings(language: "zh-Hans")
        let recorder = app.buttons["shortcutRecorder"]
        XCTAssertTrue(recorder.waitForExistence(timeout: 3))
        XCTAssertTrue(recorder.label.contains("Option + Tab"))
        XCTAssertFalse(app.buttons["resetShortcut"].isEnabled)
        app.activate()
        recorder.click()
        XCTAssertTrue(app.staticTexts["按 Esc 取消"].waitForExistence(timeout: 2))
        app.typeKey("k", modifierFlags: [])
        XCTAssertTrue(app.staticTexts["shortcutMessage"].waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(recorder.label.contains("Option + Tab"))
        app.activate()
        recorder.click()
        XCTAssertTrue(app.staticTexts["按 Esc 取消"].waitForExistence(timeout: 2))
        app.typeKey("k", modifierFlags: .option)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            (object as? XCUIElement)?.label.contains("Option + K") == true
        }, object: recorder)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed)
        XCTAssertTrue(app.buttons["resetShortcut"].isEnabled)
        saveScreenshot(app, name: "设置 · 自定义快捷键")
        app.activate()
        app.buttons["resetShortcut"].click()
        XCTAssertTrue(recorder.label.contains("Option + Tab"))
        XCTAssertFalse(app.buttons["resetShortcut"].isEnabled)

        app.activate()
        recorder.click()
        XCTAssertTrue(app.staticTexts["按 Esc 取消"].waitForExistence(timeout: 2))
        app.typeKey("k", modifierFlags: [.command, .shift])
        let commandRecorded = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            (object as? XCUIElement)?.label.contains("Shift + Command + K") == true
        }, object: recorder)
        XCTAssertEqual(XCTWaiter.wait(for: [commandRecorded], timeout: 3), .completed)
        app.activate()
        app.buttons["resetShortcut"].click()
    }

    @MainActor
    private func launchSettings(language: String, additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview-settings", "--ui-preview-language=\(language)"] + additionalArguments
        app.launch()
        XCTAssertTrue(app.buttons["displayModeCarousel"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func selectSettingsTab(_ title: String, in app: XCUIApplication) {
        let radio = app.radioButtons[title]
        let tab = radio.exists ? radio : app.buttons[title]
        XCTAssertTrue(tab.waitForExistence(timeout: 2))
        tab.click()
    }

    @MainActor
    private func recordShortcut(_ key: String, modifiers: XCUIElement.KeyModifierFlags, identifier: String, in app: XCUIApplication) {
        let recorder = app.buttons[identifier]
        scrollTo(recorder, in: app)
        recorder.click()
        XCTAssertTrue(app.staticTexts["按 Esc 取消"].waitForExistence(timeout: 2))
        app.typeKey(key, modifierFlags: modifiers)
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            (object as? XCUIElement)?.label.contains("请按下快捷键…") == false
        }, object: recorder)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 3), .completed)
    }

    @MainActor
    private func picker(_ app: XCUIApplication, identifier: String) -> XCUIElement {
        let popup = app.popUpButtons[identifier]
        if popup.exists { return popup }
        let button = app.buttons[identifier]
        if button.exists { return button }
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func clickDisplayMode(_ app: XCUIApplication, identifier: String) {
        app.activate()
        scrollTo(app.buttons[identifier], in: app)
        app.buttons[identifier].click()
    }

    @MainActor
    private func assertDisplayMode(_ app: XCUIApplication, selectedIdentifier: String) {
        for identifier in ["displayModeCarousel", "displayModeTiled"] {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.exists)
            let expected = identifier == selectedIdentifier
            let selection = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
                (object as? XCUIElement)?.isSelected == expected
            }, object: button)
            XCTAssertEqual(XCTWaiter.wait(for: [selection], timeout: 2), .completed)
        }
    }

    @MainActor
    private func assertWindowSize(_ app: XCUIApplication, title: String, matches initial: CGSize) {
        let size = app.windows[title].frame.size
        XCTAssertLessThanOrEqual(size.width, 500)
        XCTAssertLessThanOrEqual(size.height, 720)
        XCTAssertEqual(size.width, initial.width, accuracy: 1)
        XCTAssertEqual(size.height, initial.height, accuracy: 1)
    }

    @MainActor
    private func assertPermissionStatus(_ app: XCUIApplication, identifier: String, isGranted: Bool,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let element = app.staticTexts[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 2), file: file, line: line)
        let expected = isGranted ? "已开启" : "未开启"
        let state = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return element.label == expected || (element.value as? String) == expected
        }, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [state], timeout: 2), .completed, file: file, line: line)
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication,
                          file: StaticString = #filePath, line: UInt = #line) {
        let viewport = app.scrollViews.firstMatch
        for _ in 0..<8 {
            if element.isHittable { return }
            let aboveViewport = element.exists && element.frame.midY < viewport.frame.minY
            viewport.scroll(byDeltaX: 0, deltaY: aboveViewport ? 250 : -250)
        }
        XCTAssertTrue(element.isHittable, file: file, line: line)
    }

    @MainActor
    private func selectOption(_ title: String, from identifier: String, in app: XCUIApplication) {
        let menu = openPickerMenu(identifier, in: app)
        let option = menu.menuItems[title]
        XCTAssertTrue(option.waitForExistence(timeout: 2))
        // A language change rebuilds the menu labels immediately. Click its
        // current position so XCTest does not hover the dismissed menu afterward.
        option.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    @MainActor
    private func openPickerMenu(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.activate()
        let popup = picker(app, identifier: identifier)
        scrollTo(popup, in: app)
        popup.click()
        let menu = popup.descendants(matching: .menu).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 2))
        return menu
    }

    @MainActor
    private func assertSelection(_ title: String, picker: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return (element.value as? String)?.contains(title) == true || element.label.contains(title)
        }, object: picker)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 2), .completed, file: file, line: line)
    }

    @MainActor
    private func saveScreenshot(_ app: XCUIApplication, name: String) {
        app.activate()
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func saveMenuDiagnostics(_ menu: XCUIElement, app: XCUIApplication) {
        let items = menu.menuItems.allElementsBoundByIndex.enumerated().map { index, item in
            let scalars = item.label.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
            return "\(index): label=\(String(reflecting: item.label)); identifier=\(String(reflecting: item.identifier)); value=\(String(describing: item.value)); hittable=\(item.isHittable); scalars=[\(scalars)]"
        }
        let attachment = XCTAttachment(string: items.joined(separator: "\n") + "\n\n" + menu.debugDescription)
        attachment.name = "语言菜单 · AX 文本与 Unicode"
        attachment.lifetime = .keepAlways
        add(attachment)
        saveScreenshot(app, name: "语言菜单 · 五种具体语言")
    }
}
