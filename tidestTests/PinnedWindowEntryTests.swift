import AppKit
import ApplicationServices
import XCTest
@testable import tidest

final class PinnedWindowEntryTests: XCTestCase {
    @MainActor
    func testProcessDatePreservesExistingAppKitIdentitiesAndSupportsFinder() throws {
        let current = NSRunningApplication.current
        XCTAssertNotNil(WindowCatalog.processLaunchDate(current))
        if let date = current.launchDate { XCTAssertEqual(WindowCatalog.processLaunchDate(current), date) }
        let finder = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        XCTAssertNotNil(WindowCatalog.processLaunchDate(finder))
        XCTAssertEqual(WindowCatalog.processLaunchDate(finder), WindowCatalog.processLaunchDate(finder))
    }

    @MainActor
    func testLegacyRecordWithoutDateStillChecksItsExactWindowAndOwner() async throws {
        let current = NSRunningApplication.current
        let bundleID = try XCTUnwrap(current.bundleIdentifier)
        var saved = SavedPinnedWindow(id: UUID(), applicationBundleIdentifier: bundleID,
            applicationURL: "file:///Applications/Example.app/", applicationName: "Example", title: "Closed window",
            width: 800, height: 600, target: .application, processID: current.processIdentifier,
            captureID: UInt32.max, retainAfterClose: false)
        let closed = await WindowCatalog.presence(of: saved)
        if case .closed = closed {} else { XCTFail("A missing legacy date must not bypass the exact window check") }
        saved.processLaunchDate = WindowCatalog.processLaunchDate(current)?.addingTimeInterval(-1)
        let reused = await WindowCatalog.presence(of: saved)
        if case .closed = reused {} else { XCTFail("A different process date must still reject a reused identity") }
    }

    func testChromeAssociationSurvivesSavingAndRejectsReusedProcessOrWindowIDs() throws {
        let launchDate = Date(timeIntervalSince1970: 123456)
        let identity = PinnedChromeWindowIdentity(processID: 123, processLaunchDate: launchDate,
            captureID: 45, windowID: .text("1281153858"))
        func window(pid: Int32 = 123, captureID: UInt32? = 45, title: String = "Page - Google Chrome") -> WindowItem {
            WindowItem(element: AXUIElementCreateApplication(pid), processID: pid,
                applicationName: "Google Chrome", icon: nil, title: title,
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                minimized: false, captureID: captureID, stackOrder: 0)
        }
        XCTAssertTrue(identity.matches(window(), launchDate: launchDate))
        XCTAssertTrue(identity.matches(window(title: "Another page - 正在播放音频 - Google Chrome - Profile"),
                                       launchDate: launchDate))
        XCTAssertFalse(identity.matches(window(pid: 456), launchDate: launchDate))
        XCTAssertFalse(identity.matches(window(captureID: 46), launchDate: launchDate))
        XCTAssertFalse(identity.matches(window(captureID: nil), launchDate: launchDate))
        XCTAssertFalse(identity.matches(window(), launchDate: launchDate.addingTimeInterval(1)))
        XCTAssertFalse(identity.matches(window(), launchDate: nil))

        var saved = SavedPinnedWindow(id: UUID(), applicationBundleIdentifier: "com.google.Chrome",
            applicationURL: "file:///Applications/Google%20Chrome.app/", applicationName: "Google Chrome",
            title: "Page", width: 800, height: 600, target: .browser(urls: ["https://example.com"], selectedTabIndex: 0),
            processID: 123, processLaunchDate: launchDate, captureID: 45, chromeWindowIdentity: identity)
        let data = try JSONEncoder().encode(saved)
        XCTAssertEqual(try JSONDecoder().decode(SavedPinnedWindow.self, from: data), saved)
        // Previously saved entries continue to load without an association.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "chromeWindowIdentity")
        saved.chromeWindowIdentity = nil
        XCTAssertEqual(try JSONDecoder().decode(SavedPinnedWindow.self,
            from: JSONSerialization.data(withJSONObject: legacy)), saved)
    }

