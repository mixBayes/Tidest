import AppKit
import XCTest
@testable import tidest

@MainActor
final class MultiWindowLayoutPreviewTests: XCTestCase {
    func testCaptureStartsBeforeDwellAndCacheSurvivesRefreshAndPickerReopening() async throws {
        let probe = CaptureProbe()
        let controller = try makeController(probe)
        defer { controller.dismiss() }
        controller.present(preview: true)
        let region = try XCTUnwrap(controller.draft?.root.leafIDs.first)
        controller.selectRegion(region)
        let first = controller.windows[0].id
        controller.previewHighlightedWindow()
        await waitUntil { probe.calls[first] == 1 }
        XCTAssertNil(controller.windowPreview, "Taking a screenshot must not wait for the dwell timer")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(controller.windowPreview, "The screenshot must stay hidden during the 120 ms dwell")
        await waitUntil { controller.windowPreview?.id == first }
        let image = try XCTUnwrap(controller.windowPreview?.image)

        controller.highlightedWindow = 1
        controller.previewHighlightedWindow()
        await waitUntil { controller.windowPreview?.id == controller.windows[1].id }
        controller.reloadWindows()
        controller.highlightedWindow = 0
        controller.previewHighlightedWindow()
        await waitUntil { controller.windowPreview?.id == first }
        XCTAssertTrue(controller.windowPreview?.image === image)
        XCTAssertEqual(probe.calls[first], 1)

        controller.choosingWindow = false
        XCTAssertNil(controller.windowPreview)
        controller.selectRegion(region)
        controller.previewHighlightedWindow()
        await waitUntil { controller.windowPreview?.id == first }
        XCTAssertTrue(controller.windowPreview?.image === image)
        XCTAssertEqual(probe.calls[first], 1, "Closing only the picker must retain the layout session cache")
    }

    func testRevisitingAnInflightCaptureSharesItAndLateImagesCannotReplaceTheCurrentWindow() async throws {
        let probe = CaptureProbe()
        probe.suspended = true
        let controller = try makeController(probe)
        defer { controller.dismiss(); probe.finishAll() }
        controller.present(preview: true)
        controller.selectRegion(try XCTUnwrap(controller.draft?.root.leafIDs.first))
        let first = controller.windows[0].id
        let second = controller.windows[1].id
        controller.previewHighlightedWindow()
        await waitUntil { probe.pending[first] != nil }
        controller.highlightedWindow = 1
        controller.previewHighlightedWindow()
        await waitUntil { probe.pending[second] != nil }
        controller.highlightedWindow = 0
        controller.previewHighlightedWindow()
        XCTAssertEqual(probe.calls[first], 1)
        controller.highlightedWindow = 1
        controller.previewHighlightedWindow()
        probe.finish(second)
        await waitUntil { controller.windowPreview?.id == second }
        probe.finish(first)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(controller.windowPreview?.id, second)
        controller.highlightedWindow = 0
        controller.previewHighlightedWindow()
        await waitUntil { controller.windowPreview?.id == first }
        XCTAssertEqual(probe.calls[first], 1)
    }

    func testLeavingBeforeDwellKeepsTheLastPreviewAndFinishesTheCaptureIntoCache() async throws {
        let probe = CaptureProbe()
        let controller = try makeController(probe)
        defer { controller.dismiss(); probe.finishAll() }
        controller.present(preview: true)
        controller.selectRegion(try XCTUnwrap(controller.draft?.root.leafIDs.first))
        let first = controller.windows[0].id
        let second = controller.windows[1].id
        controller.previewHighlightedWindow()
        await waitUntil { controller.windowPreview?.id == first }
        probe.suspended = true
        controller.highlightedWindow = 1
        controller.previewHighlightedWindow()
        await waitUntil { probe.pending[second] != nil }
        controller.cancelPendingWindowPreview(for: second)
        probe.finish(second)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(controller.windowPreview?.id, first)
        controller.previewHighlightedWindow()
        await waitUntil { controller.windowPreview?.id == second }
        XCTAssertEqual(probe.calls[second], 1)
    }

    func testDismissalSeparatesSessionsEvenWhenAnOldCaptureIgnoresCancellation() async throws {
        let probe = CaptureProbe()
        probe.suspended = true
        let controller = try makeController(probe)
        defer { controller.dismiss(); probe.finishAll() }
        controller.present(preview: true)
        controller.selectRegion(try XCTUnwrap(controller.draft?.root.leafIDs.first))
        let oldID = controller.windows[0].id
        controller.previewHighlightedWindow()
        await waitUntil { probe.pending[oldID] != nil }
        controller.dismiss()
        XCTAssertFalse(controller.isPresented)
        XCTAssertNil(controller.windowPreview)
        controller.present(preview: true)
        controller.selectRegion(try XCTUnwrap(controller.draft?.root.leafIDs.first))
        let newID = controller.windows[0].id
        controller.previewHighlightedWindow()
        await waitUntil { probe.pending[newID] != nil }
        probe.finish(oldID)
        probe.finish(newID)
        await waitUntil { controller.windowPreview?.id == newID }
        XCTAssertEqual(probe.calls.count, 2, "The reopened layout must take a fresh screenshot")
        XCTAssertTrue(controller.windowPreview?.image === probe.images[newID])
    }

