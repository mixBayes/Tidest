import Foundation

/// Reports a day of actual interaction, independently of local action counts.
@MainActor
final class DailyActivityReporter {
    static let shared = DailyActivityReporter()

    nonisolated static var liveReportingEnabled: Bool {
        #if DEBUG
        false
        #else
        !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--ui-preview-") })
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            && NSClassFromString("XCTestCase") == nil
        #endif
    }

    private let defaults: UserDefaults
    private let settings: AppSettings
    private let reportingEnabled: Bool
    private let version: String
    private let send: (URLRequest) async throws -> (Data, URLResponse)
    private var sendingDays: Set<String> = []
    private var retryAfter: [String: Date] = [:]

    init(defaults: UserDefaults = .standard, settings: AppSettings? = nil,
         reportingEnabled: Bool = DailyActivityReporter.liveReportingEnabled,
         version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
         send: @escaping (URLRequest) async throws -> (Data, URLResponse) = {
             try await URLSession.shared.data(for: $0)
         }) {
        self.defaults = defaults
        self.settings = settings ?? .shared
        self.reportingEnabled = reportingEnabled
        self.version = version
        self.send = send
    }

    @discardableResult
    func recordActivity(at date: Date = Date()) -> Task<Void, Never>? {
        guard reportingEnabled, settings.persistChanges, settings.anonymousUsageEnabled else { return nil }
        let day = Self.dayKey(date)
        guard defaults.string(forKey: "dailyActivity.lastReportedDay") != day,
              !sendingDays.contains(day), retryAfter[day].map({ date >= $0 }) ?? true else { return nil }

        let installationID: String
        if let saved = defaults.string(forKey: "dailyActivity.installationID") {
            installationID = saved
        } else {
            installationID = "mac_\(UUID().uuidString)"
            defaults.set(installationID, forKey: "dailyActivity.installationID")
        }
        var request = URLRequest(url: URL(string: "https://us.i.posthog.com/capture/")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The public project token only permits event ingestion. It is shared
        // with tidest.app; never put a personal or project secret key here.
        let payload: [String: Any] = [
            "api_key": "phc_ojTFLJMQUBownTLerRpnYD6EeRu3PTsWKsKinEcevmxb",
            "event": "tidest_app_active",
            "distinct_id": installationID,
            "uuid": UUID().uuidString,
            "timestamp": ISO8601DateFormatter().string(from: date),
            "properties": [
                "app_version": version,
                "$process_person_profile": false,
                "$geoip_disable": true
            ] as [String: Any]
        ]

        sendingDays.insert(day)
        retryAfter[day] = date.addingTimeInterval(60)
        return Task {
            defer { sendingDays.remove(day) }
            // A click on the opt-out switch is observed before SwiftUI applies
            // it. Honor that choice before starting the scheduled request.
            guard settings.anonymousUsageEnabled else { return }
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                let (data, response) = try await send(request)
                let receipt = try JSONDecoder().decode(Receipt.self, from: data)
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode), receipt.status == "Ok",
                      receipt.quota_limited?.isEmpty ?? true else {
                    return
                }
                // Save the interaction's date, even if the response arrives
                // after midnight. Only a later interaction can count a new day.
                let savedDay = defaults.string(forKey: "dailyActivity.lastReportedDay") ?? day
                defaults.set(max(savedDay, day), forKey: "dailyActivity.lastReportedDay")
                retryAfter[day] = nil
            } catch {
                // Analytics never interrupts a user's action. No background
                // retry or heartbeat: another interaction can try after a minute.
            }
        }
    }

    private static func dayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private struct Receipt: Decodable {
        let status: String
        let quota_limited: [String]?
    }
}
