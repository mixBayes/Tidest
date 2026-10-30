import AppKit
import XCTest
@testable import tidest

@MainActor
final class LayoutTemplateStoreTests: XCTestCase {
    func testSaveRenameDeleteAndRestartPreserveOnlyStructure() throws {
        let suite = "tidest.layout-templates.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LayoutTemplateStore(defaults: defaults)
        let root = LayoutStartingPoint.largeLeft.makeRegion()
        XCTAssertTrue(store.save(name: " Work ", root: root))
        let saved = try XCTUnwrap(store.templates.first)
        XCTAssertEqual(saved.name, "Work")
        XCTAssertFalse(store.save(name: "work", root: root))
        XCTAssertTrue(store.save(name: "Focus", root: root, replacing: saved.id))
        let restarted = LayoutTemplateStore(defaults: defaults)
        XCTAssertEqual(restarted.templates.first?.id, saved.id)
        XCTAssertEqual(restarted.templates.first?.root, root)
        XCTAssertEqual(restarted.templates.first?.name, "Focus")
        XCTAssertTrue(restarted.delete(saved.id))
        XCTAssertTrue(LayoutTemplateStore(defaults: defaults).templates.isEmpty)
    }

    func testUnreadableTemplatesArePreservedAndCannotBeOverwritten() throws {
        let suite = "tidest.layout-templates.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let invalid = Data("unreadable".utf8)
        defaults.set(invalid, forKey: "multiWindowLayoutTemplates.v1")
        let store = LayoutTemplateStore(defaults: defaults)
        XCTAssertNotNil(store.errorKey)
        XCTAssertFalse(store.save(name: "New", root: .leaf(UUID())))
        XCTAssertFalse(store.delete(UUID()))
        XCTAssertEqual(defaults.data(forKey: "multiWindowLayoutTemplates.v1"), invalid)
    }

    func testPreviewTemplatesDoNotWriteAndUseTheSettingsSuite() throws {
        let suite = "tidest.layout-templates.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, persistChanges: false)
        let store = settings.makeLayoutTemplateStore()
        XCTAssertTrue(store.save(name: "Preview", root: .leaf(UUID())))
        XCTAssertEqual(store.templates.count, 1)
        XCTAssertTrue(LayoutTemplateStore(defaults: defaults).templates.isEmpty)
    }

    func testNewShortcutDefaultsAndExplicitClearingPreserveLegacyCustomKeys() throws {
        let suite = "tidest.layout-shortcut.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = WindowShortcut(keyCode: 37, modifiers: [.option, .control], keyName: "L")
        defaults.set(try JSONEncoder().encode(legacy), forKey: "quickLayoutShortcut")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.layoutShortcut, legacy)
        XCTAssertEqual(settings.multiLayoutShortcut, .multiWindowLayout)
        let new = WindowShortcut(keyCode: 40, modifiers: [.option, .control], keyName: "K")
        settings.multiLayoutShortcut = new
        XCTAssertEqual(AppSettings(defaults: defaults).multiLayoutShortcut, new)
        XCTAssertEqual(AppSettings(defaults: defaults).layoutShortcut, legacy)
        settings.multiLayoutShortcut = nil
        XCTAssertNil(AppSettings(defaults: defaults).multiLayoutShortcut)
        XCTAssertEqual(AppSettings(defaults: defaults).layoutShortcut, legacy)
    }

    func testQuickLayoutRemainsAnActionableMenuEntry() throws {
        let delegate = AppDelegate(permissions: PermissionStore(preview: true))
        let menu = delegate.makeStatusMenu()
        let item = try XCTUnwrap(menu.items.first { $0.action == #selector(AppDelegate.showMultiWindowLayout) })
        XCTAssertTrue(item.target === delegate)
        XCTAssertEqual(item.keyEquivalent, "")
    }
}
