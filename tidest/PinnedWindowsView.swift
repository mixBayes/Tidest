import AppKit
import Combine
import QuartzCore
import OSLog

/// The panel never leaves its display. Only this clipped content slides away,
/// so hiding the shelf cannot put an invisible window on a neighbouring screen.
@MainActor
final class PinnedWindowsView: NSView {
    private static let removalHintSpace: CGFloat = 64
    var onMouseDown: ((UUID, CGPoint) -> Void)?
    var onToggleRetention: ((UUID) -> Void)?
    var onActivate: ((UUID) -> Void)?
    var onRemove: ((UUID) -> Void)?
    var onMoveToOtherSide: (() -> Void)?
    var onDisplayModeChange: ((PinnedDisplayMode) -> Void)?
    var onHeaderMouseDown: ((CGPoint) -> Void)?

    private static let outerInset: CGFloat = 8
    private static let cornerRadius: CGFloat = 22
    private static let headerHeight: CGFloat = 48
    private static let footerHeight: CGFloat = 48
    private static let documentInset: CGFloat = 4
    private static let rowSpacing: CGFloat = 12
    private static let messageSpace: CGFloat = 44
    private static let reflowAnimationKey = "dockReflow"
    private static let reflowDuration: CFTimeInterval = 0.22
    private let glassContainer: NSView = {
        if #available(macOS 26.0, *) { return NSGlassEffectContainerView() }
        return NSView()
    }()
    private let slidingContent = NSView()
    private let shelf: NSView
    private let shelfContent: NSView
    private let header = PinnedShelfHeaderView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let moveSideButton = PinnedRetainButton()
    private let displayModeControl = PinnedDisplayModeControl()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let emptyIcon = PinnedDropIconView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let removalHint = PinnedRemovalHintView()
    private let scroll = NSScrollView()
    private let document = PinnedWindowDocumentView()
    private let insertionPlaceholder = NSView()
    private let insertionSizingCard = PinnedWindowCardView(frame: .zero)
    private var insertionEntryID: UUID?
    private var rows: [PinnedWindowCardView] = []
    private var windows: [PinnedWindowEntry] = []
    private var draggedID: UUID?
    private var insertionIndex: Int?
    private var showsRemovalHint = false
    private var showsMessage = false
    private var freezeRowHeights = false
    private var rowHeights: [UUID: CGFloat] = [:]
    private var isShown = false
    private var carryingWindow = false
    private var dockWidth: CGFloat = 224
    private var placementID: UUID?
    private var placementTask: Task<Void, Never>?
    private var dockSide: PinnedDockSide = .right
    private var animationID = UUID()
    private var accessibilityObserver: AnyCancellable?
    private var systemColorObserver: AnyCancellable?
    private var displayedMode: PinnedDisplayMode?
    private var modeAnimation: CADisplayLink?
    private var modeProgress: CGFloat = 1
    private var modeTransition: DisplayModeTransition?

    private struct DisplayModeTransition {
        let start: CFTimeInterval
        let reducesMotion: Bool
        let frames: [UUID: CGRect]
        let documentHeight: CGFloat
        let anchor: (id: UUID, fraction: CGFloat)?
        var scrollAdjustment: CGFloat = 0
        var lastScrollOffset: CGFloat
        var duration: CFTimeInterval { reducesMotion ? 0.12 : 0.55 }
    }
    #if DEBUG
    private static let diagnostics = Logger(subsystem: "com.mixbayes.tidest", category: "WindowDock")
    #endif

