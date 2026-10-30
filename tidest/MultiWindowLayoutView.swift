import SwiftUI

@MainActor
struct MultiWindowLayoutView: View {
    @ObservedObject var controller: MultiWindowLayoutController
    @ObservedObject var settings: AppSettings
    @ObservedObject var templates: LayoutTemplateStore
    @State private var namingTemplate = false
    @State private var renaming: LayoutTemplate?
    @State private var templateName = ""
    @State private var nameError = false
    @State private var duplicateNotice: (id: UUID, layoutID: String, title: String)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var templateFrames: [String: CGRect] = [:]
    @State private var savedTemplate: LayoutTemplate?
    @State private var animateTemplate: LayoutTemplate?
    @State private var highlightedTemplate: UUID?
    @State private var templateFlight: TemplateFlight?

    private struct TemplateFlight {
        let root: LayoutRegion
        var frame: CGRect
        var opacity: Double = 1
    }

    var body: some View {
        GeometryReader { geometry in
            let area = controller.target?.overlayLayoutFrame ?? CGRect(origin: .zero, size: geometry.size)
            ZStack(alignment: .topLeading) {
                Color(red: 0.04, green: 0.06, blue: 0.09).opacity(0.40)
                LayoutDraftCanvas(controller: controller, settings: settings)
                    .frame(width: area.width, height: area.height)
                    .offset(x: area.minX, y: area.minY)
                    .disabled(controller.isSavingCombination)
                toolbar
                    .frame(width: max(0, area.width - 40), alignment: .leading)
                    .offset(x: area.minX + 20, y: area.minY + 16)
                LayoutWindowSelection(controller: controller, settings: settings, placement: pickerPlacement(in: area), area: area)
                if !controller.outcomes.isEmpty {
                    results.padding(18)
                        .frame(width: min(390, area.width - 40), height: min(450, area.height - 120))
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .position(x: area.midX, y: area.midY)
                }
                feedback
                    .frame(width: max(0, area.width - 40))
                    .offset(x: area.minX + 20, y: area.maxY - 62)
                if let duplicateNotice, let saveFrame = templateFrames["multiLayoutSaveTemplate"] {
                    let noticeWidth = min(360, max(0, area.width - 40))
                    Label(settings.text("该布局已存在：%@", duplicateNotice.title), systemImage: "info.circle")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(.regularMaterial, in: Capsule())
                        .modifier(LayoutDuplicateFeedback(trigger: duplicateNotice.id, cornerRadius: 24,
                                                          initialScale: 0.94, peakScale: 1.04))
                        .frame(width: noticeWidth)
                        .offset(x: min(max(saveFrame.midX - noticeWidth / 2, area.minX + 20),
                                       area.maxX - 20 - noticeWidth),
                                y: saveFrame.maxY + 12)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("multiLayoutTemplateToast")
                }
                if let flight = templateFlight {
                    LayoutSavePreview(root: flight.root)
                        .frame(width: flight.frame.width, height: flight.frame.height)
                        .offset(x: flight.frame.minX, y: flight.frame.minY)
                        .opacity(flight.opacity)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("multiLayoutTemplateFlight")
                }
            }
            .coordinateSpace(name: "layoutEditor")
            .onPreferenceChange(LayoutTemplateFrameKey.self) { templateFrames = $0 }
            .task(id: animateTemplate?.id) {
                guard let template = animateTemplate else { return }
                defer { templateFlight = nil; highlightedTemplate = nil }
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                let identifier = "multiLayoutTemplate-\(template.id)"
                guard let destination = templateFrames[identifier] else { return }
                templateFlight = TemplateFlight(root: template.root, frame: reduceMotion ? destination : area,
                                                opacity: reduceMotion ? 0 : 1)
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.12)
                    : .timingCurve(0.25, 0.75, 0.25, 1, duration: 0.55)) {
                    templateFlight?.frame = destination
                    templateFlight?.opacity = 1
                }
                do { try await Task.sleep(for: .milliseconds(reduceMotion ? 140 : 570)) } catch { return }
                templateFlight = nil
                highlightedTemplate = template.id
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .environment(\.locale, settings.locale)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("multiLayoutRoot")
        .alert(settings.text("清除受影响区域的窗口选择？"), isPresented: Binding(
            get: { controller.pendingEdit != nil }, set: { if !$0 { controller.pendingEdit = nil } })) {
                Button(settings.text("清除并继续"), role: .destructive) { controller.confirmEdit() }
                Button(settings.text("取消"), role: .cancel) { controller.pendingEdit = nil }
            } message: {
                Text(settings.text("只清除结构变化区域的选择，其他区域保持不变。真实窗口不会移动。"))
            }
        .sheet(isPresented: $namingTemplate, onDismiss: {
            animateTemplate = savedTemplate
            savedTemplate = nil
        }) { templateNaming }
        .task(id: duplicateNotice?.id) {
            guard duplicateNotice != nil else { return }
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            duplicateNotice = nil
        }
        .onChange(of: controller.draft?.root) { duplicateNotice = nil }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.split.2x1").foregroundStyle(.blue)
                Text(settings.text("组合布局")).font(.system(size: 14, weight: .semibold)).fixedSize()
                Divider().frame(height: 18)
                layoutChoices
                    .disabled(controller.isBusy || controller.isDraggingRegion || !controller.outcomes.isEmpty)
            }
            .frame(height: 30)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 4) {
                toolbarButton("重置", icon: "arrow.clockwise", identifier: "multiLayoutReset") {
                    controller.resetDraft()
                }
                .disabled(!controller.canResetDraft || !controller.outcomes.isEmpty)
                toolbarButton("保存模板", icon: "square.and.arrow.down", identifier: "multiLayoutSaveTemplate") {
                    beginNaming(nil)
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: LayoutTemplateFrameKey.self,
                            value: ["multiLayoutSaveTemplate": geometry.frame(in: .named("layoutEditor"))])
                    }
                }
                .disabled(controller.draft == nil || templates.errorKey != nil || !controller.outcomes.isEmpty)
                toolbarButton("保存当前组合", icon: "pin", identifier: "multiLayoutSaveCombination") {
                    controller.saveCombination()
                }
                .disabled(!controller.canSaveCombination)
                .help(settings.text(controller.draft?.isComplete == true ? "保存当前组合" : "请先为每个格子选择窗口"))
                toolbarButton("回退", icon: "arrow.uturn.backward", identifier: "multiLayoutUndoApplication") {
                    controller.undoApplication()
                }
                .disabled(!controller.undoAvailable)
            }
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .disabled(controller.isBusy || controller.isDraggingRegion)
            .fixedSize()
            HStack(spacing: 4) {
                Button(settings.text("取消")) { controller.dismiss() }
                    .buttonStyle(LayoutToolbarActionStyle(primary: false))
                    .disabled(controller.isApplying)
                    .accessibilityIdentifier("multiLayoutCancel")
                Button { controller.apply() } label: {
                    HStack(spacing: 6) {
                        if controller.isLoading || controller.isApplying {
                            ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                        }
                        Text(settings.text(controller.isApplying ? "正在应用…" : "应用布局"))
                    }
                }
                .buttonStyle(LayoutToolbarActionStyle(primary: true))
                .disabled(!controller.canApply)
                .accessibilityIdentifier("multiLayoutApply")
            }
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .fixedSize()
        }
        .buttonStyle(.borderless)
    }

    private func toolbarButton(_ title: String, icon: String, identifier: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }
            .buttonStyle(LayoutToolbarIconStyle())
            .help(settings.text(title))
            .accessibilityLabel(settings.text(title))
            .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private var feedback: some View {
        HStack {
            Spacer()
            if controller.displayInvalidated {
                HStack {
                    Text(settings.text("显示器配置已变化，请重新确认目标显示器。"))
                    Button(settings.text("重新确认显示器")) {
                        controller.reconfirmDisplay()
                    }
                }.foregroundStyle(.orange)
            } else if let message = controller.messageKey ?? templates.errorKey {
                Text(settings.text(message)).foregroundStyle(.orange)
                    .accessibilityIdentifier("multiLayoutMessage")
            } else if controller.isSavingCombination {
                Text(settings.text("正在保存组合…"))
            } else if controller.hasSmallRegions {
                Text(settings.text("格子太小，请删除格子或拖动分隔线调整大小。" )).foregroundStyle(.orange)
            } else if !controller.sizeConflicts.isEmpty {
                Text(settings.text("窗口尺寸受限，请调整区域后重试。")).foregroundStyle(.orange)
            } else if controller.canApply && !controller.choosingWindow {
                Text(settings.text("按 Enter 应用布局，按 Esc 取消。"))
            } else if !controller.choosingWindow && controller.outcomes.isEmpty {
                Text(settings.text("点击格子选窗口，拖动卡片交换或移动格子。"))
            }
            Spacer()
        }
        .font(.system(size: 12))
        .padding(10)
        .background(.regularMaterial, in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }

    private func pickerPlacement(in area: CGRect) -> LayoutWindowPickerPlacement {
        let leaf = controller.draft?.root.leaves.first { $0.region.id == controller.draft?.selectedRegion }
        let x = area.minX + (leaf?.frame.midX ?? 0.5) * area.width
        let y = area.minY + (leaf?.frame.midY ?? 0.5) * area.height
        return LayoutWindowPickerPlacement(area: area, anchor: CGPoint(x: x, y: y))
    }

    private var layoutChoices: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    layoutButton(title: settings.text("空白布局"), root: .leaf(UUID()), identifier: "multiLayoutBlank")
                    ForEach(LayoutStartingPoint.allCases) { start in
                        layoutButton(title: settings.text(start.titleKey), root: start.makeRegion(),
                                     identifier: "multiLayoutStart-\(start.rawValue)")
                    }
                    if !templates.templates.isEmpty {
                        Divider().frame(height: 18).padding(.horizontal, 4)
                        ForEach(templates.templates) { template in
                            layoutButton(title: template.name, root: template.root, identifier: "multiLayoutTemplate-\(template.id)")
                                .contextMenu {
                                    Button(settings.text("重命名")) { beginNaming(template) }
                                    Button(settings.text("删除模板"), role: .destructive) { templates.delete(template.id) }
                                }
                        }
                    }
                }
            }
            .onChange(of: duplicateNotice?.id) {
                if let duplicateNotice { proxy.scrollTo(duplicateNotice.layoutID, anchor: .center) }
            }
            .onChange(of: animateTemplate?.id) {
                if let animateTemplate { proxy.scrollTo("multiLayoutTemplate-\(animateTemplate.id)", anchor: .center) }
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: CGFloat(5 + templates.templates.count) * 38 - 4 + (templates.templates.isEmpty ? 0 : 13))
        // Leave room for the highlighted tile to expand without unclipping the horizontal list.
        .frame(height: 42)
        .padding(.vertical, -6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(settings.text("布局"))
        .accessibilityIdentifier("multiLayoutLayouts")
    }

    private func layoutButton(title: String, root: LayoutRegion, identifier: String) -> some View {
        let selected = controller.draft?.root.hasSameLayout(as: root) == true
        return Button { controller.request(.replace(root)) } label: {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    ForEach(root.leaves, id: \.region.id) { leaf in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(.primary.opacity(0.18))
                            .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(.primary.opacity(0.85), lineWidth: 1))
                            .frame(width: max(0, leaf.frame.width * geometry.size.width - 2),
                                   height: max(0, leaf.frame.height * geometry.size.height - 2))
                            .offset(x: leaf.frame.minX * geometry.size.width + 1, y: leaf.frame.minY * geometry.size.height + 1)
                    }
                }
            }.frame(width: 26, height: 20)
        }
        .buttonStyle(LayoutToolbarIconStyle(selected: selected))
        .overlay {
            if duplicateNotice?.layoutID == identifier || highlightedTemplate.map({ "multiLayoutTemplate-\($0)" }) == identifier {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: LayoutTemplateFrameKey.self,
                    value: [identifier: geometry.frame(in: .named("layoutEditor"))])
            }
        }
        .modifier(LayoutDuplicateFeedback(trigger: duplicateNotice?.layoutID == identifier ? duplicateNotice?.id : nil,
                                          cornerRadius: 7))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .id(identifier)
    }

    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(settings.text("每个窗口的执行结果")).font(.headline)
                ForEach(controller.outcomes) { outcome in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(outcome.choice.window.applicationName).font(.callout.bold())
                        Text(outcome.choice.window.title).font(.caption).lineLimit(2)
                        Label(settings.text(outcome.status.titleKey), systemImage: outcome.status.isSuccess ? "checkmark.circle" : "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(outcome.status.isSuccess ? Color.green : Color.orange)
                    }
                }
                if controller.canRetry {
                    Button(settings.text("重试失败窗口")) { controller.apply(retryFailed: true) }
                        .accessibilityIdentifier("multiLayoutRetry")
                }
                Button(settings.text("继续编辑")) { controller.continueEditing() }
                    .accessibilityIdentifier("multiLayoutContinueEditing")
            }.padding(2)
        }.disabled(controller.isApplying)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("multiLayoutResults")
    }

    private func beginNaming(_ template: LayoutTemplate?) {
        if template == nil, let root = controller.draft?.root, showDuplicateLayout(for: root) { return }
        duplicateNotice = nil
        renaming = template
        templateName = template?.name ?? templates.suggestedName { settings.text("模板 %@", String($0)) }
        nameError = false
        savedTemplate = nil
        namingTemplate = true
    }

    @discardableResult
    private func showDuplicateLayout(for root: LayoutRegion) -> Bool {
        let match: (identifier: String, title: String)
        if root.hasSameLayout(as: .leaf(UUID())) {
            match = ("multiLayoutBlank", settings.text("空白布局"))
        } else if let start = LayoutStartingPoint.allCases.first(where: { $0.makeRegion().hasSameLayout(as: root) }) {
            match = ("multiLayoutStart-\(start.rawValue)", settings.text(start.titleKey))
        } else if let template = templates.matchingTemplate(for: root) {
            match = ("multiLayoutTemplate-\(template.id)", template.name)
        } else { return false }
        namingTemplate = false
        duplicateNotice = (UUID(), match.identifier, match.title)
        return true
    }

    private var templateNaming: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(settings.text(renaming == nil ? "保存模板" : "重命名")).font(.headline)
            TextField(settings.text("模板名称"), text: $templateName)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("multiLayoutTemplateName")
            Text(settings.text("模板只保存结构和比例，不保存窗口或显示器。"))
                .font(.caption).foregroundStyle(.secondary)
            if nameError { Text(settings.text("请输入不重复的名称，最多 60 个字符。" )).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button(settings.text("取消")) { namingTemplate = false }.keyboardShortcut(.cancelAction)
                Button(settings.text("保存")) {
                    guard let root = renaming?.root ?? controller.draft?.root else { return }
                    if renaming == nil, showDuplicateLayout(for: root) { return }
                    if templates.save(name: templateName, root: root, replacing: renaming?.id) {
                        if renaming == nil { savedTemplate = templates.matchingTemplate(for: root) }
                        namingTemplate = false
                    }
                    else { nameError = true }
                }.accessibilityIdentifier("multiLayoutConfirmSaveTemplate")
            }
        }.padding(24).frame(width: 400)
    }
}

