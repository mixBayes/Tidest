import SwiftUI

@MainActor
struct SettingsView: View {
    static let windowSize = CGSize(width: 460, height: 680)
    // Grouped macOS forms already inset each row by 10pt.
    private static let sectionPadding: CGFloat = 2

    private enum SettingsTab { case windows, general }
    private enum ShortcutField { case switching, layout, multiLayout, pinning }

    @ObservedObject var permissions: PermissionStore
    @ObservedObject var settings: AppSettings
    var onShortcutChange: (WindowShortcut) -> String?
    var onRecordingChange: (Bool) -> Void
    var onLayoutShortcutChange: (WindowShortcut) -> String?
    var onMultiLayoutShortcutChange: (WindowShortcut?) -> String?
    var onPinShortcutChange: (WindowShortcut) -> String?
    var onPinEnabledChange: (Bool) -> Void
    @State private var selectedTab = SettingsTab.windows
    @State private var recordingShortcut: ShortcutField?
    @State private var shortcutMessage: String?
    @State private var layoutShortcutMessage: String?
    @State private var multiLayoutShortcutMessage: String?
    @State private var pinShortcutMessage: String?

    init(permissions: PermissionStore, settings: AppSettings? = nil,
         onShortcutChange: @escaping (WindowShortcut) -> String?,
         onRecordingChange: @escaping (Bool) -> Void,
         onLayoutShortcutChange: @escaping (WindowShortcut) -> String? = { _ in nil },
         onMultiLayoutShortcutChange: @escaping (WindowShortcut?) -> String? = { _ in nil },
         onPinShortcutChange: @escaping (WindowShortcut) -> String? = { _ in nil },
         onPinEnabledChange: @escaping (Bool) -> Void = { _ in }) {
        self.permissions = permissions
        self.settings = settings ?? .shared
        self.onShortcutChange = onShortcutChange
        self.onRecordingChange = onRecordingChange
        self.onLayoutShortcutChange = onLayoutShortcutChange
        self.onMultiLayoutShortcutChange = onMultiLayoutShortcutChange
        self.onPinShortcutChange = onPinShortcutChange
        self.onPinEnabledChange = onPinEnabledChange
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsTabs
            Divider()
            Group {
                switch selectedTab {
                case .windows:
                    Form {
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                displaySettings
                                Divider()
                                shortcutSettings
                            }
                            .padding(Self.sectionPadding)
                        }
                        Section {
                            quickLayoutSettings
                                .padding(Self.sectionPadding)
                        }
                        Section {
                            multiLayoutSettings.padding(Self.sectionPadding)
                        }
                        Section {
                            pinningSettings
                                .padding(Self.sectionPadding)
                        }
                    }
                    .accessibilityIdentifier("windowSettingsPanel")
                case .general:
                    VStack(alignment: .leading, spacing: 18) {
                        settingsGroup { languageSettings }
                        settingsGroup { anonymousUsageSettings }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(settings.text("权限"))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            settingsGroup { permissionSettings }
                        }
                    }
                    .padding(16)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("generalSettingsPanel")
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .font(.system(size: 13))
        .frame(width: Self.windowSize.width, height: selectedTab == .windows ? Self.windowSize.height : nil)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, settings.locale)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settingsPanel")
        .onAppear { permissions.refresh() }
        .onChange(of: selectedTab) { _, _ in stopRecording() }
        .onChange(of: settings.pinningEnabled) { _, enabled in
            if !enabled { stopRecording() }
        }
        .onDisappear { stopRecording() }
    }

    private var settingsTabs: some View {
        HStack(spacing: 2) {
            settingsTab(.windows, title: "窗口", identifier: "windowSettingsTab")
            settingsTab(.general, title: "通用", identifier: "generalSettingsTab")
        }
        .padding(3)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settingsTabs")
    }

    private static let brandAmber = Color(red: 0.83, green: 0.57, blue: 0.09)

    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
            }
    }

    private func settingsTab(_ tab: SettingsTab, title: String, identifier: String) -> some View {
        let selected = selectedTab == tab
        return Button { selectedTab = tab } label: {
            Text(settings.text(title))
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .frame(width: 80, height: 28)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 1)
                            }
                            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private var displaySettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingTitle("切换窗口", icon: "rectangle.3.group", iconColor: .accentColor)
            HStack(spacing: 12) {
                displayModeOption(.carousel, imageName: "ModeCarousel")
                displayModeOption(.tiled, imageName: "ModeTiled")
            }
        }
    }

    private var languageSettings: some View {
        HStack(spacing: 12) {
            settingTitle("语言", icon: "globe")
            Spacer()
            Picker(settings.text("语言"), selection: $settings.language) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .frame(width: 180, alignment: .trailing)
            .accessibilityIdentifier("languagePicker")
        }
    }

    private var anonymousUsageSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(settings.text("发送匿名使用信息"), isOn: $settings.anonymousUsageEnabled)
                .toggleStyle(.switch)
                .accessibilityIdentifier("anonymousUsageToggle")
            Text(settings.text("帮助了解 Tidest 每天的使用情况。仅发送随机安装标识、使用时间和应用版本，不包含窗口内容。"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortcutSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(settings.text("切换窗口快捷键"))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                ShortcutRecorder(shortcut: settings.shortcut, settings: settings,
                                 isRecording: recordingBinding(for: .switching),
                                 onChange: { shortcutMessage = onShortcutChange($0) },
                                 onInvalid: { shortcutMessage = "请按住 Control、Option 或 Command，再按另一个键。" },
                                 onRecordingChange: { recording in
                                     updateRecording(recording, for: .switching)
                                 }, labelKey: "切换窗口快捷键")
                    .frame(width: 180, height: 28)
            }
            HStack {
                Text(settings.text(recordingShortcut == .switching ? "按 Esc 取消" : "点击快捷键，再按下新组合"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(settings.text("恢复默认")) { shortcutMessage = onShortcutChange(.default) }
                    .disabled(settings.shortcut.hasSameKeys(as: .default) || isRecordingAnyShortcut)
                    .accessibilityIdentifier("resetShortcut")
            }
            if let message = shortcutMessage ?? permissions.shortcutMessage {
                Text(settings.text(message))
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("shortcutMessage")
            }
        }
    }

    private var quickLayoutSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            permissionLabel("单窗布局", purpose: "调整鼠标所指窗口的位置和大小", icon: "rectangle.split.2x2",
                            iconColor: Self.brandAmber)
            HStack(spacing: 12) {
                Text(settings.text("单窗布局快捷键"))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                ShortcutRecorder(shortcut: settings.layoutShortcut, settings: settings,
                                 isRecording: recordingBinding(for: .layout),
                                 onChange: { layoutShortcutMessage = onLayoutShortcutChange($0) },
                                 onInvalid: { layoutShortcutMessage = "请按住 Control、Option 或 Command，再按另一个键。" },
                                 onRecordingChange: { recording in updateRecording(recording, for: .layout) },
                                 accessibilityIdentifier: "layoutShortcutRecorder", labelKey: "单窗布局快捷键")
                    .frame(width: 180, height: 28)
            }
            HStack {
                Text(settings.text(recordingShortcut == .layout ? "按 Esc 取消" : "点击快捷键，再按下新组合"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(settings.text("恢复默认")) { layoutShortcutMessage = onLayoutShortcutChange(.quickLayout) }
                    .disabled(settings.layoutShortcut.hasSameKeys(as: .quickLayout) || isRecordingAnyShortcut)
                    .accessibilityIdentifier("resetLayoutShortcut")
            }
            if let message = layoutShortcutMessage ?? permissions.layoutShortcutMessage {
                Text(settings.text(message))
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("layoutShortcutMessage")
            }
        }
    }

    private var multiLayoutSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            permissionLabel("组合布局", purpose: "在屏幕上划分区域，一次排列多个窗口", icon: "rectangle.3.group",
                            iconColor: .accentColor)
            HStack {
                Text(settings.text("组合布局快捷键"))
                Spacer()
                ShortcutRecorder(shortcut: settings.multiLayoutShortcut, settings: settings,
                    isRecording: recordingBinding(for: .multiLayout),
                    onChange: { multiLayoutShortcutMessage = onMultiLayoutShortcutChange($0) },
                    onInvalid: { multiLayoutShortcutMessage = "请按住 Control、Option 或 Command，再按另一个键。" },
                    onRecordingChange: { updateRecording($0, for: .multiLayout) },
                    accessibilityIdentifier: "multiLayoutShortcutRecorder", labelKey: "组合布局快捷键")
                    .frame(width: 180, height: 28)
            }
            HStack {
                Text(settings.text(settings.multiLayoutShortcut == nil
                    ? "设置快捷键后，即可打开组合布局。"
                    : "按快捷键在屏幕上排列窗口。"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(settings.text("清除快捷键")) { multiLayoutShortcutMessage = onMultiLayoutShortcutChange(nil) }
                    .disabled(settings.multiLayoutShortcut == nil || isRecordingAnyShortcut)
                    .accessibilityIdentifier("clearMultiLayoutShortcut")
            }
            if let message = multiLayoutShortcutMessage ?? permissions.multiLayoutShortcutMessage {
                Text(settings.text(message)).font(.system(size: 11)).foregroundStyle(.orange)
                    .accessibilityIdentifier("multiLayoutShortcutMessage")
            }
        }
    }

    private var pinningSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { settings.pinningEnabled },
                set: { enabled in
                    if !enabled { stopRecording() }
                    onPinEnabledChange(enabled)
                }
            )) {
                permissionLabel("停靠窗口", purpose: "把常用窗口的预览放到屏幕侧边", icon: "sidebar.right", iconColor: Self.brandAmber)
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("pinningEnabledSwitch")

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(settings.text("停靠窗口快捷键"))
                    Spacer()
                    ShortcutRecorder(shortcut: settings.pinShortcut, settings: settings,
                                     isRecording: recordingBinding(for: .pinning),
                                     onChange: { pinShortcutMessage = onPinShortcutChange($0) },
                                     onInvalid: { pinShortcutMessage = "请按住 Control、Option 或 Command，再按另一个键。" },
                                     onRecordingChange: { recording in
                                         updateRecording(recording, for: .pinning)
                                     },
                                     accessibilityIdentifier: "pinShortcutRecorder", labelKey: "停靠窗口快捷键")
                        .frame(width: 180, height: 28)
                }
                HStack {
                    Text(settings.text(recordingShortcut == .pinning ? "按 Esc 取消" : "点击快捷键，再按下新组合"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(settings.text("恢复默认")) { pinShortcutMessage = onPinShortcutChange(.pinWindow) }
                        .disabled(settings.pinShortcut.hasSameKeys(as: .pinWindow) || isRecordingAnyShortcut)
                        .accessibilityIdentifier("resetPinShortcut")
                }
                Text(settings.text("按 %@，点击窗口后再点停靠栏", settings.pinShortcut.symbolDisplayName))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!settings.pinningEnabled)

            if let message = pinShortcutMessage ?? permissions.pinShortcutMessage {
                Text(settings.text(message))
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pinShortcutMessage")
            }
        }
    }

    private var isRecordingAnyShortcut: Bool { recordingShortcut != nil }

    private func recordingBinding(for field: ShortcutField) -> Binding<Bool> {
        Binding(get: { recordingShortcut == field }, set: { recording in
            if recording { recordingShortcut = field }
            else if recordingShortcut == field { recordingShortcut = nil }
        })
    }

    private func updateRecording(_ recording: Bool, for field: ShortcutField) {
        recordingBinding(for: field).wrappedValue = recording
        if recording {
            switch field {
            case .switching: shortcutMessage = nil
            case .layout: layoutShortcutMessage = nil
            case .multiLayout: multiLayoutShortcutMessage = nil
            case .pinning: pinShortcutMessage = nil
            }
        }
        onRecordingChange(isRecordingAnyShortcut)
    }

    private func stopRecording() {
        recordingShortcut = nil
        onRecordingChange(false)
    }

    private func settingTitle(_ title: String, icon: String, iconColor: Color = .accentColor) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(iconColor, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            Text(settings.text(title))
        }
        .accessibilityElement(children: .contain)
    }

    private func displayModeOption(_ mode: DisplayMode, imageName: String) -> some View {
        let selected = settings.displayMode == mode
        return Button { settings.displayMode = mode } label: {
            VStack(spacing: 5) {
                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 160, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(selected ? Color.accentColor : .secondary.opacity(0.2), lineWidth: selected ? 2 : 1)
                    }
                    .accessibilityHidden(true)
                HStack(spacing: 5) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .accessibilityHidden(true)
                    Text(settings.text(mode.titleKey))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(settings.text(mode.titleKey))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier(mode == .carousel ? "displayModeCarousel" : "displayModeTiled")
    }

    private var permissionSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            permissionRow("辅助功能 · 必需", purpose: "用于切换、布局和停靠窗口", icon: "accessibility",
                          granted: permissions.accessibilityGranted, identifier: "accessibilityPermission",
                          action: permissions.openAccessibilitySettings)
            Divider()
            permissionRow("屏幕录制 · 可选", purpose: "用于显示窗口预览", icon: "record.circle",
                          granted: permissions.screenCaptureGranted, identifier: "screenCapturePermission",
                          action: permissions.openScreenCaptureSettings)
            Divider()
            Text(settings.text("未开启时显示应用图标，仍可照常切换窗口。"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionRow(_ title: String, purpose: String, icon: String, granted: Bool,
                               identifier: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                permissionLabel(title, purpose: purpose, icon: icon)
                    .padding(.vertical, 4)
                Spacer()
                Text(settings.text(granted ? "已开启" : "未开启"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(granted ? .secondary : .primary)
                    .fixedSize()
                    .padding(.top, 4)
                    .accessibilityIdentifier(identifier + "Status")
            }
            HStack {
                Spacer()
                Button(settings.text("前往系统设置"), action: action)
                    .accessibilityLabel(settings.text("前往系统设置") + "，" + settings.text(title))
                    .accessibilityIdentifier(identifier + "Settings")
            }
        }
    }

    private func permissionLabel(_ title: String, purpose: String, icon: String,
                                 iconColor: Color = .accentColor) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(iconColor, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(settings.text(title))
                Text(settings.text(purpose))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
