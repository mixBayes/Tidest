import AppKit
import XCTest
@testable import tidest

@MainActor
final class PinnedLayoutCombinationTests: XCTestCase {
    func testLegacyWindowsMigrateAndMixedShelfOrderSurvivesRestart() throws {
        let suite = "com.mixbayes.tidest.tests.combinations.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = savedWindow()
        let second = savedWindow()
        defaults.set(try JSONEncoder().encode([first, second]), forKey: "savedPinnedWindows")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(try settings.loadSavedPinnedItems(), [.window(first), .window(second)])
        let combination = makeCombination()
        try settings.savePinnedWindows([PinnedWindowEntry(saved: second),
            PinnedWindowEntry(combination: combination), PinnedWindowEntry(saved: first)])
        XCTAssertEqual(try AppSettings(defaults: defaults).loadSavedPinnedItems(),
                       [.window(second), .combination(combination), .window(first)])
        let restored = PinnedWindowEntry(savedItem: .combination(combination))
        XCTAssertTrue(restored.isRetained)
        XCTAssertFalse(restored.isClosed)
        XCTAssertNil(restored.window)
        XCTAssertEqual(restored.combination?.windows, combination.windows)
        XCTAssertEqual(restored.frame.size, CGSize(width: 1200, height: 800))
        try settings.savePinnedWindows([PinnedWindowEntry(saved: first)])
        XCTAssertEqual(try AppSettings(defaults: defaults).loadSavedPinnedItems(), [.window(first)])
    }

    func testIncompleteCombinationIsRejectedWithoutReplacingSavedItems() throws {
        let suite = "com.mixbayes.tidest.tests.combinations.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let original = makeCombination()
        try settings.savePinnedWindows([PinnedWindowEntry(combination: original)])
        var incomplete = original
        incomplete.windows.removeValue(forKey: original.root.leafIDs[0])
        XCTAssertFalse(incomplete.isValid)
        XCTAssertThrowsError(try settings.savePinnedWindows([PinnedWindowEntry(combination: incomplete)]))
        XCTAssertEqual(try settings.loadSavedPinnedItems(), [.combination(original)])
        defaults.set(Data("broken".utf8), forKey: "savedPinnedItems.v1")
        XCTAssertThrowsError(try settings.savePinnedWindows([]))
        XCTAssertEqual(defaults.data(forKey: "savedPinnedItems.v1"), Data("broken".utf8))
    }

    func testRestorationKeepsCellAssignmentsAndUsesTheTargetDisplaysUsableArea() {
        let combination = makeCombination()
        let leaves = combination.root.leafIDs
        let left = window(id: combination.windows[leaves[0]]!.id)
        let right = window(id: combination.windows[leaves[1]]!.id)
        let display = LayoutDisplay(id: 7, name: "Offset", frame: CGRect(x: -1440, y: 200, width: 1440, height: 900),
            visibleFrame: CGRect(x: -1440, y: 220, width: 1440, height: 850), scale: 2, primaryTop: 1117)
        let choices = [leaves[0]: LayoutWindowChoice(window: right, processLaunchDate: nil),
                       leaves[1]: LayoutWindowChoice(window: left, processLaunchDate: nil)]
        let requests = combination.requests(using: choices, on: display)
        XCTAssertEqual(requests.map { $0.0.id }, [right.id, left.id])
        XCTAssertEqual(requests[0].1.minX, display.layoutArea.minX)
        XCTAssertEqual(requests[0].1.minY, display.layoutArea.minY)
        XCTAssertEqual(requests[0].1.width, display.layoutArea.width * 0.6)
        XCTAssertEqual(requests[1].1.minX, requests[0].1.maxX)
        XCTAssertEqual(requests[1].1.maxX, display.layoutArea.maxX)
        let partial = combination.requests(using: [leaves[1]: choices[leaves[1]]!], on: display)
        XCTAssertEqual(partial.count, 1)
        XCTAssertEqual(partial[0].1, requests[1].1, "A missing member must not shift another window into its cell")
    }

