import AppKit
import XCTest
@testable import tidest

final class WindowTileLayoutTests: XCTestCase {
    func testEmptyLayoutHasNoCardsOrScrollOverflow() {
        let viewport = CGSize(width: 1280, height: 600)
        let layout = WindowTileLayout(viewportSize: viewport, aspectRatios: [])
        XCTAssertEqual(layout.rowCount, 0)
        XCTAssertEqual(layout.previewHeight, 0)
        XCTAssertEqual(layout.contentSize, viewport)
    }

    func testSingleWindowIsCenteredAndKeepsItsOriginalRatio() {
        for ratio: CGFloat in [0.4, 1, 1.6, 3.2, 12] {
            let layout = WindowTileLayout(viewportSize: CGSize(width: 1280, height: 600), aspectRatios: [ratio])
            let frame = layout.frame(for: 0)
            XCTAssertEqual(frame.midX, 640, accuracy: 0.001)
            XCTAssertEqual(frame.midY, 300, accuracy: 0.001)
            XCTAssertEqual(frame.width / frame.height, ratio, accuracy: 0.001)
            XCTAssertLessThanOrEqual(frame.width, WindowTileLayout.maximumPreviewWidth + 0.001)
            XCTAssertLessThanOrEqual(frame.height, layout.previewHeight + 0.001)
            XCTAssertEqual(layout.verticalOffset(revealing: 0, currentOffset: 0), 0)
        }
    }

    func testWindowCountAddsRowsWithoutShrinkingPreviews() {
        for viewport in [CGSize(width: 1024, height: 500), CGSize(width: 1728, height: 900), CGSize(width: 2560, height: 1400)] {
            let sparse = WindowTileLayout(viewportSize: viewport, aspectRatios: Array(repeating: 1.6, count: 6))
            let dense = WindowTileLayout(viewportSize: viewport, aspectRatios: Array(repeating: 1.6, count: 150))
            XCTAssertEqual(sparse.previewHeight, dense.previewHeight)
            for index in 0..<6 {
                XCTAssertEqual(sparse.frame(for: index).size, dense.frame(for: index).size)
            }
            XCTAssertGreaterThanOrEqual(dense.frame(for: 0).width, 220)
            XCTAssertGreaterThanOrEqual(dense.frame(for: 0).height, 140)
            XCTAssertEqual(dense.contentSize.width, viewport.width)
            XCTAssertGreaterThan(dense.contentSize.height, viewport.height)
        }
    }

    func testManyDifferentWindowRatiosNeverOverlapOrOverflowHorizontally() {
        let ratios: [CGFloat] = (0..<150).map { [0.4, 0.7, 1, 1.6, 2.8, 12][$0 % 6] }
        for viewport in [CGSize(width: 800, height: 240), CGSize(width: 1024, height: 500), CGSize(width: 1728, height: 900), CGSize(width: 2560, height: 1400)] {
            let layout = WindowTileLayout(viewportSize: viewport, aspectRatios: ratios)
            let frames = ratios.indices.map { layout.frame(for: $0) }
            XCTAssertGreaterThan(layout.rowCount, 3)
            for (index, frame) in frames.enumerated() {
                XCTAssertGreaterThanOrEqual(frame.minX, WindowTileLayout.horizontalPadding)
                XCTAssertGreaterThanOrEqual(frame.minY, 0)
                XCTAssertLessThanOrEqual(frame.maxX, layout.contentSize.width - WindowTileLayout.horizontalPadding + 0.001)
                XCTAssertLessThanOrEqual(frame.maxY, layout.contentSize.height - WindowTileLayout.verticalPadding + 0.001)
                XCTAssertEqual(frame.width / frame.height, ratios[index], accuracy: 0.001)
                for other in frames.dropFirst(index + 1) {
                    XCTAssertFalse(frame.intersects(other), "Cards overlap at index \(index) on \(viewport)")
                }
            }
        }
    }

    func testRowsFillLeftToRightBeforeAdvancingDownAndKeepOriginalWidths() {
        let ratios: [CGFloat] = [0.4, 1, 1.6, 2, 3, 0.8, 1.2, 0.6, 2.5, 0.7]
        let layout = WindowTileLayout(viewportSize: CGSize(width: 1280, height: 1000), aspectRatios: ratios)
        XCTAssertEqual(layout.rowCount, 3)
        for index in 1..<ratios.count {
            let previous = layout.frame(for: index - 1)
            let current = layout.frame(for: index)
            if abs(current.midY - previous.midY) < 0.001 {
                XCTAssertEqual(current.minX - previous.maxX, WindowTileLayout.gap, accuracy: 0.001)
            } else {
                XCTAssertGreaterThan(current.midY, previous.midY)
                XCTAssertEqual(current.minX, WindowTileLayout.horizontalPadding)
                XCTAssertGreaterThan(previous.maxX + WindowTileLayout.gap + current.width,
                                     layout.viewportSize.width - WindowTileLayout.horizontalPadding)
            }
        }
        XCTAssertNotEqual(layout.frame(for: 0).width, layout.frame(for: 1).width)
        XCTAssertEqual(layout.frame(for: 0).height, layout.frame(for: 1).height)
    }

    func testKeyboardSelectionRevealsOnlyOffscreenCardsAndClampsScrollBounds() {
        let layout = WindowTileLayout(viewportSize: CGSize(width: 1280, height: 700), aspectRatios: Array(repeating: 1.6, count: 150))
        XCTAssertEqual(layout.verticalOffset(revealing: 0, currentOffset: 0), 0)
        let last = layout.frame(for: 149)
        let end = layout.verticalOffset(revealing: 149, currentOffset: 0)
        XCTAssertGreaterThan(end, 0)
        XCTAssertGreaterThanOrEqual(last.minY, end + WindowTileLayout.verticalPadding - 0.001)
        XCTAssertLessThanOrEqual(last.maxY, end + layout.viewportSize.height - WindowTileLayout.verticalPadding + 0.001)
        XCTAssertEqual(layout.verticalOffset(revealing: 149, currentOffset: end), end)
        XCTAssertEqual(layout.verticalOffset(revealing: 0, currentOffset: end), 0)
        XCTAssertEqual(layout.verticalOffset(revealing: 149, currentOffset: .greatestFiniteMagnitude), layout.contentSize.height - layout.viewportSize.height)
    }

    func testVeryWideWindowsKeepTheirRatioAndCanBeFullyRevealed() {
        for viewport in [CGSize(width: 480, height: 300), CGSize(width: 1024, height: 500), CGSize(width: 1728, height: 900)] {
            let ratios: [CGFloat] = Array(repeating: [CGFloat(1.6), 0.4, 12], count: 30).flatMap { $0 }
            let layout = WindowTileLayout(viewportSize: viewport, aspectRatios: ratios)
            for index in ratios.indices where ratios[index] == 12 {
                let frame = layout.frame(for: index)
                XCTAssertEqual(frame.width / frame.height, 12, accuracy: 0.001)
                XCTAssertLessThan(frame.height, layout.previewHeight)
                XCTAssertLessThanOrEqual(frame.width, viewport.width - 2 * WindowTileLayout.horizontalPadding + 0.001)
                XCTAssertLessThanOrEqual(frame.width, WindowTileLayout.maximumPreviewWidth + 0.001)
                let offset = layout.verticalOffset(revealing: index, currentOffset: 0)
                XCTAssertGreaterThanOrEqual(frame.minY, offset + WindowTileLayout.verticalPadding - 0.001)
                XCTAssertLessThanOrEqual(frame.maxY, offset + viewport.height - WindowTileLayout.verticalPadding + 0.001)
            }
        }
    }
}
