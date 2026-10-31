import AppKit
import ApplicationServices
#if DEBUG
import OSLog
#endif

nonisolated struct LayoutDisplay: Identifiable, Equatable, Sendable {
    let id: UInt32
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
    let scale: Double
    let primaryTop: Double

    var layoutArea: CGRect {
        CGRect(x: visibleFrame.minX, y: primaryTop - visibleFrame.maxY,
               width: visibleFrame.width, height: visibleFrame.height)
    }

    /// SwiftUI's top-left origin within the full-screen overlay. The grid and
    /// the AX destinations cover exactly the same usable screen rectangle.
    var overlayLayoutFrame: CGRect {
        CGRect(x: visibleFrame.minX - frame.minX, y: frame.maxY - visibleFrame.maxY,
               width: visibleFrame.width, height: visibleFrame.height)
    }

    @MainActor static func current() -> [LayoutDisplay] {
        guard let primary = NSScreen.screens.first else { return [] }
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return LayoutDisplay(id: number.uint32Value, name: screen.localizedName, frame: screen.frame,
                                 visibleFrame: screen.visibleFrame, scale: screen.backingScaleFactor,
                                 primaryTop: primary.frame.maxY)
        }.sorted { $0.id < $1.id }
    }
}

nonisolated struct LayoutWindowChoice: Identifiable, @unchecked Sendable {
    let window: WindowItem
    let processLaunchDate: Date?
    var minimumSize: CGSize? = nil
    var id: UUID { window.id }
}

nonisolated struct LayoutWindowOutcome: Identifiable, Sendable {
    enum Status: String, Sendable {
        case placed, restored, constrained, unavailable, notAttempted, displayChanged, permissionDenied
        var isSuccess: Bool { self == .placed || self == .restored }
    }
    let choice: LayoutWindowChoice
    let requested: CGRect
    let actual: CGRect?
    let status: Status
    var id: UUID { choice.id }
}

nonisolated struct LayoutWindowRestore: Identifiable, Sendable {
    let choice: LayoutWindowChoice
    let frame: CGRect
    var id: UUID { choice.id }
}

nonisolated struct LayoutBatchResult: Sendable {
    let outcomes: [LayoutWindowOutcome]
    /// Includes failed attempts: a failed AX response may still have changed geometry.
    let originals: [LayoutWindowRestore]
}

@MainActor
final class MultiWindowLayoutService {
    private let catalog = WindowCatalog()
    #if DEBUG
    private static let diagnostics = Logger(subsystem: "com.mixbayes.tidest", category: "QuickLayout")
    #endif

