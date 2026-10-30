import AppKit
import Combine
import XCTest
@testable import tidest

final class TiledMouseSelectionTests: XCTestCase {
    @MainActor
    func testMousePreselectionKeepsPanelOpenAndKeyboardCanContinue() {
        let controller = makeController()
        controller.showPreview(count: 5)
        defer { controller.stop() }
        controller.move(1)
        let target = controller.windows[0].id

        controller.hoverWindow(target)

        XCTAssertEqual(controller.selection.index, 0)
        XCTAssertTrue(controller.selectionWasMovedByMouse)
        XCTAssertTrue(controller.isPresented)
        XCTAssertTrue(NSApp.windows.contains { $0.title == "Tidest 切换窗口" && $0.isVisible && $0.acceptsMouseMovedEvents })
        controller.move(1)
        XCTAssertEqual(controller.selection.index, 1)
        XCTAssertFalse(controller.selectionWasMovedByMouse)
        XCTAssertTrue(controller.isPresented)
    }

    @MainActor
    func testCarouselIgnoresMousePreselection() {
        let controller = makeController(mode: .carousel)
        controller.showPreview(count: 5)
        defer { controller.stop() }

        controller.hoverWindow(controller.windows[2].id)

        XCTAssertEqual(controller.selection.index, 0)
        XCTAssertFalse(controller.selectionWasMovedByMouse)
        XCTAssertTrue(controller.isPresented)
    }

    @MainActor
    func testUnknownAndRepeatedIDsDoNotPublishOrOverrideKeyboardSelection() {
        let controller = makeController()
        controller.showPreview(count: 5)
        defer { controller.stop() }
        var changes = 0
        let subscription = controller.$selection.dropFirst().sink { _ in changes += 1 }
        defer { subscription.cancel() }

        controller.hoverWindow(UUID())
        controller.hoverWindow(controller.windows[0].id)
        XCTAssertEqual(changes, 0)
        XCTAssertFalse(controller.selectionWasMovedByMouse)

        controller.hoverWindow(controller.windows[1].id)
        XCTAssertEqual(changes, 1)
        controller.hoverWindow(controller.windows[1].id)
        XCTAssertEqual(changes, 1)

        controller.move(1)
        XCTAssertEqual(changes, 2)
        controller.hoverWindow(controller.windows[2].id)
        XCTAssertEqual(changes, 2)
        XCTAssertFalse(controller.selectionWasMovedByMouse)
    }

    @MainActor
    func testStableMouseIDFindsTheCurrentWindowAfterListReorders() {
        let controller = makeController()
        controller.showPreview(count: 5)
        defer { controller.stop() }
        let target = controller.windows[0].id
        controller.move(1)
        controller.replaceWindowSnapshot(Array(controller.windows.reversed()))

        controller.hoverWindow(target)

        XCTAssertEqual(controller.selection.index, 4)
        XCTAssertEqual(controller.windows[controller.selection.index].id, target)
        XCTAssertTrue(controller.isPresented)

        controller.replaceWindowSnapshot(controller.windows.filter { $0.id != target })
        let remainingSelection = controller.windows[controller.selection.index].id
        controller.hoverWindow(target)
        controller.chooseWindow(target)
        XCTAssertEqual(controller.windows[controller.selection.index].id, remainingSelection)
        XCTAssertTrue(controller.isPresented)
    }

    @MainActor
    func testStableClickIDCommitsTheCorrectWindowAfterListReorders() {
        let controller = makeController()
        controller.showPreview(count: 5)
        defer { controller.stop() }
        let target = controller.windows[0].id
        controller.replaceWindowSnapshot(Array(controller.windows.reversed()))
        var chosenID: UUID?
        let subscription = controller.$selection.dropFirst().sink { selection in
            if controller.windows.indices.contains(selection.index) {
                chosenID = controller.windows[selection.index].id
            }
        }
        defer { subscription.cancel() }

        controller.chooseWindow(target)

        XCTAssertEqual(chosenID, target)
        XCTAssertFalse(controller.isPresented)
    }

