import AppKit
import XCTest
@testable import tidest

@MainActor
final class UsageWindowTests: XCTestCase {
    func testUsageGuideOpensWithoutPermissionsAndDoesNotTurnIntoAuthorization() throws {
        let permissions = PermissionStore(preview: true)
        let delegate = AppDelegate(permissions: permissions)
        defer { closeWindows(for: delegate) }

        delegate.showUsageGuide()
        let window = try XCTUnwrap(NSApp.windows.first { $0.delegate === delegate })
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.contentView?.frame.size, UsageGuideView.windowSize)
        XCTAssertFalse(permissions.accessibilityGranted)
        XCTAssertFalse(permissions.requestedScreenCapture)

        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(NSApp.windows.filter { $0.delegate === delegate }.count, 1,
                       "Reading instructions must not bring up authorization")
    }

    func testUsageGuideReusesOpenWindowAndReleasesAnimationViewOnClose() throws {
        let delegate = AppDelegate(permissions: PermissionStore(preview: true))
        defer { closeWindows(for: delegate) }
        delegate.showUsageGuide()
        let first = try XCTUnwrap(NSApp.windows.first { $0.delegate === delegate })
        let content = first.contentView
        delegate.showUsageGuide()
        XCTAssertTrue(first.contentView === content)
        XCTAssertEqual(NSApp.windows.filter { $0.delegate === delegate && $0.isVisible }.count, 1)

        first.close()
        XCTAssertNil(first.contentView, "Closing the guide must release its animation task")
        delegate.showUsageGuide()
        let reopened = try XCTUnwrap(NSApp.windows.first { $0.delegate === delegate && $0.isVisible })
        XCTAssertFalse(first === reopened)
        XCTAssertFalse(reopened.contentView === content)
    }

    private func closeWindows(for delegate: AppDelegate) {
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        for window in NSApp.windows where window.delegate === delegate {
            window.delegate = nil
            window.close()
        }
    }
}