    override init(frame frameRect: NSRect) {
        let shelfContent = NSView()
        self.shelfContent = shelfContent
        shelf = WindowBackground.make(contentView: shelfContent, cornerRadius: Self.cornerRadius,
            clearGlass: true, material: .sidebar)
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
        glassContainer.wantsLayer = true
        slidingContent.wantsLayer = true
        if #available(macOS 26.0, *), let container = glassContainer as? NSGlassEffectContainerView {
            container.contentView = slidingContent
        } else {
            glassContainer.addSubview(slidingContent)
        }
        addSubview(glassContainer)
        shelfContent.autoresizingMask = [.width, .height]
        slidingContent.addSubview(shelf)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 3
        messageLabel.isHidden = true
        removalHint.isHidden = true
        header.onMouseDown = { [weak self] point in self?.onHeaderMouseDown?(point) }
        header.addSubview(titleLabel)
        header.addSubview(countLabel)
        moveSideButton.title = ""
        moveSideButton.isBordered = false
        moveSideButton.imagePosition = .imageOnly
        moveSideButton.target = self
        moveSideButton.action = #selector(moveToOtherSide)
        moveSideButton.setAccessibilityIdentifier("pinnedMoveSide")
        header.addSubview(moveSideButton)
        shelfContent.addSubview(header)
        shelfContent.addSubview(messageLabel)
        shelfContent.addSubview(removalHint)
        displayModeControl.segmentCount = 2
        displayModeControl.controlSize = .large
        displayModeControl.trackingMode = .selectOne
        displayModeControl.segmentStyle = .rounded
        if #available(macOS 26.0, *) { displayModeControl.borderShape = .capsule }
        for segment in 0..<2 {
            displayModeControl.setLabel("", forSegment: segment)
            displayModeControl.setWidth(44, forSegment: segment)
            displayModeControl.setImageScaling(.scaleProportionallyDown, forSegment: segment)
        }
        displayModeControl.target = self
        displayModeControl.action = #selector(changeDisplayMode)
        displayModeControl.setAccessibilityIdentifier("pinnedDisplayMode")
        shelfContent.addSubview(displayModeControl)

        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.documentView = document
        document.onAnimationFrame = { [weak self] link in self?.advanceDisplayModeTransition(link) }
        shelfContent.addSubview(scroll)
        // The empty instruction and its decorative icon stay above the scroll view.
        shelfContent.addSubview(emptyLabel, positioned: .above, relativeTo: scroll)
        shelfContent.addSubview(emptyIcon, positioned: .above, relativeTo: scroll)
        insertionPlaceholder.wantsLayer = true
        insertionPlaceholder.layer?.cornerRadius = 12
        insertionPlaceholder.layer?.borderWidth = 1.5
        insertionPlaceholder.isHidden = true
        insertionPlaceholder.setAccessibilityElement(false)
        document.addSubview(insertionPlaceholder)
        setAccessibilityIdentifier("pinnedWindowsShelf")
        accessibilityObserver = NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        ).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateAppearance() }
        }
        systemColorObserver = NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateAppearance() }
            }
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { modeAnimation?.invalidate() }

    func update(windows: [PinnedWindowEntry], thumbnails: [UUID: NSImage], settings: AppSettings,
                draggedID: UUID?, highlightedID: UUID?, insertionIndex: Int?,
                showsRemovalHint: Bool, removingItem: Bool, message: String?,
                freezeRowHeights: Bool = false, carryingWindow: Bool = false,
                insertionEntry: PinnedWindowEntry? = nil, insertionThumbnail: NSImage? = nil,
                busyIDs: Set<UUID> = []) {
        let previousIDs = self.windows.map(\.id)
        let incomingIDs = windows.map(\.id)
        if modeTransition != nil, previousIDs != incomingIDs || freezeRowHeights || carryingWindow {
            finishDisplayModeTransition()
        }
        if let displayedMode, displayedMode != settings.pinnedDisplayMode,
           previousIDs == incomingIDs, !rows.isEmpty, isShown, window?.isVisible == true,
           !freezeRowHeights, !carryingWindow {
            beginDisplayModeTransition()
        }
        displayedMode = settings.pinnedDisplayMode
        if freezeRowHeights, !self.freezeRowHeights {
            for (window, row) in zip(self.windows, rows) where row.frame.height > 0 {
                rowHeights[window.id] = row.frame.height
            }
        }
        self.freezeRowHeights = freezeRowHeights
        self.windows = windows
        self.draggedID = draggedID
        self.insertionIndex = insertionIndex
        self.showsRemovalHint = showsRemovalHint
        self.carryingWindow = carryingWindow
        showsMessage = message != nil
        titleLabel.stringValue = "Tidest · \(settings.text("停靠窗口"))"
        titleLabel.toolTip = titleLabel.stringValue
        countLabel.stringValue = windows.isEmpty ? "" : "\(windows.count)"
        emptyLabel.stringValue = carryingWindow ? settings.text("点击停靠栏放下")
            : settings.text("按 %@，点一下窗口\n再点这里", settings.pinShortcut.symbolDisplayName)
        emptyLabel.isHidden = !windows.isEmpty
        emptyIcon.isHidden = !windows.isEmpty
        updateEmptyIconAnimation()
        messageLabel.stringValue = message.map { settings.text($0) } ?? ""
        messageLabel.isHidden = !showsMessage
        header.toolTip = settings.text("向内拖动可换边；点击后可用键盘选择")
        let moveTitle = settings.text(settings.pinnedDockSide == .right ? "移到左侧" : "移到右侧")
        moveSideButton.toolTip = moveTitle
        moveSideButton.setAccessibilityLabel(moveTitle)
        moveSideButton.image = NSImage(systemSymbolName: settings.pinnedDockSide == .right
            ? "sidebar.left" : "sidebar.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        let showsThumbnails = settings.pinnedDisplayMode == .thumbnails
        insertionEntryID = insertionEntry?.id
        if let insertionEntry {
            insertionSizingCard.update(window: insertionEntry,
                thumbnail: showsThumbnails ? insertionThumbnail : nil,
                settings: settings, highlighted: false, dragging: false)
        }
        let thumbnailTitle = settings.text("切换为缩略图")
        let iconTitle = settings.text("切换为图标 + 标题")
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        displayModeControl.setImage(NSImage(systemSymbolName: "rectangle.grid.1x2",
            accessibilityDescription: thumbnailTitle)?.withSymbolConfiguration(configuration), forSegment: 0)
        displayModeControl.setImage(NSImage(systemSymbolName: "list.bullet.rectangle",
            accessibilityDescription: iconTitle)?.withSymbolConfiguration(configuration), forSegment: 1)
        displayModeControl.setToolTip(thumbnailTitle, forSegment: 0)
        displayModeControl.setToolTip(iconTitle, forSegment: 1)
        displayModeControl.setAccessibilityLabel(settings.text("显示模式"))
        displayModeControl.selectedSegment = showsThumbnails ? 0 : 1
        displayModeControl.isEnabled = !freezeRowHeights && !carryingWindow
        displayModeControl.sizeToFit()

        header.setAccessibilityLabel(titleLabel.stringValue)
        header.setAccessibilityHelp(header.toolTip)
        removalHint.update(title: settings.text(removingItem ? "松开即可移除" : "拖出后松开移除"),
                           subtitle: settings.text("不会关闭窗口"), hovered: removingItem)
        removalHint.isHidden = !showsRemovalHint

        if previousIDs != windows.map(\.id) {
            var reusableRows = Dictionary(uniqueKeysWithValues: zip(previousIDs, rows))
            rows = windows.map { window in
                if let card = reusableRows.removeValue(forKey: window.id) { return card }
                let card = PinnedWindowCardView(frame: .zero)
                card.onMouseDown = { [weak self] point in self?.onMouseDown?(window.id, point) }
                card.onToggleRetention = { [weak self] in self?.onToggleRetention?(window.id) }
                card.onActivate = { [weak self] in self?.onActivate?(window.id) }
                card.onRemove = { [weak self] in self?.onRemove?(window.id) }
                return card
            }
            reusableRows.values.forEach { $0.removeFromSuperview() }
            // Reusing views must also preserve the new reading and keyboard order.
            for card in rows {
                document.addSubview(card, positioned: .below, relativeTo: insertionPlaceholder)
            }
            let existingIDs = Set(windows.map(\.id))
            rowHeights = rowHeights.filter { existingIDs.contains($0.key) }
        }
        for (window, row) in zip(windows, rows) {
            row.update(window: window, thumbnail: showsThumbnails ? thumbnails[window.id] : nil,
                       settings: settings, highlighted: window.id == highlightedID,
                       dragging: window.id == draggedID, busy: busyIDs.contains(window.id))
            if window.id == placementID { row.alphaValue = 0 }
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.recalculateKeyViewLoop()
    }

    @objc private func moveToOtherSide() {
        onMoveToOtherSide?()
    }

    @objc private func changeDisplayMode() {
        onDisplayModeChange?(displayModeControl.selectedSegment == 0 ? .thumbnails : .iconsAndTitle)
    }

    func focusFirstEntry() {
        guard let button = rows.map(\.openingButton).first(where: \.isEnabled) else { return }
        window?.makeFirstResponder(button)
    }

    private func height(for id: UUID, row: PinnedWindowCardView, width: CGFloat) -> CGFloat {
        if freezeRowHeights, let height = rowHeights[id] { return height }
        return row.preferredHeight(for: width)
    }

    override func layout() {
        super.layout()
        // Move the glass container itself so its effect and all contents travel
        // together. Layout must not reset its origin during an animation.
        if glassContainer.frame.size != bounds.size { glassContainer.setFrameSize(bounds.size) }
        if animationID == idleAnimationID {
            glassContainer.setFrameOrigin(CGPoint(x: isShown ? 0 : hiddenOffset, y: 0))
        }
        slidingContent.frame = CGRect(origin: .zero, size: bounds.size)
        shelf.frame = dockViewport.insetBy(dx: Self.outerInset, dy: Self.outerInset)
        shelfContent.frame = shelf.bounds
        let size = shelfContent.bounds.size
        header.frame = CGRect(x: 0, y: size.height - Self.headerHeight, width: size.width, height: Self.headerHeight)
        moveSideButton.frame = CGRect(x: size.width - 44, y: (Self.headerHeight - 28) / 2, width: 30, height: 28)
        let countWidth = windows.isEmpty ? 0 : max(12, ceil(countLabel.fittingSize.width))
        countLabel.frame = CGRect(x: moveSideButton.frame.minX - 8 - countWidth,
                                 y: (Self.headerHeight - 15) / 2, width: countWidth, height: 15)
        titleLabel.frame = CGRect(x: 14, y: (Self.headerHeight - 17) / 2,
                                 width: max(0, countLabel.frame.minX - 8 - 14), height: 17)
        let removalHeight = showsRemovalHint ? Self.removalHintSpace : 0
        let messageHeight = showsMessage ? Self.messageSpace : 0
        displayModeControl.frame.origin = CGPoint(x: (size.width - displayModeControl.frame.width) / 2,
            y: (Self.footerHeight - displayModeControl.frame.height) / 2)
        removalHint.frame = CGRect(x: 10, y: Self.footerHeight, width: max(0, size.width - 20), height: Self.removalHintSpace - 10)
        messageLabel.frame = CGRect(x: 16, y: Self.footerHeight + 2 + removalHeight,
                                    width: max(0, size.width - 32), height: 36)
        let previousOffset = scroll.contentView.bounds.origin
        let bottom = Self.footerHeight + removalHeight + messageHeight
        scroll.frame = CGRect(x: 10, y: bottom, width: max(0, size.width - 20),
                              height: max(0, size.height - Self.headerHeight - bottom))
        scroll.layoutSubtreeIfNeeded()
        let width = max(0, scroll.contentSize.width)
        let rowWidth = max(0, width - 4)
        let existingIndex = insertionEntryID.flatMap { id in windows.firstIndex { $0.id == id } }
        let reservesSpace = insertionIndex != nil && existingIndex == nil
        let candidates = zip(windows, rows).filter { $0.0.id != draggedID }
        let slot = min(max(0, insertionIndex ?? 0), candidates.count)
        let slotHeight = draggedID.flatMap { rowHeights[$0] }
            ?? insertionSizingCard.preferredHeight(for: rowWidth)
        let animated = isShown && window?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var candidateIndex = 0
        var placeholderFrame = CGRect.zero
        var y = Self.documentInset
        for (window, row) in zip(windows, rows) {
            let wasHidden = row.isHidden
            row.isHidden = reservesSpace && window.id == draggedID
            if row.isHidden {
                row.layer?.removeAnimation(forKey: Self.reflowAnimationKey)
                continue
            }
            if reservesSpace, candidateIndex == slot {
                placeholderFrame = CGRect(x: 2, y: y, width: rowWidth, height: slotHeight)
                y += slotHeight + Self.rowSpacing
            }
            let height = height(for: window.id, row: row, width: rowWidth)
            rowHeights[window.id] = height
            // A released item appears in its reserved slot; its old, hidden
            // position is not the start of another trip through the list.
            let destination = CGRect(x: 2, y: y, width: rowWidth, height: height)
            if let transition = modeTransition, let source = transition.frames[window.id] {
                let progress = transition.reducesMotion ? 1 : pinnedModeEase(modeProgress)
                row.frame = pinnedModeFrame(from: source, to: destination, progress: progress)
                row.setDisplayModeTransition(progress: modeProgress, reducesMotion: transition.reducesMotion)
                row.layoutSubtreeIfNeeded()
            } else {
                setReflowFrame(destination, for: row, animated: animated && !wasHidden)
            }
            y += height + Self.rowSpacing
            candidateIndex += 1
        }
        if reservesSpace, candidateIndex == slot {
            placeholderFrame = CGRect(x: 2, y: y, width: rowWidth, height: slotHeight)
            y += slotHeight + Self.rowSpacing
        }
        if insertionIndex != nil, let existingIndex { placeholderFrame = rows[existingIndex].frame }
        setReflowFrame(placeholderFrame, for: insertionPlaceholder,
                       animated: animated && insertionIndex != nil && !insertionPlaceholder.isHidden)
        insertionPlaceholder.isHidden = insertionIndex == nil
        let contentHeight = candidateIndex == 0 && !reservesSpace ? 0
            : y - Self.rowSpacing + Self.documentInset
        let targetHeight = max(contentHeight, scroll.contentSize.height)
        let documentHeight: CGFloat
        if let transition = modeTransition, !transition.reducesMotion {
            documentHeight = transition.documentHeight
                + (targetHeight - transition.documentHeight) * pinnedModeEase(modeProgress)
        } else { documentHeight = targetHeight }
        document.frame = CGRect(x: 0, y: 0, width: width, height: max(documentHeight, scroll.contentSize.height))
        let maximumOffset = max(0, document.bounds.height - scroll.contentSize.height)
        var desiredOffset = previousOffset.y
        if var transition = modeTransition {
            // Keep the same window at the top of the viewport as its height
            // changes. A real wheel/trackpad scroll still adds to that position.
            transition.scrollAdjustment += previousOffset.y - transition.lastScrollOffset
            if let anchor = transition.anchor,
               let index = windows.firstIndex(where: { $0.id == anchor.id }) {
                desiredOffset = rows[index].frame.minY + rows[index].frame.height * anchor.fraction
                    + transition.scrollAdjustment
            }
            desiredOffset = min(maximumOffset, max(0, desiredOffset))
            transition.lastScrollOffset = desiredOffset
            modeTransition = transition
        }
        scroll.contentView.scroll(to: CGPoint(x: 0, y: min(maximumOffset, max(0, desiredOffset))))
        scroll.reflectScrolledClipView(scroll.contentView)
        let emptyWidth = max(0, size.width - 48)
        emptyLabel.preferredMaxLayoutWidth = emptyWidth
        let labelHeight = ceil(emptyLabel.fittingSize.height)
        let emptyHeight = PinnedDropIconView.size + 12 + labelHeight
        let emptyBottom = scroll.frame.midY - emptyHeight / 2
        emptyLabel.frame = CGRect(x: 24, y: emptyBottom, width: emptyWidth, height: labelHeight)
        emptyIcon.frame = CGRect(x: (size.width - PinnedDropIconView.size) / 2,
                                 y: emptyBottom + labelHeight + 12,
                                 width: PinnedDropIconView.size, height: PinnedDropIconView.size)
        emptyLabel.isHidden = !windows.isEmpty || insertionIndex != nil
        emptyIcon.isHidden = emptyLabel.isHidden
        updateEmptyIconAnimation()
    }

    private func setReflowFrame(_ frame: CGRect, for view: NSView, animated: Bool) {
        guard animated, !view.frame.isEmpty, view.frame.size == frame.size,
              let layer = view.layer else {
            view.layer?.removeAnimation(forKey: Self.reflowAnimationKey)
            view.frame = frame
            return
        }
        // Pointer updates and thumbnail refreshes can lay out the same target
        // repeatedly. Leave its running animation alone until the target changes.
        guard view.frame != frame else { return }
        let source = layer.animation(forKey: Self.reflowAnimationKey) == nil
            ? layer.position : (layer.presentation()?.position ?? layer.position)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.frame = frame
        // Commit the final frame immediately for insertion hit testing and
        // scrolling. Only the rendered position travels from the current image.
        let movement = CABasicAnimation(keyPath: "position")
        movement.fromValue = NSValue(point: source)
        movement.toValue = NSValue(point: layer.position)
        movement.duration = Self.reflowDuration
        movement.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.3, 1)
        layer.add(movement, forKey: Self.reflowAnimationKey)
        CATransaction.commit()
    }

    private func finishReflowAnimations() {
        insertionPlaceholder.layer?.removeAnimation(forKey: Self.reflowAnimationKey)
        rows.forEach { $0.layer?.removeAnimation(forKey: Self.reflowAnimationKey) }
    }

    private func beginDisplayModeTransition() {
        let offset = scroll.contentView.bounds.minY
        let frames = Dictionary(uniqueKeysWithValues: zip(windows, rows).map { entry, row in
            let frame = row.layer?.animation(forKey: Self.reflowAnimationKey) == nil
                ? row.frame : (row.layer?.presentation()?.frame ?? row.frame)
            return (entry.id, frame)
        })
        let firstVisible = zip(windows, rows).first { $0.1.frame.maxY > offset }
        let anchor = firstVisible.map { entry, row in
            (id: entry.id, fraction: (offset - row.frame.minY) / max(1, row.frame.height))
        }
        rows.forEach { $0.beginDisplayModeTransition() }
        finishReflowAnimations()
        modeTransition = DisplayModeTransition(start: CACurrentMediaTime(),
            reducesMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            frames: frames, documentHeight: document.frame.height, anchor: anchor, lastScrollOffset: offset)
        modeProgress = 0
        if modeAnimation == nil {
            let link = displayLink(target: document, selector: #selector(PinnedWindowDocumentView.animationFrame(_:)))
            modeAnimation = link
            link.add(to: .main, forMode: .common)
        }
    }

    private func advanceDisplayModeTransition(_ link: CADisplayLink) {
        guard let transition = modeTransition else { return }
        modeProgress = CGFloat(min(1, max(0, (link.targetTimestamp - transition.start) / transition.duration)))
        if modeProgress >= 1 {
            finishDisplayModeTransition()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            needsLayout = true
            layoutSubtreeIfNeeded()
            CATransaction.commit()
        }
    }

    private func finishDisplayModeTransition() {
        modeAnimation?.invalidate()
        modeAnimation = nil
        guard modeTransition != nil else { return }
        modeProgress = 1
        // Complete the anchored layout before discarding the transition, so a
        // final scroll-range clamp cannot make the list jump on the last frame.
        needsLayout = true
        layoutSubtreeIfNeeded()
        rows.forEach { $0.finishDisplayModeTransition() }
        modeTransition = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { finishDisplayModeTransition() }
        updateEmptyIconAnimation()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finishReflowAnimations()
            if modeTransition?.reducesMotion == false { finishDisplayModeTransition() }
        }
        displayModeControl.updateAppearance()
        if #available(macOS 26.0, *), let container = glassContainer as? NSGlassEffectContainerView {
            container.spacing = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 0 : 56
        }
        let dark = PinnedSidebarColors.isDark(effectiveAppearance)
        scroll.scrollerKnobStyle = dark ? .light : .dark
        moveSideButton.contentTintColor = .labelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            insertionPlaceholder.layer?.backgroundColor = NSColor.controlAccentColor
                .withAlphaComponent(dark ? 0.16 : 0.10).cgColor
            insertionPlaceholder.layer?.borderColor = NSColor.controlAccentColor
                .withAlphaComponent(0.65).cgColor
        }
        emptyIcon.updateColors()
        rows.forEach { $0.updateSystemColors() }
        updateEmptyIconAnimation()
    }

    private func updateEmptyIconAnimation() {
        emptyIcon.setAnimating(isShown && window != nil && windows.isEmpty && carryingWindow
            && insertionIndex == nil
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private let idleAnimationID = UUID()

    // Pickup adds transparent drawing space, not extra drawer travel.
    private var hiddenOffset: CGFloat {
        dockSide == .left ? -dockViewport.width : dockViewport.width
    }

    func setDockSide(_ side: PinnedDockSide) {
        guard dockSide != side else { return }
        logVisibilityDiagnostic("side-change from=\(dockSide.rawValue) to=\(side.rawValue)")
        dockSide = side
        setShown(isShown, animated: false)
    }

    func setShown(_ shown: Bool, animated: Bool, completion: (() -> Void)? = nil) {
        logVisibilityDiagnostic("visibility-request shown=\(shown) animated=\(animated)")
        isShown = shown
        if !shown {
            finishDisplayModeTransition()
            finishReflowAnimations()
        }
        updateEmptyIconAnimation()
        let token = UUID()
        animationID = token
        layoutSubtreeIfNeeded()
        let destination = CGPoint(x: shown ? 0 : hiddenOffset, y: 0)
        guard animated, window?.isVisible == true,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            // Retarget the same property with zero duration to stop an active
            // animation as well as place an already hidden panel.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                glassContainer.animator().setFrameOrigin(destination)
            }
            animationID = idleAnimationID
            logVisibilityDiagnostic("visibility-set-immediately")
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = shown ? 0.22 : 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.3, 1)
            // AppKit retargets an in-flight animation from its current position.
            glassContainer.animator().setFrameOrigin(destination)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.animationID == token else {
                    self.logVisibilityDiagnostic("visibility-completion-discarded")
                    return
                }
                self.animationID = self.idleAnimationID
                self.logVisibilityDiagnostic("visibility-animation-completed")
                completion?()
            }
        }
    }

    private func logVisibilityDiagnostic(_ message: @autoclosure () -> String) {
        #if DEBUG
        let messageText = message()
        Self.diagnostics.notice("\(messageText, privacy: .public) side=\(self.dockSide.rawValue, privacy: .public) shown=\(self.isShown) windowVisible=\(self.window?.isVisible == true) bounds=\(String(describing: self.bounds), privacy: .public) drawerFrame=\(String(describing: self.glassContainer.frame), privacy: .public)")
        #endif
    }

    func insertionIndex(at screenPoint: CGPoint, excluding excludedID: UUID? = nil) -> Int {
        guard let window else { return windows.count }
        let point = document.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        if excludedID == nil, let id = insertionEntryID,
           let existing = windows.firstIndex(where: { $0.id == id }) { return existing }
        // Once space is reserved, hovering inside it must keep that slot.
        // Otherwise moving the neighbouring rows would move the target too.
        // These frames already describe the destination; the layer animation
        // must never move the insertion thresholds along with the visible rows.
        if let insertionIndex, !insertionPlaceholder.isHidden,
           insertionPlaceholder.frame.contains(point) { return insertionIndex }
        let candidates = zip(windows, rows).filter { $0.0.id != excludedID }
        return candidates.filter { point.y > $0.1.frame.midY }.count
    }

    func updateInsertionIndex(_ index: Int?) {
        guard insertionIndex != index else { return }
        insertionIndex = index
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func containsScreenPoint(_ screenPoint: CGPoint) -> Bool {
        screenRect(for: shelf).contains(screenPoint)
    }

    // The wider window is only drawing space for the carried glass. It must
    // never enlarge the actual shelf or its click-to-place region.
    private var dockViewport: CGRect {
        let width = min(dockWidth, bounds.width)
        return CGRect(x: dockSide == .left ? 0 : bounds.width - width,
                      y: 0, width: width, height: bounds.height)
    }

    func setDockWidth(_ width: CGFloat) {
        guard dockWidth != width else { return }
        dockWidth = width
        needsLayout = true
    }

    func acceptsDrop(at screenPoint: CGPoint) -> Bool {
        screenRect(for: self, rect: dockViewport).contains(screenPoint)
    }

    func previewEntryProgress(at screenPoint: CGPoint, carriedWidth: CGFloat, dockedWidth: CGFloat) -> CGFloat {
        guard isShown, window != nil else { return 0 }
        // Use the shelf's resting edge, independent of its opening animation
        // and of the preview's current scale or stretch.
        let dock = screenRect(for: self, rect: dockViewport.insetBy(dx: Self.outerInset, dy: Self.outerInset))
        let inwardDistance = dockSide == .left ? dock.maxX - screenPoint.x : screenPoint.x - dock.minX
        let approach = carriedWidth / 2 + 24
        let finish = dockedWidth / 2
        return min(1, max(0, (inwardDistance + approach) / (approach + finish)))
    }

    @discardableResult
    func hostPreview(_ preview: PinnedWindowDragPreviewView, screenFrame: CGRect,
                     screenPictureFrame: CGRect) -> Bool {
        // A sliding parent would keep moving the screenshot after the mouse
        // stops. Keep it in its floating window until the shelf is stationary.
        guard isShown, animationID == idleAnimationID,
              let window, window.frame.contains(screenFrame) else { return false }
        let frame = slidingContent.convert(window.convertFromScreen(screenFrame), from: nil)
        // Preserve the exact screenshot rectangle when moving between windows;
        // aspect-fitting here would silently undo the pointer-driven stretch.
        let picture = slidingContent.convert(window.convertFromScreen(screenPictureFrame), from: nil)
        if preview.superview !== slidingContent {
            if preview.window?.contentView === preview { preview.window?.contentView = nil }
            slidingContent.addSubview(preview, positioned: .above, relativeTo: shelf)
        }
        preview.setFrames(glass: frame, picture: picture)
        return true
    }

    func cancelPlacement() {
        placementTask?.cancel()
        placementTask = nil
        placementID = nil
        for (entry, row) in zip(windows, rows) {
            row.alphaValue = entry.id == draggedID ? 0.35 : 1
        }
    }

    func preparePlacement(_ id: UUID) {
        cancelPlacement()
        placementID = id
        if let index = windows.firstIndex(where: { $0.id == id }) { rows[index].alphaValue = 0 }
    }

    func animatePlacement(_ preview: PinnedWindowDragPreviewView, to id: UUID,
                          destination: CGRect, duration: TimeInterval = 0.22,
                          renderFrame: @escaping (CGRect, CGRect) -> Void,
                          completion: @escaping () -> Void) {
        guard let source = preview.screenFrames else { completion(); return }
        cancelPlacement()
        placementID = id
        rows.enumerated().forEach { index, row in
            if windows[index].id == id { row.alphaValue = 0 }
        }
        let targetPicture = preview.fittedPicture(in: destination)
        let targetGlass = targetPicture.insetBy(dx: -PinnedWindowDragPreviewView.inset,
                                               dy: -PinnedWindowDragPreviewView.inset)
        // Start with the shape already under the pointer. Clicking only
        // completes the move and relaxes that shape, without another stretch.
        let started = ProcessInfo.processInfo.systemUptime
        placementTask = Task { @MainActor [weak self, weak preview] in
            while !Task.isCancelled {
                guard let self, let preview else { return }
                let t = CGFloat(min(1, (ProcessInfo.processInfo.systemUptime - started) / duration))
                let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                let progress: CGFloat = reducedMotion ? 1 : t
                let remaining = 1 - progress
                let eased = 1 - remaining * remaining * remaining
                renderFrame(self.interpolate(source.glass, targetGlass, progress: eased),
                            self.interpolate(source.picture, targetPicture, progress: eased))
                let reveal = max(0, (progress - 0.75) / 0.25)
                preview.alphaValue = 1 - reveal
                if let index = self.windows.firstIndex(where: { $0.id == id }) {
                    self.rows[index].alphaValue = reveal
                }
                if progress >= 1 {
                    self.placementTask = nil
                    self.placementID = nil
                    if let index = self.windows.firstIndex(where: { $0.id == id }) {
                        self.rows[index].alphaValue = 1
                    }
                    completion()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }

    func fadeIn(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        placementID = nil
        let row = rows[index]
        row.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            row.animator().alphaValue = 1
        }
    }

    private func interpolate(_ from: CGRect, _ to: CGRect, progress: CGFloat) -> CGRect {
        CGRect(x: from.minX + (to.minX - from.minX) * progress,
               y: from.minY + (to.minY - from.minY) * progress,
               width: from.width + (to.width - from.width) * progress,
               height: from.height + (to.height - from.height) * progress)
    }

    func autoScroll(at screenPoint: CGPoint) {
        guard let y = autoScrollOffset(at: screenPoint) else { return }
        scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func canAutoScroll(at screenPoint: CGPoint) -> Bool {
        autoScrollOffset(at: screenPoint) != nil
    }

    private func autoScrollOffset(at screenPoint: CGPoint) -> CGFloat? {
        let viewport = screenRect(for: scroll)
        guard viewport.contains(screenPoint) else { return nil }
        // AppKit screen coordinates always run bottom to top, independent of
        // the scroll view's flipped setting. Document offsets run top to bottom.
        let direction: CGFloat = screenPoint.y < viewport.minY + 30 ? 1
            : (screenPoint.y > viewport.maxY - 30 ? -1 : 0)
        guard direction != 0 else { return nil }
        let maximum = max(0, document.bounds.height - scroll.contentSize.height)
        let y = min(maximum, max(0, scroll.contentView.bounds.minY + direction * 12))
        return y == scroll.contentView.bounds.minY ? nil : y
    }

    func reveal(_ id: UUID) {
        guard let index = windows.firstIndex(where: { $0.id == id }), rows.indices.contains(index) else { return }
        document.scrollToVisible(rows[index].frame.insetBy(dx: 0, dy: -6))
    }

    func cardScreenFrame(for id: UUID) -> CGRect? {
        guard let index = windows.firstIndex(where: { $0.id == id }), rows.indices.contains(index), window != nil else { return nil }
        layoutSubtreeIfNeeded()
        reveal(id)
        rows[index].layoutSubtreeIfNeeded()
        // The floating proxy has no caption. Its attachment target is the
        // fitted screenshot itself, or the compact app icon when unavailable.
        return screenRect(for: rows[index], rect: rows[index].previewRect)
    }

    private func screenRect(for view: NSView, rect: CGRect? = nil) -> CGRect {
        guard let window else { return .zero }
        return window.convertToScreen(view.convert(rect ?? view.bounds, to: nil))
    }

}

private final class PinnedShelfHeaderView: NSView {
    var onMouseDown: ((CGPoint) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("pinnedShelfHeader")
        setAccessibilityRole(.group)
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit is NSButton { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        onMouseDown?(window.convertPoint(toScreen: event.locationInWindow))
    }
}

/// A window settling into a shelf. It draws only and leaves clicks to the shelf.
@MainActor
private final class PinnedDropIconView: NSView {
    static let size: CGFloat = 56
    private let windowOutline = CAShapeLayer()
    private let tray = CAShapeLayer()
    private let animationKey = "placeWindow"

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        setAccessibilityElement(false)
        for shape in [tray, windowOutline] {
            shape.frame = bounds
            shape.fillColor = nil
            shape.strokeColor = PinnedSidebarColors.blue.cgColor
            shape.lineWidth = 1.8
            shape.lineCap = .round
            shape.lineJoin = .round
            layer?.addSublayer(shape)
        }

        // AppKit's coordinates run upward; these are the approved 56-point
        // outline reflected vertically so its downward travel is negative Y.
        let windowPath = CGMutablePath()
        windowPath.addRoundedRect(in: CGRect(x: 14, y: 26, width: 28, height: 22),
                                  cornerWidth: 4, cornerHeight: 4)
        windowPath.move(to: CGPoint(x: 14.7, y: 41.5))
        windowPath.addLine(to: CGPoint(x: 41.3, y: 41.5))
        windowPath.move(to: CGPoint(x: 19, y: 44.7))
        windowPath.addLine(to: CGPoint(x: 22, y: 44.7))
        windowOutline.path = windowPath

        let trayPath = CGMutablePath()
        trayPath.move(to: CGPoint(x: 7, y: 22))
        trayPath.addLine(to: CGPoint(x: 7, y: 13))
        trayPath.addQuadCurve(to: CGPoint(x: 12, y: 8), control: CGPoint(x: 7, y: 8))
        trayPath.addLine(to: CGPoint(x: 44, y: 8))
        trayPath.addQuadCurve(to: CGPoint(x: 49, y: 13), control: CGPoint(x: 49, y: 8))
        trayPath.addLine(to: CGPoint(x: 49, y: 22))
        tray.path = trayPath
        updateColors()
        setAnimating(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            windowOutline.strokeColor = NSColor.controlAccentColor.cgColor
            tray.strokeColor = NSColor.controlAccentColor.cgColor
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setAnimating(_ animating: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        windowOutline.transform = CATransform3DMakeTranslation(0, animating ? 0 : -12, 0)
        windowOutline.opacity = 0.92
        tray.opacity = animating ? 0.45 : 0.6
        CATransaction.commit()

        guard animating else {
            windowOutline.removeAnimation(forKey: animationKey)
            tray.removeAnimation(forKey: animationKey)
            return
        }
        // Frequent shelf updates must not restart the instruction mid-motion.
        guard windowOutline.animation(forKey: animationKey) == nil else { return }
        let duration = 3.2
        let times: [NSNumber] = [0, 0.15625, 0.375, 0.671875, 0.78125,
                                 0.78126, 0.84375, 0.9375, 1]
        let travel = CAKeyframeAnimation(keyPath: "transform.translation.y")
        travel.keyTimes = times
        travel.values = [0, 0, -12, -12, -12, 0, 0, 0, 0]
        travel.duration = duration
        travel.timingFunctions = (0..<(times.count - 1)).map { index in
            index == 1 ? CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                : CAMediaTimingFunction(name: .linear)
        }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.keyTimes = times
        fade.values = [0.92, 0.92, 0.92, 0.92, 0, 0, 0, 0.92, 0.92]
        fade.duration = duration
        let placement = CAAnimationGroup()
        placement.animations = [travel, fade]
        placement.duration = duration
        placement.repeatCount = .infinity
        let beginTime = CACurrentMediaTime()
        placement.beginTime = windowOutline.convertTime(beginTime, from: nil)
        windowOutline.add(placement, forKey: animationKey)

        let receive = CAKeyframeAnimation(keyPath: "opacity")
        receive.keyTimes = [0, 0.15625, 0.375, 0.59375, 1]
        receive.values = [0.45, 0.45, 0.85, 0.45, 0.45]
        receive.duration = duration
        receive.repeatCount = .infinity
        receive.beginTime = tray.convertTime(beginTime, from: nil)
        tray.add(receive, forKey: animationKey)
    }
}

private final class PinnedWindowDocumentView: NSView {
    var onAnimationFrame: ((CADisplayLink) -> Void)?
    override var isFlipped: Bool { true }
    @objc func animationFrame(_ link: CADisplayLink) { onAnimationFrame?(link) }
}

private func pinnedModeEase(_ progress: CGFloat) -> CGFloat {
    let t = min(1, max(0, progress))
    return 1 - pow(1 - t, 3)
}

private func pinnedModeBlend(_ progress: CGFloat) -> CGFloat {
    let t = min(1, max(0, progress))
    // Zero velocity and acceleration at both ends keep the handoff from
    // suddenly starting or ending as the two very different images overlap.
    return t * t * t * (t * (t * 6 - 15) + 10)
}

private func pinnedModeFrame(from: CGRect, to: CGRect, progress: CGFloat) -> CGRect {
    CGRect(x: from.minX + (to.minX - from.minX) * progress,
           y: from.minY + (to.minY - from.minY) * progress,
           width: from.width + (to.width - from.width) * progress,
           height: from.height + (to.height - from.height) * progress)
}

@MainActor
final class PinnedWindowCardView: NSView {
    var onMouseDown: ((CGPoint) -> Void)?
    var onToggleRetention: (() -> Void)?
    var onActivate: (() -> Void)?
    var onRemove: (() -> Void)?
    var openingButton: NSButton { openButton }
    var showsCaption = true {
        didSet {
            needsLayout = true
            updateBackground()
        }
    }
    private static let cardInset: CGFloat = 8
    private static let captionGap: CGFloat = 8
    private static let previewCornerRadius: CGFloat = 8
    private static let closedIndicatorDiameter: CGFloat = 8
    private let preview = NSImageView()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closedIndicator = NSView()
    private let closedLabel = NSTextField(labelWithString: "")
    private let openButton = PinnedOpenButton()
    private let retainButton = PinnedRetainButton()
    private var ratio: CGFloat = 16 / 10
    private var hasThumbnail = false
    private var highlighted = false
    private var showsRetention = false
    private var retained = false
    private var busy = false
    private var dragging = false
    private var hovered = false
    private var hoverTrackingArea: NSTrackingArea?
    private var closedStatus = ""
    private struct DisplayModeContent {
        let frames: [CGRect]
        let opacities: [CGFloat]
        let previewFrame: CGRect
        let previewOpacity: CGFloat
        let thumbnail: NSImage?
    }
    private var modeSource: DisplayModeContent?
    private var modeProgress: CGFloat = 1
    private var modeReducesMotion = false
    private var movingContents: [NSView] { [icon, titleLabel, closedIndicator, closedLabel, retainButton] }
    private var captionHeight: CGFloat {
        showsCaption ? (closedStatus.isEmpty ? 24 : 40) : 0
    }
    var previewRect: CGRect { hasThumbnail ? preview.frame : icon.frame }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.imageAlignment = .alignCenter
        preview.wantsLayer = true
        preview.layer?.cornerRadius = Self.previewCornerRadius
        preview.layer?.masksToBounds = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        closedIndicator.wantsLayer = true
        closedIndicator.layer?.cornerRadius = Self.closedIndicatorDiameter / 2
        closedIndicator.isHidden = true
        closedIndicator.setAccessibilityElement(false)
        closedLabel.font = .systemFont(ofSize: 11)
        closedLabel.textColor = .secondaryLabelColor
        closedLabel.isHidden = true
        openButton.isBordered = false
        openButton.setButtonType(.momentaryPushIn)
        // Its visible title and image are sibling views. AppKit cannot infer
        // button semantics from this intentionally empty native button cell.
        openButton.setAccessibilityRole(.button)
        openButton.title = ""
        openButton.focusRingType = .none
        openButton.target = self
        openButton.action = #selector(openWindow)
        openButton.onMouseDown = { [weak self] point in self?.onMouseDown?(point) }
        retainButton.isBordered = false
        retainButton.imagePosition = .imageOnly
        retainButton.setButtonType(.toggle)
        retainButton.setAccessibilityRole(.checkBox)
        // The saved model owns the image and colour. A native toggle's
        // selected drawing would add a second, misleading visual state.
        (retainButton.cell as? NSButtonCell)?.showsStateBy = []
        retainButton.target = self
        retainButton.action = #selector(toggleRetention)
        retainButton.isHidden = true
        // The screenshot passes over the app icon before fading away. Keep it
        // above the icon, while the caption and native buttons stay on top.
        for view in [icon, preview, titleLabel, closedIndicator, closedLabel] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        addSubview(openButton)
        addSubview(retainButton)
        setAccessibilityRole(.group)
        setAccessibilityElement(true)
        setAccessibilityChildren([openButton, retainButton])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(window: PinnedWindowEntry, thumbnail: NSImage?, settings: AppSettings,
                highlighted: Bool, dragging: Bool, busy: Bool = false) {
        showsRetention = true
        retained = window.isRetained
        self.busy = busy
        retainButton.state = retained ? .on : .off
        retainButton.isEnabled = !busy
        retainButton.toolTip = settings.text(retained
            ? (window.isClosed || window.combination != nil ? "取消保留后，此项会从停靠栏移除" : "取消保留后，窗口关闭时会从停靠栏移除")
            : "关闭后仍保留")
        retainButton.setAccessibilityIdentifier("pinnedRetain-\(window.id.uuidString)")
        retainButton.setAccessibilityLabel(settings.text(retained ? "取消保留" : "保留"))
        retainButton.setAccessibilityValue(NSNumber(value: retained))
        closedStatus = window.isClosed ? settings.text("已关闭") : ""
        closedIndicator.toolTip = closedStatus.isEmpty ? nil : closedStatus
        closedLabel.stringValue = closedStatus
        let openHelp = settings.text(window.combination != nil ? "恢复这组窗口" : (window.isClosed ? "点击重新打开" : "打开窗口"))
        openButton.toolTip = openHelp
        openButton.setAccessibilityHelp(openHelp)
        openButton.setAccessibilityIdentifier("pinnedOpen-\(window.id.uuidString)")
        let contextMenu = NSMenu()
        let remove = NSMenuItem(title: settings.text("从停靠栏移除"), action: #selector(removeFromShelf), keyEquivalent: "")
        remove.target = self
        remove.isEnabled = !busy
        remove.toolTip = settings.text("不会关闭窗口")
        contextMenu.autoenablesItems = false
        contextMenu.addItem(remove)
        openButton.menu = contextMenu
        updateContent(applicationName: window.combination == nil ? window.applicationName : settings.text("组合布局"), title: window.title, icon: window.icon,
                      frame: window.frame, thumbnail: thumbnail, highlighted: highlighted, dragging: dragging)
        openButton.toolTip = [window.applicationName, window.title, openHelp]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // Drag previews use the running window directly and have no controls.
    func update(window: WindowItem, thumbnail: NSImage?, highlighted: Bool, dragging: Bool) {
        showsRetention = false
        retained = false
        busy = false
        closedStatus = ""
        closedIndicator.toolTip = nil
        openButton.menu = nil
        updateContent(applicationName: window.applicationName, title: window.title, icon: window.icon,
                      frame: window.frame, thumbnail: thumbnail, highlighted: highlighted, dragging: dragging)
    }

    private func updateContent(applicationName: String, title: String, icon: NSImage?, frame: CGRect,
                               thumbnail: NSImage?, highlighted: Bool, dragging: Bool) {
        let size = thumbnail?.size ?? frame.size
        ratio = size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
            ? size.width / size.height : 16 / 10
        hasThumbnail = thumbnail != nil
        self.highlighted = highlighted
        self.dragging = dragging
        preview.image = thumbnail ?? modeSource?.thumbnail
        self.icon.image = icon
        titleLabel.stringValue = title.isEmpty ? applicationName : title
        // Keep each tooltip on its own control. A tooltip on the whole card
        // would also cover the pin button and hide its explanation.
        toolTip = nil
        titleLabel.toolTip = "\(applicationName)\n\(title)"
        preview.toolTip = nil
        self.icon.toolTip = nil
        alphaValue = dragging ? 0.35 : 1
        updateAppearance()
        let label = [applicationName, title, closedStatus].filter { !$0.isEmpty }.joined(separator: ", ")
        // The group contains two independently actionable native buttons.
        // Decorative contents are already included in the open button's label.
        setAccessibilityLabel(nil)
        openButton.setAccessibilityLabel(label)
        openButton.isEnabled = !busy
        openButton.setAccessibilityElement(showsRetention && showsCaption)
        retainButton.setAccessibilityElement(showsRetention && showsCaption)
        needsLayout = true
    }

    func preferredHeight(for width: CGFloat) -> CGFloat {
        guard hasThumbnail else { return showsCaption ? (closedStatus.isEmpty ? 44 : 52) : 48 }
        let inset = showsCaption ? Self.cardInset : 0
        let imageHeight = min(148, max(72, max(0, width - inset * 2) / ratio))
        return imageHeight + captionHeight + inset * 2
    }

    func beginDisplayModeTransition() {
        layoutSubtreeIfNeeded()
        modeSource = DisplayModeContent(frames: movingContents.map(\.frame),
            opacities: movingContents.map { $0.isHidden ? 0 : $0.alphaValue },
            previewFrame: preview.isHidden ? thumbnailFrame(in: icon.frame) : preview.frame,
            previewOpacity: preview.isHidden ? 0 : preview.alphaValue, thumbnail: preview.image)
    }

    func setDisplayModeTransition(progress: CGFloat, reducesMotion: Bool) {
        modeProgress = progress
        modeReducesMotion = reducesMotion
        needsLayout = true
    }

    func finishDisplayModeTransition() {
        modeSource = nil
        modeProgress = 1
        if !hasThumbnail { preview.image = nil }
        preview.alphaValue = 1
        movingContents.forEach { $0.alphaValue = 1 }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func thumbnailFrame(in iconFrame: CGRect) -> CGRect {
        let height = min(iconFrame.height, iconFrame.width / ratio)
        let width = height * ratio
        return CGRect(x: iconFrame.midX - width / 2, y: iconFrame.midY - height / 2,
                      width: width, height: height)
    }

    override func layout() {
        super.layout()
        preview.isHidden = !hasThumbnail
        titleLabel.isHidden = !showsCaption
        closedIndicator.isHidden = !showsCaption || closedStatus.isEmpty
        closedLabel.isHidden = closedIndicator.isHidden
        openButton.frame = bounds
        openButton.isHidden = !showsCaption || !showsRetention
        retainButton.isHidden = !showsCaption || !showsRetention
        let buttonWidth: CGFloat = showsCaption && showsRetention ? 24 : 0
        let indicatorSpacing: CGFloat = 5
        let inset = showsCaption ? Self.cardInset : 0
        // Calculate destinations at the final card height, then interpolate the
        // individual contents. Scaling the whole row would also squash text.
        let layoutHeight = modeSource == nil ? bounds.height : preferredHeight(for: bounds.width)
        // Status has its own second line, leaving long window titles readable.
        let textRight = max(0, bounds.width - inset - buttonWidth - (buttonWidth > 0 ? 5 : 1))
        if hasThumbnail {
            let viewportHeight = max(0, layoutHeight - captionHeight - inset * 2)
            let width = min(max(0, bounds.width - inset * 2), viewportHeight * ratio)
            let height = width / ratio
            let imageRect = CGRect(x: (bounds.width - width) / 2, y: inset + (viewportHeight - height) / 2,
                                   width: width, height: height)
            preview.frame = imageRect
            icon.isHidden = !showsCaption
            let captionY = inset + viewportHeight
            // The focus ring encloses the whole card, so both the screenshot
            // and its caption need space inside it, including along the left.
            icon.frame = CGRect(x: inset + 1, y: captionY + Self.captionGap, width: 16, height: 16)
            titleLabel.frame = CGRect(x: inset + 24, y: captionY + Self.captionGap,
                                      width: max(0, textRight - inset - 24), height: 16)
            retainButton.frame = CGRect(x: max(0, bounds.width - inset - 24), y: captionY + Self.captionGap - 4,
                                        width: 24, height: 24)
        } else {
            // With no screenshot there is no empty screenshot-sized card.
            // The app icon and title form one compact, readable row instead.
            icon.isHidden = false
            let iconSize = min(CGFloat(showsCaption ? 28 : 40), max(0, min(bounds.width, layoutHeight)))
            icon.frame = CGRect(x: showsCaption ? inset + 2 : (bounds.width - iconSize) / 2,
                                y: (layoutHeight - iconSize) / 2, width: iconSize, height: iconSize)
            // Centre the text that is actually visible, rather than always
            // reserving a second line for a window that is still open.
            let textHeight: CGFloat = closedStatus.isEmpty ? 16 : 31
            let titleY = max(0, (layoutHeight - textHeight) / 2)
            titleLabel.frame = CGRect(x: inset + 39, y: titleY, width: max(0, textRight - inset - 39), height: 16)
            retainButton.frame = CGRect(x: max(0, bounds.width - inset - 24), y: (layoutHeight - 24) / 2,
                                        width: 24, height: 24)
        }
        let diameter = Self.closedIndicatorDiameter
        // Align the two text lines. Keep the dot after the status so it never
        // intrudes into the app icon's column in the compact list.
        let statusWidth = min(closedLabel.fittingSize.width,
                              max(0, titleLabel.frame.width - indicatorSpacing - diameter))
        closedLabel.frame = CGRect(x: titleLabel.frame.minX,
                                  y: titleLabel.frame.maxY + 1,
                                  width: statusWidth, height: 14)
        closedIndicator.frame = CGRect(x: closedLabel.frame.maxX + indicatorSpacing,
                                       y: closedLabel.frame.midY - diameter / 2,
                                       width: diameter, height: diameter)
        if let source = modeSource {
            let targetPreview = preview.frame
            let targetIcon = icon.frame
            let progress = modeReducesMotion ? 1 : pinnedModeEase(modeProgress)
            for (index, view) in movingContents.enumerated() {
                let targetOpacity: CGFloat = view.isHidden ? 0 : 1
                view.frame = pinnedModeFrame(from: source.frames[index], to: view.frame, progress: progress)
                view.isHidden = source.opacities[index] == 0 && targetOpacity == 0
                view.alphaValue = source.opacities[index] + (targetOpacity - source.opacities[index]) * progress
            }
            if preview.image != nil {
                preview.isHidden = false
                if hasThumbnail {
                    preview.frame = pinnedModeFrame(from: source.previewFrame, to: targetPreview, progress: progress)
                    let fade = pinnedModeEase(modeReducesMotion ? modeProgress : modeProgress / 0.25)
                    preview.alphaValue = source.previewOpacity + (1 - source.previewOpacity) * fade
                } else {
                    let destination = thumbnailFrame(in: targetIcon)
                    preview.frame = pinnedModeFrame(from: source.previewFrame, to: destination,
                        progress: modeReducesMotion ? 1 : pinnedModeEase(modeProgress / 0.75))
                    // Share the last half of the 0.55-second transition. The
                    // icon first leaves its caption position, then gradually
                    // appears under the shrinking screenshot at the same center.
                    let approach = modeReducesMotion ? 1 : pinnedModeBlend(modeProgress / 0.5)
                    let fade = pinnedModeBlend(modeReducesMotion ? modeProgress : (modeProgress - 0.5) / 0.5)
                    preview.alphaValue = source.previewOpacity * (1 - fade)
                    let uncovered = 1 - source.previewOpacity
                    icon.alphaValue = source.opacities[0] + (uncovered - source.opacities[0]) * approach
                        + source.previewOpacity * fade
                    icon.setFrameOrigin(CGPoint(
                        x: icon.frame.minX + (preview.frame.midX - icon.frame.midX) * approach,
                        y: icon.frame.minY + (preview.frame.midY - icon.frame.midY) * approach))
                }
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func updateSystemColors() {
        updateAppearance()
        openButton.needsDisplay = true
        retainButton.needsDisplay = true
    }

    private func updateAppearance() {
        let dark = PinnedSidebarColors.isDark(effectiveAppearance)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            closedIndicator.layer?.backgroundColor = NSColor.systemGray.cgColor
            preview.layer?.borderColor = (highlighted ? NSColor.controlAccentColor
                : (dark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.08))).cgColor
            layer?.borderColor = (highlighted ? NSColor.controlAccentColor
                : (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.10))).cgColor
        }
        preview.layer?.borderWidth = highlighted ? 2 : 0.5
        // A missing-image item still gets the existing duplicate-pin highlight.
        layer?.borderWidth = !hasThumbnail && showsCaption && showsRetention ? (highlighted ? 1.5 : 0.5) : 0
        retainButton.image = NSImage(systemSymbolName: retained ? "pin.fill" : "pin", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        retainButton.contentTintColor = retained ? PinnedSidebarColors.blue : PinnedSidebarColors.muted
        updateBackground()
    }

    private func updateBackground() {
        let dark = PinnedSidebarColors.isDark(effectiveAppearance)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let background: NSColor
            if !showsCaption || !showsRetention {
                background = .clear
            } else if highlighted {
                background = NSColor.controlAccentColor.withAlphaComponent(dark ? 0.20 : 0.12)
            } else {
                let activeHover = hovered && !busy && !dragging
                background = (dark ? NSColor.white : NSColor.black)
                    .withAlphaComponent(activeHover ? (dark ? 0.12 : 0.10) : (dark ? 0.075 : 0.065))
            }
            layer?.backgroundColor = background.cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        hoverTrackingArea = area
        addTrackingArea(area)
        hovered = window.map { visibleRect.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        updateBackground()
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateBackground()
    }

    @objc private func openWindow() {
        guard !busy else { return }
        onActivate?()
    }

    @objc private func removeFromShelf() {
        guard !busy else { return }
        onRemove?()
    }

    @objc private func toggleRetention() {
        // The controller confirms the saved state after reading the app and
        // writing it to disk; the toggle must wait for that result.
        retainButton.state = retained ? .on : .off
        guard !busy else { return }
        onToggleRetention?()
    }

    override func mouseDown(with event: NSEvent) {
        guard !busy, let window else { return }
        onMouseDown?(window.convertPoint(toScreen: event.locationInWindow))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === retainButton || hit.isDescendant(of: retainButton) { return retainButton }
        return openButton.isHidden ? self : openButton
    }
}

/// Native Press and keyboard activation use NSButton's target/action. Mouse
/// down stays in the controller's existing click-or-drag sequence.
private final class PinnedOpenButton: NSButton {
    var onMouseDown: ((CGPoint) -> Void)?
    override var acceptsFirstResponder: Bool { isEnabled }
    override var needsPanelToBecomeKey: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        onMouseDown?(window.convertPoint(toScreen: event.locationInWindow))
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let action else { return false }
        // Use the same native target/action as keyboard activation. Return
        // whether AppKit actually delivered it, including disabled-state refusal.
        return sendAction(action, to: target)
    }

    override func keyDown(with event: NSEvent) {
        if [UInt16(36), UInt16(76), UInt16(49)].contains(event.keyCode) {
            if isEnabled, !event.isARepeat { performClick(nil) }
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        needsDisplay = true
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard window?.firstResponder === self else { return }
        NSColor.keyboardFocusIndicatorColor.setStroke()
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
        ring.lineWidth = 2
        ring.stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class PinnedRetainButton: NSButton {
    private var hovered = false
    private var hoverTrackingArea: NSTrackingArea?
    private var isMouseInteraction = false
    private var showsKeyboardFocus = false
    override var acceptsFirstResponder: Bool { isEnabled }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        hoverTrackingArea = area
        addTrackingArea(area)
        hovered = window.map { visibleRect.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        showsKeyboardFocus = result && !isMouseInteraction && NSApp.currentEvent?.type != .leftMouseDown
        needsDisplay = true
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { showsKeyboardFocus = false }
        needsDisplay = true
        return result
    }

    override func mouseDown(with event: NSEvent) {
        isMouseInteraction = true
        showsKeyboardFocus = false
        needsDisplay = true
        defer { isMouseInteraction = false }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        showsKeyboardFocus = true
        needsDisplay = true
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsKeyboardFocus, window?.firstResponder === self else { return }
        NSColor.keyboardFocusIndicatorColor.setStroke()
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        ring.lineWidth = 2
        ring.stroke()
    }
}

private final class PinnedRemovalHintView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var hovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.font = .systemFont(ofSize: 11, weight: .medium)
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        icon.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        addSubview(label)
        addSubview(subtitle)
        addSubview(icon)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(title: String, subtitle: String, hovered: Bool) {
        label.stringValue = title
        self.subtitle.stringValue = subtitle
        self.hovered = hovered
        updateAppearance()
        setAccessibilityLabel("\(title), \(subtitle)")
    }

    override func layout() {
        super.layout()
        icon.frame = CGRect(x: 13, y: bounds.midY - 10, width: 20, height: 20)
        label.frame = CGRect(x: 42, y: bounds.midY + 1, width: max(0, bounds.width - 52), height: 15)
        subtitle.frame = CGRect(x: 42, y: bounds.midY - 14, width: max(0, bounds.width - 52), height: 13)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        label.textColor = hovered ? PinnedSidebarColors.remove : .labelColor
        icon.contentTintColor = hovered ? PinnedSidebarColors.remove : PinnedSidebarColors.muted
    }
}

private enum PinnedSidebarColors {
    static var muted: NSColor { .secondaryLabelColor }
    static var blue: NSColor { .controlAccentColor }
    static var remove: NSColor { .systemRed }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
