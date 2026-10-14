import XCTest
@testable import tidest

final class PermissionStoreTests: XCTestCase {
    @MainActor
    func testPreviewPermissionActionsDoNotChangeGrantedStateOrRequestCapture() {
        for accessibility in [false, true] {
            for screenCapture in [false, true] {
                let permissions = PermissionStore(preview: true, accessibility: accessibility, screenCapture: screenCapture)

                permissions.openAccessibilitySettings()
                permissions.openScreenCaptureSettings()
                permissions.requestAccessibility()
                permissions.requestScreenCapture()
                permissions.refresh()

                XCTAssertEqual(permissions.accessibilityGranted, accessibility)
                XCTAssertEqual(permissions.screenCaptureGranted, screenCapture)
                XCTAssertFalse(permissions.requestedScreenCapture)
                XCTAssertFalse(permissions.screenCaptureReminderSuppressed)
            }
        }
    }

    @MainActor
    func testGuideRequiresAccessibilityButAllowsCaptureReminderToBeSuppressed() {
        let missingAccessibility = PermissionStore(preview: true, screenCapture: true)
        missingAccessibility.screenCaptureReminderSuppressed = true
        XCTAssertEqual(missingAccessibility.startupGuide, .accessibility)
        XCTAssertEqual(missingAccessibility.manualGuide, .accessibility)

        let captureSkipped = PermissionStore(preview: true, accessibility: true)
        XCTAssertEqual(captureSkipped.startupGuide, .screenCapture)
        captureSkipped.screenCaptureReminderSuppressed = true
        XCTAssertNil(captureSkipped.startupGuide)
        XCTAssertEqual(captureSkipped.manualGuide, .screenCapture)
        XCTAssertFalse(captureSkipped.screenCaptureGranted)
    }
}
