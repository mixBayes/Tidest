import CoreGraphics

/// Window frames use Accessibility's coordinates: x grows right and y grows down.
nonisolated enum QuickLayout: Int, CaseIterable, Identifiable, Sendable {
    case topLeft = 1
    case top = 2
    case topRight = 3
    case left = 4
    case full = 5
    case right = 6
    case bottomLeft = 7
    case bottom = 8
    case bottomRight = 9

    var id: Int { rawValue }

    var titleKey: String {
        switch self {
        case .topLeft: "左上角"
        case .top: "上半屏"
        case .topRight: "右上角"
        case .left: "左半屏"
        case .full: "铺满屏幕"
        case .right: "右半屏"
        case .bottomLeft: "左下角"
        case .bottom: "下半屏"
        case .bottomRight: "右下角"
        }
    }

    func frame(in area: CGRect) -> CGRect {
        let width: CGFloat
        let height: CGFloat
        switch self {
        case .top, .bottom, .full: width = area.width
        default: width = area.width / 2
        }
        switch self {
        case .left, .right, .full: height = area.height
        default: height = area.height / 2
        }
        return anchoredFrame(size: CGSize(width: width, height: height), in: area)
    }

    /// After an app enforces its own size limits, retain the requested alignment.
    func anchoredFrame(size: CGSize, in area: CGRect) -> CGRect {
        let x: CGFloat
        let y: CGFloat
        switch self {
        case .topLeft, .left, .bottomLeft: x = area.minX
        case .topRight, .right, .bottomRight: x = area.maxX - size.width
        case .top, .full, .bottom: x = area.midX - size.width / 2
        }
        switch self {
        case .topLeft, .top, .topRight: y = area.minY
        case .bottomLeft, .bottom, .bottomRight: y = area.maxY - size.height
        case .left, .full, .right: y = area.midY - size.height / 2
        }
        // An oversized window cannot fit. Keep the title bar and its left-side
        // controls on screen instead of centering them outside the display.
        return CGRect(x: size.width > area.width ? area.minX : x,
                      y: size.height > area.height ? area.minY : y,
                      width: size.width, height: size.height)
    }
}

nonisolated enum QuickLayoutGeometry {
    static func axPoint(from point: CGPoint, primaryScreenTop: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenTop - point.y)
    }

    static func appKitRect(from rect: CGRect, primaryScreenTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenTop - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Returns the parts of a window that are on a screen and not covered by
    /// a window in front of it. All inputs and outputs share AX coordinates.
    static func visibleRegions(of frame: CGRect, occluders: [CGRect], screens: [CGRect]) -> [CGRect] {
        var regions: [CGRect] = []
        for screen in screens {
            let clipped = frame.intersection(screen)
            guard !clipped.isNull, !clipped.isEmpty else { continue }
            var additions = [clipped]
            // Overlapping or mirrored display rectangles must not produce
            // duplicate highlight regions.
            for existing in regions {
                additions = additions.flatMap { subtract(existing, from: $0) }
            }
            regions.append(contentsOf: additions)
        }
        for occluder in occluders {
            regions = regions.flatMap { subtract(occluder, from: $0) }
            if regions.isEmpty { break }
        }
        return regions
    }

    /// The panel uses AppKit coordinates, where y grows upward.
    static func panelFrame(near pointer: CGPoint, size: CGSize, in visibleFrame: CGRect) -> CGRect {
        let gap: CGFloat = 12
        var x = pointer.x + gap
        var y = pointer.y - gap - size.height
        if x + size.width > visibleFrame.maxX {
            x = pointer.x - gap - size.width
        }
        if y < visibleFrame.minY {
            y = pointer.y + gap
        }
        x = min(max(x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - size.width))
        y = min(max(y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - size.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// A carried preview is held at its centre, rather than beside the pointer.
    static func centeredPanelFrame(at pointer: CGPoint, size: CGSize, in visibleFrame: CGRect) -> CGRect {
        let x = min(max(pointer.x - size.width / 2, visibleFrame.minX),
                    max(visibleFrame.minX, visibleFrame.maxX - size.width))
        let y = min(max(pointer.y - size.height / 2, visibleFrame.minY),
                    max(visibleFrame.minY, visibleFrame.maxY - size.height))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Shrink toward the current pointer while translating the original frame
    /// by every mouse movement, so following never waits for the shrink to end.
    static func pickupPanelFrame(from initialFrame: CGRect, initialPointer: CGPoint,
                                 at pointer: CGPoint, size: CGSize, in visibleFrame: CGRect,
                                 progress: CGFloat) -> CGRect {
        let start = initialFrame.offsetBy(dx: pointer.x - initialPointer.x, dy: pointer.y - initialPointer.y)
        let end = centeredPanelFrame(at: pointer, size: size, in: visibleFrame)
        let progress = min(1, max(0, progress))
        return CGRect(x: start.minX + (end.minX - start.minX) * progress,
                      y: start.minY + (end.minY - start.minY) * progress,
                      width: start.width + (end.width - start.width) * progress,
                      height: start.height + (end.height - start.height) * progress)
    }

    private static func subtract(_ occluder: CGRect, from frame: CGRect) -> [CGRect] {
        let intersection = frame.intersection(occluder)
        guard !intersection.isNull, !intersection.isEmpty else { return [frame] }
        return [
            CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: intersection.minY - frame.minY),
            CGRect(x: frame.minX, y: intersection.maxY, width: frame.width, height: frame.maxY - intersection.maxY),
            CGRect(x: frame.minX, y: intersection.minY, width: intersection.minX - frame.minX, height: intersection.height),
            CGRect(x: intersection.maxX, y: intersection.minY, width: frame.maxX - intersection.maxX, height: intersection.height)
        ].filter { !$0.isEmpty }
    }
}
