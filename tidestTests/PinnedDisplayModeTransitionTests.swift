import AppKit
import ApplicationServices
import XCTest
@testable import tidest

final class PinnedDisplayModeTransitionTests: XCTestCase {
    @MainActor
    func testThumbnailAndIconShareASoftCrossfadeAtTheSameCenter() throws {
        let settings = makeSettings()
        let entry = makeEntry(0)
        let image = NSImage(size: CGSize(width: 400, height: 250))
        let card = PinnedWindowCardView(frame: .zero)
        card.update(window: entry, thumbnail: image, settings: settings, highlighted: false, dragging: false)
        card.frame = CGRect(x: 0, y: 0, width: 184, height: card.preferredHeight(for: 184))
        card.layoutSubtreeIfNeeded()
        let preview = try XCTUnwrap(card.subviews.compactMap { $0 as? NSImageView }.first { $0.image === image })
        let icon = try XCTUnwrap(card.subviews.compactMap { $0 as? NSImageView }.first { $0 !== preview })
        let original = preview.frame
        card.beginDisplayModeTransition()
        card.update(window: entry, thumbnail: nil, settings: settings, highlighted: false, dragging: false)
        card.setDisplayModeTransition(progress: 0, reducesMotion: false)
        card.layoutSubtreeIfNeeded()
        XCTAssertEqual(preview.frame, original)
        XCTAssertTrue(preview.image === image)
        XCTAssertFalse(preview.isHidden)

        card.frame.size.height = card.preferredHeight(for: 184)
        card.setDisplayModeTransition(progress: 0.5, reducesMotion: false)
        card.layoutSubtreeIfNeeded()
        XCTAssertLessThan(preview.frame.width, original.width / 2)
        XCTAssertEqual(preview.frame.width / preview.frame.height, 1.6, accuracy: 0.01)
        XCTAssertEqual(preview.alphaValue, 1, accuracy: 0.001)
        XCTAssertEqual(icon.alphaValue, 0, accuracy: 0.001)
        XCTAssertEqual(preview.frame.midX, icon.frame.midX, accuracy: 0.001)
        XCTAssertEqual(preview.frame.midY, icon.frame.midY, accuracy: 0.001)

        // The first small step into the handoff should barely change opacity,
        // rather than losing a large part of the thumbnail in a single frame.
        card.setDisplayModeTransition(progress: 0.52, reducesMotion: false)
        card.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(preview.alphaValue, 0.99)
        XCTAssertLessThan(icon.alphaValue, 0.01)
        card.setDisplayModeTransition(progress: 0.75, reducesMotion: false)
        card.layoutSubtreeIfNeeded()
        XCTAssertEqual(preview.alphaValue, 0.5, accuracy: 0.01)
        XCTAssertEqual(icon.alphaValue, 0.5, accuracy: 0.01)
        XCTAssertEqual(preview.frame.midX, icon.frame.midX, accuracy: 0.001)
        XCTAssertEqual(preview.frame.midY, icon.frame.midY, accuracy: 0.001)
        card.setDisplayModeTransition(progress: 0.98, reducesMotion: false)
        card.layoutSubtreeIfNeeded()
        XCTAssertLessThan(preview.alphaValue, 0.01)
        XCTAssertGreaterThan(icon.alphaValue, 0.99)
        XCTAssertTrue(preview.image === image)
        card.finishDisplayModeTransition()
        XCTAssertNil(preview.image)
        XCTAssertTrue(preview.isHidden)
        XCTAssertEqual(card.frame.height, 44)
    }

    @MainActor
    func testReversalDuringHandoffPreservesGeometryAndBothOpacities() throws {
        let settings = makeSettings()
        let entry = makeEntry(0)
        let image = NSImage(size: CGSize(width: 400, height: 250))
        let card = PinnedWindowCardView(frame: .zero)
        card.update(window: entry, thumbnail: image, settings: settings, highlighted: false, dragging: false)
        card.frame = CGRect(x: 0, y: 0, width: 184, height: card.preferredHeight(for: 184))
        card.layoutSubtreeIfNeeded()
        let preview = try XCTUnwrap(card.subviews.compactMap { $0 as? NSImageView }.first { $0.image === image })
        let icon = try XCTUnwrap(card.subviews.compactMap { $0 as? NSImageView }.first { $0 !== preview })
        card.beginDisplayModeTransition()
        card.update(window: entry, thumbnail: nil, settings: settings, highlighted: false, dragging: false)
        card.frame.size.height = 44
        card.setDisplayModeTransition(progress: 0.75, reducesMotion: false)
        card.layoutSubtreeIfNeeded()
        let frames = [preview.frame, icon.frame]
        let opacities = [preview.alphaValue, icon.alphaValue]
        card.beginDisplayModeTransition()
        card.update(window: entry, thumbnail: image, settings: settings, highlighted: false, dragging: false)
        card.setDisplayModeTransition(progress: 0, reducesMotion: false)
        card.layoutSubtreeIfNeeded()
        XCTAssertEqual([preview.frame, icon.frame], frames)
        XCTAssertEqual([preview.alphaValue, icon.alphaValue], opacities)
    }

