import AppKit
import SwiftUI

private enum UsageTopic: String, CaseIterable {
    case switching, layout, multiLayout, docking

    var title: String {
        switch self {
        case .switching: "窗口切换"
        case .layout: "窗口定位"
        case .multiLayout: "快速布局"
        case .docking: "窗口停靠"
        }
    }

    var symbol: String {
        switch self {
        case .switching: "rectangle.3.group"
        case .layout: "rectangle.split.2x2"
        case .multiLayout: "rectangle.3.group.fill"
        case .docking: "sidebar.right"
        }
    }

    @MainActor func shortcut(_ settings: AppSettings) -> WindowShortcut? {
        switch self {
        case .switching: settings.shortcut
        case .layout: settings.layoutShortcut
        case .multiLayout: settings.multiLayoutShortcut
        case .docking: settings.pinShortcut
        }
    }

    @MainActor func steps(_ settings: AppSettings) -> [String] {
        let shortcut = shortcut(settings) ?? settings.layoutShortcut
        switch self {
        case .switching:
            return [settings.text("按住 %@，按 %@ 打开窗口列表", shortcut.modifierName, shortcut.keyName),
                    settings.text("再按 %@，快速切换窗口。", shortcut.keyName),
                    settings.text("松开按钮，将选中窗口置顶。")]
        case .layout:
            return [settings.text("鼠标移到窗口上，按 %@", shortcut.displayName),
                    settings.text("点击想要的位置，或按对应数字"),
                    settings.text("窗口自动移到所选位置")]
        case .multiLayout:
            return [self.shortcut(settings).map { settings.text("按 %@，在屏幕上打开布局", $0.displayName) }
                        ?? settings.text("从菜单栏打开快速布局"),
                    settings.text("拖动分隔线、点击边缘分裂，为格子选择窗口"),
                    settings.text("点击左上方的应用，显示排列好的窗口")]
        case .docking:
            return [settings.text("按 %@，点一下要添加的窗口", shortcut.displayName),
                    settings.text("把预览移到停靠栏，再点一下"),
                    settings.text("以后点击停靠项目，就能回到窗口")]
        }
    }

    var hint: String {
        switch self {
        case .switching: "也可以用方向键或鼠标选择，按 Esc 取消。"
        case .layout: "按 1–9 选择位置，空格铺满屏幕，Esc 取消。"
        case .multiLayout: "预览期间窗口保持原位。模板只保存结构；回退可尽力还原窗口。"
        case .docking: "移到屏幕边缘展开停靠栏。拖出项目可移除；点图钉可在窗口关闭后保留。"
        }
    }
}

/// Every pose is calculated from this position, so seeking and playing show the same frame.
nonisolated struct UsageTimeline {
    static let duration = 9.0
    static let stepPositions = [0.0, 0.5, 0.85]
    let progress: Double

    init(progress: Double) {
        self.progress = min(max(progress, 0), 1)
    }

    var time: Double { progress * Self.duration }
    var step: Int { min(Int(progress * 3), 2) }
    var layoutPanelOpacity: Double { transition(1.2, 1.5) * (1 - transition(5.4, 5.7)) }
    var layoutPlacement: Double { transition(6, 6.7) }
    var dockFlight: Double { transition(3.2, 4.7) }

    func transition(_ start: Double, _ end: Double) -> Double {
        let fraction = min(max((time - start) / (end - start), 0), 1)
        return fraction * fraction * (3 - 2 * fraction)
    }

    func pulse(_ start: Double, _ end: Double) -> Double {
        guard time > start, time < end else { return 0 }
        return sin((time - start) / (end - start) * .pi)
    }
}

@MainActor
struct UsageGuideView: View {
    static let windowSize = CGSize(width: 700, height: 610)
    @ObservedObject var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var topic = UsageTopic.switching
    @State private var progress = 0.0
    @State private var isPlaying = true
    @State private var replayID = 0
    private var step: Int { UsageTimeline(progress: progress).step }

