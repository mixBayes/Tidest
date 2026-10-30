import SwiftUI

@MainActor
struct MultiWindowLayoutView: View {
    @ObservedObject var controller: MultiWindowLayoutController
    @ObservedObject var settings: AppSettings
    @ObservedObject var templates: LayoutTemplateStore
    @State private var showingLayouts = false
    @State private var namingTemplate = false
    @State private var renaming: LayoutTemplate?
    @State private var templateName = ""
    @State private var nameError = false

    var body: some View {
        GeometryReader { geometry in
            let area = controller.target?.overlayLayoutFrame ?? CGRect(origin: .zero, size: geometry.size)
            ZStack(alignment: .topLeading) {
                Color(red: 0.04, green: 0.06, blue: 0.09).opacity(0.40)
                LayoutDraftCanvas(controller: controller, settings: settings)
                    .frame(width: area.width, height: area.height)
                    .offset(x: area.minX, y: area.minY)
                toolbar
                    .frame(width: max(0, area.width - 40))
                    .offset(x: area.minX + 20, y: area.minY + 16)
                if controller.choosingWindow {
                    let size = CGSize(width: min(350, area.width - 32), height: min(430, area.height - 112))
                    LayoutWindowPicker(controller: controller, settings: settings)
                        .padding(16)
                        .frame(width: size.width, height: size.height)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
                        .position(pickerCenter(in: area, size: size))
                }
                if !controller.outcomes.isEmpty {
                    results.padding(18)
                        .frame(width: min(390, area.width - 40), height: min(450, area.height - 120))
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .position(x: area.midX, y: area.midY)
                }
                feedback
                    .frame(width: max(0, area.width - 40))
                    .offset(x: area.minX + 20, y: area.maxY - 62)
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
        .sheet(isPresented: $namingTemplate) { templateNaming }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.split.2x1").foregroundStyle(.blue)
                Text(settings.text("快速布局")).font(.system(size: 14, weight: .semibold))
                Divider().frame(height: 18)
                Button(settings.text("布局")) { showingLayouts.toggle() }
                    .accessibilityIdentifier("multiLayoutLayouts")
                    .popover(isPresented: $showingLayouts, arrowEdge: .bottom) {
                        gallery.padding(20).frame(width: 480, height: 440)
                    }
                    .disabled(controller.isApplying || !controller.outcomes.isEmpty)
                Menu {
                    ForEach(controller.displays) { display in
                        Button(display.name) { controller.selectDisplay(display.id) }
                    }
                } label: { Image(systemName: "display") }
                .help(controller.target?.name ?? settings.text("目标显示器"))
                .accessibilityIdentifier("multiLayoutDisplay")
                .disabled(controller.isApplying)
                Menu {
                    Button(settings.text("撤销草稿编辑")) { controller.undoDraft() }
                        .disabled(controller.draft?.canUndo != true || !controller.outcomes.isEmpty)
                        .accessibilityIdentifier("multiLayoutUndoDraft")
                    Button(settings.text("合并区域")) { controller.request(.merge) }
                        .disabled(controller.draft?.mergeRegion == nil || !controller.outcomes.isEmpty)
                        .accessibilityIdentifier("multiLayoutMerge")
                    Button(settings.text("清除窗口选择")) { controller.clearWindow() }
                        .disabled(controller.draft?.selectedRegion.flatMap { controller.draft?.assignments[$0] } == nil || !controller.outcomes.isEmpty)
                    Divider()
                    Button(settings.text("保存为模板")) { beginNaming(nil) }
                        .disabled(templates.errorKey != nil || !controller.outcomes.isEmpty)
                        .accessibilityIdentifier("multiLayoutSaveTemplate")
                    Button(settings.text("撤销上次应用")) { controller.undoApplication() }
                        .disabled(!controller.undoAvailable)
                        .accessibilityIdentifier("multiLayoutUndoApplication")
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel(settings.text("更多操作"))
                .accessibilityIdentifier("multiLayoutMore")
                .disabled(controller.isApplying)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                if controller.isLoading || controller.isApplying { ProgressView().controlSize(.small) }
                Button(settings.text(controller.isApplying ? "正在应用…" : "应用布局")) { controller.apply() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!controller.canApply)
                    .accessibilityIdentifier("multiLayoutApply")
                Button(settings.text("取消")) { controller.dismiss() }
                    .buttonStyle(.bordered).controlSize(.large)
                    .disabled(controller.isApplying)
                    .accessibilityIdentifier("multiLayoutCancel")
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder private var feedback: some View {
        HStack {
            Spacer()
            if controller.displayInvalidated {
                HStack {
                    Text(settings.text("显示器配置已变化，请重新确认目标显示器。"))
                    Button(settings.text("重新确认显示器")) {
                        if let id = controller.target?.id { controller.selectDisplay(id) }
                    }
                }.foregroundStyle(.orange)
            } else if let message = controller.messageKey ?? templates.errorKey {
                Text(settings.text(message)).foregroundStyle(.orange)
                    .accessibilityIdentifier("multiLayoutMessage")
            } else if controller.hasSmallRegions {
                Text(settings.text("区域过小，请合并区域或选择更大的显示器。" )).foregroundStyle(.orange)
            } else if !controller.sizeConflicts.isEmpty {
                Text(settings.text("窗口尺寸受限，请调整区域后重试。")).foregroundStyle(.orange)
            } else if controller.confirming {
                Text(settings.text("按 Enter 应用布局，按 Esc 返回编辑。"))
                    .accessibilityIdentifier("multiLayoutConfirming")
            } else if !controller.choosingWindow && controller.outcomes.isEmpty {
                Text(settings.text("点击格子选窗口，拖动分隔线调整大小。"))
            }
            Spacer()
        }
        .font(.system(size: 12))
        .padding(10)
        .background(.regularMaterial, in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }

    private func pickerCenter(in area: CGRect, size: CGSize) -> CGPoint {
        let leaf = controller.draft?.root.leaves.first { $0.region.id == controller.draft?.selectedRegion }
        let x = area.minX + (leaf?.frame.midX ?? 0.5) * area.width
        let y = area.minY + (leaf?.frame.midY ?? 0.5) * area.height
        return CGPoint(x: min(area.maxX - size.width / 2 - 16, max(area.minX + size.width / 2 + 16, x)),
                       y: min(area.maxY - size.height / 2 - 16, max(area.minY + size.height / 2 + 88, y)))
    }

    private func chooseLayout(_ root: LayoutRegion) {
        showingLayouts = false
        controller.request(.replace(root))
    }

    private var gallery: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(settings.text("选择布局起点")).font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 14) {
                    ForEach(LayoutStartingPoint.allCases) { start in
                        templateCard(title: settings.text(start.titleKey), root: start.makeRegion()) {
                            chooseLayout(start.makeRegion())
                        }
                        .accessibilityIdentifier("multiLayoutStart-\(start.rawValue)")
                    }
                }
                Button { chooseLayout(.leaf(UUID())) } label: {
                    Label(settings.text("空白布局"), systemImage: "plus.rectangle")
                }.accessibilityIdentifier("multiLayoutBlank")
                if !templates.templates.isEmpty {
                    Text(settings.text("我的模板")).font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 14) {
                        ForEach(templates.templates) { template in
                            templateCard(title: template.name, root: template.root) { chooseLayout(template.root) }
                                .contextMenu {
                                    Button(settings.text("重命名")) { beginNaming(template) }
                                    Button(settings.text("删除模板"), role: .destructive) { templates.delete(template.id) }
                                }
                        }
                    }
                }
                Text(settings.text("可继续左右或上下分割、拖动分隔线；尺寸限制由当前空间决定。"))
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(2)
        }
    }

    private func templateCard(title: String, root: LayoutRegion, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        ForEach(root.leaves, id: \.region.id) { leaf in
                            RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.16))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor.opacity(0.4)))
                                .frame(width: max(0, leaf.frame.width * geometry.size.width - 4),
                                       height: max(0, leaf.frame.height * geometry.size.height - 4))
                                .offset(x: leaf.frame.minX * geometry.size.width + 2, y: leaf.frame.minY * geometry.size.height + 2)
                        }
                    }
                }.frame(height: 92)
                Text(title).font(.callout.weight(.medium)).lineLimit(2)
            }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
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
        renaming = template
        templateName = template?.name ?? ""
        nameError = false
        namingTemplate = true
    }

    private var templateNaming: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(settings.text(renaming == nil ? "保存为模板" : "重命名")).font(.headline)
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
                    if templates.save(name: templateName, root: root, replacing: renaming?.id) { namingTemplate = false }
                    else { nameError = true }
                }.accessibilityIdentifier("multiLayoutConfirmSaveTemplate")
            }
        }.padding(24).frame(width: 400)
    }
}