    func choices() async -> [LayoutWindowChoice] {
        guard AXIsProcessTrusted() else { return [] }
        let windows = await catalog.load()
        guard !Task.isCancelled else { return [] }
        let dates = Dictionary(uniqueKeysWithValues: Set(windows.map(\.processID)).compactMap { process -> (pid_t, Date?)? in
            guard let app = NSRunningApplication(processIdentifier: process) else { return nil }
            return (process, WindowCatalog.processLaunchDate(app))
        })
        let task = Task.detached(priority: .userInitiated) {
            let onScreen = Self.onScreenWindows()
            return windows.compactMap { window -> LayoutWindowChoice? in
                guard !Task.isCancelled, let number = window.captureID,
                      onScreen[number] == window.processID, Self.isOperable(window) else { return nil }
                return LayoutWindowChoice(window: window, processLaunchDate: dates[window.processID] ?? nil,
                                          minimumSize: Self.minimumSize(window.element))
            }
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func stop() { catalog.stop() }

    func reveal(_ outcomes: [LayoutWindowOutcome], topology: [LayoutDisplay]) async {
        let choices = outcomes.filter { $0.status.isSuccess }.map(\.choice)
        var activated: Set<pid_t> = []
        // Activate each app once and let its activation finish. Interleaving
        // app activation with window raising can cover earlier layout windows.
        for choice in choices {
            guard !Task.isCancelled, AXIsProcessTrusted(), LayoutDisplay.current() == topology else { return }
            guard isAvailableForReveal(choice), activated.insert(choice.window.processID).inserted,
                  let app = NSRunningApplication(processIdentifier: choice.window.processID) else { continue }
            if Self.isSettable(choice.window.element, kAXMainAttribute) == true {
                _ = AXUIElementSetAttributeValue(choice.window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
            let application = AXUIElementCreateApplication(choice.window.processID)
            AXUIElementSetMessagingTimeout(application, 0.15)
            // Accessibility activates the selected running process directly;
            // opening its bundle would also send an unwanted reopen event.
            let activation = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            if activation == .success {
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(1))
                while !app.isActive, !app.isTerminated, clock.now < deadline {
                    do { try await Task.sleep(for: .milliseconds(20)) }
                    catch { return }
                }
            }
            #if DEBUG
            if activation != .success || !app.isActive {
                Self.diagnostics.warning("Layout activation pid=\(choice.window.processID) ax=\(activation.rawValue) active=\(app.isActive)")
            }
            #endif
        }
        // No more application switches after this point. Raise every selected
        // window, including multiple windows belonging to the same application.
        for choice in choices {
            guard !Task.isCancelled, AXIsProcessTrusted(), LayoutDisplay.current() == topology else { return }
            guard isAvailableForReveal(choice) else { continue }
            let raised = AXUIElementPerformAction(choice.window.element, kAXRaiseAction as CFString)
            if raised != .success {
                #if DEBUG
                Self.diagnostics.warning("Layout raise pid=\(choice.window.processID) ax=\(raised.rawValue)")
                #endif
            }
        }
    }

    private func isAvailableForReveal(_ choice: LayoutWindowChoice) -> Bool {
        guard identityMatches(choice), let number = choice.window.captureID,
              Self.onScreenWindows()[number] == choice.window.processID,
              Self.isOperable(choice.window), AXAccess.windowID(choice.window.element) == number else { return false }
        return true
    }

    /// Preflight the entire batch before the first write; revalidate topology and identity for each subsequent write.
    func apply(_ requests: [(LayoutWindowChoice, CGRect)], topology: [LayoutDisplay], restoring: Bool = false) async -> LayoutBatchResult {
        guard !requests.isEmpty else { return LayoutBatchResult(outcomes: [], originals: []) }
        let initialStatus: LayoutWindowOutcome.Status?
        if LayoutDisplay.current() != topology { initialStatus = .displayChanged }
        else if !AXIsProcessTrusted() { initialStatus = .permissionDenied }
        else { initialStatus = nil }
        if let initialStatus {
            return LayoutBatchResult(outcomes: requests.map { LayoutWindowOutcome(choice: $0.0, requested: $0.1, actual: nil, status: initialStatus) }, originals: [])
        }
        var preflight: [UUID: CGRect] = [:]
        var failures: [UUID: LayoutWindowOutcome.Status] = [:]
        for (choice, requested) in requests {
            guard !Task.isCancelled else { failures[choice.id] = .notAttempted; continue }
            if !identityMatches(choice) { failures[choice.id] = .unavailable; continue }
            let task = Task.detached(priority: .userInitiated) { Self.inspect(choice, requested: requested) }
            let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            if let frame = result.frame { preflight[choice.id] = frame }
            if let status = result.failure { failures[choice.id] = status }
        }
        var outcomes: [LayoutWindowOutcome] = []
        var originals: [LayoutWindowRestore] = []
        for (choice, requested) in requests {
            let status: LayoutWindowOutcome.Status
            var actual = preflight[choice.id]
            if let failure = failures[choice.id] { status = failure }
            else if Task.isCancelled { status = .notAttempted }
            else if LayoutDisplay.current() != topology { status = .displayChanged }
            else if !AXIsProcessTrusted() { status = .permissionDenied }
            else if !identityMatches(choice) { status = .unavailable }
            else {
                let task = Task.detached(priority: .userInitiated) { () -> (LayoutWindowOutcome.Status, CGRect?, CGRect?) in
                    // Check membership in the current desktop again after every suspension.
                    let inspection = Self.inspect(choice, requested: requested)
                    if let failure = inspection.failure { return (failure, inspection.frame, nil) }
                    guard let original = inspection.frame else { return (.unavailable, nil, nil) }
                    let result = await Self.performPlacement(in: requested,
                        readFrame: { AXAccess.frame(choice.window.element) },
                        isSettable: { Self.isSettable(choice.window.element, $0) },
                        setSize: {
                            guard !Task.isCancelled, AXIsProcessTrusted(), Self.physicalTopologyMatches(topology) else { return .cannotComplete }
                            return Self.setSize($0, of: choice.window.element)
                        },
                        setPosition: {
                            guard !Task.isCancelled, AXIsProcessTrusted(), Self.physicalTopologyMatches(topology) else { return .cannotComplete }
                            return Self.setPosition($0, of: choice.window.element)
                        },
                        pause: {
                            do { try await Task.sleep(for: .milliseconds(50)); return !Task.isCancelled }
                            catch { return false }
                        })
                    let actual = AXAccess.frame(choice.window.element)
                    let status: LayoutWindowOutcome.Status
                    if !Self.physicalTopologyMatches(topology) { status = .displayChanged }
                    else if !AXIsProcessTrusted() { status = .permissionDenied }
                    else {
                        switch result {
                        case .exact, .constrained: status = restoring ? .restored : .placed
                        case .unavailable: status = .unavailable
                        }
                    }
                    return (status, actual, original)
                }
                let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
                status = result.0
                actual = result.1
                if result.2 != nil, let original = preflight[choice.id],
                   result.1 == nil || !Self.sameFrame(result.1!, original) {
                    originals.append(LayoutWindowRestore(choice: choice, frame: original))
                }
            }
            #if DEBUG
            Self.diagnostics.notice("placement status=\(status.rawValue, privacy: .public) restoring=\(restoring) original=\(String(describing: preflight[choice.id]), privacy: .public) requested=\(String(describing: requested), privacy: .public) actual=\(String(describing: actual), privacy: .public)")
            #endif
            outcomes.append(LayoutWindowOutcome(choice: choice, requested: requested, actual: actual, status: status))
        }
        return LayoutBatchResult(outcomes: outcomes, originals: originals)
    }

    // Skip windows that cannot resize. Resizable windows keep the closest
    // placement their application allows, even when it has size limits.
    nonisolated static func performPlacement(in requested: CGRect,
        readFrame: () -> CGRect?, isSettable: (String) -> Bool?,
        setSize: (CGSize) -> AXError, setPosition: (CGPoint) -> AXError,
        pause: () async -> Bool) async -> WindowLayoutResult {
        guard let resizable = isSettable(kAXSizeAttribute) else { return .unavailable }
        guard resizable else { return .unavailable }
        return await WindowLayoutService.performLayout(.full, in: requested, readFrame: readFrame,
            isSettable: isSettable, setSize: setSize, setPosition: setPosition, pause: pause)
    }

    private func identityMatches(_ choice: LayoutWindowChoice) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: choice.window.processID), !application.isTerminated,
              application.bundleIdentifier == choice.window.applicationBundleIdentifier else { return false }
        if let expected = choice.processLaunchDate {
            guard WindowCatalog.processLaunchDate(application) == expected else { return false }
        }
        return true
    }

    private nonisolated static func inspect(_ choice: LayoutWindowChoice, requested: CGRect) -> (frame: CGRect?, failure: LayoutWindowOutcome.Status?) {
        guard !Task.isCancelled, requested.minX.isFinite, requested.minY.isFinite,
              requested.width.isFinite, requested.height.isFinite, requested.width > 1, requested.height > 1,
              let number = choice.window.captureID, onScreenWindows()[number] == choice.window.processID,
              isOperable(choice.window), AXAccess.windowID(choice.window.element) == number,
              let frame = AXAccess.frame(choice.window.element) else { return (nil, .unavailable) }
        return (frame, nil)
    }

    private nonisolated static func minimumSize(_ element: AXUIElement) -> CGSize? {
        guard let value = AXAccess.value(element, "AXMinSize"), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size), size.width.isFinite, size.height.isFinite,
              size.width >= 0, size.height >= 0 else { return nil }
        return size
    }