    private var usesStaticSteps: Bool {
        #if DEBUG
        reduceMotion || ProcessInfo.processInfo.arguments.contains("--ui-preview-usage-static")
        #else
        reduceMotion
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(settings.text("使用说明"))
                    .font(.system(size: 23, weight: .semibold))
                Spacer()
                Text(settings.text(usesStaticSteps ? "选择功能，点击步骤查看" : "拖动进度条，查看每一步"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(UsageTopic.allCases, id: \.self) { item in
                    Button {
                        topic = item
                        progress = 0
                        isPlaying = true
                        replayID += 1
                    } label: {
                        Label(settings.text(item.title), systemImage: item.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(topic == item ? Color.accentColor.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 9))
                            .foregroundStyle(topic == item ? Color.accentColor : Color.primary)
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(topic == item ? .isSelected : [])
                    .accessibilityIdentifier("usageTopic-\(item.rawValue)")
                }
            }
            VStack(spacing: 0) {
                UsageDemo(topic: topic, progress: progress, settings: settings)
                    .frame(height: 268)
                    .accessibilityHidden(true)
                Divider()
                VStack(spacing: 8) {
                    Slider(value: Binding(get: { progress }, set: { value in
                        isPlaying = false
                        progress = value
                    }), in: 0...1, onEditingChanged: { editing in
                        if editing { isPlaying = false }
                    })
                    .accessibilityLabel(settings.text("播放进度"))
                    .accessibilityValue("\(Int((progress * 100).rounded()))%")
                    .accessibilityIdentifier("usageProgress")
                    HStack(spacing: 10) {
                        Text(topic.shortcut(settings)?.symbolDisplayName ?? settings.text("菜单栏 → 快速布局"))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel(topic.shortcut(settings)?.displayName ?? settings.text("菜单栏 → 快速布局"))
                            .accessibilityIdentifier("usageShortcut")
                        Text("0:\(String(format: "%02d", Int(progress * UsageTimeline.duration))) / 0:09")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("usageElapsed")
                        Spacer()
                        if usesStaticSteps {
                            Text(settings.text("已减少动态效果，可拖动进度或点击步骤"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("usageStaticSteps")
                        } else {
                            Button {
                                if progress >= 1 { progress = 0 }
                                isPlaying.toggle()
                            } label: {
                                Label(settings.text(isPlaying ? "暂停" : "继续播放"),
                                      systemImage: isPlaying ? "pause.fill" : "play.fill")
                                    .frame(minWidth: 70)
                            }
                            .accessibilityIdentifier("usagePlayback")
                            Button {
                                progress = 0
                                isPlaying = true
                                replayID += 1
                            } label: {
                                Label(settings.text("重播"), systemImage: "arrow.counterclockwise")
                            }
                            .accessibilityIdentifier("usageReplay")
                        }
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(12)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary, lineWidth: 1)
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(topic.steps(settings).enumerated()), id: \.offset) { index, instruction in
                    Button {
                        isPlaying = false
                        progress = UsageTimeline.stepPositions[index]
                    } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("\(index + 1)")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .frame(width: 25, height: 25)
                                .foregroundStyle(index == step ? Color.white : Color.secondary)
                                .background(index == step ? Color.accentColor : Color.primary.opacity(0.06), in: Circle())
                            Text(instruction)
                                .font(.system(size: 12))
                                .foregroundStyle(index == step ? .primary : .secondary)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(index + 1). \(instruction)")
                    .accessibilityAddTraits(index == step ? .isSelected : [])
                    .accessibilityIdentifier("usageStep\(index)")
                }
            }
            Text(settings.text(topic == .docking && !settings.pinningEnabled
                               ? "停靠栏已关闭，可在“设置 → 窗口”中开启。" : topic.hint))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("usageHint")
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: Self.windowSize.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, settings.locale)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usageGuide")
        .task(id: isPlaying && !usesStaticSteps ? replayID : nil) {
            guard isPlaying, !usesStaticSteps else { return }
            let clock = ContinuousClock()
            var previousTick = clock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(33)) }
                catch { return }
                guard !Task.isCancelled, isPlaying else { return }
                let now = clock.now
                let elapsed = previousTick.duration(to: now).components
                previousTick = now
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                let next = progress + seconds / UsageTimeline.duration
                // Each cycle starts from a clean desktop without animating the reset.
                progress = next >= 1 ? 0 : next
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            isPlaying = false
        }
        .transaction { if usesStaticSteps { $0.animation = nil } }
    }
}

/// A miniature desktop, drawn with the same native window and layout conventions as Tidest.
/// It only illustrates the actions; it never reads, captures, or moves the user's windows.
@MainActor
private struct UsageDemo: View {
    let topic: UsageTopic
    let progress: Double
    @ObservedObject var settings: AppSettings
    private let width: CGFloat = 648
    private let height: CGFloat = 268
    private var timeline: UsageTimeline { UsageTimeline(progress: progress) }

