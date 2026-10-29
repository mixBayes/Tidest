import AppKit
import ApplicationServices
import Carbon
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class QuickLayoutController {
    private(set) var isPresented = false

    private let settings: AppSettings
    private let service = WindowLayoutService()
    private let catalog = WindowCatalog()
    private var panel: QuickLayoutPanel?
    private var highlights: [QuickLayoutPassivePanel] = []
    private var target: LayoutTarget?
    private var layoutArea = CGRect.zero
    private var visibleScreenFrame = CGRect.zero
    private var sessionID = UUID()
    private var targetTask: Task<Void, Never>?
    private var layoutTasks: [UUID: (window: WindowItem, task: Task<Void, Never>)] = [:]
    private var keyMonitor: Any?
    private var pendingKeyMonitor: Any?
    private var clickMonitor: Any?
    private var outsideClickMonitor: Any?
    private var tipPanel: QuickLayoutPassivePanel?
    private var tipTask: Task<Void, Never>?
    private var feedbackID = UUID()
    private var previewMode = false
    private var previewConstrained = false
    private var shortcutHeld = false

    private let statistics: UsageStatisticsStore

    init(settings: AppSettings? = nil, statistics: UsageStatisticsStore? = nil) {
        self.settings = settings ?? .shared
        self.statistics = statistics ?? .shared
    }

    func present() {
        // Keeping one session also prevents a held shortcut from retargeting
        // to the panel or to a different window as the pointer moves.
        guard !shortcutHeld else { return }
        shortcutHeld = true
        guard !isPresented else { return }
        let pointer = NSEvent.mouseLocation
        let screens = NSScreen.screens
        guard let primary = screens.first,
              let screen = screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return }
        let primaryScreenTop = primary.frame.maxY
        let screenFrames = screens.map(\.frame)
        let screenBounds = screenFrames.map { Self.axRect($0, primaryScreenTop: primaryScreenTop) }
        let point = QuickLayoutGeometry.axPoint(from: pointer, primaryScreenTop: primaryScreenTop)
        layoutArea = Self.axRect(screen.visibleFrame, primaryScreenTop: primaryScreenTop)
        visibleScreenFrame = screen.visibleFrame
        previewMode = false
        feedbackID = UUID()
        clearTip()
        sessionID = UUID()
        let session = sessionID
        isPresented = true
        installEventMonitors()
        // Nothing is ordered on screen or takes keyboard focus until AX has
        // identified the window under the original shortcut position.
        targetTask = Task { [weak self] in
            guard let self else { return }
            let found = await service.target(at: point, screens: screenBounds)
            guard !Task.isCancelled, isPresented, sessionID == session else { return }
            targetTask = nil
            guard let found else { dismiss(); return }
            if let pendingKeyMonitor { NSEvent.removeMonitor(pendingKeyMonitor) }
            pendingKeyMonitor = nil
            target = found
            showHighlights(for: found, primaryScreenTop: primaryScreenTop, screenFrames: screenFrames)
            presentPanel(near: pointer)
            DailyActivityReporter.shared.recordActivity()
        }
    }

    func releaseShortcutKey() { shortcutHeld = false }

    func dismiss() {
        sessionID = UUID()
        feedbackID = UUID()
        targetTask?.cancel()
        targetTask = nil
        isPresented = false
        target = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let pendingKeyMonitor { NSEvent.removeMonitor(pendingKeyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        keyMonitor = nil
        pendingKeyMonitor = nil
        clickMonitor = nil
        outsideClickMonitor = nil
        panel?.orderOut(nil)
        for highlight in highlights { highlight.orderOut(nil) }
        highlights = []
        clearTip()
    }

    func stop() {
        dismiss()
        shortcutHeld = false
        for operation in layoutTasks.values { operation.task.cancel() }
        layoutTasks = [:]
        catalog.stop()
    }

    private func choose(_ layout: QuickLayout) {
        guard isPresented, let target else { return }
        let area = layoutArea
        let screenFrame = visibleScreenFrame
        let preview = previewMode
        let constrained = previewConstrained
        dismiss()
        let feedback = UUID()
        feedbackID = feedback
        if preview {
            if constrained {
                showTip("受窗口大小限制，已尽量按所选位置排列。", in: screenFrame, feedback: feedback)
            }
            return
        }
        let operation = UUID()
        let previousTasks = layoutTasks.values.filter {
            $0.window.processID == target.window.processID && CFEqual($0.window.element, target.window.element)
        }.map { $0.task }
        for task in previousTasks { task.cancel() }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            // A canceled AX request may still be finishing its last message.
            // Wait for it before sending a newer layout to the same window.
            for previous in previousTasks { await previous.value }
            guard !Task.isCancelled else { layoutTasks[operation] = nil; return }
            let result = await service.apply(layout, to: target, in: area)
            layoutTasks[operation] = nil
            // Count completed placement even if a newer panel now owns feedback.
            // Raising the arranged window below is part of this same use.
            if result != .unavailable { statistics.record() }
            // A later shortcut or selection owns feedback and keyboard focus.
            // The requested layout still completes, without interrupting it.
            guard !Task.isCancelled, feedbackID == feedback, !isPresented else { return }
            if result != .unavailable {
                // Raising a window is helpful after arranging a covered window;
                // a failed raise does not undo an otherwise successful layout.
                _ = catalog.activate(target.window)
            }
            switch result {
            case .exact: break
            case .constrained:
                showTip("受窗口大小限制，已尽量按所选位置排列。", in: screenFrame, feedback: feedback)
            case .unavailable:
                showTip("这个窗口暂时无法调整，请再试一次。", in: screenFrame, feedback: feedback)
            }
        }
        layoutTasks[operation] = (window: target.window, task: task)
    }

    private func presentPanel(near pointer: CGPoint) {
        guard let target else { return }
        let frame = QuickLayoutGeometry.panelFrame(near: pointer, size: QuickLayoutView.panelSize,
                                                   in: visibleScreenFrame)
        if panel == nil {
            let panel = QuickLayoutPanel(contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            Self.configure(panel)
            panel.acceptsMouseMovedEvents = true
            panel.onResignKey = { [weak self] in
                guard let self, self.isPresented, self.panel?.isVisible == true else { return }
                self.dismiss()
            }
            self.panel = panel
        }
        panel?.title = settings.text("快速布局")
        panel?.contentView = Self.glassContentView(for: QuickLayoutView(settings: settings,
            title: target.window.title, applicationName: target.window.applicationName,
            icon: target.window.icon, onChoose: { [weak self] in self?.choose($0) }),
            size: QuickLayoutView.panelSize, cornerRadius: 22)
        panel?.setFrame(frame, display: true)
        panel?.makeKeyAndOrderFront(nil)
    }

    private func showHighlights(for target: LayoutTarget, primaryScreenTop: CGFloat, screenFrames: [CGRect]) {
        let windowFrame = QuickLayoutGeometry.appKitRect(from: target.window.frame, primaryScreenTop: primaryScreenTop)
        let visible = target.visibleRegions.map {
            QuickLayoutGeometry.appKitRect(from: $0, primaryScreenTop: primaryScreenTop)
        }
        for screenFrame in screenFrames {
            let regions = visible.map { $0.intersection(screenFrame) }.filter { !$0.isNull && !$0.isEmpty }
            guard !regions.isEmpty else { continue }
            let highlight = QuickLayoutPassivePanel(contentRect: screenFrame,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            Self.configure(highlight)
            highlight.ignoresMouseEvents = true
            highlight.contentView = QuickLayoutHighlightView(screenFrame: screenFrame,
                windowFrame: windowFrame, visibleRegions: regions)
            highlights.append(highlight)
            highlight.orderFrontRegardless()
        }
    }

    private func installEventMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return consumed ? nil : event
        }
        if target == nil {
            pendingKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, self.isPresented, self.target == nil,
                          event.modifierFlags.intersection([.command, .option]).isEmpty,
                          Int(event.keyCode) == kVK_Escape else { return }
                    self.dismiss()
                }
            }
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isPresented else { return }
                if event.window !== self.panel { self.dismiss() }
            }
            return event
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard isPresented, event.modifierFlags.intersection([.command, .option]).isEmpty else { return false }
        if Int(event.keyCode) == kVK_Escape {
            guard target == nil || (panel?.isKeyWindow == true && event.window === panel) else { return false }
            dismiss()
            return true
        }
        guard panel?.isKeyWindow == true, event.window === panel else { return false }
        let number: Int
        switch Int(event.keyCode) {
        case kVK_ANSI_1, kVK_ANSI_Keypad1: number = 1
        case kVK_ANSI_2, kVK_ANSI_Keypad2: number = 2
        case kVK_ANSI_3, kVK_ANSI_Keypad3: number = 3
        case kVK_ANSI_4, kVK_ANSI_Keypad4: number = 4
        case kVK_ANSI_5, kVK_ANSI_Keypad5, kVK_Space: number = 5
        case kVK_ANSI_6, kVK_ANSI_Keypad6: number = 6
        case kVK_ANSI_7, kVK_ANSI_Keypad7: number = 7
        case kVK_ANSI_8, kVK_ANSI_Keypad8: number = 8
        case kVK_ANSI_9, kVK_ANSI_Keypad9: number = 9
        default: return false
        }
        guard let layout = QuickLayout(rawValue: number) else { return false }
        choose(layout)
        return true
    }

    private func showTip(_ messageKey: String, in screenFrame: CGRect, feedback: UUID) {
        guard feedbackID == feedback else { return }
        clearTip()
        let size = QuickLayoutTipView.panelSize
        let x = max(screenFrame.minX, min(screenFrame.midX - size.width / 2, screenFrame.maxX - size.width))
        let y = max(screenFrame.minY, min(screenFrame.minY + 40, screenFrame.maxY - size.height))
        let panel = QuickLayoutPassivePanel(contentRect: CGRect(origin: CGPoint(x: x, y: y), size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        Self.configure(panel)
        panel.ignoresMouseEvents = true
        panel.contentView = Self.glassContentView(for: QuickLayoutTipView(settings: settings, messageKey: messageKey),
            size: size, cornerRadius: 18)
        tipPanel = panel
        panel.orderFrontRegardless()
        tipTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(2350)) }
            catch { return }
            guard let self, !Task.isCancelled, feedbackID == feedback, tipPanel === panel else { return }
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.65
                    panel.animator().alphaValue = 0
                }, completionHandler: nil)
            }
            do { try await Task.sleep(for: .milliseconds(650)) }
            catch { return }
            guard !Task.isCancelled, feedbackID == feedback, tipPanel === panel else { return }
            clearTip()
        }
    }

    private func clearTip() {
        tipTask?.cancel()
        tipTask = nil
        tipPanel?.orderOut(nil)
        tipPanel = nil
    }

    private static func glassContentView<Content: View>(for content: Content, size: CGSize,
                                                       cornerRadius: CGFloat) -> NSView {
        let frame = CGRect(origin: .zero, size: size)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = frame
        hosting.autoresizingMask = [.width, .height]
        let glass = WindowBackground.make(contentView: hosting, frame: frame, cornerRadius: cornerRadius)
        // Clip the glass, its effects, and hosted content to the same rounded boundary.
        glass.wantsLayer = true
        glass.layer?.cornerRadius = cornerRadius
        glass.layer?.masksToBounds = true
        return glass
    }

    private static func configure(_ panel: NSPanel) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The glass supplies its rounded edge; a window shadow adds a rectangular outline.
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    private static func axRect(_ frame: CGRect, primaryScreenTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryScreenTop - frame.maxY, width: frame.width, height: frame.height)
    }

    #if DEBUG
    func showPreview(constrained: Bool = false) {
        dismiss()
        let screens = NSScreen.screens
        guard let primary = screens.first, let screen = NSScreen.main ?? screens.first else { return }
        previewMode = true
        previewConstrained = constrained
        visibleScreenFrame = screen.visibleFrame
        let top = primary.frame.maxY
        layoutArea = Self.axRect(screen.visibleFrame, primaryScreenTop: top)
        let size = CGSize(width: min(900, screen.visibleFrame.width * 0.72),
                          height: min(560, screen.visibleFrame.height * 0.68))
        let frame = CGRect(x: screen.visibleFrame.midX - size.width / 2,
                           y: screen.visibleFrame.midY - size.height / 2,
                           width: size.width, height: size.height)
        let pid = ProcessInfo.processInfo.processIdentifier
        let window = WindowItem(element: AXUIElementCreateApplication(pid), processID: pid,
            applicationName: "Finder", icon: NSWorkspace.shared.icon(for: .folder), title: settings.text("文稿"),
            frame: Self.axRect(frame, primaryScreenTop: top), minimized: false, captureID: nil, stackOrder: 0)
        let target = LayoutTarget(window: window, visibleRegions: [window.frame])
        self.target = target
        isPresented = true
        installEventMonitors()
        showHighlights(for: target, primaryScreenTop: top, screenFrames: screens.map(\.frame))
        presentPanel(near: CGPoint(x: frame.midX, y: frame.midY))
    }
    #endif
}

private final class QuickLayoutPanel: NSPanel {
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

private final class QuickLayoutPassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class QuickLayoutHighlightView: NSView {
    private let windowFrame: CGRect
    private let visibleRegions: [CGRect]

    init(screenFrame: CGRect, windowFrame: CGRect, visibleRegions: [CGRect]) {
        self.windowFrame = windowFrame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        self.visibleRegions = visibleRegions.map { $0.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY) }
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { return nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        // Clip the original window outline, rather than outlining individual
        // visible pieces. Occlusion therefore never introduces interior seams.
        let visible = CGMutablePath()
        for region in visibleRegions { visible.addRect(region) }
        context.addPath(visible)
        context.clip()
        let accent = NSColor(calibratedRed: 0.24, green: 0.53, blue: 1, alpha: 1)
        context.setFillColor(accent.withAlphaComponent(0.10).cgColor)
        context.fill(windowFrame)
        context.setStrokeColor(accent.withAlphaComponent(0.88).cgColor)
        context.setLineWidth(2)
        let outline = CGPath(roundedRect: windowFrame.insetBy(dx: 1, dy: 1),
                             cornerWidth: 8, cornerHeight: 8, transform: nil)
        context.addPath(outline)
        context.strokePath()
    }
}
