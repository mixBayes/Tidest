import AppKit
import ApplicationServices
import Carbon
import Combine
import OSLog

@MainActor
final class PinnedWindowsController {
    private struct PickedWindow {
        let id = UUID()
        let selectionID: UUID
        var point: CGPoint
        let target: WindowItem
        var thumbnail: NSImage?
        var isPlacing = false
    }

    private struct ItemDrag {
        let id: UUID
        let origin: CGPoint
        var point: CGPoint
        var moved = false
    }

    private struct ShelfDrag {
        let origin: CGPoint
        let side: PinnedDockSide
        var switched = false
    }

    private(set) var isEnabled = false
    private(set) var isShortcutHeld = false
    private(set) var isCaptureModeActive = false
    private let settings: AppSettings
    private let previewStore: PinnedWindowPreviewStore?
    private let catalog: WindowCatalog
    private let launchService = PinnedWindowLaunchService()
    private let layoutService = WindowLayoutService()
    private let windowHighlight = PinnedWindowHighlight()
    private let captureTip = PinnedCaptureTip()
    private var windows: [PinnedWindowEntry] = []
    private var thumbnails: [UUID: NSImage] = [:]
    private var panel: PinnedWindowsPanel?
    private var shelf: PinnedWindowsView?
    private var dragPanel: PinnedWindowsPanel?
    private var dragPreview: PinnedWindowDragPreviewView?
    private var dockDisplayID: CGDirectDisplayID?
    private var presentedDisplayID: CGDirectDisplayID?
    private var isExpanded = false
    private var captureEnabled = false
    private var captureEpoch = UUID()
    private var selectionSession: UUID?
    private var selectionTarget: LayoutTarget?
    private var selectionRegions: [CGRect] = []
    private var selectionThumbnail: NSImage?
    private var lookupPoint: CGPoint?
    private var lookupToken = UUID()
    private var selectionCaptureToken = UUID()
    private var pickedWindow: PickedWindow?
    private var previousCaptureApplication: NSRunningApplication?
    private var previousCaptureCursor: NSCursor?
    private var previewAnimationID = UUID()
    private var isPreviewAnimating = false
    private var pickupAnimation: (frame: CGRect, point: CGPoint, startedAt: TimeInterval)?
    private var pickupAnimationTask: Task<Void, Never>?
    private var consumesDropMouseUp = false
    private var tipDisplayID: CGDirectDisplayID?
    private var tipCarryingWindow: Bool?
    private var itemDrag: ItemDrag?
    private var shelfDrag: ShelfDrag?
    private var insertionIndex: Int?
    private var removingItem = false
    private var highlightedID: UUID?
    private var message: String?
    private var hoverBlockedUntilPointerLeaves = false
    private var pointerUpdateTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var autoScrollTimer: Timer?
    private var pointerMonitoringActive: Bool?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var windowObservers: [pid_t: AXObserver] = [:]
    private var observedWindows: [UUID: WindowItem] = [:]
    private var languageObserver: AnyCancellable?
    private var identifyTask: Task<Void, Never>?
    private var dragCaptureTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var previewRestoreTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var metadataToken = UUID()
    private var presenceTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var highlightTask: Task<Void, Never>?
    private var entryTasks: [UUID: Task<Void, Never>] = [:]
    private var entryTokens: [UUID: UUID] = [:]
    private var capturingIDs: Set<UUID> = []
    private var confirmedClosedIDs: Set<UUID> = []
    private var restoringIDs: Set<UUID> = []
    private var restorationToken = UUID()
    private var restorationTask: Task<Void, Never>?
    private var previewMode = false
    private static let diagnostics = Logger(subsystem: "com.mixbayes.tidest", category: "WindowDock")
    #if DEBUG
    private var diagnosticPointerUpdates = 0
    private var diagnosticLastPointerLogAt: TimeInterval = 0
    private var diagnosticLastHoverReason = ""
    private var diagnosticLastHoverLogAt: TimeInterval = 0
    #endif

    init(settings: AppSettings? = nil, catalog: WindowCatalog? = nil,
         previewStore: PinnedWindowPreviewStore? = nil) {
        self.settings = settings ?? .shared
        self.previewStore = self.settings.persistChanges ? previewStore ?? PinnedWindowPreviewStore() : nil
        self.catalog = catalog ?? WindowCatalog()
        do {
            windows = try self.settings.loadSavedPinnedWindows().map(PinnedWindowEntry.init(saved:))
            self.previewStore?.removeExcept(Set(windows.map(\.id)))
        } catch {
            // Keep the unreadable saved data intact. Show the short notice
            // when the user next opens the toolbar, without blocking it.
            message = "暂时无法读取停靠项目，请再试一次"
        }
        windowHighlight.onMouseDown = { [weak self] point in self?.pickUpWindow(at: point) ?? false }
        windowHighlight.onMouseDragged = { [weak self] point in self?.movePickedWindow(to: point) }
        // The first click's up only releases the highlight receiver. Putting
        // the window down requires a later click on our shelf.
        windowHighlight.onMouseUp = { [weak self] point in self?.movePickedWindow(to: point) }
        languageObserver = self.settings.$language.dropFirst().sink { [weak self] _ in
            // @Published emits before the new value is assigned.
            Task { @MainActor [weak self] in
                guard let self else { return }
                render()
                if isCaptureModeActive, let screen = screen(at: NSEvent.mouseLocation) {
                    captureTip.show(on: screen, settings: self.settings, carryingWindow: pickedWindow != nil)
                }
            }
        }
    }

    @discardableResult
    func start(captureEnabled: Bool) -> Bool {
        logDiagnostic("start requested enabled=\(isEnabled) capture=\(captureEnabled) side=\(settings.pinnedDockSide.rawValue)")
        updateCapturePermission(captureEnabled)
        if isEnabled { return true }
        isEnabled = true
        restoreSavedPreviews()
        hoverBlockedUntilPointerLeaves = false
        if dockScreen == nil { dockDisplayID = screen(at: NSEvent.mouseLocation).map(displayID) }
        installPointerMonitoring()
        installWindowMonitoring()
        logDiagnostic("start edge-notifications-only dockDisplay=\(dockDisplayID ?? 0) screens=\(NSScreen.screens.map { "\(displayID($0)):\($0.frame)" })")
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        restoreOriginalWindows()
        checkClosedWindows()
        return true
    }

    func stop() {
        logDiagnostic("stop requested")
        persistWindows()
        for entry in windows { savePreview(for: entry.id) }
        isEnabled = false
        highlightedID = nil
        message = nil
        cancelInteraction()
        isShortcutHeld = false
        cancelPendingPointerUpdate()
        cancelScheduledCollapse()
        stopAutoScroll()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        pointerMonitoringActive = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        clearWindowObservers()
        refreshTask?.cancel()
        refreshTask = nil
        previewRestoreTask?.cancel()
        previewRestoreTask = nil
        metadataToken = UUID()
        metadataTask?.cancel()
        metadataTask = nil
        presenceTask?.cancel()
        presenceTask = nil
        messageTask?.cancel()
        messageTask = nil
        highlightTask?.cancel()
        highlightTask = nil
        restorationToken = UUID()
        restorationTask?.cancel()
        restorationTask = nil
        restoringIDs.removeAll()
        for id in Array(entryTasks.keys) { cancelEntryTask(id) }
        captureEpoch = UUID()
        panel?.orderOut(nil)
        dragPanel?.orderOut(nil)
        // All entries and their previews are saved when they change.
        // Pausing the toolbar must not erase them.
    }

    func pressShortcut() {
        logDiagnostic("shortcut pressed enabled=\(isEnabled) held=\(isShortcutHeld) mode=\(isCaptureModeActive) itemDrag=\(itemDrag != nil) shelfDrag=\(shelfDrag != nil)")
        guard isEnabled, !isShortcutHeld else { return }
        // This latch filters Carbon repeats only. Mode lifetime no longer
        // depends on keeping either shortcut key physically held.
        isShortcutHeld = true
        toggleCaptureMode()
    }

    func finishSavingPreviews() {
        previewStore?.finishPendingWrites()
    }

    func toggleCaptureMode() {
        guard isEnabled else { return }
        if isCaptureModeActive { cancelInteraction(); return }
        guard itemDrag == nil, shelfDrag == nil else { return }
        previousCaptureApplication = NSWorkspace.shared.frontmostApplication
        previousCaptureCursor = NSCursor.current
        isCaptureModeActive = true
        logDiagnostic("capture mode entered pointer=\(NSEvent.mouseLocation)")
        selectionSession = UUID()
        clearHoverSelection()
        collapse(animated: true)
        updateCaptureTip(at: NSEvent.mouseLocation)
        NSApp.activate()
        updateCaptureCursor()
        updateHoverSelection(at: NSEvent.mouseLocation)
    }

    func releaseShortcut() {
        isShortcutHeld = false
    }

