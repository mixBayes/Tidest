import CoreGraphics
import ApplicationServices
import XCTest
@testable import tidest

final class QuickLayoutTests: XCTestCase {
    func testSystemRecordingOverlaysDoNotBlockSelectionOrHideTheWindowHighlight() throws {
        let primary = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let secondary = CGRect(x: -1200, y: -200, width: 1200, height: 900)
        let point = CGPoint(x: -600, y: 300)
        let cursor = WindowLayoutService.ScreenWindow(id: 1, processID: 10,
            frame: CGRect(x: point.x, y: point.y, width: 28, height: 40),
            layer: Int(CGWindowLevelForKey(.cursorWindow)), order: 0)
        let overlays = [primary, secondary].enumerated().map { index, frame in
            WindowLayoutService.ScreenWindow(id: CGWindowID(index + 2), processID: 20,
                frame: frame, layer: Int(CGWindowLevelForKey(.mainMenuWindow)), order: index + 1)
        }
        let application = WindowLayoutService.ScreenWindow(id: 4, processID: 30,
            frame: CGRect(x: -1100, y: -100, width: 1000, height: 700), layer: 0, order: 3)
        let windows = WindowLayoutService.excludingSystemOverlays(
            from: [cursor] + overlays + [application], screens: [primary, secondary]) {
                $0 == 20 ? "com.apple.screencaptureui" : nil
            }

        let selected = try XCTUnwrap(WindowLayoutService.selectSnapshot(at: point, in: windows, ownProcessID: 40))
        XCTAssertEqual(selected.id, application.id)
        let visible = QuickLayoutGeometry.visibleRegions(of: selected.frame,
            occluders: windows.filter { $0.order < selected.order }.map(\.frame), screens: [primary, secondary])
        XCTAssertEqual(visible, [application.frame])
    }

    func testRealPopupStillBlocksSelectionDuringRecording() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let overlay = WindowLayoutService.ScreenWindow(id: 1, processID: 20,
            frame: screen, layer: Int(CGWindowLevelForKey(.mainMenuWindow)), order: 0)
        let popup = WindowLayoutService.ScreenWindow(id: 2, processID: 30,
            frame: CGRect(x: 100, y: 100, width: 200, height: 200), layer: 8, order: 1)
        let application = WindowLayoutService.ScreenWindow(id: 3, processID: 30,
            frame: screen, layer: 0, order: 2)
        let windows = WindowLayoutService.excludingSystemOverlays(
            from: [overlay, popup, application], screens: [screen]) {
                $0 == 20 ? "com.apple.screencaptureui" : nil
            }