    /// Available off the main actor, immediately before every AX write.
    private nonisolated static func physicalTopologyMatches(_ expected: [LayoutDisplay]) -> Bool {
        for display in expected {
            guard CGDisplayIsActive(display.id) != 0,
                  CGDisplayBounds(display.id) == CGRect(x: display.frame.minX, y: display.primaryTop - display.frame.maxY,
                                                        width: display.frame.width, height: display.frame.height) else { return false }
        }
        return true
    }

    private nonisolated static func sameFrame(_ left: CGRect, _ right: CGRect) -> Bool {
        abs(left.minX - right.minX) <= 2 && abs(left.minY - right.minY) <= 2 &&
        abs(left.width - right.width) <= 2 && abs(left.height - right.height) <= 2
    }

    private nonisolated static func isOperable(_ window: WindowItem) -> Bool {
        AXUIElementSetMessagingTimeout(window.element, 0.15)
        var process: pid_t = 0
        guard AXUIElementGetPid(window.element, &process) == .success, process == window.processID,
              AXAccess.value(window.element, kAXRoleAttribute) as? String == kAXWindowRole,
              AXAccess.value(window.element, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
              AXAccess.value(window.element, kAXMinimizedAttribute) as? Bool != true,
              AXAccess.value(window.element, "AXFullScreen") as? Bool != true,
              isSettable(window.element, kAXPositionAttribute) == true,
              isSettable(window.element, kAXSizeAttribute) == true else { return false }
        return true
    }

    private nonisolated static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return error == .success ? settable.boolValue : nil
    }

    private nonisolated static func onScreenWindows() -> [CGWindowID: pid_t] {
        let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var result: [CGWindowID: pid_t] = [:]
        for info in entries {
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            result[id] = pid
        }
        return result
    }

    private nonisolated static func setSize(_ size: CGSize, of element: AXUIElement) -> AXError {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    private nonisolated static func setPosition(_ point: CGPoint, of element: AXUIElement) -> AXError {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }
}
