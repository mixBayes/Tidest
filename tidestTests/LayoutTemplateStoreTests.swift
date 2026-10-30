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
        let root = LayoutRegion.split(UUID(), .columns, 0.6, .leaf(UUID()), .leaf(UUID()))
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
        XCTAssertTrue(store.save(name: "Preview", root: .split(UUID(), .rows, 0.4, .leaf(UUID()), .leaf(UUID()))))
        XCTAssertEqual(store.templates.count, 1)
        XCTAssertTrue(LayoutTemplateStore(defaults: defaults).templates.isEmpty)
    }

    func testDuplicateGeometryCannotBeSavedUnderAnotherNameOrWithNewRegionIDs() throws {
        let suite = "tidest.layout-templates.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LayoutTemplateStore(defaults: defaults)
        let root = LayoutRegion.split(UUID(), .columns, 0.6, .leaf(UUID()), .leaf(UUID()))
        XCTAssertTrue(store.save(name: "Work", root: root))
        let originalData = defaults.data(forKey: "multiWindowLayoutTemplates.v1")
        let duplicate = LayoutRegion.split(UUID(), .columns, 0.6, .leaf(UUID()), .leaf(UUID()))
        XCTAssertEqual(store.matchingTemplate(for: duplicate)?.name, "Work")
        XCTAssertFalse(store.save(name: "Another name", root: duplicate))
        XCTAssertEqual(store.templates.count, 1)
        XCTAssertEqual(defaults.data(forKey: "multiWindowLayoutTemplates.v1"), originalData)
        XCTAssertEqual(LayoutTemplateStore(defaults: defaults).matchingTemplate(for: duplicate)?.id, store.templates.first?.id)
        XCTAssertTrue(store.save(name: "Different proportions", root: .split(UUID(), .columns, 0.61, .leaf(UUID()), .leaf(UUID()))))
    }

    func testBuiltInLayoutsIncludingEquivalentGridCannotBeSavedAgain() throws {
        let suite = "tidest.layout-templates.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LayoutTemplateStore(defaults: defaults)
        XCTAssertFalse(store.save(name: "Blank", root: .leaf(UUID())))
        for start in LayoutStartingPoint.allCases {
            XCTAssertFalse(store.save(name: start.rawValue, root: start.makeRegion()))
        }
        let columns = { LayoutRegion.split(UUID(), .columns, 0.5, .leaf(UUID()), .leaf(UUID())) }
        let grid = LayoutRegion.split(UUID(), .rows, 0.5, columns(), columns())
        XCTAssertFalse(store.save(name: "Grid split in a different order", root: grid))
        XCTAssertTrue(store.templates.isEmpty)
        XCTAssertNil(defaults.data(forKey: "multiWindowLayoutTemplates.v1"))
    }

    func testSuggestedNamesSkipExistingNamesAndRemainAvailableAfterRestart() throws {
        let suite = "tidest.layout-templates.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LayoutTemplateStore(defaults: defaults)
        let makeName = { (number: Int) in "Template \(number)" }
        XCTAssertEqual(store.suggestedName(using: makeName), "Template 1")
        for (name, ratio) in [("template 1", 0.6), ("Template 3", 0.7)] {
            XCTAssertTrue(store.save(name: name, root: .split(UUID(), .columns, ratio, .leaf(UUID()), .leaf(UUID()))))
        }
        XCTAssertEqual(store.suggestedName(using: makeName), "Template 2")
        XCTAssertEqual(LayoutTemplateStore(defaults: defaults).suggestedName(using: makeName), "Template 2")
        let first = try XCTUnwrap(store.templates.first)
        XCTAssertTrue(store.delete(first.id))
        XCTAssertEqual(store.suggestedName(using: makeName), "Template 1")
    }

    func testLegacyTemplatesMatchingBuiltInsRemainReadableAndCanBeRenamed() throws {
        let suite = "tidest.layout-templates.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = LayoutTemplate(name: "Old layout", root: LayoutStartingPoint.columns.makeRegion())
        defaults.set(try JSONEncoder().encode([legacy]), forKey: "multiWindowLayoutTemplates.v1")
        let store = LayoutTemplateStore(defaults: defaults)
        XCTAssertNil(store.errorKey)
        XCTAssertEqual(store.templates, [legacy])
        XCTAssertTrue(store.save(name: "Renamed layout", root: legacy.root, replacing: legacy.id))
        XCTAssertEqual(LayoutTemplateStore(defaults: defaults).templates.first?.name, "Renamed layout")
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

    func testQuickLayoutMenuEntryOnlyDisplaysItsShortcut() throws {
        let delegate = AppDelegate(permissions: PermissionStore(preview: true))
        let menu = delegate.makeStatusMenu()
        let item = try XCTUnwrap(menu.items.first { $0.accessibilityIdentifier() == "multiWindowLayoutShortcut" })
        XCTAssertNil(item.action)
        XCTAssertNil(item.target)
        XCTAssertFalse(item.isEnabled)
        XCTAssertEqual(item.keyEquivalent, "")
        let settings = AppSettings.shared
        let expectedTitle = settings.multiLayoutShortcut.map {
            settings.text("%@ · %@", settings.text("组合布局"), $0.symbolDisplayName)
        } ?? settings.text("组合布局")
        XCTAssertEqual(item.title, expectedTitle)
        XCTAssertFalse(menu.items.contains { $0.action == NSSelectorFromString("undoMultiWindowLayout") })
    }
}
