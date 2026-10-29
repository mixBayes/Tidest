import AppKit
import Combine
import OSLog
import Sparkle

/// Owns the session independently of About. Sparkle owns downloading, signature
/// validation, staging, replacement and relaunch; this class owns the UI choices.
@MainActor
final class UpdateChecker: NSObject, ObservableObject, SPUUserDriver, SPUUpdaterDelegate {
    struct AvailableUpdate: Equatable {
        let build: String
        let version: String
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case unavailable
        case updateAvailable(version: String)
        case downloading(version: String)
        case preparing(version: String)
        case readyToInstall(version: String)
        case installing(version: String)
        case manualUpdate(version: String, url: URL)
        case installFromApplications
        case checkFailed
        case updateFailed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var downloadedBytes: UInt64 = 0
    @Published private(set) var expectedBytes: UInt64 = 0
    @Published private(set) var availableUpdate: AvailableUpdate?
    private(set) var shouldPromptForDownload = false
    var onReadyToInstall: (() -> Void)?
    var onFocus: (() -> Void)?

    private var updater: SPUUpdater?
    private var availabilityObservation: AnyCancellable?
    private var waitingForUserCheck = false
    private let check: ((UpdateChecker) -> Void)?
    private let defaults: UserDefaults
    private var choice: ((SPUUserUpdateChoice) -> Void)?
    private var cancellation: (() -> Void)?
    private var version = ""
    private var pendingAction: (version: String, restart: Bool)?
    private let logger = Logger(subsystem: "com.mixbayes.tidest", category: "Updates")

    // The injected check is used by tests and UI previews, never by releases.
    init(defaults: UserDefaults = .standard,
         currentBuild: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
         check: ((UpdateChecker) -> Void)? = nil) {
        self.check = check
        self.defaults = defaults
        if let saved = defaults.dictionary(forKey: "updates.available") as? [String: String],
           let build = saved["build"], let version = saved["version"], let currentBuild,
           SUStandardVersionComparator.default.compareVersion(build, toVersion: currentBuild) == .orderedDescending {
            availableUpdate = AvailableUpdate(build: build, version: version)
            self.version = version
            state = .updateAvailable(version: version)
        } else {
            defaults.removeObject(forKey: "updates.available")
        }
        super.init()
    }

    var needsUpdateReminder: Bool {
        guard let availableUpdate else { return false }
        return !(defaults.stringArray(forKey: "updates.remindedVersions") ?? []).contains(availableUpdate.version)
    }

    func markUpdateReminderShown() {
        guard let availableUpdate, needsUpdateReminder else { return }
        var versions = defaults.stringArray(forKey: "updates.remindedVersions") ?? []
        versions.append(availableUpdate.version)
        defaults.set(versions, forKey: "updates.remindedVersions")
    }

    /// Start Sparkle's own persisted schedule; do not add a second timer or
    /// force a network request every time Tidest is restarted.
    func start() {
        guard check == nil else { return }
        do { try startUpdater() }
        catch { log(error, operation: "Could not start scheduled checks") }
    }

    private func startUpdater() throws {
        guard updater == nil else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                                 userDriver: self, delegate: self)
        try updater.start()
        self.updater = updater
        availabilityObservation = updater.publisher(for: \.sessionInProgress)
            .receive(on: RunLoop.main)
            .sink { [weak self] inProgress in
                guard let self, !inProgress, waitingForUserCheck,
                      self.updater?.sessionInProgress == false else { return }
                waitingForUserCheck = false
                beginUserCheck()
            }
    }

