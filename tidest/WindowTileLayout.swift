import CoreGraphics
import Foundation

nonisolated struct WindowTileLayout {
    static let horizontalPadding: CGFloat = 36
    static let verticalPadding: CGFloat = 16
    static let gap: CGFloat = 24
    static let maximumPreviewWidth: CGFloat = 560

    let viewportSize: CGSize
    let previewHeight: CGFloat
    let rowCount: Int
    let contentSize: CGSize
    private let frames: [CGRect]

    init(viewportSize: CGSize, aspectRatios: [CGFloat]) {
        self.viewportSize = viewportSize
        precondition(aspectRatios.allSatisfy { $0.isFinite && $0 > 0 })
        guard !aspectRatios.isEmpty else {
            previewHeight = 0
            rowCount = 0
            contentSize = viewportSize
            frames = []
            return
        }

        let availableWidth = max(1, viewportSize.width - 2 * Self.horizontalPadding)
        let availableHeight = max(1, viewportSize.height - 2 * Self.verticalPadding)
        // Fill each row from left to right, then add rows below it. Adding
        // windows never shrinks the previews or widens the scroll document.
        let height = min(240, max(140, availableWidth * 0.18), availableHeight)
        let maximumWidth = min(Self.maximumPreviewWidth, availableWidth)
        var row = 0
        var x: CGFloat = 0
        var positions: [CGRect] = []
        for ratio in aspectRatios {
            let imageHeight = min(height, maximumWidth / ratio)
            let imageWidth = imageHeight * ratio
            if x > 0, x + Self.gap + imageWidth > availableWidth {
                row += 1
                x = 0
            }
            if x > 0 { x += Self.gap }
            positions.append(CGRect(x: Self.horizontalPadding + x,
                                    y: CGFloat(row) * (height + Self.gap) + (height - imageHeight) / 2,
                                    width: imageWidth, height: imageHeight))
            x += imageWidth
        }
        let rows = row + 1
        let gridHeight = CGFloat(rows) * height + CGFloat(rows - 1) * Self.gap
        let contentHeight = max(viewportSize.height, gridHeight + 2 * Self.verticalPadding)
        let gridY = (contentHeight - gridHeight) / 2
        for index in positions.indices {
            positions[index].origin.y += gridY
        }
        if positions.count == 1 { positions[0].origin.x = (viewportSize.width - positions[0].width) / 2 }
        previewHeight = height
        rowCount = rows
        contentSize = CGSize(width: viewportSize.width, height: contentHeight)
        frames = positions
    }

    func frame(for index: Int) -> CGRect {
        frames[index]
    }

    func verticalOffset(revealing index: Int, currentOffset: CGFloat) -> CGFloat {
        let bounds = frame(for: index)
        let maximum = max(0, contentSize.height - viewportSize.height)
        var offset = min(maximum, max(0, currentOffset))
        if bounds.minY < offset + Self.verticalPadding {
            offset = bounds.minY - Self.verticalPadding
        } else if bounds.maxY > offset + viewportSize.height - Self.verticalPadding {
            offset = bounds.maxY + Self.verticalPadding - viewportSize.height
        }
        return min(maximum, max(0, offset))
    }
}
