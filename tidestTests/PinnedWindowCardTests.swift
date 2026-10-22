import AppKit
import ApplicationServices
import XCTest
@testable import tidest

final class PinnedWindowCardTests: XCTestCase {
    @MainActor
    func testPinClickKeepsExistingKeyboardFocusAndUsesOnlyTheSavedVisualState() throws {
        try withSettings { settings in
            let entry = PinnedWindowEntry(window: makeWindow())
            let card = PinnedWindowCardView(frame: CGRect(x: 0, y: 0, width: 220, height: 52))
            card.update(window: entry, thumbnail: nil, settings: settings, highlighted: false, dragging: false)
            let window = NSWindow(contentRect: card.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = card
            XCTAssertTrue(window.makeFirstResponder(card.openingButton))
            let button = try XCTUnwrap(card.subviews.compactMap { $0 as? NSButton }
                .first { $0 !== card.openingButton })
            XCTAssertEqual(button.focusRingType, .none)
            XCTAssertEqual(button.accessibilityRole(), .checkBox)
            XCTAssertEqual((button.cell as? NSButtonCell)?.showsStateBy, [])
            var toggles = 0
            card.onToggleRetention = { toggles += 1 }
            button.performClick(nil)
            XCTAssertEqual(toggles, 1)
            XCTAssertTrue(window.firstResponder === card.openingButton)
            XCTAssertFalse(window.isKeyWindow)
            XCTAssertEqual(button.state, .off)
            XCTAssertTrue(window.makeFirstResponder(button))
            XCTAssertTrue(window.firstResponder === button)
            button.performClick(nil)
            XCTAssertEqual(toggles, 2)
        }
    }

    @MainActor
    func testPinReceivesItsOwnClickAndKeepsSavedStateUntilConfirmed() throws {
        try withSettings { settings in
            let entry = PinnedWindowEntry(window: makeWindow())
            let card = PinnedWindowCardView(frame: CGRect(x: 20, y: 30, width: 220, height: 44))
            let container = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
            container.addSubview(card)
            card.update(window: entry, thumbnail: nil, settings: settings, highlighted: false, dragging: false)
            card.layoutSubtreeIfNeeded()
            let button = try XCTUnwrap(card.subviews.compactMap { $0 as? NSButton }.first { $0 !== card.openingButton })
            let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: container)

            XCTAssertTrue(card.hitTest(point) === button)
            XCTAssertTrue(button.acceptsFirstMouse(for: nil))
            XCTAssertEqual(button.accessibilityIdentifier(), "pinnedRetain-\(entry.id.uuidString)")
            XCTAssertEqual(button.toolTip, settings.text("关闭后仍保留"))
            var toggles = 0
            card.onToggleRetention = { toggles += 1 }
            button.performClick(nil)
            XCTAssertEqual(toggles, 1)
            XCTAssertEqual(button.state, .off)

            card.update(window: entry, thumbnail: nil, settings: settings, highlighted: false, dragging: false, busy: true)
            button.performClick(nil)
            XCTAssertFalse(button.isEnabled)
            XCTAssertEqual(toggles, 1)
        }
    }

    @MainActor
    func testClosedItemShowsReadableStatusAndReopenActionWithoutChangingPreviewRatio() throws {
        try withSettings { settings in
            let saved = SavedPinnedWindow(
                id: UUID(), applicationBundleIdentifier: "com.example.app",
                applicationURL: "file:///Applications/Example.app/", applicationName: "Example",
                title: "Saved window", width: 80, height: 160, target: .application)
            let entry = PinnedWindowEntry(saved: saved)
            let card = PinnedWindowCardView(frame: .zero)
            let thumbnail = NSImage(size: CGSize(width: 80, height: 160))
            card.update(window: entry, thumbnail: thumbnail, settings: settings, highlighted: false, dragging: false)
            card.frame = CGRect(x: 0, y: 0, width: 220, height: card.preferredHeight(for: 220))
            card.layoutSubtreeIfNeeded()

            let indicator = try XCTUnwrap(card.subviews.first { $0.toolTip == settings.text("已关闭") })
            let button = try XCTUnwrap(card.subviews.compactMap { $0 as? NSButton }.first { $0 !== card.openingButton })
            XCTAssertFalse(indicator.isHidden)
            XCTAssertEqual(indicator.frame.size, CGSize(width: 8, height: 8))
            XCTAssertEqual(card.previewRect.width / card.previewRect.height, 0.5, accuracy: 0.001)
            XCTAssertEqual(button.state, .on)
            XCTAssertEqual(button.accessibilityLabel(), settings.text("取消保留"))
            let status = try XCTUnwrap(card.subviews.compactMap { $0 as? NSTextField }
                .first { $0.stringValue == settings.text("已关闭") })
            XCTAssertFalse(status.isHidden)
            XCTAssertTrue(card.openingButton.isEnabled)
            XCTAssertTrue(card.openingButton.toolTip?.contains(settings.text("点击重新打开")) == true)
            XCTAssertTrue(card.openingButton.accessibilityLabel()?.contains(settings.text("已关闭")) == true)
            XCTAssertEqual(button.toolTip, settings.text("取消保留后，此项会从停靠栏移除"))
        }
    }