    private func log(_ error: Error, operation: String) {
        let error = error as NSError
        logger.error("\(operation, privacy: .public): \(error.domain, privacy: .public) (\(error.code))")
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .preparing, .installing: true
        default: false
        }
    }

    var downloadProgress: Double? {
        guard expectedBytes > 0 else { return nil }
        return min(Double(downloadedBytes) / Double(expectedBytes), 1)
    }

    func showUpdateStatus() {
        guard !isBusy else { return }
        switch state {
        case .updateAvailable, .readyToInstall, .manualUpdate: return
        default: break
        }
        if let availableUpdate {
            version = availableUpdate.version
            shouldPromptForDownload = false
            state = .updateAvailable(version: availableUpdate.version)
        } else {
            checkForUpdates()
        }
    }

    func checkForUpdates() {
        guard !isBusy else { return }
        guard choice == nil else { return }
        // An existing offer is shown in About. Buttons below revalidate it when
        // its Sparkle session has already been dismissed to allow scheduling.
        switch state {
        case .updateAvailable, .readyToInstall: return
        default: break
        }
        beginUserCheck()
    }

    private func beginUserCheck() {
        state = .checking
        if let check {
            check(self)
            return
        }
        do {
            try startUpdater()
            // A user may open About during a scheduled network request or
            // Sparkle's brief installer-status probe. Wait for that session.
            guard updater?.sessionInProgress == false else {
                waitingForUserCheck = true
                return
            }
            updater?.checkForUpdates()
        } catch {
            pendingAction = nil
            log(error, operation: "Could not start updater")
            state = .checkFailed
        }
    }

    func downloadUpdate() {
        guard case .updateAvailable = state else { return }
        guard let reply = choice else {
            pendingAction = (version, false)
            beginUserCheck()
            return
        }
        choice = nil
        state = .downloading(version: version)
        reply(.install)
    }

    func restartAndInstall() {
        guard case .readyToInstall = state else { return }
        guard let reply = choice else {
            pendingAction = (version, true)
            beginUserCheck()
            return
        }
        choice = nil
        state = .installing(version: version)
        reply(.install)
    }

    /// Keep the badge and visible offer, but release Sparkle's session so its
    /// next scheduled check can find a newer release. Staged updates stay on disk.
    func deferUpdate() {
        switch state {
        case .updateAvailable, .readyToInstall:
            let reply = choice
            choice = nil
            reply?(.dismiss)
        default: break
        }
    }

    func cancelDownload() {
        guard case .downloading = state, let cancel = cancellation else { return }
        cancellation = nil
        state = .idle
        cancel()
    }

    func offerUpdate(version: String, stage: SPUUserUpdateStage,
                     build: String? = nil, userInitiated: Bool = true,
                     informationURL: URL? = nil, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let pendingAction = userInitiated ? self.pendingAction : nil
        if userInitiated { self.pendingAction = nil }
        self.version = version
        shouldPromptForDownload = userInitiated
        let available = AvailableUpdate(build: build ?? version, version: version)
        defaults.set(["build": available.build, "version": available.version], forKey: "updates.available")
        availableUpdate = available
        if let informationURL {
            state = informationURL.scheme == "https" ? .manualUpdate(version: version, url: informationURL) : .unavailable
            reply(.dismiss)
            return
        }
        if !userInitiated {
            shouldPromptForDownload = false
            state = stage == .installing ? .readyToInstall(version: version) : .updateAvailable(version: version)
            if self.pendingAction == nil { waitingForUserCheck = false }
            reply(.dismiss)
            return
        }
        choice = reply
        if let pendingAction, pendingAction.version == version,
           pendingAction.restart == (stage == .installing) {
            choice = nil
            state = pendingAction.restart ? .installing(version: version) : .downloading(version: version)
            reply(.install)
            return
        }
        if stage == .installing {
            state = .readyToInstall(version: version)
            onReadyToInstall?()
        } else {
            state = .updateAvailable(version: version)
        }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, automaticUpdateDownloading: NSNumber(value: false), sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        state = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancellation = nil
        if appcastItem.isInformationOnlyUpdate, appcastItem.infoURL == nil {
            self.state = .unavailable
            reply(.dismiss)
            return
        }
        offerUpdate(version: appcastItem.displayVersionString, stage: state.stage,
                    build: appcastItem.versionString, userInitiated: state.userInitiated,
                    informationURL: appcastItem.isInformationOnlyUpdate ? appcastItem.infoURL : nil, reply: reply)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    // Optional release notes must not stop the update when their request fails.
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        pendingAction = nil
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        if reason?.intValue == Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue)
            || reason?.intValue == Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue) {
            state = .upToDate
        } else {
            state = .unavailable
        }
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let error = error as NSError
        logger.error("Update failed: \(error.domain, privacy: .public) (\(error.code))")
        choice = nil
        cancellation = nil
        pendingAction = nil
        if error.domain == SUSparkleErrorDomain,
           [Int(SUError.runningFromDiskImageError.rawValue), Int(SUError.runningTranslocated.rawValue)].contains(error.code) {
            state = .installFromApplications
        } else {
            state = state == .checking ? .checkFailed : .updateFailed
        }
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        downloadedBytes = 0
        expectedBytes = 0
        state = .downloading(version: version)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        downloadedBytes += length
    }

    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        state = .preparing(version: version)
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        choice = reply
        state = .readyToInstall(version: version)
        onReadyToInstall?()
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                             retryTerminatingApplication: @escaping () -> Void) {
        state = .installing(version: version)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        choice = nil
        cancellation = nil
        switch state {
        case .checking, .downloading, .preparing, .installing:
            state = .idle
        default: break // Keep the outcome visible after Sparkle ends its session.
        }
    }

    func showUpdateInFocus() { onFocus?() }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        // A background failure must not replace a known update badge or display
        // an error window. Sparkle schedules the next check itself.
        if updateCheck == .updatesInBackground, let error { log(error, operation: "Scheduled check failed") }
    }
}