private struct LayoutTemplateFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

@MainActor
private struct LayoutDuplicateFeedback: ViewModifier {
    let trigger: UUID?
    let cornerRadius: CGFloat
    var initialScale: CGFloat = 1
    var peakScale: CGFloat = 1.12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationTrigger = false

    private struct Values {
        var scale: CGFloat = 1
        var haloProgress: Double = 1
    }

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: Values(), trigger: animationTrigger) { content, value in
                content
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(Color.accentColor, lineWidth: 1.5)
                            .scaleEffect(1 + value.haloProgress * 0.24)
                            .opacity(reduceMotion ? 0 : (1 - value.haloProgress) * 0.4)
                            .blur(radius: 0.5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .scaleEffect(reduceMotion ? 1 : value.scale)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    MoveKeyframe(initialScale)
                    CubicKeyframe(peakScale, duration: 0.1)
                    SpringKeyframe(1, duration: 0.3, spring: .init(duration: 0.3, bounce: 0.25))
                }
                KeyframeTrack(\.haloProgress) {
                    MoveKeyframe(0)
                    LinearKeyframe(1, duration: 0.4)
                }
            }
            .onChange(of: trigger, initial: true) { _, value in
                guard value != nil, !reduceMotion else { return }
                animationTrigger.toggle()
            }
    }
}

@MainActor
private struct LayoutToolbarIconStyle: ButtonStyle {
    var selected = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(selected ? Color.accentColor : .white)
            .frame(width: 34, height: 30)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.accentColor.opacity(0.2) : .clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(.white.opacity(isEnabled ? (configuration.isPressed ? 0.16 : (hovered ? 0.08 : 0)) : 0))
                    }
            }
            .opacity(isEnabled ? 0.95 : 0.35)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

@MainActor
private struct LayoutToolbarActionStyle: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: primary ? .semibold : .medium))
            .foregroundStyle(.white.opacity(isEnabled ? 0.95 : 0.4))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(primary ? Color.accentColor.opacity(isEnabled ? 1 : 0.22) : .clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.white.opacity(isEnabled ? (configuration.isPressed ? 0.16 : (hovered ? 0.08 : 0)) : 0))
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// The same geometry selects the drag target and projects its on-line hint.
private struct LayoutDividerGeometry: Identifiable {
    static let resizeDistance: CGFloat = 36
    static let buttonRadius: CGFloat = 44
    static let handleRadius: CGFloat = 18
    let id: UUID
    let axis: LayoutSplitAxis
    let frame: CGRect
    let ratio: Double

    init?(_ placement: LayoutRegion.Placement, size: CGSize) {
        guard case .split(let id, let axis, let ratio, _, _) = placement.region else { return nil }
        self.id = id
        self.axis = axis
        self.ratio = ratio
        frame = CGRect(x: placement.frame.minX * size.width, y: placement.frame.minY * size.height,
                       width: placement.frame.width * size.width, height: placement.frame.height * size.height)
    }

    var vertical: Bool { axis == .columns }
    var position: CGFloat { vertical ? frame.minX + frame.width * ratio : frame.minY + frame.height * ratio }

    func distance(to point: CGPoint) -> CGFloat {
        abs((vertical ? point.x : point.y) - position)
    }

    func translatedRatio(_ translation: CGSize) -> Double {
        ratio + (vertical ? translation.width / frame.width : translation.height / frame.height)
    }