    @MainActor
    func testCancellingRetentionOrReplacingTheWindowDropsTheChromeAssociation() throws {
        let launchDate = Date(timeIntervalSince1970: 123456)
        let identity = PinnedChromeWindowIdentity(processID: 0, processLaunchDate: launchDate,
            captureID: 45, windowID: .text("chrome-session"))
        var window = makeWindow()
        window.captureID = 45
        var entry = PinnedWindowEntry(window: window)
        entry.saved = SavedPinnedWindow(id: window.id, applicationBundleIdentifier: "com.google.Chrome",
            applicationURL: "file:///Applications/Google%20Chrome.app/", applicationName: "Google Chrome",
            title: "Page", width: 800, height: 600, target: .browser(urls: ["https://example.com"], selectedTabIndex: 0),
            processID: 0, processLaunchDate: launchDate, captureID: 45, chromeWindowIdentity: identity)
        XCTAssertEqual(entry.recordForSaving()?.chromeWindowIdentity, identity)
        entry.saved?.retainAfterClose = false
        XCTAssertNil(entry.recordForSaving()?.chromeWindowIdentity)
        entry.saved?.retainAfterClose = true
        window.captureID = 46
        entry.window = window
        XCTAssertNil(entry.recordForSaving()?.chromeWindowIdentity)
    }

    func testEveryLaunchTargetAndOriginalWindowIdentitySurviveJSONRoundTrip() throws {
        let targets: [PinnedLaunchTarget] = [
            .application,
            .finder(path: "/Users/example/Documents/项目"),
            .terminal(path: "/Users/example/Projects/a b"),
            .browser(urls: ["https://example.com", "https://example.org/search?q=test"], selectedTabIndex: 1)
        ]
        let values = targets.map { target in
            SavedPinnedWindow(
                id: UUID(), applicationBundleIdentifier: "com.example.app",
                applicationURL: "file:///Applications/Example.app/", applicationName: "Example",
                title: "My window", width: 800, height: 600, target: target,
                processID: 123, processLaunchDate: Date(timeIntervalSince1970: 123456), captureID: 45)
        }

        let data = try JSONEncoder().encode(values)
        XCTAssertEqual(try JSONDecoder().decode([SavedPinnedWindow].self, from: data), values)
    }

    func testLiveEntryKeepsWindowIdentityAndDoesNotStartRetained() {
        let window = makeWindow()
        let entry = PinnedWindowEntry(window: window)

        XCTAssertEqual(entry.id, window.id)
        XCTAssertEqual(entry.applicationName, window.applicationName)
        XCTAssertEqual(entry.title, window.title)
        XCTAssertEqual(entry.frame, window.frame)
        XCTAssertFalse(entry.isClosed)
        XCTAssertFalse(entry.isRetained)
        XCTAssertNil(entry.saved)
    }

    @MainActor
    func testRestoredEntryKeepsLastDisplayMetadataAfterWindowCloses() {
        let saved = SavedPinnedWindow(
            id: UUID(), applicationBundleIdentifier: "com.example.app",
            applicationURL: "file:///Applications/Example.app/", applicationName: "Saved Example",
            title: "Saved window", width: 800, height: 600, target: .application)
        var entry = PinnedWindowEntry(saved: saved)

        XCTAssertEqual(entry.id, saved.id)
        XCTAssertEqual(entry.applicationName, saved.applicationName)
        XCTAssertEqual(entry.title, saved.title)
        XCTAssertEqual(entry.frame.size, CGSize(width: 800, height: 600))
        XCTAssertTrue(entry.isClosed)
        XCTAssertTrue(entry.isRetained)

        let icon = NSImage(size: CGSize(width: 32, height: 32))
        let window = makeWindow(icon: icon)
        entry.window = window
        XCTAssertEqual(entry.id, saved.id)
        XCTAssertEqual(entry.title, window.title)
        XCTAssertEqual(entry.frame, window.frame)
        XCTAssertFalse(entry.isClosed)
        XCTAssertTrue(entry.isRetained)

        let updated = makeWindow(title: "Updated window", frame: CGRect(x: 30, y: 40, width: 500, height: 900),
                                 icon: icon)
        entry.window = updated
        entry.window = nil
        XCTAssertEqual(entry.applicationName, updated.applicationName)
        XCTAssertEqual(entry.title, updated.title)
        XCTAssertEqual(entry.frame, updated.frame)
        XCTAssertTrue(entry.icon === icon)
        XCTAssertEqual(entry.saved, saved)
        XCTAssertTrue(entry.isClosed)

        let reopened = makeWindow(title: "Reopened window")
        entry.window = reopened
        entry.window = nil
        XCTAssertEqual(entry.title, reopened.title)
        XCTAssertEqual(entry.frame, reopened.frame)
        XCTAssertNil(entry.icon)
        XCTAssertEqual(entry.saved, saved)
    }

    private func makeWindow(title: String = "Live window",
                            frame: CGRect = CGRect(x: 10, y: 20, width: 900, height: 700),
                            icon: NSImage? = nil) -> WindowItem {
        WindowItem(element: AXUIElementCreateApplication(0), processID: 0,
                   applicationName: "Example", icon: icon, title: title, frame: frame,
                   minimized: false, captureID: nil, stackOrder: 0)
    }
}
