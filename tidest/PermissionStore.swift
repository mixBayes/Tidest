import AppKit
import ApplicationServices
import Combine

enum PermissionGuide: Equatable {
    case accessibility
    case screenCapture
    case granted
}

@MainActor
final class PermissionStore: ObservableObject {
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var screenCaptureGranted = false
    @Published var screenCaptureReminderSuppressed = false {
        didSet {
            if !preview { defaults.set(screenCaptureReminderSuppressed, forKey: "screenCaptureReminderSuppressed") }
        }
    }
    @Published var requestedScreenCapture = false
    @Published var shortcutMessage: String?
    @Published var layoutShortcutMessage: String?
    @Published var pinShortcutMessage: String?
    private let preview: Bool
    private let defaults: UserDefaults

    // Preview values never read saved reminders or change system permissions or preferences.
    init(preview: Bool = false, accessibility: Bool = false, screenCapture: Bool = false,
         defaults: UserDefaults = .standard) {
        self.preview = preview
        self.defaults = defaults
        if preview {
            accessibilityGranted = accessibility
            screenCaptureGranted = screenCapture
        } else {
            screenCaptureReminderSuppressed = defaults.bool(forKey: "screenCaptureReminderSuppressed")
            refresh()
        }
    }

    var startupGuide: PermissionGuide? {
        if !accessibilityGranted { return .accessibility }
        if !screenCaptureGranted && !screenCaptureReminderSuppressed { return .screenCapture }
        return nil
    }

    var manualGuide: PermissionGuide {
        if !accessibilityGranted { return .accessibility }
        if !screenCaptureGranted { return .screenCapture }
        return .granted
    }

    func refresh() {
        guard !preview else { return }
        accessibilityGranted = AXIsProcessTrusted()
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
    }

    func requestAccessibility() {
        guard !preview else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings("Privacy_Accessibility")
        refresh()
    }

    func requestScreenCapture() {
        guard !preview else { return }
        requestedScreenCapture = true
        _ = CGRequestScreenCaptureAccess()
        refresh()
        if !screenCaptureGranted { openSettings("Privacy_ScreenCapture") }
    }

    // macOS owns permission changes. These actions keep the existing native
    // authorization request and route granted permissions to System Settings.
    func openAccessibilitySettings() {
        guard !preview else { return }
        refresh()
        if !accessibilityGranted { requestAccessibility() }
        else { openSettings("Privacy_Accessibility") }
    }

    func openScreenCaptureSettings() {
        guard !preview else { return }
        refresh()
        if !screenCaptureGranted { requestScreenCapture() }
        else { openSettings("Privacy_ScreenCapture") }
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}