    static func hovered(in root: LayoutRegion, size: CGSize, point: CGPoint) -> Self? {
        let leaves = root.leaves.map {
            CGRect(x: $0.frame.minX * size.width, y: $0.frame.minY * size.height,
                   width: $0.frame.width * size.width, height: $0.frame.height * size.height)
        }
        guard let leaf = leaves.first(where: { $0.contains(point) }) else { return nil }
        let buttons = [CGPoint(x: leaf.minX, y: leaf.midY), CGPoint(x: leaf.maxX, y: leaf.midY),
                       CGPoint(x: leaf.midX, y: leaf.minY), CGPoint(x: leaf.midX, y: leaf.maxY)]
        guard !buttons.contains(where: { hypot(point.x - $0.x, point.y - $0.y) <= buttonRadius }) else { return nil }
        return root.placements().compactMap { Self($0, size: size) }.filter {
            let along = $0.vertical ? point.y : point.x
            let start = $0.vertical ? $0.frame.minY : $0.frame.minX
            let end = $0.vertical ? $0.frame.maxY : $0.frame.maxX
            return along >= start && along <= end && $0.distance(to: point) <= resizeDistance
        }.min { $0.distance(to: point) < $1.distance(to: point) }
    }
}

@MainActor
private struct LayoutDraftCanvas: View {
    @ObservedObject var controller: MultiWindowLayoutController
    @ObservedObject var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var splitOrigin: SplitOrigin?
    @State private var holdingSplitButton = false
    @State private var resizeOrigin: LayoutDividerGeometry?
    @State private var cellDrag: CellDrag?
    @GestureState private var draggingCard = false
    private let highlight = Color(red: 0.40, green: 0.71, blue: 1)

    private struct CellDrag {
        let id = UUID()
        let source: UUID
        let original: MultiWindowLayoutDraft
        let grabOffset: CGSize
        var location: CGPoint
        var target: LayoutRegionDropTarget?
        var isSettling = false
    }

    private var dragAnimation: Animation? {
        reduceMotion ? nil : .timingCurve(0.3, 0, 0.2, 1, duration: 0.26)
    }

    private struct SplitOrigin {
        let id = UUID()
        let regionID: UUID
        let edge: LayoutSplitEdge
    }

    private var splittingRegion: LayoutRegion.Placement? {
        guard let splitOrigin,
              let placement = controller.draft?.root.placements().first(where: { $0.region.id == splitOrigin.regionID }),
              case .split = placement.region else { return nil }
        return placement
    }

    private var hoveredRegion: UUID? {
        guard cellDrag == nil, let pointer = controller.pointer,
              !controller.isApplying, controller.outcomes.isEmpty else { return nil }
        return controller.draft?.root.leaves.first { $0.frame.contains(pointer) }?.region.id
    }

    private func resizeTarget(in size: CGSize) -> LayoutDividerGeometry? {
        guard let draft = controller.draft, !controller.isApplying, controller.outcomes.isEmpty,
              !controller.choosingWindow, splittingRegion == nil, cellDrag == nil else { return nil }
        if let resizeOrigin {
            return draft.root.placements().first { $0.region.id == resizeOrigin.id }
                .flatMap { LayoutDividerGeometry($0, size: size) }
        }
        guard let pointer = controller.pointer else { return nil }
        return LayoutDividerGeometry.hovered(in: draft.root, size: size,
                                              point: CGPoint(x: pointer.x * size.width, y: pointer.y * size.height))
    }

