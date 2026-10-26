import AppKit
import CoreImage.CIFilterBuiltins
import QuartzCore

/// Keep AppKit's segment tracking, keyboard navigation and accessibility. Only
/// replace its drawing on systems that have the public Liquid Glass material.
@MainActor
final class PinnedDisplayModeControl: NSSegmentedControl {
    private var artwork: PinnedDisplayModeArtwork?
    private var animation: CADisplayLink?
    private var animationStart: CFTimeInterval = 0
    private var sourceCenter: CGFloat = 0
    private var sourceStretch: CGFloat = 0
    private var destinationCenter: CGFloat = 0
    private var displayedSelection = -1
    private var showsKeyboardFocus = false
    private static let duration: CFTimeInterval = 0.55

    override var acceptsFirstResponder: Bool { isEnabled }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        if #available(macOS 26.0, *) {
            cell = PinnedDisplayModeCell()
            let artwork = PinnedDisplayModeArtwork(frame: bounds)
            artwork.onFrame = { [weak self] link in self?.advanceAnimation(link) }
            self.artwork = artwork
            addSubview(artwork)
            focusRingType = .none
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { animation?.invalidate() }

    override var selectedSegment: Int {
        didSet { synchronizeSelection(animated: window?.isVisible == true) }
    }

    override var isEnabled: Bool {
        didSet {
            artwork?.alphaValue = isEnabled ? 1 : 0.4
            if !isEnabled { finishAnimation() }
        }
    }

    override func setImage(_ image: NSImage?, forSegment segment: Int) {
        super.setImage(image, forSegment: segment)
        artwork?.invalidateSymbols()
    }

    override func layout() {
        super.layout()
        guard let artwork else { return }
        let resized = artwork.frame.size != bounds.size
        artwork.frame = bounds
        artwork.images = (0..<segmentCount).map { image(forSegment: $0) }
        if resized {
            finishAnimation()
            artwork.invalidateSymbols()
        }
        if animation == nil { positionLens() }
    }

    // NSSegmentedCell changes its selection directly while tracking a mouse or
    // key. Observe that committed selection before forwarding the usual action.
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        synchronizeSelection(animated: window?.isVisible == true)
        return super.sendAction(action, to: target)
    }

    override func mouseDown(with event: NSEvent) {
        showsKeyboardFocus = false
        artwork?.showsFocus = false
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        showsKeyboardFocus = true
        artwork?.showsFocus = true
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        showsKeyboardFocus = result && NSApp.currentEvent?.type != .leftMouseDown
        artwork?.showsFocus = showsKeyboardFocus
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { artwork?.showsFocus = false }
        return result
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        finishAnimation()
        artwork?.invalidateSymbols()
    }

    override func viewDidHide() {
        super.viewDidHide()
        finishAnimation()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        artwork?.invalidateSymbols()
    }

    func updateAppearance() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            finishAnimation()
        }
        artwork?.invalidateSymbols()
    }

    private func synchronizeSelection(animated: Bool) {
        guard let artwork, selectedSegment >= 0, selectedSegment < segmentCount,
              displayedSelection != selectedSegment else { return }
        let hadSelection = displayedSelection >= 0
        displayedSelection = selectedSegment
        let destination = center(for: selectedSegment)
        guard animated, hadSelection, !artwork.lensFrame.isEmpty,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else {
            finishAnimation()
            return
        }
        // A reversal begins at the currently drawn position, including its
        // deformation, so fast clicks never jump back to an old endpoint.
        sourceCenter = artwork.lensFrame.midX
        sourceStretch = max(0, artwork.lensFrame.width - lensWidth)
        destinationCenter = destination
        animationStart = CACurrentMediaTime()
        if animation == nil {
            let link = displayLink(target: artwork, selector: #selector(PinnedDisplayModeArtwork.step(_:)))
            animation = link
            link.add(to: .main, forMode: .common)
        }
    }

    private var lensWidth: CGFloat { max(0, bounds.width / CGFloat(max(1, segmentCount)) - 4) }

    private func center(for segment: Int) -> CGFloat {
        bounds.minX + bounds.width * (CGFloat(segment) + 0.5) / CGFloat(max(1, segmentCount))
    }

    private func positionLens() {
        guard let artwork, selectedSegment >= 0 else { return }
        setLens(center: center(for: selectedSegment), stretch: 0, in: artwork)
    }

    private func setLens(center: CGFloat, stretch: CGFloat, in artwork: PinnedDisplayModeArtwork) {
        let height = max(0, bounds.height - 4 - stretch * 0.08)
        artwork.lensFrame = CGRect(x: center - (lensWidth + stretch) / 2,
            y: bounds.midY - height / 2, width: lensWidth + stretch, height: height)
    }

    private func advanceAnimation(_ link: CADisplayLink) {
        guard let artwork else { return }
        let progress = min(1, max(0, (link.targetTimestamp - animationStart) / Self.duration))
        if progress >= 1 {
            finishAnimation()
            return
        }
        // Smooth travel with one restrained stretch-and-settle cycle. Both the
        // native glass and the optical image consume this exact same rectangle.
        let t = CGFloat(progress)
        let travel = 1 - pow(1 - t, 3)
        let stretch = sourceStretch * pow(1 - t, 3)
            + abs(destinationCenter - sourceCenter) * 0.32 * pow(sin(.pi * t), 2)
        setLens(center: sourceCenter + (destinationCenter - sourceCenter) * travel,
                stretch: stretch, in: artwork)
    }

    private func finishAnimation() {
        animation?.invalidate()
        animation = nil
        positionLens()
    }
}

