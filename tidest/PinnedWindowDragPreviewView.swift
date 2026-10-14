import AppKit

/// The picture draws the exact rectangle supplied by the drag geometry, so
/// entering and leaving the shelf can continuously stretch the screenshot.
@MainActor
final class PinnedWindowDragPreviewView: NSView {
    static let inset: CGFloat = 12
    static let carriedPictureWidth: CGFloat = 230
    static let dockedPictureWidth: CGFloat = 170
    private let background: NSView
    private let content: NSView
    private let picture = NSImageView()
    private var imageSize = CGSize(width: 40, height: 40)
    private var pictureRect = CGRect.zero
    private var hasThumbnail = false

    var screenFrames: (glass: CGRect, picture: CGRect)? {
        guard let window else { return nil }
        return (window.convertToScreen(convert(bounds, to: nil)),
                window.convertToScreen(convert(pictureRect, to: nil)))
    }

    override init(frame frameRect: NSRect) {
        let content = NSView()
        self.content = content
        background = WindowBackground.make(contentView: content, cornerRadius: 18, clearGlass: true)
        super.init(frame: frameRect)
        background.frame = bounds
        background.autoresizingMask = [.width, .height]
        addSubview(background)
        picture.imageScaling = .scaleAxesIndependently
        picture.imageAlignment = .alignCenter
        picture.alphaValue = 0.9
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 8
        picture.layer?.masksToBounds = true
        picture.setAccessibilityElement(false)
        content.addSubview(picture)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(window: PinnedWindowEntry, thumbnail: NSImage?) {
        hasThumbnail = thumbnail != nil
        picture.image = thumbnail ?? window.icon
        let size = thumbnail?.size ?? CGSize(width: 40, height: 40)
        imageSize = size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
            ? size : CGSize(width: 16, height: 10)
        needsLayout = true
    }

    func preferredSize(pictureWidth: CGFloat, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        let side = hasThumbnail ? pictureWidth : 40
        let imageScale = side / max(imageSize.width, imageSize.height)
        let fittedSize = CGSize(width: imageSize.width * imageScale + Self.inset * 2,
                                height: imageSize.height * imageScale + Self.inset * 2)
        let scale = max(0, min(1, maxWidth / fittedSize.width, maxHeight / fittedSize.height))
        return CGSize(width: fittedSize.width * scale, height: fittedSize.height * scale)
    }

    func fittedPicture(in rect: CGRect) -> CGRect {
        let scale = max(0, min(rect.width / imageSize.width, rect.height / imageSize.height))
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    func setFrames(glass: CGRect, picture: CGRect) {
        let rect = picture.offsetBy(dx: -glass.minX, dy: -glass.minY)
        if frame != glass { frame = glass }
        if pictureRect != rect {
            pictureRect = rect
            needsLayout = true
        }
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        content.frame = bounds
        picture.frame = pictureRect
    }

    // In the shelf this is decoration; the controller owns the second click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