    var body: some View {
        GeometryReader { geometry in
            if let draft = controller.draft {
                let resizeTarget = resizeTarget(in: geometry.size)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(draft.root.leaves.enumerated()), id: \.element.region.id) { index, leaf in
                        region(leaf, index: index, size: geometry.size)
                    }
                    ForEach(draft.root.placements(), id: \.region.id) { placement in
                        if let divider = LayoutDividerGeometry(placement, size: geometry.size),
                           placement.region.id != splittingRegion?.region.id {
                            dividerControl(divider, active: resizeTarget?.id == divider.id)
                        }
                    }
                    // Shared edges keep one continuous baseline. Split controls
                    // grow inward from it only when the pointer approaches a guide.
                    boundary(vertical: false, origin: .zero, length: geometry.size.width, size: geometry.size)
                    boundary(vertical: false, origin: CGPoint(x: 0, y: geometry.size.height), length: geometry.size.width, size: geometry.size)
                    boundary(vertical: true, origin: .zero, length: geometry.size.height, size: geometry.size)
                    boundary(vertical: true, origin: CGPoint(x: geometry.size.width, y: 0), length: geometry.size.height, size: geometry.size)
                    ForEach(draft.root.placements(), id: \.region.id) { placement in
                        if case .split(_, let axis, let ratio, _, _) = placement.region,
                           placement.region.id != splittingRegion?.region.id {
                            let rect = placement.frame
                            let vertical = axis == .columns
                            boundary(vertical: vertical,
                                     origin: CGPoint(x: (rect.minX + (vertical ? rect.width * ratio : 0)) * geometry.size.width,
                                                     y: (rect.minY + (vertical ? 0 : rect.height * ratio)) * geometry.size.height),
                                     length: vertical ? rect.height * geometry.size.height : rect.width * geometry.size.width,
                                     size: geometry.size,
                                     resizeTarget: resizeTarget?.id == placement.region.id ? resizeTarget : nil)
                        }
                    }
                    if let placement = splittingRegion, let origin = splitOrigin,
                       case .split(_, let axis, let ratio, _, _) = placement.region {
                        LayoutSplitReveal(axis: axis, edge: origin.edge, ratio: ratio, highlight: highlight,
                                          tracingCompleted: {
                            if splitOrigin?.id == origin.id { holdingSplitButton = false }
                        }, completed: {
                            if splitOrigin?.id == origin.id { splitOrigin = nil }
                        })
                        .frame(width: placement.frame.width * geometry.size.width,
                               height: placement.frame.height * geometry.size.height)
                        .offset(x: placement.frame.minX * geometry.size.width, y: placement.frame.minY * geometry.size.height)
                        .id(origin.id)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .allowsHitTesting(splittingRegion == nil)
                .onChange(of: resizeTarget?.id) { _, _ in updateResizeCursor(resizeTarget) }
                .onChange(of: controller.pointer) { _, _ in
                    if resizeTarget != nil { updateResizeCursor(resizeTarget) }
                }
                .onDisappear { if resizeTarget != nil { NSCursor.arrow.set() } }
                .opacity(cellDrag == nil ? 1 : 0)
                .overlay(alignment: .topLeading) {
                    if let drag = cellDrag {
                        dragOverlay(drag, size: geometry.size)
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        .coordinateSpace(name: "layoutCanvas")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("multiLayoutCanvas")
        .onChange(of: controller.draft?.root) { _, _ in
            if splittingRegion == nil { splitOrigin = nil }
            endCellDrag()
        }
        .onChange(of: controller.target?.id) { _, _ in
            splitOrigin = nil
            resizeOrigin = nil
            endCellDrag()
        }
        .onChange(of: draggingCard) { _, active in
            if !active && cellDrag?.isSettling != true { endCellDrag() }
        }
        .onChange(of: controller.isPresented) { _, presented in if !presented { endCellDrag() } }
        .onChange(of: controller.displayInvalidated) { _, invalid in if invalid { endCellDrag() } }
        .onChange(of: controller.isApplying) { _, applying in if applying { endCellDrag() } }
        .onChange(of: controller.choosingWindow) { _, choosing in if choosing { endCellDrag() } }
        .onDisappear { endCellDrag() }
        .onChange(of: controller.isPresented) { _, presented in
            if !presented { resizeOrigin = nil }
        }
        .onChange(of: reduceMotion) { _, reduced in if reduced { splitOrigin = nil } }
    }

    private func region(_ leaf: LayoutRegion.Placement, index: Int, size: CGSize) -> some View {
        let choice = controller.draft?.assignments[leaf.region.id].flatMap { id in controller.windows.first { $0.id == id } }
        let hovered = hoveredRegion == leaf.region.id && !controller.isApplying && controller.outcomes.isEmpty
        let revealing = splittingRegion?.region.leafIDs.contains(leaf.region.id) == true
        let showingControls = hovered && !controller.choosingWindow && splittingRegion == nil && resizeOrigin == nil && cellDrag == nil
        let width = leaf.frame.width * size.width
        let height = leaf.frame.height * size.height
        let compact = height < 240 || width < 240
        let cardWidth = min(300, max(0, width - 80))
        let cardHeight: CGFloat = compact ? 32 : 160
        let canDelete = (controller.draft?.root.leafIDs.count ?? 0) > 1
        let canClear = controller.draft?.assignments[leaf.region.id] != nil
        let controlsWidth: CGFloat = CGFloat((canDelete ? 1 : 0) + (canClear ? 1 : 0)) * 28
        return ZStack {
            Button { controller.selectRegion(leaf.region.id) } label: {
                Rectangle().fill(hovered ? highlight.opacity(0.22) : Color.white.opacity(0.055))
                    .opacity(revealing ? 0 : 1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(settings.text("区域 %@", String(index + 1)) + ": " + (choice?.window.title ?? settings.text("选择窗口")))
            .accessibilityIdentifier("multiLayoutRegion-\(index)")

            ZStack(alignment: .topTrailing) {
                Button { controller.selectRegion(leaf.region.id) } label: {
                    if let draft = controller.draft {
                        cardFace(for: leaf.region.id, index: index, draft: draft,
                                 frame: CGSize(width: cardWidth, height: cardHeight),
                                 emphasized: hovered, controlsWidth: controlsWidth)
                    }
                }
                .buttonStyle(.plain).focusable(false).accessibilityHidden(true)
                .highPriorityGesture(cardDrag(from: leaf.region.id, size: size),
                                     including: controller.choosingWindow ? .none : .all)
                .help(settings.text("拖到格子中间交换窗口，拖到屏幕边缘移动格子"))
                HStack(spacing: 0) {
                    if canClear {
                        Button { controller.clearWindow(in: leaf.region.id) } label: {
                            Image(systemName: "xmark.circle")
                                .frame(width: 28, height: 28).contentShape(Rectangle())
                        }
                        .help(settings.text("清除窗口选择"))
                        .accessibilityLabel(settings.text("清除窗口选择"))
                        .accessibilityIdentifier("multiLayoutClear-\(index)")
                    }
                    if canDelete {
                        Button { controller.deleteRegion(leaf.region.id) } label: {
                            Image(systemName: "trash")
                                .frame(width: 28, height: 28).contentShape(Rectangle())
                        }
                        .help(settings.text("删除格子"))
                        .accessibilityLabel(settings.text("删除格子"))
                        .accessibilityIdentifier("multiLayoutDelete-\(index)")
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .buttonStyle(.plain)
                .padding(compact ? 2 : 5)
                .opacity(showingControls ? 1 : 0)
                .allowsHitTesting(showingControls)
                .accessibilityHidden(!showingControls)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: showingControls)
            }
            .frame(width: cardWidth, height: cardHeight)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("multiLayoutCard-\(index)")
            .opacity(revealing ? 0 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: revealing)
        }
        .frame(width: width, height: height)
        .disabled(controller.isApplying || !controller.outcomes.isEmpty)
        .offset(x: leaf.frame.minX * size.width, y: leaf.frame.minY * size.height)
    }

    private func cardFace(for region: UUID, index: Int, draft: MultiWindowLayoutDraft,
                          frame: CGSize, emphasized: Bool, controlsWidth: CGFloat) -> some View {
        let compact = frame.height == 32
        let choice = draft.assignments[region].flatMap { id in controller.windows.first { $0.id == id } }
        return Group {
            if compact {
                Text("\(index + 1) · " + (choice?.window.applicationName ?? settings.text("选择窗口")))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.trailing, max(0, controlsWidth - 4))
                    .padding(.horizontal, 8).frame(maxWidth: .infinity).frame(height: 32)
            } else {
                VStack(spacing: 6) {
                    Text(settings.text("区域 %@", String(index + 1)))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(emphasized ? 0.95 : 0.75)).padding(.horizontal, 24)
                    if let choice {
                        if let icon = choice.window.icon { Image(nsImage: icon).resizable().scaledToFit().frame(width: 36, height: 36) }
                        Text(choice.window.applicationName).font(.system(size: 16, weight: .semibold))
                            .lineLimit(1).truncationMode(.tail)
                        Text(choice.window.title).font(.system(size: 12)).lineLimit(2)
                            .truncationMode(.tail)
                            .foregroundStyle(.white.opacity(emphasized ? 0.95 : 0.8))
                    } else {
                        Image(systemName: "macwindow.badge.plus").font(.system(size: 24, weight: .light))
                        Text(settings.text(draft.assignments[region] == nil ? "选择窗口" : "窗口已失效，请重新选择。"))
                            .font(.system(size: 14, weight: .medium))
                    }
                    if controller.sizeConflicts.contains(region) {
                        Text(settings.text("窗口尺寸受限，请调整区域后重试。" )).font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(10).frame(maxWidth: .infinity)
            }
        }
        .frame(width: frame.width, height: frame.height)
        .foregroundStyle(.white)
        .background {
            let shape = RoundedRectangle(cornerRadius: compact ? 8 : 14)
            shape.fill(.regularMaterial)
            shape.fill(Color(red: 0.24, green: 0.34, blue: 0.48).opacity(emphasized ? 0.98 : 0))
            shape.strokeBorder(emphasized ? highlight.opacity(0.85) : .white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(emphasized ? 0.3 : 0.12), radius: 16, y: 5)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: emphasized)
        .contentShape(Rectangle())
    }

    private func dropTarget(at point: CGPoint, from source: UUID, size: CGSize) -> LayoutRegionDropTarget? {
        guard let root = controller.draft?.root,
              let target = LayoutRegionDropTarget.hitTest(point, in: size, root: root, source: source),
              controller.previewDrop(from: source, to: target) != nil else { return nil }
        return target
    }

    private func cardFrame(in leaf: CGRect, size: CGSize) -> CGRect {
        let width = leaf.width * size.width
        let height = leaf.height * size.height
        let cardWidth = min(300, max(0, width - 80))
        let cardHeight: CGFloat = height < 240 || width < 240 ? 32 : 160
        return CGRect(x: leaf.midX * size.width - cardWidth / 2,
                      y: leaf.midY * size.height - cardHeight / 2, width: cardWidth, height: cardHeight)
    }

    private func cardDrag(from source: UUID, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("layoutCanvas"))
            .updating($draggingCard) { _, active, _ in active = true }
            .onChanged { value in
                guard !controller.isApplying, controller.outcomes.isEmpty, !controller.choosingWindow,
                      !controller.displayInvalidated, splittingRegion == nil, resizeOrigin == nil,
                      cellDrag?.isSettling != true, let draft = controller.draft else { return }
                if var drag = cellDrag {
                    drag.location = value.location
                    drag.target = dropTarget(at: value.location, from: source, size: size)
                    cellDrag = drag
                } else if let leaf = draft.root.leaves.first(where: { $0.region.id == source }) {
                    let frame = cardFrame(in: leaf.frame, size: size)
                    cellDrag = CellDrag(source: source, original: draft,
                                        grabOffset: CGSize(width: frame.midX - value.startLocation.x,
                                                           height: frame.midY - value.startLocation.y),
                                        location: value.location,
                                        target: dropTarget(at: value.location, from: source, size: size))
                }
                if !controller.isDraggingRegion { controller.isDraggingRegion = true }
                NSCursor.closedHand.set()
            }
            .onEnded { value in
                guard var drag = cellDrag, drag.source == source, !drag.isSettling else { return }
                drag.location = value.location
                drag.target = dropTarget(at: value.location, from: source, size: size)
                drag.isSettling = true
                let ending = drag
                NSCursor.arrow.set()
                // Keep the original cards mounted until the floating card has
                // landed. Committing first would replace their contents mid-flight.
                withAnimation(dragAnimation, completionCriteria: .removed) {
                    cellDrag = ending
                } completion: {
                    guard cellDrag?.id == ending.id else { return }
                    if let target = ending.target { controller.dropRegion(source, to: target) }
                    endCellDrag()
                }
            }
    }

    private func endCellDrag() {
        if cellDrag != nil { NSCursor.arrow.set() }
        cellDrag = nil
        if controller.isDraggingRegion { controller.isDraggingRegion = false }
    }

    private func dragOverlay(_ drag: CellDrag, size: CGSize) -> some View {
        let preview = drag.target.flatMap { drag.original.previewingDrop(from: drag.source, to: $0) } ?? drag.original
        let leaves = preview.root.leaves
        let placements = preview.root.placements()
        return ZStack(alignment: .topLeading) {
            // The same screen tint and card faces remain throughout the drag.
            Color.white.opacity(0.055)
            Rectangle().strokeBorder(.white.opacity(0.25), lineWidth: 1)
            ForEach(drag.original.root.placements(), id: \.region.id) { original in
                if let current = placements.first(where: { $0.region.id == original.region.id }),
                   case .split(_, let axis, let ratio, _, _) = current.region {
                    let rect = current.frame
                    let from = CGPoint(x: (rect.minX + (axis == .columns ? rect.width * ratio : 0)) * size.width,
                                       y: (rect.minY + (axis == .rows ? rect.height * ratio : 0)) * size.height)
                    let to = CGPoint(x: axis == .columns ? from.x : rect.maxX * size.width,
                                     y: axis == .rows ? from.y : rect.maxY * size.height)
                    LayoutDragDivider(from: from, to: to)
                        .stroke(.white.opacity(0.25), lineWidth: 1)
                        .animation(dragAnimation, value: drag.target)
                }
            }
            ForEach(drag.original.root.leafIDs, id: \.self) { id in
                if let leaf = leaves.first(where: { $0.region.id == id }) {
                    let targeted = drag.target == .swap(id) || (id == drag.source && isEdgeDrop(drag.target))
                    Rectangle().fill(highlight.opacity(targeted ? 0.17 : 0))
                        .overlay {
                            Rectangle().inset(by: 2).strokeBorder(highlight.opacity(targeted ? 0.95 : 0), lineWidth: 2)
                                .shadow(color: highlight.opacity(targeted ? 0.55 : 0), radius: 10)
                        }
                        .frame(width: leaf.frame.width * size.width, height: leaf.frame.height * size.height)
                        .position(x: leaf.frame.midX * size.width, y: leaf.frame.midY * size.height)
                        .animation(dragAnimation, value: drag.target)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(settings.text(drag.target == .swap(id) ? "松手交换窗口" : "松手移动格子"))
                        .accessibilityIdentifier("multiLayoutDropTarget-\(id)")
                        .accessibilityHidden(!targeted)
                }
            }
            ForEach(Array(drag.original.root.leaves.enumerated()), id: \.element.region.id) { index, origin in
                dragCard(origin, index: index, drag: drag, preview: preview, size: size)
            }
            dragHint(drag, size: size)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("multiLayoutDragPreview")
    }

    private func isEdgeDrop(_ target: LayoutRegionDropTarget?) -> Bool {
        if case .move = target { return true }
        return false
    }

    private func dragCard(_ origin: LayoutRegion.Placement, index: Int, drag: CellDrag,
                          preview: MultiWindowLayoutDraft, size: CGSize) -> some View {
        let source = origin.region.id == drag.source
        let floating = source && !drag.isSettling
        let destination: UUID
        if case .swap(let other) = drag.target {
            destination = source ? other : (origin.region.id == other ? drag.source : origin.region.id)
        } else { destination = origin.region.id }
        let leaves = preview.root.leaves
        let placement = leaves.first { $0.region.id == destination } ?? origin
        let frame = cardFrame(in: floating ? origin.frame : placement.frame, size: size)
        let center = floating
            ? CGPoint(x: drag.location.x + drag.grabOffset.width, y: drag.location.y + drag.grabOffset.height)
            : CGPoint(x: frame.midX, y: frame.midY)
        let canClear = drag.original.assignments[origin.region.id] != nil
        let controlsWidth = CGFloat((drag.original.root.leafIDs.count > 1 ? 1 : 0) + (canClear ? 1 : 0)) * 28
        let displayIndex = floating ? index : (leaves.firstIndex { $0.region.id == destination } ?? index)
        return cardFace(for: origin.region.id, index: displayIndex, draft: drag.original, frame: frame.size,
                        emphasized: source || drag.target == .swap(origin.region.id), controlsWidth: controlsWidth)
            .scaleEffect(floating ? 1.015 : 1)
            .shadow(color: .black.opacity(floating ? 0.2 : 0), radius: 20, y: 8)
            .position(center)
            .animation(source && !drag.isSettling ? nil : dragAnimation, value: drag.target)
            .animation(dragAnimation, value: drag.isSettling)
            .zIndex(source ? 1 : 0)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(drag.original.assignments[origin.region.id].flatMap { id in
                controller.windows.first { $0.id == id }?.window.title
            } ?? settings.text("空格子"))
            .accessibilityIdentifier("multiLayoutDragCard-\(index)")
    }

    private func dragHint(_ drag: CellDrag, size: CGSize) -> some View {
        let hint: String
        switch drag.target {
        case .swap: hint = "松手交换窗口"
        case .move: hint = "松手移动格子"
        case nil: hint = "拖到格子中间交换，拖到屏幕边缘移动"
        }
        return Text(settings.text(hint)).font(.system(size: 12)).multilineTextAlignment(.center)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .foregroundStyle(.white)
            .frame(maxWidth: 290)
            .position(x: min(max(150, drag.location.x), max(150, size.width - 150)),
                      y: min(max(24, drag.location.y + drag.grabOffset.height + 108), max(24, size.height - 24)))
            .opacity(drag.isSettling ? 0 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: drag.isSettling)
            .accessibilityIdentifier("multiLayoutDragHint")
    }

    private func boundary(vertical: Bool, origin: CGPoint, length: CGFloat, size: CGSize,
                          resizeTarget: LayoutDividerGeometry? = nil) -> some View {
        let pointer = controller.pointer.map { CGPoint(x: $0.x * size.width - origin.x, y: $0.y * size.height - origin.y) }
        let resizeCenter = resizeTarget.flatMap { _ in pointer.map { min(length, max(0, vertical ? $0.y : $0.x)) } }
        return LayoutBoundaryView(vertical: vertical, length: length,
                           tabs: boundaryTabs(vertical: vertical, origin: origin, length: length, size: size),
                           hoveredRegion: hoveredRegion,
                           pointer: pointer,
                           showsControls: !controller.choosingWindow && !controller.isApplying && controller.outcomes.isEmpty && splittingRegion == nil && resizeOrigin == nil && cellDrag == nil,
                           heldRegion: holdingSplitButton && splittingRegion != nil ? splitOrigin?.regionID : nil,
                           heldEdge: holdingSplitButton && splittingRegion != nil ? splitOrigin?.edge : nil,
                           resizeCenter: resizeCenter, isResizing: resizeOrigin != nil,
                           highlight: highlight,
                           label: settings.text(vertical ? "垂直分裂" : "水平分裂")) { id, edge in
            // Capture the actual edge before the model replaces this leaf.
            splitOrigin = reduceMotion ? nil : SplitOrigin(regionID: id, edge: edge)
            holdingSplitButton = !reduceMotion
            controller.splitRegion(id, edge: edge)
            if splittingRegion == nil { splitOrigin = nil }
        }
        .offset(x: origin.x - (vertical ? 32 : 0), y: origin.y - (vertical ? 0 : 32))
    }

    private func boundaryTabs(vertical: Bool, origin: CGPoint, length: CGFloat, size: CGSize) -> [LayoutBoundaryView.Tab] {
        (controller.draft?.root.leaves ?? []).enumerated().compactMap { index, leaf in
            let rect = CGRect(x: leaf.frame.minX * size.width, y: leaf.frame.minY * size.height,
                              width: leaf.frame.width * size.width, height: leaf.frame.height * size.height)
            let line = vertical ? origin.x : origin.y
            let near = vertical ? rect.minX : rect.minY
            let far = vertical ? rect.maxX : rect.maxY
            let start = vertical ? rect.minY - origin.y : rect.minX - origin.x
            let end = vertical ? rect.maxY - origin.y : rect.maxX - origin.x
            guard start >= -0.5, end <= length + 0.5 else { return nil }
            let inward: CGFloat
            if abs(line - near) < 0.5 { inward = 1 }
            else if abs(line - far) < 0.5 { inward = -1 }
            else { return nil }
            return LayoutBoundaryView.Tab(regionID: leaf.region.id, index: index,
                                          edge: vertical ? (inward > 0 ? .left : .right) : (inward > 0 ? .top : .bottom),
                                          start: start, end: end, inward: inward)
        }
    }

    private func dividerControl(_ divider: LayoutDividerGeometry, active: Bool) -> some View {
        let vertical = divider.vertical
        let reach = LayoutDividerGeometry.resizeDistance
        return Rectangle().fill(Color.white.opacity(0.001))
        .frame(width: vertical ? reach * 2 : divider.frame.width,
               height: vertical ? divider.frame.height : reach * 2)
        .contentShape(Rectangle())
        .offset(x: vertical ? divider.position - reach : divider.frame.minX,
                y: vertical ? divider.frame.minY : divider.position - reach)
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("layoutCanvas"))
            .onChanged { value in
                if resizeOrigin == nil { resizeOrigin = divider }
                guard let origin = resizeOrigin, origin.id == divider.id else { return }
                controller.resize(origin.id, ratio: origin.translatedRatio(value.translation), ended: false)
            }
            .onEnded { value in
                guard let origin = resizeOrigin, origin.id == divider.id else { return }
                controller.resize(origin.id, ratio: origin.translatedRatio(value.translation), ended: true)
                resizeOrigin = nil
            })
        .allowsHitTesting(active)
        .accessibilityLabel(settings.text(vertical ? "左右分隔线" : "上下分隔线"))
        .accessibilityValue("\(Int(divider.ratio * 100))%")
        .accessibilityIdentifier("multiLayoutDivider-\(divider.id)")
        .accessibilityAdjustableAction { direction in
            guard !controller.isApplying, controller.outcomes.isEmpty else { return }
            controller.resize(divider.id, ratio: divider.ratio + (direction == .increment ? 0.05 : -0.05), ended: true)
        }
    }

    private func updateResizeCursor(_ divider: LayoutDividerGeometry?) {
        if cellDrag != nil { NSCursor.closedHand.set(); return }
        guard let divider else { NSCursor.arrow.set(); return }
        (divider.vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
    }
}

/// Interpolate divider endpoints, including when a split changes direction.
private struct LayoutDragDivider: Shape {
    var from: CGPoint
    var to: CGPoint

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(from.x, from.y), AnimatablePair(to.x, to.y)) }
        set {
            from = CGPoint(x: newValue.first.first, y: newValue.first.second)
            to = CGPoint(x: newValue.second.first, y: newValue.second.second)
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        return path
    }
}

@MainActor
private struct LayoutSplitReveal: View {
    let axis: LayoutSplitAxis
    let edge: LayoutSplitEdge
    let ratio: CGFloat
    let highlight: Color
    let tracingCompleted: () -> Void
    let completed: () -> Void
    @State private var traceProgress: CGFloat = 0
    @State private var travelProgress: CGFloat = 0

    var body: some View {
        LayoutSplitTrace(axis: axis, edge: edge, ratio: ratio, highlight: highlight,
                         traceProgress: traceProgress, travelProgress: travelProgress)
            .onAppear {
                withAnimation(.linear(duration: 0.46), completionCriteria: .logicallyComplete) {
                    traceProgress = 1
                } completion: {
                    tracingCompleted()
                    withAnimation(.easeInOut(duration: 0.3), completionCriteria: .logicallyComplete) {
                        travelProgress = 1
                    } completion: {
                        completed()
                    }
                }
            }
    }
}

/// Trace the existing curve and border first. Only after both lights reach
/// the side borders does the new divider leave the original edge.
private struct LayoutSplitTrace: View, Animatable {
    let axis: LayoutSplitAxis
    let edge: LayoutSplitEdge
    let ratio: CGFloat
    let highlight: Color
    var traceProgress: CGFloat
    var travelProgress: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(traceProgress, travelProgress) }
        set { traceProgress = newValue.first; travelProgress = newValue.second }
    }

    private func phase(_ progress: CGFloat, from start: CGFloat, to end: CGFloat) -> CGFloat {
        let fraction = min(1, max(0, (progress - start) / (end - start)))
        return fraction * fraction * (3 - 2 * fraction)
    }

    var body: some View {
        Canvas { context, size in
            let vertical = axis == .columns
            let length = vertical ? size.height : size.width
            let breadth = vertical ? size.width : size.height
            let nearEdge = edge == .left || edge == .top
            let baseline: CGFloat = nearEdge ? 0 : breadth
            let inward: CGFloat = nearEdge ? 1 : -1
            let center = length / 2
            let curveProgress = phase(traceProgress, from: 0.1, to: 0.5)
            let edgeProgress = phase(traceProgress, from: 0.5, to: 1)
            let glowOpacity = 1 - phase(travelProgress, from: 0.75, to: 1)
            let across = baseline + (breadth * ratio - baseline) * travelProgress
            func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
                vertical ? CGPoint(x: across, y: along) : CGPoint(x: along, y: across)
            }
            func fillRegion(from start: CGFloat, to end: CGFloat, color: Color) {
                let extent = abs(end - start)
                let rect = CGRect(origin: point(0, min(start, end)),
                                  size: vertical ? CGSize(width: extent, height: length)
                                      : CGSize(width: length, height: extent))
                context.fill(Path(rect), with: .color(color))
            }
            // The moving divider pulls the highlighted cell out of the clicked
            // edge; the rest of the original cell keeps its normal background.
            fillRegion(from: baseline, to: across, color: highlight.opacity(0.22))
            fillRegion(from: across, to: nearEdge ? breadth : 0, color: .white.opacity(0.055))

            var glow = context
            glow.addFilter(.blur(radius: 5))
            func drawTip(_ position: CGPoint) {
                let halo = Path(ellipseIn: CGRect(x: position.x - 5, y: position.y - 5, width: 10, height: 10))
                let dot = Path(ellipseIn: CGRect(x: position.x - 2.5, y: position.y - 2.5, width: 5, height: 5))
                glow.fill(halo, with: .color(highlight.opacity(glowOpacity)))
                context.fill(dot, with: .color(.white.opacity(glowOpacity)))
            }
            func drawLine(_ path: Path, opacity: CGFloat = 1) {
                glow.stroke(path, with: .color(highlight.opacity(0.65 * glowOpacity * opacity)),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                context.stroke(path, with: .color(highlight.opacity(opacity)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }

            let apex = point(center, baseline + inward * 34)
            // These are the same cubic control points as LayoutBoundaryContour,
            // followed in reverse on the first half, from the apex to each shoulder.
            for direction: CGFloat in [-1, 1] {
                var curve = Path()
                curve.move(to: apex)
                curve.addCurve(to: point(center + direction * 44, baseline),
                               control1: point(center + direction * 28, baseline + inward * 34),
                               control2: point(center + direction * 22, baseline))
                var trail = curve.trimmedPath(from: 0, to: curveProgress)
                if edgeProgress > 0 {
                    trail.addLine(to: point(center + direction * (44 + (center - 44) * edgeProgress), baseline))
                }
                drawLine(trail, opacity: 1 - phase(travelProgress, from: 0, to: 0.6))
                if travelProgress == 0, curveProgress > 0, let tip = trail.currentPoint { drawTip(tip) }
            }
            if curveProgress == 0 { drawTip(apex) }

            if travelProgress > 0 {
                var divider = Path()
                divider.move(to: point(0, across))
                divider.addLine(to: point(length, across))
                drawLine(divider)
                drawTip(point(0, across))
                drawTip(point(length, across))
            }
        }
    }
}

@MainActor
private struct LayoutBoundaryView: View {
    struct Tab: Equatable, Identifiable {
        let regionID: UUID
        let index: Int
        let edge: LayoutSplitEdge
        let start: CGFloat
        let end: CGFloat
        let inward: CGFloat
        var id: String { "\(regionID)-\(edge.rawValue)" }
        var center: CGFloat { (start + end) / 2 }
    }

    let vertical: Bool
    let length: CGFloat
    let tabs: [Tab]
    let hoveredRegion: UUID?
    let pointer: CGPoint?
    let showsControls: Bool
    let heldRegion: UUID?
    let heldEdge: LayoutSplitEdge?
    let resizeCenter: CGFloat?
    let isResizing: Bool
    let highlight: Color
    let label: String
    let split: (UUID, LayoutSplitEdge) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previousTab: Tab?
    @State private var previousResizeCenter: CGFloat?

    private var guideCenters: [CGFloat] {
        // Both sides of a shared edge may have the same midpoint.
        tabs.reduce(into: []) { centers, tab in
            if !centers.contains(where: { abs($0 - tab.center) < 0.5 }) { centers.append(tab.center) }
        }
    }

    private var activeTab: Tab? {
        guard showsControls, let pointer,
              let tab = tabs.first(where: { $0.regionID == hoveredRegion }) else { return nil }
        let along = vertical ? pointer.y : pointer.x
        let across = vertical ? pointer.x : pointer.y
        // This radius covers the entire opened control while keeping the
        // activation areas of a region's four guides separate, even in small cells.
        return hypot(along - tab.center, across) <= LayoutDividerGeometry.buttonRadius ? tab : nil
    }

    private var controlTabs: [Tab] {
        // Keep each hidden control mounted at zero depth so its very first
        // reveal animates too. Preserve a removed leaf while its split traces.
        if let previousTab, !tabs.contains(where: { $0.id == previousTab.id }) {
            return tabs + [previousTab]
        }
        return tabs
    }

    var body: some View {
        let heldTab = previousTab.flatMap { $0.regionID == heldRegion && $0.edge == heldEdge ? $0 : nil }
        let tab = heldTab ?? activeTab
        let hoveredTab = tabs.first { $0.regionID == hoveredRegion }
        let animation = reduceMotion ? nil : Animation.easeInOut(duration: 0.18)
        let resizePosition = resizeCenter ?? previousResizeCenter ?? length / 2
        let resizeRadius = min(LayoutDividerGeometry.handleRadius, max(0, min(resizePosition, length - resizePosition)))
        ZStack(alignment: .topLeading) {
            ForEach(controlTabs) { attachment in
                let visible = tab?.id == attachment.id
                let hovered = pointer.map {
                    abs((vertical ? $0.y : $0.x) - attachment.center) <= 14 &&
                    abs((vertical ? $0.x : $0.y) - attachment.inward * 17) <= 14
                } ?? false
                LayoutBoundaryControl(vertical: vertical, tab: attachment, progress: visible ? 1 : 0,
                                      hovered: hovered && showsControls, highlight: highlight, label: label) {
                    split(attachment.regionID, attachment.edge)
                }
                .animation(animation, value: visible)
                .allowsHitTesting(visible && showsControls)
                .accessibilityHidden(!visible || !showsControls)
            }
            LayoutResizeControl(vertical: vertical, center: resizePosition,
                                radius: resizeRadius, progress: resizeCenter == nil ? 0 : 1,
                                pressed: isResizing, hoveredSegment: hoveredTab.map { $0.start...$0.end },
                                highlight: highlight)
                .animation(animation, value: resizeCenter != nil)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            ForEach(guideCenters, id: \.self) { midpoint in
                let covered = tab.map { abs(midpoint - $0.center) < 0.5 } ?? false
                guide(at: midpoint)
                    .opacity(showsControls && !covered ? 1 : 0)
                    .animation(animation, value: tab?.id)
            }
        }
        .frame(width: vertical ? 64 : length, height: vertical ? length : 64)
        .onChange(of: tab, initial: true) { _, value in
            if let value { previousTab = value }
        }
        .onChange(of: resizeCenter, initial: true) { _, value in
            if let value { previousResizeCenter = value }
        }
    }

    private func guide(at midpoint: CGFloat) -> some View {
        let glow = LinearGradient(colors: [highlight.opacity(0), highlight, highlight.opacity(0)],
                                  startPoint: vertical ? .top : .leading, endPoint: vertical ? .bottom : .trailing)
        return ZStack {
            Capsule().fill(glow).frame(width: vertical ? 8 : 42, height: vertical ? 42 : 8).blur(radius: 5)
            Capsule().fill(glow).frame(width: vertical ? 2 : 30, height: vertical ? 30 : 2)
        }
        .position(x: vertical ? 32 : midpoint, y: vertical ? midpoint : 32)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A circular resize handle grows from the divider, leaving its arrow centered.
@MainActor
private struct LayoutResizeControl: View, Animatable {
    let vertical: Bool
    let center: CGFloat
    let radius: CGFloat
    var progress: CGFloat
    let pressed: Bool
    let hoveredSegment: ClosedRange<CGFloat>?
    let highlight: Color

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let scale = radius / LayoutDividerGeometry.handleRadius
        let bulge = LayoutResizeContour(vertical: vertical, center: center, radius: radius,
                                         progress: progress, handleOnly: true)
        let divider = LayoutResizeContour(vertical: vertical, center: center, radius: radius, progress: progress)
        ZStack(alignment: .topLeading) {
            bulge.fill(.regularMaterial)
            bulge.fill(highlight.opacity(pressed ? 0.32 : 0.12))
            divider.stroke(.white.opacity(0.45), lineWidth: 1)
            divider.stroke(highlight, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .opacity(progress)
            if let hoveredSegment {
                LayoutResizeContour(vertical: vertical, center: center, radius: radius,
                                    progress: progress, segment: hoveredSegment)
                    .stroke(highlight, lineWidth: 2)
                    .opacity(1 - progress)
            }
            resizeSymbol
                .frame(width: 28, height: 28)
                .rotationEffect(.degrees(vertical ? 0 : 90))
                .scaleEffect(scale * (pressed ? 0.9 : 1))
                .opacity(min(1, max(0, (progress - 0.8) / 0.2)))
                .position(x: vertical ? 32 : center,
                          y: vertical ? center : 32)
        }
        .transaction { $0.animation = nil }
    }

    private var resizeSymbol: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 10, y: 14))
                path.addLine(to: CGPoint(x: 4, y: 14))
                path.move(to: CGPoint(x: 7.5, y: 10.5))
                path.addLine(to: CGPoint(x: 4, y: 14))
                path.addLine(to: CGPoint(x: 7.5, y: 17.5))
                path.move(to: CGPoint(x: 18, y: 14))
                path.addLine(to: CGPoint(x: 24, y: 14))
                path.move(to: CGPoint(x: 20.5, y: 10.5))
                path.addLine(to: CGPoint(x: 24, y: 14))
                path.addLine(to: CGPoint(x: 20.5, y: 17.5))
            }
            .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            Path { path in
                path.move(to: CGPoint(x: 14, y: 8))
                path.addLine(to: CGPoint(x: 14, y: 20))
            }
            .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [2, 3]))
        }
    }
}

