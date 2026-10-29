import Combine
import Foundation

@MainActor
final class UsageStatisticsStore: ObservableObject {
    static let shared: UsageStatisticsStore = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--ui-preview-") }) {
            let sample = ProcessInfo.processInfo.arguments.contains("--ui-preview-statistics-sample")
            let now = Date()
            let start = sample ? Calendar.current.date(byAdding: .day, value: -6, to: now)! : now
            let store = UsageStatisticsStore(defaults: UserDefaults(suiteName: "com.mixbayes.tidest.preview")!,
                                            persistChanges: false, now: start)
            if sample {
                for (index, count) in [8, 17, 0, 12, 24, 15, 21].enumerated() {
                    let date = Calendar.current.date(byAdding: .day, value: index - 6, to: now)!
                    for _ in 0..<count { store.record(at: date) }
                }
            }
            return store
        }
        #endif
        return UsageStatisticsStore()
    }()

    struct Day: Identifiable {
        let date: Date
        let count: Int
        var id: Date { date }
    }

    @Published private(set) var dailyCounts: [String: Int]
    let startedAt: Date
    private let defaults: UserDefaults
    private let persistChanges: Bool
    private let calendar: Calendar
    private static let storageKey = "usageStatistics"

    init(defaults: UserDefaults = .standard, persistChanges: Bool = true,
         calendar: Calendar = .autoupdatingCurrent, now: Date = Date()) {
        self.defaults = defaults
        self.persistChanges = persistChanges
        self.calendar = calendar
        let saved = persistChanges ? defaults.dictionary(forKey: Self.storageKey) : nil
        dailyCounts = saved?["dailyCounts"] as? [String: Int] ?? [:]
        startedAt = saved?["startedAt"] as? Date ?? now
        save()
    }

    var totalCount: Int { dailyCounts.values.reduce(0, +) }

    func count(on date: Date) -> Int { dailyCounts[dayKey(date)] ?? 0 }

    func record(at date: Date = Date()) {
        dailyCounts[dayKey(date), default: 0] += 1
        save()
    }

    func lastSevenDays(endingAt date: Date) -> [Day] {
        let today = calendar.startOfDay(for: date)
        return (-6...0).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: today).map {
                Day(date: $0, count: count(on: $0))
            }
        }
    }

    private func dayKey(_ date: Date) -> String {
        // Use local calendar dates, not 24-hour intervals: daylight-saving
        // transitions can make a day shorter or longer than 24 hours.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private func save() {
        guard persistChanges else { return }
        // Property-list values need no encoding, network request or permission.
        defaults.set(["startedAt": startedAt, "dailyCounts": dailyCounts], forKey: Self.storageKey)
    }
}
