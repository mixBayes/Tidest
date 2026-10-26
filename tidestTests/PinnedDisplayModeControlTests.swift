import AppKit
import XCTest
@testable import tidest

final class PinnedDisplayModeControlTests: XCTestCase {
    @MainActor
    func testGlassDoesNotInterceptEitherNativeSegmentAfterResizing() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Liquid Glass requires macOS 26") }
        let control = makeControl()
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        root.addSubview(control)
        let glass = try XCTUnwrap(descendants(of: control).compactMap { $0 as? NSGlassEffectView }.first)

        for width in [control.frame.width, 120] {
            control.frame = CGRect(x: 20, y: 20, width: width, height: control.frame.height)
            for segment in 0..<2 {
                control.selectedSegment = segment
                control.layoutSubtreeIfNeeded()
                let point = CGPoint(x: control.frame.minX + width * (CGFloat(segment) + 0.5) / 2,
                                    y: control.frame.midY)
                XCTAssertTrue(control.hitTest(point) === control)
                XCTAssertEqual(glass.frame.midX, width * (CGFloat(segment) + 0.5) / 2, accuracy: 0.01)
                XCTAssertTrue(control.bounds.contains(glass.frame))
                XCTAssertNotNil(glass.contentView)
                XCTAssertTrue(control.acceptsFirstMouse(for: nil))
            }
        }
        control.isEnabled = false
        XCTAssertFalse(control.acceptsFirstResponder)
    }

    @MainActor
    func testRapidReversalKeepsCurrentPositionAndStopsAtLatestSelection() async throws {
        guard #available(macOS 26.0, *),
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else {
            throw XCTSkip("Animation is disabled by the system display settings")
        }
        let control = makeControl()
        let window = NSWindow(contentRect: control.bounds, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = control
        window.orderFront(nil)
        defer { window.close() }
        control.layoutSubtreeIfNeeded()
        let glass = try XCTUnwrap(descendants(of: control).compactMap { $0 as? NSGlassEffectView }.first)
        let initialCenter = glass.frame.midX
        control.selectedSegment = 1
        try await Task.sleep(for: .milliseconds(90))
        let movingCenter = glass.frame.midX
        XCTAssertGreaterThan(movingCenter, initialCenter)
        XCTAssertLessThan(movingCenter, control.bounds.width * 0.75)
        control.selectedSegment = 0
        XCTAssertEqual(glass.frame.midX, movingCenter, accuracy: 0.01)
        // A render refresh with the same saved value must not restart movement.
        control.selectedSegment = 0
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(glass.frame.midX, initialCenter, accuracy: 0.01)
        XCTAssertEqual(control.selectedSegment, 0)
        let settledFrame = glass.frame
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(glass.frame, settledFrame)
    }

    @MainActor
    func testSelectedHighlightKeepsItsColorWithoutAKeyWindow() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Liquid Glass requires macOS 26") }
        let control = makeControl()
        let glass = try XCTUnwrap(descendants(of: control).compactMap { $0 as? NSGlassEffectView }.first)
        glass.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(glass.contentView)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let color = try XCTUnwrap(bitmap.colorAt(x: 3, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.alphaComponent, 0.1)
        XCTAssertGreaterThan(color.blueComponent, color.redComponent + 0.1)
    }

    @MainActor
    func testNativeKeyboardSelectionSendsNormalControlAction() throws {
        let control = makeControl()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 160, height: 70),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root
        root.addSubview(control)
        control.setFrameOrigin(CGPoint(x: 40, y: 20))
        window.makeFirstResponder(control)
        let action = SelectionReceiver()
        control.target = action
        control.action = #selector(SelectionReceiver.changed(_:))
        for (characters, keyCode) in [(String(UnicodeScalar(NSRightArrowFunctionKey)!), UInt16(124)), (" ", UInt16(49))] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode))
            control.keyDown(with: event)
        }
        XCTAssertEqual(control.selectedSegment, 1)
        XCTAssertEqual(action.selections.last, 1)

        window.close()
    }

    @MainActor
    private func makeControl() -> PinnedDisplayModeControl {
        let control = PinnedDisplayModeControl()
        control.segmentCount = 2
        control.controlSize = .large
        control.trackingMode = .selectOne
        control.segmentStyle = .rounded
        for segment in 0..<2 {
            control.setWidth(44, forSegment: segment)
            control.setImage(NSImage(systemSymbolName: segment == 0 ? "rectangle.grid.1x2" : "list.bullet.rectangle",
                                    accessibilityDescription: nil), forSegment: segment)
        }
        control.selectedSegment = 0
        control.sizeToFit()
        control.layoutSubtreeIfNeeded()
        return control
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

@MainActor
private final class SelectionReceiver: NSObject {
    var selections: [Int] = []
    @objc func changed(_ control: NSSegmentedControl) { selections.append(control.selectedSegment) }
}