/// Begin with the split buttons' tangent curve, then round it into a true circle.
/// The parent samples one progress value for this contour, the fill, highlights and icon.
private struct LayoutResizeContour: Shape {
    let vertical: Bool
    let center: CGFloat
    let radius: CGFloat
    let progress: CGFloat
    var handleOnly = false
    var segment: ClosedRange<CGFloat>?

    func path(in rect: CGRect) -> Path {
        func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            vertical ? CGPoint(x: 32 + across, y: along) : CGPoint(x: along, y: 32 + across)
        }
        let length = vertical ? rect.height : rect.width
        let start = segment?.lowerBound ?? 0
        let end = segment?.upperBound ?? length
        var path = Path()
        guard progress > 0, radius > 0, center >= start, center <= end else {
            if !handleOnly {
                path.move(to: point(start, 0))
                path.addLine(to: point(end, 0))
            }
            return path
        }

        let rounding = progress * progress * (3 - 2 * progress)
        let initialSpan = min(44, center, length - center)
        let span = initialSpan + (radius - initialSpan) * rounding
        let depth = radius * progress
        if !handleOnly {
            path.move(to: point(start, 0))
            path.addLine(to: point(center - span, 0))
            path.move(to: point(center + span, 0))
            path.addLine(to: point(end, 0))
        }

