import AppKit
import Carbon
import Combine
import ScreenCaptureKit
import SwiftUI

@MainActor
final class SwitcherController: ObservableObject {
    @Published private(set) var windows: [WindowItem] = []
    @Published private(set) var selection = WindowSelection()
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    private(set) var isPresented = false
    private(set) var selectionWasMovedByMouse = false
    @Published private(set) var screenWidth: CGFloat = 1280

    let settings: AppSettings
    private let statistics: UsageStatisticsStore

    let catalog = WindowCatalog()
    private var panel: SwitcherPanel?
    private var sessionID = UUID()
    private var queuedSteps = 0
    private var selectionWasChanged = false
    private var commitRequested = false
    private var loadTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var startupScheduled = false
    private var capturePermissionGranted = false
    private var contentTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var previewID = UUID()
    private var previewWindows: [WindowItem] = []
    private var captureWindows: [CGWindowID: SCWindow] = [:]
    private var attemptedCaptures: Set<UUID> = []
    private var shortcutTimer: Timer?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var clickMonitor: Any?
    private var outsideClickMonitor: Any?
    private var previewMode = false
    private var shortcutRepeat = ShortcutRepeat()
    private var windowScroll = WindowScroll()

    init(settings: AppSettings? = nil, statistics: UsageStatisticsStore? = nil) {
        self.settings = settings ?? .shared
        self.statistics = statistics ?? .shared
    }

    func updateCapturePermission(_ granted: Bool) {
        capturePermissionGranted = granted
        guard !granted else { return }
        startupTask?.cancel()
        startupTask = nil
        startupScheduled = false
        clearPreviews()
    }

