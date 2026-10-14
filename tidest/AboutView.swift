import AppKit
import SwiftUI

struct AboutView: View {
    static let windowSize = CGSize(width: 320, height: 280)
    @ObservedObject var settings: AppSettings
    @StateObject private var updateChecker = UpdateChecker()

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text("Tidest").font(.system(size: 21, weight: .semibold))
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                Text(settings.text("版本 %@", version))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("appVersion")
            }
            Button(settings.text(updateChecker.state == .checking ? "正在检查…" : "检查更新"), systemImage: "arrow.clockwise") {
                Task { await updateChecker.checkForUpdates() }
            }
                .disabled(updateChecker.state == .checking)
                .accessibilityIdentifier("checkForUpdates")
                .padding(.top, 6)
            Text(updateStatus)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(height: 40)
                .padding(.horizontal, 22)
                .accessibilityIdentifier("updateStatus")
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, settings.locale)
    }

    private var updateStatus: String {
        switch updateChecker.state {
        case .idle, .checking:
            return ""
        case .upToDate:
            return settings.text("已是最新版本")
        case .downloadOpened(let version):
            return settings.text("已在浏览器中打开 %@ 的下载链接。", version)
        case .checkFailed:
            return settings.text("暂时无法检查更新，请稍后重试。")
        case .downloadFailed:
            return settings.text("无法打开下载链接，请稍后重试。")
        }
    }
}