        if progress >= 1 {
            path.addEllipse(in: CGRect(x: (vertical ? 32 : center) - radius,
                                      y: (vertical ? center : 32) - radius,
                                      width: radius * 2, height: radius * 2))
            return path
        }

        // Interpolate the existing split curve toward the four circle quadrants.
        let circleControl: CGFloat = 4 * (sqrt(2) - 1) / 3
        let entry = span * (0.5 + 0.5 * rounding)
        let entryDepth = circleControl * depth * rounding
        let shoulder = span * (28.0 / 44 + (circleControl - 28.0 / 44) * rounding)
        path.move(to: point(center - span, 0))
        path.addCurve(to: point(center, depth),
                      control1: point(center - entry, entryDepth), control2: point(center - shoulder, depth))
        path.addCurve(to: point(center + span, 0),
                      control1: point(center + shoulder, depth), control2: point(center + entry, entryDepth))
        path.addCurve(to: point(center, -depth),
                      control1: point(center + entry, -entryDepth), control2: point(center + shoulder, -depth))
        path.addCurve(to: point(center - span, 0),
                      control1: point(center - shoulder, -depth), control2: point(center - entry, -entryDepth))
        path.closeSubpath()
        return path
    }
}

/// One progress value drives the curve, its hover fill and the delayed icon.
/// Computing opacity inside the animatable view keeps it invisible until the
/// curve is almost open, including the first time the pointer reaches a guide.
@MainActor
private struct LayoutBoundaryControl: View, Animatable {
    let vertical: Bool
    let tab: LayoutBoundaryView.Tab
    var progress: CGFloat
    let hovered: Bool
    let highlight: Color
    let label: String
    let split: () -> Void

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let depth = tab.inward * 34 * progress
        let iconOpacity = min(1, max(0, (progress - 0.8) / 0.2))
        let bulge = LayoutBoundaryContour(vertical: vertical, center: tab.center, depth: depth, tabOnly: true)
        ZStack(alignment: .topLeading) {
            bulge.fill(.regularMaterial).allowsHitTesting(false)
            bulge.stroke(highlight, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .opacity(progress).allowsHitTesting(false)
            Button(action: split) {
                Image(systemName: vertical ? "rectangle.split.2x1" : "rectangle.split.1x2")
                    .font(.system(size: 14, weight: .semibold))
                    .opacity(iconOpacity)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(LayoutSplitButtonStyle(vertical: vertical, inward: tab.inward, depth: depth,
                                               hovered: hovered, highlight: highlight))
            .help(label).accessibilityLabel(label)
            .accessibilityIdentifier("multiLayoutSplit-\(tab.index)-\(tab.edge.rawValue)")
            // Keep the hit target still while the surrounding edge grows.
            .position(x: vertical ? 32 + tab.inward * 17 : tab.center,
                      y: vertical ? tab.center : 32 + tab.inward * 17)
        }
        // Child shapes must use the sampled progress, not start another animation.
        .transaction { $0.animation = nil }
    }
}

@MainActor
private struct LayoutSplitButtonStyle: ButtonStyle {
    let vertical: Bool
    let inward: CGFloat
    let depth: CGFloat
    let hovered: Bool
    let highlight: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(hovered ? 1 : 0.78))
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .shadow(color: highlight.opacity(hovered ? 0.65 : 0), radius: 4)
            .background {
                LayoutBoundaryContour(vertical: vertical, center: 44, depth: depth, tabOnly: true)
                    .fill(highlight.opacity(configuration.isPressed ? 0.44 : (hovered ? 0.24 : 0)))
                    .frame(width: vertical ? 64 : 88, height: vertical ? 88 : 64)
                    .offset(x: vertical ? -inward * 17 : 0, y: vertical ? 0 : -inward * 17)
                    .allowsHitTesting(false)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// The original straight edge and an optional, smoothly rounded inward bulge.
private struct LayoutBoundaryContour: Shape {
    var vertical: Bool
    var center: CGFloat
    var depth: CGFloat
    var segment: ClosedRange<CGFloat>?
    var tabOnly = false

    var animatableData: CGFloat {
        get { depth }
        set { depth = newValue }
    }

    func path(in rect: CGRect) -> Path {
        func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            vertical ? CGPoint(x: 32 + across, y: along) : CGPoint(x: along, y: 32 + across)
        }
        let length = vertical ? rect.height : rect.width
        let start = tabOnly ? center - 44 : (segment?.lowerBound ?? 0)
        let end = tabOnly ? center + 44 : (segment?.upperBound ?? length)
        var path = Path()
        path.move(to: point(start, 0))
        if depth == 0 {
            path.addLine(to: point(end, 0))
            return path
        }
        path.addLine(to: point(center - 44, 0))
        path.addCurve(to: point(center, depth),
                      control1: point(center - 22, 0), control2: point(center - 28, depth))
        path.addCurve(to: point(center + 44, 0),
                      control1: point(center + 28, depth), control2: point(center + 22, 0))
        path.addLine(to: point(end, 0))
        if tabOnly { path.closeSubpath() }
        return path
    }
}

nonisolated struct LayoutWindowPickerPlacement {
    let picker: CGRect
    let preview: CGRect

    init(area: CGRect, anchor: CGPoint) {
        let margin: CGFloat = 16
        let gap: CGFloat = 12
        let scale = min(1, max(0, (area.width - margin * 2 - gap) / 670))
        let pickerSize = CGSize(width: 350 * scale, height: max(0, min(430, area.height - 112)))
        let previewSize = CGSize(width: 320 * scale, height: min(240 * scale, pickerSize.height))
        let minX = area.minX + margin
        let maxX = area.maxX - margin
        var x = min(maxX - pickerSize.width, max(minX, anchor.x - pickerSize.width / 2))
        let centerY = min(area.maxY - margin - pickerSize.height / 2,
                          max(area.minY + 88 + pickerSize.height / 2, anchor.y))
        var previewX = x + pickerSize.width + gap
        if previewX + previewSize.width > maxX {
            if x - gap - previewSize.width >= minX {
                previewX = x - gap - previewSize.width
            } else {
                // Reserve both cards before the first preview appears. Hovering
                // changes the image, never the picker position or the side.
                x = max(minX, maxX - pickerSize.width - gap - previewSize.width)
                previewX = x + pickerSize.width + gap
            }
        }
        picker = CGRect(x: x, y: centerY - pickerSize.height / 2, width: pickerSize.width, height: pickerSize.height)
        preview = CGRect(x: previewX, y: centerY - previewSize.height / 2, width: previewSize.width, height: previewSize.height)
    }
}

@MainActor
private struct LayoutWindowSelection: View {
    @ObservedObject var controller: MultiWindowLayoutController
    @ObservedObject var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let placement: LayoutWindowPickerPlacement
    let area: CGRect
    @State private var activePlacement: LayoutWindowPickerPlacement?
    @State private var pickerVisible = false
    @State private var pickerSettled = false
    @State private var displayedPreview: MultiWindowLayoutController.WindowPreview?
    @State private var selectedRowFrames: [UUID: CGRect] = [:]
    @State private var previewCenterY: CGFloat?
    @State private var animationID = UUID()

