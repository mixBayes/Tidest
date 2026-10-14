import AppKit
import Combine
import QuartzCore

/// A quiet, click-through reminder while the user is picking a window.
@MainActor
final class PinnedCaptureTip {
    private var panel: PinnedCaptureTipPanel?

    func show(on screen: NSScreen, settings: AppSettings, carryingWindow: Bool = false) {
        let wasVisible = panel?.isVisible == true
        let area = screen.visibleFrame
        let size = CGSize(width: min(300, area.width), height: min(60, area.height))
        let frame = CGRect(x: area.midX - size.width / 2,
                           y: max(area.minY, area.maxY - size.height - 12),
                           width: size.width, height: size.height)
        if panel == nil {
            let panel = PinnedCaptureTipPanel(
                contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            let view = PinnedCaptureTipView(frame: CGRect(origin: .zero, size: size))
            view.autoresizingMask = [.width, .height]
            panel.contentView = view
            self.panel = panel
        }
        let view = panel?.contentView as? PinnedCaptureTipView
        view?.endAttention()
        panel?.setFrame(frame, display: true)
        view?.update(settings: settings, carryingWindow: carryingWindow)
        panel?.title = settings.text("Tidest 拾取窗口")
        // A key panel lets the capture mode own the native cursor and Escape
        // while leaving mouse clicks to the highlighted window and shelf.
        panel?.makeKeyAndOrderFront(nil)
        if !wasVisible { view?.beginAttention() }
    }

    func hide() {
        (panel?.contentView as? PinnedCaptureTipView)?.endAttention()
        panel?.orderOut(nil)
    }
}

private final class PinnedCaptureTipPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class PinnedCaptureTipView: NSVisualEffectView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let instructionLabel = NSTextField(labelWithString: "")
    private var attentionTask: Task<Void, Never>?
    private var systemColorObserver: AnyCancellable?
    private var attentionID = UUID()
    private let attentionAnimationKey = "captureTipBorderAttention"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 0.5
        layer?.masksToBounds = true
        // Native behind-window material uses this alpha mask, rather than
        // relying on CALayer clipping alone. A one-point centre stretches
        // while the fourteen-point rounded corners retain their shape.
        let mask = NSImage(size: CGSize(width: 29, height: 29), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.clear(rect)
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil))
            context.fillPath()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        mask.resizingMode = .stretch
        maskImage = mask
        icon.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor
        icon.setAccessibilityElement(false)
        let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.font = titleFont.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: 12) } ?? titleFont
        titleLabel.textColor = .labelColor
        instructionLabel.font = .systemFont(ofSize: 11)
        instructionLabel.textColor = .secondaryLabelColor
        for label in [titleLabel, instructionLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        addSubview(icon)
        updateBorderColor()
        systemColorObserver = NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.icon.contentTintColor = .controlAccentColor
                    self?.endAttention()
                }
            }
        setAccessibilityIdentifier("pinnedCaptureModeTip")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(settings: AppSettings, carryingWindow: Bool) {
        titleLabel.stringValue = settings.text(carryingWindow ? "点击停靠栏放下" : "点击要添加的窗口")
        instructionLabel.stringValue = settings.text("按 Esc 取消")
        setAccessibilityLabel("\(titleLabel.stringValue), \(instructionLabel.stringValue)")
        needsLayout = true
    }

    func beginAttention() {
        endAttention()
        guard window?.isVisible == true, let borderLayer = layer,
              let normalColor = borderLayer.borderColor else { return }
        let token = UUID()
        attentionID = token
        var blue = NSColor.controlAccentColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            blue = NSColor.controlAccentColor.cgColor
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            borderLayer.borderColor = blue
            borderLayer.borderWidth = 1.5
            CATransaction.commit()
        } else {
            // Two blue peaks over two seconds, then the semantic model color
            // remains. Animate only our border, leaving native material layers.
            let color = CAKeyframeAnimation(keyPath: "borderColor")
            color.values = [normalColor, blue, normalColor, blue, normalColor]
            let width = CAKeyframeAnimation(keyPath: "borderWidth")
            width.values = [0.5, 1.5, 0.5, 1.5, 0.5]
            for animation in [color, width] {
                animation.keyTimes = [0, 0.25, 0.5, 0.75, 1]
                animation.timingFunctions = (0..<4).map { _ in CAMediaTimingFunction(name: .easeInEaseOut) }
                animation.duration = 2
            }
            let pulse = CAAnimationGroup()
            pulse.animations = [color, width]
            pulse.duration = 2
            borderLayer.add(pulse, forKey: attentionAnimationKey)
        }
        attentionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, !Task.isCancelled, attentionID == token, window?.isVisible == true else { return }
            endAttention()
        }
    }

    func endAttention() {
        attentionID = UUID()
        attentionTask?.cancel()
        attentionTask = nil
        layer?.removeAnimation(forKey: attentionAnimationKey)
        updateBorderColor()
    }

    override func layout() {
        super.layout()
        icon.frame = CGRect(x: 15, y: bounds.midY - 11, width: 22, height: 22)
        titleLabel.frame = CGRect(x: 49, y: bounds.midY + 1, width: max(0, bounds.width - 63), height: 17)
        instructionLabel.frame = CGRect(x: 49, y: bounds.midY - 18,
                                        width: max(0, bounds.width - 63), height: 16)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        icon.contentTintColor = .controlAccentColor
        endAttention()
    }

    private func updateBorderColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        }
        layer?.borderWidth = 0.5
        CATransaction.commit()
    }
}
