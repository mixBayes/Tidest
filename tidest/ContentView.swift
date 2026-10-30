import SwiftUI

@MainActor
struct ContentView: View {
    static func windowSize(for guide: PermissionGuide) -> CGSize {
        guide == .granted ? CGSize(width: 460, height: 380) : CGSize(width: 540, height: 500)
    }

    @ObservedObject var permissions: PermissionStore
    @ObservedObject var settings: AppSettings
    var guide: PermissionGuide
    var onFinish: () -> Void
    var onQuit: () -> Void

    init(permissions: PermissionStore, settings: AppSettings? = nil, guide: PermissionGuide,
         onFinish: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.permissions = permissions
        self.settings = settings ?? .shared
        self.guide = guide
        self.onFinish = onFinish
        self.onQuit = onQuit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: iconName)
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(iconColor, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(settings.text(titleKey))
                        .font(.system(size: 22, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let permissionKey {
                        Text(settings.text(permissionKey))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(settings.text(purposeKey))
                if let consequenceKey {
                    Text(settings.text(consequenceKey))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 13))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)

            if guide == .granted {
                Text(settings.text("按住 %@，按 %@ 选择，松开切换",
                                   settings.shortcut.modifierName, settings.shortcut.keyName))
                    .font(.system(size: 13, weight: .medium))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("startUsingShortcut")
            } else {
                settingsExample
                VStack(alignment: .leading, spacing: 10) {
                    instruction(1, "点击“打开系统设置”")
                    instruction(2, "找到 Tidest，打开旁边的开关")
                    Text(settings.text("回到这里，会自动检查是否开启"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 30)
                }
                .font(.system(size: 13))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("permissionSteps")
            }

            if guide == .screenCapture {
                Toggle(settings.text("下次不再提醒"), isOn: $permissions.screenCaptureReminderSuppressed)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .accessibilityIdentifier("suppressScreenCaptureReminder")
            }

            Spacer(minLength: 0)
            actions
        }
        .padding(.horizontal, 26)
        .padding(.top, 26)
        .padding(.bottom, 16)
        .frame(width: Self.windowSize(for: guide).width, height: Self.windowSize(for: guide).height, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, settings.locale)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("permissionGuide")
    }

    private var settingsExample: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "gearshape")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(settings.text("系统设置") + " › " + settings.text("隐私与安全性"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(settings.text(guide == .accessibility ? "辅助功能" : "屏幕录制"))
                        .font(.system(size: 13, weight: .medium))
                }
                Spacer(minLength: 0)
                Text(settings.text("示例"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            // A crop of the actual System Settings app row. The same row and
            // switch appear in both privacy lists; surrounding labels stay localised.
            Image("PermissionAppRow")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .overlay(alignment: .trailing) {
                    Capsule()
                        .stroke(Color.accentColor, lineWidth: 2)
                        .frame(width: 42, height: 24)
                        .padding(.trailing, 8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.quaternary, lineWidth: 1)
        }
        .accessibilityIdentifier("permissionSettingsExample")
    }

    private func instruction(_ number: Int, _ key: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(String(number))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20, height: 20)
                .background(Color.accentColor.opacity(0.1), in: Circle())
                .accessibilityHidden(true)
            Text(settings.text(key))
        }
    }

    private var titleKey: String {
        switch guide {
        case .accessibility: "允许切换窗口"
        case .screenCapture: "显示窗口预览"
        case .granted: "开始使用 Tidest"
        }
    }

    private var permissionKey: String? {
        switch guide {
        case .accessibility: "辅助功能 · 必需"
        case .screenCapture: "屏幕录制 · 可选"
        case .granted: nil
        }
    }

    private var purposeKey: String {
        switch guide {
        case .accessibility: "用于切换到你选择的窗口。"
        case .screenCapture: "用于显示窗口预览。停靠预览保存在本机。"
        case .granted: permissions.screenCaptureGranted
            ? "现在可以切换窗口并查看预览。" : "现在可以切换窗口。"
        }
    }

    private var consequenceKey: String? {
        switch guide {
        case .accessibility: "未开启时，无法使用 Tidest。"
        case .screenCapture: "未开启时显示应用图标，仍可照常切换窗口。"
        case .granted: nil
        }
    }

    private var iconName: String {
        switch guide {
        case .accessibility: "accessibility"
        case .screenCapture: "record.circle"
        case .granted: "checkmark"
        }
    }

    private var iconColor: Color {
        switch guide {
        case .accessibility: .blue
        case .screenCapture: .blue
        case .granted: .green
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            switch guide {
            case .accessibility:
                Button(settings.text("退出 Tidest"), action: onQuit)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("quitPermissionGuide")
                Button(settings.text("打开系统设置")) { permissions.requestAccessibility() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("grantAccessibility")
            case .screenCapture:
                Button(settings.text("暂不开启"), action: onFinish)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("skipScreenCapture")
                Button(settings.text("打开系统设置")) { permissions.requestScreenCapture() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("grantScreenCapture")
            case .granted:
                Button(settings.text("开始使用"), action: onFinish)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("closePermissionGuide")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

#Preview {
    ContentView(permissions: PermissionStore(preview: true), guide: .screenCapture, onFinish: {}, onQuit: {})
}