    private var highlightedWindowID: UUID? {
        guard controller.filteredWindows.indices.contains(controller.highlightedWindow) else { return nil }
        return controller.filteredWindows[controller.highlightedWindow].id
    }

    var body: some View {
        let frames = activePlacement ?? placement
        let previewOnRight = frames.preview.midX > frames.picker.midX
        let previewOffset: CGFloat = previewOnRight ? -18 : 18
        ZStack(alignment: .topLeading) {
            if let preview = displayedPreview, let centerY = previewCenterY {
                LayoutWindowPreview(preview: preview, settings: settings, size: frames.preview.size,
                                    alignment: previewOnRight ? .leading : .trailing)
                    .position(x: frames.preview.midX, y: centerY)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: centerY)
                    .transition(.offset(x: reduceMotion ? 0 : previewOffset).combined(with: .opacity))
                    .zIndex(0)
            }
            // Keep the picker laid out before opening. Its first fade no longer
            // competes with insertion or starts an animation from onAppear.
            LayoutWindowPicker(controller: controller, settings: settings, isReady: pickerSettled)
                .disabled(!controller.choosingWindow)
                .padding(16)
                .frame(width: frames.picker.width, height: frames.picker.height)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
                .position(x: frames.picker.midX, y: frames.picker.midY)
                .animation(nil, value: frames.picker)
                .opacity(pickerVisible ? 1 : 0)
                .zIndex(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: "layoutWindowSelection")
        .allowsHitTesting(controller.choosingWindow && pickerSettled)
        .accessibilityHidden(!controller.choosingWindow)
        .onPreferenceChange(LayoutWindowRowFramesKey.self) { frames in
            MainActor.assumeIsolated {
                selectedRowFrames = frames
                updatePreviewPosition()
                updatePreview()
            }
        }
        .onChange(of: controller.choosingWindow, initial: true) { _, presented in
            setPresented(presented)
        }
        .onChange(of: highlightedWindowID) { _, _ in
            updatePreviewPosition()
            updatePreview()
        }
        .onChange(of: controller.windowPreview?.id) { _, _ in updatePreview() }
        .onChange(of: reduceMotion) { _, _ in setPresented(controller.choosingWindow) }
    }