    func cancelInteraction() {
        logDiagnostic("interaction cancelled mode=\(isCaptureModeActive) expanded=\(isExpanded)")
        isCaptureModeActive = false
        restoreCaptureCursor()
        selectionSession = nil
        captureTip.hide()
        tipDisplayID = nil
        tipCarryingWindow = nil
        clearHoverSelection()
        cancelPickedWindow()
        itemDrag = nil
        if shelfDrag != nil { NSCursor.arrow.set() }
        shelfDrag = nil
        insertionIndex = nil
        removingItem = false
        dragPanel?.orderOut(nil)
        hoverBlockedUntilPointerLeaves = isAtDockEdge(NSEvent.mouseLocation)
        collapse(animated: isEnabled)
        render()
    }

    func updateCapturePermission(_ granted: Bool) {
        let changed = captureEnabled != granted
        captureEnabled = granted
        guard !granted else {
            if changed, isEnabled { restoreSavedPreviews() }
            if changed, isEnabled, isExpanded { refreshThumbnails() }
            if changed, let selectionSession, let window = selectionTarget?.window {
                captureSelectionThumbnail(window, session: selectionSession)
            } else if changed, let picked = pickedWindow {
                captureSelectionThumbnail(picked.target, session: picked.selectionID)
            }
            return
        }
        captureEpoch = UUID()
        dragCaptureTask?.cancel()
        dragCaptureTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        previewRestoreTask?.cancel()
        previewRestoreTask = nil
        thumbnails.removeAll()
        selectionThumbnail = nil
        pickedWindow?.thumbnail = nil
        render()
        updateDragPreview()
    }

    private var dockScreen: NSScreen? {
        NSScreen.screens.first { displayID($0) == dockDisplayID }
    }

    private var hasActiveShelfDrag: Bool {
        (pickedWindow.map { !$0.isPlacing } ?? false) || itemDrag != nil || shelfDrag != nil
    }

    private var isHardwareMouseButtonPressed: Bool {
        // Session-wide button state includes synthesized input that can remain
        // pressed after the device was released. Only hardware input should
        // pause shelf hover and window lookup during an ordinary mouse gesture.
        CGEventSource.buttonState(.hidSystemState, button: .left)
            || CGEventSource.buttonState(.hidSystemState, button: .right)
            || CGEventSource.buttonState(.hidSystemState, button: .center)
    }

    private func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func screen(at point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func quartzPoint(_ point: CGPoint) -> CGPoint {
        let top = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).maxY
        return CGPoint(x: point.x, y: top - point.y)
    }

