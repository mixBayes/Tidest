import AppKit
import ApplicationServices
import Carbon
import Combine
import SwiftUI

@MainActor
final class MultiWindowLayoutController: NSObject, ObservableObject, NSWindowDelegate {
    struct WindowPreview: Identifiable {
        let window: WindowItem
        let image: NSImage?
        var id: UUID { window.id }
    }

    enum Edit {
        case replace(LayoutRegion), split(LayoutSplitEdge), merge
    }
    @Published private(set) var isPresented = false
    @Published private(set) var isApplying = false
    @Published private(set) var isSavingCombination = false
    @Published private(set) var draft: MultiWindowLayoutDraft?
    @Published private(set) var windows: [LayoutWindowChoice] = []
    @Published private(set) var displays: [LayoutDisplay] = []
    @Published private(set) var target: LayoutDisplay?
    @Published private(set) var pointer: CGPoint?
    @Published private(set) var displayInvalidated = false
    @Published private(set) var isLoading = false
    @Published var isDraggingRegion = false
    @Published var choosingWindow = false {
        didSet {
            if !choosingWindow {
                panel?.makeFirstResponder(nil)
                endWindowPreview()
            }
        }
    }
    @Published var search = "" {
        didSet { highlightedWindow = filteredWindows.firstIndex { assignedRegionNumber(for: $0.id) == nil } ?? 0 }
    }
    @Published var highlightedWindow = 0
    @Published var pendingEdit: Edit?
    @Published private(set) var outcomes: [LayoutWindowOutcome] = []
    @Published private(set) var messageKey: String?
    @Published private(set) var undoAvailable = false
    @Published private(set) var windowPreview: WindowPreview?
    let templates: LayoutTemplateStore
    let settings: AppSettings
    var onSaveCombination: ((LayoutCombinationSnapshot, Bool) async throws -> Void)?

    private let service = MultiWindowLayoutService()
    private let statistics: UsageStatisticsStore
    private var panel: NSPanel?
    private var topology: [LayoutDisplay] = []
    private var undoTopology: [LayoutDisplay] = []
    private var undoHistory = LayoutUndoHistory<LayoutWindowRestore>()
    private var operation: Task<Void, Never>?
    private var combinationSave: Task<Void, Never>?
    private var combinationSaveID = UUID()
    private var loading: Task<Void, Never>?
    private var monitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var refreshTimer: Timer?
    private var enterHeld = false
    private var previewMode = false
    private var isUndoResult = false
    private var dragSplit: UUID?
    private var previewFailureRemaining = false
    private let captureThumbnail: @MainActor (WindowItem) async -> NSImage?
    private var thumbnailTasks: [UUID: Task<NSImage?, Never>] = [:]
    private var thumbnails: [UUID: NSImage] = [:]
    private var attemptedThumbnails: Set<UUID> = []
    private var thumbnailSession = UUID()
    private var windowPreviewTask: Task<Void, Never>?
    private var windowPreviewTarget: UUID?

    init(settings: AppSettings? = nil, templates: LayoutTemplateStore? = nil, statistics: UsageStatisticsStore? = nil,
         captureThumbnail: @escaping @MainActor (WindowItem) async -> NSImage? = { await WindowThumbnailCapture.capture($0) }) {
        let resolved = settings ?? .shared
        self.settings = resolved
        self.templates = templates ?? resolved.makeLayoutTemplateStore()
        self.statistics = statistics ?? .shared
        self.captureThumbnail = captureThumbnail
        super.init()
    }

    var filteredWindows: [LayoutWindowChoice] {
        return windows.filter {
            search.isEmpty || ($0.window.applicationName + " " + $0.window.title).localizedStandardContains(search)
        }
    }

    func assignedRegionNumber(for window: UUID) -> Int? {
        guard let draft, let index = draft.root.leaves.firstIndex(where: {
            $0.region.id != draft.selectedRegion && draft.assignments[$0.region.id] == window
        }) else { return nil }
        return index + 1
    }

    private var minimumRegionSize: CGSize {
        guard let target else { return CGSize(width: 1, height: 1) }
        return CGSize(width: 160 / target.layoutArea.width, height: 100 / target.layoutArea.height)
    }