@MainActor
private struct LayoutDraftCanvas: View {
    @ObservedObject var controller: MultiWindowLayoutController
    @ObservedObject var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pointer: CGPoint?
    @State private var splitOrigin: SplitOrigin?
    @State private var holdingSplitButton = false
    private let highlight = Color(red: 0.40, green: 0.71, blue: 1)

    private struct SplitOrigin {
        let id = UUID()
        let regionID: UUID
        let edge: String
    }

    private var splittingRegion: LayoutRegion.Placement? {
        guard let splitOrigin,
              let placement = controller.draft?.root.placements().first(where: { $0.region.id == splitOrigin.regionID }),
              case .split = placement.region else { return nil }
        return placement
    }

    private var hoveredRegion: UUID? {
        guard let pointer, !controller.isApplying, controller.outcomes.isEmpty else { return nil }
        return controller.draft?.root.leaves.first { $0.frame.contains(pointer) }?.region.id
    }

    var body: some View {
        GeometryReader { geometry in
            if let draft = controller.draft {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(draft.root.leaves.enumerated()), id: \.element.region.id) { index, leaf in
                        region(leaf, index: index, size: geometry.size)
                    }
                    ForEach(draft.root.placements(), id: \.region.id) { placement in
                        if case .split(_, let axis, let ratio, _, _) = placement.region,
                           placement.region.id != splittingRegion?.region.id {
                            divider(placement, axis: axis, ratio: ratio, size: geometry.size)
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
                                     size: geometry.size)
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
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        pointer = CGPoint(x: point.x / geometry.size.width, y: point.y / geometry.size.height)
                    case .ended: pointer = nil
                    }
                }
            }
        }
        .coordinateSpace(name: "layoutCanvas")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("multiLayoutCanvas")
        .onChange(of: controller.pendingEdit != nil) { _, pending in
            // Cancelled or rejected splits never start a visual transition.
            if !pending && splittingRegion == nil { splitOrigin = nil }
        }
        .onChange(of: controller.draft?.root) { _, _ in
            if controller.pendingEdit == nil && splittingRegion == nil { splitOrigin = nil }
        }
        .onChange(of: controller.target?.id) { _, _ in splitOrigin = nil; pointer = nil }
        .onChange(of: reduceMotion) { _, reduced in if reduced { splitOrigin = nil } }
    }

    private func region(_ leaf: LayoutRegion.Placement, index: Int, size: CGSize) -> some View {
        let choice = controller.draft?.assignments[leaf.region.id].flatMap { id in controller.windows.first { $0.id == id } }
        let hovered = hoveredRegion == leaf.region.id && !controller.isApplying && controller.outcomes.isEmpty
        let revealing = splittingRegion?.region.leafIDs.contains(leaf.region.id) == true
        let showingControls = hovered && !controller.choosingWindow && splittingRegion == nil
        let width = leaf.frame.width * size.width
        let height = leaf.frame.height * size.height
        let compact = height < 240 || width < 240
        let canDelete = (controller.draft?.root.leafIDs.count ?? 0) > 1
        return ZStack {
            Button { controller.selectRegion(leaf.region.id) } label: {
                Rectangle().fill(hovered || revealing ? highlight.opacity(0.22) : Color.white.opacity(0.055))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(settings.text("区域 %@", String(index + 1)) + ": " + (choice?.window.title ?? settings.text("选择窗口")))
            .accessibilityIdentifier("multiLayoutRegion-\(index)")

            ZStack(alignment: .topTrailing) {
                Button { controller.selectRegion(leaf.region.id) } label: {
                    Group {
                        if compact {
                            Text("\(index + 1) · " + (choice?.window.applicationName ?? settings.text("选择窗口")))
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1).truncationMode(.tail)
                                .padding(.trailing, canDelete ? 24 : 0)
                                .padding(.horizontal, 8).frame(maxWidth: .infinity).frame(height: 32)
                        } else {
                            VStack(spacing: 8) {
                                Text(settings.text("区域 %@", String(index + 1)))
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.7)).padding(.horizontal, 24)
                                if let choice {
                                    if let icon = choice.window.icon { Image(nsImage: icon).resizable().scaledToFit().frame(width: 36, height: 36) }
                                    Text(choice.window.applicationName).font(.system(size: 16, weight: .semibold))
                                    Text(choice.window.title).font(.system(size: 12)).lineLimit(2)
                                } else {
                                    Image(systemName: "macwindow.badge.plus").font(.system(size: 24, weight: .light))
                                    Text(settings.text(controller.draft?.assignments[leaf.region.id] == nil ? "选择窗口" : "窗口已失效，请重新选择。"))
                                        .font(.system(size: 14, weight: .medium))
                                }
                                if controller.sizeConflicts.contains(leaf.region.id) {
                                    Text(settings.text("窗口尺寸受限，请调整区域后重试。" )).font(.caption).foregroundStyle(.orange)
                                }
                            }
                            .padding(12).frame(maxWidth: .infinity)
                        }
                    }
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: compact ? 8 : 14))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).focusable(false).accessibilityHidden(true)
                if canDelete {
                    Button { controller.deleteRegion(leaf.region.id) } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(settings.text("删除格子"))
                    .accessibilityLabel(settings.text("删除格子"))
                    .accessibilityIdentifier("multiLayoutDelete-\(index)")
                    .padding(compact ? 2 : 5)
                    .opacity(showingControls ? 1 : 0)
                    .allowsHitTesting(showingControls)
                    .accessibilityHidden(!showingControls)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: showingControls)
                }
            }
            .frame(width: min(300, max(0, width - 80)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("multiLayoutCard-\(index)")
            .opacity(revealing ? 0 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: revealing)
        }
        .frame(width: width, height: height)
        .disabled(controller.isApplying || !controller.outcomes.isEmpty)
        .offset(x: leaf.frame.minX * size.width, y: leaf.frame.minY * size.height)
    }

    private func boundary(vertical: Bool, origin: CGPoint, length: CGFloat, size: CGSize) -> some View {
        LayoutBoundaryView(vertical: vertical, length: length,
                           tabs: boundaryTabs(vertical: vertical, origin: origin, length: length, size: size),
                           hoveredRegion: hoveredRegion,
                           pointer: pointer.map { CGPoint(x: $0.x * size.width - origin.x, y: $0.y * size.height - origin.y) },
                           showsControls: !controller.choosingWindow && !controller.isApplying && controller.outcomes.isEmpty && splittingRegion == nil,
                           heldRegion: holdingSplitButton && splittingRegion != nil ? splitOrigin?.regionID : nil,
                           heldEdge: holdingSplitButton && splittingRegion != nil ? splitOrigin?.edge : nil,
                           highlight: highlight,
                           label: settings.text(vertical ? "垂直分裂" : "水平分裂")) { id, edge in
            // Capture the actual edge before the model replaces this leaf.
            // If clearing a window choice needs confirmation, keep this origin
            // until the confirmed split appears in the model.
            splitOrigin = reduceMotion ? nil : SplitOrigin(regionID: id, edge: edge)
            holdingSplitButton = !reduceMotion
            controller.splitRegion(id, axis: vertical ? .columns : .rows)
            if controller.pendingEdit == nil && splittingRegion == nil { splitOrigin = nil }
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
                                          edge: vertical ? (inward > 0 ? "left" : "right") : (inward > 0 ? "top" : "bottom"),
                                          start: start, end: end, inward: inward)
        }
    }

    private func divider(_ placement: LayoutRegion.Placement, axis: LayoutSplitAxis, ratio: Double, size: CGSize) -> some View {
        let rect = placement.frame
        let vertical = axis == .columns
        return Rectangle().fill(Color.white.opacity(0.001))
        .frame(width: vertical ? 12 : rect.width * size.width,
               height: vertical ? rect.height * size.height : 12)
        .contentShape(Rectangle())
        .offset(x: vertical ? (rect.minX + rect.width * ratio) * size.width - 6 : rect.minX * size.width,
                y: vertical ? rect.minY * size.height : (rect.minY + rect.height * ratio) * size.height - 6)
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("layoutCanvas"))
            .onChanged { value in
                let fraction = vertical ? (value.location.x / size.width - rect.minX) / rect.width : (value.location.y / size.height - rect.minY) / rect.height
                controller.resize(placement.region.id, ratio: fraction, ended: false)
            }
            .onEnded { value in
                let fraction = vertical ? (value.location.x / size.width - rect.minX) / rect.width : (value.location.y / size.height - rect.minY) / rect.height
                controller.resize(placement.region.id, ratio: fraction, ended: true)
            })
        .onHover { inside in
            if inside { (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() }
            else { NSCursor.pop() }
        }
        .allowsHitTesting(!controller.isApplying && controller.outcomes.isEmpty && !controller.choosingWindow)
        .accessibilityLabel(settings.text(vertical ? "左右分隔线" : "上下分隔线"))
        .accessibilityValue("\(Int(ratio * 100))%")
        .accessibilityIdentifier("multiLayoutDivider-\(placement.region.id)")
        .accessibilityAdjustableAction { direction in
            guard !controller.isApplying, controller.outcomes.isEmpty else { return }
            controller.resize(placement.region.id, ratio: ratio + (direction == .increment ? 0.05 : -0.05), ended: true)
        }
    }
}