/// Suppress only the standard bezel and symbols; the cell still owns AppKit's
/// native hit testing, selected values, key handling and accessible segments.
private final class PinnedDisplayModeCell: NSSegmentedCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {}
}

@MainActor
private final class PinnedDisplayModeArtwork: NSView {
    var images: [NSImage?] = []
    var onFrame: ((CADisplayLink) -> Void)?
    var showsFocus = false { didSet { needsDisplay = true } }
    private let glass: NSView
    private let lensSymbols = PinnedDisplayModeLensSymbols()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let distortion = CIFilter.bumpDistortion()
    private var symbols: CGImage?
    private var symbolsAreDirty = true

    var lensFrame = CGRect.zero {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glass.frame = lensFrame
            if #available(macOS 26.0, *), let glass = glass as? NSGlassEffectView {
                glass.cornerRadius = lensFrame.height / 2
            }
            lensSymbols.needsDisplay = true
            needsDisplay = true
            CATransaction.commit()
        }
    }

    override init(frame frameRect: NSRect) {
        if #available(macOS 26.0, *) {
            let effect = NSGlassEffectView()
            effect.style = .regular
            effect.contentView = lensSymbols
            glass = effect
        } else {
            glass = NSView()
        }
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        lensSymbols.setAccessibilityElement(false)
        lensSymbols.artwork = self
        addSubview(glass)
        invalidateSymbols()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Decorative glass must never intercept the native control's clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @objc func step(_ link: CADisplayLink) { onFrame?(link) }

    func invalidateSymbols() {
        symbolsAreDirty = true
        needsDisplay = true
        lensSymbols.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let reducedTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let track = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (reducedTransparency ? NSColor.controlBackgroundColor : NSColor.labelColor.withAlphaComponent(0.055)).setFill()
        track.fill()
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            NSColor.labelColor.withAlphaComponent(0.5).setStroke()
            track.lineWidth = 1
            track.stroke()
        }
        NSGraphicsContext.saveGraphicsState()
        // Draw the original symbols only outside the moving lens. Drawing a
        // magnified copy over the original would create ghosted double icons.
        let outsideLens = NSBezierPath(rect: bounds)
        outsideLens.append(NSBezierPath(roundedRect: lensFrame,
            xRadius: lensFrame.height / 2, yRadius: lensFrame.height / 2))
        outsideLens.windingRule = .evenOdd
        outsideLens.addClip()
        if let symbols = symbolImage() {
            NSImage(cgImage: symbols, size: bounds.size).draw(in: bounds)
        }
        NSGraphicsContext.restoreGraphicsState()
        if showsFocus {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            track.lineWidth = 2
            track.stroke()
        }
    }

    private func symbolImage() -> CGImage? {
        guard symbolsAreDirty else { return symbols }
        symbolsAreDirty = false
        symbols = nil
        guard bounds.width > 0, bounds.height > 0, !images.isEmpty else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        guard let context = CGContext(data: nil, width: Int(ceil(bounds.width * scale)),
            height: Int(ceil(bounds.height * scale)), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (index, image) in images.enumerated() {
                guard let image, image.size.width > 0, image.size.height > 0 else { continue }
                let fit = min(1, 18 / max(image.size.width, image.size.height))
                let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
                let center = bounds.width * (CGFloat(index) + 0.5) / CGFloat(images.count)
                var rect = CGRect(x: center - size.width / 2, y: bounds.midY - size.height / 2,
                                  width: size.width, height: size.height)
                guard let mask = image.cgImage(forProposedRect: &rect, context: .current, hints: nil) else { continue }
                context.saveGState()
                context.clip(to: rect, mask: mask)
                context.setFillColor(NSColor.labelColor.cgColor)
                context.fill(rect)
                context.restoreGState()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        symbols = context.makeImage()
        return symbols
    }

    func drawLensSymbols(in view: NSView) {
        guard let symbols = symbolImage() else { return }
        var image = symbols
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if !reduced {
            let scale = CGFloat(symbols.width) / bounds.width
            distortion.inputImage = CIImage(cgImage: symbols)
            distortion.center = CGPoint(x: lensFrame.midX * scale, y: lensFrame.midY * scale)
            distortion.radius = Float(max(lensFrame.width, lensFrame.height) * 0.8 * scale)
            distortion.scale = 0.18
            if let output = distortion.outputImage,
               let refracted = imageContext.createCGImage(output, from: CGRect(x: 0, y: 0,
                    width: symbols.width, height: symbols.height)) {
                image = refracted
            }
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: view.bounds, xRadius: view.bounds.height / 2,
                     yRadius: view.bounds.height / 2).addClip()
        // A nonactivating shelf can render native glass tint as neutral gray.
        // Keep selection color in its content so it remains visible even when
        // another app owns keyboard focus; the native material supplies the rim.
        let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSColor.systemIndigo.withAlphaComponent(dark ? 0.30 : 0.22).setFill()
        view.bounds.fill()
        NSImage(cgImage: image, size: bounds.size).draw(in:
            bounds.offsetBy(dx: -lensFrame.minX, dy: -lensFrame.minY))
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor
private final class PinnedDisplayModeLensSymbols: NSView {
    weak var artwork: PinnedDisplayModeArtwork?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        artwork?.drawLensSymbols(in: self)
    }
}
