import AppKit
import ApplicationServices
import Darwin

nonisolated struct WindowItem: Identifiable, @unchecked Sendable {
    var id = UUID()
    let element: AXUIElement
    let processID: pid_t
    let applicationName: String
    let icon: NSImage?
    let title: String
    let frame: CGRect
    let minimized: Bool
    var captureID: CGWindowID?
    var stackOrder: Int
    var applicationBundleIdentifier: String? = nil

    var allowsThumbnail: Bool {
        WindowThumbnailCapture.isAllowed(applicationBundleIdentifier: applicationBundleIdentifier)
    }
}

nonisolated struct CaptureWindow: Sendable {
    let id: CGWindowID
    let processID: pid_t
    let order: Int
}

nonisolated enum WindowPresence: Sendable {
    case present
    case closed
    case unknown
}

nonisolated enum AXAccess {
    private typealias WindowIDReader = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32

    // This unpublished system function identifies the concrete window without
    // comparing titles or geometry. Resolve it at runtime so its absence only
    // removes previews and stack information; AX window operations still work.
    private static let windowIDReader: WindowIDReader? = {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: WindowIDReader.self)
    }()

    static func windowID(_ window: AXUIElement) -> CGWindowID? {
        guard let read = windowIDReader else { return nil }
        var id: CGWindowID = 0
        guard read(window, &id) == AXError.success.rawValue, id != kCGNullWindowID else { return nil }
        return id
    }

    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
    static func frame(_ window: AXUIElement) -> CGRect? {
        guard let position = value(window, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(window, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}

@MainActor
final class WindowCatalog {
    // AppKit does not report a launch date for some apps, including Finder.
    // Keep its date where available so existing saved identities stay valid;
    // the kernel still supplies the start time for those missing dates.
    static func processLaunchDate(_ application: NSRunningApplication) -> Date? {
        if let date = application.launchDate { return date }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(application.processIdentifier, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
              info.pbi_start_tvsec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    private nonisolated struct ApplicationInfo: @unchecked Sendable {
        let processID: pid_t
        let name: String
        let icon: NSImage?
        let bundleIdentifier: String?
    }
    private var knownWindows: [WindowItem] = []
    func stop() {
        knownWindows = []
    }

    // Pinning one window must preserve identities already used by the
    // switcher. AX identity stays stable across moves and title changes.
    @discardableResult
    func track(_ window: WindowItem, preferredID: UUID? = nil) -> WindowItem {
        var window = window
        if let preferredID { window.id = preferredID }
        if let index = knownWindows.firstIndex(where: {
            $0.processID == window.processID && CFEqual($0.element, window.element)
        }) {
            window.id = preferredID ?? knownWindows[index].id
            knownWindows[index] = window
        } else {
            knownWindows.append(window)
        }
        return window
    }

    static func presence(of window: WindowItem) async -> WindowPresence {
        guard !Task.isCancelled else { return .unknown }
        guard let app = NSRunningApplication(processIdentifier: window.processID),
              !app.isTerminated else { return .closed }
        guard AXIsProcessTrusted() else { return .unknown }
        let task = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return WindowPresence.unknown }
            AXUIElementSetMessagingTimeout(window.element, 0.15)
            var role: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(window.element, kAXRoleAttribute as CFString, &role)
            guard !Task.isCancelled else { return .unknown }
            if result == .invalidUIElement { return .closed }
            if result == .success, role as? String == kAXWindowRole { return .present }
            // A busy application, missing permission or unsupported attribute
            // is not proof that the user closed this window.
            return .unknown
        }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        return Task.isCancelled ? .unknown : result
    }

    static func presence(of saved: SavedPinnedWindow) async -> WindowPresence {
        guard !Task.isCancelled, let processID = saved.processID else { return .unknown }
        guard let application = NSRunningApplication(processIdentifier: processID), !application.isTerminated
        else { return .closed }
        guard !saved.applicationBundleIdentifier.isEmpty else { return .unknown }
        guard application.bundleIdentifier == saved.applicationBundleIdentifier else { return .closed }
        if let launchDate = saved.processLaunchDate {
            guard let currentDate = processLaunchDate(application) else { return .unknown }
            guard currentDate == launchDate else { return .closed }
        }
        // Legacy Finder records have no date. The exact system window number
        // and its owning process can still establish whether the window exists.
        guard let captureID = saved.captureID else { return .unknown }
        let task = Task.detached(priority: .utility) {
            guard !Task.isCancelled,
                  let infos = CGWindowListCopyWindowInfo(.optionIncludingWindow, captureID) as? [[String: Any]]
            else { return WindowPresence.unknown }
            return infos.contains {
                $0[kCGWindowNumber as String] as? UInt32 == captureID &&
                $0[kCGWindowOwnerPID as String] as? Int32 == processID
            } ? .present : .closed
        }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        return Task.isCancelled ? .unknown : result
    }

    func load() async -> [WindowItem] {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.map { ApplicationInfo(processID: $0.processIdentifier, name: $0.localizedName ?? AppSettings.shared.text("应用"), icon: $0.icon, bundleIdentifier: $0.bundleIdentifier) }
        let task = Task.detached(priority: .userInitiated) { Self.scan(apps) }
        let windows = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled else { return [] }
        return identify(Self.sortedByStackOrder(windows))
    }

    var cachedWindows: [WindowItem] { Self.sortedByStackOrder(knownWindows) }

    func currentWindows() -> [WindowItem] {
        Self.ordered(knownWindows, candidates: Self.captureCandidates())
    }

    // Cached screenshots keep their AX identity, but their old stack positions
    // must be replaced before the panel opens. CG IDs survive moves and renames.
    nonisolated static func ordered(_ windows: [WindowItem], candidates: [CaptureWindow]) -> [WindowItem] {
        let updated = windows.map { window in
            var window = window
            let candidate = candidates.first { $0.id == window.captureID && $0.processID == window.processID }
            window.stackOrder = candidate?.order ?? Int.max
            return window
        }
        return sortedByStackOrder(updated)
    }

    private nonisolated static func sortedByStackOrder(_ windows: [WindowItem]) -> [WindowItem] {
        windows.sorted { left, right in
            if left.stackOrder != right.stackOrder { return left.stackOrder < right.stackOrder }
            if left.processID != right.processID { return left.applicationName.localizedStandardCompare(right.applicationName) == .orderedAscending }
            return left.title.localizedStandardCompare(right.title) == .orderedAscending
        }
    }

    // AX identifies the actual window even when its title or position changes.
    // Keep its UUID across scans so an existing thumbnail remains reusable.
    func identify(_ entries: [WindowItem]) -> [WindowItem] {
        let identified = entries.map { entry in
            var entry = entry
            if let previous = knownWindows.first(where: { $0.processID == entry.processID && CFEqual($0.element, entry.element) }) {
                entry.id = previous.id
            }
            return entry
        }
        knownWindows = identified
        return identified
    }

    func activate(_ window: WindowItem) -> Bool {
        Self.activateWindow(window)
    }

    static func activateWindow(_ window: WindowItem) -> Bool {
        guard AXIsProcessTrusted(), let app = NSRunningApplication(processIdentifier: window.processID), !app.isTerminated else { return false }
        AXUIElementSetMessagingTimeout(window.element, 1)
        if AXAccess.value(window.element, kAXMinimizedAttribute) as? Bool == true {
            guard AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else { return false }
        }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(window.element, kAXMainAttribute as CFString, &settable) == .success, settable.boolValue {
            _ = AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        guard app.activate() else { return false }
        guard AXUIElementPerformAction(window.element, kAXRaiseAction as CFString) == .success else { return false }
        return true
    }

    nonisolated static func captureCandidates() -> [CaptureWindow] {
        // Onscreen windows have an explicit front-to-back order. Append hidden,
        // minimized and other-Space windows after the current desktop's stack.
        let onscreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var seen: Set<CGWindowID> = []
        return (onscreen + all).enumerated().compactMap { order, info in
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  info[kCGWindowLayer as String] as? Int == 0,
                  seen.insert(id).inserted else { return nil }
            return CaptureWindow(id: id, processID: pid, order: order)
        }
    }

    private nonisolated static func scan(_ applications: [ApplicationInfo]) -> [WindowItem] {
        let candidates = captureCandidates()
        var windows: [WindowItem] = []
        for app in applications {
            if Task.isCancelled { break }
            let element = AXUIElementCreateApplication(app.processID)
            AXUIElementSetMessagingTimeout(element, 0.15)
            guard let elements = AXAccess.value(element, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            for window in elements {
                if Task.isCancelled { break }
                AXUIElementSetMessagingTimeout(window, 0.15)
                guard AXAccess.value(window, kAXRoleAttribute) as? String == kAXWindowRole,
                      let frame = AXAccess.frame(window), frame.width > 1, frame.height > 1 else { continue }
                let subrole = AXAccess.value(window, kAXSubroleAttribute) as? String
                guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { continue }
                let title = AXAccess.value(window, kAXTitleAttribute) as? String ?? ""
                let captureID = AXAccess.windowID(window)
                let candidate = candidates.first { $0.id == captureID && $0.processID == app.processID }
                windows.append(WindowItem(element: window, processID: app.processID, applicationName: app.name, icon: app.icon, title: title.isEmpty ? app.name : title, frame: frame, minimized: AXAccess.value(window, kAXMinimizedAttribute) as? Bool ?? false, captureID: captureID, stackOrder: candidate?.order ?? Int.max, applicationBundleIdentifier: app.bundleIdentifier))
            }
        }
        let captureCounts = Dictionary(windows.compactMap(\.captureID).map { ($0, 1) }, uniquingKeysWith: +)
        for index in windows.indices {
            if let id = windows[index].captureID, captureCounts[id, default: 0] > 1 {
                windows[index].captureID = nil
                windows[index].stackOrder = Int.max
            }
        }
        return windows
    }
}