    @MainActor
    func testClosingAddsStatusSpaceAndReopeningRemovesItWithoutChangingPreview() throws {
        try withSettings { settings in
            let title = "窗口标题很长时应该保留开头的文字，仅在末尾显示省略号"
            let icon = NSImage(size: CGSize(width: 32, height: 32))
            let window = WindowItem(element: AXUIElementCreateApplication(0), processID: 0,
                                    applicationName: "Example", icon: icon, title: title,
                                    frame: CGRect(x: 10, y: 20, width: 900, height: 700),
                                    minimized: false, captureID: nil, stackOrder: 0)
            let saved = SavedPinnedWindow(
                id: window.id, applicationBundleIdentifier: "com.example.app",
                applicationURL: "file:///Applications/Example.app/", applicationName: "Saved Example",
                title: "Old saved title", width: 80, height: 160, target: .application)
            let thumbnails: [NSImage?] = [nil, NSImage(size: CGSize(width: 80, height: 160))]
            for thumbnail in thumbnails {
                var entry = PinnedWindowEntry(window: window)
                entry.saved = saved
                let card = PinnedWindowCardView(frame: .zero)
                card.update(window: entry, thumbnail: thumbnail, settings: settings, highlighted: false, dragging: false)
                let height = card.preferredHeight(for: 184)
                card.frame = CGRect(x: 0, y: 0, width: 184, height: height)
                card.layoutSubtreeIfNeeded()
                let label = try XCTUnwrap(card.subviews.compactMap { $0 as? NSTextField }.first)
                let originalFrames = card.subviews.map(\.frame)
                let originalHidden = card.subviews.map(\.isHidden)
                let status = try XCTUnwrap(card.subviews.compactMap { $0 as? NSTextField }.last)
                let images = card.subviews.compactMap { $0 as? NSImageView }
                let originalImages = images.map(\.image)
                let originalTooltip = label.toolTip
                let originalPreview = card.previewRect

                entry.window = nil
                card.update(window: entry, thumbnail: thumbnail, settings: settings, highlighted: false, dragging: false)
                let closedHeight = card.preferredHeight(for: 184)
                card.setFrameSize(CGSize(width: 184, height: closedHeight))
                card.layoutSubtreeIfNeeded()
                let indicator = try XCTUnwrap(card.subviews.first { $0.toolTip == settings.text("已关闭") })
                XCTAssertEqual(label.stringValue, title)
                XCTAssertEqual(label.toolTip, originalTooltip)
                XCTAssertEqual(label.lineBreakMode, .byTruncatingTail)
                XCTAssertGreaterThanOrEqual(label.frame.width, 100)
                XCTAssertEqual(closedHeight - height, thumbnail == nil ? 8 : 16)
                XCTAssertEqual(label.frame.width, originalFrames[2].width)
                if thumbnail != nil { XCTAssertEqual(card.previewRect, originalPreview) }
                XCTAssertFalse(indicator.isHidden)
                XCTAssertGreaterThan(indicator.frame.minX, status.frame.maxX)
                XCTAssertEqual(indicator.frame.midY, status.frame.midY)
                XCTAssertLessThanOrEqual(indicator.frame.maxX, label.frame.maxX)
                XCTAssertGreaterThan(indicator.frame.minY, label.frame.maxY)
                XCTAssertFalse(status.isHidden)
                XCTAssertEqual(status.frame.minX, label.frame.minX)
                XCTAssertLessThanOrEqual(status.frame.width, label.frame.width)
                XCTAssertLessThanOrEqual(status.frame.maxY, card.bounds.height - 8)
                for (index, view) in card.subviews.enumerated() where view !== indicator && view !== status {
                    XCTAssertEqual(view.isHidden, originalHidden[index])
                }
                for (index, imageView) in images.enumerated() {
                    XCTAssertTrue(imageView.image === originalImages[index])
                }

                // Repeated layouts must not progressively shrink the title.
                let closedFrames = card.subviews.map(\.frame)
                card.needsLayout = true
                card.layoutSubtreeIfNeeded()
                XCTAssertEqual(card.subviews.map(\.frame), closedFrames)

                entry.window = window
                card.update(window: entry, thumbnail: thumbnail, settings: settings, highlighted: false, dragging: false)
                XCTAssertEqual(card.preferredHeight(for: 184), height)
                card.setFrameSize(CGSize(width: 184, height: height))
                card.layoutSubtreeIfNeeded()
                XCTAssertTrue(indicator.isHidden)
                XCTAssertTrue(status.isHidden)
                XCTAssertEqual(card.subviews.map(\.isHidden), originalHidden)
                XCTAssertEqual(card.subviews.map(\.frame), originalFrames)
            }
        }
    }