    private func setPresented(_ presented: Bool) {
        let id = UUID()
        animationID = id
        pickerSettled = false
        if presented {
            // Keep one position through opening, closing and an interrupted close.
            if activePlacement == nil { activePlacement = placement }
            updatePreviewPosition()
            controller.previewHighlightedWindow()
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: presented ? 0.22 : 0.18), completionCriteria: .removed) {
            pickerVisible = presented
            if !presented { displayedPreview = nil }
        } completion: {
            guard animationID == id, controller.choosingWindow == presented else { return }
            if presented {
                pickerSettled = true
                // Capture can finish early; presentation waits for the actual animation.
                updatePreviewPosition()
                updatePreview()
            } else {
                activePlacement = nil
                previewCenterY = nil
            }
        }
    }

    private func updatePreviewPosition() {
        guard controller.choosingWindow, let frames = activePlacement,
              let id = highlightedWindowID, let row = selectedRowFrames[id] else { return }
        let halfHeight = frames.preview.height / 2
        previewCenterY = min(area.maxY - 16 - halfHeight,
                             max(area.minY + 16 + halfHeight, row.midY))
    }

    private func updatePreview() {
        guard controller.choosingWindow, pickerSettled else { return }
        if let preview = controller.windowPreview {
            // Never insert an image at a provisional position or for an older row.
            guard preview.id == highlightedWindowID, selectedRowFrames[preview.id] != nil,
                  previewCenterY != nil, displayedPreview?.id != preview.id else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                displayedPreview = preview
            }
        } else {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                // The removal transition retains this snapshot until fade-out ends.
                displayedPreview = nil
            }
        }
    }
}

nonisolated private struct LayoutWindowRowFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

@MainActor
private struct LayoutWindowPreview: View {
    let preview: MultiWindowLayoutController.WindowPreview
    @ObservedObject var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let size: CGSize
    let alignment: Alignment

    var body: some View {
        ZStack {
            Group {
                if let image = preview.image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .accessibilityIdentifier("multiLayoutWindowPreviewImage")
                } else {
                    VStack(spacing: 10) {
                        if let icon = preview.window.icon {
                            Image(nsImage: icon).resizable().scaledToFit().frame(width: 48, height: 48)
                        }
                        Text(settings.text("暂时无法预览")).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .id(preview.id)
            .transition(.opacity)
            .zIndex(1)
        }
        .padding(12)
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: preview.id)
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(preview.window.applicationName + ": " + preview.window.title)
        .accessibilityIdentifier("multiLayoutWindowPreview")
    }
}

@MainActor
private struct LayoutWindowPicker: View {
    @ObservedObject var controller: MultiWindowLayoutController
    @ObservedObject var settings: AppSettings
    let isReady: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searching: Bool
    @State private var openingPointerLocation: CGPoint?
    @State private var lastHoverLocation: CGPoint?
    @State private var pointerSelection: UUID?
    @State private var hoveredWindowID: UUID?
    private let highlight = Color(red: 0.40, green: 0.71, blue: 1)

    private var highlightedWindowID: UUID? {
        guard controller.filteredWindows.indices.contains(controller.highlightedWindow) else { return nil }
        return controller.filteredWindows[controller.highlightedWindow].id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(settings.text("选择窗口")).font(.headline)
                Spacer()
                Button { controller.choosingWindow = false } label: { Image(systemName: "xmark") }
                    .help(settings.text("返回预览"))
            }
            TextField(settings.text("搜索应用或窗口标题"), text: $controller.search)
                .textFieldStyle(.roundedBorder).focused($searching)
                .accessibilityIdentifier("multiLayoutWindowSearch")
            HStack {
                Text(settings.text("方向键选择，Enter 确认，Esc 返回。" )).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { controller.reloadWindows() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(controller.isLoading).help(settings.text("刷新窗口"))
                    .accessibilityIdentifier("multiLayoutRefreshWindows")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(controller.filteredWindows.enumerated()), id: \.element.id) { index, choice in
                            let occupied = controller.assignedRegionNumber(for: choice.id)
                            let highlighted = occupied == nil && controller.highlightedWindow == index
                            Button { controller.chooseWindow(choice.id) } label: {
                                HStack(spacing: 8) {
                                    if let icon = choice.window.icon { Image(nsImage: icon).resizable().scaledToFit().frame(width: 28, height: 28) }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(choice.window.applicationName).font(.callout.bold())
                                            .foregroundStyle(.white.opacity(highlighted ? 1 : 0.94))
                                        Text(choice.window.title).font(.caption).lineLimit(2)
                                            .foregroundStyle(.white.opacity(highlighted ? 0.82 : 0.66))
                                        if let occupied {
                                            Text(settings.text("已分配到区域 %@", String(occupied))).font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(highlight.opacity(highlighted ? 0.14 : 0),
                                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(highlight.opacity(highlighted ? 0.65 : 0), lineWidth: 1)
                                            .allowsHitTesting(false)
                                    }
                                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: highlighted)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(choice.id)
                                .disabled(occupied != nil)
                                .background {
                                    if highlighted {
                                        GeometryReader { geometry in
                                            Color.clear.preference(key: LayoutWindowRowFramesKey.self,
                                                                   value: [choice.id: geometry.frame(in: .named("layoutWindowSelection"))])
                                        }
                                    }
                                }
                                .onContinuousHover(coordinateSpace: .global) { phase in
                                    if case .ended = phase {
                                        if hoveredWindowID == choice.id {
                                            hoveredWindowID = nil
                                            controller.cancelPendingWindowPreview(for: choice.id)
                                        }
                                        return
                                    }
                                    // Compare positions from this hover event in the window's
                                    // coordinate space. The panel's separately sampled pointer
                                    // can lag or already refer to a later mouse event.
                                    // Keyboard scrolling keeps this position unchanged.
                                    guard isReady, case .active(let point) = phase,
                                          point != lastHoverLocation else { return }
                                    lastHoverLocation = point
                                    if let openingPointerLocation {
                                        // Revealing the picker under a stationary cursor
                                        // must not replace the initial keyboard selection.
                                        guard NSEvent.mouseLocation != openingPointerLocation else { return }
                                        self.openingPointerLocation = nil
                                    }
                                    guard occupied == nil else { return }
                                    pointerSelection = choice.id
                                    hoveredWindowID = choice.id
                                    controller.highlightedWindow = index
                                    controller.previewHighlightedWindow()
                                }
                                .accessibilityAddTraits(highlighted ? .isSelected : [])
                                .accessibilityIdentifier("multiLayoutWindow-\(index)")
                        }
                        if !controller.isLoading && controller.filteredWindows.isEmpty {
                            Text(settings.text("没有可用窗口。仅支持当前桌面上可移动、可缩放的普通窗口。"))
                                .font(.callout).foregroundStyle(.secondary).padding(.vertical)
                        }
                    }
                }.onChange(of: controller.highlightedWindow) { _, index in
                    guard controller.filteredWindows.indices.contains(index) else { return }
                    let id = controller.filteredWindows[index].id
                    let fromPointer = pointerSelection == id
                    if !fromPointer { hoveredWindowID = nil }
                    pointerSelection = nil
                    // A hovered row is already visible. Moving it here would make
                    // the list jump as the pointer passes its partially visible edge.
                    if !fromPointer { proxy.scrollTo(id) }
                }
                .onChange(of: controller.choosingWindow) { _, presented in
                    openingPointerLocation = presented ? NSEvent.mouseLocation : nil
                    guard presented, let id = highlightedWindowID else { return }
                    // The picker stays mounted between openings; reset its scroll
                    // position while it is still fading in, before showing a preview.
                    proxy.scrollTo(id)
                }
            }
        }
        .onChange(of: isReady, initial: true) { _, ready in
            searching = ready
            if !ready {
                lastHoverLocation = nil
                pointerSelection = nil
                hoveredWindowID = nil
            }
        }
        .onChange(of: highlightedWindowID, initial: true) { _, _ in controller.previewHighlightedWindow() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("multiLayoutWindowPicker")
    }
}