    private func blend(_ start: CGFloat, _ end: CGFloat, _ amount: Double) -> CGFloat {
        start + (end - start) * amount
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.accentColor.opacity(0.055)
            HStack(spacing: 10) {
                Image(systemName: "apple.logo")
                Text(timeline.time >= 6.4 && topic != .layout ? "Notes" : "Safari").fontWeight(.semibold)
                Spacer()
                Image(systemName: "wifi")
                Image(systemName: "battery.100percent")
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: 22)
            .background(.background.opacity(0.65))

            switch topic {
            case .switching: switching
            case .layout: layout
            case .multiLayout: multiLayout
            case .docking: docking
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .allowsHitTesting(false)
    }

    private var multiLayout: some View {
        HStack(spacing: 4) {
            demoWindow("Safari", symbol: "safari", tint: .blue)
            VStack(spacing: 4) {
                demoWindow("Finder", symbol: "folder", tint: .cyan)
                demoWindow("Notes", symbol: "note.text", tint: .orange)
            }
        }
        .padding(20)
        .overlay(alignment: .bottom) {
            Text(settings.text(timeline.step < 2 ? "预览草稿" : "应用布局"))
                .font(.system(size: 11, weight: .semibold)).padding(6)
                .background(.regularMaterial, in: Capsule())
        }
    }

    private var switching: some View {
        let time = timeline.time
        let notesSelected = (time >= 3 && time < 3.5) || time >= 4
        let released = time >= 6.4
        let listOpacity = timeline.transition(0.7, 1) * (1 - timeline.transition(6, 6.25))
        return ZStack(alignment: .topLeading) {
            demoWindow("Safari", symbol: "safari", tint: .blue)
                .frame(width: 310, height: 174).offset(x: 90, y: 50)
                .zIndex(released ? 0 : 1)
            demoWindow("Notes", symbol: "note.text", tint: .orange)
                .frame(width: 290, height: 168)
                .offset(x: 260, y: 72)
                .shadow(color: .black.opacity(released ? 0.12 : 0), radius: 10, y: 5)
                .zIndex(released ? 1 : 0)
            HStack(spacing: 8) {
                switcherItem("Safari", symbol: "safari", selected: !notesSelected)
                switcherItem("Notes", symbol: "note.text", selected: notesSelected)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary) }
            .opacity(listOpacity)
            .frame(width: width, height: height)
            .zIndex(2)
            keycap(time >= 6 ? settings.text("松开 %@", settings.shortcut.modifierName)
                   : settings.shortcut.symbolDisplayName, active: time >= 0.7 && time < 6)
                .position(x: width / 2, y: 240)
                .zIndex(3)
        }
    }