#if DEBUG
extension UpdateChecker {
    static func preview(outcome: String) -> UpdateChecker {
        let defaults = UserDefaults(suiteName: "com.mixbayes.tidest.preview.updates")!
        if !outcome.hasPrefix("background") || ProcessInfo.processInfo.arguments.contains("--ui-preview-reset-update-reminders") {
            defaults.removePersistentDomain(forName: "com.mixbayes.tidest.preview.updates")
        }
        let previewVersion = outcome.contains("newer") ? "2.0.10" : "2.0.9"
        let previewBuild = outcome.contains("newer") ? "3" : "2"
        var staged = false
        let checker = UpdateChecker(defaults: defaults, currentBuild: "1") { checker in
            Task { @MainActor [weak checker] in
                try? await Task.sleep(for: .seconds(outcome == "checking" ? 30 : (outcome == "failed" ? 3 : 1)))
                guard let checker else { return }
                if staged {
                    checker.offerUpdate(version: previewVersion, stage: .installing, build: previewBuild) { [weak checker] choice in
                        if choice == .dismiss { checker?.dismissUpdateInstallation() }
                    }
                    return
                }
                if outcome == "failed" {
                    checker.showUpdaterError(URLError(.notConnectedToInternet), acknowledgement: {})
                } else if outcome == "up-to-date" {
                    checker.showUpdateNotFoundWithError(NSError(domain: SUSparkleErrorDomain, code: 1001,
                        userInfo: [SPUNoUpdateFoundReasonKey: SPUNoUpdateFoundReason.onLatestVersion.rawValue]), acknowledgement: {})
                } else {
                    checker.offerUpdate(version: previewVersion, stage: .notDownloaded, build: previewBuild) { [weak checker] choice in
                        guard choice == .install, let checker else { return }
                        checker.showDownloadInitiated { [weak checker] in checker?.dismissUpdateInstallation() }
                        checker.showDownloadDidReceiveExpectedContentLength(10_000_000)
                        Task { @MainActor [weak checker] in
                            for _ in 0..<10 {
                                try? await Task.sleep(for: .milliseconds(outcome == "downloading" ? 3_000 : 150))
                                guard let checker, case .downloading = checker.state else { return }
                                checker.showDownloadDidReceiveData(ofLength: 1_000_000)
                            }
                            guard let checker else { return }
                            if outcome == "download-failed" {
                                checker.showUpdaterError(URLError(.networkConnectionLost), acknowledgement: {})
                                return
                            }
                            checker.showDownloadDidStartExtractingUpdate()
                            try? await Task.sleep(for: .milliseconds(500))
                            staged = true
                            checker.showReady(toInstallAndRelaunch: { [weak checker] choice in
                                guard choice == .dismiss, let checker else { return }
                                checker.dismissUpdateInstallation()
                            })
                        }
                    }
                }
            }
        }
        if outcome.hasPrefix("background") {
            Task { @MainActor [weak checker] in
                try? await Task.sleep(for: .seconds(1))
                guard let checker else { return }
                checker.offerUpdate(version: previewVersion, stage: .notDownloaded, build: previewBuild,
                                    userInitiated: false) { [weak checker] _ in checker?.dismissUpdateInstallation() }
            }
        }
        return checker
    }
}
#endif
