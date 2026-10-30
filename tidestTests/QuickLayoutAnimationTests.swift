import AppKit
import QuartzCore
import XCTest
@testable import tidest

@MainActor
final class QuickLayoutAnimationTests: XCTestCase {
    func testSelectionStartsAtTheTemplateBlockAndRemovesTheHighlightAfterLanding() async throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let controller = makeController()
        defer { controller.stop() }
        controller.showPreview()
        try await Task.sleep(for: .milliseconds(100))
        let picker = try XCTUnwrap(NSApp.keyWindow)
        let pickerFrame = picker.frame

        controller.choose(.right)
        XCTAssertFalse(controller.isPresented)
        XCTAssertFalse(picker.isVisible)
        let overlay = try XCTUnwrap(placementOverlay)
        XCTAssertTrue(overlay.ignoresMouseEvents)
        XCTAssertFalse(overlay.canBecomeKey)
        try await Task.sleep(for: .milliseconds(30))
        let region = try XCTUnwrap(overlay.contentView?.layer?.sublayers?.first)
        let flight = try XCTUnwrap(region.animation(forKey: "placement") as? CAAnimationGroup)
        let bounds = try XCTUnwrap(flight.animations?.compactMap { $0 as? CABasicAnimation }
            .first { $0.keyPath == "bounds" }?.fromValue as? NSValue).rectValue
        let center = try XCTUnwrap(flight.animations?.compactMap { $0 as? CABasicAnimation }
            .first { $0.keyPath == "position" }?.fromValue as? NSValue).pointValue
        let source = CGRect(x: center.x - bounds.width / 2 + overlay.frame.minX,
                            y: center.y - bounds.height / 2 + overlay.frame.minY,
                            width: bounds.width, height: bounds.height)
        XCTAssertTrue(pickerFrame.contains(source), "The flight must start inside the selected template")
        XCTAssertGreaterThan(source.midX, pickerFrame.midX, "Right-half selection is in the third column")
        XCTAssertEqual(source.width, 31, accuracy: 0.5)
        XCTAssertEqual(source.height, 32, accuracy: 0.5)
        let screen = try XCTUnwrap(NSScreen.screens.first { $0.visibleFrame == overlay.frame })
        let visible = screen.visibleFrame
        XCTAssertEqual(region.frame, CGRect(x: visible.width / 2, y: 0,
                                            width: visible.width / 2, height: visible.height))
        XCTAssertTrue(overlay.isVisible, "Do not remove the highlight while it is still moving")

        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(overlay.isVisible)
        XCTAssertNil(placementOverlay)
    }

    func testReopeningDuringTheFlightRemovesOldFeedbackAndKeepsTheNewPanel() async throws {
        let controller = makeController()
        defer { controller.stop() }
        controller.showPreview()
        try await Task.sleep(for: .milliseconds(100))
        controller.choose(.left)
        let oldOverlay = try XCTUnwrap(placementOverlay)

        controller.showPreview()
        XCTAssertFalse(oldOverlay.isVisible)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(controller.isPresented)
        XCTAssertTrue(NSApp.keyWindow?.isVisible == true)
        XCTAssertNil(placementOverlay, "An old completion must not revive its highlight")
    }

    func testConstrainedWindowEndsAtItsActualFrameAndKeepsTheExistingTip() async throws {
        let controller = makeController()
        defer { controller.stop() }
        controller.showPreview(constrained: true)
        try await Task.sleep(for: .milliseconds(100))
        controller.choose(.full)
        let overlay = try XCTUnwrap(placementOverlay)
        let region = try XCTUnwrap(overlay.contentView?.layer?.sublayers?.first)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(region.frame.width, min(900, overlay.frame.width * 0.72), accuracy: 0.5)
        XCTAssertEqual(region.frame.height, min(560, overlay.frame.height * 0.68), accuracy: 0.5)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(overlay.isVisible)
        XCTAssertTrue(NSApp.windows.contains { window in
            window.isVisible && window.frame.size == QuickLayoutTipView.panelSize
        })
    }

    private var placementOverlay: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue == "quickLayoutPlacement" }
    }

    private func makeController() -> QuickLayoutController {
        QuickLayoutController(settings: AppSettings(persistChanges: false),
                              statistics: UsageStatisticsStore(persistChanges: false))
    }
}