        XCTAssertNil(WindowLayoutService.selectSnapshot(at: CGPoint(x: 150, y: 150), in: windows, ownProcessID: 40))
        XCTAssertEqual(WindowLayoutService.selectSnapshot(at: CGPoint(x: 500, y: 500), in: windows, ownProcessID: 40)?.id,
                       application.id)
        let visible = QuickLayoutGeometry.visibleRegions(of: application.frame,
            occluders: windows.filter { $0.order < application.order }.map(\.frame), screens: [screen])
        XCTAssertEqual(totalArea(visible), screen.width * screen.height - popup.frame.width * popup.frame.height)
    }

    func testOtherFullscreenOverlaysStillBlockSelection() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let overlay = WindowLayoutService.ScreenWindow(id: 1, processID: 20,
            frame: screen, layer: Int(CGWindowLevelForKey(.mainMenuWindow)), order: 0)
        let application = WindowLayoutService.ScreenWindow(id: 2, processID: 30,
            frame: screen, layer: 0, order: 1)
        for bundleIdentifier in ["com.example.overlay", nil] {
            let windows = WindowLayoutService.excludingSystemOverlays(from: [overlay, application], screens: [screen]) {
                _ in bundleIdentifier
            }
            XCTAssertNil(WindowLayoutService.selectSnapshot(at: CGPoint(x: 500, y: 500), in: windows, ownProcessID: 40))
        }
    }

    func testScreenshotControlsAndPartialOverlaysStillBlockSelection() {
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let application = WindowLayoutService.ScreenWindow(id: 2, processID: 30,
            frame: screen, layer: 0, order: 1)
        for layer in [CGWindowLevelForKey(.mainMenuWindow), CGWindowLevelForKey(.screenSaverWindow) + 499] {
            let control = WindowLayoutService.ScreenWindow(id: 1, processID: 20,
                frame: CGRect(x: 100, y: 100, width: 800, height: 50), layer: Int(layer), order: 0)
            let windows = WindowLayoutService.excludingSystemOverlays(from: [control, application], screens: [screen]) {
                _ in "com.apple.screencaptureui"
            }
            XCTAssertNil(WindowLayoutService.selectSnapshot(at: CGPoint(x: 500, y: 125), in: windows, ownProcessID: 40))
        }
    }

    func testRightHalfCanFillTheScreenAfterAnInitiallyLimitedResize() async {
        let area = CGRect(x: 0, y: 24, width: 1200, height: 800)
        let window = LayoutWindow(frame: area, screens: [area])
        let halfResult = await window.apply(.right, in: area)
        XCTAssertEqual(halfResult, .exact)
        XCTAssertEqual(window.frame, CGRect(x: 600, y: 24, width: 600, height: 800))

        let fullResult = await window.apply(.full, in: area)
        XCTAssertEqual(fullResult, .exact)
        XCTAssertEqual(window.frame, area)
    }

    func testEveryLayoutTransitionCanResizeAtScreenEdges() async {
        let area = CGRect(x: -1200, y: -900, width: 1200, height: 800)
        for initial in QuickLayout.allCases {
            for destination in QuickLayout.allCases {
                let window = LayoutWindow(frame: initial.frame(in: area), screens: [area])
                let result = await window.apply(destination, in: area)
                XCTAssertEqual(result, .exact, "\(initial) → \(destination)")
                XCTAssertEqual(window.frame, destination.frame(in: area), "\(initial) → \(destination)")
                XCTAssertTrue(window.positions.allSatisfy { area.contains($0) })
            }
        }
    }

    func testMovingToALargerDisplayReleasesTheOldDisplaysSizeLimit() async {
        let small = CGRect(x: 0, y: 24, width: 800, height: 600)
        let large = CGRect(x: -1600, y: -976, width: 1600, height: 1000)
        let window = LayoutWindow(frame: QuickLayout.right.frame(in: small), screens: [small, large])
        let result = await window.apply(.full, in: large)
        XCTAssertEqual(result, .exact)
        XCTAssertEqual(window.frame, large)
    }

    func testPermanentMinimumSizeStillKeepsTheRequestedAlignment() async {
        let area = CGRect(x: 100, y: 40, width: 1200, height: 800)
        let minimum = CGSize(width: 760, height: 560)
        for layout in QuickLayout.allCases {
            let window = LayoutWindow(frame: CGRect(origin: area.origin, size: minimum), screens: [area])
            window.minimumSize = minimum
            let result = await window.apply(layout, in: area)
            let requested = layout.frame(in: area)
            let expectedSize = CGSize(width: max(minimum.width, requested.width),
                                      height: max(minimum.height, requested.height))
            XCTAssertEqual(result, expectedSize == requested.size ? .exact : .constrained)
            XCTAssertEqual(window.frame, layout.anchoredFrame(size: expectedSize, in: area))
            XCTAssertTrue(window.positions.allSatisfy { area.contains($0) })
        }
    }

    func testFixedSizeWindowsAreAlignedWithoutAttemptingAResize() async {
        let area = CGRect(x: 0, y: 24, width: 1200, height: 800)
        let size = CGSize(width: 400, height: 300)
        for layout in QuickLayout.allCases {
            let window = LayoutWindow(frame: CGRect(origin: area.origin, size: size), screens: [area])
            window.resizable = false
            let result = await window.apply(layout, in: area)
            XCTAssertEqual(result, .constrained)
            XCTAssertEqual(window.frame, layout.anchoredFrame(size: size, in: area))
            XCTAssertEqual(window.resizeCount, 0)
        }
    }

    func testFailedResizeAfterMovingIsNotReportedAsASizeLimit() async {
        let area = CGRect(x: 0, y: 24, width: 1200, height: 800)
        let window = LayoutWindow(frame: QuickLayout.right.frame(in: area), screens: [area])
        window.resizeErrorAfterMoving = .cannotComplete
        let result = await window.apply(.full, in: area)
        XCTAssertEqual(result, .unavailable)
    }

    func testIgnoredMoveIsNotReportedAsASizeLimit() async {
        let area = CGRect(x: 0, y: 24, width: 1200, height: 800)
        let window = LayoutWindow(frame: QuickLayout.right.frame(in: area), screens: [area])
        window.ignoresPosition = true
        let result = await window.apply(.full, in: area)
        XCTAssertEqual(result, .unavailable)
    }

    func testNumberedLayoutsFillTheExpectedPartsOfAnOffsetDisplay() {
        let area = CGRect(x: -1200, y: -900, width: 1200, height: 800)
        let expected: [CGRect] = [
            CGRect(x: -1200, y: -900, width: 600, height: 400),
            CGRect(x: -1200, y: -900, width: 1200, height: 400),
            CGRect(x: -600, y: -900, width: 600, height: 400),
            CGRect(x: -1200, y: -900, width: 600, height: 800),
            area,
            CGRect(x: -600, y: -900, width: 600, height: 800),
            CGRect(x: -1200, y: -500, width: 600, height: 400),
            CGRect(x: -1200, y: -500, width: 1200, height: 400),
            CGRect(x: -600, y: -500, width: 600, height: 400)
        ]
        XCTAssertEqual(QuickLayout.allCases.map(\.rawValue), Array(1...9))
        for layout in QuickLayout.allCases {
            XCTAssertEqual(layout.frame(in: area), expected[layout.id - 1])
        }
    }

    func testAWindowsMinimumSizeKeepsTheRequestedCornerOrEdge() {
        let area = CGRect(x: 100, y: 40, width: 1200, height: 800)
        let actualSize = CGSize(width: 760, height: 560)
        let expectedOrigins: [CGPoint] = [
            CGPoint(x: 100, y: 40), CGPoint(x: 320, y: 40), CGPoint(x: 540, y: 40),
            CGPoint(x: 100, y: 160), CGPoint(x: 320, y: 160), CGPoint(x: 540, y: 160),
            CGPoint(x: 100, y: 280), CGPoint(x: 320, y: 280), CGPoint(x: 540, y: 280)
        ]
        for layout in QuickLayout.allCases {
            let actual = layout.anchoredFrame(size: actualSize, in: area)
            XCTAssertEqual(actual.origin, expectedOrigins[layout.id - 1])
            XCTAssertEqual(actual.size, actualSize)
            XCTAssertTrue(area.contains(actual))
        }
    }

    func testOversizedWindowsRetainTheirSizeAndKeepTheTitleBarAccessible() {
        let area = CGRect(x: -800, y: 24, width: 800, height: 600)
        for layout in QuickLayout.allCases {
            let bothOversized = layout.anchoredFrame(size: CGSize(width: 1200, height: 900), in: area)
            XCTAssertEqual(bothOversized.origin, area.origin)
            XCTAssertEqual(bothOversized.size, CGSize(width: 1200, height: 900))
            let tall = layout.anchoredFrame(size: CGSize(width: 400, height: 900), in: area)
            XCTAssertEqual(tall.minY, area.minY)
            XCTAssertGreaterThanOrEqual(tall.minX, area.minX)
            XCTAssertLessThanOrEqual(tall.maxX, area.maxX)
        }
    }

    func testCoordinateConversionUsesThePrimaryScreenEvenForDisplaysAboveAndToTheLeft() {
        let pointer = CGPoint(x: -650, y: 1400)
        XCTAssertEqual(QuickLayoutGeometry.axPoint(from: pointer, primaryScreenTop: 1080),
                       CGPoint(x: -650, y: -320))
        let axFrame = CGRect(x: -1000, y: -720, width: 1000, height: 720)
        XCTAssertEqual(QuickLayoutGeometry.appKitRect(from: axFrame, primaryScreenTop: 1080),
                       CGRect(x: -1000, y: 1080, width: 1000, height: 720))
        let primary = CGRect(x: 0, y: 24, width: 1920, height: 1030)
        XCTAssertEqual(QuickLayoutGeometry.appKitRect(from: primary, primaryScreenTop: 1080),
                       CGRect(x: 0, y: 26, width: 1920, height: 1030))
    }

    func testInteriorOcclusionLeavesFourDisjointRegionsWithTheRightVisibleArea() {
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        let cover = CGRect(x: 20, y: 30, width: 50, height: 40)
        let regions = QuickLayoutGeometry.visibleRegions(of: window, occluders: [cover], screens: [window])
        XCTAssertEqual(regions.count, 4)
        XCTAssertEqual(totalArea(regions), 8000)
        assertVisible(regions, within: window, excluding: [cover])
        XCTAssertTrue(regions.contains { $0.contains(CGPoint(x: 10, y: 50)) })
        XCTAssertTrue(regions.contains { $0.contains(CGPoint(x: 90, y: 50)) })
        XCTAssertTrue(regions.contains { $0.contains(CGPoint(x: 50, y: 10)) })
        XCTAssertTrue(regions.contains { $0.contains(CGPoint(x: 50, y: 90)) })
    }

    func testOverlappingOccludersAreSubtractedOnlyOnceAndOffscreenSpaceIsExcluded() {
        let window = CGRect(x: -100, y: -40, width: 300, height: 160)
        let screen = CGRect(x: 0, y: 0, width: 200, height: 100)
        let covers = [CGRect(x: 0, y: 0, width: 100, height: 80),
                      CGRect(x: 50, y: 20, width: 100, height: 80)]
        let regions = QuickLayoutGeometry.visibleRegions(of: window, occluders: covers, screens: [screen])
        XCTAssertEqual(totalArea(regions), 7000)
        assertVisible(regions, within: screen, excluding: covers)
        let reversed = QuickLayoutGeometry.visibleRegions(of: window, occluders: covers.reversed(), screens: [screen])
        XCTAssertEqual(totalArea(reversed), 7000)
        XCTAssertTrue(QuickLayoutGeometry.visibleRegions(of: window, occluders: [window], screens: [screen]).isEmpty)
        XCTAssertTrue(QuickLayoutGeometry.visibleRegions(of: window, occluders: [], screens: []).isEmpty)
    }

    func testWindowAcrossOffsetDisplaysDoesNotHighlightTheGapBetweenThem() {
        let window = CGRect(x: -200, y: -100, width: 400, height: 300)
        let left = CGRect(x: -500, y: -300, width: 400, height: 400)
        let right = CGRect(x: 0, y: 0, width: 500, height: 400)
        let regions = QuickLayoutGeometry.visibleRegions(of: window, occluders: [], screens: [left, right])
        XCTAssertEqual(totalArea(regions), 60000)
        XCTAssertTrue(regions.contains { $0.contains(CGPoint(x: -150, y: 50)) })
        XCTAssertTrue(regions.contains { $0.contains(CGPoint(x: 150, y: 150)) })
        XCTAssertFalse(regions.contains { $0.contains(CGPoint(x: -50, y: 50)) })
        XCTAssertFalse(regions.contains { $0.contains(CGPoint(x: 150, y: -50)) })
    }

    func testOverlappingDisplayBoundsDoNotDuplicateTheHighlight() {
        let window = CGRect(x: 0, y: 0, width: 200, height: 100)
        let screens = [CGRect(x: 0, y: 0, width: 150, height: 100),
                       CGRect(x: 100, y: 0, width: 100, height: 100)]
        let regions = QuickLayoutGeometry.visibleRegions(of: window, occluders: [], screens: screens)
        XCTAssertEqual(totalArea(regions), 20000)
        assertVisible(regions, within: window, excluding: [])
    }

    func testPanelIsCenteredOnThePointerWhenThereIsEnoughSpace() {
        let screen = CGRect(x: -1200, y: 0, width: 1200, height: 900)
        let pointer = CGPoint(x: -800, y: 600)
        let frame = QuickLayoutGeometry.centeredPanelFrame(at: pointer, size: CGSize(width: 300, height: 340), in: screen)
        XCTAssertEqual(frame.midX, pointer.x)
        XCTAssertEqual(frame.midY, pointer.y)
        XCTAssertEqual(frame.size, CGSize(width: 300, height: 340))
        XCTAssertTrue(screen.contains(frame))
    }

    func testPanelOnlyShiftsTheNecessaryDistanceAtScreenEdgesAndCorners() {
        let screen = CGRect(x: -1200, y: 1080, width: 1200, height: 900)
        let size = CGSize(width: 300, height: 340)
        let cases: [(pointer: CGPoint, origin: CGPoint)] = [
            (screen.origin, screen.origin),
            (CGPoint(x: 0, y: 1980), CGPoint(x: -300, y: 1640)),
            (CGPoint(x: -1200, y: 1980), CGPoint(x: -1200, y: 1640)),
            (CGPoint(x: -10, y: 1090), CGPoint(x: -300, y: 1080)),
            (CGPoint(x: -600, y: 1530), CGPoint(x: -750, y: 1360)),
            (CGPoint(x: -1200, y: 1530), CGPoint(x: -1200, y: 1360)),
            (CGPoint(x: 0, y: 1530), CGPoint(x: -300, y: 1360)),
            (CGPoint(x: -600, y: 1080), CGPoint(x: -750, y: 1080)),
            (CGPoint(x: -600, y: 1980), CGPoint(x: -750, y: 1640))
        ]
        for (pointer, origin) in cases {
            let panel = QuickLayoutGeometry.centeredPanelFrame(at: pointer, size: size, in: screen)
            XCTAssertEqual(panel, CGRect(origin: origin, size: size), "Unexpected position for pointer \(pointer)")
            XCTAssertTrue(screen.contains(panel), "Panel escapes its display for pointer \(pointer)")
        }
    }

    // Model a window whose resize is limited by the space to its right and
    // below, while keeping permanent minimum sizes separate from that limit.
    private final class LayoutWindow {
        var frame: CGRect
        let screens: [CGRect]
        var minimumSize = CGSize.zero
        var resizable = true
        var ignoresPosition = false
        var resizeErrorAfterMoving: AXError?
        var positions: [CGRect] = []
        var resizeCount = 0

        init(frame: CGRect, screens: [CGRect]) {
            self.frame = frame
            self.screens = screens
        }

        func apply(_ layout: QuickLayout, in area: CGRect) async -> WindowLayoutResult {
            await WindowLayoutService.performLayout(layout, in: area,
                readFrame: { self.frame },
                isSettable: { $0 != kAXSizeAttribute || self.resizable },
                setSize: { size in
                    self.resizeCount += 1
                    if !self.positions.isEmpty, let error = self.resizeErrorAfterMoving { return error }
                    guard let screen = self.screens.first(where: { $0.contains(self.frame.origin) })
                    else { return .cannotComplete }
                    self.frame.size = CGSize(
                        width: max(self.minimumSize.width, min(size.width, screen.maxX - self.frame.minX)),
                        height: max(self.minimumSize.height, min(size.height, screen.maxY - self.frame.minY)))
                    return .success
                },
                setPosition: { point in
                    if !self.ignoresPosition { self.frame.origin = point }
                    self.positions.append(self.frame)
                    return .success
                },
                pause: { true })
        }
    }

    private func totalArea(_ regions: [CGRect]) -> CGFloat {
        regions.reduce(0) { $0 + $1.width * $1.height }
    }

    private func assertVisible(_ regions: [CGRect], within bounds: CGRect, excluding occluders: [CGRect],
                               file: StaticString = #filePath, line: UInt = #line) {
        for (index, region) in regions.enumerated() {
            XCTAssertFalse(region.isEmpty, file: file, line: line)
            XCTAssertTrue(bounds.contains(region), file: file, line: line)
            for occluder in occluders {
                XCTAssertTrue(region.intersection(occluder).isEmpty, file: file, line: line)
            }
            for other in regions.dropFirst(index + 1) {
                XCTAssertTrue(region.intersection(other).isEmpty, file: file, line: line)
            }
        }
    }
}
