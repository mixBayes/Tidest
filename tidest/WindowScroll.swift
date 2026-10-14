import AppKit

nonisolated struct WindowScroll {
    static let swipeThreshold: CGFloat = 30
    private var horizontal: CGFloat = 0
    private var vertical: CGFloat = 0
    private var didMove = false

    mutating func reset() {
        horizontal = 0
        vertical = 0
        didMove = false
    }

    mutating func direction(for event: NSEvent) -> Int {
        guard event.momentumPhase.isEmpty else { return 0 }
        // Keep physical left/right and wheel up/down consistent with the hints,
        // whether or not the system's natural scrolling preference is enabled.
        let deviceSign: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        let x = event.scrollingDeltaX * deviceSign
        let y = event.scrollingDeltaY * deviceSign

        if !event.hasPreciseScrollingDeltas {
            reset()
            guard y != 0, abs(y) > abs(x) else { return 0 }
            return y < 0 ? 1 : -1
        }

        if event.phase.contains(.began) || event.phase.contains(.mayBegin) { reset() }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            reset()
            return 0
        }
        // Touch scrolling has a physical gesture phase. A phase-less event
        // alone cannot identify a new swipe, so it must not advance selection.
        guard !event.phase.isEmpty, !didMove else { return 0 }
        horizontal += x
        vertical += y
        guard abs(horizontal) >= Self.swipeThreshold, abs(horizontal) > abs(vertical) else { return 0 }
        didMove = true
        return horizontal > 0 ? 1 : -1
    }
}
