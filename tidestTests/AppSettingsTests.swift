import Foundation
import ApplicationServices
import XCTest
@testable import tidest

final class AppSettingsTests: XCTestCase {
    @MainActor
    func testNewInstallUsesCarouselAndAutomaticallySelectsSystemLanguage() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults, preferredLanguages: { ["zh-TW"] })
            XCTAssertEqual(settings.displayMode, .carousel)
            XCTAssertEqual(settings.shortcut, .default)
            XCTAssertEqual(settings.layoutShortcut, .quickLayout)
            XCTAssertEqual(settings.language, .traditionalChinese)
            XCTAssertEqual(settings.locale.identifier, "zh-Hant")
            XCTAssertEqual(settings.text("权限"), "權限")
            XCTAssertTrue(settings.anonymousUsageEnabled)
        }
    }

    @MainActor
    func testAutomaticSelectionDoesNotPersistAndMatchesSystemAgainOnRestart() {
        withDefaults { defaults in
            let firstLaunch = AppSettings(defaults: defaults, preferredLanguages: { ["zh-CN"] })
            XCTAssertEqual(firstLaunch.language, .simplifiedChinese)
            XCTAssertNil(defaults.string(forKey: "language"))

            let restarted = AppSettings(defaults: defaults, preferredLanguages: { ["ja-JP"] })
            XCTAssertEqual(restarted.language, .japanese)
            XCTAssertEqual(restarted.text("语言"), "言語")
            XCTAssertNil(defaults.string(forKey: "language"))
        }
    }

    @MainActor
    func testSystemLanguageMatchesRegionAndRespectsPreferredLanguageOrder() {
        XCTAssertEqual(AppLanguage.matching(["zh-CN"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.matching(["zh-SG"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.matching(["zh-TW"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.matching(["zh-HK"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.matching(["ja-JP", "en-US"]), .japanese)
        XCTAssertEqual(AppLanguage.matching(["fr-FR", "ko-KR", "en-US"]), .korean)
        XCTAssertEqual(AppLanguage.matching(["fr-FR"]), .english)
        XCTAssertEqual(AppLanguage.matching([]), .english)
    }

    @MainActor
    func testModeAndManualLanguageSurviveRestart() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults, preferredLanguages: { ["en-US"] })
            settings.displayMode = .tiled
            settings.language = .korean
            settings.anonymousUsageEnabled = false
            settings.shortcut = WindowShortcut(keyCode: 40, modifiers: [.option, .shift], keyName: "K")
            settings.layoutShortcut = WindowShortcut(keyCode: 37, modifiers: [.control, .option], keyName: "L")

            let restarted = AppSettings(defaults: defaults, preferredLanguages: { ["ja-JP"] })
            XCTAssertEqual(restarted.displayMode, .tiled)
            XCTAssertEqual(restarted.language, .korean)
            XCTAssertFalse(restarted.anonymousUsageEnabled)
            XCTAssertEqual(restarted.shortcut, settings.shortcut)
            XCTAssertEqual(restarted.layoutShortcut, settings.layoutShortcut)
            XCTAssertEqual(restarted.locale.identifier, "ko")
            XCTAssertEqual(restarted.text("通用"), "일반")
        }
    }

    @MainActor
    func testChangingLanguageUpdatesTextImmediately() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults, preferredLanguages: { ["ja-JP"] })
            XCTAssertEqual(settings.text("显示模式"), "表示モード")
            settings.language = .english
            XCTAssertEqual(settings.locale.identifier, "en")
            XCTAssertEqual(settings.text("显示模式"), "Display mode")
            settings.language = .simplifiedChinese
            XCTAssertEqual(settings.text("显示模式"), "显示模式")
        }
    }

    @MainActor
    func testPreviewChangesDoNotSavePreferences() {
        withDefaults { defaults in
            defaults.set(DisplayMode.carousel.rawValue, forKey: "displayMode")
            defaults.set(AppLanguage.english.rawValue, forKey: "language")
            let settings = AppSettings(defaults: defaults, persistChanges: false, preferredLanguages: { ["en"] })
            settings.displayMode = .tiled
            settings.language = .japanese
            settings.anonymousUsageEnabled = false
            settings.shortcut = WindowShortcut(keyCode: 40, modifiers: .option, keyName: "K")
            settings.layoutShortcut = WindowShortcut(keyCode: 37, modifiers: .option, keyName: "L")

            XCTAssertEqual(settings.displayMode, .tiled)
            XCTAssertEqual(settings.text("语言"), "言語")
            let restarted = AppSettings(defaults: defaults, preferredLanguages: { ["en"] })
            XCTAssertEqual(restarted.displayMode, .carousel)
            XCTAssertEqual(restarted.language, .english)
            XCTAssertTrue(restarted.anonymousUsageEnabled)
            XCTAssertEqual(restarted.shortcut, .default)
            XCTAssertEqual(restarted.layoutShortcut, .quickLayout)
        }
    }

    @MainActor
    func testLayoutShortcutResetSurvivesRestartAndInvalidSavedKeysUseDefault() throws {
        try withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.layoutShortcut = WindowShortcut(keyCode: 37, modifiers: .option, keyName: "L")
            settings.layoutShortcut = .quickLayout
            XCTAssertEqual(AppSettings(defaults: defaults).layoutShortcut, .quickLayout)

            let invalid = WindowShortcut(keyCode: 37, modifiers: [], keyName: "L")
            defaults.set(try JSONEncoder().encode(invalid), forKey: "quickLayoutShortcut")
            XCTAssertEqual(AppSettings(defaults: defaults).layoutShortcut, .quickLayout)
            defaults.set(Data("not JSON".utf8), forKey: "quickLayoutShortcut")
            XCTAssertEqual(AppSettings(defaults: defaults).layoutShortcut, .quickLayout)
        }
    }

    @MainActor
    func testShortcutHelpUsesSavedKeysAndCurrentLanguage() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults, preferredLanguages: { ["en"] })
            settings.shortcut = WindowShortcut(keyCode: 40, modifiers: .option, keyName: "K")
            XCTAssertEqual(settings.text("按住 %@，按 %@ 切换窗口", settings.shortcut.modifierName, settings.shortcut.keyName),
                           "Hold Option and press K to switch windows")
            settings.language = .simplifiedChinese
            XCTAssertEqual(settings.text("按住 %@，按 %@ 切换窗口", settings.shortcut.modifierName, settings.shortcut.keyName),
                           "按住 Option，按 K 切换窗口")
        }
    }

    @MainActor
    func testRetainedWindowsAndTheirOrderSurviveRestart() throws {
        try withDefaults { defaults in
            let first = savedWindow(title: "First", target: .finder(path: "/Users/example/Documents"))
            let second = savedWindow(title: "Second", target: .browser(urls: ["https://example.com"], selectedTabIndex: 0))
            let settings = AppSettings(defaults: defaults)

            try settings.savePinnedWindows([PinnedWindowEntry(saved: second), PinnedWindowEntry(saved: first)])

            let restarted = AppSettings(defaults: defaults)
            XCTAssertEqual(try restarted.loadSavedPinnedWindows(), [second, first])
        }
    }

    @MainActor
    func testAllDockedWindowsAreSavedAndCancellingRetentionKeepsTheLiveItem() throws {
        try withDefaults { defaults in
            let saved = savedWindow(title: "Keep", target: .application)
            let liveWindow = WindowItem(
                element: AXUIElementCreateApplication(0), processID: 0,
                applicationName: "Example", icon: nil, title: "Live only",
                frame: .zero, minimized: false, captureID: nil, stackOrder: 0)
            var retained = PinnedWindowEntry(saved: saved)
            retained.window = liveWindow
            let unretained = PinnedWindowEntry(window: liveWindow)
            let settings = AppSettings(defaults: defaults)

            try settings.savePinnedWindows([unretained, retained])
            let restored = try settings.loadSavedPinnedWindows().map(PinnedWindowEntry.init(saved:))
            XCTAssertEqual(restored.map(\.id), [unretained.id, retained.id])
            XCTAssertEqual(restored.map(\.isRetained), [false, true])
            XCTAssertEqual(restored.map(\.title), [liveWindow.title, liveWindow.title])

            retained.saved?.retainAfterClose = false
            try settings.savePinnedWindows([unretained, retained])
            let afterCancellation = try AppSettings(defaults: defaults).loadSavedPinnedWindows()
                .map(PinnedWindowEntry.init(saved:))
            XCTAssertEqual(afterCancellation.map(\.id), [unretained.id, retained.id])
            XCTAssertEqual(afterCancellation.map(\.isRetained), [false, false])
        }
    }

    @MainActor
    func testSavedWindowsUseTheInjectedDefaultsInsteadOfStandardDefaults() throws {
        try withDefaults { firstDefaults in
            try withDefaults { secondDefaults in
                let saved = savedWindow(title: "First suite", target: .terminal(path: "/tmp"))
                try AppSettings(defaults: firstDefaults).savePinnedWindows([PinnedWindowEntry(saved: saved)])

                XCTAssertEqual(try AppSettings(defaults: firstDefaults).loadSavedPinnedWindows(), [saved])
                XCTAssertEqual(try AppSettings(defaults: secondDefaults).loadSavedPinnedWindows(), [])
            }
        }
    }

    @MainActor
    func testPreviewSavingDoesNotOverwriteOrClearRetainedWindows() throws {
        try withDefaults { defaults in
            let original = savedWindow(title: "Original", target: .application)
            let replacement = savedWindow(title: "Preview", target: .application)
            try AppSettings(defaults: defaults).savePinnedWindows([PinnedWindowEntry(saved: original)])
            let originalData = try XCTUnwrap(defaults.data(forKey: "savedPinnedItems.v1"))
            let preview = AppSettings(defaults: defaults, persistChanges: false)

            try preview.savePinnedWindows([PinnedWindowEntry(saved: replacement)])
            try preview.savePinnedWindows([])

            XCTAssertEqual(defaults.data(forKey: "savedPinnedItems.v1"), originalData)
            XCTAssertEqual(try AppSettings(defaults: defaults).loadSavedPinnedWindows(), [original])
        }
    }

    @MainActor
    func testEncodingFailureIsReportedWithoutReplacingPreviousSavedWindows() throws {
        try withDefaults { defaults in
            let original = savedWindow(title: "Original", target: .application)
            let settings = AppSettings(defaults: defaults)
            try settings.savePinnedWindows([PinnedWindowEntry(saved: original)])
            let invalid = SavedPinnedWindow(
                id: UUID(), applicationBundleIdentifier: "com.example.app",
                applicationURL: "file:///Applications/Example.app/", applicationName: "Example",
                title: "Invalid size", width: .nan, height: 600, target: .application)

            XCTAssertThrowsError(try settings.savePinnedWindows([PinnedWindowEntry(saved: invalid)]))
            XCTAssertEqual(try settings.loadSavedPinnedWindows(), [original])
        }
    }

    @MainActor
    func testUnreadableSavedWindowsAreReportedWithoutChangingDataOrOtherSettings() throws {
        try withDefaults { defaults in
            defaults.set(Data("not JSON".utf8), forKey: "savedPinnedWindows")
            defaults.set(DisplayMode.tiled.rawValue, forKey: "displayMode")
            let settings = AppSettings(defaults: defaults)

            XCTAssertThrowsError(try settings.loadSavedPinnedWindows())
            XCTAssertEqual(defaults.data(forKey: "savedPinnedWindows"), Data("not JSON".utf8))
            XCTAssertEqual(settings.displayMode, .tiled)
        }
    }

    @MainActor
    func testSavingCannotReplaceOrClearUnreadableSavedWindows() throws {
        try withDefaults { defaults in
            let unreadableData = Data("not JSON".utf8)
            defaults.set(unreadableData, forKey: "savedPinnedWindows")
            let settings = AppSettings(defaults: defaults)
            let replacement = savedWindow(title: "Replacement", target: .application)

            XCTAssertThrowsError(try settings.savePinnedWindows([PinnedWindowEntry(saved: replacement)]))
            XCTAssertEqual(defaults.data(forKey: "savedPinnedWindows"), unreadableData)

            XCTAssertThrowsError(try settings.savePinnedWindows([]))
            XCTAssertEqual(defaults.data(forKey: "savedPinnedWindows"), unreadableData)
        }
    }

    private func savedWindow(title: String, target: PinnedLaunchTarget) -> SavedPinnedWindow {
        SavedPinnedWindow(id: UUID(), applicationBundleIdentifier: "com.example.app",
                          applicationURL: "file:///Applications/Example.app/", applicationName: "Example",
                          title: title, width: 800, height: 600, target: target)
    }

    @MainActor
    private func withDefaults(_ perform: (UserDefaults) throws -> Void) rethrows {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try perform(defaults)
    }
}
