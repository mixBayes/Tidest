import AppKit
import SwiftUI

@MainActor
struct AboutView: View {
    static let windowSize = CGSize(width: 320, height: 250)
    @ObservedObject var settings: AppSettings
    @StateObject private var updateChecker: UpdateChecker
    var onUpdateAvailable: () -> Void

    init(settings: AppSettings, updateChecker: UpdateChecker, onUpdateAvailable: @escaping () -> Void) {
        self.settings = settings
        _updateChecker = StateObject(wrappedValue: updateChecker)
        self.onUpdateAvailable = onUpdateAvailable
    }

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
            HStack(spacing: 6) {
                if updateChecker.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("updateProgress")
                }
                if case .readyToInstall = updateChecker.state {
                    Button(settings.text("重启并更新")) { updateChecker.restartAndInstall() }
                        .accessibilityIdentifier("restartAndUpdate")
                } else if case .updateAvailable = updateChecker.state {
                    Button(settings.text("下载")) { updateChecker.downloadUpdate() }
                        .accessibilityIdentifier("downloadUpdate")
                } else if case .downloading = updateChecker.state {
                    Button(settings.text("取消下载")) { updateChecker.cancelDownload() }
                        .accessibilityIdentifier("cancelUpdateDownload")
                } else if !updateChecker.isBusy || updateChecker.state == .checking {
                    Button(settings.text(updateChecker.state == .checking ? "正在检查…" : "检查更新")) {
                        updateChecker.checkForUpdates()
                    }
                    .disabled(updateChecker.isBusy)
                    .accessibilityIdentifier("checkForUpdates")
                }
            }
            .padding(.top, 6)
            Text(updateStatus)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(minHeight: 14)
                .padding(.horizontal, 22)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("updateStatus")
            if case .downloading = updateChecker.state {
                VStack(spacing: 5) {
                    if let progress = updateChecker.downloadProgress {
                        ProgressView(value: progress)
                            .accessibilityIdentifier("updateDownloadProgress")
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(downloadSize).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(width: 230)
            }
            if case .manualUpdate(_, let url) = updateChecker.state {
                Link(settings.text("前往下载"), destination: url)
            }
        }
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: Self.windowSize.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, settings.locale)
        .task { updateChecker.showUpdateStatus() }
        .onChange(of: updateChecker.state) { _, state in
            if case .updateAvailable = state, updateChecker.shouldPromptForDownload { onUpdateAvailable() }
        }
    }

    private var updateStatus: String {
        switch updateChecker.state {
        case .idle, .checking:
            return ""
        case .upToDate:
            return settings.text("已是最新版本")
        case .updateAvailable(let version):
            return settings.text("发现新版本 %@", version)
        case .downloading(let version):
            return settings.text("正在下载 Tidest %@…", version)
        case .preparing:
            return settings.text("正在准备更新…")
        case .readyToInstall:
            return settings.text("更新已准备好。现在重启，或在下次退出 Tidest 时完成更新。")
        case .installing:
            return settings.text("正在重启并更新…")
        case .unavailable:
            return settings.text("暂时没有适合这台 Mac 的更新。")
        case .manualUpdate(let version, _):
            return settings.text("Tidest %@ 需要手动下载。", version)
        case .installFromApplications:
            return settings.text("请先将 Tidest 放入“应用程序”，再检查更新。")
        case .checkFailed:
            return settings.text("暂时无法检查更新，请稍后重试。")
        case .updateFailed:
            return settings.text("更新未完成，请稍后重试。你可以继续使用当前版本。")
        }
    }

    private var downloadSize: String {
        let received = ByteCountFormatter.string(fromByteCount: Int64(clamping: updateChecker.downloadedBytes), countStyle: .file)
        guard updateChecker.expectedBytes > 0 else { return received }
        let total = ByteCountFormatter.string(fromByteCount: Int64(clamping: updateChecker.expectedBytes), countStyle: .file)
        return "\(received) / \(total)"
    }
}
