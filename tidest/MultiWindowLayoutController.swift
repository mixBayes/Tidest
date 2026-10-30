import AppKit
import ApplicationServices
import Carbon
import Combine
import SwiftUI

@MainActor
final class MultiWindowLayoutController: NSObject, ObservableObject, NSWindowDelegate {
    enum Edit {
        case replace(LayoutRegion), split(LayoutSplitAxis), merge
    }
    @Published private(set) var isPresented = false
    @Published private(set) var isApplying = false
    @Published private(set) var draft: MultiWindowLayoutDraft?
    @Published private(set) var windows: [LayoutWindowChoice] = []
    @Published private(set) var displays: [LayoutDisplay] = []
    @Published private(set) var target: LayoutDisplay?
    @Published private(set) var displayInvalidated = false
    @Published private(set) var isLoading = false
    @Published var choosingWindow = false {
        didSet { if !choosingWindow { panel?.makeFirstResponder(nil) } }
    }
    @Published var confirming = false
    @Published var search = "" {
        didSet { highlightedWindow = filteredWindows.firstIndex { assignedRegionNumber(for: $0.id) == nil } ?? 0 }
    }
    @Published var highlightedWindow = 0
    @Published var pendingEdit: Edit?
    @Published private(set) var outcomes: [LayoutWindowOutcome] = []
    @Published private(set) var messageKey: String?
    @Published private(set) var undoAvailable = false
    @Published var canvasSize = CGSize(width: 600, height: 400)
    let templates: LayoutTemplateStore
    let settings: AppSettings

    private let service = MultiWindowLayoutService()
    private let statistics: UsageStatisticsStore
    private var panel: NSPanel?
    private var topology: [LayoutDisplay] = []
    private var undoTopology: [LayoutDisplay] = []
    private var undoHistory = LayoutUndoHistory<LayoutWindowRestore>()
    private var operation: Task<Void, Never>?
    private var loading: Task<Void, Never>?
    private var monitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var refreshTimer: Timer?
    private var enterHeld = false
    private var previewMode = false
    private var isUndoResult = false
    private var dragSplit: UUID?
    private var previewFailureRemaining = false

    init(settings: AppSettings? = nil, templates: LayoutTemplateStore? = nil, statistics: UsageStatisticsStore? = nil) {
        let resolved = settings ?? .shared
        self.settings = resolved
        self.templates = templates ?? resolved.makeLayoutTemplateStore()
        self.statistics = statistics ?? .shared
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
        return CGSize(width: max(160 / target.layoutArea.width, 90 / max(1, canvasSize.width)),
                      height: max(100 / target.layoutArea.height, 72 / max(1, canvasSize.height)))
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
            (previewMode || AXIsProcessTrusted()) && !displayInvalidated && !isApplying && !isLoading && outcomes.isEmpty &&
            draft.assignments.values.allSatisfy { id in windows.contains { $0.id == id } }
    }

    var hasSmallRegions: Bool { draft.map { !$0.root.fits(minimumSize: minimumRegionSize) } ?? false }

