import AppKit

nonisolated enum PinnedLaunchTarget: Codable, Equatable, Sendable {
    case application
    case finder(path: String)
    case terminal(path: String)
    case browser(urls: [String], selectedTabIndex: Int)
}

// Chrome's session ID and the system window ID are different namespaces.
// Their association is valid only for this exact process and live window.
nonisolated struct PinnedChromeWindowIdentity: Codable, Equatable, Sendable {
    let processID: Int32
    let processLaunchDate: Date
    let captureID: UInt32
    let windowID: PinnedAppleWindowID

    func matches(_ window: WindowItem, launchDate: Date?) -> Bool {
        processID == window.processID && processLaunchDate == launchDate && captureID == window.captureID
    }
}

// Only this value is saved with the list. Accessibility references stay in
// memory; all docked previews are stored separately as local PNG files.
nonisolated struct SavedPinnedWindow: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let applicationBundleIdentifier: String
    let applicationURL: String
    let applicationName: String
    let title: String
    let width: Double
    let height: Double
    let target: PinnedLaunchTarget
    var processID: Int32? = nil
    var processLaunchDate: Date? = nil
    var captureID: UInt32? = nil
    // Older records contained only retained items. Missing means retained
    // for those records; new unretained snapshots explicitly save false.
    var retainAfterClose: Bool? = nil
    var chromeWindowIdentity: PinnedChromeWindowIdentity? = nil
}

nonisolated struct PinnedWindowEntry: Identifiable, @unchecked Sendable {
    let id: UUID
    var window: WindowItem? {
        didSet {
            if let window { lastWindow = window }
        }
    }
    var saved: SavedPinnedWindow?
    var combination: SavedPinnedCombination?
    // Closing only clears the activatable window. Keep its last display
    // metadata in memory separately from the saved reopen target.
    private var lastWindow: WindowItem?

    init(window: WindowItem) {
        id = window.id
        self.window = window
        lastWindow = window
    }

    init(saved: SavedPinnedWindow) {
        id = saved.id
        self.saved = saved
    }

    init(combination: SavedPinnedCombination) {
        id = combination.id
        self.combination = combination
    }

    init(savedItem: SavedPinnedItem) {
        switch savedItem {
        case .window(let saved): self.init(saved: saved)
        case .combination(let combination): self.init(combination: combination)
        }
    }

    @MainActor
    func savedItem() -> SavedPinnedItem? {
        if let combination { return .combination(combination) }
        return recordForSaving().map(SavedPinnedItem.window)
    }

    var applicationName: String { lastWindow?.applicationName ?? saved?.applicationName ?? "" }
    var allowsThumbnail: Bool {
        if combination != nil { return true }
        return WindowThumbnailCapture.isAllowed(applicationBundleIdentifier:
            lastWindow?.applicationBundleIdentifier ?? saved?.applicationBundleIdentifier)
    }
    var title: String { combination?.name ?? lastWindow?.title ?? saved?.title ?? "" }
    var frame: CGRect {
        if let combination { return CGRect(x: 0, y: 0, width: combination.width, height: combination.height) }
        return lastWindow?.frame ?? CGRect(x: 0, y: 0, width: saved?.width ?? 0, height: saved?.height ?? 0)
    }
    var isRetained: Bool { combination != nil || (saved.map { $0.retainAfterClose ?? true } ?? false) }
    // Unretained snapshots await reconnection after launch. A missing AX
    // reference alone does not prove closure; confirmed closed items leave.
    var isClosed: Bool { combination == nil && window == nil && isRetained }

    @MainActor
    func recordForSaving() -> SavedPinnedWindow? {
        guard let lastWindow else { return saved }
        let application = window.flatMap { NSRunningApplication(processIdentifier: $0.processID) }
        let launchDate = application.flatMap(WindowCatalog.processLaunchDate) ?? saved?.processLaunchDate
        let chromeIdentity = saved?.chromeWindowIdentity.flatMap {
            isRetained && $0.matches(lastWindow, launchDate: launchDate) ? $0 : nil
        }
        return SavedPinnedWindow(
            id: id, applicationBundleIdentifier: application?.bundleIdentifier ?? saved?.applicationBundleIdentifier ?? "",
            applicationURL: application?.bundleURL?.absoluteString ?? saved?.applicationURL ?? "",
            applicationName: applicationName, title: title, width: frame.width, height: frame.height,
            target: isRetained ? saved?.target ?? .application : .application,
            processID: lastWindow.processID, processLaunchDate: launchDate,
            captureID: lastWindow.captureID, retainAfterClose: isRetained,
            chromeWindowIdentity: chromeIdentity)
    }

    @MainActor
    var icon: NSImage? {
        if combination != nil { return NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil) }
        if let lastWindow { return lastWindow.icon }
        guard let saved, let url = URL(string: saved.applicationURL), url.isFileURL else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
