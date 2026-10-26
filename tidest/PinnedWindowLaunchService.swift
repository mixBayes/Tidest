import AppKit
import ApplicationServices
import CoreServices
import Darwin
import OSLog

nonisolated enum PinnedWindowLaunchError: Error, LocalizedError, Equatable, Sendable {
    case applicationUnavailable, windowUnavailable, automationDenied, folderUnavailable
    case terminalDirectoryUnavailable, tabsUnavailable, openFailed, incompleteRestore

    var errorDescription: String? {
        switch self {
        case .applicationUnavailable: return "找不到这个应用，请重新添加窗口"
        case .windowUnavailable: return "这个窗口暂时无法确认，请再试一次"
        case .automationDenied: return "请允许 Tidest 控制这个应用，然后再试一次"
        case .folderUnavailable: return "这个文件夹无法重新打开，请重新选择"
        case .terminalDirectoryUnavailable: return "无法读取终端的本地目录，请再试一次"
        case .tabsUnavailable: return "无法读取这个窗口的全部标签，请再试一次"
        case .openFailed: return "应用未能打开，请再试一次"
        case .incompleteRestore: return "窗口已打开，但部分内容未能恢复，请在应用中查看"
        }
    }
}

// Apple Events carry paths and URLs as typed data. They never become
// AppleScript source. Terminal receives only one escaped, absolute cd argument.
@MainActor
final class PinnedWindowLaunchService {
    private struct OpenedWindow {
        let processID: pid_t
        let launchDate: Date?
        let outcome: PinnedCreationOutcome
    }
    private var openedWindows: [UUID: OpenedWindow] = [:]
    private var openTasks: [UUID: (token: UUID, task: Task<WindowItem?, Error>)] = [:]
    private var generations: [UUID: UUID] = [:]
    private var chromeWindows: [UUID: PinnedChromeWindowIdentity] = [:]

    func forget(_ id: UUID) {
        openedWindows.removeValue(forKey: id)
        chromeWindows.removeValue(forKey: id)
        // An application may finish opening after the caller cancels/removes
        // an item. Do not resurrect its remembered target in that case.
        generations[id] = UUID()
    }