    private func quartzScreenFrames() -> [CGRect] {
        let top = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).maxY
        return NSScreen.screens.map {
            CGRect(x: $0.frame.minX, y: top - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height)
        }
    }

    private func edgeScreen(at point: CGPoint, tolerance: CGFloat) -> NSScreen? {
        NSScreen.screens.first {
            guard point.y >= $0.frame.minY && point.y <= $0.frame.maxY else { return false }
            if settings.pinnedDockSide == .left {
                return point.x >= $0.frame.minX && point.x <= $0.frame.minX + tolerance
            }
            return point.x >= $0.frame.maxX - tolerance && point.x <= $0.frame.maxX
        }
    }

    private func clearHoverSelection(cancelCapture: Bool = true) {
        lookupToken = UUID()
        identifyTask?.cancel()
        identifyTask = nil
        lookupPoint = nil
        selectionTarget = nil
        selectionRegions.removeAll()
        selectionThumbnail = nil
        windowHighlight.clear()
        if cancelCapture {
            selectionCaptureToken = UUID()
            dragCaptureTask?.cancel()
            dragCaptureTask = nil
        }
    }

    private func updateHoverSelection(at point: CGPoint) {
        guard isEnabled, isCaptureModeActive, let session = selectionSession,
              pickedWindow == nil, itemDrag == nil, !windowHighlight.isTracking else {
            logHoverDiagnostic("blocked-by-interaction-state")
            return
        }
        guard !isHardwareMouseButtonPressed else {
            logHoverDiagnostic("mouse-button-held")
            clearHoverSelection()
            return
        }
        // The shelf is our own interaction surface. Never put a selection
        // overlay over its cards or search for the window underneath it.
        if isExpanded, panel?.frame.contains(point) == true {
            logHoverDiagnostic("pointer-over-shelf")
            clearHoverSelection()
            return
        }
        if selectionRegions.contains(where: { $0.contains(point) }) {
            logHoverDiagnostic("inside-highlighted-window")
            return
        }
        if selectionTarget != nil { clearHoverSelection() }
        if identifyTask != nil {
            logHoverDiagnostic("lookup-pending")
            return
        }
        if let lookupPoint, hypot(point.x - lookupPoint.x, point.y - lookupPoint.y) < 2 {
            logHoverDiagnostic("pointer-unchanged")
            return
        }

        lookupPoint = point
        let token = UUID()
        lookupToken = token
        let targetPoint = quartzPoint(point)
        let screens = quartzScreenFrames()
        let top = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).maxY
        logHoverDiagnostic("lookup-started")
        logDiagnostic("lookup coordinates appKit=\(point) quartz=\(targetPoint) screens=\(screens)")
        identifyTask = Task { [weak self] in
            guard let self else { return }
            let target = await layoutService.target(at: targetPoint, screens: screens)
            guard !Task.isCancelled, lookupToken == token else {
                logDiagnostic("lookup result discarded cancelled=\(Task.isCancelled) tokenMatches=\(lookupToken == token)")
                return
            }
            identifyTask = nil
            guard isEnabled, isCaptureModeActive, selectionSession == session,
                  pickedWindow == nil, itemDrag == nil, !windowHighlight.isTracking,
                  !isHardwareMouseButtonPressed else {
                logHoverDiagnostic("lookup-result-blocked-by-interaction-state")
                return
            }
            let pointer = NSEvent.mouseLocation
            guard !(isExpanded && panel?.frame.contains(pointer) == true) else {
                logHoverDiagnostic("lookup-result-pointer-over-shelf")
                clearHoverSelection()
                return
            }
            guard let target else {
                logHoverDiagnostic("lookup-returned-no-window")
                if hypot(pointer.x - point.x, pointer.y - point.y) >= 2 {
                    lookupPoint = nil
                    updateHoverSelection(at: pointer)
                }
                return
            }
            let regions = target.visibleRegions.map {
                QuickLayoutGeometry.appKitRect(from: $0, primaryScreenTop: top)
            }
            // A slow result may arrive after the mouse has reached another
            // window. Show it only if its visible part still owns the pointer.
            guard regions.contains(where: { $0.contains(pointer) }) else {
                logDiagnostic("lookup result missed current pointer=\(pointer) regions=\(regions)")
                lookupPoint = nil
                updateHoverSelection(at: pointer)
                return
            }
            let tracked = catalog.track(target.window)
            let selected = LayoutTarget(window: tracked, visibleRegions: target.visibleRegions)
            selectionTarget = selected
            selectionRegions = regions
            selectionThumbnail = captureEnabled ? thumbnails[tracked.id] : nil
            windowHighlight.show(target: selected, primaryScreenTop: top)
            logDiagnostic("highlight shown pid=\(tracked.processID) regions=\(regions)")
            captureSelectionThumbnail(tracked, session: session)
        }
    }

    private func pickUpWindow(at point: CGPoint) -> Bool {
        guard isEnabled, isCaptureModeActive, let session = selectionSession,
              pickedWindow == nil, itemDrag == nil, let target = selectionTarget,
              selectionRegions.contains(where: { $0.contains(point) }) else { return false }
        messageTask?.cancel()
        message = nil
        pickedWindow = PickedWindow(selectionID: session, point: point,
                                    target: target.window, thumbnail: selectionThumbnail)
        cancelPendingPointerUpdate()
        updateCaptureTip(at: point)
        updateCaptureCursor()
        // Keep the first click's receiver through up. It never doubles as the
        // later shelf click that places this window.
        clearHoverSelection(cancelCapture: false)
        if let screen = screen(at: point) { expand(on: screen) }
        render()
        updateDragPreview(animatePickup: true)
        panel?.ignoresMouseEvents = !acceptsShelfDrop(at: point)
        updateAutoScroll(at: point)
        return true
    }

    private func movePickedWindow(to point: CGPoint) {
        guard var picked = pickedWindow, !picked.isPlacing else { return }
        picked.point = point
        pickedWindow = picked
        updateCaptureTip(at: point)
        if let screen = screen(at: point),
           !isExpanded || presentedDisplayID != displayID(screen) { expand(on: screen) }
        updateDragPreview(updateContent: false)
        // The transparent margin hosts the glass bridge, but clicks outside
        // the original shelf still belong to the application underneath it.
        panel?.ignoresMouseEvents = !acceptsShelfDrop(at: point)
        updateAutoScroll(at: point)
        insertionIndex = acceptsShelfDrop(at: point)
            ? shelf?.insertionIndex(at: point) ?? windows.count : nil
        shelf?.updateInsertionIndex(insertionIndex)
    }

    private func acceptsShelfDrop(at point: CGPoint) -> Bool {
        isExpanded && shelf?.acceptsDrop(at: point) == true
    }

    private func placePickedWindow(at point: CGPoint) {
        guard isEnabled, isCaptureModeActive, var picked = pickedWindow, !picked.isPlacing,
              selectionSession == picked.selectionID, !windowHighlight.isTracking,
              acceptsShelfDrop(at: point), let display = presentedDisplayID,
              let screen = NSScreen.screens.first(where: { displayID($0) == display }) else { return }
        movePickedWindow(to: point)
        // Preserve the displayed shape even if the initial pickup is unfinished.
        stopPickupAnimation()
        picked.isPlacing = true
        stopAutoScroll()
        picked.point = point
        pickedWindow = picked
        let window = picked.target
        let index = shelf?.insertionIndex(at: point) ?? windows.count
        let pinnedID = dock(window, thumbnail: captureEnabled ? picked.thumbnail : nil, at: index)
        insertionIndex = nil
        dockDisplayID = display
        expand(on: screen)
        render()
        shelf?.reveal(pinnedID)
        highlight(pinnedID)
        let animation = UUID()
        previewAnimationID = animation
        isPreviewAnimating = true
        guard let preview = dragPreview, let shelf, let destination = shelf.cardScreenFrame(for: pinnedID),
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finishCaptureMode()
            refreshThumbnails()
            return
        }
        let session = picked.id
        shelf.animatePlacement(preview, to: pinnedID, destination: destination, renderFrame: { [weak self] glass, picture in
            guard let self, self.previewAnimationID == animation, self.pickedWindow?.id == session else { return }
            self.positionDragPreview(screenFrame: glass, pictureFrame: picture, on: screen)
        }) { [weak self] in
            guard let self, self.previewAnimationID == animation,
                  self.pickedWindow?.id == session else { return }
            self.finishCaptureMode()
            self.refreshThumbnails()
        }
    }

    private func finishCaptureMode() {
        isCaptureModeActive = false
        restoreCaptureCursor()
        selectionSession = nil
        captureTip.hide()
        tipDisplayID = nil
        tipCarryingWindow = nil
        clearHoverSelection()
        cancelPickedWindow()
        installPointerMonitoring()
        updatePointer(at: NSEvent.mouseLocation)
        render()
    }

    private func captureSelectionThumbnail(_ window: WindowItem, session: UUID) {
        guard captureEnabled, window.allowsThumbnail else { return }
        let epoch = captureEpoch
        let token = UUID()
        selectionCaptureToken = token
        dragCaptureTask?.cancel()
        dragCaptureTask = Task { [weak self] in
            let image = await WindowThumbnailCapture.capture(window)
            guard let self, !Task.isCancelled, isEnabled, captureEnabled, captureEpoch == epoch,
                  selectionSession == session, selectionCaptureToken == token else { return }
            if selectionTarget?.window.id == window.id { selectionThumbnail = image }
            if pickedWindow?.selectionID == session, pickedWindow?.target.id == window.id {
                pickedWindow?.thumbnail = image
                render()
                updateDragPreview()
            }
            dragCaptureTask = nil
        }
    }

    private func cancelPickedWindow() {
        guard pickedWindow != nil else { return }
        pickedWindow = nil
        stopPickupAnimation()
        previewAnimationID = UUID()
        isPreviewAnimating = false
        windowHighlight.clear()
        selectionCaptureToken = UUID()
        dragCaptureTask?.cancel()
        dragCaptureTask = nil
        insertionIndex = nil
        shelf?.cancelPlacement()
        dragPreview?.removeFromSuperview()
        dragPreview = nil
        dragPanel?.orderOut(nil)
        dragPanel = nil
        // Cancelling a pickup must not change the saved docking display.
        if let dockScreen, isExpanded { expand(on: dockScreen) }
        stopAutoScroll()
        scheduleCollapseAfterPointerLeaves(at: NSEvent.mouseLocation)
        render()
    }

    private func beginItemDrag(_ id: UUID, at point: CGPoint) {
        guard isEnabled, !isCaptureModeActive, pickedWindow == nil, itemDrag == nil, shelfDrag == nil,
              !busyIDs.contains(id), windows.contains(where: { $0.id == id }) else { return }
        clearHoverSelection()
        messageTask?.cancel()
        message = nil
        itemDrag = ItemDrag(id: id, origin: point, point: point)
        cancelScheduledCollapse()
        render()
    }

    private func moveItemDrag(to point: CGPoint) {
        guard var drag = itemDrag else { return }
        drag.point = point
        if hypot(point.x - drag.origin.x, point.y - drag.origin.y) >= 5 { drag.moved = true }
        itemDrag = drag
        guard drag.moved else { return }
        shelf?.autoScroll(at: point)
        updateAutoScroll(at: point)
        removingItem = shelf?.containsScreenPoint(point) == false
        insertionIndex = !removingItem && shelf?.containsScreenPoint(point) == true
            ? shelf?.insertionIndex(at: point, excluding: drag.id) : nil
        render()
        updateDragPreview()
    }

    private func endItemDrag(at point: CGPoint) {
        moveItemDrag(to: point)
        guard let drag = itemDrag else { return }
        let remove = drag.moved && shelf?.containsScreenPoint(point) == false
        let destination = drag.moved && !remove && shelf?.containsScreenPoint(point) == true
            ? shelf?.insertionIndex(at: point, excluding: drag.id) : nil
        itemDrag = nil
        insertionIndex = nil
        removingItem = false
        dragPanel?.orderOut(nil)
        if remove {
            removeEntryFromShelf(drag.id)
        } else if let destination, let source = windows.firstIndex(where: { $0.id == drag.id }) {
            var reordered = windows
            let window = reordered.remove(at: source)
            reordered.insert(window, at: min(max(0, destination), reordered.count))
            _ = replaceEntries(reordered)
        } else if !drag.moved {
            activateEntry(drag.id)
        }
        stopAutoScroll()
        scheduleCollapseAfterPointerLeaves(at: point)
        render()
    }

    private func beginShelfDrag(at point: CGPoint) {
        guard isEnabled, isExpanded, !isCaptureModeActive, pickedWindow == nil,
              itemDrag == nil, shelfDrag == nil else { return }
        shelfDrag = ShelfDrag(origin: point, side: settings.pinnedDockSide)
        cancelScheduledCollapse()
        NSCursor.closedHand.set()
    }

    private func moveShelfDrag(to point: CGPoint) {
        guard var drag = shelfDrag, !drag.switched else { return }
        let inwardDistance = (point.x - drag.origin.x) * (drag.side == .left ? 1 : -1)
        guard inwardDistance >= 80 else { return }
        // The receiver's panel moves to the opposite edge during this same
        // mouse sequence. Latch the switch until up so it cannot bounce back.
        drag.switched = true
        shelfDrag = drag
        setDockSide(drag.side.opposite)
    }

    private func moveShelfToOtherSide() {
        guard isEnabled, isExpanded, !isCaptureModeActive, !hasActiveShelfDrag else { return }
        setDockSide(settings.pinnedDockSide.opposite)
        panel?.makeKey()
        shelf?.focusFirstEntry()
    }

    private func setDisplayMode(_ mode: PinnedDisplayMode) {
        guard isEnabled, isExpanded, !hasActiveShelfDrag, pickedWindow == nil,
              settings.pinnedDisplayMode != mode else { return }
        settings.pinnedDisplayMode = mode
        render()
    }

    private func setDockSide(_ side: PinnedDockSide) {
        settings.pinnedDockSide = side
        dockDisplayID = presentedDisplayID
        if let dockScreen { ensurePanel(on: dockScreen) }
        render()
    }

    private func endShelfDrag(at point: CGPoint) {
        guard shelfDrag != nil else { return }
        moveShelfDrag(to: point)
        let switched = shelfDrag?.switched == true
        shelfDrag = nil
        if !switched {
            panel?.makeKey()
            shelf?.focusFirstEntry()
        }
        scheduleCollapseAfterPointerLeaves(at: point)
        NSCursor.arrow.set()
        render()
    }

    private func updateAutoScroll(at point: CGPoint) {
        guard isEnabled, hasActiveShelfDrag, shelf?.canAutoScroll(at: point) == true else {
            stopAutoScroll()
            return
        }
        guard autoScrollTimer == nil else { return }
        // This timer drives scrolling during a drag, using the last received
        // pointer event. It neither polls input nor runs outside the scroll edge.
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.isEnabled, self.hasActiveShelfDrag,
                      let point = self.pickedWindow?.point ?? self.itemDrag?.point,
                      self.shelf?.canAutoScroll(at: point) == true else {
                    self.stopAutoScroll()
                    return
                }
                if self.pickedWindow != nil {
                    self.shelf?.autoScroll(at: point)
                    self.movePickedWindow(to: point)
                } else if self.itemDrag?.moved == true { self.moveItemDrag(to: point) }
                else { self.stopAutoScroll() }
            }
        }
        autoScrollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    private var busyIDs: Set<UUID> {
        Set(entryTokens.keys).union(restoringIDs)
    }

    @discardableResult
    private func dock(_ window: WindowItem, thumbnail: NSImage?, at index: Int) -> UUID {
        let existing = windows.first { $0.window.map { sameWindow($0, window) } ?? false }
        let id = existing?.id ?? window.id
        if existing == nil {
            var entry = PinnedWindowEntry(window: window)
            entry.saved = entry.recordForSaving()
            windows.insert(entry, at: min(max(0, index), windows.count))
        }
        if window.allowsThumbnail, let thumbnail { thumbnails[id] = thumbnail }
        persistWindows()
        savePreview(for: id)
        return id
    }

    private func persistWindows() {
        guard !previewMode else { return }
        // Automatic snapshots must not interrupt docking or switching. A
        // failed save leaves the previous usable disk snapshot intact.
        try? settings.savePinnedWindows(windows)
    }

    private func sameWindow(_ left: WindowItem, _ right: WindowItem) -> Bool {
        left.processID == right.processID && CFEqual(left.element, right.element)
    }

    // Save before changing a user's choice. A failed write leaves the pin,
    // order and removal exactly as they were so a restart cannot surprise them.
    @discardableResult
    private func replaceEntries(_ entries: [PinnedWindowEntry]) -> Bool {
        do {
            if !previewMode { try settings.savePinnedWindows(entries) }
            let previousIDs = Set(windows.map(\.id))
            windows = entries
            if !previewMode {
                let ids = Set(entries.map(\.id))
                for id in previousIDs.subtracting(ids) { previewStore?.remove(for: id) }
            }
            return true
        } catch {
            showMessage("暂时无法保存，请再试一次")
            return false
        }
    }

    private func cancelEntryTask(_ id: UUID) {
        entryTokens[id] = nil
        capturingIDs.remove(id)
        entryTasks.removeValue(forKey: id)?.cancel()
    }

    private func finishEntryTask(_ id: UUID, token: UUID) {
        guard entryTokens[id] == token else { return }
        let wasCapturing = capturingIDs.contains(id)
        entryTokens[id] = nil
        entryTasks[id] = nil
        capturingIDs.remove(id)
        render()
        if wasCapturing { checkClosedWindows() }
    }

    private func isCurrentEntryTask(_ id: UUID, token: UUID) -> Bool {
        !Task.isCancelled && isEnabled && entryTokens[id] == token && windows.contains { $0.id == id }
    }

    private func toggleRetention(_ id: UUID) {
        logDiagnostic("retention requested id=\(id) enabled=\(isEnabled) busy=\(busyIDs.contains(id))")
        guard isEnabled, !busyIDs.contains(id), let index = windows.firstIndex(where: { $0.id == id }) else { return }
        if windows[index].isRetained {
            var entries = windows
            if entries[index].isClosed { entries.remove(at: index) }
            else {
                var saved = entries[index].recordForSaving()
                saved?.retainAfterClose = false
                entries[index].saved = saved
            }
            if replaceEntries(entries) {
                cancelEntryTask(id)
                launchService.forget(id)
                if !entries.contains(where: { $0.id == id }) {
                    thumbnails[id] = nil
                    confirmedClosedIDs.remove(id)
                }
                render()
            }
            return
        }
        guard let window = windows[index].window else {
            Self.diagnostics.warning("retention unavailable id=\(id.uuidString, privacy: .public) reason=window-not-associated")
            restoreOriginalWindows()
            showMessage(PinnedWindowLaunchError.windowUnavailable.localizedDescription)
            return
        }
        if previewMode {
            windows[index].saved = previewSavedWindow(window)
            render()
            return
        }

        let token = UUID()
        entryTokens[id] = token
        capturingIDs.insert(id)
        entryTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { finishEntryTask(id, token: token) }
            do {
                let saved = try await launchService.capture(window)
                guard isCurrentEntryTask(id, token: token) else { return }
                let presence = await WindowCatalog.presence(of: window)
                guard isCurrentEntryTask(id, token: token),
                      let index = windows.firstIndex(where: { $0.id == id }), !windows[index].isRetained else { return }
                var entries = windows
                entries[index].saved = saved
                let justClosed: Bool
                if case .closed = presence { justClosed = true } else { justClosed = false }
                if (justClosed || confirmedClosedIDs.contains(id)),
                   let current = entries[index].window, sameWindow(current, window) {
                    entries[index].window = nil
                }
                if replaceEntries(entries) {
                    logDiagnostic("retention saved id=\(id) pid=\(window.processID) captureID=\(window.captureID ?? 0)")
                    render()
                }
            } catch {
                guard isCurrentEntryTask(id, token: token) else { return }
                Self.diagnostics.error("retention failed id=\(id.uuidString, privacy: .public) error=\(String(describing: error as? PinnedWindowLaunchError), privacy: .public)")
                showMessage(error.localizedDescription)
            }
        }
        render()
    }

    private func removeEntryFromShelf(_ id: UUID) {
        guard isEnabled, !busyIDs.contains(id), windows.contains(where: { $0.id == id }) else { return }
        let remaining = windows.filter { $0.id != id }
        guard replaceEntries(remaining) else { return }
        cancelEntryTask(id)
        launchService.forget(id)
        thumbnails[id] = nil
        confirmedClosedIDs.remove(id)
        render()
    }

    private func activateEntry(_ id: UUID) {
        guard isEnabled, !busyIDs.contains(id), let entry = windows.first(where: { $0.id == id }) else { return }
        if previewMode { highlight(id); return }
        let token = UUID()
        entryTokens[id] = token
        entryTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { finishEntryTask(id, token: token) }
            if let window = entry.window {
                let presence = await WindowCatalog.presence(of: window)
                guard isCurrentEntryTask(id, token: token),
                      let index = windows.firstIndex(where: { $0.id == id }) else { return }
                if let current = windows[index].window {
                    guard sameWindow(current, window) else { return }
                } else {
                    // A periodic check may already have cleared this exact
                    // window while the click was checking it independently.
                    guard windows[index].isRetained, case .closed = presence else { return }
                }
                switch presence {
                case .present:
                    if catalog.activate(window) {
                        hoverBlockedUntilPointerLeaves = isAtDockEdge(NSEvent.mouseLocation)
                        collapse(animated: true)
                    } else { showMessage("这个窗口暂时无法切换，请再试一次") }
                    return
                case .unknown:
                    showMessage("这个窗口暂时无法确认，请再试一次")
                    return
                case .closed:
                    confirmedClosedIDs.insert(id)
                    if windows[index].isRetained {
                        windows[index].window = nil
                        render()
                    } else {
                        removeClosedEntry(id)
                        render()
                        return
                    }
                }
            }
            guard isCurrentEntryTask(id, token: token),
                  let current = windows.first(where: { $0.id == id }) else { return }
            guard current.isRetained, let saved = current.saved else {
                restoreOriginalWindows()
                showMessage("这个窗口暂时无法确认，请再试一次")
                return
            }
            do {
                let opened = try await launchService.open(saved)
                guard isCurrentEntryTask(id, token: token) else { return }
                if let opened {
                    bindWindow(opened, to: id)
                    hoverBlockedUntilPointerLeaves = isAtDockEdge(NSEvent.mouseLocation)
                    collapse(animated: true)
                } else {
                    showMessage("已打开应用，暂时无法关联窗口")
                }
            } catch {
                guard isCurrentEntryTask(id, token: token) else { return }
                showMessage(error.localizedDescription)
            }
        }
        render()
    }

    private func bindWindow(_ window: WindowItem, to id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        var entries = windows
        let tracked = catalog.track(window, preferredID: id)
        entries[index].window = tracked
        confirmedClosedIDs.remove(id)
        if var saved = entries[index].saved {
            saved.processID = tracked.processID
            saved.processLaunchDate = NSRunningApplication(processIdentifier: tracked.processID)
                .flatMap(WindowCatalog.processLaunchDate)
            saved.captureID = tracked.captureID
            saved.chromeWindowIdentity = launchService.chromeWindowIdentity(for: tracked)
                ?? saved.chromeWindowIdentity.flatMap {
                    $0.matches(tracked, launchDate: saved.processLaunchDate) ? $0 : nil
                }
            entries[index].saved = saved
        }
        let duplicates = entries.filter { entry in
            entry.id != id && (entry.window.map { sameWindow($0, tracked) } ?? false)
        }.map(\.id)
        entries.removeAll { duplicates.contains($0.id) }
        // Opening an app has already happened. Keep its real window linked in
        // memory even if writing its new identity fails; the saved target stays
        // usable, and the launch service also remembers an unlinked new window.
        if !replaceEntries(entries) { windows = entries }
        for duplicate in duplicates {
            cancelEntryTask(duplicate)
            launchService.forget(duplicate)
            thumbnails[duplicate] = nil
            confirmedClosedIDs.remove(duplicate)
        }
        render()
        refreshThumbnails()
    }

    private func restoreOriginalWindows() {
        guard !previewMode, restorationTask == nil else { return }
        let savedEntries = windows.filter { $0.window == nil && $0.saved != nil }
        guard !savedEntries.isEmpty else { return }
        let token = UUID()
        restorationToken = token
        restoringIDs = Set(savedEntries.map(\.id))
        restorationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if restorationToken == token {
                    restorationTask = nil
                    restoringIDs.removeAll()
                    render()
                }
            }
            let currentWindows = await catalog.load()
            guard !Task.isCancelled, isEnabled, restorationToken == token else { return }
            for entry in savedEntries {
                guard !Task.isCancelled, isEnabled, restorationToken == token,
                      let saved = entry.saved else { return }
                let presence = await WindowCatalog.presence(of: saved)
                guard !Task.isCancelled, isEnabled, restorationToken == token,
                      let current = windows.first(where: { $0.id == entry.id }),
                      current.window == nil, current.saved == saved else { continue }
                if case .closed = presence {
                    if !current.isRetained { removeClosedEntry(entry.id) }
                    continue
                }
                guard case .present = presence, let processID = saved.processID,
                      let captureID = saved.captureID else { continue }
                let matches = currentWindows.filter { $0.processID == processID && $0.captureID == captureID }
                guard matches.count == 1 else { continue }
                bindWindow(matches[0], to: entry.id)
            }
        }
        render()
    }

    private func installWindowMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                    self?.scheduleWindowRefresh(processID: application.processIdentifier)
                }
            })
        }
        updateWindowObservers()
    }

    private func clearWindowObservers() {
        for observer in windowObservers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        windowObservers.removeAll()
        observedWindows.removeAll()
    }

    private func updateWindowObservers() {
        guard isEnabled, !previewMode else { clearWindowObservers(); return }
        let current = Dictionary(uniqueKeysWithValues: windows.compactMap { entry in
            entry.window.map { (entry.id, $0) }
        })
        let notifications = [kAXTitleChangedNotification, kAXMovedNotification,
                             kAXResizedNotification, kAXUIElementDestroyedNotification]
        for (id, window) in observedWindows {
            if let replacement = current[id], sameWindow(window, replacement) { continue }
            if let observer = windowObservers[window.processID] {
                for notification in notifications {
                    AXObserverRemoveNotification(observer, window.element, notification as CFString)
                }
            }
            observedWindows[id] = nil
        }
        let processes = Set(current.values.map(\.processID))
        for (processID, observer) in windowObservers where !processes.contains(processID) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            windowObservers[processID] = nil
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for (id, window) in current where observedWindows[id] == nil {
            if windowObservers[window.processID] == nil {
                var created: AXObserver?
                let result = AXObserverCreate(window.processID, { _, element, notification, context in
                    guard let context else { return }
                    MainActor.assumeIsolated {
                        let controller = Unmanaged<PinnedWindowsController>.fromOpaque(context).takeUnretainedValue()
                        if notification as String == kAXUIElementDestroyedNotification {
                            controller.checkClosedWindows()
                        }
                        var processID: pid_t = 0
                        guard AXUIElementGetPid(element, &processID) == .success else { return }
                        controller.scheduleWindowRefresh(processID: processID)
                    }
                }, &created)
                guard result == .success, let observer = created else { continue }
                windowObservers[window.processID] = observer
                let application = AXUIElementCreateApplication(window.processID)
                AXUIElementSetMessagingTimeout(application, 0.3)
                for notification in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
                    AXObserverAddNotification(observer, application, notification as CFString, context)
                }
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
            guard let observer = windowObservers[window.processID] else { continue }
            for notification in notifications {
                AXObserverAddNotification(observer, window.element, notification as CFString, context)
            }
            observedWindows[id] = window
        }
    }

    private func scheduleWindowRefresh(processID: pid_t) {
        guard isEnabled, !previewMode, windows.contains(where: { $0.window?.processID == processID }) else { return }
        // Coalesce both sides of a focus switch, so refreshing the new window
        // cannot cancel the departing window's last successful snapshot.
        refreshWindowMetadata(debounce: true)
    }

    private func installPointerMonitoring() {
        guard isEnabled else { return }
        let active = isCaptureModeActive || isExpanded
        guard pointerMonitoringActive != active || localMonitor == nil || globalMonitor == nil else { return }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        pointerMonitoringActive = active
        let idleEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseUp, .rightMouseUp, .otherMouseUp]
        let localEvents: NSEvent.EventTypeMask = active
            ? [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown] : idleEvents
        let globalEvents: NSEvent.EventTypeMask = active
            ? [.mouseMoved, .leftMouseDragged, .leftMouseUp, .keyDown] : idleEvents
        logDiagnostic("pointer notifications active=\(active)")
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: localEvents) { [weak self] event in
            guard let self, self.isEnabled else { return event }
            if !self.isCaptureModeActive, !self.isExpanded {
                self.handleEdgeNotification(at: NSEvent.mouseLocation)
                return event
            }
            defer { self.updateCaptureCursor() }
            if event.type == .leftMouseDown {
                self.consumesDropMouseUp = false
                if self.pickedWindow != nil, event.window === self.panel, !self.windowHighlight.isTracking {
                    // Handle the shelf before its cards see down, so a drop
                    // onto an existing card cannot also activate that window.
                    if let window = event.window {
                        let point = window.convertPoint(toScreen: event.locationInWindow)
                        if self.acceptsShelfDrop(at: point) {
                            self.consumesDropMouseUp = true
                            self.placePickedWindow(at: point)
                        }
                    }
                    return nil
                }
            }
            if event.type == .leftMouseUp, self.consumesDropMouseUp {
                self.consumesDropMouseUp = false
                return nil
            }
            if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape),
               self.isCaptureModeActive || self.itemDrag != nil || self.shelfDrag != nil ||
                (self.isExpanded && event.window === self.panel) {
                self.cancelInteraction()
                return nil
            }
            if event.type == .mouseMoved || event.type == .leftMouseUp {
                self.schedulePointerUpdate(at: NSEvent.mouseLocation)
            }
            if self.shelfDrag != nil {
                switch event.type {
                case .leftMouseDragged: self.moveShelfDrag(to: NSEvent.mouseLocation); return nil
                case .leftMouseUp: self.endShelfDrag(at: NSEvent.mouseLocation); return nil
                default: return event
                }
            }
            // The pickup click still belongs to the highlight view. Its up
            // releases that receiver; it never places the picked window.
            guard self.itemDrag != nil else { return event }
            switch event.type {
            case .leftMouseDragged: self.moveItemDrag(to: NSEvent.mouseLocation); return nil
            case .leftMouseUp: self.endItemDrag(at: NSEvent.mouseLocation); return nil
            default: return event
            }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: globalEvents) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled else { return }
                if !self.isCaptureModeActive, !self.isExpanded {
                    self.handleEdgeNotification(at: NSEvent.mouseLocation)
                    return
                }
                defer { self.updateCaptureCursor() }
                if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape),
                   self.isCaptureModeActive || self.itemDrag != nil || self.shelfDrag != nil {
                    // A global monitor observes Escape; it cannot consume the
                    // event that the front application also receives.
                    self.cancelInteraction()
                } else if self.shelfDrag != nil {
                    if event.type == .leftMouseDragged { self.moveShelfDrag(to: NSEvent.mouseLocation) }
                    else if event.type == .leftMouseUp { self.endShelfDrag(at: NSEvent.mouseLocation) }
                } else if self.pickedWindow != nil {
                    if event.type == .leftMouseDragged {
                        self.movePickedWindow(to: NSEvent.mouseLocation)
                    }
                } else if self.itemDrag != nil {
                    if event.type == .leftMouseDragged { self.moveItemDrag(to: NSEvent.mouseLocation) }
                    else if event.type == .leftMouseUp { self.endItemDrag(at: NSEvent.mouseLocation) }
                }
                if event.type == .mouseMoved || event.type == .leftMouseUp ||
                    (event.type == .leftMouseDragged && self.pickedWindow == nil && self.itemDrag == nil && self.shelfDrag == nil) {
                    self.schedulePointerUpdate(at: NSEvent.mouseLocation)
                }
            }
        }
    }

    private func updateCaptureCursor() {
        if shelfDrag != nil { NSCursor.closedHand.set(); return }
        guard isCaptureModeActive else { return }
        // AppKit updates cursors as views change. Keep the capture hand while
        // the pointer crosses other windows or the highlight is removed.
        (pickedWindow == nil ? NSCursor.openHand : NSCursor.closedHand).set()
    }

    private func restoreCaptureCursor() {
        guard let cursor = previousCaptureCursor else { return }
        previousCaptureCursor = nil
        cursor.set()
        let application = previousCaptureApplication
        previousCaptureApplication = nil
        // A deliberate switch to another app during capture takes precedence.
        if NSApp.isActive, let application,
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            application.activate()
        }
    }

    private func updateCaptureTip(at point: CGPoint) {
        guard isCaptureModeActive, let screen = screen(at: point) else { return }
        let display = displayID(screen)
        let carryingWindow = pickedWindow != nil
        guard tipDisplayID != display || tipCarryingWindow != carryingWindow else { return }
        tipDisplayID = display
        tipCarryingWindow = carryingWindow
        captureTip.show(on: screen, settings: settings, carryingWindow: carryingWindow)
    }

    private func handleEdgeNotification(at point: CGPoint) {
        guard isEnabled, !isCaptureModeActive, !isExpanded, let dockScreen else { return }
        let atEdge = edgeScreen(at: point, tolerance: 3).map(displayID) == displayID(dockScreen)
        if hoverBlockedUntilPointerLeaves {
            if !atEdge { hoverBlockedUntilPointerLeaves = false }
            return
        }
        guard atEdge, !isHardwareMouseButtonPressed else { return }
        expand(on: dockScreen)
    }

    private func schedulePointerUpdate(at point: CGPoint) {
        guard isEnabled, isCaptureModeActive || isExpanded else { return }
        // A carried preview must follow every movement notification. Only
        // window lookup and ordinary shelf hover use the slower coalesced path.
        if pickedWindow != nil {
            cancelPendingPointerUpdate()
            updatePointer(at: point)
            return
        }
        guard pointerUpdateTask == nil else { return }
        // Coalesce a burst of movement into one update of the latest position.
        // There is no scheduled work when the pointer stays still.
        pointerUpdateTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            pointerUpdateTask = nil
            updatePointer(at: NSEvent.mouseLocation)
        }
    }

    private func cancelPendingPointerUpdate() {
        pointerUpdateTask?.cancel()
        pointerUpdateTask = nil
    }

    private func updatePointer(at point: CGPoint) {
        guard isEnabled, isCaptureModeActive || isExpanded else { return }
        #if DEBUG
        diagnosticPointerUpdates += 1
        let diagnosticNow = ProcessInfo.processInfo.systemUptime
        if diagnosticNow - diagnosticLastPointerLogAt >= 2 {
            diagnosticLastPointerLogAt = diagnosticNow
            let appKitButtons = NSEvent.pressedMouseButtons
            let hidLeft = CGEventSource.buttonState(.hidSystemState, button: .left)
            let hidRight = CGEventSource.buttonState(.hidSystemState, button: .right)
            let sessionLeft = CGEventSource.buttonState(.combinedSessionState, button: .left)
            let sessionRight = CGEventSource.buttonState(.combinedSessionState, button: .right)
            let edgeDisplay = edgeScreen(at: point, tolerance: 3).map(displayID) ?? 0
            logDiagnostic("pointer updates=\(diagnosticPointerUpdates) mode=\(isCaptureModeActive) session=\(selectionSession != nil) picked=\(pickedWindow != nil) itemDrag=\(itemDrag != nil) shelfDrag=\(shelfDrag != nil) mouseButtons=\(appKitButtons) expanded=\(isExpanded) visible=\(panel?.isVisible == true) side=\(settings.pinnedDockSide.rawValue) dockDisplay=\(dockDisplayID ?? 0) edgeDisplay=\(edgeDisplay) point=\(point)")
            logDiagnostic("input-sources appKitButtons=\(appKitButtons) hidLeft=\(hidLeft) hidRight=\(hidRight) sessionLeft=\(sessionLeft) sessionRight=\(sessionRight)")
        }
        #endif
        updateCaptureCursor()
        if shelfDrag != nil { return }
        if isCaptureModeActive { updateCaptureTip(at: point) }
        if pickedWindow != nil {
            movePickedWindow(to: point)
            return
        }
        if let drag = itemDrag {
            if drag.moved { moveItemDrag(to: point) }
            return
        }
        if isCaptureModeActive {
            if selectionSession != nil { updateHoverSelection(at: point) }
            scheduleCollapseAfterPointerLeaves(at: point)
            return
        }
        scheduleCollapseAfterPointerLeaves(at: point)
    }

    private func scheduleCollapseAfterPointerLeaves(at point: CGPoint) {
        guard isExpanded, !hasActiveShelfDrag, panel?.isKeyWindow != true else { cancelScheduledCollapse(); return }
        if panel?.frame.contains(point) == true || isAtDockEdge(point) {
            cancelScheduledCollapse()
            return
        }
        guard collapseTask == nil else { return }
        collapseTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            collapseTask = nil
            guard isEnabled, isExpanded, !hasActiveShelfDrag, panel?.isKeyWindow != true else { return }
            let point = NSEvent.mouseLocation
            guard panel?.frame.contains(point) != true, !isAtDockEdge(point) else { return }
            collapse(animated: true)
        }
    }

    private func isAtDockEdge(_ point: CGPoint) -> Bool {
        guard let dockScreen else { return false }
        return edgeScreen(at: point, tolerance: 3).map(displayID) == displayID(dockScreen)
    }

    private func cancelScheduledCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }

    private func expand(on screen: NSScreen) {
        guard isEnabled else { return }
        ensurePanel(on: screen)
        let display = displayID(screen)
        let opening = !isExpanded || presentedDisplayID != display
        presentedDisplayID = display
        isExpanded = true
        cancelScheduledCollapse()
        panel?.ignoresMouseEvents = false
        panel?.orderFrontRegardless()
        installPointerMonitoring()
        if opening {
            logDiagnostic("shelf opening display=\(display) frame=\(String(describing: panel?.frame)) visible=\(panel?.isVisible == true)")
            render()
            if let message, messageTask == nil { showMessage(message) }
            shelf?.setShown(true, animated: true)
            restoreOriginalWindows()
            checkClosedWindows()
            refreshWindowMetadata()
            refreshThumbnails()
        }
    }

    private func collapse(animated: Bool) {
        logDiagnostic("shelf collapsing animated=\(animated) mode=\(isCaptureModeActive)")
        isExpanded = false
        cancelScheduledCollapse()
        cancelPendingPointerUpdate()
        stopAutoScroll()
        installPointerMonitoring()
        panel?.ignoresMouseEvents = true
        shelf?.setShown(false, animated: animated) { [weak self] in
            guard let self, !isExpanded else { return }
            panel?.orderOut(nil)
            if isCaptureModeActive, selectionSession != nil {
                // A lookup at the sliding shelf may have hit our own panel.
                // Its disappearance makes that location eligible again.
                if selectionTarget == nil { lookupPoint = nil }
                updateHoverSelection(at: NSEvent.mouseLocation)
            }
        }
    }

    private func ensurePanel(on screen: NSScreen) {
        let area = screen.visibleFrame
        let dockWidth = min(224, screen.frame.width)
        let width = min(dockWidth + (pickedWindow != nil ? 320 : 0), screen.frame.width)
        let frame = CGRect(x: settings.pinnedDockSide == .left ? screen.frame.minX : screen.frame.maxX - width, y: area.minY,
                           width: width, height: area.height)
        if panel == nil {
            let panel = makePanel(frame: frame)
            // Keep the shelf above app windows but below native help windows,
            // so the pin's tooltip remains visible over the shelf.
            panel.level = .popUpMenu
            panel.title = "Tidest · \(settings.text("窗口停靠"))"
            let view = PinnedWindowsView(frame: CGRect(origin: .zero, size: frame.size))
            view.autoresizingMask = [.width, .height]
            view.onMouseDown = { [weak self] id, point in self?.beginItemDrag(id, at: point) }
            view.onToggleRetention = { [weak self] id in self?.toggleRetention(id) }
            view.onActivate = { [weak self] id in self?.activateEntry(id) }
            view.onRemove = { [weak self] id in self?.removeEntryFromShelf(id) }
            view.onMoveToOtherSide = { [weak self] in self?.moveShelfToOtherSide() }
            view.onDisplayModeChange = { [weak self] mode in self?.setDisplayMode(mode) }
            panel.onResignKey = { [weak self] in
                self?.scheduleCollapseAfterPointerLeaves(at: NSEvent.mouseLocation)
            }
            view.onHeaderMouseDown = { [weak self] point in self?.beginShelfDrag(at: point) }
            panel.contentView = view
            self.panel = panel
            shelf = view
            view.setShown(false, animated: false)
        }
        shelf?.setDockSide(settings.pinnedDockSide)
        shelf?.setDockWidth(dockWidth)
        if panel?.frame != frame { panel?.setFrame(frame, display: true) }
        shelf?.layoutSubtreeIfNeeded()
    }

    private func makePanel(frame: CGRect) -> PinnedWindowsPanel {
        let panel = PinnedWindowsPanel(contentRect: frame,
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }

    private func stopPickupAnimation() {
        pickupAnimationTask?.cancel()
        pickupAnimationTask = nil
        pickupAnimation = nil
        isPreviewAnimating = false
    }

    private func animatePickup(from frame: CGRect, at point: CGPoint) {
        guard let picked = pickedWindow else { return }
        stopPickupAnimation()
        pickupAnimation = (frame, point, ProcessInfo.processInfo.systemUptime)
        let animation = UUID()
        previewAnimationID = animation
        isPreviewAnimating = true
        let session = picked.id
        // Only lifting the original window is timed. Shelf entry is driven
        // entirely by pointer position and never starts an animation task.
        pickupAnimationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard let self, !Task.isCancelled, self.previewAnimationID == animation,
                      self.pickedWindow?.id == session else { return }
                self.updateDragPreview(updateContent: false)
                if self.pickupAnimation == nil {
                    self.pickupAnimationTask = nil
                    return
                }
            }
        }
    }

    private func updateDragPreview(animatePickup: Bool = false, updateContent: Bool = true) {
        let target: PinnedWindowEntry?
        let image: NSImage?
        let point: CGPoint
        if let picked = pickedWindow {
            guard !picked.isPlacing else { return }
            target = PinnedWindowEntry(window: picked.target)
            image = captureEnabled ? picked.thumbnail : nil
            point = picked.point
        } else if let drag = itemDrag, drag.moved {
            target = windows.first { $0.id == drag.id }
            image = captureEnabled ? thumbnails[drag.id] : nil
            point = drag.point
        } else {
            dragPanel?.orderOut(nil)
            dragPreview?.removeFromSuperview()
            return
        }
        guard let target else { return }
        guard !isPreviewAnimating || pickupAnimation != nil || animatePickup else { return }
        let needsContentUpdate = updateContent || dragPreview == nil
        if dragPanel == nil {
            let panel = makePanel(frame: .zero)
            panel.ignoresMouseEvents = true
            dragPanel = panel
        }
        if dragPreview == nil { dragPreview = PinnedWindowDragPreviewView(frame: .zero) }
        guard let ghost = dragPanel, let preview = dragPreview else { return }
        if needsContentUpdate {
            preview.update(window: target, thumbnail: image)
        }
        guard let screen = screen(at: point) else { return }
        let area = screen.visibleFrame
        let carriedSize = preview.preferredSize(
            pictureWidth: PinnedWindowDragPreviewView.carriedPictureWidth,
            maxWidth: area.width, maxHeight: area.height)
        let dockedSize = preview.preferredSize(
            pictureWidth: PinnedWindowDragPreviewView.dockedPictureWidth,
            maxWidth: area.width, maxHeight: area.height)
        let entry: CGFloat
        if pickedWindow != nil, isExpanded, presentedDisplayID == displayID(screen) {
            entry = shelf?.previewEntryProgress(at: point, carriedWidth: carriedSize.width,
                                               dockedWidth: dockedSize.width) ?? 0
        } else {
            entry = 0
        }
        // Use a fixed geometric interval, never the already-deformed frame.
        // The same pointer position produces the same size in either direction.
        let shrink = pickedWindow == nil ? 1 : entry * entry * (3 - 2 * entry)
        let size = CGSize(width: carriedSize.width + (dockedSize.width - carriedSize.width) * shrink,
                          height: carriedSize.height + (dockedSize.height - carriedSize.height) * shrink)
        var frame = QuickLayoutGeometry.centeredPanelFrame(at: point, size: size, in: area)
        ghost.alphaValue = 1
        preview.alphaValue = 1
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animatePickup, pickedWindow != nil, !reducedMotion {
            let top = NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).maxY
            let origin = QuickLayoutGeometry.appKitRect(from: target.frame, primaryScreenTop: top)
            self.animatePickup(from: origin, at: point)
        } else if reducedMotion {
            stopPickupAnimation()
        }
        var pickupProgress: CGFloat = 1
        if let pickupAnimation {
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - pickupAnimation.startedAt) / 0.4)
            let remaining = 1 - progress
            pickupProgress = CGFloat(1 - remaining * remaining * remaining)
            frame = QuickLayoutGeometry.pickupPanelFrame(from: pickupAnimation.frame,
                initialPointer: pickupAnimation.point, at: point, size: size, in: area, progress: pickupProgress)
            if progress >= 1 {
                self.pickupAnimation = nil
                isPreviewAnimating = false
            }
        }
        let inset = PinnedWindowDragPreviewView.inset
        var picture = preview.fittedPicture(in: frame.insetBy(dx: inset, dy: inset))
        // Deformation peaks halfway through entry and eases to zero at both
        // ends. Bias the extra width toward the shelf to make the pull visible.
        let stretch = reducedMotion ? 0 : 16 * entry * entry * (1 - entry) * (1 - entry) * pickupProgress
        let extraWidth = picture.width * 0.24 * stretch
        let lostHeight = picture.height * 0.14 * stretch
        let xAnchor: CGFloat = settings.pinnedDockSide == .left ? 0.85 : 0.15
        picture = CGRect(x: picture.minX - extraWidth * xAnchor,
                         y: picture.minY + lostHeight / 2,
                         width: picture.width + extraWidth, height: picture.height - lostHeight)
        let glass = picture.insetBy(dx: -inset, dy: -inset)
        frame = QuickLayoutGeometry.centeredPanelFrame(
            at: CGPoint(x: glass.midX, y: glass.midY), size: glass.size, in: area)
        picture = picture.offsetBy(dx: frame.minX - glass.minX, dy: frame.minY - glass.minY)
        positionDragPreview(screenFrame: frame, pictureFrame: picture, on: screen)
    }

    private func positionDragPreview(screenFrame frame: CGRect, pictureFrame picture: CGRect, on screen: NSScreen) {
        guard let ghost = dragPanel, let preview = dragPreview else { return }
        // Dragging and placement use the same screen rectangles. The initial
        // pickup can still be larger than the shelf's drawing area on click.
        if pickedWindow != nil, presentedDisplayID == displayID(screen),
           shelf?.hostPreview(preview, screenFrame: frame, screenPictureFrame: picture) == true {
            ghost.orderOut(nil)
            return
        }
        if ghost.contentView !== preview {
            preview.removeFromSuperview()
            ghost.contentView = preview
        }
        if ghost.frame.size != frame.size {
            ghost.setFrame(frame, display: true)
        } else if ghost.frame.origin != frame.origin {
            // Moving an unchanged image only changes the panel origin;
            // it does not recreate the image view.
            ghost.setFrameOrigin(frame.origin)
        }
        preview.setFrames(glass: CGRect(origin: .zero, size: frame.size),
                          picture: picture.offsetBy(dx: -frame.minX, dy: -frame.minY))
        if !ghost.isVisible { ghost.orderFrontRegardless() }
    }

    private func render() {
        updateWindowObservers()
        let insertionEntry = pickedWindow.map { picked in
            windows.first { $0.window.map { sameWindow($0, picked.target) } ?? false }
                ?? PinnedWindowEntry(window: picked.target)
        }
        shelf?.update(windows: windows, thumbnails: thumbnails, settings: settings,
                      draggedID: itemDrag?.moved == true ? itemDrag?.id : nil,
                      highlightedID: highlightedID, insertionIndex: insertionIndex,
                      showsRemovalHint: itemDrag?.moved == true, removingItem: removingItem, message: message,
                      freezeRowHeights: hasActiveShelfDrag, carryingWindow: pickedWindow != nil,
                      insertionEntry: insertionEntry,
                      insertionThumbnail: captureEnabled ? pickedWindow?.thumbnail : nil,
                      busyIDs: busyIDs)
    }

    // Temporary diagnostics record control flow, not window titles or contents.
    // Debug-only throttling keeps movement notifications from flooding the console.
    private func logDiagnostic(_ message: @autoclosure () -> String) {
        #if DEBUG
        let messageText = message()
        Self.diagnostics.notice("\(messageText, privacy: .public)")
        #endif
    }

    private func logHoverDiagnostic(_ reason: String) {
        #if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        guard reason != diagnosticLastHoverReason || now - diagnosticLastHoverLogAt >= 2 else { return }
        diagnosticLastHoverReason = reason
        diagnosticLastHoverLogAt = now
        logDiagnostic("selection \(reason) enabled=\(isEnabled) mode=\(isCaptureModeActive) session=\(selectionSession != nil) picked=\(pickedWindow != nil) itemDrag=\(itemDrag != nil) tracking=\(windowHighlight.isTracking) lookupPending=\(identifyTask != nil) mouseButtons=\(NSEvent.pressedMouseButtons)")
        #endif
    }

    private func highlight(_ id: UUID) {
        highlightedID = id
        highlightTask?.cancel()
        render()
        highlightTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.2)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            highlightedID = nil
            render()
        }
    }

    private func showMessage(_ key: String) {
        message = key
        messageTask?.cancel()
        render()
        messageTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            message = nil
            render()
        }
    }

    private func refreshThumbnails() {
        guard isEnabled, captureEnabled, !previewMode else { return }
        let snapshot = windows.compactMap(\.window)
        guard !snapshot.isEmpty else { return }
        let epoch = captureEpoch
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let images = await WindowThumbnailCapture.capture(for: snapshot)
            guard let self, !Task.isCancelled, isEnabled, captureEnabled, captureEpoch == epoch else { return }
            for (id, image) in images {
                guard let original = snapshot.first(where: { $0.id == id }),
                      let current = windows.first(where: { $0.id == id })?.window,
                      !confirmedClosedIDs.contains(id), sameWindow(current, original) else { continue }
                thumbnails[id] = image
                savePreview(for: id)
            }
            render()
            refreshTask = nil
        }
    }

    private func savePreview(for id: UUID) {
        guard !previewMode, let previewStore,
              windows.contains(where: { $0.id == id && $0.allowsThumbnail }),
              let image = thumbnails[id]?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        previewStore.save(image, for: id)
    }

    private func restoreSavedPreviews() {
        guard !previewMode, captureEnabled, let previewStore, previewRestoreTask == nil else { return }
        let ids = Set(windows.filter(\.allowsThumbnail).map(\.id))
        guard !ids.isEmpty else { return }
        let epoch = captureEpoch
        previewRestoreTask = Task { [weak self] in
            let images = await previewStore.load(for: ids)
            guard let self, !Task.isCancelled, isEnabled, captureEnabled, captureEpoch == epoch else { return }
            for (id, image) in images {
                guard thumbnails[id] == nil, windows.contains(where: { $0.id == id && $0.allowsThumbnail }) else { continue }
                thumbnails[id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
            render()
            previewRestoreTask = nil
        }
    }

    private func refreshWindowMetadata(debounce: Bool = false) {
        guard isEnabled, !previewMode else { return }
        let snapshot = windows.compactMap(\.window)
        guard !snapshot.isEmpty else { return }
        let token = UUID()
        metadataToken = token
        metadataTask?.cancel()
        metadataTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if metadataToken == token { metadataTask = nil }
            }
            if debounce {
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
            }
            // Read the pinned AX objects directly, including windows outside
            // the current desktop. Never substitute another app window.
            let readTask = Task.detached(priority: .utility) {
                snapshot.compactMap { window -> WindowItem? in
                    guard !Task.isCancelled else { return nil }
                    return try? PinnedAppleEvents.currentWindow(window)
                }
            }
            let refreshed = await withTaskCancellationHandler { await readTask.value } onCancel: { readTask.cancel() }
            guard !Task.isCancelled, isEnabled, metadataToken == token else { return }
            guard !refreshed.isEmpty else { return }
            for updated in refreshed {
                guard let index = windows.firstIndex(where: { $0.id == updated.id }),
                      let current = windows[index].window, sameWindow(current, updated),
                      !confirmedClosedIDs.contains(updated.id) else { continue }
                windows[index].window = catalog.track(updated, preferredID: windows[index].id)
            }
            persistWindows()
            render()
            refreshThumbnails()
            for updated in refreshed {
                guard !Task.isCancelled, isEnabled, metadataToken == token else { return }
                guard let index = windows.firstIndex(where: { $0.id == updated.id }),
                      let current = windows[index].window, sameWindow(current, updated),
                      windows[index].isRetained,
                      let previousSaved = windows[index].saved,
                      !confirmedClosedIDs.contains(updated.id), !busyIDs.contains(updated.id) else { continue }
                do {
                    let saved = try await launchService.capture(updated, previous: previousSaved, allowsInteraction: false)
                    guard !Task.isCancelled, isEnabled, metadataToken == token else { return }
                    // A user may unpin, remove or reopen an entry while this
                    // read is in flight. Only update the unchanged live entry.
                    guard let index = windows.firstIndex(where: { $0.id == updated.id }),
                          let current = windows[index].window, sameWindow(current, updated),
                          windows[index].saved == previousSaved, !busyIDs.contains(updated.id),
                          !confirmedClosedIDs.contains(updated.id), saved != previousSaved else { continue }
                    var entries = windows
                    entries[index].saved = saved
                    try settings.savePinnedWindows(entries)
                    windows = entries
                } catch {
                    // Refreshing is optional. Keep the last usable reopen
                    // target without messages or disabling any shelf control.
                    if error is CancellationError { return }
                }
            }
        }
    }

    private func checkClosedWindows() {
        guard isEnabled, !previewMode, presenceTask == nil else { return }
        var snapshot = windows.compactMap(\.window)
        for window in [selectionTarget?.window, pickedWindow?.target].compactMap({ $0 })
            where !snapshot.contains(where: { $0.id == window.id }) {
            snapshot.append(window)
        }
        guard !snapshot.isEmpty else { return }
        presenceTask = Task { [weak self] in
            var closed: [WindowItem] = []
            for window in snapshot {
                guard !Task.isCancelled else { return }
                if case .closed = await WindowCatalog.presence(of: window) { closed.append(window) }
            }
            guard let self, !Task.isCancelled, isEnabled else { return }
            presenceTask = nil
            guard !closed.isEmpty else { return }
            if let selected = selectionTarget?.window, closed.contains(where: { self.sameWindow($0, selected) }) {
                clearHoverSelection()
            }
            if let drag = pickedWindow, closed.contains(where: { self.sameWindow($0, drag.target) }) {
                cancelPickedWindow()
            }
            var removedIDs: Set<UUID> = []
            for window in closed {
                if windowDidClose(window) { removedIDs.insert(window.id) }
                // During capture, keep the row until the requested snapshot
                // succeeds or fails. A successful snapshot may outlive its
                // window and must still become a retained closed entry.
            }
            if let drag = itemDrag, removedIDs.contains(drag.id) {
                itemDrag = nil
                insertionIndex = nil
                removingItem = false
                dragPanel?.orderOut(nil)
            }
            render()
        }
    }

    @discardableResult
    private func windowDidClose(_ window: WindowItem) -> Bool {
        // A late notification for an old window must not clear its replacement.
        guard let index = windows.firstIndex(where: { $0.id == window.id }),
              let current = windows[index].window, sameWindow(current, window) else { return false }
        confirmedClosedIDs.insert(window.id)
        if windows[index].isRetained {
            windows[index].window = nil
            persistWindows()
        } else if !capturingIDs.contains(window.id) {
            removeClosedEntry(window.id)
            return true
        }
        return false
    }

    private func removeClosedEntry(_ id: UUID) {
        windows.removeAll { $0.id == id }
        cancelEntryTask(id)
        launchService.forget(id)
        thumbnails[id] = nil
        confirmedClosedIDs.remove(id)
        if !previewMode { previewStore?.remove(for: id) }
        persistWindows()
    }

    private func screensChanged() {
        guard isEnabled else { return }
        // Screen changes invalidate every cached visible region and origin,
        // even when the shortcut is held before its first mouse-down.
        cancelInteraction()
        if dockScreen == nil { dockDisplayID = screen(at: NSEvent.mouseLocation).map(displayID) }
        if isExpanded, let dockScreen { expand(on: dockScreen) }
    }

    #if DEBUG
    func showPreview(count: Int = 5) {
        previewMode = true
        isEnabled = true
        installPointerMonitoring()
        messageTask?.cancel()
        messageTask = nil
        message = nil
        dockDisplayID = screen(at: NSEvent.mouseLocation).map(displayID)
        windows = (0..<min(150, max(0, count))).map { index in
            let window = WindowItem(element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
                       processID: ProcessInfo.processInfo.processIdentifier, applicationName: "Tidest",
                       icon: NSApp.applicationIconImage, title: "Tidest \(index + 1)",
                       frame: CGRect(x: 0, y: 0, width: index % 2 == 0 ? 1280 : 720,
                                     height: index % 2 == 0 ? 800 : 1080),
                       minimized: false, captureID: nil, stackOrder: index)
            if index == 0 { return PinnedWindowEntry(saved: previewSavedWindow(window)) }
            return PinnedWindowEntry(window: window)
        }
        thumbnails.removeAll()
        confirmedClosedIDs.removeAll()
        if let dockScreen { expand(on: dockScreen) }
    }
    #endif

    private func previewSavedWindow(_ window: WindowItem) -> SavedPinnedWindow {
        SavedPinnedWindow(id: window.id, applicationBundleIdentifier: Bundle.main.bundleIdentifier ?? "",
                          applicationURL: Bundle.main.bundleURL.absoluteString,
                          applicationName: window.applicationName, title: window.title,
                          width: window.frame.width, height: window.frame.height, target: .application)
    }
}

private final class PinnedWindowsPanel: NSPanel {
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
