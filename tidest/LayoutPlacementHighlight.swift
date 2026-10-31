import AppKit
import QuartzCore

/// A passive overlay expands a layout block without taking focus or handling input.
@MainActor
final class LayoutPlacementHighlight {
    private let panel: LayoutPlacementPanel
    private let region = CALayer()
    private let screenFrame: CGRect
    private let accent = NSColor.controlAccentColor

    init(source: CGRect, in screenFrame: CGRect, identifier: String) {
        self.screenFrame = screenFrame
        panel = LayoutPlacementPanel(contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.identifier = NSUserInterfaceItemIdentifier(identifier)
        panel.ignoresMouseEvents = true
        let content = NSView(frame: CGRect(origin: .zero, size: screenFrame.size))
        content.wantsLayer = true
        region.frame = source.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        region.cornerRadius = 3
        region.backgroundColor = accent.cgColor
        region.borderColor = accent.withAlphaComponent(0).cgColor
        content.layer?.addSublayer(region)
        panel.contentView = content
        panel.orderFrontRegardless()
    }

    func move(to frame: CGRect, duration: TimeInterval) async {
        let destination = frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        let fill = accent.withAlphaComponent(0.10).cgColor
        let border = accent.withAlphaComponent(0.88).cgColor
        let animations = [
            animation("position", from: region.position,
                      to: CGPoint(x: destination.midX, y: destination.midY)),
            animation("bounds", from: region.bounds, to: CGRect(origin: .zero, size: destination.size)),
            animation("cornerRadius", from: region.cornerRadius, to: CGFloat(8)),
            animation("backgroundColor", from: region.backgroundColor, to: fill),
            animation("borderColor", from: region.borderColor, to: border),
            animation("borderWidth", from: region.borderWidth, to: CGFloat(2))
        ]
        await withCheckedContinuation { continuation in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { continuation.resume() }
            region.frame = destination
            region.cornerRadius = 8
            region.backgroundColor = fill
            region.borderColor = border
            region.borderWidth = 2
            if duration > 0 {
                for animation in animations { animation.duration = duration }
                let group = CAAnimationGroup()
                group.animations = animations
                group.duration = duration
                group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                region.add(group, forKey: "placement")
            }
            CATransaction.commit()
        }
    }

    func fadeOut() async {
        await withCheckedContinuation { continuation in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                panel.animator().alphaValue = 0
            }, completionHandler: { continuation.resume() })
        }
    }

    func hide() { panel.orderOut(nil) }

    private func animation(_ key: String, from: Any?, to: Any) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = to
        return animation
    }
}

private final class LayoutPlacementPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
