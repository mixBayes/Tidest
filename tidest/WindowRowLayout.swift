import Foundation

nonisolated struct WindowRowLayout {
    static let minimumMargin: CGFloat = 100
    static let maximumGap: CGFloat = 48
    static let angle = 69.0
    static let perspective = 0.55
    static let foldedScale = 0.84
    let cardWidths: [CGFloat]
    let cardHeight: CGFloat
    let deckHeight: CGFloat
    let rowWidth: CGFloat
    private let centers: [CGFloat]
    private let bounds: [ClosedRange<CGFloat>]

    init(screenWidth: CGFloat, aspectRatios: [CGFloat], selectedIndex: Int = 0) {
        guard !aspectRatios.isEmpty else {
            cardWidths = []
            cardHeight = 0
            deckHeight = 0
            rowWidth = 0
            centers = []
            bounds = []
            return
        }
        let available = max(0, screenWidth - 2 * Self.minimumMargin)
        let radians = CGFloat(Self.angle) * .pi / 180
        let scale = CGFloat(Self.foldedScale)
        // SwiftUI normalizes perspective by the view's longest side. A portrait
        // image therefore has less perspective depth than a landscape image.
        let depths = aspectRatios.map { CGFloat(Self.perspective) * sin(radians) * min(1, $0) }
        let foldedRatios = zip(aspectRatios, depths).map { ratio, depth in
            ratio * cos(radians) * scale / (1 - pow(depth / 2, 2))
        }
        let widest = aspectRatios.indices.sorted { aspectRatios[$0] > aspectRatios[$1] }
        var spanRatio = aspectRatios[widest[0]]
        if widest.count > 1 {
            spanRatio = max(spanRatio + 2 * foldedRatios[widest[1]], aspectRatios[widest[1]] + 2 * foldedRatios[widest[0]])
        }
        // Reserve room for any window to become selected. Keep the common
        // height stable while cycling, including when a very wide window exists.
        let preferredHeight = min(325, aspectRatios.count == 1 ? 325 : available * 0.3)
        let height = min(preferredHeight, available / spanRatio)
        let widths = aspectRatios.map { height * $0 }
        let foldedWidths = foldedRatios.map { height * $0 }
        let shifts = zip(foldedWidths, depths).map { width, depth in width * depth / 4 }

        var selection = WindowSelection()
        selection.begin(count: aspectRatios.count, steps: selectedIndex)
        let distances = aspectRatios.indices.map { selection.distance(to: $0) }
        let left = aspectRatios.indices.filter { distances[$0] < 0 }.sorted { abs(distances[$0]) < abs(distances[$1]) }
        let right = aspectRatios.indices.filter { distances[$0] > 0 }.sorted { abs(distances[$0]) < abs(distances[$1]) }
        let halfSide = (available - widths[selection.index]) / 2
        let widestSide = (left + right).map { foldedWidths[$0] }.max() ?? 0
        let gap = min(Self.maximumGap, max(0, halfSide - widestSide))
        // Adjacent pages advance by a common step, overlapping when necessary.
        // Bound that step for every image, rather than assuming equal widths.
        var step = (Array(left.dropLast()) + Array(right.dropLast())).map { foldedWidths[$0] + Self.maximumGap }.min() ?? 0
        for side in [left, right] {
            for (rank, index) in side.enumerated() where rank > 0 {
                step = min(step, (halfSide - gap - foldedWidths[index]) / CGFloat(rank))
            }
        }
        step = max(0, step)

        let selectedCenter = screenWidth / 2
        var positions = Array(repeating: selectedCenter, count: aspectRatios.count)
        var ranges = Array(repeating: selectedCenter...selectedCenter, count: aspectRatios.count)
        ranges[selection.index] = (selectedCenter - widths[selection.index] / 2)...(selectedCenter + widths[selection.index] / 2)
        for side in [left, right] {
            for (rank, index) in side.enumerated() {
                let sign: CGFloat = distances[index] < 0 ? -1 : 1
                let offset = widths[selection.index] / 2 + gap + CGFloat(rank) * step + foldedWidths[index] / 2
                let projectedCenter = selectedCenter + sign * offset
                positions[index] = projectedCenter - sign * shifts[index]
                ranges[index] = (projectedCenter - foldedWidths[index] / 2)...(projectedCenter + foldedWidths[index] / 2)
            }
        }
        cardWidths = widths
        cardHeight = height
        let foldedHeight = depths.map { height * scale / (1 - $0 / 2) }.max() ?? height
        deckHeight = max(height, foldedHeight) + 40
        rowWidth = ranges.map(\.upperBound).max()! - ranges.map(\.lowerBound).min()!
        centers = positions
        bounds = ranges
    }
    func center(for index: Int) -> CGFloat {
        centers[index]
    }
    func projectedBounds(for index: Int) -> ClosedRange<CGFloat> {
        bounds[index]
    }
}
