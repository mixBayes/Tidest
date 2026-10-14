import AppKit

@MainActor
enum WindowBackground {
    static func make(contentView: NSView, frame: NSRect = .zero, cornerRadius: CGFloat,
                     clearGlass: Bool = false, material: NSVisualEffectView.Material = .hudWindow) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.style = clearGlass ? .clear : .regular
            glass.cornerRadius = cornerRadius
            glass.contentView = contentView
            return glass
        }
        return makeFrosted(contentView: contentView, frame: frame, cornerRadius: cornerRadius, material: material)
    }

    // Keep the content and its coordinates the same on systems without glass.
    static func makeFrosted(contentView: NSView, frame: NSRect, cornerRadius: CGFloat,
                           material: NSVisualEffectView.Material = .hudWindow) -> NSVisualEffectView {
        let effect = NSVisualEffectView(frame: frame)
        effect.material = material
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        contentView.frame = effect.bounds
        contentView.autoresizingMask = [.width, .height]
        effect.addSubview(contentView)
        return effect
    }
}
