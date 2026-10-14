import AppKit
import ApplicationServices
import XCTest
@testable import tidest

final class WindowBackgroundTests: XCTestCase {
    @MainActor
    func testFrostedBackgroundKeepsControlsClickableAfterResizing() {
        let content = NSView()
        let button = NSButton(title: "Open", target: nil, action: nil)
        button.frame = CGRect(x: 16, y: 18, width: 80, height: 24)
        content.addSubview(button)
        let background = WindowBackground.makeFrosted(contentView: content,
            frame: CGRect(x: 0, y: 0, width: 200, height: 100), cornerRadius: 18)

        for size in [CGSize(width: 200, height: 100), CGSize(width: 320, height: 160)] {
            background.setFrameSize(size)
            background.layoutSubtreeIfNeeded()
            XCTAssertEqual(content.frame, background.bounds)
            let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: background)
            XCTAssertTrue(background.hitTest(point) === button)
        }
        XCTAssertEqual(background.layer?.cornerRadius, 18)
        XCTAssertEqual(background.layer?.masksToBounds, true)
    }

    @MainActor
    func testCarriedPictureKeepsItsScreenRectangleWhenReparented() throws {
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = root
        let floating = NSView(frame: CGRect(x: 20, y: 30, width: 360, height: 300))
        let dock = NSView(frame: CGRect(x: 280, y: 40, width: 340, height: 400))
        root.addSubview(floating)
        root.addSubview(dock)
        let preview = PinnedWindowDragPreviewView(frame: .zero)
        let entry = PinnedWindowEntry(window: WindowItem(
            element: AXUIElementCreateApplication(0), processID: 0, applicationName: "Example",
            icon: nil, title: "Preview", frame: CGRect(x: 0, y: 0, width: 400, height: 200),
            minimized: false, captureID: nil, stackOrder: 0))
        preview.update(window: entry, thumbnail: NSImage(size: CGSize(width: 400, height: 200)))
        floating.addSubview(preview)
        preview.setFrames(glass: CGRect(x: 30, y: 20, width: 254, height: 160),
            picture: CGRect(x: 42, y: 32, width: 230, height: 136))
        let original = try XCTUnwrap(preview.screenFrames)
        let image = try XCTUnwrap(imageView(in: preview))
        XCTAssertEqual(window.convertToScreen(image.convert(image.bounds, to: nil)), original.picture)

        dock.addSubview(preview)
        preview.setFrames(glass: dock.convert(window.convertFromScreen(original.glass), from: nil),
            picture: dock.convert(window.convertFromScreen(original.picture), from: nil))
        let moved = try XCTUnwrap(preview.screenFrames)
        XCTAssertEqual(moved.glass, original.glass)
        XCTAssertEqual(moved.picture, original.picture)
        XCTAssertEqual(window.convertToScreen(image.convert(image.bounds, to: nil)), original.picture)
        XCTAssertNil(preview.hitTest(CGPoint(x: preview.frame.midX, y: preview.frame.midY)))
    }

    @MainActor
    private func imageView(in view: NSView) -> NSImageView? {
        if let image = view as? NSImageView { return image }
        return view.subviews.lazy.compactMap { self.imageView(in: $0) }.first
    }
}