    var sizeConflicts: Set<UUID> {
        guard let draft, let target else { return [] }
        return Set(draft.root.leaves.compactMap { leaf in
            guard let id = draft.assignments[leaf.region.id], let size = windows.first(where: { $0.id == id })?.minimumSize else { return nil }
            return size.width > leaf.frame.width * target.layoutArea.width + 2 || size.height > leaf.frame.height * target.layoutArea.height + 2 ? leaf.region.id : nil
        })
    }

    var canApply: Bool {
        guard let draft else { return false }
        return draft.isComplete && draft.root.fits(minimumSize: minimumRegionSize) && sizeConflicts.isEmpty &&
            (previewMode || AXIsProcessTrusted()) && !displayInvalidated && !isApplying && !isSavingCombination && !isLoading && !isDraggingRegion && outcomes.isEmpty &&
            draft.assignments.values.allSatisfy { id in windows.contains { $0.id == id } }
    }

    var isBusy: Bool { isApplying || isSavingCombination }

    var canSaveCombination: Bool {
        guard let draft else { return false }
        return draft.isComplete && !isApplying && !isSavingCombination && !isLoading &&
            !isDraggingRegion && outcomes.isEmpty && !displayInvalidated &&
            draft.assignments.values.allSatisfy { id in windows.contains { $0.id == id } }
    }

    func saveCombination() {
        guard canSaveCombination, let draft, let target, let onSaveCombination else { return }
        let members = draft.assignments.compactMapValues { id in windows.first { $0.id == id }?.window }
        let snapshot = LayoutCombinationSnapshot(root: draft.root, windows: members, display: target)
        choosingWindow = false
        isSavingCombination = true
        messageKey = nil
        let saveID = UUID()
        combinationSaveID = saveID
        combinationSave = Task { [weak self] in
            guard let self else { return }
            defer {
                if combinationSaveID == saveID { isSavingCombination = false; combinationSave = nil }
            }
            do {
                try await onSaveCombination(snapshot, previewMode)
            } catch {
                guard !Task.isCancelled, isPresented else { return }
                messageKey = (error as? PinnedWindowLaunchError)?.localizedDescription ?? "组合未能保存，请再试一次。"
            }
        }
    }

    var hasSmallRegions: Bool { draft.map { !$0.root.fits(minimumSize: minimumRegionSize) } ?? false }

    var canResetDraft: Bool {
        guard let draft else { return false }
        return !draft.assignments.isEmpty ||
            draft.root.leaves.map(\.frame) != LayoutStartingPoint.columns.makeRegion().leaves.map(\.frame)
    }

    func present(preview: Bool = false) {
        if isPresented {
            if !isApplying { panel?.makeKeyAndOrderFront(nil) }
            return
        }
        previewMode = preview
        #if DEBUG
        previewFailureRemaining = preview && ProcessInfo.processInfo.arguments.contains("--ui-preview-multi-layout-partial")
        #endif
        displays = LayoutDisplay.current()
        topology = displays
        target = displays.first { $0.frame.contains(NSEvent.mouseLocation) } ?? displays.first
        guard let target else { return }
        displayInvalidated = false
        draft = MultiWindowLayoutDraft(root: LayoutStartingPoint.columns.makeRegion())
        windows = []
        outcomes = []
        messageKey = nil
        choosingWindow = false
        pendingEdit = nil
        dragSplit = nil
        isDraggingRegion = false
        undoHistory.beginDraft()
        enterHeld = false
        isPresented = true
        let frame = target.frame
        if panel == nil {
            let panel = MultiWindowLayoutPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                               backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.titlebarAppearsTransparent = true
            panel.identifier = NSUserInterfaceItemIdentifier("multiWindowLayoutPanel")
            panel.delegate = self
            self.panel = panel
        }
        panel?.title = settings.text("组合布局")
        let content = NSHostingView(rootView: MultiWindowLayoutView(controller: self, settings: settings, templates: templates))
        // Keep screen entry/exit tracking independent of SwiftUI's animated cells.
        content.addTrackingArea(NSTrackingArea(rect: .zero,
                                              options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                              owner: panel, userInfo: nil))
        panel?.contentView = content
        panel?.setFrame(frame, display: true)
        panel?.makeKeyAndOrderFront(nil)
        installMonitors()
        updatePointer()
        if preview { loadPreviewWindows() }
        else { reloadWindows(); DailyActivityReporter.shared.recordActivity() }
    }