    private var layout: some View {
        let time = timeline.time
        let placement = timeline.layoutPlacement
        let pointerArrival = timeline.transition(0, 0.7)
        let selection = timeline.transition(3.1, 3.8)
        return ZStack(alignment: .topLeading) {
            demoWindow("Safari", symbol: "safari", tint: .blue)
                .frame(width: blend(290, 312, placement), height: blend(174, 230, placement))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor.opacity(timeline.transition(1, 1.2) * (1 - placement)), lineWidth: 2)
                }
                .offset(x: blend(75, 8, placement), y: blend(53, 30, placement))
            VStack(alignment: .leading, spacing: 8) {
                Text(settings.text("窗口定位")).font(.system(size: 10, weight: .semibold))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(43), spacing: 5), count: 3), spacing: 5) {
                    ForEach(QuickLayout.allCases) { item in
                        let selected = time >= 3.7 && item == .left
                        VStack(spacing: 2) {
                            GeometryReader { geometry in
                                let frame = item.frame(in: CGRect(origin: .zero, size: geometry.size).insetBy(dx: 2, dy: 2))
                                ZStack(alignment: .topLeading) {
                                    RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.06))
                                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(selected ? 1 : 0.35))
                                        .frame(width: frame.width, height: frame.height)
                                        .offset(x: frame.minX, y: frame.minY)
                                }
                            }.frame(width: 30, height: 19)
                            Text("\(item.rawValue)").font(.system(size: 8, weight: .medium))
                        }
                        .frame(width: 43, height: 36)
                        .background(selected ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            .frame(width: 139)
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary) }
            .scaleEffect(blend(0.94, 1, timeline.transition(1.2, 1.5)), anchor: .topLeading)
            .opacity(timeline.layoutPanelOpacity)
            .offset(x: 392, y: 60)
            pointer(clickStrength: timeline.pulse(5.15, 5.65))
                .offset(x: blend(blend(450, 244, pointerArrival), 425, selection),
                        y: blend(blend(195, 118, pointerArrival), 144, selection))
            keycap(time >= 3 ? "4" : settings.layoutShortcut.symbolDisplayName,
                   active: (time >= 1 && time < 1.5) || (time >= 5.2 && time < 5.6))
                .position(x: width / 2, y: 240)
        }
    }

    private var docking: some View {
        let left = settings.pinnedDockSide == .left
        let shelfX: CGFloat = left ? 12 : 540
        let windowX: CGFloat = left ? 246 : 75
        let time = timeline.time
        let flight = timeline.dockFlight
        let saved = timeline.transition(5, 5.2)
        let notesInFront = time < 5.2 || time >= 6.4
        return ZStack(alignment: .topLeading) {
            demoWindow("Safari", symbol: "safari", tint: .blue)
                .frame(width: 265, height: 168).offset(x: windowX, y: 56)
                .zIndex(notesInFront ? 0 : 1)
            demoWindow("Notes", symbol: "note.text", tint: .orange)
                .frame(width: 234, height: 147)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor.opacity(timeline.transition(0.65, 0.85)
                                      * (1 - timeline.transition(2.2, 2.45))), lineWidth: 2)
                }
                .offset(x: left ? 170 : 246, y: 80)
                .zIndex(notesInFront ? 1 : 0)
            VStack(spacing: 10) {
                HStack {
                    Image(systemName: left ? "sidebar.left" : "sidebar.right")
                    Spacer()
                    Image(systemName: "square.grid.2x2")
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                ZStack {
                    Image(systemName: "plus").foregroundStyle(.tertiary)
                        .opacity(1 - timeline.transition(2.2, 2.45))
                    Group {
                        if settings.pinnedDisplayMode == .thumbnails {
                            demoWindow("Notes", symbol: "note.text", tint: .orange)
                                .frame(width: 70, height: 51)
                        } else {
                            Label("Notes", systemImage: "note.text")
                                .font(.system(size: 10)).frame(width: 70, height: 35)
                        }
                    }
                    .opacity(saved)
                }
                .frame(width: 70, height: 51)
            }
            .padding(10)
            .frame(width: 90, height: 126, alignment: .top)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor.opacity(0.1 + 0.6 * flight * (1 - saved)))
            }
            .offset(x: shelfX, y: 59)
            .zIndex(2)
            // A separate preview moves to the shelf; the source window stays in place.
            demoWindow("Notes", symbol: "note.text", tint: .orange)
                .frame(width: blend(104, 70, flight), height: blend(68, 51, flight))
                .shadow(color: .black.opacity(0.16), radius: 7, y: 4)
                .offset(x: blend(left ? 240 : 316, shelfX + 10, flight), y: blend(115, 90, flight))
                .opacity(timeline.transition(2.2, 2.45) * (1 - saved))
                .zIndex(3)
            pointer(clickStrength: timeline.pulse(2, 2.5) + timeline.pulse(4.9, 5.35) + timeline.pulse(6.2, 6.7))
                .offset(x: blend(left ? 280 : 360, shelfX + 47, flight), y: blend(139, 111, flight))
                .zIndex(4)
            keycap(settings.pinShortcut.symbolDisplayName, active: time >= 0.55 && time < 1)
                .position(x: width / 2, y: 240)
                .zIndex(4)
        }
    }

    private func demoWindow(_ name: String, symbol: String, tint: Color) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach([Color.red, .yellow, .green].indices, id: \.self) { index in
                    Circle().fill([Color.red, .yellow, .green][index].opacity(0.75)).frame(width: 5, height: 5)
                }
                Spacer(minLength: 2)
                Text(name).font(.system(size: 9, weight: .medium)).lineLimit(1)
                Spacer(minLength: 2)
            }
            .padding(.horizontal, 9).frame(height: 22)
            .background(.primary.opacity(0.035))
            ZStack {
                tint.opacity(0.06)
                Image(systemName: symbol).font(.system(size: 25, weight: .light)).foregroundStyle(tint.opacity(0.7))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.12)) }
    }

    private func switcherItem(_ name: String, symbol: String, selected: Bool) -> some View {
        VStack(spacing: 6) {
            demoWindow(name, symbol: symbol, tint: name == "Safari" ? .blue : .orange)
                .frame(width: 126, height: 74)
            Text(name).font(.system(size: 10, weight: .medium))
        }
        .padding(7)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2) }
    }

    private func keycap(_ label: String, active: Bool) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(active ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.12)) }
    }

    private func pointer(clickStrength: Double) -> some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 21, weight: .medium))
            .foregroundStyle(.primary)
            .padding(8)
            .background(Color.accentColor.opacity(0.2 * clickStrength), in: Circle())
            .shadow(color: Color(nsColor: .windowBackgroundColor), radius: 1)
    }
}

#Preview {
    UsageGuideView(settings: .shared)
}