    @MainActor
    func testMouseMoveUsesScrolledDocumentCoordinatesAndIgnoresGapsAndClippedImages() throws {
        let controller = makeController()
        controller.showPreview(count: 8)
        defer { controller.stop() }
        let windows = controller.windows
        let viewport = CGSize(width: 640, height: 300)
        let layout = WindowTileLayout(viewportSize: viewport, aspectRatios: Array(repeating: 1.6, count: windows.count))
        let scroll = VerticalTileScrollView(frame: CGRect(origin: .zero, size: viewport))
        let document = MouseTestDocumentView(frame: CGRect(origin: .zero, size: layout.contentSize))
        scroll.documentView = document
        scroll.selectAtPoint = { point in
            if let index = windows.indices.first(where: { layout.frame(for: $0).contains(point) }) {
                controller.hoverWindow(windows[index].id)
            }
        }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: viewport), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        scroll.layoutSubtreeIfNeeded()
        scroll.updateTrackingAreas()
        XCTAssertTrue(scroll.trackingAreas.contains { $0.options.contains(.mouseMoved) && $0.options.contains(.activeAlways) })

        func moveTo(_ point: CGPoint) throws {
            let location = document.convert(point, to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: 1,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
            scroll.mouseMoved(with: event)
        }

        let first = layout.frame(for: 0)
        try moveTo(CGPoint(x: first.midX, y: first.midY))
        XCTAssertEqual(controller.selection.index, 0)
        let seventh = layout.frame(for: 6)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: layout.verticalOffset(revealing: 6, currentOffset: 0)))
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.layoutSubtreeIfNeeded()
        scroll.updateTrackingAreas()
        // Scrolling or rebuilding tracking areas under a stationary pointer
        // must not manufacture a mouse move and change selection.
        XCTAssertEqual(controller.selection.index, 0)

        try moveTo(CGPoint(x: seventh.midX, y: seventh.midY))
        XCTAssertEqual(controller.selection.index, 6)
        XCTAssertTrue(controller.isPresented)
        try moveTo(CGPoint(x: seventh.midX, y: seventh.maxY + WindowTileLayout.gap / 2))
        XCTAssertEqual(controller.selection.index, 6)
        try moveTo(CGPoint(x: first.midX, y: first.midY))
        XCTAssertEqual(controller.selection.index, 6)
    }

    @MainActor
    func testOrdinaryWheelScrollsDownWithoutPointerCallbackOrHorizontalMovement() throws {
        let viewport = CGSize(width: 640, height: 300)
        let layout = WindowTileLayout(viewportSize: viewport, aspectRatios: Array(repeating: 1.6, count: 20))
        let scroll = VerticalTileScrollView(frame: CGRect(origin: .zero, size: viewport))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.documentView = MouseTestDocumentView(frame: CGRect(origin: .zero, size: layout.contentSize))
        scroll.selectAtPoint = { _ in XCTFail("Scrolling must not manufacture pointer movement") }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: viewport), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        scroll.layoutSubtreeIfNeeded()
        let source = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -5, wheel2: 0, wheel3: 0))
        scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: source)))
        let scrolled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            scroll.contentView.bounds.minY > 0
        }, object: scroll)
        // Native scrolling and predicate checks run asynchronously. A one-second
        // deadline can expire just before the next check observes the movement.
        XCTAssertEqual(XCTWaiter.wait(for: [scrolled], timeout: 2), .completed)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        XCTAssertEqual(scroll.contentView.bounds.minX, 0)
    }

    @MainActor
    private func makeController(mode: DisplayMode = .tiled) -> SwitcherController {
        let suite = "TiledMouseSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults, preferredLanguages: { ["zh-Hans"] })
        settings.displayMode = mode
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return SwitcherController(settings: settings)
    }
}

private final class MouseTestDocumentView: NSView {
    override var isFlipped: Bool { true }
}