    @MainActor
    func testNativePressAndKeyboardOpenShareActionAndIgnoreBusyOrRepeatInput() throws {
        try withSettings { settings in
            let entry = PinnedWindowEntry(window: makeWindow())
            let card = PinnedWindowCardView(frame: CGRect(x: 0, y: 0, width: 220, height: 52))
            card.update(window: entry, thumbnail: nil, settings: settings, highlighted: false, dragging: false)
            let open = card.openingButton
            var activations = 0
            card.onActivate = { activations += 1 }
            XCTAssertEqual(open.accessibilityRole(), .button)
            XCTAssertEqual(open.accessibilityIdentifier(), "pinnedOpen-\(entry.id.uuidString)")
            XCTAssertTrue(open.accessibilityPerformPress())
            XCTAssertEqual(activations, 1)

            for keyCode in [UInt16(36), UInt16(49), UInt16(76)] {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    characters: keyCode == 49 ? " " : "\r", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: keyCode))
                open.keyDown(with: event)
            }
            XCTAssertEqual(activations, 4)
            let repeatEvent = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: " ", charactersIgnoringModifiers: " ", isARepeat: true, keyCode: 49))
            open.keyDown(with: repeatEvent)
            XCTAssertEqual(activations, 4)

            card.update(window: entry, thumbnail: nil, settings: settings,
                        highlighted: false, dragging: false, busy: true)
            XCTAssertFalse(open.isEnabled)
            XCTAssertFalse(open.accessibilityPerformPress())
            open.performClick(nil)
            open.keyDown(with: repeatEvent)
            XCTAssertEqual(activations, 4)
        }
    }

    @MainActor
    func testMouseDownKeepsDragPathAndKeyboardFocusCanEnterNativeButton() throws {
        try withSettings { settings in
            let card = PinnedWindowCardView(frame: CGRect(x: 0, y: 0, width: 220, height: 52))
            card.update(window: PinnedWindowEntry(window: makeWindow()), thumbnail: nil,
                        settings: settings, highlighted: false, dragging: false)
            let window = NSWindow(contentRect: card.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = card
            var activations = 0
            var mouseDowns = 0
            card.onActivate = { activations += 1 }
            card.onMouseDown = { _ in mouseDowns += 1 }
            let open = card.openingButton
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 10, y: 10),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            open.mouseDown(with: event)
            XCTAssertEqual(mouseDowns, 1)
            XCTAssertEqual(activations, 0)
            XCTAssertFalse(window.isKeyWindow)
            XCTAssertTrue(window.makeFirstResponder(open))
            XCTAssertTrue(window.firstResponder === open)
        }
    }

    @MainActor
    func testNativeContextMenuRemovesOnlyThroughShelfActionAndHonorsBusyState() throws {
        try withSettings { settings in
            let entry = PinnedWindowEntry(window: makeWindow())
            let card = PinnedWindowCardView(frame: CGRect(x: 0, y: 0, width: 220, height: 52))
            card.update(window: entry, thumbnail: nil, settings: settings, highlighted: false, dragging: false)
            var removals = 0
            card.onRemove = { removals += 1 }
            let menu = try XCTUnwrap(card.openingButton.menu)
            XCTAssertEqual(menu.items.first?.title, settings.text("从停靠栏移除"))
            XCTAssertEqual(menu.items.first?.toolTip, settings.text("不会关闭窗口"))
            menu.performActionForItem(at: 0)
            XCTAssertEqual(removals, 1)
            card.update(window: entry, thumbnail: nil, settings: settings,
                        highlighted: false, dragging: false, busy: true)
            XCTAssertFalse(card.openingButton.menu?.items.first?.isEnabled ?? true)
            menu.performActionForItem(at: 0)
            XCTAssertEqual(removals, 1)
        }
    }

    @MainActor
    func testDragPreviewHasNoPinControl() throws {
        try withSettings { settings in
            let window = makeWindow()
            let card = PinnedWindowCardView(frame: CGRect(x: 0, y: 0, width: 220, height: 44))
            card.update(window: PinnedWindowEntry(window: window), thumbnail: nil,
                        settings: settings, highlighted: false, dragging: false)
            card.update(window: window, thumbnail: nil, highlighted: false, dragging: true)
            card.layoutSubtreeIfNeeded()

            let button = try XCTUnwrap(card.subviews.compactMap { $0 as? NSButton }.first { $0 !== card.openingButton })
            XCTAssertTrue(button.isHidden)
        }
    }

    @MainActor
    private func withSettings(_ body: (AppSettings) throws -> Void) rethrows {
        let name = "PinnedWindowCardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, preferredLanguages: { ["zh-CN"] })
        try body(settings)
    }

    private func makeWindow() -> WindowItem {
        WindowItem(element: AXUIElementCreateApplication(0), processID: 0,
                   applicationName: "Example", icon: nil, title: "Live window",
                   frame: CGRect(x: 0, y: 0, width: 900, height: 700),
                   minimized: false, captureID: nil, stackOrder: 0)
    }
}
