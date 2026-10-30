import AppKit
import ApplicationServices
import Carbon
import XCTest
@testable import tidest

final class WindowScrollTests: XCTestCase {
    func testTouchSwipeWaitsForHorizontalMovementAndMovesOnlyOnce() {
        var scroll = WindowScroll()
        XCTAssertEqual(scroll.direction(for: event(x: 5, phase: .began)), 0)
        XCTAssertEqual(scroll.direction(for: event(x: 10, phase: .changed)), 0)
        XCTAssertEqual(scroll.direction(for: event(x: 15, phase: .changed)), 1)
        XCTAssertEqual(scroll.direction(for: event(x: 100, phase: .changed)), 0)
        XCTAssertEqual(scroll.direction(for: event(x: -100, phase: .changed)), 0)
        XCTAssertEqual(scroll.direction(for: event(phase: .ended)), 0)
        XCTAssertEqual(scroll.direction(for: event(x: -30, phase: .began)), -1)
    }

    func testMagicMouseSwipeDoesNotRequireMayBegin() {
        var scroll = WindowScroll()
        XCTAssertEqual(scroll.direction(for: event(x: 30, phase: .began)), 1)
        XCTAssertEqual(scroll.direction(for: event(phase: .ended)), 0)
        XCTAssertEqual(scroll.direction(for: event(x: -30, phase: .began)), -1)
    }

    func testVerticalAndMostlyVerticalTouchMovementDoesNotSelect() {
        var scroll = WindowScroll()
        XCTAssertEqual(scroll.direction(for: event(x: 2, y: 100, phase: .began)), 0)
        XCTAssertEqual(scroll.direction(for: event(x: 30, y: 100, phase: .changed)), 0)
        XCTAssertEqual(scroll.direction(for: event(phase: .ended)), 0)
        XCTAssertEqual(scroll.direction(for: event(x: -30, y: 3, phase: .began)), -1)
    }

    func testMomentumCannotMoveOrContributeToTheNextSwipe() {
        var scroll = WindowScroll()
        XCTAssertEqual(scroll.direction(for: event(x: 10, phase: .began)), 0)
        XCTAssertEqual(scroll.direction(for: event(phase: .ended)), 0)
        for phase: NSEvent.Phase in [.began, .changed, .ended] {
            XCTAssertEqual(scroll.direction(for: event(x: 100, momentum: phase)), 0)
        }
        XCTAssertEqual(scroll.direction(for: event(x: 20, phase: .began)), 0)
        XCTAssertEqual(scroll.direction(for: event(x: 10, phase: .changed)), 1)
    }

    func testCancelledGestureAndSessionResetDiscardPartialMovement() {
        var scroll = WindowScroll()
        XCTAssertEqual(scroll.direction(for: event(x: 20, phase: .began)), 0)
        XCTAssertEqual(scroll.direction(for: event(x: 100, phase: .cancelled)), 0)
        XCTAssertEqual(scroll.direction(for: event(x: 20, phase: .began)), 0)
        scroll.reset()
        XCTAssertEqual(scroll.direction(for: event(x: 20, phase: .changed)), 0)
        XCTAssertEqual(scroll.direction(for: event(x: 10, phase: .changed)), 1)
    }

    func testOrdinaryWheelSelectsByVerticalDirectionAndIgnoresHorizontalWheel() {
        var scroll = WindowScroll()
        XCTAssertEqual(scroll.direction(for: event(y: -1, precise: false)), 1)
        XCTAssertEqual(scroll.direction(for: event(y: -8, precise: false)), 1)
        XCTAssertEqual(scroll.direction(for: event(y: 1, precise: false)), -1)
        XCTAssertEqual(scroll.direction(for: event(x: 3, precise: false)), 0)
        XCTAssertEqual(scroll.direction(for: event(x: -3, y: 1, precise: false)), 0)
        XCTAssertEqual(scroll.direction(for: event(precise: false)), 0)
    }

    func testPreciseScrollWithoutAGesturePhaseDoesNotImpersonateATouchSwipe() {
        var scroll = WindowScroll()
        XCTAssertEqual(scroll.direction(for: event(x: 100)), 0)
        XCTAssertEqual(scroll.direction(for: event(y: -100)), 0)
        XCTAssertEqual(scroll.direction(for: event(x: 30, phase: .began)), 1)
    }

    func testNaturalScrollingDoesNotReverseThePhysicalDirections() {
        var scroll = WindowScroll()
        XCTAssertEqual(scroll.direction(for: TestScrollEvent(event(x: -30, phase: .began), inverted: true)), 1)
        XCTAssertEqual(scroll.direction(for: event(phase: .ended)), 0)
        XCTAssertEqual(scroll.direction(for: TestScrollEvent(event(x: 30, phase: .began), inverted: true)), -1)
        XCTAssertEqual(scroll.direction(for: TestScrollEvent(event(y: 1, precise: false), inverted: true)), 1)
        XCTAssertEqual(scroll.direction(for: TestScrollEvent(event(y: -1, precise: false), inverted: true)), -1)
    }

