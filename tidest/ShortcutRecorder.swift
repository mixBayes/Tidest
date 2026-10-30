import AppKit
import Carbon
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: WindowShortcut?
    let settings: AppSettings
    @Binding var isRecording: Bool
    let onChange: (WindowShortcut) -> Void
    let onInvalid: () -> Void
    let onRecordingChange: (Bool) -> Void
    let accessibilityIdentifier: String
    let labelKey: String

    init(shortcut: WindowShortcut?, settings: AppSettings, isRecording: Binding<Bool>,
         onChange: @escaping (WindowShortcut) -> Void,
         onInvalid: @escaping () -> Void,
         onRecordingChange: @escaping (Bool) -> Void,
         accessibilityIdentifier: String = "shortcutRecorder", labelKey: String = "快捷键") {
        self.shortcut = shortcut
        self.settings = settings
        _isRecording = isRecording
        self.onChange = onChange
        self.onInvalid = onInvalid
        self.onRecordingChange = onRecordingChange
        self.accessibilityIdentifier = accessibilityIdentifier
        self.labelKey = labelKey
    }

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.cell = RecorderButtonCell(textCell: "")
        button.bezelStyle = .rounded
        button.font = .monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.target = button
        button.action = #selector(RecorderButton.toggleRecording)
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.title = isRecording ? settings.text("请按下快捷键…") : (shortcut?.symbolDisplayName ?? settings.text("未设置"))
        button.font = (isRecording || shortcut == nil)
            ? .systemFont(ofSize: 12, weight: .medium)
            : .monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.setAccessibilityLabel(settings.text(labelKey) + ": " + (isRecording ? button.title : (shortcut?.displayName ?? settings.text("未设置"))))
        button.recording = isRecording
        button.needsDisplay = true
        button.onRecordingChange = { value in
            isRecording = value
            onRecordingChange(value)
        }
        button.onChange = onChange
        button.onInvalid = onInvalid
    }

    final class RecorderButtonCell: NSButtonCell {
        override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
            let button = controlView as? RecorderButton
            let recording = button?.recording == true
            let dark = controlView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let outer = frame.insetBy(dx: 1, dy: 2)
            guard outer.width > 4, outer.height > 4 else { return }

            let radius: CGFloat = 6
            let skirtColor: NSColor
            let topColor: NSColor
            let borderColor: NSColor

            if recording {
                skirtColor = dark
                    ? NSColor(srgbRed: 0.09, green: 0.38, blue: 0.24, alpha: 1)
                    : NSColor(srgbRed: 0.83, green: 0.60, blue: 0.10, alpha: 1)
                topColor = dark
                    ? NSColor(srgbRed: 0.11, green: 0.26, blue: 0.19, alpha: 1)
                    : NSColor(srgbRed: 1.0, green: 0.96, blue: 0.82, alpha: 1)
                borderColor = NSColor(named: "AccentColor") ?? .controlAccentColor
            } else {
                skirtColor = dark
                    ? NSColor(srgbRed: 0.08, green: 0.11, blue: 0.10, alpha: 0.95)
                    : NSColor(srgbRed: 0.81, green: 0.79, blue: 0.75, alpha: 1)
                topColor = dark
                    ? NSColor(srgbRed: 0.16, green: 0.20, blue: 0.18, alpha: 1)
                    : NSColor(srgbRed: 0.98, green: 0.97, blue: 0.94, alpha: 1)
                borderColor = dark
                    ? NSColor.white.withAlphaComponent(0.18)
                    : NSColor(srgbRed: 0.08, green: 0.15, blue: 0.12, alpha: 0.22)
            }

            let skirtPath = NSBezierPath(roundedRect: outer, xRadius: radius, yRadius: radius)
            skirtColor.setFill()
            skirtPath.fill()

            let pressOffset: CGFloat = isHighlighted ? 1.0 : 0.0
            let topRect = NSRect(x: outer.minX,
                                 y: outer.minY + pressOffset,
                                 width: outer.width,
                                 height: max(2, outer.height - 2.0 - pressOffset))
            let topPath = NSBezierPath(roundedRect: topRect, xRadius: radius, yRadius: radius)
            topColor.setFill()
            topPath.fill()

            borderColor.setStroke()
            topPath.lineWidth = recording ? 1.5 : 1.0
            topPath.stroke()
        }

        override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
            let button = controlView as? RecorderButton
            let recording = button?.recording == true
            let dark = controlView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let textColor: NSColor
            if !isEnabled {
                textColor = .disabledControlTextColor
            } else if recording {
                textColor = dark
                    ? NSColor(srgbRed: 0.25, green: 0.82, blue: 0.56, alpha: 1)
                    : (NSColor(named: "AccentColor") ?? .controlAccentColor)
            } else {
                textColor = dark
                    ? NSColor(srgbRed: 0.95, green: 0.97, blue: 0.96, alpha: 1)
                    : NSColor(srgbRed: 0.08, green: 0.15, blue: 0.12, alpha: 1)
            }
            let mutable = NSMutableAttributedString(attributedString: title)
            let range = NSRange(location: 0, length: mutable.length)
            mutable.addAttribute(.foregroundColor, value: textColor, range: range)
            if let font = button?.font {
                mutable.addAttribute(.font, value: font, range: range)
            }
            let size = mutable.size()
            let pressOffset: CGFloat = isHighlighted ? 1.0 : 0.0
            let rect = NSRect(x: controlView.bounds.midX - size.width / 2,
                              y: (controlView.bounds.height - 2.0 - size.height) / 2 + pressOffset,
                              width: size.width,
                              height: size.height)
            mutable.draw(in: rect)
            return rect
        }
    }

    final class RecorderButton: NSButton {
        var recording = false {
            didSet { if !recording { pendingShortcut = nil } }
        }
        private var pendingShortcut: WindowShortcut?
        var onRecordingChange: ((Bool) -> Void)?
        var onChange: ((WindowShortcut) -> Void)?
        var onInvalid: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }

        @objc func toggleRecording() {
            if recording { finishRecording() }
            else {
                window?.makeFirstResponder(self)
                recording = true
                onRecordingChange?(true)
            }
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            if event.keyCode == kVK_Escape { finishRecording(); return }
            guard pendingShortcut == nil else { return }
            guard let shortcut = WindowShortcut(event: event), shortcut.isValid else { onInvalid?(); return }
            // Register only after release so holding the recorded key cannot
            // immediately trigger the newly registered global shortcut.
            pendingShortcut = shortcut
        }

        override func keyUp(with event: NSEvent) {
            guard recording, let pendingShortcut, event.keyCode == pendingShortcut.keyCode else {
                super.keyUp(with: event)
                return
            }
            onChange?(pendingShortcut)
            finishRecording()
        }

        override func flagsChanged(with event: NSEvent) {
            // Command key equivalents may not deliver keyUp to the responder.
            // Releasing a required modifier also ends the held combination.
            if recording, let pendingShortcut, !pendingShortcut.modifiersAreHeld(event.modifierFlags) {
                onChange?(pendingShortcut)
                finishRecording()
            } else { super.flagsChanged(with: event) }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event)
            return true
        }

        override func resignFirstResponder() -> Bool {
            finishRecording()
            return super.resignFirstResponder()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { finishRecording() }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey(_:)),
                                                       name: NSWindow.didResignKeyNotification, object: window)
            }
        }

        @objc private func windowDidResignKey(_ notification: Notification) {
            finishRecording()
        }

        private func finishRecording() {
            guard recording else { return }
            recording = false
            pendingShortcut = nil
            onRecordingChange?(false)
        }
    }
}
