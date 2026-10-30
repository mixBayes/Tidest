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

    func testReplacingAssignedStructureRequiresConfirmationAndCancelPreservesDraft() throws {
        let controller = try makeController()
        defer { controller.dismiss() }
        controller.present(preview: true)
        controller.request(.replace(LayoutStartingPoint.columns.makeRegion()))
        let id = try XCTUnwrap(controller.draft?.root.leafIDs.first)
        controller.selectRegion(id)
        controller.chooseWindow(try XCTUnwrap(controller.filteredWindows.first?.id))
        let before = controller.draft
        let replacement = LayoutStartingPoint.grid.makeRegion()
        controller.request(.replace(replacement))
        XCTAssertNotNil(controller.pendingEdit)
        XCTAssertEqual(controller.draft, before)
        controller.pendingEdit = nil
        XCTAssertEqual(controller.draft, before)
        controller.request(.replace(replacement))
        controller.confirmEdit()
        XCTAssertEqual(controller.draft?.root, replacement)
        XCTAssertTrue(controller.draft?.assignments.isEmpty == true)
        XCTAssertTrue(controller.outcomes.isEmpty)
        XCTAssertFalse(controller.undoAvailable)
    }

    func testSplittingAssignedRegionKeepsItsWindowWithoutConfirmationAndCanBeUndone() throws {
        let cases: [(LayoutSplitEdge, Int)] = [(.left, 0), (.right, 1), (.top, 0), (.bottom, 1)]
        for (edge, emptyIndex) in cases {
            let controller = try makeController()
            defer { controller.dismiss() }
            controller.present(preview: true)
            let ids = try XCTUnwrap(controller.draft?.root.leafIDs)
            let choices = controller.windows
            for (region, choice) in zip(ids, choices) {
                controller.selectRegion(region)
                controller.chooseWindow(choice.id)
            }
            controller.selectRegion(ids[0], openPicker: false)
            let before = controller.draft
            controller.splitRegion(ids[0], edge: edge)

            XCTAssertNil(controller.pendingEdit, edge.rawValue)
            XCTAssertFalse(controller.choosingWindow)
            let children = try XCTUnwrap(controller.draft?.root.region(ids[0])?.leafIDs)
            XCTAssertEqual(children.count, 2)
            XCTAssertNil(controller.draft?.assignments[children[emptyIndex]])
            XCTAssertEqual(controller.draft?.assignments[children[1 - emptyIndex]], choices[0].id)
            XCTAssertEqual(controller.draft?.assignments[ids[1]], choices[1].id)
            XCTAssertFalse(controller.canApply, "The newly added region still needs a window")
            XCTAssertTrue(controller.outcomes.isEmpty)
            XCTAssertFalse(controller.undoAvailable)
            controller.undoDraft()
            XCTAssertEqual(controller.draft, before)
            XCTAssertTrue(controller.canApply)
        }
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

    func testOverlayCoversTheTargetScreenAndStartsWithEditableColumns() throws {
        let controller = try makeController()
        controller.present(preview: true)
        defer { controller.dismiss() }
        let target = try XCTUnwrap(controller.target)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "multiWindowLayoutPanel" && $0.isVisible })
        XCTAssertEqual(panel.frame, target.frame)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertFalse(panel.styleMask.contains(.titled))
        XCTAssertEqual(controller.draft?.root.leafIDs.count, 2)
        XCTAssertFalse(controller.choosingWindow)
    }

    func testOverlayAndWindowCoordinatesShareTheUsableAreaOnOffsetScreens() {
        for frame in [CGRect(x: -1440, y: 200, width: 1440, height: 900),
                      CGRect(x: 1728, y: -400, width: 900, height: 1440)] {
            let visible = CGRect(x: frame.minX + 60, y: frame.minY + 30, width: frame.width - 60, height: frame.height - 54)
            let display = LayoutDisplay(id: 1, name: "Test", frame: frame, visibleFrame: visible, scale: 2, primaryTop: 1117)
            let local = display.overlayLayoutFrame
            XCTAssertEqual(local.minX + frame.minX, display.layoutArea.minX)
            XCTAssertEqual(local.minY + display.primaryTop - frame.maxY, display.layoutArea.minY)
            XCTAssertEqual(local.size, display.layoutArea.size)
        }
    }

    func testEdgeSplitTargetsItsOwnRegionAndKeepsTheOtherRegionsAssignments() throws {
        let controller = try makeController()
        controller.present(preview: true)
        defer { controller.dismiss() }
        let leaves = try XCTUnwrap(controller.draft?.root.leafIDs)
        controller.selectRegion(leaves[0])
        let choice = try XCTUnwrap(controller.windows.first)
        controller.chooseWindow(choice.id)
        controller.splitRegion(leaves[1], edge: .bottom)
        XCTAssertNil(controller.pendingEdit)
        XCTAssertFalse(controller.choosingWindow)
        XCTAssertEqual(controller.draft?.assignments[leaves[0]], choice.id)
        XCTAssertEqual(controller.draft?.root.region(leaves[1])?.leafIDs.count, 2)
    }

    func testDeletingAssignedRegionClosesPickerAndCanBeUndoneWithoutMovingWindows() throws {
        let controller = try makeController()
        controller.present(preview: true)
        defer { controller.dismiss() }
        let ids = try XCTUnwrap(controller.draft?.root.leafIDs)
        for (region, choice) in zip(ids, controller.windows) {
            controller.selectRegion(region)
            controller.chooseWindow(choice.id)
        }
        controller.selectRegion(ids[0])
        let before = controller.draft
        controller.deleteRegion(ids[0])
        XCTAssertFalse(controller.choosingWindow)
        XCTAssertNil(controller.pendingEdit)
        XCTAssertEqual(controller.draft?.root.leafIDs, [ids[1]])
        XCTAssertTrue(controller.canApply)
        XCTAssertTrue(controller.outcomes.isEmpty)
        XCTAssertFalse(controller.undoAvailable)
        controller.undoDraft()
        XCTAssertEqual(controller.draft, before)
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
