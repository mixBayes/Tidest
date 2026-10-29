import AppKit
import SwiftUI

/// A clickable reminder anchored to the menu-bar icon, without taking focus
/// from the user's current application. It is not a separate installed helper.
@MainActor
final class UpdateReminder {
    static let symbolName = "arrow.up.circle.fill"
    private var panel: NSPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    @discardableResult
    func show(relativeTo button: NSStatusBarButton, settings: AppSettings,
              onClick: @escaping () -> Void) -> Bool {
        guard let window = button.window, window.isVisible, let screen = window.screen else { return false }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard screen.frame.intersects(anchor) else { return false }
        hide()
        let content = NSHostingView(rootView: Button {
            self.hide()
            onClick()
        } label: {
            Label {
                Text(settings.text("Tidest 有新版本，点击查看"))
            } icon: {
                Image(systemName: Self.symbolName)
                    .foregroundStyle(Color("UpdateReminderIcon"))
            }
                .font(.system(size: 12))
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("openUpdateFromReminder")
        .fixedSize())
        let size = content.fittingSize
        let left = max(screen.visibleFrame.minX + 8,
                       min(anchor.midX - size.width / 2, screen.visibleFrame.maxX - size.width - 8))
        let frame = CGRect(x: left, y: anchor.minY - size.height - 6, width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.identifier = NSUserInterfaceItemIdentifier("updateReminder")
        panel.title = settings.text("Tidest 更新")
        panel.contentView = WindowBackground.make(contentView: content, frame: CGRect(origin: .zero, size: size),
                                                   cornerRadius: 10, material: .popover)
        self.panel = panel
        panel.orderFrontRegardless()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self, weak panel] event in
            MainActor.assumeIsolated {
                if event.type == .keyDown || event.window !== panel { self?.hide() }
            }
            return event
        }
        // The read-only mouse monitor needs no Accessibility permission.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        return panel.isVisible
    }

    func hide() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }

    static func statusImage(hasUpdate: Bool) -> NSImage? {
        guard let original = NSImage(named: "MenuBarIcon") else { return nil }
        guard hasUpdate else { return original }
        let image = NSImage(size: CGSize(width: 22, height: 20), flipped: false) { _ in
            original.draw(in: CGRect(x: 0, y: 2, width: 16, height: 16))
            let badge = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            // Clear a small separation so the arrow remains readable on either
            // a light or dark menu bar. The final image uses template rendering.
            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
            NSBezierPath(ovalIn: CGRect(x: 12, y: 0, width: 10, height: 10)).fill()
            NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
            badge?.draw(in: CGRect(x: 13, y: 1, width: 8, height: 8))
            return true
        }
        image.isTemplate = true
        return image
    }

    static func aboutTitle(_ title: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: title + "  ")
        let attachment = NSTextAttachment()
        attachment.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        attachment.bounds = CGRect(x: 0, y: -2, width: 13, height: 13)
        result.append(NSAttributedString(attachment: attachment))
        return result
    }
}
