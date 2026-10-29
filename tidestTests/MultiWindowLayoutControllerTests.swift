import AppKit
import XCTest
@testable import tidest

/// macOS integration with the real panel and sample windows; never invokes AX writes.
@MainActor
final class MultiWindowLayoutControllerTests: XCTestCase {
    func testPreviewAssignmentsRequireExplicitApplyAndUndoHasASeparateOperation() async throws {
        let controller = try makeController()
        defer { controller.dismiss() }
        controller.present(preview: true)
        controller.request(.replace(LayoutStartingPoint.columns.makeRegion()))
        let ids = try XCTUnwrap(controller.draft?.root.leafIDs)
        let choices = controller.filteredWindows
        XCTAssertEqual(choices.count, 8)
        controller.selectRegion(ids[0])
        controller.chooseWindow(choices[0].id)
        XCTAssertTrue(controller.isPresented)
        XCTAssertFalse(controller.canApply)
        XCTAssertTrue(controller.outcomes.isEmpty)
        controller.selectRegion(ids[1])
        controller.chooseWindow(choices[1].id)
        XCTAssertTrue(controller.canApply)
        XCTAssertTrue(controller.outcomes.isEmpty)
        XCTAssertFalse(controller.undoAvailable)
        controller.apply()
        await finish(controller)
        XCTAssertFalse(controller.isPresented, "A completed layout closes its preview")
        XCTAssertEqual(controller.outcomes.map(\.status), [.placed, .placed])
        XCTAssertTrue(controller.undoAvailable)
        controller.presentUndo()
        await finish(controller)
        XCTAssertEqual(controller.outcomes.map(\.status), [.restored, .restored])
        XCTAssertFalse(controller.undoAvailable)
    }

    func testEditingAssignedStructureRequiresConfirmationAndCancelPreservesDraft() throws {
        let controller = try makeController()
        defer { controller.dismiss() }
        controller.present(preview: true)
        controller.request(.replace(LayoutStartingPoint.columns.makeRegion()))
        let id = try XCTUnwrap(controller.draft?.root.leafIDs.first)
        controller.selectRegion(id)
        controller.chooseWindow(try XCTUnwrap(controller.filteredWindows.first?.id))
        let before = controller.draft
        controller.request(.split(.rows))
        XCTAssertNotNil(controller.pendingEdit)
        XCTAssertEqual(controller.draft, before)
        controller.pendingEdit = nil
        XCTAssertEqual(controller.draft, before)
        controller.request(.split(.rows))
        controller.confirmEdit()
        XCTAssertEqual(controller.draft?.root.leafIDs.count, 3)
        XCTAssertTrue(controller.draft?.assignments.isEmpty == true)
        XCTAssertTrue(controller.outcomes.isEmpty)
        XCTAssertFalse(controller.undoAvailable)
    }

    func testAWindowOccupiedByAnotherRegionIsDisabledAndCannotBeChosen() throws {
        let controller = try makeController()
        defer { controller.dismiss() }
        controller.present(preview: true)
        controller.request(.replace(LayoutStartingPoint.columns.makeRegion()))
        let ids = try XCTUnwrap(controller.draft?.root.leafIDs)
        let choice = try XCTUnwrap(controller.filteredWindows.first)
        controller.selectRegion(ids[0])
        controller.chooseWindow(choice.id)
        controller.selectRegion(ids[1])
        XCTAssertNotNil(controller.assignedRegionNumber(for: choice.id))
        controller.chooseWindow(choice.id)
        XCTAssertNil(controller.draft?.assignments[ids[1]])
        XCTAssertTrue(controller.choosingWindow)
    }

    private func makeController() throws -> MultiWindowLayoutController {
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a macOS display session")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "tidest.multi-layout.tests.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults, persistChanges: false)
        return MultiWindowLayoutController(settings: settings,
            statistics: UsageStatisticsStore(defaults: defaults, persistChanges: false))
    }

    private func finish(_ controller: MultiWindowLayoutController) async {
        let deadline = Date().addingTimeInterval(3)
        while controller.isApplying && Date() < deadline { await Task.yield() }
        XCTAssertFalse(controller.isApplying)
    }
}