    func present(preview: Bool = false) {
        if isPresented { panel?.makeKeyAndOrderFront(nil); return }
        previewMode = preview
        #if DEBUG
        previewFailureRemaining = preview && ProcessInfo.processInfo.arguments.contains("--ui-preview-multi-layout-partial")
        #endif
        displays = LayoutDisplay.current()
        topology = displays
        target = displays.first { $0.frame.contains(NSEvent.mouseLocation) } ?? displays.first
        guard let target else { return }
        displayInvalidated = false
        draft = nil
        windows = []
        outcomes = []
        messageKey = nil
        choosingWindow = false
        confirming = false
        undoHistory.beginDraft()
        enterHeld = false
        isPresented = true
        let size = CGSize(width: min(1040, target.visibleFrame.width), height: min(720, target.visibleFrame.height))
        let frame = CGRect(x: target.visibleFrame.midX - size.width / 2, y: target.visibleFrame.midY - size.height / 2,
                           width: size.width, height: size.height)
        if panel == nil {
            let panel = MultiWindowLayoutPanel(contentRect: frame, styleMask: [.titled, .closable, .nonactivatingPanel],
                                               backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.titlebarAppearsTransparent = true
            panel.identifier = NSUserInterfaceItemIdentifier("multiWindowLayoutPanel")
            panel.delegate = self
            self.panel = panel
        }
        panel?.title = settings.text("快速布局")
        panel?.contentView = NSHostingView(rootView: MultiWindowLayoutView(controller: self, settings: settings, templates: templates))
        panel?.setFrame(frame, display: true)
        panel?.makeKeyAndOrderFront(nil)
        installMonitors()
        if preview { loadPreviewWindows() }
        else { reloadWindows(); DailyActivityReporter.shared.recordActivity() }
    }

    func dismiss() {
        guard !isApplying else { return }
        loading?.cancel()
        loading = nil
        isPresented = false
        choosingWindow = false
        confirming = false
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

    func selectDisplay(_ id: UInt32) {
        guard !isApplying else { return }
        displays = LayoutDisplay.current()
        guard let display = displays.first(where: { $0.id == id }) else { return }
        target = display
        topology = displays
        displayInvalidated = false
        confirming = false
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

    func request(_ edit: Edit) {
        guard !isApplying, outcomes.isEmpty else { return }
        let affected: [UUID]
        switch edit {
        case .replace: affected = draft?.root.leafIDs ?? []
        case .split: affected = draft?.selectedRegion.map { [$0] } ?? []
        case .merge: affected = draft?.mergeRegion?.leafIDs ?? []
        }
        if affected.contains(where: { draft?.assignments[$0] != nil }) { pendingEdit = edit }
        else { commit(edit) }
    }

    func confirmEdit() {
        guard let pendingEdit else { return }
        commit(pendingEdit)
        self.pendingEdit = nil
    }

    private func commit(_ edit: Edit) {
        choosingWindow = false
        confirming = false
        messageKey = nil
        switch edit {
        case .replace(let root):
            guard root.isValid else { return }
            if draft == nil { draft = MultiWindowLayoutDraft(root: root) }
            else { draft?.replace(with: root) }
        case .split(let axis):
            if draft?.split(axis, confirmed: true, minimumSize: minimumRegionSize) != true { messageKey = "区域过小，无法继续分割。" }
        case .merge: _ = draft?.merge(confirmed: true)
        }
    }

    func selectRegion(_ id: UUID, openPicker: Bool = true) {
        guard !isApplying, outcomes.isEmpty else { return }
        draft?.selectedRegion = id
        confirming = false
        if openPicker {
            search = ""
            highlightedWindow = filteredWindows.firstIndex { assignedRegionNumber(for: $0.id) == nil } ?? 0
            choosingWindow = true
        }
    }

    func chooseWindow(_ id: UUID) {
        guard !isApplying, let region = draft?.selectedRegion,
              filteredWindows.contains(where: { $0.id == id }), assignedRegionNumber(for: id) == nil else { return }
        _ = draft?.assign(id, to: region)
        choosingWindow = false
        confirming = false
    }

    func clearWindow() {
        guard !isApplying, let region = draft?.selectedRegion else { return }
        _ = draft?.assign(nil, to: region)
        confirming = false
    }

    func resize(_ split: UUID, ratio: Double, ended: Bool) {
        guard !isApplying, outcomes.isEmpty else { return }
        if dragSplit != split { draft?.checkpoint(); dragSplit = split }
        draft?.resize(split, ratio: ratio, minimumSize: minimumRegionSize)
        confirming = false
        if ended { dragSplit = nil }
    }

    func undoDraft() {
        guard !isApplying, outcomes.isEmpty else { return }
        draft?.undo()
        choosingWindow = false
        confirming = false
    }

    func continueEditing() {
        guard !isApplying else { return }
        outcomes = []
        messageKey = nil
        confirming = false
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
        confirming = false
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
            if !previewMode, !result.outcomes.isEmpty, outcomes.allSatisfy({ $0.status.isSuccess }) { statistics.record() }
            finishOperation()
            if !outcomes.isEmpty, outcomes.allSatisfy({ $0.status.isSuccess }) { dismiss() }
        }
    }

    func presentUndo() {
        guard !isApplying, undoAvailable else { return }
        if !isPresented {
            let previous = draft
            present(preview: previewMode)
            draft = previous
        }
        undoApplication()
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
        confirming = false
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

    private func finishOperation() {
        isApplying = false
        operation = nil
        if !previewMode, LayoutDisplay.current() != topology { displayInvalidated = true }
        panel?.makeKeyAndOrderFront(nil)
    }

    private func installMonitors() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return consumed ? nil : event
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPresented else { return }
                self.displays = LayoutDisplay.current()
                self.displayInvalidated = self.displays != self.topology
                self.confirming = false
                if self.displayInvalidated { self.operation?.cancel() }
            }
        }
        if !previewMode {
            let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isPresented, !self.isApplying, self.loading == nil else { return }
                    self.reloadWindows()
                }
            }
            refreshTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
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
            else if confirming { confirming = false }
            else { dismiss() }
            return true
        }
        if isApplying { return enter }
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
            if confirming { apply() }
            else if canApply { confirming = true }
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
        #endif
        isLoading = false
    }
}

private final class MultiWindowLayoutPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