    @MainActor
    func testPanelReceivesWheelAndTouchEventsWithoutCommittingOrChangingKeyboardSelection() throws {
        let controller = makeCarouselController()
        controller.showPreview(count: 3)
        defer { controller.stop() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "Tidest 切换窗口" && $0.isVisible })

        func send(_ event: NSEvent) {
            NSApp.sendEvent(TestScrollEvent(event, window: panel, windowNumber: panel.windowNumber))
        }

        XCTAssertEqual(controller.selection.index, 0)
        send(event(y: -1, precise: false))
        XCTAssertEqual(controller.selection.index, 1)
        send(event(x: 30, phase: .began))
        XCTAssertEqual(controller.selection.index, 2)
        send(event(x: 100, phase: .changed))
        send(event(x: 100, momentum: .began))
        XCTAssertEqual(controller.selection.index, 2)
        XCTAssertTrue(controller.isPresented)

        // A scroll for another window must not change the switcher's selection.
        let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        NSApp.sendEvent(TestScrollEvent(event(y: -1, precise: false), window: other, windowNumber: other.windowNumber))
        XCTAssertEqual(controller.selection.index, 2)

        let tab = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 1, windowNumber: panel.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: UInt16(kVK_Tab)))
        NSApp.sendEvent(tab)
        XCTAssertEqual(controller.selection.index, 0)
        XCTAssertTrue(controller.isPresented)
    }

    @MainActor
    func testScrollingUsesExistingLoopSelectionAndDismissClearsPartialSwipe() {
        let controller = makeCarouselController()
        let windows = (0..<3).map { index in
            WindowItem(element: AXUIElementCreateApplication(42), processID: 42, applicationName: "Finder", icon: nil, title: "窗口 \(index)", frame: CGRect(x: 0, y: 0, width: 800, height: 500), minimized: false, captureID: nil, stackOrder: index)
        }
        controller.replaceWindowSnapshot(windows)
        controller.scroll(event(y: 1, precise: false))
        XCTAssertEqual(controller.selection.index, 2)
        controller.scroll(event(y: -1, precise: false))
        XCTAssertEqual(controller.selection.index, 0)
        controller.scroll(event(x: 20, phase: .began))
        controller.dismiss()
        controller.replaceWindowSnapshot(windows)
        controller.scroll(event(x: 20, phase: .changed))
        XCTAssertEqual(controller.selection.index, 0)
        controller.scroll(event(x: 10, phase: .changed))
        XCTAssertEqual(controller.selection.index, 1)
        XCTAssertEqual(controller.windows.count, 3)
        XCTAssertNil(controller.message)
    }

    @MainActor
    private func makeCarouselController() -> SwitcherController {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "WindowScrollTests.\(UUID().uuidString)")!, persistChanges: false)
        settings.displayMode = .carousel
        settings.language = .simplifiedChinese
        return SwitcherController(settings: settings)
    }

    private func event(x: Int32 = 0, y: Int32 = 0, precise: Bool = true, phase: NSEvent.Phase = [], momentum: NSEvent.Phase = []) -> NSEvent {
        let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)!
        // CoreGraphics and AppKit use different numeric phase values.
        let cgPhase: CGScrollPhase?
        switch phase {
        case .began: cgPhase = .began
        case .changed: cgPhase = .changed
        case .ended: cgPhase = .ended
        case .cancelled: cgPhase = .cancelled
        case .mayBegin: cgPhase = .mayBegin
        default: cgPhase = nil
        }
        let cgMomentum: CGMomentumScrollPhase
        switch momentum {
        case .began: cgMomentum = .begin
        case .changed: cgMomentum = .continuous
        case .ended: cgMomentum = .end
        default: cgMomentum = .none
        }
        cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(cgPhase?.rawValue ?? 0))
        cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(cgMomentum.rawValue))
        let event = NSEvent(cgEvent: cgEvent)!
        XCTAssertEqual(event.phase, phase)
        XCTAssertEqual(event.momentumPhase, momentum)
        return event
    }
}

// Supply AppKit's window routing and natural-scrolling metadata while forwarding
// the native scroll data; CGEvent's public fields cannot set this metadata.
private final class TestScrollEvent: NSEvent {
    private let source: NSEvent
    private let targetWindow: NSWindow?
    private let targetNumber: Int
    private let inverted: Bool?
    init(_ source: NSEvent, window: NSWindow? = nil, windowNumber: Int = 0, inverted: Bool? = nil) {
        self.source = source
        targetWindow = window
        targetNumber = windowNumber
        self.inverted = inverted
        super.init()
    }
    required init?(coder: NSCoder) { return nil }
    override var type: NSEvent.EventType { source.type }
    override var window: NSWindow? { targetWindow ?? source.window }
    override var windowNumber: Int { targetWindow == nil ? source.windowNumber : targetNumber }
    override var isDirectionInvertedFromDevice: Bool { inverted ?? source.isDirectionInvertedFromDevice }
    override var hasPreciseScrollingDeltas: Bool { source.hasPreciseScrollingDeltas }
    override var scrollingDeltaX: CGFloat { source.scrollingDeltaX }
    override var scrollingDeltaY: CGFloat { source.scrollingDeltaY }
    override var phase: NSEvent.Phase { source.phase }
    override var momentumPhase: NSEvent.Phase { source.momentumPhase }
}
