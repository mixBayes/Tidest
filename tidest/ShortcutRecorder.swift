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
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.target = button
        button.action = #selector(RecorderButton.toggleRecording)
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.title = isRecording ? settings.text("请按下快捷键…") : (shortcut?.symbolDisplayName ?? settings.text("未设置"))
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.setAccessibilityLabel(settings.text(labelKey) + ": " + (isRecording ? button.title : (shortcut?.displayName ?? settings.text("未设置"))))
        button.recording = isRecording
        button.onRecordingChange = { value in
            isRecording = value
            onRecordingChange(value)
        }
        button.onChange = onChange
        button.onInvalid = onInvalid
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
