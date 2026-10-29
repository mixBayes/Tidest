import AppKit
import Sparkle
import XCTest
@testable import tidest

@MainActor
final class AutomaticUpdateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var domain: String!

    override func setUp() {
        domain = "com.mixbayes.tidest.tests.reminders." + UUID().uuidString
        defaults = UserDefaults(suiteName: domain)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: domain)
    }

    func testDailyScheduleOnlyChecksAndDoesNotAutomaticallyDownload() {
        let info = Bundle.main.infoDictionary!
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info["SUScheduledCheckInterval"] as? Int, 86_400)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false)
    }

    func testBackgroundOfferEndsItsSessionWithoutDownloadOrModalPrompt() {
        let checker = makeChecker()
        var replies: [SPUUserUpdateChoice] = []
        checker.offerUpdate(version: "2.0.9", stage: .notDownloaded, build: "2", userInitiated: false) { replies.append($0) }
        checker.dismissUpdateInstallation()
        XCTAssertEqual(replies, [.dismiss])
        XCTAssertEqual(checker.state, .updateAvailable(version: "2.0.9"))
        XCTAssertFalse(checker.shouldPromptForDownload)
        XCTAssertEqual(checker.availableUpdate?.version, "2.0.9")
        XCTAssertTrue(checker.needsUpdateReminder)
    }

    func testReminderIsOncePerVersionAcrossRestartsAndFutureVersionsStillNotify() {
        let checker = makeChecker()
        offerBackground(checker, version: "2.0.9", build: "2")
        checker.markUpdateReminderShown()
        checker.markUpdateReminderShown()
        let restarted = makeChecker()
        XCTAssertEqual(restarted.availableUpdate?.version, "2.0.9")
        XCTAssertFalse(restarted.needsUpdateReminder)
        offerBackground(restarted, version: "2.0.10", build: "3")
        XCTAssertTrue(restarted.needsUpdateReminder)
        restarted.markUpdateReminderShown()
        offerBackground(restarted, version: "2.0.9", build: "2")
        XCTAssertFalse(restarted.needsUpdateReminder, "An earlier version must not be announced twice")
        XCTAssertEqual(defaults.stringArray(forKey: "updates.remindedVersions"), ["2.0.9", "2.0.10"])
    }

    func testUnshownReminderIsNotConsumedAndBadgeIsKeptAfterUserSeesIt() {
        let checker = makeChecker()
        offerBackground(checker, version: "2.0.9", build: "2")
        let restarted = makeChecker()
        XCTAssertTrue(restarted.needsUpdateReminder)
        restarted.markUpdateReminderShown()
        XCTAssertNotNil(restarted.availableUpdate)
        restarted.checkForUpdates()
        XCTAssertNotNil(restarted.availableUpdate)
    }

    func testPersistedOfferAppearsImmediatelyWithoutRecheckingOnAboutOpen() {
        let checker = makeChecker()
        offerBackground(checker, version: "2.0.9", build: "2")
        let restarted = makeChecker { _ in XCTFail("Opening About must use the cached update") }
        restarted.showUpdateStatus()
        XCTAssertEqual(restarted.state, .updateAvailable(version: "2.0.9"))
        XCTAssertFalse(restarted.shouldPromptForDownload)
    }

    func testReopeningAboutAfterCancelShowsKnownVersionWithoutCheckingAgain() {
        let checker = makeChecker { _ in XCTFail("The known version should remain available after canceling") }
        offerBackground(checker, version: "2.0.9", build: "2")
        checker.showDownloadInitiated(cancellation: {})
        checker.cancelDownload()
        checker.showUpdateStatus()
        XCTAssertEqual(checker.state, .updateAvailable(version: "2.0.9"))
        XCTAssertFalse(checker.shouldPromptForDownload)
    }

    func testInstalledUpdateClearsPersistedBadgeOnNextLaunch() {
        let checker = makeChecker()
        offerBackground(checker, version: "2.0.9", build: "2")
        checker.markUpdateReminderShown()
        let updated = UpdateChecker(defaults: defaults, currentBuild: "2", check: { _ in })
        XCTAssertNil(updated.availableUpdate)
        XCTAssertFalse(updated.needsUpdateReminder)
        XCTAssertNil(defaults.object(forKey: "updates.available"))
        XCTAssertEqual(defaults.stringArray(forKey: "updates.remindedVersions"), ["2.0.9"])
    }

    func testBackgroundOfferIsRevalidatedWhenUserClicksDownload() {
        var checks = 0
        var replies: [SPUUserUpdateChoice] = []
        let checker = makeChecker { checker in
            checks += 1
            checker.offerUpdate(version: "2.0.9", stage: .notDownloaded, build: "2") { replies.append($0) }
        }
        offerBackground(checker, version: "2.0.9", build: "2")
        checker.checkForUpdates() // Reopening About only displays the known offer.
        XCTAssertEqual(checks, 0)
        checker.downloadUpdate()
        checker.downloadUpdate()
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(replies, [.install])
        XCTAssertEqual(checker.state, .downloading(version: "2.0.9"))
    }

    func testNewVersionDuringRevalidationRequiresAnotherDownloadConfirmation() {
        var replies: [SPUUserUpdateChoice] = []
        let checker = makeChecker { checker in
            checker.offerUpdate(version: "2.0.10", stage: .notDownloaded, build: "3") { replies.append($0) }
        }
        offerBackground(checker, version: "2.0.9", build: "2")
        checker.downloadUpdate()
        XCTAssertTrue(replies.isEmpty)
        XCTAssertEqual(checker.state, .updateAvailable(version: "2.0.10"))
        XCTAssertTrue(checker.shouldPromptForDownload)
    }

    func testLaterReleasesManualOfferWithoutClearingBadgeAndDownloadStillWorks() {
        var replies: [SPUUserUpdateChoice] = []
        let checker = makeChecker { checker in
            checker.offerUpdate(version: "2.0.9", stage: .notDownloaded, build: "2") { replies.append($0) }
        }
        checker.checkForUpdates()
        checker.deferUpdate()
        checker.dismissUpdateInstallation()
        XCTAssertEqual(replies, [.dismiss])
        XCTAssertEqual(checker.state, .updateAvailable(version: "2.0.9"))
        XCTAssertNotNil(checker.availableUpdate)
        checker.downloadUpdate()
        XCTAssertEqual(replies, [.dismiss, .install])
    }

    func testLaterKeepsStagedUpdateAndRestartIsOnlySentAfterExplicitClick() {
        var replies: [SPUUserUpdateChoice] = []
        let checker = makeChecker { checker in
            checker.offerUpdate(version: "2.0.9", stage: .installing, build: "2") { replies.append($0) }
        }
        checker.checkForUpdates()
        checker.deferUpdate()
        checker.dismissUpdateInstallation()
        XCTAssertEqual(replies, [.dismiss])
        XCTAssertEqual(checker.state, .readyToInstall(version: "2.0.9"))
        checker.checkForUpdates()
        XCTAssertEqual(replies, [.dismiss])
        checker.restartAndInstall()
        XCTAssertEqual(replies, [.dismiss, .install])
    }

    func testBackgroundFailureKeepsKnownUpdateAndDoesNotChangeVisibleState() {
        let checker = makeChecker()
        offerBackground(checker, version: "2.0.9", build: "2")
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: checker, delegate: nil)
        checker.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: URLError(.notConnectedToInternet))
        XCTAssertEqual(checker.state, .updateAvailable(version: "2.0.9"))
        XCTAssertNotNil(checker.availableUpdate)
        XCTAssertFalse(checker.shouldPromptForDownload)
    }

    func testAboutMenuKeepsItsActionAndAnnouncesTheAvailableUpdate() throws {
        let checker = makeChecker()
        let delegate = AppDelegate(permissions: PermissionStore(preview: true), updateChecker: checker)
        let original = try XCTUnwrap(delegate.makeStatusMenu().items.first { $0.action == #selector(AppDelegate.showAbout) })
        XCTAssertNil(original.attributedTitle)
        offerBackground(checker, version: "2.0.9", build: "2")
        let item = try XCTUnwrap(delegate.makeStatusMenu().items.first { $0.action == #selector(AppDelegate.showAbout) })
        XCTAssertTrue(item.title.hasPrefix(original.title))
        XCTAssertTrue(item.attributedTitle?.string.hasPrefix(original.title) == true)
        XCTAssertNotEqual(item.accessibilityLabel(), original.accessibilityLabel())
    }

    private func makeChecker(check: @escaping (UpdateChecker) -> Void = { _ in }) -> UpdateChecker {
        UpdateChecker(defaults: defaults, currentBuild: "1", check: check)
    }

    private func offerBackground(_ checker: UpdateChecker, version: String, build: String) {
        checker.offerUpdate(version: version, stage: .notDownloaded, build: build, userInitiated: false) { _ in }
        checker.dismissUpdateInstallation()
    }
}
