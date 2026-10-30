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
    @State private var hoveredRegion: UUID?
    private let highlight = Color(red: 0.40, green: 0.71, blue: 1)

    var body: some View {
        GeometryReader { geometry in
            if let draft = controller.draft {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(draft.root.leaves.enumerated()), id: \.element.region.id) { index, leaf in
                        region(leaf, index: index, size: geometry.size)
                    }
                    ForEach(draft.root.placements(), id: \.region.id) { placement in
                        if case .split(_, let axis, let ratio, _, _) = placement.region {
                            divider(placement, axis: axis, ratio: ratio, size: geometry.size)
                        }
                    }
                }
            }
        }
        .coordinateSpace(name: "layoutCanvas")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("multiLayoutCanvas")
    }

    private func region(_ leaf: LayoutRegion.Placement, index: Int, size: CGSize) -> some View {
        let choice = controller.draft?.assignments[leaf.region.id].flatMap { id in controller.windows.first { $0.id == id } }
        let selected = controller.draft?.selectedRegion == leaf.region.id
        let width = leaf.frame.width * size.width
        let height = leaf.frame.height * size.height
        return ZStack {
            Button { controller.selectRegion(leaf.region.id) } label: {
                ZStack {
                    Rectangle().fill(selected ? highlight.opacity(0.22) : Color.white.opacity(0.055))
                    Rectangle().strokeBorder(selected ? highlight : .white.opacity(0.45), lineWidth: selected ? 3 : 1)
                    if height < 180 || width < 240 {
                        Text("\(index + 1) · " + (choice?.window.applicationName ?? settings.text("选择窗口")))
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1).truncationMode(.tail)
                            .padding(8).frame(maxWidth: max(0, width - 80))
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    } else {
                        VStack(spacing: 8) {
                            Text(settings.text("区域 %@", String(index + 1)))
                                .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.7))
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
                        .padding(12).frame(maxWidth: min(300, width - 80))
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(settings.text("区域 %@", String(index + 1)) + ": " + (choice?.window.title ?? settings.text("选择窗口")))
            .accessibilityIdentifier("multiLayoutRegion-\(index)")
            if (selected || hoveredRegion == leaf.region.id) && !controller.choosingWindow {
                splitButton(leaf.region.id, axis: .rows, index: index, edge: "top")
                    .position(x: width / 2, y: 20)
                splitButton(leaf.region.id, axis: .rows, index: index, edge: "bottom")
                    .position(x: width / 2, y: height - 20)
                splitButton(leaf.region.id, axis: .columns, index: index, edge: "left")
                    .position(x: 20, y: height / 2)
                splitButton(leaf.region.id, axis: .columns, index: index, edge: "right")
                    .position(x: width - 20, y: height / 2)
            }
        }
        .frame(width: width, height: height)
        .disabled(controller.isApplying || !controller.outcomes.isEmpty)
        .onHover { inside in
            if inside { hoveredRegion = leaf.region.id }
            else if hoveredRegion == leaf.region.id { hoveredRegion = nil }
        }
        .offset(x: leaf.frame.minX * size.width, y: leaf.frame.minY * size.height)
    }

    private func splitButton(_ id: UUID, axis: LayoutSplitAxis, index: Int, edge: String) -> some View {
        Button { controller.splitRegion(id, axis: axis) } label: {
            Image(systemName: axis == .rows ? "rectangle.split.1x2" : "rectangle.split.2x1")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .help(settings.text(axis == .rows ? "水平分裂" : "垂直分裂"))
        .accessibilityLabel(settings.text(axis == .rows ? "水平分裂" : "垂直分裂"))
        .accessibilityIdentifier("multiLayoutSplit-\(index)-\(edge)")
    }

    private func divider(_ placement: LayoutRegion.Placement, axis: LayoutSplitAxis, ratio: Double, size: CGSize) -> some View {
        let rect = placement.frame
        let vertical = axis == .columns
        return ZStack {
            Rectangle().fill(Color.white.opacity(0.001))
            Rectangle().fill(.white.opacity(0.6))
                .frame(width: vertical ? 2 : nil, height: vertical ? nil : 2)
        }
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
