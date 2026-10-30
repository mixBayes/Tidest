import SwiftUI

struct SwitcherView: View {
    @ObservedObject var model: SwitcherController
    @ObservedObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: SwitcherController) {
        self.model = model
        settings = model.settings
    }

    var body: some View {
        ZStack {
            Color.black.opacity(model.windows.isEmpty && model.message == nil ? 0 : 0.65)
                .contentShape(Rectangle()).onTapGesture { model.dismiss() }
            if let message = model.message {
                Text(settings.text(message)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.windows.isEmpty {
                VStack(spacing: 0) {
                if settings.displayMode == .tiled {
                    TiledWindowsView(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 48)
                } else {
                    Spacer(minLength: 0)
                    deck
                }
                if model.windows.indices.contains(model.selection.index) {
                    let current = model.windows[model.selection.index]
                    if settings.displayMode == .carousel {
                        Text(current.title).font(.system(size: 20, weight: .semibold))
                            .lineLimit(1).padding(.horizontal, 100)
                            .help(current.title)
                            .accessibilityIdentifier("selectedWindowTitle")
                    }
                    Text("\(current.applicationName) · \(model.selection.index + 1) / \(model.windows.count)\(current.minimized ? " · " + settings.text("已最小化") : "")")
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 6)
                }
                HStack(spacing: 20) {
                    arrow("chevron.left", direction: -1)
                    Text(settings.text("按 %@ 选择 · 松开 %@ 切换 · Esc 取消", settings.shortcut.keyName, settings.shortcut.modifierName))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .help(selectionHelp)
                        .accessibilityIdentifier("switcherSelectionInstructions")
                    arrow("chevron.right", direction: 1)
                }
                .padding(.top, 16).padding(.bottom, 20)
                if settings.displayMode == .carousel { Spacer(minLength: 0) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .transaction { if reduceMotion { $0.animation = nil } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("windowSwitcher")
    }

    private var deck: some View {
        GeometryReader { geometry in
            let layout = WindowRowLayout(screenWidth: geometry.size.width, aspectRatios: aspectRatios, selectedIndex: model.selection.index)
            ZStack {
                ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, window in
                    let distance = model.selection.distance(to: index)
                    let depth = abs(distance)
                    let direction = distance < 0 ? -1.0 : 1.0
                    Button { model.choose(index) } label: {
                        WindowCard(window: window, thumbnail: model.thumbnails[window.id], selected: depth == 0)
                            .frame(width: layout.cardWidths[index], height: layout.cardHeight)
                            .overlay {
                                if depth == 0 {
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 2.5)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .rotation3DEffect(.degrees(depth == 0 ? 0 : -direction * WindowRowLayout.angle), axis: (x: 0, y: 1, z: 0), perspective: WindowRowLayout.perspective)
                    .scaleEffect(depth == 0 ? 1 : WindowRowLayout.foldedScale)
                    .position(x: layout.center(for: index), y: geometry.size.height / 2)
                    .zIndex(Double(model.windows.count - depth))
                    .accessibilityLabel("\(window.applicationName)，\(window.title)")
                    .accessibilityAddTraits(depth == 0 ? [.isSelected] : [])
                    .help("\(window.applicationName) · \(window.title)")
                    .accessibilityIdentifier("windowCard-\(index)")
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.selection.index)
        }
        .frame(height: WindowRowLayout(screenWidth: model.screenWidth, aspectRatios: aspectRatios, selectedIndex: model.selection.index).deckHeight)
    }

    private var aspectRatios: [CGFloat] {
        model.windows.map { window in
            let size = model.thumbnails[window.id]?.size ?? window.frame.size
            return size.width / size.height
        }
    }

    private var selectionHelp: String {
        settings.text("长按 %@ 可连续选择窗口", settings.shortcut.keyName) + "\n"
            + settings.text(settings.displayMode == .tiled ? "上下滚动查看窗口" : "也可左右扫动或滚动鼠标滚轮选择")
    }
    private func arrow(_ icon: String, direction: Int) -> some View {
        Button { model.move(direction) } label: {
            Image(systemName: icon).font(.system(size: 12, weight: .medium)).frame(width: 42, height: 28)
                .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .accessibilityLabel(settings.text(direction == 1 ? "下一个窗口" : "上一个窗口"))
    }
}

struct WindowCard: View {
    let window: WindowItem
    let thumbnail: NSImage?
    let selected: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let thumbnail {
                    WindowThumbnailView(image: thumbnail)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .overlay(alignment: .bottomLeading) {
                            let inset = min(8, min(geometry.size.width, geometry.size.height) * 0.1)
                            let iconSize = min(28, max(0, min(geometry.size.width, geometry.size.height) - 2 * inset))
                            applicationIcon
                                .frame(width: iconSize, height: iconSize)
                                .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
                                .padding(inset)
                        }
                        .transition(.identity)
                } else {
                    let inset = min(14, min(geometry.size.width, geometry.size.height) * 0.1)
                    let iconSize = min(64, max(0, min(geometry.size.width - 2 * inset, geometry.size.height * 0.4)))
                    let titleTop = geometry.size.height / 2 + iconSize / 2 + min(12, geometry.size.height * 0.08)
                    let titleHeight = max(0, geometry.size.height - titleTop - inset)
                    applicationIcon
                        .frame(width: iconSize, height: iconSize)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    // Short previews keep the app icon; selection also has an outside caption.
                    if titleHeight >= 16 {
                        Text(window.title).font(.system(size: 13, weight: .medium))
                            .lineLimit(2).multilineTextAlignment(.center)
                            .frame(width: max(0, geometry.size.width - 2 * inset), height: titleHeight, alignment: .top)
                            .position(x: geometry.size.width / 2, y: titleTop + titleHeight / 2)
                            .transition(.identity)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .shadow(color: .black.opacity(selected ? 0.45 : 0.2), radius: selected ? 15 : 8, y: 9)
        .compositingGroup()
    }

    private var applicationIcon: some View {
        Group {
            if let icon = window.icon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "macwindow").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct WindowThumbnailView: View {
    let image: NSImage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frames: [Frame]

    init(image: NSImage) {
        self.image = image
        _frames = State(initialValue: [Frame(image: image)])
    }

    var body: some View {
        ZStack {
            ForEach(Array(frames.enumerated()), id: \.element.id) { index, frame in
                Image(nsImage: frame.image).resizable().scaledToFit()
                    .zIndex(Double(index))
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .onChange(of: image) { _, image in
            guard frames.last?.image !== image else { return }
            let next = Frame(image: image)
            if reduceMotion {
                frames = [next]
                return
            }
            // Keep every older image opaque until its replacement has fully
            // appeared. Overlapping refreshes may only discard earlier frames.
            withAnimation(.easeInOut(duration: 0.2), completionCriteria: .removed) {
                frames.append(next)
            } completion: {
                guard let index = frames.firstIndex(where: { $0.id == next.id }) else { return }
                frames.removeSubrange(..<index)
            }
        }
    }

    private struct Frame: Identifiable {
        let id = UUID()
        let image: NSImage
    }
}
