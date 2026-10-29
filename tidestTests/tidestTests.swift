//
//  tidestTests.swift
//  tidestTests
//
//

import AppKit
import ApplicationServices
import XCTest
@testable import tidest

final class tidestTests: XCTestCase {
    func testFullScreenRowKeepsMarginsAndCapsGapsForManyWindowCounts() {
        for width: CGFloat in [1024, 1728, 2560] {
            for count in [1, 2, 3, 5, 8, 20, 80, 150] {
                for selectedIndex in Set([0, count / 2, count - 1]) {
                    let layout = WindowRowLayout(screenWidth: width, aspectRatios: Array(repeating: 1.6, count: count), selectedIndex: selectedIndex)
                    assertMarginsAndGaps(layout, screenWidth: width)
                }
            }
        }
    }
    func testAdditionalWindowsCompressTheFoldedPages() {
        let sparse = WindowRowLayout(screenWidth: 1728, aspectRatios: Array(repeating: 1.6, count: 5))
        let dense = WindowRowLayout(screenWidth: 1728, aspectRatios: Array(repeating: 1.6, count: 30))
        XCTAssertLessThan(dense.center(for: 2) - dense.center(for: 1), sparse.center(for: 2) - sparse.center(for: 1))
        XCTAssertLessThanOrEqual(dense.rowWidth, 1728 - 200 + 0.001)
    }

    func testNaturalAspectRatiosKeepOneHeightAndSelectedWindowCentered() {
        for ratios: [CGFloat] in [[0.4, 1.6, 2.8, 1, 0.75, 4], [12, 0.45, 1]] {
            for width: CGFloat in [1024, 1728, 2560] {
                let initialHeight = WindowRowLayout(screenWidth: width, aspectRatios: ratios).cardHeight
                for selected in ratios.indices {
                    let layout = WindowRowLayout(screenWidth: width, aspectRatios: ratios, selectedIndex: selected)
                    XCTAssertEqual(layout.cardHeight, initialHeight, accuracy: 0.001)
                    XCTAssertEqual(layout.center(for: selected), width / 2, accuracy: 0.001)
                    for index in ratios.indices {
                        XCTAssertEqual(layout.cardWidths[index] / layout.cardHeight, ratios[index], accuracy: 0.001)
                    }
                    assertMarginsAndGaps(layout, screenWidth: width)
                }
            }
        }
    }

    func testPortraitAndLandscapeProjectionMatchesNativeSwiftUIBounds() {
        let layout = WindowRowLayout(screenWidth: 1728, aspectRatios: [0.5, 1, 2], selectedIndex: 1)
        // Measured from native SwiftUI projection views with the same tilt.
        let portrait = layout.projectedBounds(for: 0)
        let landscape = layout.projectedBounds(for: 2)
        XCTAssertEqual((portrait.upperBound - portrait.lowerBound) / layout.cardWidths[0], 0.3060725925847817, accuracy: 0.000001)
        XCTAssertEqual((landscape.upperBound - landscape.lowerBound) / layout.cardWidths[2], 0.3222708047994327, accuracy: 0.000001)
    }

    func testEmptyWindowLayoutHasNoCardsOrHeight() {
        let layout = WindowRowLayout(screenWidth: 1728, aspectRatios: [])
        XCTAssertTrue(layout.cardWidths.isEmpty)
        XCTAssertEqual(layout.cardHeight, 0)
        XCTAssertEqual(layout.deckHeight, 0)
        XCTAssertEqual(layout.rowWidth, 0)
    }

    private func assertMarginsAndGaps(_ layout: WindowRowLayout, screenWidth: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let bounds = layout.cardWidths.indices.map { layout.projectedBounds(for: $0) }.sorted { $0.lowerBound < $1.lowerBound }
        XCTAssertGreaterThanOrEqual(bounds.first!.lowerBound, 100 - 0.001, file: file, line: line)
        var coveredEnd = bounds.first!.upperBound
        for range in bounds.dropFirst() {
            XCTAssertLessThanOrEqual(range.lowerBound - coveredEnd, 48 + 0.001, file: file, line: line)
            coveredEnd = max(coveredEnd, range.upperBound)
        }
        XCTAssertLessThanOrEqual(coveredEnd, screenWidth - 100 + 0.001, file: file, line: line)
    }
    func testHoldingShortcutWaitsOneSecondAndSuppressesSystemRepeat() {
        var repeatState = ShortcutRepeat()
        XCTAssertTrue(repeatState.keyDown(at: 10))
        XCTAssertFalse(repeatState.keyDown(at: 10.2))
        XCTAssertFalse(repeatState.tick(at: 10.99, modifiersDown: true, keyDown: true))
        XCTAssertTrue(repeatState.tick(at: 11, modifiersDown: true, keyDown: true))
        XCTAssertFalse(repeatState.tick(at: 11.2, modifiersDown: true, keyDown: true))
        XCTAssertTrue(repeatState.tick(at: 12, modifiersDown: true, keyDown: true))
        XCTAssertTrue(repeatState.tick(at: 16, modifiersDown: true, keyDown: true))
        XCTAssertFalse(repeatState.tick(at: 16.1, modifiersDown: true, keyDown: true))
    }

