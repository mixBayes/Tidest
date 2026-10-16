import AppKit
import XCTest
@testable import tidest

final class PinnedWindowsControllerTests: XCTestCase {
    @MainActor
    func testBothDockSidesCanBeReachedOnEveryDisplay() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let arrangements = [
            [primary, CGRect(x: 1440, y: -200, width: 1920, height: 1080)],
            [primary, CGRect(x: -1920, y: 180, width: 1920, height: 1080)],
            [primary, CGRect(x: 0, y: 900, width: 1440, height: 2560)],
            [primary, CGRect(x: -300, y: -1080, width: 1920, height: 1080)],
            [primary, CGRect(x: -1080, y: -400, width: 1080, height: 1920),
             CGRect(x: 1440, y: 300, width: 2560, height: 1440)]
        ]

        for frames in arrangements {
            for side in [PinnedDockSide.left, .right] {
                for (index, frame) in frames.enumerated() {
                    let point = edgePoint(in: frame, side: side)
                    XCTAssertEqual(PinnedWindowsController.edgeScreenIndex(at: point, frames: frames, side: side),
                                   index, "Missed \(side) edge of display \(index) in \(frames)")
                }
            }
        }
    }

    @MainActor
    func testVerticallyAdjacentDisplaysDoNotShareTheSameEdgePoint() {
        let frames = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                      CGRect(x: 0, y: 900, width: 1440, height: 1080)]
        for side in [PinnedDockSide.left, .right] {
            let positions: [CGFloat] = side == .left ? [0, 1, 3] : [1437, 1439, 1440]
            for x in positions {
                XCTAssertEqual(PinnedWindowsController.edgeScreenIndex(at: CGPoint(x: x, y: 899),
                    frames: frames, side: side), 0)
                XCTAssertEqual(PinnedWindowsController.edgeScreenIndex(at: CGPoint(x: x, y: 900),
                    frames: frames, side: side), 1)
                XCTAssertEqual(PinnedWindowsController.edgeScreenIndex(at: CGPoint(x: x, y: 1980),
                    frames: frames, side: side), 1)
            }
        }
    }

    @MainActor
    func testDockIgnoresTheOppositeEdgeInteriorsAndSpaceBetweenDisplays() {
        let frames = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                      CGRect(x: 1600, y: 300, width: 1920, height: 1080)]
        for side in [PinnedDockSide.left, .right] {
            for frame in frames {
                XCTAssertNil(PinnedWindowsController.edgeScreenIndex(
                    at: edgePoint(in: frame, side: side.opposite), frames: frames, side: side))
                XCTAssertNil(PinnedWindowsController.edgeScreenIndex(
                    at: CGPoint(x: frame.midX, y: frame.midY), frames: frames, side: side))
                let edge = edgePoint(in: frame, side: side)
                XCTAssertNil(PinnedWindowsController.edgeScreenIndex(
                    at: CGPoint(x: edge.x, y: frame.minY - 1), frames: frames, side: side))
            }
            XCTAssertNil(PinnedWindowsController.edgeScreenIndex(
                at: CGPoint(x: 1500, y: 500), frames: frames, side: side))
            XCTAssertNil(PinnedWindowsController.edgeScreenIndex(at: .zero, frames: [], side: side))
        }
    }

    @MainActor
    func testRemovedOrRearrangedDisplaysNoLongerAcceptTheirOldEdge() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let secondary = CGRect(x: -1920, y: -180, width: 1920, height: 1080)
        let rearranged = secondary.offsetBy(dx: 3360, dy: 1080)
        for side in [PinnedDockSide.left, .right] {
            let oldEdge = edgePoint(in: secondary, side: side)
            XCTAssertEqual(PinnedWindowsController.edgeScreenIndex(
                at: oldEdge, frames: [primary, secondary], side: side), 1)
            XCTAssertNil(PinnedWindowsController.edgeScreenIndex(at: oldEdge, frames: [primary], side: side))
            XCTAssertNil(PinnedWindowsController.edgeScreenIndex(
                at: oldEdge, frames: [primary, rearranged], side: side))
            XCTAssertEqual(PinnedWindowsController.edgeScreenIndex(
                at: edgePoint(in: rearranged, side: side), frames: [primary, rearranged], side: side), 1)
        }
    }

    @MainActor
    func testPointerReopensAndMovesTheSameShelfAcrossConnectedDisplays() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "com.mixbayes.tidest.tests.multidisplay.\(UUID())"))
        let settings = AppSettings(defaults: defaults, persistChanges: false)
        let controller = PinnedWindowsController(settings: settings)
        controller.showPreview(count: 3)
        defer { controller.stop() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.contentView is PinnedWindowsView })
        let shelf = try XCTUnwrap(panel.contentView as? PinnedWindowsView)
        let entryIDs = openingIDs(in: shelf)
        XCTAssertEqual(entryIDs.count, 3)
        let screens = NSScreen.screens
        XCTAssertFalse(screens.isEmpty)

        for side in [PinnedDockSide.left, .right] {
            settings.pinnedDockSide = side
            controller.cancelInteraction(animated: false)
            for screen in screens + screens.reversed() {
                // Clear Escape's edge latch, then exercise the ordinary
                // pointer path both while closed and while already open.
                controller.updatePointer(at: CGPoint(x: screen.frame.midX, y: screen.frame.midY))
                controller.updatePointer(at: edgePoint(in: screen.frame, side: side))
                XCTAssertTrue(panel.isVisible)
                XCTAssertTrue(panel.contentView === shelf)
                XCTAssertEqual(openingIDs(in: shelf), entryIDs)
                XCTAssertEqual(panel.frame.minX,
                    side == .left ? screen.frame.minX : screen.frame.maxX - panel.frame.width, accuracy: 0.01)
                XCTAssertEqual(panel.frame.minY, screen.visibleFrame.minY, accuracy: 0.01)
                XCTAssertEqual(panel.frame.height, screen.visibleFrame.height, accuracy: 0.01)
                XCTAssertTrue(screen.frame.contains(panel.frame))
            }
        }
    }

    private func edgePoint(in frame: CGRect, side: PinnedDockSide) -> CGPoint {
        CGPoint(x: side == .left ? frame.minX + 1 : frame.maxX - 1, y: frame.midY)
    }

    @MainActor
    private func openingIDs(in view: NSView) -> Set<String> {
        var ids = Set<String>()
        let id = view.accessibilityIdentifier()
        if id.hasPrefix("pinnedOpen-") { ids.insert(id) }
        for subview in view.subviews { ids.formUnion(openingIDs(in: subview)) }
        return ids
    }
}
