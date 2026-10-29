import Foundation
import XCTest
@testable import tidest

@MainActor
final class DailyActivityReporterTests: XCTestCase {
    func testOneAnonymousEventPerBeijingDaySurvivesRestart() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let before = instant("2026-10-29T15:59:59Z")
        let after = instant("2026-10-29T16:00:01Z")
        var events: [[String: Any]] = []
        let send: (URLRequest) async throws -> (Data, URLResponse) = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://us.i.posthog.com/capture/")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertFalse(request.httpShouldHandleCookies)
            events.append(try self.event(request))
            return try self.response()
        }
        let first = DailyActivityReporter(defaults: defaults, settings: settings, reportingEnabled: true,
                                          version: "2.0.8", send: send)
        XCTAssertNil(defaults.string(forKey: "dailyActivity.installationID"), "Starting alone must not create an identity or event")
        await first.recordActivity(at: before)?.value
        XCTAssertNil(first.recordActivity(at: before.addingTimeInterval(0.5)))

        let restarted = DailyActivityReporter(defaults: defaults, settings: settings, reportingEnabled: true,
                                              version: "2.0.8", send: send)
        XCTAssertNil(restarted.recordActivity(at: before))
        await restarted.recordActivity(at: after)?.value
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0]["distinct_id"] as? String, events[1]["distinct_id"] as? String)
        for (event, date) in zip(events, [before, after]) {
            XCTAssertEqual(Set(event.keys), ["api_key", "event", "distinct_id", "uuid", "timestamp", "properties"])
            XCTAssertEqual(event["event"] as? String, "tidest_app_active")
            XCTAssertEqual(event["timestamp"] as? String, ISO8601DateFormatter().string(from: date))
            let properties = try XCTUnwrap(event["properties"] as? [String: Any])
            XCTAssertEqual(Set(properties.keys), ["app_version", "$process_person_profile", "$geoip_disable"])
            XCTAssertEqual(properties["app_version"] as? String, "2.0.8")
            XCTAssertEqual(properties["$process_person_profile"] as? Bool, false)
            XCTAssertEqual(properties["$geoip_disable"] as? Bool, true)
        }
        XCTAssertNotNil(UUID(uuidString: String(try XCTUnwrap(events[0]["distinct_id"] as? String).dropFirst(4))))
    }

    func testConcurrentInputDoesNotSendDuplicateEvents() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var continuation: CheckedContinuation<Void, Never>?
        var calls = 0
        let reporter = DailyActivityReporter(defaults: defaults, settings: AppSettings(defaults: defaults), reportingEnabled: true,
                                             send: { _ in
            calls += 1
            await withCheckedContinuation { continuation = $0 }
            return try self.response()
        })
        let date = instant("2026-10-29T12:00:00Z")
        let task = try XCTUnwrap(reporter.recordActivity(at: date))
        XCTAssertNil(reporter.recordActivity(at: date))
        while continuation == nil { await Task.yield() }
        XCTAssertNil(reporter.recordActivity(at: date.addingTimeInterval(120)))
        continuation?.resume()
        await task.value
        XCTAssertEqual(calls, 1)
        XCTAssertNil(reporter.recordActivity(at: date.addingTimeInterval(240)))
    }

    func testMidnightInteractionCountsBothDaysWhenYesterdayResponseArrivesLast() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var continuation: CheckedContinuation<Void, Never>?
        var calls = 0
        let reporter = DailyActivityReporter(defaults: defaults, settings: AppSettings(defaults: defaults), reportingEnabled: true,
                                             send: { _ in
            calls += 1
            if calls == 1 { await withCheckedContinuation { continuation = $0 } }
            return try self.response()
        })
        let before = instant("2026-10-29T15:59:59Z")
        let after = instant("2026-10-29T16:00:01Z")
        let yesterday = try XCTUnwrap(reporter.recordActivity(at: before))
        while continuation == nil { await Task.yield() }
        let today = try XCTUnwrap(reporter.recordActivity(at: after))
        await today.value
        continuation?.resume()
        await yesterday.value
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(defaults.string(forKey: "dailyActivity.lastReportedDay"), "2026-10-30")
        XCTAssertNil(reporter.recordActivity(at: after.addingTimeInterval(120)))
    }

    func testFailureRetriesOnLaterInputWithoutChangingIdentityOrMarkingSuccess() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var ids: [String] = []
        let reporter = DailyActivityReporter(defaults: defaults, settings: AppSettings(defaults: defaults), reportingEnabled: true,
                                             send: { request in
            ids.append(try XCTUnwrap(self.event(request)["distinct_id"] as? String))
            if ids.count == 1 { throw URLError(.notConnectedToInternet) }
            return try self.response()
        })
        let date = instant("2026-10-29T12:00:00Z")
        await reporter.recordActivity(at: date)?.value
        XCTAssertNil(defaults.string(forKey: "dailyActivity.lastReportedDay"))
        XCTAssertNil(reporter.recordActivity(at: date.addingTimeInterval(59)))
        XCTAssertEqual(ids.count, 1)
        await reporter.recordActivity(at: date.addingTimeInterval(60))?.value
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids[0], ids[1])
        XCTAssertEqual(defaults.string(forKey: "dailyActivity.lastReportedDay"), "2026-10-29")
    }

    func testHTTPRejectionQuotaAndMalformedReceiptsDoNotMarkDayReported() async throws {
        let cases: [(Int, String)] = [
            (500, #"{"status":"Ok"}"#), (400, #"{"status":"error"}"#),
            (200, #"{"status":"Ok","quota_limited":["events"]}"#),
            (200, #"{"status":"error"}"#), (200, "<html>Unavailable</html>"), (204, "")
        ]
        for (status, body) in cases {
            let (defaults, suite) = makeDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            let reporter = DailyActivityReporter(defaults: defaults, settings: AppSettings(defaults: defaults), reportingEnabled: true,
                                                 send: { _ in try self.response(status: status, body: body) })
            await reporter.recordActivity(at: instant("2026-10-29T12:00:00Z"))?.value
            XCTAssertNil(defaults.string(forKey: "dailyActivity.lastReportedDay"), "\(status): \(body)")
        }
    }

    func testOptOutBuildAndPreviewGatesDoNotCreateIdentityOrSend() async {
        for mode in ["opt-out", "development", "preview"] {
            let (defaults, suite) = makeDefaults()
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(defaults: defaults, persistChanges: mode != "preview")
            settings.anonymousUsageEnabled = mode != "opt-out"
            let reporter = DailyActivityReporter(defaults: defaults, settings: settings, reportingEnabled: mode != "development",
                                                 send: { _ in
                XCTFail("\(mode) must not send")
                throw URLError(.cancelled)
            })
            XCTAssertNil(reporter.recordActivity())
            XCTAssertNil(defaults.string(forKey: "dailyActivity.installationID"))
            XCTAssertNil(defaults.string(forKey: "dailyActivity.lastReportedDay"))
        }
        #if DEBUG
        XCTAssertFalse(DailyActivityReporter.liveReportingEnabled)
        #endif
    }

    func testOptOutTakesEffectForFutureInputAndCanBeReenabled() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        var calls = 0
        let reporter = DailyActivityReporter(defaults: defaults, settings: settings, reportingEnabled: true,
                                             send: { _ in
            calls += 1
            return try self.response()
        })
        let date = instant("2026-10-29T12:00:00Z")
        await reporter.recordActivity(at: date)?.value
        settings.anonymousUsageEnabled = false
        XCTAssertNil(reporter.recordActivity(at: date.addingTimeInterval(86400)))
        settings.anonymousUsageEnabled = true
        await reporter.recordActivity(at: date.addingTimeInterval(86400))?.value
        XCTAssertEqual(calls, 2)
    }

    func testOptOutBeforeScheduledRequestStartsPreventsSending() async throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let reporter = DailyActivityReporter(defaults: defaults, settings: settings, reportingEnabled: true,
                                             send: { _ in
            XCTFail("The opt-out click must cancel a request that has not started")
            throw URLError(.cancelled)
        })
        let task = try XCTUnwrap(reporter.recordActivity())
        settings.anonymousUsageEnabled = false
        await task.value
        XCTAssertNil(defaults.string(forKey: "dailyActivity.lastReportedDay"))
    }

    private func event(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private func response(status: Int = 200, body: String = #"{"status":"Ok"}"#) throws -> (Data, URLResponse) {
        (Data(body.utf8), try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://us.i.posthog.com/capture/")!,
                                                     statusCode: status, httpVersion: nil, headerFields: nil)))
    }

    private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "DailyActivityReporterTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}