    func testUnavailablePreviewIsRememberedWithoutBlockingWindowSelection() async throws {
        let probe = CaptureProbe()
        probe.producesImage = false
        let controller = try makeController(probe)
        defer { controller.dismiss() }
        controller.present(preview: true)
        let region = try XCTUnwrap(controller.draft?.root.leafIDs.first)
        controller.selectRegion(region)
        let first = controller.windows[0].id
        controller.previewHighlightedWindow()
        await waitUntil { controller.windowPreview?.id == first }
        XCTAssertNil(controller.windowPreview?.image)
        controller.reloadWindows()
        controller.choosingWindow = false
        controller.selectRegion(region)
        controller.previewHighlightedWindow()
        await waitUntil { controller.windowPreview?.id == first }
        XCTAssertEqual(probe.calls[first], 1)
        controller.chooseWindow(first)
        XCTAssertEqual(controller.draft?.assignments[region], first)
    }

    func testPreviewPlacementKeepsBothCardsInsideOffsetAndNarrowScreens() {
        for area in [CGRect(x: 0, y: 0, width: 1728, height: 1084),
                     CGRect(x: 60, y: 24, width: 900, height: 1386),
                     CGRect(x: 0, y: 0, width: 640, height: 480)] {
            for x in [area.minX, area.midX, area.maxX] {
                for y in [area.minY, area.midY, area.maxY] {
                    let placement = LayoutWindowPickerPlacement(area: area, anchor: CGPoint(x: x, y: y))
                    for frame in [placement.picker, placement.preview] {
                        XCTAssertGreaterThanOrEqual(frame.minX, area.minX + 16 - 0.001)
                        XCTAssertLessThanOrEqual(frame.maxX, area.maxX - 16 + 0.001)
                        XCTAssertGreaterThanOrEqual(frame.minY, area.minY + 88 - 0.001)
                        XCTAssertLessThanOrEqual(frame.maxY, area.maxY - 16 + 0.001)
                    }
                    XCTAssertEqual(placement.picker.midY, placement.preview.midY, accuracy: 0.001)
                    XCTAssertFalse(placement.picker.intersects(placement.preview))
                    XCTAssertEqual(max(placement.preview.minX - placement.picker.maxX,
                                       placement.picker.minX - placement.preview.maxX), 12, accuracy: 0.001)
                }
            }
        }
        let area = CGRect(x: 0, y: 0, width: 1728, height: 1084)
        let right = LayoutWindowPickerPlacement(area: area, anchor: CGPoint(x: 432, y: 542))
        let left = LayoutWindowPickerPlacement(area: area, anchor: CGPoint(x: 1296, y: 542))
        XCTAssertGreaterThan(right.preview.minX, right.picker.maxX)
        XCTAssertLessThan(left.preview.maxX, left.picker.minX)
        XCTAssertEqual(right.preview.size, CGSize(width: 320, height: 240))
        XCTAssertEqual(right.picker.size, CGSize(width: 350, height: 430))
    }

    private func makeController(_ probe: CaptureProbe) throws -> MultiWindowLayoutController {
        try XCTSkipIf(NSScreen.screens.isEmpty, "Requires a macOS display session")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "tidest.preview.tests.\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults, persistChanges: false)
        return MultiWindowLayoutController(settings: settings,
            statistics: UsageStatisticsStore(defaults: defaults, persistChanges: false),
            captureThumbnail: { await probe.capture($0) })
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Timed out waiting for preview", file: file, line: line)
    }

    private final class CaptureProbe {
        var calls: [UUID: Int] = [:]
        var images: [UUID: NSImage] = [:]
        var pending: [UUID: CheckedContinuation<NSImage?, Never>] = [:]
        var suspended = false
        var producesImage = true

        func capture(_ window: WindowItem) async -> NSImage? {
            calls[window.id, default: 0] += 1
            if producesImage { images[window.id] = NSImage(size: NSSize(width: 640, height: 480)) }
            if suspended {
                return await withCheckedContinuation { pending[window.id] = $0 }
            }
            return images[window.id]
        }

        func finish(_ id: UUID) { pending.removeValue(forKey: id)?.resume(returning: images[id]) }
        func finishAll() { for id in Array(pending.keys) { finish(id) } }
    }
}