    func capture(_ window: WindowItem, previous: SavedPinnedWindow? = nil,
                 allowsInteraction: Bool = true) async throws -> SavedPinnedWindow {
        try Task.checkCancellation()
        guard let app = NSRunningApplication(processIdentifier: window.processID), !app.isTerminated,
              let bundleID = app.bundleIdentifier, let applicationURL = app.bundleURL else {
            throw PinnedWindowLaunchError.applicationUnavailable
        }
        let launchDate = WindowCatalog.processLaunchDate(app)
        let liveWindow = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try PinnedAppleEvents.currentWindow(window)
        }.value
        try Task.checkCancellation()
        var chromeIdentity: PinnedChromeWindowIdentity?
        if bundleID == "com.google.Chrome" {
            chromeIdentity = [chromeWindows[window.id], previous?.chromeWindowIdentity]
                .compactMap { $0 }.first { $0.matches(liveWindow, launchDate: launchDate) }
            if chromeIdentity == nil {
                guard let launchDate, let captureID = liveWindow.captureID else {
                    throw PinnedWindowLaunchError.windowUnavailable
                }
                try await Task.detached(priority: .userInitiated) {
                    try PinnedAppleEvents(processID: window.processID, allowsInteraction: allowsInteraction)
                        .checkAutomationPermission()
                }.value
                try Task.checkCancellation()
                if allowsInteraction, !WindowCatalog.activateWindow(liveWindow) {
                    throw PinnedWindowLaunchError.windowUnavailable
                }
                let info = PinnedApplicationInfo(processID: app.processIdentifier,
                    name: liveWindow.applicationName, icon: liveWindow.icon, bundleIdentifier: bundleID)
                // Explicit pinning can wait for activation. A background read
                // only establishes an association if the user already focused it.
                for attempt in 0..<(allowsInteraction ? 12 : 1) {
                    try Task.checkCancellation()
                    let pair = try await Task.detached(priority: .userInitiated) {
                        try PinnedAppleEvents(processID: window.processID, allowsInteraction: allowsInteraction)
                            .focusedChromeWindow(info, matching: liveWindow)
                    }.value
                    if let pair {
                        chromeIdentity = PinnedChromeWindowIdentity(processID: window.processID,
                            processLaunchDate: launchDate, captureID: captureID, windowID: pair.identifier)
                        break
                    }
                    if attempt < 11, allowsInteraction { try await Task.sleep(for: .milliseconds(100)) }
                }
                guard chromeIdentity != nil else { throw PinnedWindowLaunchError.windowUnavailable }
            }
        }
        let chromeWindowID = chromeIdentity?.windowID
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try PinnedAppleEvents.capture(liveWindow, bundleID: bundleID,
                allowsInteraction: allowsInteraction, chromeWindowID: chromeWindowID)
        }
        let target = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard !app.isTerminated, WindowCatalog.processLaunchDate(app) == launchDate else {
            throw PinnedWindowLaunchError.applicationUnavailable
        }
        if let chromeIdentity { chromeWindows[window.id] = chromeIdentity }
        return SavedPinnedWindow(id: window.id, applicationBundleIdentifier: bundleID,
                                 applicationURL: applicationURL.absoluteString,
                                 applicationName: window.applicationName, title: liveWindow.title,
                                 width: liveWindow.frame.width, height: liveWindow.frame.height, target: target,
                                 processID: window.processID, processLaunchDate: launchDate,
                                 captureID: liveWindow.captureID, chromeWindowIdentity: chromeIdentity)
    }

    func chromeWindowIdentity(for window: WindowItem) -> PinnedChromeWindowIdentity? {
        let launchDate = NSRunningApplication(processIdentifier: window.processID)
            .flatMap(WindowCatalog.processLaunchDate)
        return chromeWindows[window.id].flatMap { $0.matches(window, launchDate: launchDate) ? $0 : nil }
    }

    // nil means the app opened, but no exact AX window could be associated.
    // A repeated click resolves/activates the same created window. Only proof
    // that that window closed permits creation of another one.
    func open(_ saved: SavedPinnedWindow) async throws -> WindowItem? {
        try Task.checkCancellation()
        if let pending = openTasks[saved.id] { return try await pending.task.value }
        let token = UUID()
        let generation = generations[saved.id] ?? UUID()
        generations[saved.id] = generation
        // Once a launch starts it finishes remembering its side effects even
        // if the shelf task is cancelled. The caller decides whether to show
        // the result; cancellation cannot undo a created application window.
        let task = Task { try await performOpen(saved, generation: generation) }
        openTasks[saved.id] = (token, task)
        defer {
            if openTasks[saved.id]?.token == token { openTasks.removeValue(forKey: saved.id) }
        }
        return try await task.value
    }

    private func performOpen(_ saved: SavedPinnedWindow, generation: UUID) async throws -> WindowItem? {
        if let opened = openedWindows[saved.id],
           let app = NSRunningApplication(processIdentifier: opened.processID), !app.isTerminated,
           WindowCatalog.processLaunchDate(app) == opened.launchDate, app.bundleIdentifier == saved.applicationBundleIdentifier {
            app.activate()
            let state = await Task.detached(priority: .userInitiated) {
                let events = PinnedAppleEvents(processID: opened.processID)
                let outcome = events.retryCreated(opened.outcome, target: saved.target, bundleID: saved.applicationBundleIdentifier)
                return outcome
            }.value
            if !state.windowKnownClosed {
                if generations[saved.id] == generation {
                    openedWindows[saved.id] = OpenedWindow(processID: opened.processID, launchDate: opened.launchDate,
                                                         outcome: state)
                }
                if let error = state.error { throw error }
                guard let identifier = state.identifier else { return nil }
                return try await resolve(identifier, app: app, id: saved.id)
            }
        }
        openedWindows.removeValue(forKey: saved.id)
        let applicationURL = try installedApplication(saved)
        // Validate every input before causing any application to open.
        try await Task.detached(priority: .userInitiated) { try PinnedAppleEvents.validate(saved.target) }.value
        let previous = await accessibilityWindows(for: saved.applicationBundleIdentifier)
        let configuration = NSWorkspace.OpenConfiguration()
        switch saved.target {
        case .finder, .terminal:
            // A normal open/reopen event can create a default window before
            // the saved folder or directory is opened in its own window.
            // Only launch here; create below opens the exact saved target.
            configuration.activates = false
            configuration.appleEvent = NSAppleEventDescriptor(
                eventClass: PinnedAppleEvents.fourCC("ascr"), eventID: PinnedAppleEvents.fourCC("noop"),
                targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: saved.applicationBundleIdentifier),
                returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        default: break
        }
        let app: NSRunningApplication
        do {
            app = try await NSWorkspace.shared.openApplication(at: applicationURL,
                                                               configuration: configuration)
        } catch {
            throw PinnedWindowLaunchError.openFailed
        }
        if saved.target == .application {
            // For apps without a window-creation interface, only a unique new
            // window is trustworthy. Existing windows are never guessed.
            for _ in 0..<12 {
                let current = await accessibilityWindows(for: saved.applicationBundleIdentifier)
                let new = current.filter { candidate in
                    !previous.contains { $0.processID == candidate.processID && CFEqual($0.element, candidate.element) }
                }
                if new.count == 1 {
                    var window = new[0]
                    window.id = saved.id
                    return window
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            return nil
        }
        let outcome = await Task.detached(priority: .userInitiated) {
            PinnedAppleEvents(processID: app.processIdentifier).create(saved.target, bundleID: saved.applicationBundleIdentifier)
        }.value
        if outcome.creationAttempted, generations[saved.id] == generation {
            openedWindows[saved.id] = OpenedWindow(processID: app.processIdentifier, launchDate: WindowCatalog.processLaunchDate(app),
                                                 outcome: outcome)
        }
        if let error = outcome.error { throw error }
        app.activate()
        guard let identifier = outcome.identifier else { return nil }
        if app.bundleIdentifier == "com.google.Chrome" {
            return try await resolveChromeWindow(identifier, app: app, id: saved.id)
        }
        // Associate the exact created window even while its content loads.
        // Finder and Terminal use their ID directly; Safari reads metadata
        // from that ID on each attempt because its native ID is unverified.
        for _ in 0..<12 {
            if let window = try await resolve(identifier, app: app, id: saved.id) { return window }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return nil
    }

    private func installedApplication(_ saved: SavedPinnedWindow) throws -> URL {
        let stored = URL(string: saved.applicationURL)
        let candidates = [stored, NSWorkspace.shared.urlForApplication(withBundleIdentifier: saved.applicationBundleIdentifier)]
        guard let url = candidates.compactMap({ $0 }).first(where: {
            $0.isFileURL && Bundle(url: $0)?.bundleIdentifier == saved.applicationBundleIdentifier
        }) else { throw PinnedWindowLaunchError.applicationUnavailable }
        return url
    }

    private func accessibilityWindows(for bundleID: String) async -> [WindowItem] {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        let info = apps.map { PinnedApplicationInfo(processID: $0.processIdentifier,
                                                  name: $0.localizedName ?? bundleID, icon: $0.icon,
                                                  bundleIdentifier: $0.bundleIdentifier) }
        return await Task.detached(priority: .userInitiated) { PinnedAppleEvents.accessibilityWindows(info) }.value
    }

    private func resolveChromeWindow(_ identifier: PinnedAppleWindowID, app: NSRunningApplication,
                                    id: UUID) async throws -> WindowItem? {
        let info = PinnedApplicationInfo(processID: app.processIdentifier,
            name: app.localizedName ?? "", icon: app.icon, bundleIdentifier: app.bundleIdentifier)
        try await Task.detached(priority: .userInitiated) {
            try PinnedAppleEvents(processID: app.processIdentifier).bringForward(identifier)
        }.value
        app.activate()
        for attempt in 0..<12 {
            let pair = try await Task.detached(priority: .userInitiated) {
                try PinnedAppleEvents(processID: info.processID)
                    .focusedChromeWindow(info, identifier: identifier)
            }.value
            if let pair, let captureID = pair.window.captureID, let launchDate = WindowCatalog.processLaunchDate(app) {
                var window = pair.window
                window.id = id
                chromeWindows[id] = PinnedChromeWindowIdentity(processID: info.processID,
                    processLaunchDate: launchDate, captureID: captureID, windowID: identifier)
                return window
            }
            if attempt < 11 { try await Task.sleep(for: .milliseconds(150)) }
        }
        return nil
    }

    private func resolve(_ identifier: PinnedAppleWindowID, app: NSRunningApplication, id: UUID) async throws -> WindowItem? {
        if app.bundleIdentifier == "com.google.Chrome" {
            return try await resolveChromeWindow(identifier, app: app, id: id)
        }
        let info = PinnedApplicationInfo(processID: app.processIdentifier,
                                        name: app.localizedName ?? "", icon: app.icon,
                                        bundleIdentifier: app.bundleIdentifier)
        let windows = await Task.detached(priority: .userInitiated) { PinnedAppleEvents.accessibilityWindows([info]) }.value
        let matches: [WindowItem]
        if app.bundleIdentifier == "com.apple.finder" || app.bundleIdentifier == "com.apple.Terminal" {
            guard case .number(let number) = identifier else { return nil }
            matches = windows.filter { $0.captureID == UInt32(bitPattern: number) }
        } else {
            guard let snapshot = await Task.detached(priority: .userInitiated, operation: {
                try? PinnedAppleEvents(processID: app.processIdentifier).windowMetadata(identifier)
            }).value else { return nil }
            matches = windows.filter { PinnedAppleEvents.matches(title: $0.title, frame: $0.frame,
                                                                 title: snapshot.title, frame: snapshot.frame) }
        }
        guard matches.count == 1 else { return nil }
        var window = matches[0]
        window.id = id
        return window
    }
}

private nonisolated struct PinnedApplicationInfo: @unchecked Sendable {
    let processID: pid_t
    let name: String
    let icon: NSImage?
    let bundleIdentifier: String?
}

nonisolated enum PinnedAppleWindowID: Codable, Equatable, Hashable, Sendable {
    case number(Int32)
    case text(String)

    init(_ descriptor: NSAppleEventDescriptor) throws {
        // Finder returns UInt32 IDs; Terminal window references contain Int64
        // IDs. Normalize them before matching a system window or retrying.
        if [typeSInt32, typeUInt32, typeSInt64].contains(descriptor.descriptorType) {
            guard let value = descriptor.stringValue.flatMap(Int64.init),
                  (Int64(Int32.min)...Int64(UInt32.max)).contains(value) else {
                throw PinnedWindowLaunchError.windowUnavailable
            }
            // System window IDs use all 32 bits, including the sign bit.
            self = .number(Int32(truncatingIfNeeded: value))
        }
        else if let value = descriptor.stringValue, !value.isEmpty { self = .text(value) }
        else { throw PinnedWindowLaunchError.windowUnavailable }
    }
    var descriptor: NSAppleEventDescriptor {
        switch self {
        case .number(let value): return NSAppleEventDescriptor(int32: value)
        case .text(let value): return NSAppleEventDescriptor(string: value)
        }
    }
}

private nonisolated struct PinnedScriptWindow: Sendable {
    let identifier: PinnedAppleWindowID
    let title: String
    let frame: CGRect
}

private nonisolated struct PinnedCreationOutcome: Sendable {
    var creationAttempted = false
    var identifier: PinnedAppleWindowID?
    var referenceData: Data?
    var originalWindowIdentifiers: [PinnedAppleWindowID] = []
    var needsBrowserRestore = false
    var windowKnownClosed = false
    var error: PinnedWindowLaunchError?
}

nonisolated struct PinnedTerminalProcess: Sendable {
    let pid: pid_t
    let parentPID: pid_t
    let processGroupID: UInt32
    let foregroundGroupID: UInt32
    let deviceID: UInt32
    let isShell: Bool
}

// A short-lived client is confined to one background task. AppKit and the
// shelf are never held waiting for Apple Events or another app's AX response.
nonisolated struct PinnedAppleEvents {
    private static let diagnostics = Logger(subsystem: "com.mixbayes.tidest", category: "WindowRetention")
    let processID: pid_t
    let allowsInteraction: Bool

    init(processID: pid_t, allowsInteraction: Bool = true) {
        self.processID = processID
        self.allowsInteraction = allowsInteraction
    }

    private static let finderRecentsURL = URL(
        fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Resources/MyLibraries/myDocuments.cannedSearch",
        isDirectory: true)
    private static let finderRecentsNames: Set<String> = {
        guard let bundle = Bundle(url: finderRecentsURL),
              let tableURL = bundle.url(forResource: "InfoPlist", withExtension: "loctable"),
              let data = try? Data(contentsOf: tableURL),
              let names = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any] else { return [] }
        return Set(names.values.compactMap { ($0 as? [String: Any])?["CFBundleDisplayName"] as? String })
    }()

    static func fourCC(_ value: String) -> UInt32 {
        precondition(value.utf8.count == 4)
        return value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func object(_ desiredClass: String, form: String, data: NSAppleEventDescriptor,
                       container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor(recordDescriptor: ())
        record.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC(desiredClass)), forKeyword: UInt32(keyAEDesiredClass))
        record.setDescriptor(container, forKeyword: UInt32(keyAEContainer))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: fourCC(form)), forKeyword: UInt32(keyAEKeyForm))
        record.setDescriptor(data, forKeyword: UInt32(keyAEKeyData))
        return record.coerce(toDescriptorType: typeObjectSpecifier)!
    }
    static func property(_ code: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        object("prop", form: "prop", data: NSAppleEventDescriptor(typeCode: fourCC(code)), container: container)
    }
    static func element(_ kind: String, at index: Int, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        object(kind, form: "indx", data: NSAppleEventDescriptor(int32: Int32(index)), container: container)
    }
    static func all(_ kind: String, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        let ordinal = NSAppleEventDescriptor(enumCode: fourCC("all "))
        let all = NSAppleEventDescriptor(descriptorType: typeAbsoluteOrdinal, data: ordinal.data)!
        return object(kind, form: "indx", data: all, container: container)
    }
    private static func window(_ id: PinnedAppleWindowID) -> NSAppleEventDescriptor {
        object("cwin", form: "ID  ", data: id.descriptor)
    }

    private func send(_ eventID: String, eventClass: String = "core",
                      parameters: [String: NSAppleEventDescriptor]) throws -> NSAppleEventDescriptor {
        try Task.checkCancellation()
        let event = NSAppleEventDescriptor(eventClass: Self.fourCC(eventClass), eventID: Self.fourCC(eventID),
                                           targetDescriptor: NSAppleEventDescriptor(processIdentifier: processID),
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        for (keyword, value) in parameters { event.setParam(value, forKeyword: Self.fourCC(keyword)) }
        do {
            var options: NSAppleEventDescriptor.SendOptions = [.waitForReply]
            options.insert(allowsInteraction ? .canInteract : .neverInteract)
            let reply = try event.sendEvent(options: options, timeout: 30)
            if let error = reply.paramDescriptor(forKeyword: keyErrorNumber), error.int32Value != 0 {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(error.int32Value))
            }
            return reply.paramDescriptor(forKeyword: keyDirectObject) ?? .null()
        } catch {
            let failure = error as NSError
            Self.diagnostics.error("apple-event failed pid=\(processID) event=\(eventID, privacy: .public) domain=\(failure.domain, privacy: .public) code=\(failure.code)")
            if (error as NSError).code == -1743 { throw PinnedWindowLaunchError.automationDenied }
            throw error
        }
    }
    private func get(_ object: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try send("getd", parameters: ["----": object])
    }
    private func set(_ object: NSAppleEventDescriptor, to value: NSAppleEventDescriptor) throws {
        _ = try send("setd", parameters: ["----": object, "data": value])
    }
    private func make(_ kind: String, in container: NSAppleEventDescriptor? = nil,
                      target: NSAppleEventDescriptor? = nil,
                      properties: [String: NSAppleEventDescriptor] = [:]) throws -> NSAppleEventDescriptor {
        var parameters = ["kocl": NSAppleEventDescriptor(typeCode: Self.fourCC(kind))]
        if let target { parameters["to  "] = target }
        let propertiesRecord = NSAppleEventDescriptor(recordDescriptor: ())
        for (key, value) in properties { propertiesRecord.setDescriptor(value, forKeyword: Self.fourCC(key)) }
        parameters["prdt"] = propertiesRecord
        if let container {
            let insertion = NSAppleEventDescriptor(recordDescriptor: ())
            insertion.setDescriptor(container, forKeyword: keyAEObject)
            insertion.setDescriptor(NSAppleEventDescriptor(enumCode: Self.fourCC("end ")), forKeyword: keyAEPosition)
            parameters["insh"] = insertion.coerce(toDescriptorType: typeInsertionLoc)!
        }
        return try send("crel", parameters: parameters)
    }

    private func windows() throws -> [PinnedScriptWindow] {
        let references = try get(Self.all("cwin"))
        guard references.descriptorType == typeAEList else { throw PinnedWindowLaunchError.windowUnavailable }
        return try (1...max(1, references.numberOfItems)).compactMap { index in
            guard references.numberOfItems > 0, let reference = references.atIndex(index) else { return nil }
            let identifier = try PinnedAppleWindowID(get(Self.property("ID  ", of: reference)))
            guard let title = try get(Self.property("pnam", of: reference)).stringValue else {
                throw PinnedWindowLaunchError.windowUnavailable
            }
            let frame = try Self.frame(get(Self.property("pbnd", of: reference)))
            return PinnedScriptWindow(identifier: identifier, title: title, frame: frame)
        }
    }

    private func windowIdentifiers() throws -> [PinnedAppleWindowID] {
        let identifiers = try get(Self.property("ID  ", of: Self.all("cwin")))
        guard identifiers.descriptorType == typeAEList else { throw PinnedWindowLaunchError.windowUnavailable }
        return try (0..<identifiers.numberOfItems).map { index in
            guard let descriptor = identifiers.atIndex(index + 1) else { throw PinnedWindowLaunchError.windowUnavailable }
            return try PinnedAppleWindowID(descriptor)
        }
    }

    fileprivate func windowExists(_ identifier: PinnedAppleWindowID) throws -> Bool {
        do {
            _ = try get(Self.property("ID  ", of: Self.window(identifier)))
            return true
        } catch {
            // errAENoSuchObject is evidence of closure. Timeout, permission
            // and a busy app never mean "closed" and must not duplicate it.
            if (error as NSError).code == -1728 { return false }
            throw Self.userError(error, otherwise: .windowUnavailable)
        }
    }

    fileprivate func windowMetadata(_ identifier: PinnedAppleWindowID) throws -> PinnedScriptWindow {
        let reference = Self.window(identifier)
        guard let title = try get(Self.property("pnam", of: reference)).stringValue else {
            throw PinnedWindowLaunchError.windowUnavailable
        }
        return PinnedScriptWindow(identifier: identifier, title: title,
                                  frame: try Self.frame(get(Self.property("pbnd", of: reference))))
    }

    fileprivate func bringForward(_ identifier: PinnedAppleWindowID) throws {
        try set(Self.property("pidx", of: Self.window(identifier)), to: NSAppleEventDescriptor(int32: 1))
    }

    fileprivate func checkAutomationPermission() throws {
        let address = NSAppleEventDescriptor(processIdentifier: processID)
        guard AEDeterminePermissionToAutomateTarget(address.aeDesc, typeWildCard, typeWildCard,
                                                   allowsInteraction) == noErr else {
            throw PinnedWindowLaunchError.automationDenied
        }
    }

    private func focusedWindowElement() -> AXUIElement? {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.3)
        guard AXAccess.value(application, kAXFrontmostAttribute) as? Bool == true,
              let value = AXAccess.value(application, kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        guard AXAccess.value(element, kAXMainAttribute) as? Bool == true else { return nil }
        return element
    }

    // Both views of the front window must remain unchanged while its IDs
    // are read. Native index 1 also excludes a script window behind DevTools
    // or another Chrome window absent from its browser-window collection.
    fileprivate func focusedChromeWindow(_ info: PinnedApplicationInfo, matching expected: WindowItem? = nil,
                                         identifier expectedID: PinnedAppleWindowID? = nil)
        throws -> (window: WindowItem, identifier: PinnedAppleWindowID)? {
        try Task.checkCancellation()
        guard let element = focusedWindowElement(), let captureID = AXAccess.windowID(element),
              expected.map({ $0.processID == processID && $0.captureID == captureID
                  && CFEqual($0.element, element) }) ?? true else { return nil }
        if !allowsInteraction { try checkAutomationPermission() }
        let front = Self.element("cwin", at: 1)
        let identifier = try PinnedAppleWindowID(get(Self.property("ID  ", of: front)))
        guard expectedID.map({ $0 == identifier }) ?? true,
              try get(Self.property("pidx", of: Self.window(identifier))).int32Value == 1,
              let stillFocused = focusedWindowElement(), CFEqual(element, stillFocused),
              AXAccess.windowID(stillFocused) == captureID,
              try PinnedAppleWindowID(get(Self.property("ID  ", of: front))) == identifier,
              let finalFocus = focusedWindowElement(), CFEqual(element, finalFocus),
              AXAccess.windowID(finalFocus) == captureID else { return nil }
        let window = try Self.currentWindow(WindowItem(element: element, processID: processID,
            applicationName: info.name, icon: info.icon, title: "", frame: .zero,
            minimized: false, captureID: captureID, stackOrder: 0,
            applicationBundleIdentifier: info.bundleIdentifier))
        return (window, identifier)
    }

    static func matches(title leftTitle: String, frame left: CGRect, title rightTitle: String, frame right: CGRect) -> Bool {
        leftTitle == rightTitle && abs(left.minX - right.minX) <= 2 && abs(left.minY - right.minY) <= 2 &&
        abs(left.width - right.width) <= 2 && abs(left.height - right.height) <= 2
    }

    static func frame(_ descriptor: NSAppleEventDescriptor) throws -> CGRect {
        if descriptor.descriptorType == typeAEList, descriptor.numberOfItems == 4 {
            let values = (1...4).compactMap { descriptor.atIndex($0)?.doubleValue }
            guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > values[0], values[3] > values[1] else {
                throw PinnedWindowLaunchError.windowUnavailable
            }
            return CGRect(x: values[0], y: values[1], width: values[2] - values[0], height: values[3] - values[1])
        }
        // Cocoa's Standard Suite returns a QuickDraw rectangle, in the
        // descriptor's native byte order: top, left, bottom, right (Int16).
        guard descriptor.descriptorType == typeQDRectangle, descriptor.data.count == 8 else {
            throw PinnedWindowLaunchError.windowUnavailable
        }
        let edges = descriptor.data.withUnsafeBytes { bytes in
            (0..<4).map { bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self) }
        }
        guard edges[3] > edges[1], edges[2] > edges[0] else { throw PinnedWindowLaunchError.windowUnavailable }
        return CGRect(x: Int(edges[1]), y: Int(edges[0]),
                      width: Int(edges[3]) - Int(edges[1]), height: Int(edges[2]) - Int(edges[0]))
    }

    static func currentWindow(_ window: WindowItem) throws -> WindowItem {
        AXUIElementSetMessagingTimeout(window.element, 0.3)
        guard AXAccess.value(window.element, kAXRoleAttribute) as? String == kAXWindowRole,
              let frame = AXAccess.frame(window.element), frame.width > 1, frame.height > 1 else {
            throw PinnedWindowLaunchError.windowUnavailable
        }
        let currentTitle = AXAccess.value(window.element, kAXTitleAttribute) as? String
        // Safari still uses title/bounds to associate its scripting window.
        // Other apps' identities do not depend on this display attribute.
        guard window.applicationBundleIdentifier != "com.apple.Safari" || currentTitle != nil else {
            throw PinnedWindowLaunchError.windowUnavailable
        }
        let title = currentTitle ?? window.title
        let captureID = AXAccess.windowID(window.element)
        let capture = WindowCatalog.captureCandidates().first {
            $0.id == captureID && $0.processID == window.processID
        }
        return WindowItem(id: window.id, element: window.element, processID: window.processID,
                          applicationName: window.applicationName, icon: window.icon, title: title, frame: frame,
                          minimized: AXAccess.value(window.element, kAXMinimizedAttribute) as? Bool ?? false,
                          captureID: captureID, stackOrder: capture?.order ?? Int.max,
                          applicationBundleIdentifier: window.applicationBundleIdentifier)
    }

    static func capture(_ window: WindowItem, bundleID: String,
                        allowsInteraction: Bool = true,
                        chromeWindowID: PinnedAppleWindowID? = nil) throws -> PinnedLaunchTarget {
        let supported = ["com.apple.finder", "com.apple.Terminal", "com.google.Chrome", "com.apple.Safari"]
        guard supported.contains(bundleID) else { return .application }
        if !allowsInteraction {
            // Background refreshes only use an existing automation grant.
            // Permission requests belong to the user's explicit pin/open action.
            try PinnedAppleEvents(processID: window.processID, allowsInteraction: false).checkAutomationPermission()
        }
        let events = PinnedAppleEvents(processID: window.processID, allowsInteraction: allowsInteraction)
        do {
            let reference: NSAppleEventDescriptor
            let scriptTitle: String
            if bundleID == "com.google.Chrome" {
                guard let chromeWindowID else { throw PinnedWindowLaunchError.windowUnavailable }
                reference = Self.window(chromeWindowID)
                scriptTitle = window.title
            } else if bundleID == "com.apple.finder" || bundleID == "com.apple.Terminal" {
                // These native apps expose the system window number as their
                // Apple Events ID. Titles and bounds are display metadata.
                guard let captureID = window.captureID else { throw PinnedWindowLaunchError.windowUnavailable }
                reference = Self.window(.number(Int32(bitPattern: captureID)))
                scriptTitle = window.title
            } else {
                let snapshots = try events.windows()
                let matches = snapshots.filter { Self.matches(title: window.title, frame: window.frame,
                    title: $0.title, frame: $0.frame) }
                guard matches.count == 1 else { throw PinnedWindowLaunchError.windowUnavailable }
                reference = Self.window(matches[0].identifier)
                scriptTitle = matches[0].title
            }
            let target: PinnedLaunchTarget
            switch bundleID {
            case "com.apple.finder":
                let folder = Self.property("fvtg", of: reference)
                guard let raw = try events.get(Self.property("pURL", of: folder)).stringValue else {
                    throw PinnedWindowLaunchError.folderUnavailable
                }
                target = try finderTarget(rawURL: raw, title: scriptTitle)
            case "com.apple.Terminal":
                let selected = Self.property("tcnt", of: reference)
                guard let tty = try events.get(Self.property("ttty", of: selected)).stringValue,
                      let path = try terminalDirectory(tty: tty) else {
                    throw PinnedWindowLaunchError.terminalDirectoryUnavailable
                }
                target = .terminal(path: path)
            default:
                let chrome = bundleID == "com.google.Chrome"
                let tabs = Self.all(chrome ? "CrTb" : "bTab", of: reference)
                let urls = try stringList(events.get(Self.property(chrome ? "URL " : "pURL", of: tabs)))
                let selectedProperty = chrome ? Self.property("acTI", of: reference)
                    : Self.property("pidx", of: Self.property("cTab", of: reference))
                let selected = Int(try events.get(selectedProperty).int32Value) - 1
                guard urls == (try stringList(events.get(Self.property(chrome ? "URL " : "pURL", of: tabs)))) else {
                    throw PinnedWindowLaunchError.tabsUnavailable
                }
                target = .browser(urls: urls, selectedTabIndex: selected)
            }
            try validate(target)
            return target
        } catch {
            if error is CancellationError { throw error }
            throw userError(error, otherwise: bundleID == "com.apple.Terminal" ? .terminalDirectoryUnavailable
                            : (bundleID == "com.apple.finder" ? .folderUnavailable : .tabsUnavailable))
        }
    }

    private static func finderTarget(rawURL: String, title: String) throws -> PinnedLaunchTarget {
        // Finder's sidebar Recents view reports an empty target URL. Its
        // system search bundle supplies both the reopen path and names in
        // every Finder language. A real folder, even with that name, keeps
        // its own nonempty URL.
        if rawURL.isEmpty, finderRecentsNames.contains(title) {
            return .finder(path: finderRecentsURL.path)
        }
        guard let url = URL(string: rawURL), url.isFileURL else {
            throw PinnedWindowLaunchError.folderUnavailable
        }
        return .finder(path: url.path)
    }

    private static func stringList(_ descriptor: NSAppleEventDescriptor) throws -> [String] {
        guard descriptor.descriptorType == typeAEList, descriptor.numberOfItems > 0 else { throw PinnedWindowLaunchError.tabsUnavailable }
        return try (1...descriptor.numberOfItems).map {
            guard let value = descriptor.atIndex($0)?.stringValue else { throw PinnedWindowLaunchError.tabsUnavailable }
            return value
        }
    }

    static func validate(_ target: PinnedLaunchTarget) throws {
        switch target {
        case .application: break
        case .finder(let path), .terminal(let path):
            guard validDirectoryPath(path) else { throw PinnedWindowLaunchError.folderUnavailable }
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw PinnedWindowLaunchError.folderUnavailable
            }
        case .browser(let urls, let selected):
            guard !urls.isEmpty, urls.indices.contains(selected), urls.allSatisfy({
                guard !$0.isEmpty, let url = URL(string: $0), let scheme = url.scheme?.lowercased() else { return false }
                return !["javascript", "vbscript"].contains(scheme) && !$0.contains("\0")
            }) else { throw PinnedWindowLaunchError.tabsUnavailable }
        }
    }

    static func validDirectoryPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    static func terminalCommand(path: String) throws -> String {
        guard validDirectoryPath(path) else { throw PinnedWindowLaunchError.folderUnavailable }
        // Backslash each special character, including !. Unlike POSIX
        // quotes alone, this also prevents csh/tcsh history expansion.
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_-.")
        let argument = path.unicodeScalars.map { safe.contains($0) ? String($0) : "\\" + String($0) }.joined()
        return "cd " + argument
    }

    fileprivate func create(_ target: PinnedLaunchTarget, bundleID: String) -> PinnedCreationOutcome {
        var outcome = PinnedCreationOutcome()
        do {
            outcome.originalWindowIdentifiers = try windowIdentifiers()
            switch target {
            case .application: break
            case .finder(let path):
                outcome.creationAttempted = true
                // Finder's make command navigates to folders and saved searches through
                // its destination parameter, not the initial target property.
                let reference = try make("brow", target: NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: path, isDirectory: true)))
                outcome.referenceData = try Self.flattenReference(reference)
                outcome.identifier = Self.windowIdentifier(in: reference)
                if outcome.identifier == nil {
                    outcome.identifier = try PinnedAppleWindowID(get(Self.property("ID  ", of: reference)))
                }
            case .terminal(let path):
                // Omitting a destination makes Terminal create a new window.
                outcome.creationAttempted = true
                let tab = try send("dosc", parameters: ["----": NSAppleEventDescriptor(string: Self.terminalCommand(path: path))])
                outcome.referenceData = try Self.flattenReference(tab)
                outcome.identifier = Self.windowIdentifier(in: tab)
            case .browser:
                let chrome = bundleID == "com.google.Chrome"
                guard chrome || bundleID == "com.apple.Safari" else { throw PinnedWindowLaunchError.openFailed }
                outcome.creationAttempted = true
                outcome.needsBrowserRestore = true
                let reference = try make(chrome ? "cwin" : "docu")
                outcome.referenceData = try Self.flattenReference(reference)
                outcome.identifier = Self.windowIdentifier(in: reference)
                if chrome, outcome.identifier == nil {
                    outcome.identifier = try PinnedAppleWindowID(get(Self.property("ID  ", of: reference)))
                }
            }
            if outcome.identifier == nil {
                let before = Set(outcome.originalWindowIdentifiers)
                let added = try windowIdentifiers().filter { !before.contains($0) }
                if added.count == 1 { outcome.identifier = added[0] }
            }
            if let identifier = outcome.identifier {
                if outcome.needsBrowserRestore {
                    // Flip before the first URL write. A partial restoration
                    // should be shown, not duplicated on the next click.
                    outcome.needsBrowserRestore = false
                    try restoreBrowser(target, window: identifier, bundleID: bundleID)
                }
                try? bringForward(identifier)
            }
        } catch {
            if outcome.identifier != nil { outcome.error = .incompleteRestore }
            else if outcome.referenceData != nil {
                // The app returned the new object's reference. ID/metadata
                // failure is retryable and must not discard that reference.
                if Self.userError(error, otherwise: .windowUnavailable) == .automationDenied {
                    outcome.error = .automationDenied
                }
            } else {
                outcome.error = Self.userError(error, otherwise: .openFailed)
                if outcome.error == .automationDenied { outcome.creationAttempted = false }
            }
        }
        return outcome
    }

    fileprivate func retryCreated(_ previous: PinnedCreationOutcome, target: PinnedLaunchTarget,
                                  bundleID: String) -> PinnedCreationOutcome {
        var outcome = previous
        // Permission or a busy app can recover on the next user action.
        if outcome.error != .incompleteRestore { outcome.error = nil }
        do {
            if outcome.identifier == nil, let data = outcome.referenceData {
                outcome.identifier = try recoverIdentifier(referenceData: data,
                                                          excluding: outcome.originalWindowIdentifiers,
                                                          bundleID: bundleID)
            }
            guard let identifier = outcome.identifier else { return outcome }
            guard try windowExists(identifier) else { outcome.windowKnownClosed = true; return outcome }
            try? bringForward(identifier)
            if outcome.needsBrowserRestore {
                outcome.needsBrowserRestore = false
                do { try restoreBrowser(target, window: identifier, bundleID: bundleID) }
                catch { outcome.error = .incompleteRestore }
            }
        } catch {
            outcome.error = Self.userError(error, otherwise: .windowUnavailable)
        }
        return outcome
    }

    private func restoreBrowser(_ target: PinnedLaunchTarget, window identifier: PinnedAppleWindowID,
                                bundleID: String) throws {
        guard case .browser(let urls, let selected) = target else { return }
        let chrome = bundleID == "com.google.Chrome"
        let reference = Self.window(identifier)
        let tabKind = chrome ? "CrTb" : "bTab"
        let urlCode = chrome ? "URL " : "pURL"
        try set(Self.property(urlCode, of: Self.element(tabKind, at: 1, of: reference)),
                to: NSAppleEventDescriptor(string: urls[0]))
        for url in urls.dropFirst() {
            _ = try make(tabKind, in: reference, properties: [urlCode: NSAppleEventDescriptor(string: url)])
        }
        if chrome {
            try set(Self.property("acTI", of: reference), to: NSAppleEventDescriptor(int32: Int32(selected + 1)))
        } else {
            try set(Self.property("cTab", of: reference), to: Self.element(tabKind, at: selected + 1, of: reference))
        }
    }

    private func recoverIdentifier(referenceData: Data, excluding original: [PinnedAppleWindowID],
                                   bundleID: String) throws -> PinnedAppleWindowID? {
        let reference = try Self.unflattenReference(referenceData)
        if let identifier = Self.windowIdentifier(in: reference) { return identifier }
        // Safari returns a document rather than a window. Compare that exact
        // returned object to the documents of new windows; names, positions
        // and the current front window are never substitutes for identity.
        let original = Set(original)
        let candidates = try windowIdentifiers().filter { !original.contains($0) }
        var matches: [PinnedAppleWindowID] = []
        for identifier in candidates {
            let window = Self.window(identifier)
            let object = bundleID == "com.apple.Safari" ? Self.property("docu", of: window)
                : (bundleID == "com.apple.Terminal" ? Self.property("tcnt", of: window) : window)
            let current = try get(object)
            if try Self.flattenReference(current) == referenceData { matches.append(identifier) }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    // The descriptor is flattened across tasks so no Foundation descriptor
    // instance is shared between background operations.
    static func flattenReference(_ descriptor: NSAppleEventDescriptor) throws -> Data {
        let size = AESizeOfFlattenedDesc(descriptor.aeDesc)
        guard size > 0 else { throw PinnedWindowLaunchError.windowUnavailable }
        var data = Data(count: size)
        var actual = 0
        let status = data.withUnsafeMutableBytes {
            AEFlattenDesc(descriptor.aeDesc, $0.baseAddress, size, &actual)
        }
        guard status == noErr else { throw PinnedWindowLaunchError.windowUnavailable }
        data.count = actual
        return data
    }

    static func unflattenReference(_ data: Data) throws -> NSAppleEventDescriptor {
        guard !data.isEmpty else { throw PinnedWindowLaunchError.windowUnavailable }
        var descriptor = AEDesc(descriptorType: typeNull, dataHandle: nil)
        let status = data.withUnsafeBytes { AEUnflattenDescFromBytes($0.baseAddress!, $0.count, &descriptor) }
        guard status == noErr else { throw PinnedWindowLaunchError.windowUnavailable }
        return NSAppleEventDescriptor(aeDescNoCopy: &descriptor)
    }

    static func windowIdentifier(in reference: NSAppleEventDescriptor) -> PinnedAppleWindowID? {
        guard reference.descriptorType == typeObjectSpecifier else { return nil }
        let desiredClass = reference.forKeyword(UInt32(keyAEDesiredClass))?.typeCodeValue
        if [fourCC("cwin"), fourCC("brow")].contains(desiredClass),
           reference.forKeyword(UInt32(keyAEKeyForm))?.enumCodeValue == fourCC("ID  "),
           let value = reference.forKeyword(UInt32(keyAEKeyData)) {
            return try? PinnedAppleWindowID(value)
        }
        guard let container = reference.forKeyword(UInt32(keyAEContainer)) else { return nil }
        return windowIdentifier(in: container)
    }

    private static func userError(_ error: Error, otherwise fallback: PinnedWindowLaunchError) -> PinnedWindowLaunchError {
        (error as? PinnedWindowLaunchError) ?? ((error as NSError).code == -1743 ? .automationDenied : fallback)
    }

    fileprivate static func accessibilityWindows(_ apps: [PinnedApplicationInfo]) -> [WindowItem] {
        guard AXIsProcessTrusted() else { return [] }
        let candidates = WindowCatalog.captureCandidates()
        return apps.flatMap { app -> [WindowItem] in
            let application = AXUIElementCreateApplication(app.processID)
            AXUIElementSetMessagingTimeout(application, 0.3)
            guard let windows = AXAccess.value(application, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
            return windows.compactMap { element -> WindowItem? in
                AXUIElementSetMessagingTimeout(element, 0.3)
                guard AXAccess.value(element, kAXRoleAttribute) as? String == kAXWindowRole,
                      let frame = AXAccess.frame(element), frame.width > 1, frame.height > 1 else { return nil }
                let currentTitle = AXAccess.value(element, kAXTitleAttribute) as? String
                guard app.bundleIdentifier != "com.apple.Safari" || currentTitle != nil else { return nil }
                let title = currentTitle ?? app.name
                let captureID = AXAccess.windowID(element)
                let capture = candidates.first { $0.id == captureID && $0.processID == app.processID }
                return WindowItem(element: element, processID: app.processID, applicationName: app.name,
                                  icon: app.icon, title: title, frame: frame,
                                  minimized: AXAccess.value(element, kAXMinimizedAttribute) as? Bool ?? false,
                                  captureID: captureID, stackOrder: capture?.order ?? Int.max,
                                  applicationBundleIdentifier: app.bundleIdentifier)
            }
        }
    }

    // A nested interactive shell owns the foreground process group. If a
    // foreground command (including SSH) owns it instead, walk back to its
    // nearest local shell. Background jobs never select the saved directory.
    static func terminalShellPID(processes: [PinnedTerminalProcess], deviceID: UInt32) -> pid_t? {
        let info = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let session = processes.filter { $0.deviceID == deviceID }
        let groups = Set(session.map(\.foregroundGroupID).filter { $0 > 0 && $0 != UInt32.max })
        guard groups.count == 1, let foreground = groups.first else { return nil }
        let foregroundProcesses = session.filter { $0.processGroupID == foreground }
        guard !foregroundProcesses.isEmpty else { return nil }
        var shells: Set<pid_t> = []
        for foregroundProcess in foregroundProcesses {
            var current: PinnedTerminalProcess? = foregroundProcess
            var visited: Set<pid_t> = []
            var nearestShell: pid_t?
            while let process = current, process.deviceID == deviceID, visited.insert(process.pid).inserted {
                if process.isShell { nearestShell = process.pid; break }
                current = info[process.parentPID]
            }
            // The selected Terminal tab already supplied this exact device.
            // Walking past its shell into a protected login process adds no
            // identity information and can fail even when cwd is readable.
            guard let nearestShell else { return nil }
            shells.insert(nearestShell)
        }
        return shells.count == 1 ? shells.first : nil
    }

    // The selected tab's tty identifies its local session. Read the actual
    // local shell's cwd from libproc, not a title, prompt, scrollback or OSC
    // hint. An SSH process does not change the local shell's directory.
    private static func terminalDirectory(tty: String) throws -> String? {
        guard tty.hasPrefix("/dev/tty"), !tty.contains("\0") else { return nil }
        var device = stat()
        guard tty.withCString({ lstat($0, &device) }) == 0 else { return nil }
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(needed) + 32)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return nil }
        let allowedShells = Set((try String(contentsOfFile: "/etc/shells", encoding: .utf8)).split(separator: "\n")
            .map(String.init).filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        var info: [pid_t: proc_bsdinfo] = [:]
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var entry = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &entry, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size {
                info[pid] = entry
            }
        }
        let processes = info.map { pid, entry in
            var executable = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let hasExecutable = proc_pidpath(pid, &executable, UInt32(executable.count)) > 0
            return PinnedTerminalProcess(pid: pid, parentPID: pid_t(entry.pbi_ppid),
                                         processGroupID: entry.pbi_pgid, foregroundGroupID: entry.e_tpgid,
                                         deviceID: entry.e_tdev,
                                         isShell: hasExecutable && allowedShells.contains(String(cString: executable)))
        }
        guard let shellPID = terminalShellPID(processes: processes, deviceID: UInt32(bitPattern: device.st_rdev)) else {
            diagnostics.warning("terminal-directory unavailable stage=shell-selection device=\(device.st_rdev)")
            return nil
        }
        var paths = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        guard proc_pidinfo(shellPID, PROC_PIDVNODEPATHINFO, 0, &paths, Int32(size)) == size else {
            diagnostics.warning("terminal-directory unavailable stage=cwd pid=\(shellPID) errno=\(errno)")
            return nil
        }
        let path = withUnsafePointer(to: &paths.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return validDirectoryPath(path) ? path : nil
    }
}