    func testReleasingEitherKeyStopsRepeatAndNextPressAdvancesImmediately() {
        var repeatState = ShortcutRepeat()
        XCTAssertTrue(repeatState.keyDown(at: 0))
        XCTAssertFalse(repeatState.tick(at: 1, modifiersDown: true, keyDown: false))
        XCTAssertTrue(repeatState.keyDown(at: 1.1))
        repeatState.keyUp()
        XCTAssertFalse(repeatState.tick(at: 3, modifiersDown: true, keyDown: true))
        XCTAssertTrue(repeatState.keyDown(at: 4))
        XCTAssertFalse(repeatState.tick(at: 5, modifiersDown: false, keyDown: true))
        XCTAssertTrue(repeatState.keyDown(at: 6))
    }
    func testSwitchStartsAtPreviousWindowAndWrapsInBothDirections() {
        var selection = WindowSelection()
        selection.begin(count: 5, steps: 1)
        XCTAssertEqual(selection.index, 1)
        selection.move(-1)
        XCTAssertEqual(selection.index, 0)
        selection.move(-1)
        XCTAssertEqual(selection.index, 4)
        selection.move(1)
        XCTAssertEqual(selection.index, 0)
        selection.begin(count: 5, steps: 7)
        XCTAssertEqual(selection.index, 2)
        selection.begin(count: 5, steps: -1)
        XCTAssertEqual(selection.index, 4)
    }

    func testEmptyAndSingleWindowSessionsAreSafe() {
        var selection = WindowSelection()
        selection.begin(count: 0, steps: 1)
        selection.move(-1)
        selection.select(4)
        XCTAssertEqual(selection.index, 0)
        XCTAssertEqual(selection.count, 0)
        selection.begin(count: 1, steps: -1)
        selection.move(1)
        XCTAssertEqual(selection.index, 0)
    }

    func testPagePositionsWrapAcrossBothSidesWhileSelectionCyclesInStackOrder() {
        var selection = WindowSelection()
        selection.begin(count: 7, steps: 0)
        XCTAssertEqual(selection.distance(to: 6), -1)
        XCTAssertEqual(selection.distance(to: 1), 1)
        selection.select(6)
        XCTAssertEqual(selection.distance(to: 0), 1)
        XCTAssertEqual(selection.distance(to: 5), -1)
        selection.move(1)
        XCTAssertEqual(selection.index, 0)
    }

    func testFrontmostPageStartsCenteredWithHalfTheRemainingWindowsOnEachSide() {
        for count in [2, 5, 20, 150] {
            let layout = WindowRowLayout(screenWidth: 1728, aspectRatios: Array(repeating: 1.6, count: count))
            XCTAssertEqual(layout.center(for: 0), 864)
            let selected = layout.projectedBounds(for: 0)
            var previous = selected.upperBound
            for index in 1...count / 2 {
                let bounds = layout.projectedBounds(for: index)
                XCTAssertGreaterThanOrEqual(bounds.lowerBound, previous - 0.001)
                previous = bounds.lowerBound
            }
            for index in (count / 2 + 1)..<count {
                XCTAssertLessThanOrEqual(layout.projectedBounds(for: index).upperBound, selected.lowerBound + 0.001)
            }
        }
    }

    @MainActor
    func testCachedWindowOrderUsesFreshSystemRanksEvenAfterMovingAndRenaming() {
        var first = makeWindow(processID: 42, title: "A")
        first.captureID = 11
        first.stackOrder = 0
        var second = makeWindow(processID: 99, title: "B")
        second.captureID = 12
        second.stackOrder = 1
        let candidates = [
            CaptureWindow(id: 12, processID: 99, order: 0),
            CaptureWindow(id: 11, processID: 42, order: 1)
        ]
        let sorted = WindowCatalog.ordered([first, second], candidates: candidates)
        XCTAssertEqual(sorted.map(\.id), [second.id, first.id])
        XCTAssertEqual(sorted.map(\.stackOrder), [0, 1])
    }

