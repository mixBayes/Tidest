import AppKit
import ApplicationServices
import OSLog

nonisolated struct LayoutTarget: @unchecked Sendable {
    let window: WindowItem
    // Accessibility and CG window bounds use a top-left screen origin.
    let visibleRegions: [CGRect]
}

nonisolated enum WindowLayoutResult: Equatable, Sendable {
    case exact
    case constrained
    case unavailable
}

@MainActor
final class WindowLayoutService {
    #if DEBUG
    private nonisolated static let diagnostics = Logger(subsystem: "com.mixbayes.tidest", category: "WindowLookup")
    #endif
    nonisolated struct ScreenWindow: Sendable {
        let id: CGWindowID
        let processID: pid_t
        let frame: CGRect
        let layer: Int
        let order: Int
    }

    private nonisolated struct ApplicationInfo: @unchecked Sendable {
        let name: String
        let icon: NSImage?
        let bundleIdentifier: String?
    }

    func target(at point: CGPoint, screens: [CGRect]) async -> LayoutTarget? {
        guard AXIsProcessTrusted() else {
            Self.logDiagnostic("rejected accessibility-not-trusted")
            return nil
        }
        guard screens.contains(where: { $0.contains(point) }) else {
            Self.logDiagnostic("rejected pointer-outside-screens point=\(point) screens=\(screens)")
            return nil
        }
        // Take this snapshot before suspending: the window under the shortcut's
        // mouse position must not come from the switcher's cached catalogue.
        let windows = Self.screenWindows()
        guard let front = Self.selectSnapshot(at: point, in: windows,
                                              ownProcessID: ProcessInfo.processInfo.processIdentifier) else {
            if let blocked = windows.first(where: { $0.frame.contains(point) }) {
                Self.logDiagnostic("rejected front-window pid=\(blocked.processID) ownPid=\(ProcessInfo.processInfo.processIdentifier) layer=\(blocked.layer) id=\(blocked.id) frame=\(blocked.frame) point=\(point)")
            } else {
                Self.logDiagnostic("rejected no-window-at-pointer windowCount=\(windows.count) point=\(point)")
            }
            return nil
        }
        guard let app = NSRunningApplication(processIdentifier: front.processID) else {
            Self.logDiagnostic("rejected application-unavailable pid=\(front.processID)")
            return nil
        }
        guard app.activationPolicy == .regular, !app.isTerminated else {
            Self.logDiagnostic("rejected application-state pid=\(front.processID) policy=\(app.activationPolicy.rawValue) terminated=\(app.isTerminated)")
            return nil
        }
        let application = ApplicationInfo(name: app.localizedName ?? "", icon: app.icon, bundleIdentifier: app.bundleIdentifier)
        let task = Task.detached(priority: .userInitiated) {
            Self.identify(point: point, front: front, windows: windows, screens: screens, application: application)
        }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        Self.logDiagnostic("lookup finished cancelled=\(Task.isCancelled) found=\(result != nil) pid=\(front.processID) id=\(front.id)")
        return Task.isCancelled ? nil : result
    }