    func scheduleStartupPreviews() {
        let granted = CGPreflightScreenCaptureAccess()
        updateCapturePermission(granted)
        guard !startupScheduled, AXIsProcessTrusted(), granted else { return }
        startupScheduled = true
        startupTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            guard let self, !Task.isCancelled, capturePermissionGranted,
                  AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { return }
            let preview = previewID
            let entries = await catalog.load()
            guard !Task.isCancelled, previewID == preview else { return }
            refreshPreviews(for: entries)
        }
    }

    func press(_ direction: Int, captureEnabled: Bool) {
        // Drop cached images before presenting any windows after permission is revoked.
        updateCapturePermission(captureEnabled)
        guard shortcutRepeat.keyDown(at: ProcessInfo.processInfo.systemUptime) else { return }
        if !previewMode { DailyActivityReporter.shared.recordActivity() }
        if isPresented {
            if isLoading { queuedSteps += direction }
            else { move(direction) }
            return
        }
        sessionID = UUID()
        let session = sessionID
        loadTask?.cancel()
        startupTask?.cancel()
        startupTask = nil
        queuedSteps = 0
        commitRequested = false
        message = nil
        selectionWasMovedByMouse = false
        selectionWasChanged = false
        windows = catalog.currentWindows()
        selection.begin(count: windows.count, steps: 0)
        isLoading = windows.isEmpty
        presentPanel()
        startShortcutTimer()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let entries = await catalog.load()
            guard !Task.isCancelled else { return }
            // Keep preparing previews even if the user closes the panel quickly.
            if capturePermissionGranted { refreshPreviews(for: entries) }
            else { clearPreviews() }
            guard session == sessionID, isPresented else { return }
            if isLoading {
                windows = entries
                selection.begin(count: entries.count, steps: queuedSteps)
            } else {
                replaceWindowSnapshot(entries, preservingSelection: selectionWasChanged)
            }
            isLoading = false
            if entries.isEmpty {
                showMessage("没有可切换的窗口")
            } else if commitRequested {
                commit()
            }
        }
    }

    func releaseShortcutKey() { shortcutRepeat.keyUp() }

    func replaceWindowSnapshot(_ entries: [WindowItem], preservingSelection: Bool = true) {
        let selectedID = windows.indices.contains(selection.index) ? windows[selection.index].id : nil
        let index = preservingSelection
            ? entries.firstIndex { $0.id == selectedID } ?? min(selection.index, max(0, entries.count - 1))
            : 0
        windows = entries
        selection.begin(count: entries.count, steps: index)
    }

    func move(_ direction: Int) {
        guard !isLoading, !windows.isEmpty else { return }
        selectionWasChanged = true
        selectionWasMovedByMouse = false
        withAnimation(.easeInOut(duration: 0.2)) { selection.move(direction) }
        capturePreviews()
    }

    func hoverWindow(_ id: UUID) {
        guard isPresented, settings.displayMode == .tiled, !isLoading,
              let index = windows.firstIndex(where: { $0.id == id }) else { return }
        selectionWasChanged = true
        guard index != selection.index else { return }
        selectionWasMovedByMouse = true
        selection.select(index)
        capturePreviews()
    }

    func chooseWindow(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        choose(index)
    }

    func scroll(_ event: NSEvent) {
        guard settings.displayMode == .carousel, !isLoading, !windows.isEmpty else { return }
        let direction = windowScroll.direction(for: event)
        if direction != 0 { move(direction) }
    }

    func choose(_ index: Int) {
        guard !isLoading, windows.indices.contains(index) else { return }
        selection.select(index)
        commit()
    }

    func commit() {
        guard isPresented else { return }
        if isLoading { commitRequested = true; return }
        guard windows.indices.contains(selection.index) else { dismiss(); return }
        let target = windows[selection.index]
        dismiss()
        if !previewMode {
            if catalog.activate(target) { statistics.record() }
            else { showMessage("这个窗口暂时无法切换，请再试一次") }
        }
    }

    func dismiss() {
        sessionID = UUID()
        messageTask?.cancel()
        messageTask = nil
        shortcutTimer?.invalidate()
        shortcutTimer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        keyMonitor = nil
        scrollMonitor = nil
        clickMonitor = nil
        outsideClickMonitor = nil
        panel?.orderOut(nil)
        isPresented = false
        isLoading = false
        windows = []
        message = nil
        commitRequested = false
        selectionWasMovedByMouse = false
        shortcutRepeat.keyUp()
        windowScroll.reset()
    }

    func stop() {
        dismiss()
        loadTask?.cancel()
        loadTask = nil
        startupTask?.cancel()
        startupTask = nil
        startupScheduled = false
        clearPreviews()
    }

    private func presentPanel() {
        // Open on the display containing the pointer, including a second monitor.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        screenWidth = frame.width
        if panel == nil {
            let panel = SwitcherPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = settings.text("Tidest 窗口切换")
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .screenSaver
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            panel.contentView = NSHostingView(rootView: SwitcherView(model: self))
            self.panel = panel
        }
        panel?.title = settings.text("Tidest 窗口切换")
        panel?.setFrame(frame, display: true)
        isPresented = true
        panel?.makeKeyAndOrderFront(nil)
        installEventMonitors()
    }

    private func installEventMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return consumed ? nil : event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.isPresented, event.window === self.panel else { return false }
                // Tiled mode scrolls the list itself, including trackpad momentum.
                guard self.settings.displayMode == .carousel else { return false }
                self.scroll(event)
                return true
            }
            return consumed ? nil : event
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel { self.dismiss() }
            }
            return event
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard isPresented else { return false }
        if event.type == .keyUp {
            if event.keyCode == settings.shortcut.keyCode { releaseShortcutKey() }
            return true
        }
        if event.type == .flagsChanged {
            if !previewMode && !settings.shortcut.modifiersAreHeld(event.modifierFlags) { commit() }
            return false
        }
        if settings.shortcut.matches(event) {
            guard shortcutRepeat.keyDown(at: ProcessInfo.processInfo.systemUptime) else { return true }
            if isLoading { queuedSteps += 1 } else { move(1) }
            return true
        }
        switch Int(event.keyCode) {
        case kVK_Escape: dismiss()
        case kVK_LeftArrow: move(-1)
        case kVK_RightArrow: move(1)
        case kVK_Return, kVK_Space: commit()
        default: break
        }
        return true
    }

    private func startShortcutTimer() {
        // Inspect the configured keys only while the panel is open. The one-second
        // repeat cadence is independent of the system keyboard repeat settings.
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPresented else { return }
                let flags = NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue))
                let modifiersDown = self.settings.shortcut.modifiersAreHeld(flags)
                if !modifiersDown {
                    if self.previewMode { self.releaseShortcutKey() } else { self.commit() }
                    return
                }
                if self.shortcutRepeat.tick(at: ProcessInfo.processInfo.systemUptime, modifiersDown: modifiersDown, keyDown: CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(self.settings.shortcut.keyCode))) {
                    if self.isLoading { self.queuedSteps += 1 } else { self.move(1) }
                }
            }
        }
        shortcutTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func showMessage(_ text: String) {
        dismiss()
        message = text
        presentPanel()
        let session = sessionID
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled, let self, sessionID == session else { return }
            dismiss()
        }
    }

    func retainPreviews(for entries: [WindowItem]) {
        previewWindows = entries
        let ids = Set(entries.filter(\.allowsThumbnail).map(\.id))
        thumbnails = thumbnails.filter { ids.contains($0.key) }
    }

    func cacheThumbnail(_ image: NSImage, for id: UUID) {
        guard previewWindows.contains(where: { $0.id == id && $0.allowsThumbnail }) else { return }
        thumbnails[id] = image
    }

    private func clearPreviews() {
        previewID = UUID()
        contentTask?.cancel()
        captureTask?.cancel()
        contentTask = nil
        captureTask = nil
        previewWindows = []
        thumbnails = [:]
        captureWindows = [:]
        attemptedCaptures = []
    }

    private func refreshPreviews(for entries: [WindowItem]) {
        guard capturePermissionGranted, CGPreflightScreenCaptureAccess() else {
            clearPreviews()
            return
        }
        previewID = UUID()
        contentTask?.cancel()
        captureTask?.cancel()
        contentTask = nil
        captureTask = nil
        captureWindows = [:]
        attemptedCaptures = []
        retainPreviews(for: entries)
        guard entries.contains(where: { $0.allowsThumbnail && $0.captureID != nil }) else { return }
        let preview = previewID
        contentTask = Task { [weak self] in
            guard let self, capturePermissionGranted, CGPreflightScreenCaptureAccess() else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard !Task.isCancelled, previewID == preview, capturePermissionGranted,
                      CGPreflightScreenCaptureAccess() else { return }
                captureWindows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
                capturePreviews()
            } catch {
                // A missing preview never prevents selecting the AX window.
            }
        }
    }

    private func capturePreviews() {
        guard capturePermissionGranted, !captureWindows.isEmpty, !previewMode else { return }
        captureTask?.cancel()
        let preview = previewID
        let targets = isPresented && !isLoading && !windows.isEmpty
            ? windows.indices.sorted { abs(selection.distance(to: $0)) < abs(selection.distance(to: $1)) }.map { windows[$0] }
            : previewWindows
        captureTask = Task { [weak self] in
            guard let self else { return }
            for target in targets {
                guard !Task.isCancelled, previewID == preview, capturePermissionGranted,
                      CGPreflightScreenCaptureAccess() else { return }
                guard target.allowsThumbnail, !attemptedCaptures.contains(target.id),
                      let id = target.captureID, let window = captureWindows[id],
                      window.owningApplication?.processID == target.processID else { continue }
                let configuration = SCStreamConfiguration()
                let scale = min(1, 640 / max(1, window.frame.width, window.frame.height))
                configuration.width = max(1, Int(window.frame.width * scale))
                configuration.height = max(1, Int(window.frame.height * scale))
                configuration.scalesToFit = true
                configuration.preservesAspectRatio = true
                configuration.ignoreShadowsSingleWindow = true
                configuration.showsCursor = false
                configuration.capturesAudio = false
                do {
                    let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
                    guard !Task.isCancelled, previewID == preview, capturePermissionGranted,
                          CGPreflightScreenCaptureAccess() else { return }
                    cacheThumbnail(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)), for: target.id)
                    attemptedCaptures.insert(target.id)
                } catch {
                    guard !Task.isCancelled, previewID == preview else { return }
                    attemptedCaptures.insert(target.id)
                }
            }
        }
    }

    #if DEBUG
    func showPreview(count: Int = 5) {
        previewMode = true
        selectionWasMovedByMouse = false
        let pid = ProcessInfo.processInfo.processIdentifier
        let element = AXUIElementCreateApplication(pid)
        let titles = ["文稿", "下载", "项目资料", "图片", "归档"]
        let withThumbnails = ProcessInfo.processInfo.arguments.contains("--ui-preview-thumbnails")
        let sizes = [NSSize(width: 1000, height: 500), NSSize(width: 400, height: 700), NSSize(width: 800, height: 500), NSSize(width: 600, height: 600), NSSize(width: 1200, height: 450)]
        windows = (0..<max(1, min(150, count))).map { index in
            let title = titles[index % titles.count] + (index < titles.count ? "" : " \(index + 1)")
            let size = withThumbnails ? sizes[index % sizes.count] : NSSize(width: 800, height: 500)
            return WindowItem(element: element, processID: pid, applicationName: "Finder", icon: NSWorkspace.shared.icon(for: .folder), title: title, frame: CGRect(origin: .zero, size: size), minimized: false, captureID: nil, stackOrder: index)
        }
        if withThumbnails {
            // Generated pictures exercise image rendering without screen access.
            retainPreviews(for: windows)
            thumbnails = Dictionary(uniqueKeysWithValues: windows.enumerated().map { index, window in
                (window.id, Self.previewImage(window, index: index))
            })
            if ProcessInfo.processInfo.arguments.contains("--ui-preview-refresh") {
                let entries = windows
                captureTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) }
                    catch { return }
                    guard let self else { return }
                    for (index, window) in entries.enumerated() {
                        cacheThumbnail(Self.previewImage(window, index: index, updated: true), for: window.id)
                    }
                }
            }
        }
        selection.begin(count: windows.count, steps: 0)
        presentPanel()
        startShortcutTimer()
    }

    private static func previewImage(_ window: WindowItem, index: Int, updated: Bool = false) -> NSImage {
        let title = updated ? "已更新 · \(window.title)" : window.title
        let hue = CGFloat((index + (updated ? 2 : 0)) % 5) / 5
        let color = NSColor(calibratedHue: hue, saturation: 0.55, brightness: 0.8, alpha: 1)
        return NSImage(size: window.frame.size, flipped: true) { bounds in
            let radius = CGFloat(index % 3) * 16
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).addClip()
            NSColor.white.setFill()
            NSBezierPath(rect: bounds).fill()
            color.setFill()
            NSBezierPath(rect: CGRect(x: 0, y: 0, width: bounds.width * 0.2, height: bounds.height)).fill()
            (title as NSString).draw(at: CGPoint(x: bounds.width * 0.24, y: bounds.height * 0.05), withAttributes: [.font: NSFont.systemFont(ofSize: min(bounds.width, bounds.height) * 0.056, weight: .semibold), .foregroundColor: NSColor.black])
            color.withAlphaComponent(0.18).setFill()
            for row in 0..<5 {
                NSBezierPath(roundedRect: CGRect(x: bounds.width * 0.24, y: bounds.height * (0.18 + CGFloat(row) * 0.15), width: bounds.width * 0.72, height: bounds.height * 0.1), xRadius: 6, yRadius: 6).fill()
            }
            return true
        }
    }
    #endif
}

private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