    @MainActor
    func testCachedWindowsReadTheActualDesktopStackAfterAWindowIsRaised() {
        let catalog = WindowCatalog()
        let pid = ProcessInfo.processInfo.processIdentifier
        let native = (0..<3).map { index in
            let window = NSWindow(contentRect: CGRect(x: 100 + index * 20, y: 100, width: 300, height: 200),
                                  styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Stack \(index)"
            window.orderFront(nil)
            return window
        }
        defer { native.forEach { $0.close() } }
        let entries = native.enumerated().map { index, window in
            WindowItem(element: AXUIElementCreateApplication(pid), processID: pid, applicationName: "Tidest", icon: nil,
                       title: window.title, frame: window.frame, minimized: false,
                       captureID: CGWindowID(window.windowNumber), stackOrder: index)
        }
        _ = catalog.identify(entries)
        // orderFront returns before WindowServer necessarily publishes the new
        // stack. Observe that initial order before testing a later raise.
        let initialOrder = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            catalog.currentWindows().map(\.id) == entries.reversed().map(\.id)
        }, object: catalog)
        XCTAssertEqual(XCTWaiter.wait(for: [initialOrder], timeout: 2), .completed)
        XCTAssertEqual(catalog.currentWindows().map(\.id), entries.reversed().map(\.id))
        native[0].orderFront(nil)
        let raised = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            catalog.currentWindows().first?.id == entries[0].id
        }, object: catalog)
        XCTAssertEqual(XCTWaiter.wait(for: [raised], timeout: 2), .completed)
        XCTAssertEqual(catalog.currentWindows().map(\.id), [entries[0].id, entries[2].id, entries[1].id])
    }

    @MainActor
    func testFreshListSelectsNewFrontmostWindowBeforeUserInteraction() {
        let controller = SwitcherController()
        let oldTop = makeWindow(processID: 42, title: "Old top")
        let newTop = makeWindow(processID: 99, title: "New top")
        controller.replaceWindowSnapshot([oldTop])
        controller.replaceWindowSnapshot([newTop, oldTop], preservingSelection: false)
        XCTAssertEqual(controller.selection.index, 0)
        XCTAssertEqual(controller.windows[0].id, newTop.id)
        controller.move(1)
        controller.replaceWindowSnapshot([oldTop, newTop])
        XCTAssertEqual(controller.windows[controller.selection.index].id, oldTop.id)
    }

    @MainActor
    func testWindowKeepsItsPreviewIdentityAfterItsTitleAndPositionChange() {
        let catalog = WindowCatalog()
        let original = makeWindow(processID: 42, title: "下载")
        let first = catalog.identify([original])[0]
        let updated = WindowItem(element: AXUIElementCreateApplication(42), processID: 42, applicationName: "Finder", icon: nil, title: "文稿", frame: original.frame.offsetBy(dx: 100, dy: 50), minimized: true, captureID: 11, stackOrder: 2)
        let second = catalog.identify([updated])[0]

        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.title, "文稿")
        XCTAssertEqual(second.frame, updated.frame)
        XCTAssertTrue(second.minimized)
    }

    @MainActor
    func testNewOrReopenedWindowDoesNotInheritAClosedWindowsIdentity() {
        let catalog = WindowCatalog()
        let original = makeWindow(processID: 42, title: "下载")
        let first = catalog.identify([original])[0]
        let other = catalog.identify([makeWindow(processID: 99, title: "下载")])[0]
        XCTAssertNotEqual(other.id, first.id)

        _ = catalog.identify([])
        let reopened = catalog.identify([makeWindow(processID: 42, title: "下载")])[0]
        XCTAssertNotEqual(reopened.id, first.id)
    }

    @MainActor
    func testCatalogProvidesItsLastScanBeforeAnotherScanCompletes() {
        let catalog = WindowCatalog()
        let original = catalog.identify([makeWindow(processID: 42, title: "下载")])[0]
        XCTAssertEqual(catalog.cachedWindows.map(\.id), [original.id])
        let other = catalog.identify([makeWindow(processID: 99, title: "文稿")])[0]
        XCTAssertEqual(catalog.cachedWindows.map(\.id), [other.id])
        catalog.stop()
        XCTAssertTrue(catalog.cachedWindows.isEmpty)
    }

    @MainActor
    func testRefreshingListAndScreenshotPreservesSelectedWindow() {
        let controller = SwitcherController()
        let first = makeWindow(processID: 42, title: "下载")
        let selected = makeWindow(processID: 99, title: "文稿")
        let added = makeWindow(processID: 100, title: "图片")
        controller.replaceWindowSnapshot([first, selected])
        controller.move(1)
        controller.retainPreviews(for: [first, selected])
        let oldImage = NSImage(size: NSSize(width: 640, height: 400))
        let newImage = NSImage(size: NSSize(width: 640, height: 400))
        controller.cacheThumbnail(oldImage, for: selected.id)

        controller.replaceWindowSnapshot([selected, added, first])
        controller.retainPreviews(for: [selected, added, first])
        XCTAssertTrue(controller.thumbnails[selected.id] === oldImage)
        controller.cacheThumbnail(newImage, for: selected.id)

        XCTAssertEqual(controller.windows[controller.selection.index].id, selected.id)
        XCTAssertEqual(controller.selection.index, 0)
        XCTAssertTrue(controller.thumbnails[selected.id] === newImage)
        XCTAssertFalse(controller.isLoading)
        XCTAssertNil(controller.message)
    }

    @MainActor
    func testRefreshingAfterSelectedWindowClosesKeepsSelectionInRange() {
        let controller = SwitcherController()
        let windows = [makeWindow(processID: 42, title: "下载"), makeWindow(processID: 99, title: "文稿"), makeWindow(processID: 100, title: "图片")]
        controller.replaceWindowSnapshot(windows)
        controller.move(2)
        controller.replaceWindowSnapshot(Array(windows.prefix(2)))
        XCTAssertEqual(controller.selection.index, 1)
        XCTAssertEqual(controller.selection.count, 2)
        controller.replaceWindowSnapshot([])
        XCTAssertEqual(controller.selection.index, 0)
        XCTAssertEqual(controller.selection.count, 0)
    }

    @MainActor
    func testClosingSwitcherPreservesPreloadedThumbnails() {
        let controller = SwitcherController()
        let window = makeWindow(processID: 42, title: "下载")
        let thumbnail = NSImage(size: NSSize(width: 640, height: 400))
        controller.retainPreviews(for: [window])
        controller.cacheThumbnail(thumbnail, for: window.id)

        controller.dismiss()

        XCTAssertTrue(controller.thumbnails[window.id] === thumbnail)
        XCTAssertFalse(controller.isPresented)
        XCTAssertTrue(controller.windows.isEmpty)
    }

    @MainActor
    func testNextScanKeepsExistingPreviewAndDiscardsClosedWindowAndLateScreenshot() {
        let controller = SwitcherController()
        let retained = makeWindow(processID: 42, title: "下载")
        let closed = makeWindow(processID: 99, title: "文稿")
        let added = makeWindow(processID: 100, title: "图片")
        let thumbnail = NSImage(size: NSSize(width: 640, height: 400))
        controller.retainPreviews(for: [retained, closed])
        controller.cacheThumbnail(thumbnail, for: retained.id)
        controller.cacheThumbnail(thumbnail, for: closed.id)

        controller.retainPreviews(for: [retained, added])
        controller.cacheThumbnail(thumbnail, for: closed.id)

        XCTAssertTrue(controller.thumbnails[retained.id] === thumbnail)
        XCTAssertNil(controller.thumbnails[closed.id])
        XCTAssertNil(controller.thumbnails[added.id])
        controller.cacheThumbnail(thumbnail, for: added.id)
        XCTAssertTrue(controller.thumbnails[added.id] === thumbnail)
    }

    @MainActor
    func testStoppingApplicationClearsPreviewCache() {
        let controller = SwitcherController()
        let window = makeWindow(processID: 42, title: "下载")
        controller.retainPreviews(for: [window])
        controller.cacheThumbnail(NSImage(size: NSSize(width: 640, height: 400)), for: window.id)

        controller.stop()

        XCTAssertTrue(controller.thumbnails.isEmpty)
    }

    private func makeWindow(processID: pid_t, title: String) -> WindowItem {
        WindowItem(element: AXUIElementCreateApplication(processID), processID: processID, applicationName: "Finder", icon: nil, title: title, frame: CGRect(x: 100, y: 100, width: 900, height: 600), minimized: false, captureID: 11, stackOrder: 0)
    }
}
