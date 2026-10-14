import AppKit
import SwiftUI

struct TiledWindowsView: View {
    @ObservedObject var model: SwitcherController

    var body: some View {
        GeometryReader { geometry in
            let ratios = model.windows.map { window in
                let size = model.thumbnails[window.id]?.size ?? window.frame.size
                return size.width / size.height
            }
            let layout = WindowTileLayout(viewportSize: geometry.size, aspectRatios: ratios)
            let selectedID = model.windows.indices.contains(model.selection.index) ? model.windows[model.selection.index].id : nil
            TileScrollContainer(layout: layout, selectedIndex: model.selection.index, selectedID: selectedID,
                                selectionWasMovedByMouse: model.selectionWasMovedByMouse, hover: model.hoverWindow,
                                content: WindowTilesContent(windows: model.windows, thumbnails: model.thumbnails,
                                                            selectedIndex: model.selection.index, layout: layout,
                                                            choose: model.chooseWindow))
        }
        .accessibilityIdentifier("tiledWindows")
    }
}

private struct WindowTilesContent: View {
    let windows: [WindowItem]
    let thumbnails: [UUID: NSImage]
    let selectedIndex: Int
    let layout: WindowTileLayout
    let choose: (UUID) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                let selected = index == selectedIndex
                let frame = layout.frame(for: index)
                Button { choose(window.id) } label: {
                    WindowCard(window: window, thumbnail: thumbnails[window.id], selected: selected)
                        .frame(width: frame.width, height: frame.height)
                        .overlay {
                            if selected {
                                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 3)
                            }
                        }
                }
                .buttonStyle(.plain)
                .position(x: frame.midX, y: frame.midY)
                .accessibilityLabel("\(window.applicationName)，\(window.title)")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .help("\(window.applicationName) · \(window.title)")
                .accessibilityIdentifier("windowCard-\(index)")
            }

            if windows.indices.contains(selectedIndex) {
                let window = windows[selectedIndex]
                let frame = layout.frame(for: selectedIndex)
                // One caption outside the repeated buttons keeps their layout
                // and accessibility subtree unchanged as selection moves.
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(window.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                .frame(width: frame.width, height: 14, alignment: .leading)
                .position(x: frame.midX, y: frame.maxY + 9)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .frame(width: layout.contentSize.width, height: layout.contentSize.height)
        .preferredColorScheme(.dark)
    }
}

private struct TileScrollContainer: NSViewRepresentable {
    let layout: WindowTileLayout
    let selectedIndex: Int
    let selectedID: UUID?
    let selectionWasMovedByMouse: Bool
    let hover: (UUID) -> Void
    let content: WindowTilesContent

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> VerticalTileScrollView {
        let scroll = VerticalTileScrollView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.horizontalScrollElasticity = .none
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        scroll.documentView = hosting
        context.coordinator.hosting = hosting
        return scroll
    }

    func updateNSView(_ scroll: VerticalTileScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.hosting?.rootView = content
        coordinator.hosting?.frame = CGRect(origin: .zero, size: layout.contentSize)
        scroll.selectAtPoint = { point in
            guard let index = content.windows.indices.first(where: { layout.frame(for: $0).contains(point) }) else { return }
            hover(content.windows[index].id)
        }
        scroll.layoutSubtreeIfNeeded()

        // Thumbnail refreshes must not pull a manually scrolled list back to the
        // selection. Keyboard selection reveals its screenshot; mouse selection
        // preserves the list's current scroll position.
        let shouldReveal = (coordinator.selectedID != selectedID && !selectionWasMovedByMouse)
            || coordinator.viewportSize != layout.viewportSize
        coordinator.selectedID = selectedID
        coordinator.viewportSize = layout.viewportSize
        if shouldReveal, selectedID != nil {
            let y = layout.verticalOffset(revealing: selectedIndex, currentOffset: scroll.contentView.bounds.minY)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    final class Coordinator {
        var hosting: NSHostingView<WindowTilesContent>?
        var selectedID: UUID?
        var viewportSize: CGSize?
    }
}

final class VerticalTileScrollView: NSScrollView {
    var selectAtPoint: ((CGPoint) -> Void)?
    private var mouseTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTracking { removeTrackingArea(mouseTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking)
        mouseTracking = tracking
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard event.type == .mouseMoved, let documentView,
              contentView.bounds.contains(contentView.convert(event.locationInWindow, from: nil)) else { return }
        let location = documentView.convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: location.x, y: documentView.isFlipped ? location.y : documentView.bounds.maxY - location.y)
        selectAtPoint?(point)
    }
}
