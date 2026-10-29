import AppKit
import XCTest
@testable import tidest

@MainActor
final class UsageStatisticsTests: XCTestCase {
    func testCountsSurviveRestartAndRollOverAtLocalMidnight() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let before = instant("2026-10-28T15:59:59Z")
        let after = instant("2026-10-28T16:00:01Z")
        let store = UsageStatisticsStore(defaults: defaults, calendar: calendar, now: before)
        store.record(at: before)
        store.record(at: before)
        store.record(at: after)

        let restarted = UsageStatisticsStore(defaults: defaults, calendar: calendar, now: after)
        XCTAssertEqual(restarted.startedAt, before)
        XCTAssertEqual(restarted.count(on: before), 2)
        XCTAssertEqual(restarted.count(on: after), 1)
        XCTAssertEqual(restarted.totalCount, 3)
        XCTAssertEqual(restarted.lastSevenDays(endingAt: after).map(\.count), [0, 0, 0, 0, 0, 2, 1])
    }

    func testSevenDaysIncludeZeroDaysAcrossDaylightSavingAndKeepOlderTotals() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let old = instant("2026-10-01T12:00:00Z")
        let today = instant("2026-11-03T12:00:00Z")
        let store = UsageStatisticsStore(defaults: defaults, calendar: calendar, now: old)
        store.record(at: old)
        // Both occurrences of 01:30 on the day clocks go back are one day.
        store.record(at: instant("2026-11-01T08:30:00Z"))
        store.record(at: instant("2026-11-01T09:30:00Z"))
        let days = store.lastSevenDays(endingAt: today)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(Set(days.map(\.date)).count, 7)
        XCTAssertEqual(days.map { calendar.component(.day, from: $0.date) }, [28, 29, 30, 31, 1, 2, 3])
        XCTAssertEqual(days.map(\.count), [0, 0, 0, 0, 2, 0, 0])
        XCTAssertEqual(store.totalCount, 3)
        XCTAssertEqual(store.count(on: today), 0)
    }

    func testPreviewDoesNotReadOrOverwriteSavedCounts() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let date = instant("2026-10-29T04:00:00Z")
        let saved = UsageStatisticsStore(defaults: defaults, now: date)
        saved.record(at: date)
        let preview = UsageStatisticsStore(defaults: defaults, persistChanges: false, now: date)
        XCTAssertEqual(preview.totalCount, 0)
        preview.record(at: date)
        preview.record(at: date)
        XCTAssertEqual(preview.totalCount, 2)
        XCTAssertEqual(UsageStatisticsStore(defaults: defaults, now: date).totalCount, 1)
    }

    func testMenuPlacesStatisticsImmediatelyBelowUsageGuide() throws {
        let delegate = AppDelegate(permissions: PermissionStore(preview: true))
        let items = delegate.makeStatusMenu().items
        let guide = try XCTUnwrap(items.firstIndex { $0.action == #selector(AppDelegate.showUsageGuide) })
        XCTAssertEqual(items[guide + 1].action, #selector(AppDelegate.showStatistics))
    }

    func testStatisticsWindowOpensWithoutPermissionsReusesAndReleasesContent() throws {
        let permissions = PermissionStore(preview: true)
        let delegate = AppDelegate(permissions: permissions)
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            for window in NSApp.windows where window.delegate === delegate {
                window.delegate = nil
                window.close()
            }
        }
        delegate.showStatistics()
        let window = try XCTUnwrap(NSApp.windows.first { $0.delegate === delegate })
        let content = window.contentView
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(content?.frame.width, UsageStatisticsView.windowSize.width)
        XCTAssertEqual(content?.frame.height ?? 0, content?.fittingSize.height ?? 0, accuracy: 1)
        XCTAssertLessThanOrEqual(content?.frame.height ?? 0, 360)
        XCTAssertFalse(permissions.accessibilityGranted)
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        XCTAssertEqual(NSApp.windows.filter { $0.delegate === delegate }.count, 1)
        delegate.showStatistics()
        XCTAssertTrue(window.contentView === content)
        window.close()
        XCTAssertNil(window.contentView)
        delegate.showStatistics()
        let reopened = try XCTUnwrap(NSApp.windows.first { $0.delegate === delegate && $0.isVisible })
        XCTAssertFalse(window === reopened)
    }

    private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "UsageStatisticsTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}
