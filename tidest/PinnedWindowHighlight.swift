import AppKit

/// The selectable parts of one external window. These small panels own the
/// mouse-down instead of intercepting another application's mouse events.
@MainActor
final class PinnedWindowHighlight {
    var onMouseDown: ((CGPoint) -> Bool)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?
    private(set) var isTracking = false

    private var panels: [PinnedWindowHighlightPanel] = []
    private var sourcePanel: PinnedWindowHighlightPanel?
    private var trackingAccepted = false

    func show(target: LayoutTarget, primaryScreenTop: CGFloat) {
        // AppKit keeps delivering the drag to the view that received down.
        // Replacing that view while its mouse is held would break the sequence.
        guard !isTracking else { return }
        clear()

        let windowFrame = QuickLayoutGeometry.appKitRect(
            from: target.window.frame, primaryScreenTop: primaryScreenTop)
        for region in target.visibleRegions {
            guard !region.isNull, !region.isEmpty,
                  region.minX.isFinite, region.minY.isFinite,
                  region.width.isFinite, region.height.isFinite else { continue }
            let frame = QuickLayoutGeometry.appKitRect(from: region, primaryScreenTop: primaryScreenTop)
            let panel = PinnedWindowHighlightPanel(
                contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .screenSaver
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isMovable = false
            panel.ignoresMouseEvents = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            panel.setAccessibilityElement(false)

            let view = PinnedWindowHighlightView(regionFrame: frame, windowFrame: windowFrame)
            view.onMouseDown = { [weak self, weak panel] point in
                guard let self, let panel else { return }
                beginMouseSequence(from: panel, at: point)
            }
            view.onMouseDragged = { [weak self, weak panel] point in
                guard let self, let panel, isTracking, sourcePanel === panel, trackingAccepted else { return }
                onMouseDragged?(point)
            }
            view.onMouseUp = { [weak self, weak panel] point in
                guard let self, let panel else { return }
                endMouseSequence(from: panel, at: point)
            }
            panel.contentView = view
            panels.append(panel)
            panel.orderFrontRegardless()
        }
    }

    func clear() {
        for panel in panels {
            if isTracking, panel === sourcePanel {
                // Keep the exact source window, view and geometry until up.
                // Only its drawing disappears; it remains a mouse receiver.
                (panel.contentView as? PinnedWindowHighlightView)?.setHighlighted(false)
            } else {
                panel.orderOut(nil)
            }
        }
        panels = isTracking ? sourcePanel.map { [$0] } ?? [] : []
    }

    private func beginMouseSequence(from panel: PinnedWindowHighlightPanel, at point: CGPoint) {
        guard !isTracking, panels.contains(where: { $0 === panel }) else { return }
        isTracking = true
        sourcePanel = panel
        trackingAccepted = false
        let accepted = onMouseDown?(point) ?? false
        trackingAccepted = accepted
        if !accepted {
            // This down already belongs to our panel. Consume its remaining
            // sequence without forwarding anything to the original window.
            clear()
        }
    }

    private func endMouseSequence(from panel: PinnedWindowHighlightPanel, at point: CGPoint) {
        guard isTracking, sourcePanel === panel else { return }
        let accepted = trackingAccepted
        isTracking = false
        trackingAccepted = false
        sourcePanel = nil
        // Finish the old overlay before notifying the controller. Its up
        // callback may show a new target that must survive this old sequence.
        let oldPanels = panels
        panels.removeAll()
        for oldPanel in oldPanels { oldPanel.orderOut(nil) }
        if accepted { onMouseUp?(point) }
    }
}

private final class PinnedWindowHighlightPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PinnedWindowHighlightView: NSView {
    var onMouseDown: ((CGPoint) -> Void)?
    var onMouseDragged: ((CGPoint) -> Void)?
    var onMouseUp: ((CGPoint) -> Void)?

    private let windowFrame: CGRect
    private var isHighlighted = true

    init(regionFrame: CGRect, windowFrame: CGRect) {
        self.windowFrame = windowFrame.offsetBy(dx: -regionFrame.minX, dy: -regionFrame.minY)
        super.init(frame: CGRect(origin: .zero, size: regionFrame.size))
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { return nil }

    func setHighlighted(_ highlighted: Bool) {
        isHighlighted = highlighted
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        guard isHighlighted else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)
        let accent = NSColor(srgbRed: 70.0 / 255.0, green: 123.0 / 255.0, blue: 227.0 / 255.0, alpha: 1)
        context.setFillColor(accent.withAlphaComponent(0.10).cgColor)
        context.fill(windowFrame)
        context.setStrokeColor(accent.withAlphaComponent(0.88).cgColor)
        context.setLineWidth(2)
        // Draw the original window outline, clipped to this visible region.
        // Occlusion cuts never acquire their own interior border lines.
        let outline = CGPath(roundedRect: windowFrame.insetBy(dx: 1, dy: 1),
                             cornerWidth: 8, cornerHeight: 8, transform: nil)
        context.addPath(outline)
        context.strokePath()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        onMouseDown?(window.convertPoint(toScreen: event.locationInWindow))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        onMouseDragged?(window.convertPoint(toScreen: event.locationInWindow))
    }

    override func mouseUp(with event: NSEvent) {
        guard let window else { return }
        onMouseUp?(window.convertPoint(toScreen: event.locationInWindow))
    }
}