    func testSaveRequiresEveryCellAndProducesOnePinnedShelfItemWithoutApplying() async throws {
        let settings = AppSettings(persistChanges: false)
        let layout = MultiWindowLayoutController(settings: settings)
        let dock = PinnedWindowsController(settings: settings)
        layout.onSaveCombination = { try await dock.saveCombination($0, preview: $1) }
        defer { layout.dismiss(); dock.stop() }
        layout.present(preview: true)
        let leaves = try XCTUnwrap(layout.draft?.root.leafIDs)
        XCTAssertFalse(layout.canSaveCombination)
        layout.saveCombination()
        XCTAssertFalse(layout.isSavingCombination)
        layout.selectRegion(leaves[0])
        layout.chooseWindow(layout.windows[0].id)
        XCTAssertFalse(layout.canSaveCombination)
        layout.selectRegion(leaves[1])
        layout.chooseWindow(layout.windows[1].id)
        XCTAssertTrue(layout.canSaveCombination)
        layout.saveCombination()
        XCTAssertTrue(layout.isSavingCombination)
        XCTAssertFalse(layout.canApply)
        XCTAssertFalse(layout.canSaveCombination)
        for _ in 0..<120 where layout.isSavingCombination { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(layout.isSavingCombination)
        XCTAssertNil(layout.messageKey)
        XCTAssertTrue(layout.isPresented)
        XCTAssertTrue(layout.outcomes.isEmpty)
        let shelf = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentView is PinnedWindowsView }?.contentView)
        let controls = allSubviews(of: shelf)
        XCTAssertEqual(controls.filter { $0.accessibilityIdentifier().hasPrefix("pinnedOpen-") }.count, 1)
        let pin = try XCTUnwrap(controls.first { $0.accessibilityIdentifier().hasPrefix("pinnedRetain-") } as? NSButton)
        XCTAssertEqual(pin.state, .on)
        let open = try XCTUnwrap(controls.first { $0.accessibilityIdentifier().hasPrefix("pinnedOpen-") } as? NSButton)
        dock.onActivateCombination = { layout.dismiss() }
        open.performClick(nil)
        XCTAssertFalse(layout.isPresented, "Restoring a group must reveal its windows instead of leaving the editor over them")
        try await Task.sleep(for: .milliseconds(100))
        pin.performClick(nil)
        XCTAssertEqual(allSubviews(of: shelf).filter { $0.accessibilityIdentifier().hasPrefix("pinnedOpen-") }.count, 0)
    }

    func testSaveFailureKeepsTheDraftEditableAndAllowsRetry() async throws {
        let layout = MultiWindowLayoutController(settings: AppSettings(persistChanges: false))
        defer { layout.dismiss() }
        layout.present(preview: true)
        for (leaf, choice) in zip(layout.draft!.root.leafIDs, layout.windows) {
            layout.selectRegion(leaf)
            layout.chooseWindow(choice.id)
        }
        let original = layout.draft
        layout.onSaveCombination = { _, _ in throw PinnedWindowLaunchError.automationDenied }
        layout.saveCombination()
        for _ in 0..<20 where layout.isSavingCombination { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(layout.draft, original)
        XCTAssertEqual(layout.messageKey, PinnedWindowLaunchError.automationDenied.localizedDescription)
        XCTAssertTrue(layout.canSaveCombination)
        XCTAssertTrue(layout.canApply)
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allSubviews(of: $0) }
    }

    private func makeCombination() -> SavedPinnedCombination {
        let root = LayoutRegion.split(UUID(), .columns, 0.6, .leaf(UUID()), .leaf(UUID()))
        return SavedPinnedCombination(name: "Work", root: root,
            windows: [root.leafIDs[0]: savedWindow(), root.leafIDs[1]: savedWindow()],
            displayID: 7, width: 1200, height: 800)
    }

    private func savedWindow() -> SavedPinnedWindow {
        SavedPinnedWindow(id: UUID(), applicationBundleIdentifier: "com.example.app",
            applicationURL: "file:///Applications/Example.app/", applicationName: "Example", title: "Document",
            width: 800, height: 600, target: .application)
    }

    private func window(id: UUID) -> WindowItem {
        var window = WindowItem(element: AXUIElementCreateApplication(0), processID: 0, applicationName: "Example",
            icon: nil, title: "Document", frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            minimized: false, captureID: nil, stackOrder: 0)
        window.id = id
        return window
    }
}
