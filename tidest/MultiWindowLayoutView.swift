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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if controller.displayInvalidated {
                HStack {
                    Label(settings.text("显示器配置已变化，请重新确认目标显示器。"), systemImage: "display.trianglebadge.exclamationmark")
                    Spacer()
                    Button(settings.text("重新确认显示器")) {
                        if let id = controller.target?.id { controller.selectDisplay(id) }
                    }
                }.foregroundStyle(.orange)
            }
            if let message = controller.messageKey ?? templates.errorKey {
                Text(settings.text(message)).foregroundStyle(.orange).font(.callout)
                    .accessibilityIdentifier("multiLayoutMessage")
            }
            if controller.hasSmallRegions {
                Text(settings.text("区域过小，请合并区域或选择更大的显示器。" )).foregroundStyle(.orange).font(.callout)
            }
            if controller.draft == nil && controller.outcomes.isEmpty { gallery }
            else { editor }
            Divider()
            footer
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, settings.locale)
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

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(settings.text("快速布局")).font(.title2.bold())
                Text(settings.text("先选结构，再填窗口；应用前，真实窗口保持原位。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(controller.displays) { display in
                    Button(display.name) { controller.selectDisplay(display.id) }
                }
            } label: {
                Label(controller.target?.name ?? settings.text("目标显示器"), systemImage: "display")
            }
            .disabled(controller.isApplying)
            .accessibilityIdentifier("multiLayoutDisplay")
        }
    }

    private var gallery: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(settings.text("选择布局起点")).font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 14) {
                    ForEach(LayoutStartingPoint.allCases) { start in
                        templateCard(title: settings.text(start.titleKey), root: start.makeRegion()) {
                            controller.request(.replace(start.makeRegion()))
                        }
                        .accessibilityIdentifier("multiLayoutStart-\(start.rawValue)")
                    }
                }
                Button { controller.request(.replace(.leaf(UUID()))) } label: {
                    Label(settings.text("空白布局"), systemImage: "plus.rectangle")
                }.accessibilityIdentifier("multiLayoutBlank")
                if !templates.templates.isEmpty {
                    Text(settings.text("我的模板")).font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 14) {
                        ForEach(templates.templates) { template in
                            templateCard(title: template.name, root: template.root) { controller.request(.replace(template.root)) }
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

    private var editor: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Menu(settings.text("更换起点")) {
                        ForEach(LayoutStartingPoint.allCases) { start in
                            Button(settings.text(start.titleKey)) { controller.request(.replace(start.makeRegion())) }
                        }
                        Button(settings.text("空白布局")) { controller.request(.replace(.leaf(UUID()))) }
                        ForEach(templates.templates) { template in
                            Button(template.name) { controller.request(.replace(template.root)) }
                        }
                    }
                    Button(settings.text("撤销草稿编辑")) { controller.undoDraft() }
                        .disabled(controller.draft?.canUndo != true)
                        .accessibilityIdentifier("multiLayoutUndoDraft")
                    Spacer()
                    Button(settings.text("保存为模板")) { beginNaming(nil) }
                        .disabled(templates.errorKey != nil)
                        .accessibilityIdentifier("multiLayoutSaveTemplate")
                }.disabled(controller.isApplying || !controller.outcomes.isEmpty)
                if let draft = controller.draft {
                    let missing = draft.root.leafIDs.filter { id in
                        guard let assigned = draft.assignments[id] else { return true }
                        return !controller.windows.contains { $0.id == assigned }
                    }.count
                    if missing > 0 {
                        Text(settings.text("还需选择 %@ 个窗口", String(missing))).font(.callout).foregroundStyle(.secondary)
                    }
                }
                LayoutDraftCanvas(controller: controller, settings: settings)
                    .aspectRatio(previewAspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if controller.confirming {
                    Label(settings.text("按 Enter 应用布局，按 Esc 返回编辑。"), systemImage: "return")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityIdentifier("multiLayoutConfirming")
                } else {
                    Text(settings.text("点击区域选择窗口；拖动分隔线调整比例。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if controller.undoAvailable {
                    Text(settings.text("再次应用将替换最近一次可撤销操作。" )).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Group {
                if !controller.outcomes.isEmpty { results }
                else if controller.choosingWindow { LayoutWindowPicker(controller: controller, settings: settings) }
                else { inspector }
            }.frame(width: 240)
        }
    }

    private var previewAspectRatio: CGFloat {
        guard let frame = controller.target?.visibleFrame, frame.height > 0 else { return 16.0 / 10 }
        return frame.width / frame.height
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(settings.text("编辑选中区域")).font(.headline)
            Button(settings.text("选择窗口")) {
                if let id = controller.draft?.selectedRegion { controller.selectRegion(id) }
            }.accessibilityIdentifier("multiLayoutChooseWindow")
            Button(settings.text("清除窗口选择")) { controller.clearWindow() }
                .disabled(controller.draft?.selectedRegion.flatMap { controller.draft?.assignments[$0] } == nil)
            Divider()
            Button { controller.request(.split(.columns)) } label: {
                Label(settings.text("左右分割"), systemImage: "rectangle.split.2x1")
            }.accessibilityIdentifier("multiLayoutSplitColumns")
            Button { controller.request(.split(.rows)) } label: {
                Label(settings.text("上下分割"), systemImage: "rectangle.split.1x2")
            }.accessibilityIdentifier("multiLayoutSplitRows")
            Button(settings.text("合并同次分割")) { controller.request(.merge) }
                .disabled(controller.draft?.mergeRegion == nil)
                .accessibilityIdentifier("multiLayoutMerge")
            Spacer()
            Text(settings.text("模板只保存结构和比例，不保存窗口或显示器。"))
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(controller.isApplying)
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
        }.disabled(controller.isApplying).accessibilityIdentifier("multiLayoutResults")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(settings.text("撤销上次应用")) { controller.undoApplication() }
                .disabled(!controller.undoAvailable || controller.isApplying)
                .accessibilityIdentifier("multiLayoutUndoApplication")
            Text(settings.text("尽力撤销；多窗口操作可能部分成功。"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if controller.isLoading || controller.isApplying { ProgressView().controlSize(.small) }
            Button(settings.text("取消")) { controller.dismiss() }.disabled(controller.isApplying)
            Button(settings.text(controller.isApplying ? "正在应用…" : "应用布局")) { controller.apply() }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.canApply)
                .accessibilityIdentifier("multiLayoutApply")
        }
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
                .onAppear { controller.canvasSize = geometry.size }
                .onChange(of: geometry.size) { _, value in controller.canvasSize = value }
            }
        }
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .coordinateSpace(name: "layoutCanvas")
        .accessibilityIdentifier("multiLayoutCanvas")
    }

    private func region(_ leaf: LayoutRegion.Placement, index: Int, size: CGSize) -> some View {
        let choice = controller.draft?.assignments[leaf.region.id].flatMap { id in controller.windows.first { $0.id == id } }
        let selected = controller.draft?.selectedRegion == leaf.region.id
        return Button { controller.selectRegion(leaf.region.id) } label: {
            VStack(spacing: 6) {
                Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if let choice {
                    if let icon = choice.window.icon { Image(nsImage: icon).resizable().scaledToFit().frame(width: 28, height: 28) }
                    Text(choice.window.applicationName).font(.callout.bold()).lineLimit(1)
                    Text(choice.window.title).font(.caption).lineLimit(2)
                } else {
                    Image(systemName: "plus").font(.title3)
                    Text(settings.text(controller.draft?.assignments[leaf.region.id] == nil ? "选择窗口" : "窗口已失效，请重新选择。"))
                        .font(.caption).lineLimit(2)
                }
                if controller.sizeConflicts.contains(leaf.region.id) {
                    Text(settings.text("窗口尺寸受限，请调整区域后重试。" )).font(.caption2).foregroundStyle(.orange)
                }
                if controller.confirming, let area = controller.target?.layoutArea {
                    Text("\(Int(leaf.frame.width * area.width)) × \(Int(leaf.frame.height * area.height))").font(.caption2)
                }
            }.padding(8)
                .frame(width: max(0, leaf.frame.width * size.width - 6), height: max(0, leaf.frame.height * size.height - 6))
                .background(selected ? Color.accentColor.opacity(0.13) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controller.isApplying || !controller.outcomes.isEmpty)
        .accessibilityLabel(settings.text("区域 %@", String(index + 1)) + ": " + (choice?.window.title ?? settings.text("选择窗口")))
        .accessibilityIdentifier("multiLayoutRegion-\(index)")
        .offset(x: leaf.frame.minX * size.width + 3, y: leaf.frame.minY * size.height + 3)
    }

    private func divider(_ placement: LayoutRegion.Placement, axis: LayoutSplitAxis, ratio: Double, size: CGSize) -> some View {
        let rect = placement.frame
        let vertical = axis == .columns
        return RoundedRectangle(cornerRadius: 3)
            .fill(Color.secondary.opacity(0.35))
            .frame(width: vertical ? 6 : rect.width * size.width,
                   height: vertical ? rect.height * size.height : 6)
            .contentShape(Rectangle())
            .offset(x: vertical ? (rect.minX + rect.width * ratio) * size.width - 3 : rect.minX * size.width,
                    y: vertical ? rect.minY * size.height : (rect.minY + rect.height * ratio) * size.height - 3)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("layoutCanvas"))
                .onChanged { value in
                    let fraction = vertical ? (value.location.x / size.width - rect.minX) / rect.width : (value.location.y / size.height - rect.minY) / rect.height
                    controller.resize(placement.region.id, ratio: fraction, ended: false)
                }
                .onEnded { value in
                    let fraction = vertical ? (value.location.x / size.width - rect.minX) / rect.width : (value.location.y / size.height - rect.minY) / rect.height
                    controller.resize(placement.region.id, ratio: fraction, ended: true)
                })
            .allowsHitTesting(!controller.isApplying && controller.outcomes.isEmpty)
            .accessibilityLabel(settings.text(vertical ? "左右分隔线" : "上下分隔线"))
            .accessibilityValue("\(Int(ratio * 100))%")
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
                            }.buttonStyle(.plain).id(index)
                                .disabled(controller.assignedRegionNumber(for: choice.id) != nil)
                                .accessibilityAddTraits(controller.highlightedWindow == index ? .isSelected : [])
                                .accessibilityIdentifier("multiLayoutWindow-\(index)")
                        }
                        if !controller.isLoading && controller.filteredWindows.isEmpty {
                            Text(settings.text("没有可用窗口。仅支持当前桌面上可移动、可缩放的普通窗口。"))
                                .font(.callout).foregroundStyle(.secondary).padding(.vertical)
                        }
                    }
                }.onChange(of: controller.highlightedWindow) { _, index in proxy.scrollTo(index) }
            }
        }
        .onAppear { searching = true }
        .accessibilityIdentifier("multiLayoutWindowPicker")
    }
}