    func apply(_ layout: QuickLayout, to target: LayoutTarget, in area: CGRect) async -> WindowLayoutResult {
        guard AXIsProcessTrusted(), Self.valid(area),
              let app = NSRunningApplication(processIdentifier: target.window.processID),
              !app.isTerminated else { return .unavailable }
        let window = target.window
        let task = Task.detached(priority: .userInitiated) {
            AXUIElementSetMessagingTimeout(window.element, 0.15)
            return await Self.performLayout(layout, in: area,
                readFrame: { AXAccess.frame(window.element) },
                isSettable: { attribute in
                    var settable = DarwinBoolean(false)
                    let error = AXUIElementIsAttributeSettable(window.element, attribute as CFString, &settable)
                    if error == .attributeUnsupported { return false }
                    return error == .success ? settable.boolValue : nil
                },
                setSize: { size in
                    var size = size
                    guard let value = AXValueCreate(.cgSize, &size) else { return .illegalArgument }
                    return AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, value)
                },
                setPosition: { position in
                    var position = position
                    guard let value = AXValueCreate(.cgPoint, &position) else { return .illegalArgument }
                    return AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, value)
                },
                pause: {
                    do {
                        try await Task.sleep(for: .milliseconds(50))
                        return !Task.isCancelled
                    } catch { return false }
                })
        }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        return Task.isCancelled ? .unavailable : result
    }

    // A front panel which cannot be laid out still blocks selection of the
    // application behind it. Never search for the next supported window.
    nonisolated static func selectSnapshot(at point: CGPoint, in windows: [ScreenWindow], ownProcessID: pid_t) -> ScreenWindow? {
        guard let front = windows.first(where: { $0.frame.contains(point) }),
              front.layer == 0, front.processID != ownProcessID else { return nil }
        return front
    }

    nonisolated static func matchesSnapshot(frame: CGRect, processID: pid_t, snapshot: ScreenWindow) -> Bool {
        processID == snapshot.processID && sameFrame(frame, snapshot.frame)
    }

    private nonisolated static func screenWindows() -> [ScreenWindow] {
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            logDiagnostic("screen-window-list unavailable")
            return []
        }
        return entries.enumerated().compactMap { order, info in
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                  let processID = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), valid(frame) else { return nil }
            return ScreenWindow(id: id, processID: processID, frame: frame, layer: layer, order: order)
        }
    }

    private nonisolated static func identify(point: CGPoint, front: ScreenWindow, windows: [ScreenWindow],
                                             screens: [CGRect], application: ApplicationInfo) -> LayoutTarget? {
        guard !Task.isCancelled else {
            logDiagnostic("identify cancelled-before-hit")
            return nil
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var hit: AXUIElement?
        let hitError = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
        guard hitError == .success, let hit, !Task.isCancelled else {
            logDiagnostic("rejected accessibility-hit error=\(hitError.rawValue) elementPresent=\(hit != nil) cancelled=\(Task.isCancelled) point=\(point)")
            return nil
        }
        var processID: pid_t = 0
        let processError = AXUIElementGetPid(hit, &processID)
        guard processError == .success, processID == front.processID else {
            logDiagnostic("rejected accessibility-pid error=\(processError.rawValue) hitPid=\(processID) frontPid=\(front.processID)")
            return nil
        }
        AXUIElementSetMessagingTimeout(hit, 0.15)
        let element: AXUIElement
        if AXAccess.value(hit, kAXRoleAttribute) as? String == kAXWindowRole {
            element = hit
        } else {
            guard let value = AXAccess.value(hit, kAXWindowAttribute),
                  CFGetTypeID(value) == AXUIElementGetTypeID() else {
                logDiagnostic("rejected accessibility-hit-has-no-window pid=\(processID)")
                return nil
            }
            element = value as! AXUIElement
        }
        AXUIElementSetMessagingTimeout(element, 0.15)
        guard !Task.isCancelled else {
            logDiagnostic("identify cancelled-after-hit")
            return nil
        }
        let role = AXAccess.value(element, kAXRoleAttribute) as? String
        guard role == kAXWindowRole else {
            logDiagnostic("rejected accessibility-window-role role=\(role ?? "missing") pid=\(processID)")
            return nil
        }
        guard let subrole = AXAccess.value(element, kAXSubroleAttribute) as? String,
              subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else {
            logDiagnostic("rejected accessibility-window-subrole pid=\(processID)")
            return nil
        }
        guard let frame = AXAccess.frame(element), valid(frame) else {
            logDiagnostic("rejected accessibility-window-frame pid=\(processID)")
            return nil
        }
        guard AXAccess.value(element, kAXMinimizedAttribute) as? Bool != true else {
            logDiagnostic("rejected accessibility-window-minimized pid=\(processID)")
            return nil
        }
        let title = AXAccess.value(element, kAXTitleAttribute) as? String ?? ""
        // The system-wide AX hit already identifies the concrete window.
        // Validate it against the front CG bounds instead of matching titles:
        // CG titles can be withheld without screen-recording permission, and
        // two windows from one app can have identical bounds and titles.
        guard matchesSnapshot(frame: frame, processID: processID, snapshot: front),
              !Task.isCancelled else {
            logDiagnostic("rejected window-bounds-mismatch axFrame=\(frame) cgFrame=\(front.frame) pid=\(processID) cancelled=\(Task.isCancelled)")
            return nil
        }
        // CG only exposes rectangular bounds, so transparent corners and holes
        // are conservatively treated as occupied. No screenshots are requested.
        let visible = QuickLayoutGeometry.visibleRegions(of: frame,
            occluders: windows.filter { $0.order < front.order }.map(\.frame), screens: screens)
        guard visible.contains(where: { $0.contains(point) }) else {
            logDiagnostic("rejected pointer-outside-visible-region point=\(point) regions=\(visible) frame=\(frame) pid=\(processID)")
            return nil
        }
        logDiagnostic("identified window pid=\(processID) id=\(front.id) regionCount=\(visible.count)")
        return LayoutTarget(window: WindowItem(element: element, processID: processID,
            applicationName: application.name, icon: application.icon,
            title: title.isEmpty ? application.name : title, frame: frame, minimized: false,
            captureID: front.id, stackOrder: front.order,
            applicationBundleIdentifier: application.bundleIdentifier), visibleRegions: visible)
    }

    // Temporary Debug diagnostics exclude titles, URLs and document contents.
    private nonisolated static func logDiagnostic(_ message: @autoclosure () -> String) {
        #if DEBUG
        let messageText = message()
        diagnostics.notice("\(messageText, privacy: .public)")
        #endif
    }

    // The closures keep the real AX decision path testable without creating
    // windows, requesting permissions or emulating the whole accessibility API.
    nonisolated static func performLayout(_ layout: QuickLayout, in area: CGRect,
        readFrame: () -> CGRect?, isSettable: (String) -> Bool?,
        setSize: (CGSize) -> AXError, setPosition: (CGPoint) -> AXError,
        pause: () async -> Bool) async -> WindowLayoutResult {
        guard !Task.isCancelled, valid(area),
              let initial = readFrame(), valid(initial),
              isSettable(kAXPositionAttribute) == true,
              let resizable = isSettable(kAXSizeAttribute) else { return .unavailable }
        let requested = layout.frame(in: area)
        var actual = initial
        if resizable {
            // A failed message is not evidence of a minimum window size.
            guard !Task.isCancelled, setSize(requested.size) == .success,
                  let resized = await settledFrame(readFrame: readFrame, pause: pause,
                    matches: { sameSize($0.size, requested.size) }) else { return .unavailable }
            actual = resized
        }
        // Leave room for the requested size when moving. Anchoring a size
        // temporarily limited by the old position would keep that limit in
        // place (for example, centering a right-half window before enlarging).
        let placementSize = resizable
            ? CGSize(width: max(actual.width, requested.width), height: max(actual.height, requested.height))
            : actual.size
        let destination = layout.anchoredFrame(size: placementSize, in: area).origin
        guard !Task.isCancelled, setPosition(destination) == .success,
              let moved = await settledFrame(readFrame: readFrame, pause: pause,
                matches: { abs($0.minX - destination.x) <= 2 && abs($0.minY - destination.y) <= 2 }) else { return .unavailable }
        actual = moved
        // The old position or display can limit an otherwise resizable
        // window. Apply the size again at its destination before deciding
        // that the application has a permanent size limit.
        if resizable && !sameSize(actual.size, requested.size) {
            guard !Task.isCancelled, setSize(requested.size) == .success,
                  let resized = await settledFrame(readFrame: readFrame, pause: pause,
                    matches: { sameSize($0.size, requested.size) }) else { return .unavailable }
            actual = resized
        }
        let anchored = layout.anchoredFrame(size: actual.size, in: area)
        if !sameFrame(actual, anchored) {
            guard !Task.isCancelled, setPosition(anchored.origin) == .success,
                  let corrected = await settledFrame(readFrame: readFrame, pause: pause,
                    matches: { sameFrame($0, anchored) }) else { return .unavailable }
            actual = corrected
        }
        // A size-limit tip is justified only after the window actually reaches
        // the requested edge. A successful AX message alone does not prove it
        // moved, and a fixed-size window may already have the requested size.
        guard sameFrame(actual, layout.anchoredFrame(size: actual.size, in: area)) else { return .unavailable }
        return sameFrame(actual, requested) ? .exact : .constrained
    }

    private nonisolated static func settledFrame(readFrame: () -> CGRect?, pause: () async -> Bool,
                                                  matches: (CGRect) -> Bool) async -> CGRect? {
        var last: CGRect?
        for _ in 0..<6 {
            guard !Task.isCancelled, await pause(),
                  let frame = readFrame(), valid(frame) else { return nil }
            last = frame
            if matches(frame) { return frame }
        }
        return last
    }

    private nonisolated static func valid(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite &&
        frame.width > 1 && frame.height > 1
    }

    private nonisolated static func sameSize(_ left: CGSize, _ right: CGSize) -> Bool {
        abs(left.width - right.width) <= 2 && abs(left.height - right.height) <= 2
    }

    private nonisolated static func sameFrame(_ left: CGRect, _ right: CGRect) -> Bool {
        sameSize(left.size, right.size) && abs(left.minX - right.minX) <= 2 && abs(left.minY - right.minY) <= 2
    }
}
