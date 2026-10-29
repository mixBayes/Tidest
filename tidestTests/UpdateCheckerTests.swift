import Foundation
import Sparkle
import XCTest
@testable import tidest

@MainActor
final class UpdateCheckerTests: XCTestCase {
    func testCheckDoesNotDownloadUntilUserChoosesDownload() {
        var choices: [SPUUserUpdateChoice] = []
        let checker = makeChecker { checker in
            checker.offerUpdate(version: "2.0.9", stage: .notDownloaded) { choices.append($0) }
        }
        checker.checkForUpdates()
        XCTAssertEqual(checker.state, .updateAvailable(version: "2.0.9"))
        XCTAssertTrue(choices.isEmpty)
        checker.downloadUpdate()
        checker.downloadUpdate()
        XCTAssertEqual(choices, [.install])
        XCTAssertEqual(checker.state, .downloading(version: "2.0.9"))
    }

    func testDownloadFinishingWaitsForExplicitRestartAndOnlyRepliesOnce() {
        let checker = offeredUpdate()
        var installs: [SPUUserUpdateChoice] = []
        var prompts = 0
        checker.onReadyToInstall = { prompts += 1 }
        checker.downloadUpdate()
        checker.showDownloadDidStartExtractingUpdate()
        checker.showReady(toInstallAndRelaunch: { installs.append($0) })
        XCTAssertEqual(checker.state, .readyToInstall(version: "2.0.9"))
        XCTAssertEqual(prompts, 1)
        XCTAssertTrue(installs.isEmpty)
        // Later leaves this session pending. Closing/reopening About rechecks.
        checker.checkForUpdates()
        XCTAssertEqual(checker.state, .readyToInstall(version: "2.0.9"))
        XCTAssertTrue(installs.isEmpty)
        checker.restartAndInstall()
        checker.restartAndInstall()
        XCTAssertEqual(installs, [.install])
        XCTAssertEqual(checker.state, .installing(version: "2.0.9"))
    }

    func testAlreadyStagedUpdateAlsoRequiresRestartConfirmation() {
        let checker = makeChecker(check: { _ in XCTFail("Must not start another check") })
        var choices: [SPUUserUpdateChoice] = []
        checker.offerUpdate(version: "2.0.9", stage: .installing) { choices.append($0) }
        checker.checkForUpdates()
        XCTAssertTrue(choices.isEmpty)
        checker.restartAndInstall()
        XCTAssertEqual(choices, [.install])
    }

    func testRestartIsIgnoredBeforePreparationFinishes() {
        let checker = offeredUpdate()
        checker.restartAndInstall()
        XCTAssertEqual(checker.state, .updateAvailable(version: "2.0.9"))
        checker.downloadUpdate()
        checker.restartAndInstall()
        XCTAssertEqual(checker.state, .downloading(version: "2.0.9"))
        checker.showDownloadDidStartExtractingUpdate()
        checker.restartAndInstall()
        XCTAssertEqual(checker.state, .preparing(version: "2.0.9"))
    }

    func testRepeatedChecksDoNotInterruptActiveDownloadOrReadySession() {
        var checks = 0
        let checker = makeChecker { checker in
            checks += 1
            checker.offerUpdate(version: "2.0.9", stage: .notDownloaded) { _ in }
        }
        checker.checkForUpdates()
        checker.checkForUpdates()
        checker.downloadUpdate()
        checker.checkForUpdates()
        checker.showDownloadDidStartExtractingUpdate()
        checker.checkForUpdates()
        checker.showReady(toInstallAndRelaunch: { _ in })
        checker.checkForUpdates()
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(checker.state, .readyToInstall(version: "2.0.9"))
    }

    func testDownloadProgressHandlesUnknownAndChangedLengths() {
        let checker = offeredUpdate()
        checker.downloadUpdate()
        checker.showDownloadInitiated(cancellation: {})
        XCTAssertNil(checker.downloadProgress)
        checker.showDownloadDidReceiveData(ofLength: 60)
        XCTAssertNil(checker.downloadProgress)
        checker.showDownloadDidReceiveExpectedContentLength(100)
        XCTAssertEqual(checker.downloadProgress, 0.6)
        checker.showDownloadDidReceiveData(ofLength: 60)
        XCTAssertEqual(checker.downloadProgress, 1)
        checker.showDownloadDidReceiveExpectedContentLength(200)
        XCTAssertEqual(checker.downloadProgress, 0.6)
    }