@MainActor
private struct LayoutSplitReveal: View {
    let axis: LayoutSplitAxis
    let edge: String
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
    let edge: String
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
            let nearEdge = edge == "left" || edge == "top"
            let baseline: CGFloat = nearEdge ? 0 : breadth
            let inward: CGFloat = nearEdge ? 1 : -1
            let center = length / 2
            let curveProgress = phase(traceProgress, from: 0.1, to: 0.5)
            let edgeProgress = phase(traceProgress, from: 0.5, to: 1)
            let glowOpacity = 1 - phase(travelProgress, from: 0.75, to: 1)
            func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
                vertical ? CGPoint(x: across, y: along) : CGPoint(x: along, y: across)
            }
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
                let across = baseline + (breadth * ratio - baseline) * travelProgress
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
    struct Tab: Equatable {
        let regionID: UUID
        let index: Int
        let edge: String
        let start: CGFloat
        let end: CGFloat
        let inward: CGFloat
        var center: CGFloat { (start + end) / 2 }
    }

    let vertical: Bool
    let length: CGFloat
    let tabs: [Tab]
    let hoveredRegion: UUID?
    let pointer: CGPoint?
    let showsControls: Bool
    let heldRegion: UUID?
    let heldEdge: String?
    let highlight: Color
    let label: String
    let split: (UUID, String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previousTab: Tab?

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
        return hypot(along - tab.center, across) <= 44 ? tab : nil
    }

    var body: some View {
        let heldTab = previousTab.flatMap { $0.regionID == heldRegion && $0.edge == heldEdge ? $0 : nil }
        let tab = heldTab ?? activeTab
        let hoveredTab = tabs.first { $0.regionID == hoveredRegion }
        // Retain the attachment point while fading out, so the edge flattens
        // where the button was instead of jumping back to the line's midpoint.
        let attachment = tab ?? previousTab
        let visible = tab != nil
        let center = attachment?.center ?? length / 2
        let depth = visible ? (attachment?.inward ?? 1) * 34 : 0
        let animation = reduceMotion ? nil : Animation.easeInOut(duration: 0.18)
        let bulge = LayoutBoundaryContour(vertical: vertical, center: center, depth: depth, tabOnly: true)
        ZStack(alignment: .topLeading) {
            bulge.fill(.regularMaterial)
                .allowsHitTesting(false)
                .animation(animation, value: depth)
            // The original straight border stays visible behind the new curve.
            LayoutBoundaryContour(vertical: vertical, center: center, depth: 0)
                .stroke(.white.opacity(0.45), lineWidth: 1)
                .allowsHitTesting(false)
            LayoutBoundaryContour(vertical: vertical, center: center, depth: 0,
                                  segment: hoveredTab.map { $0.start...$0.end })
                .stroke(highlight, lineWidth: 2)
                .opacity(hoveredTab == nil ? 0 : 1)
                .allowsHitTesting(false)

            ForEach(guideCenters, id: \.self) { midpoint in
                guide(at: midpoint)
                    .opacity(showsControls && !(visible && abs(midpoint - center) < 0.5) ? 1 : 0)
                    .animation(animation, value: visible)
            }
            bulge.stroke(highlight, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(false)
                .animation(animation, value: depth)
                .animation(animation, value: visible)
            if let attachment {
                Button { split(attachment.regionID, attachment.edge) } label: {
                    Image(systemName: vertical ? "rectangle.split.2x1" : "rectangle.split.1x2")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(LayoutSplitButtonStyle(vertical: vertical, inward: attachment.inward, highlight: highlight))
                .help(label).accessibilityLabel(label)
                .accessibilityIdentifier("multiLayoutSplit-\(attachment.index)-\(attachment.edge)")
                .opacity(visible ? 1 : 0)
                .animation(animation, value: visible)
                // Keep the hit target still while the surrounding edge grows.
                .position(x: vertical ? 32 + attachment.inward * 17 : center,
                          y: vertical ? center : 32 + attachment.inward * 17)
                .allowsHitTesting(visible && showsControls)
                .accessibilityHidden(!visible || !showsControls)
            }
        }
        .frame(width: vertical ? 64 : length, height: vertical ? length : 64)
        .onChange(of: tab, initial: true) { _, value in
            if let value { previousTab = value }
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

@MainActor
private struct LayoutSplitButtonStyle: ButtonStyle {
    let vertical: Bool
    let inward: CGFloat
    let highlight: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(hovered ? 1 : 0.78))
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .shadow(color: highlight.opacity(hovered ? 0.65 : 0), radius: 4)
            .background {
                LayoutBoundaryContour(vertical: vertical, center: 44, depth: inward * 34, tabOnly: true)
                    .fill(highlight.opacity(configuration.isPressed ? 0.44 : (hovered ? 0.24 : 0)))
                    .frame(width: vertical ? 64 : 88, height: vertical ? 88 : 64)
                    .offset(x: vertical ? -inward * 17 : 0, y: vertical ? 0 : -inward * 17)
                    .allowsHitTesting(false)
            }
            .onHover { hovered = $0 }
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

@MainActor
private struct LayoutWindowPicker: View {
    @ObservedObject var controller: MultiWindowLayoutController
    @ObservedObject var settings: AppSettings
    @FocusState private var searching: Bool
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
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(controller.filteredWindows.enumerated()), id: \.element.id) { index, choice in
                            Button { controller.chooseWindow(choice.id) } label: {
                                HStack(spacing: 8) {
                                    if let icon = choice.window.icon { Image(nsImage: icon).resizable().scaledToFit().frame(width: 28, height: 28) }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(choice.window.applicationName).font(.callout.bold())
                                        Text(choice.window.title).font(.caption).lineLimit(2)
                                        if let occupied = controller.assignedRegionNumber(for: choice.id) {
                                            Text(settings.text("已分配到区域 %@", String(occupied))).font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(controller.highlightedWindow == index ? Color.accentColor.opacity(0.15) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(choice.id)
                                .disabled(controller.assignedRegionNumber(for: choice.id) != nil)
                                .accessibilityAddTraits(controller.highlightedWindow == index ? .isSelected : [])
                                .accessibilityIdentifier("multiLayoutWindow-\(index)")
                        }
                        if !controller.isLoading && controller.filteredWindows.isEmpty {
                            Text(settings.text("没有可用窗口。仅支持当前桌面上可移动、可缩放的普通窗口。"))
                                .font(.callout).foregroundStyle(.secondary).padding(.vertical)
                        }
                    }
                }.onChange(of: controller.highlightedWindow) { _, index in
                    guard controller.filteredWindows.indices.contains(index) else { return }
                    proxy.scrollTo(controller.filteredWindows[index].id)
                }
            }
        }
        .onAppear { searching = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("multiLayoutWindowPicker")
    }
}