    @MainActor
    func testRapidReverseKeepsCurrentGeometryAndRestoresTheSameThumbnail() async throws {
        try requireMotion()
        let fixture = makeShelf(count: 6)
        defer { fixture.window.close() }
        let row = try XCTUnwrap(cards(in: fixture.shelf).first)
        let initial = row.frame
        let preview = try XCTUnwrap(row.subviews.compactMap { $0 as? NSImageView }.first { $0.image === fixture.image })
        fixture.render(mode: .iconsAndTitle)
        XCTAssertEqual(row.frame, initial)
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertLessThan(row.frame.height, initial.height)
        XCTAssertGreaterThan(row.frame.height, 44)
        let movingFrame = row.frame
        let movingPreview = preview.frame
        fixture.render(mode: .thumbnails)
        XCTAssertEqual(row.frame, movingFrame)
        XCTAssertEqual(preview.frame, movingPreview)
        try await Task.sleep(for: .milliseconds(680))
        XCTAssertEqual(row.frame, initial)
        XCTAssertTrue(preview.image === fixture.image)
        XCTAssertFalse(preview.isHidden)
        XCTAssertEqual(preview.alphaValue, 1)
        XCTAssertTrue(row.openingButton.isEnabled)
    }

    @MainActor
    func testScrollingKeepsTheSameWindowAtTheTopDuringCollapse() async throws {
        try requireMotion()
        let fixture = makeShelf(count: 24)
        defer { fixture.window.close() }
        let rows = cards(in: fixture.shelf)
        let scroll = try XCTUnwrap(descendants(of: fixture.shelf).compactMap { $0 as? NSScrollView }.first)
        let anchor = rows[8]
        let fraction: CGFloat = 0.25
        scroll.contentView.scroll(to: CGPoint(x: 0, y: anchor.frame.minY + anchor.frame.height * fraction))
        scroll.reflectScrolledClipView(scroll.contentView)
        fixture.render(mode: .iconsAndTitle)
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(scroll.contentView.bounds.minY,
            anchor.frame.minY + anchor.frame.height * fraction, accuracy: 1)
        // A thumbnail refresh with the same mode must not restart the animation.
        fixture.render(mode: .iconsAndTitle)
        try await Task.sleep(for: .milliseconds(530))
        XCTAssertEqual(anchor.frame.height, 44)
        XCTAssertEqual(scroll.contentView.bounds.minY,
            anchor.frame.minY + anchor.frame.height * fraction, accuracy: 1)
    }

    @MainActor
    func testReducedMotionOnlyFadesAndMissingThumbnailsStayCompact() throws {
        let settings = makeSettings()
        let entry = makeEntry(0)
        let image = NSImage(size: CGSize(width: 400, height: 250))
        let card = PinnedWindowCardView(frame: CGRect(x: 0, y: 0, width: 184, height: 150))
        card.update(window: entry, thumbnail: image, settings: settings, highlighted: false, dragging: false)
        card.layoutSubtreeIfNeeded()
        let preview = try XCTUnwrap(card.subviews.compactMap { $0 as? NSImageView }.first { $0.image === image })
        card.beginDisplayModeTransition()
        card.update(window: entry, thumbnail: nil, settings: settings, highlighted: false, dragging: false)
        card.frame.size.height = 44
        card.setDisplayModeTransition(progress: 0, reducesMotion: true)
        card.layoutSubtreeIfNeeded()
        let stationaryFrame = preview.frame
        card.setDisplayModeTransition(progress: 0.5, reducesMotion: true)
        card.layoutSubtreeIfNeeded()
        XCTAssertEqual(preview.frame, stationaryFrame)
        XCTAssertLessThan(preview.alphaValue, 1)
        card.finishDisplayModeTransition()
        card.beginDisplayModeTransition()
        card.update(window: entry, thumbnail: nil, settings: settings, highlighted: false, dragging: false)
        card.setDisplayModeTransition(progress: 0.5, reducesMotion: false)
        card.layoutSubtreeIfNeeded()
        XCTAssertTrue(preview.isHidden)
        XCTAssertEqual(card.preferredHeight(for: 184), 44)
    }

    @MainActor
    private struct ShelfFixture {
        let window: NSWindow
        let shelf: PinnedWindowsView
        let settings: AppSettings
        let entries: [PinnedWindowEntry]
        let image: NSImage

        func render(mode: PinnedDisplayMode) {
            settings.pinnedDisplayMode = mode
            shelf.update(windows: entries, thumbnails: Dictionary(uniqueKeysWithValues: entries.map { ($0.id, image) }),
                settings: settings, draggedID: nil, highlightedID: nil, insertionIndex: nil,
                showsRemovalHint: false, removingItem: false, message: nil)
        }
    }

    @MainActor
    private func makeShelf(count: Int) -> ShelfFixture {
        let shelf = PinnedWindowsView(frame: CGRect(x: 0, y: 0, width: 224, height: 600))
        let window = NSWindow(contentRect: shelf.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = shelf
        let fixture = ShelfFixture(window: window, shelf: shelf, settings: makeSettings(),
            entries: (0..<count).map(makeEntry), image: NSImage(size: CGSize(width: 400, height: 250)))
        fixture.render(mode: .thumbnails)
        window.orderFront(nil)
        shelf.setShown(true, animated: false)
        return fixture
    }

    @MainActor
    private func makeSettings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "Tidest.ModeTransitionTests.\(UUID())")!, persistChanges: false)
    }

    @MainActor
    private func requireMotion() throws {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            throw XCTSkip("Motion is disabled by the system display settings")
        }
    }

    private func makeEntry(_ index: Int) -> PinnedWindowEntry {
        PinnedWindowEntry(window: WindowItem(element: AXUIElementCreateApplication(0), processID: 0,
            applicationName: "Example", icon: NSImage(systemSymbolName: "app", accessibilityDescription: nil),
            title: "Window \(index)", frame: CGRect(x: 0, y: 0, width: 800, height: 500),
            minimized: false, captureID: nil, stackOrder: index))
    }

    @MainActor
    private func cards(in view: NSView) -> [PinnedWindowCardView] {
        descendants(of: view).compactMap { $0 as? PinnedWindowCardView }.sorted { $0.frame.minY < $1.frame.minY }
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