    func testCancelWorksDuringDownloadAndCannotCancelStaging() {
        let checker = offeredUpdate()
        var cancels = 0
        checker.downloadUpdate()
        checker.showDownloadInitiated { cancels += 1 }
        checker.cancelDownload()
        checker.cancelDownload()
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(checker.state, .idle)
        checker.showDownloadInitiated { cancels += 1 }
        checker.showDownloadDidStartExtractingUpdate()
        checker.cancelDownload()
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(checker.state, .preparing(version: "2.0.9"))
    }

    func testFailedCheckCanBeRetriedAndOutcomeSurvivesSessionDismissal() {
        var checks = 0
        let checker = makeChecker { checker in
            checks += 1
            if checks == 1 {
                checker.showUpdaterError(URLError(.notConnectedToInternet), acknowledgement: {})
                checker.dismissUpdateInstallation()
            } else {
                checker.offerUpdate(version: "2.0.9", stage: .notDownloaded) { _ in }
            }
        }
        checker.checkForUpdates()
        XCTAssertEqual(checker.state, .checkFailed)
        checker.checkForUpdates()
        XCTAssertEqual(checker.state, .updateAvailable(version: "2.0.9"))
    }

    func testFailedUpdateCannotUseOldRestartReplyAndCanBeRetried() {
        let checker = offeredUpdate()
        var installs = 0
        checker.downloadUpdate()
        checker.showReady(toInstallAndRelaunch: { _ in installs += 1 })
        checker.showUpdaterError(URLError(.networkConnectionLost), acknowledgement: {})
        checker.dismissUpdateInstallation()
        checker.restartAndInstall()
        XCTAssertEqual(installs, 0)
        XCTAssertEqual(checker.state, .updateFailed)
        checker.checkForUpdates()
        XCTAssertEqual(checker.state, .updateAvailable(version: "2.0.9"))
    }

    func testUnsupportedMacDoesNotClaimToBeOnLatestVersion() {
        for reason in [SPUNoUpdateFoundReason.onLatestVersion, .onNewerThanLatestVersion, .systemIsTooOld, .hardwareDoesNotSupportARM64, .unknown] {
            let checker = makeChecker(check: { _ in })
            let error = NSError(domain: SUSparkleErrorDomain, code: 1001,
                                userInfo: [SPUNoUpdateFoundReasonKey: reason.rawValue])
            var acknowledgements = 0
            checker.showUpdateNotFoundWithError(error) { acknowledgements += 1 }
            checker.dismissUpdateInstallation()
            XCTAssertEqual(checker.state, [.onLatestVersion, .onNewerThanLatestVersion].contains(reason) ? .upToDate : .unavailable)
            XCTAssertEqual(acknowledgements, 1)
        }
    }

    func testReadOnlyOrTranslocatedAppExplainsWhereToInstallIt() {
        for code in [SUError.runningFromDiskImageError, .runningTranslocated] {
            let checker = makeChecker(check: { _ in })
            checker.showUpdaterError(NSError(domain: SUSparkleErrorDomain, code: Int(code.rawValue)), acknowledgement: {})
            XCTAssertEqual(checker.state, .installFromApplications)
        }
    }

    func testInformationOnlyUpdateIsNotDownloaded() throws {
        let checker = makeChecker(check: { _ in XCTFail("Unexpected check") })
        var choices: [SPUUserUpdateChoice] = []
        let url = try XCTUnwrap(URL(string: "https://tidest.app/download"))
        checker.offerUpdate(version: "3.0.0", stage: .notDownloaded, informationURL: url) { choices.append($0) }
        checker.downloadUpdate()
        checker.restartAndInstall()
        XCTAssertEqual(choices, [.dismiss])
        XCTAssertEqual(checker.state, .manualUpdate(version: "3.0.0", url: url))
    }

    private func makeChecker(check: @escaping (UpdateChecker) -> Void) -> UpdateChecker {
        let name = "com.mixbayes.tidest.tests.updates." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return UpdateChecker(defaults: defaults, currentBuild: "1", check: check)
    }

    private func offeredUpdate() -> UpdateChecker {
        let checker = makeChecker { checker in
            checker.offerUpdate(version: "2.0.9", stage: .notDownloaded) { _ in }
        }
        checker.checkForUpdates()
        return checker
    }
}