    func dismiss() {
        guard !isApplying else { return }
        combinationSave?.cancel()
        combinationSaveID = UUID()
        combinationSave = nil
        isSavingCombination = false
        loading?.cancel()
        loading = nil
        isPresented = false
        isDraggingRegion = false
        pointer = nil
        choosingWindow = false
        releaseWindowPreviews()
        panel?.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func stop() {
        operation?.cancel()
        loading?.cancel()
        service.stop()
        if !isApplying { dismiss() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !isApplying }
    func windowWillClose(_ notification: Notification) { dismiss() }

    func reconfirmDisplay() {
        guard !isApplying else { return }
        displays = LayoutDisplay.current()
        guard let display = displays.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) else { return }
        target = display
        panel?.setFrame(display.frame, display: true)
        updatePointer()
        topology = displays
        displayInvalidated = false
        outcomes = []
        messageKey = nil
        undoHistory.beginDraft()
        reloadWindows()
    }

    func reloadWindows() {
        guard !isApplying else { return }
        if previewMode { loadPreviewWindows(); return }
        loading?.cancel()
        isLoading = windows.isEmpty
        loading = Task { [weak self] in
            guard let self else { return }
            let choices = await service.choices()
            guard !Task.isCancelled, isPresented else { return }
            let highlightedID = filteredWindows.indices.contains(highlightedWindow) ? filteredWindows[highlightedWindow].id : nil
            windows = choices
            highlightedWindow = highlightedID.flatMap { id in self.filteredWindows.firstIndex { $0.id == id } }
                ?? filteredWindows.firstIndex { self.assignedRegionNumber(for: $0.id) == nil } ?? 0
            isLoading = false
            loading = nil
        }
    }

    func previewHighlightedWindow() {
        guard choosingWindow, filteredWindows.indices.contains(highlightedWindow) else {
            endWindowPreview()
            return
        }
        let window = filteredWindows[highlightedWindow].window
        guard assignedRegionNumber(for: window.id) == nil else { endWindowPreview(); return }
        guard windowPreviewTarget != window.id else { return }
        windowPreviewTask?.cancel()
        windowPreviewTarget = window.id
        let session = thumbnailSession
        // A capture belongs to the layout session, not to the hover. Revisiting
        // a window shares its in-flight task or its finished snapshot.
        let capture: Task<NSImage?, Never>?
        if attemptedThumbnails.contains(window.id) {
            capture = nil
        } else if let pending = thumbnailTasks[window.id] {
            capture = pending
        } else {
            let takeSnapshot = captureThumbnail
            let task = Task { [weak self] in
                let image = window.allowsThumbnail ? await takeSnapshot(window) : nil
                guard !Task.isCancelled, let self, thumbnailSession == session else { return nil as NSImage? }
                thumbnails[window.id] = image
                attemptedThumbnails.insert(window.id)
                thumbnailTasks[window.id] = nil
                return image
            }
            thumbnailTasks[window.id] = task
            capture = task
        }
        let cached = thumbnails[window.id]
        windowPreviewTask = Task { [weak self] in
            // Only presentation waits; the screenshot above starts immediately.
            do { try await Task.sleep(for: .milliseconds(120)) }
            catch { return }
            let image = if let capture { await capture.value } else { cached }
            guard !Task.isCancelled, let self, thumbnailSession == session,
                  choosingWindow, windowPreviewTarget == window.id,
                  windows.contains(where: { $0.id == window.id }) else { return }
            windowPreview = WindowPreview(window: window, image: image)
        }
    }

    private func endWindowPreview() {
        windowPreviewTask?.cancel()
        windowPreviewTask = nil
        windowPreviewTarget = nil
        windowPreview = nil
    }

    func cancelPendingWindowPreview(for id: UUID) {
        guard windowPreviewTarget == id else { return }
        windowPreviewTask?.cancel()
        windowPreviewTask = nil
        windowPreviewTarget = nil
        // Leaving the list keeps the last displayed image. An unfinished
        // screenshot still completes into the session cache.
    }

    private func releaseWindowPreviews() {
        endWindowPreview()
        thumbnailSession = UUID()
        let pending = thumbnailTasks
        let images = thumbnails
        thumbnailTasks = [:]
        thumbnails = [:]
        attemptedThumbnails = []
        // Detach the old session immediately, then cancel its captures and
        // release image storage without delaying the panel's dismissal.
        Task.detached(priority: .utility) {
            for task in pending.values { task.cancel() }
            withExtendedLifetime(images) {}
        }
    }

    func request(_ edit: Edit) {
        guard !isBusy, outcomes.isEmpty else { return }
        let affected: [UUID]
        switch edit {
        case .replace: affected = draft?.root.leafIDs ?? []
        case .split: affected = []
        case .merge: affected = draft?.mergeRegion?.leafIDs ?? []
        }
        if affected.contains(where: { draft?.assignments[$0] != nil }) { pendingEdit = edit }
        else { commit(edit) }
    }

    func confirmEdit() {
        guard !isBusy, let pendingEdit else { return }
        commit(pendingEdit)
        self.pendingEdit = nil
    }

    private func commit(_ edit: Edit) {
        choosingWindow = false
        messageKey = nil
        switch edit {
        case .replace(let root):
            guard root.isValid else { return }
            if draft == nil { draft = MultiWindowLayoutDraft(root: root) }
            else { draft?.replace(with: root) }
        case .split(let edge):
            if draft?.split(edge, minimumSize: minimumRegionSize) != true { messageKey = "区域过小，无法继续分割。" }
        case .merge: _ = draft?.merge(confirmed: true)
        }
    }

    func selectRegion(_ id: UUID, openPicker: Bool = true) {
        guard !isBusy, outcomes.isEmpty else { return }
        draft?.selectedRegion = id
        if openPicker {
            search = ""
            highlightedWindow = filteredWindows.firstIndex { assignedRegionNumber(for: $0.id) == nil } ?? 0
            choosingWindow = true
        }
    }

    func chooseWindow(_ id: UUID) {
        guard !isBusy, let region = draft?.selectedRegion,
              filteredWindows.contains(where: { $0.id == id }), assignedRegionNumber(for: id) == nil else { return }
        _ = draft?.assign(id, to: region)
        choosingWindow = false
    }

    func splitRegion(_ id: UUID, edge: LayoutSplitEdge) {
        selectRegion(id, openPicker: false)
        choosingWindow = false
        request(.split(edge))
    }

    func clearWindow(in region: UUID) {
        guard !isBusy, outcomes.isEmpty, draft?.assignments[region] != nil else { return }
        _ = draft?.assign(nil, to: region)
        choosingWindow = false
    }

    func resetDraft() {
        guard !isBusy, outcomes.isEmpty else { return }
        draft = MultiWindowLayoutDraft(root: LayoutStartingPoint.columns.makeRegion())
        choosingWindow = false
        pendingEdit = nil
        messageKey = nil
        dragSplit = nil
    }

    func deleteRegion(_ id: UUID) {
        guard !isBusy, outcomes.isEmpty, draft?.removeRegion(id) == true else { return }
        choosingWindow = false
        messageKey = nil
        dragSplit = nil
    }

    func previewDrop(from source: UUID, to target: LayoutRegionDropTarget) -> MultiWindowLayoutDraft? {
        guard isPresented, !isBusy, outcomes.isEmpty, !choosingWindow,
              pendingEdit == nil, !displayInvalidated else { return nil }
        return draft?.previewingDrop(from: source, to: target, minimumSize: minimumRegionSize)
    }

    func dropRegion(_ source: UUID, to target: LayoutRegionDropTarget) {
        guard previewDrop(from: source, to: target) != nil,
              draft?.drop(from: source, to: target, minimumSize: minimumRegionSize) == true else { return }
        messageKey = nil
        dragSplit = nil
    }

    func resize(_ split: UUID, ratio: Double, ended: Bool) {
        guard !isBusy, outcomes.isEmpty else { return }
        if dragSplit != split { draft?.checkpoint(); dragSplit = split }
        draft?.resize(split, ratio: ratio, minimumSize: minimumRegionSize)
        if ended { dragSplit = nil }
    }

    func undoDraft() {
        guard !isBusy, outcomes.isEmpty else { return }
        draft?.undo()
        choosingWindow = false
    }

    func continueEditing() {
        guard !isBusy else { return }
        outcomes = []
        messageKey = nil
        undoHistory.beginDraft()
        reloadWindows()
    }

    func apply(retryFailed: Bool = false) {
        guard !isApplying, let draft, let target, !displayInvalidated, !isLoading,
              draft.isComplete, retryFailed || canApply else { return }
        let failed = Set(outcomes.filter { !$0.status.isSuccess }.map(\.id))
        let requested = draft.root.placements(in: target.layoutArea, scale: target.scale).compactMap { placement -> (LayoutWindowChoice, CGRect)? in
            guard case .leaf(let regionID) = placement.region, let id = draft.assignments[regionID],
                  !retryFailed || failed.contains(id), let choice = windows.first(where: { $0.id == id }) else { return nil }
            return (choice, placement.frame)
        }
        // Never silently omit a window that disappeared from a refreshed catalogue.
        let expected = retryFailed ? failed.count : draft.root.leafIDs.count
        guard requested.count == expected, !requested.isEmpty else {
            messageKey = "部分窗口已不可用，请继续编辑并重新选择。"
            return
        }
        let previous = outcomes
        let expectedTopology = topology
        isApplying = true
        choosingWindow = false
        isUndoResult = false
        operation = Task { [weak self] in
            guard let self else { return }
            let result: LayoutBatchResult
            if previewMode {
                let failedID = previewFailureRemaining ? requested.last?.0.id : nil
                previewFailureRemaining = false
                result = LayoutBatchResult(outcomes: requested.map { LayoutWindowOutcome(choice: $0.0, requested: $0.1,
                                           actual: $0.0.id == failedID ? $0.0.window.frame : $0.1,
                                           status: $0.0.id == failedID ? .constrained : .placed) },
                                           originals: requested.map { LayoutWindowRestore(choice: $0.0, frame: $0.0.window.frame) })
            } else { result = await service.apply(requested, topology: expectedTopology) }
            if undoHistory.recordApplication(result.originals, hasSuccessfulResults: result.outcomes.contains { $0.status.isSuccess }) {
                undoTopology = expectedTopology
            }
            undoAvailable = !undoHistory.originals.isEmpty
            if retryFailed {
                let replacements = Dictionary(uniqueKeysWithValues: result.outcomes.map { ($0.id, $0) })
                outcomes = previous.map { replacements[$0.id] ?? $0 }
            } else { outcomes = result.outcomes }
            let completed = !outcomes.isEmpty && outcomes.allSatisfy { $0.status.isSuccess }
            if completed {
                // Release the layout panel before handing the arranged windows
                // to their apps. A retry must reveal the whole completed layout.
                panel?.orderOut(nil)
                if !previewMode {
                    await service.reveal(outcomes, topology: expectedTopology)
                    statistics.record()
                }
            }
            finishOperation(showPanel: !completed)
            if completed { dismiss() }
        }
    }

    func undoApplication() {
        guard !isApplying, !undoHistory.originals.isEmpty else { return }
        guard previewMode || LayoutDisplay.current() == undoTopology else {
            messageKey = "显示器配置已变化，无法安全撤销上次应用。"
            return
        }
        let requests = undoHistory.originals.map { ($0.choice, $0.frame) }
        let expectedTopology = undoTopology
        isApplying = true
        choosingWindow = false
        isUndoResult = true
        operation = Task { [weak self] in
            guard let self else { return }
            if previewMode {
                outcomes = requests.map { LayoutWindowOutcome(choice: $0.0, requested: $0.1, actual: $0.1, status: .restored) }
            } else { outcomes = await service.apply(requests, topology: expectedTopology, restoring: true).outcomes }
            undoHistory.recordRestoration(successfulIDs: Set(outcomes.filter { $0.status.isSuccess }.map(\.id)))
            undoAvailable = !undoHistory.originals.isEmpty
            finishOperation()
        }
    }

    var canRetry: Bool { !isUndoResult && outcomes.contains { !$0.status.isSuccess } && !displayInvalidated }

    private func finishOperation(showPanel: Bool = true) {
        isApplying = false
        operation = nil
        if !previewMode, LayoutDisplay.current() != topology { displayInvalidated = true }
        if showPanel { panel?.makeKeyAndOrderFront(nil) }
    }

    private func installMonitors() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .mouseMoved, .mouseEntered, .mouseExited,
                                                            .leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .keyDown || event.type == .keyUp { return self.handleKey(event) }
                if event.window === self.panel { self.updatePointer() }
                else if self.pointer != nil { self.pointer = nil }
                return false
            }
            return consumed ? nil : event
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPresented else { return }
                self.displays = LayoutDisplay.current()
                self.displayInvalidated = self.displays != self.topology
                if self.displayInvalidated { self.operation?.cancel() }
            }
        }
        if !previewMode {
            let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isPresented, !self.isBusy, self.loading == nil else { return }
                    self.reloadWindows()
                }
            }
            refreshTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func updatePointer() {
        let point = NSEvent.mouseLocation
        guard isPresented, panel?.attachedSheet == nil, let area = target?.visibleFrame,
              area.contains(point) else {
            if pointer != nil { pointer = nil }
            return
        }
        // The draft uses top-left coordinates normalized to the usable screen.
        let normalized = CGPoint(x: (point.x - area.minX) / area.width,
                                 y: (area.maxY - point.y) / area.height)
        if pointer != normalized { pointer = normalized }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard isPresented, event.window === panel, panel?.attachedSheet == nil,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        let enter = event.keyCode == kVK_Return || event.keyCode == kVK_ANSI_KeypadEnter
        if event.type == .keyUp {
            if enter { enterHeld = false; return true }
            return false
        }
        if event.keyCode == kVK_Escape {
            if isApplying { return true }
            if choosingWindow { choosingWindow = false }
            else { dismiss() }
            return true
        }
        if isBusy { return enter }
        if choosingWindow {
            let count = filteredWindows.count
            if event.keyCode == kVK_DownArrow || event.keyCode == kVK_UpArrow {
                if count > 0 {
                    for _ in 0..<count {
                        highlightedWindow = (highlightedWindow + (event.keyCode == kVK_DownArrow ? 1 : -1) + count) % count
                        if assignedRegionNumber(for: filteredWindows[highlightedWindow].id) == nil { break }
                    }
                }
                return true
            }
            if enter {
                guard !event.isARepeat, !enterHeld else { return true }
                enterHeld = true
                if filteredWindows.indices.contains(highlightedWindow) { chooseWindow(filteredWindows[highlightedWindow].id) }
                return true
            }
            return false
        }
        // Template naming and other text fields own their Return key.
        guard !(panel?.firstResponder is NSTextView) else { return false }
        if enter {
            guard !event.isARepeat, !enterHeld else { return true }
            enterHeld = true
            if canApply { apply() }
            return true
        }
        return false
    }

    private func loadPreviewWindows() {
        #if DEBUG
        guard windows.isEmpty else { isLoading = false; return }
        let pid = ProcessInfo.processInfo.processIdentifier
        windows = (1...8).map { index in
            let window = WindowItem(element: AXUIElementCreateApplication(pid), processID: pid,
                                    applicationName: index % 2 == 0 ? "Safari" : "Finder", icon: NSImage(named: NSImage.folderName),
                                    title: "\(settings.text("示例窗口")) \(index)", frame: CGRect(x: 40, y: 60, width: 800, height: 600),
                                    minimized: false, captureID: nil, stackOrder: index)
            return LayoutWindowChoice(window: window, processLaunchDate: nil)
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-preview-thumbnails") {
            for (index, choice) in windows.enumerated() {
                let size = index.isMultiple(of: 2) ? NSSize(width: 640, height: 480) : NSSize(width: 360, height: 640)
                thumbnails[choice.id] = NSImage(size: size, flipped: false) { bounds in
                    NSColor(calibratedHue: CGFloat(index) / 10, saturation: 0.32, brightness: 0.25, alpha: 1).setFill()
                    bounds.fill()
                    NSColor.white.withAlphaComponent(0.08).setFill()
                    CGRect(x: 0, y: 0, width: bounds.width * 0.22, height: bounds.height - 40).fill()
                    CGRect(x: 0, y: bounds.height - 40, width: bounds.width, height: 40).fill()
                    for row in 0..<3 {
                        NSColor.white.withAlphaComponent(0.12).setFill()
                        NSBezierPath(roundedRect: CGRect(x: bounds.width * 0.28, y: bounds.height - 130 - CGFloat(row) * 74,
                                                       width: bounds.width * 0.64, height: 54), xRadius: 8, yRadius: 8).fill()
                    }
                    (choice.window.title as NSString).draw(at: CGPoint(x: 20, y: bounds.height - 28),
                        withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: NSColor.white])
                    return true
                }
                attemptedThumbnails.insert(choice.id)
            }
        }
        #endif
        isLoading = false
    }
}

private final class MultiWindowLayoutPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
