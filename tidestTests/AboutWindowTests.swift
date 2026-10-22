import AppKit
import XCTest
@testable import tidest

@MainActor
final class AboutWindowTests: XCTestCase {
    func testAboutOpensWithoutPermissionsAndSurvivesPermissionRefresh() throws {
        let permissions = PermissionStore(preview: true)
        let delegate = AppDelegate(permissions: permissions)
        defer { closeWindows(for: delegate) }

        delegate.showAbout()
        let about = try XCTUnwrap(NSApp.windows.first { $0.delegate === delegate })
        XCTAssertTrue(about.isVisible)
        XCTAssertFalse(permissions.accessibilityGranted)
        XCTAssertFalse(permissions.screenCaptureGranted)

        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        XCTAssertTrue(about.isVisible)
        XCTAssertEqual(NSApp.windows.filter { $0.delegate === delegate }.count, 1,
                       "Opening About must not bring up a permission guide")

        delegate.showGuide()
        XCTAssertTrue(about.isVisible, "A permission guide must not hide About")
    }

    func testClosingAndReopeningAboutCreatesANewCheckWithoutDuplicatingVisibleWindows() throws {
        let delegate = AppDelegate(permissions: PermissionStore(preview: true))
        defer { closeWindows(for: delegate) }

        delegate.showAbout()
        let first = try XCTUnwrap(NSApp.windows.first { $0.delegate === delegate })
        let firstContent = first.contentView
        delegate.showAbout()
        XCTAssertTrue(first.isVisible)
        XCTAssertTrue(first.contentView === firstContent)

        first.close()
        delegate.showAbout()
        let reopened = try XCTUnwrap(NSApp.windows.first { $0.delegate === delegate && $0.isVisible })
        XCTAssertFalse(first === reopened)
        XCTAssertFalse(firstContent === reopened.contentView)
    }

    private func closeWindows(for delegate: AppDelegate) {
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        for window in NSApp.windows where window.delegate === delegate {
            // Closing the required guide normally quits Tidest. These windows
            // belong to a separate test delegate, not the running application.
            window.delegate = nil
            window.close()
        }
    }
}
