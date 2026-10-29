import Charts
import SwiftUI

@MainActor
struct UsageStatisticsView: View {
    static let windowSize = CGSize(width: 480, height: 340)
    @ObservedObject var settings: AppSettings
    @ObservedObject var statistics: UsageStatisticsStore
    @State private var hoveredDate: Date?
    @State private var showsExplanation = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            // Read the clock on updates too, so a use just after midnight is
            // reflected immediately, before the next periodic refresh.
            content(on: Date())
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(width: Self.windowSize.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, settings.locale)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usageStatisticsPanel")
    }

    private func content(on date: Date) -> some View {
        let days = statistics.lastSevenDays(endingAt: date)
        let selected = days.first { Calendar.current.isDate($0.date, inSameDayAs: hoveredDate ?? date) }
            ?? days.last!
        let step = max(1, Int(ceil(Double(days.map(\.count).max() ?? 0) / 2)))
        let ticks = [0, step, step * 2]
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(settings.text("今日使用"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(number(statistics.count(on: date)))
                        .font(.system(size: 40, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .accessibilityIdentifier("statisticsToday")
                }
                Spacer(minLength: 24)
                VStack(alignment: .trailing, spacing: 7) {
                    Text(settings.text("累计使用"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(number(statistics.totalCount))
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .accessibilityIdentifier("statisticsTotal")
                }
                .padding(.bottom, 5)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(settings.text("最近 7 天")).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(settings.text("%@ · %@ 次", shortDate(selected.date), number(selected.count)))
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityIdentifier("statisticsSelectedDay")
                }
                Chart(days) { day in
                    BarMark(x: .value(settings.text("日期"), day.date),
                            y: .value(settings.text("使用次数"), day.count), width: .fixed(28))
                        .cornerRadius(4)
                        .foregroundStyle(day.id == selected.id ? Color.accentColor : Color.accentColor.opacity(0.25))
                        .accessibilityLabel(fullDate(day.date))
                        .accessibilityValue(settings.text("%@ 次", number(day.count)))
                }
                .chartXScale(range: .plotDimension(startPadding: 18, endPadding: 18))
                .chartYScale(domain: 0...(step * 2))
                .chartXAxis {
                    AxisMarks(values: days.map(\.date)) { value in
                        AxisValueLabel(centered: false, anchor: .top, collisionResolution: .disabled) {
                            if let date = value.as(Date.self) {
                                Text(date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).locale(settings.locale)))
                                    .font(.system(size: 10))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: ticks) { value in
                        AxisGridLine().foregroundStyle(.primary.opacity(0.055))
                        AxisValueLabel {
                            if let count = value.as(Int.self) { Text(number(count)) }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Color.clear.contentShape(Rectangle())
                            .accessibilityHidden(true)
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard let frame = proxy.plotFrame,
                                          geometry[frame].contains(location),
                                          let date: Date = proxy.value(atX: location.x - geometry[frame].minX) else {
                                        hoveredDate = nil
                                        return
                                    }
                                    hoveredDate = days.min {
                                        abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                                    }?.date
                                case .ended: hoveredDate = nil
                                }
                            }
                    }
                }
                .frame(height: 144)
                .accessibilityIdentifier("statisticsChart")
            }

            VStack(spacing: 12) {
                Divider().overlay(.primary.opacity(0.03))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(settings.text("仅本机保存"))
                    Text("·").accessibilityHidden(true)
                    Text(settings.text("始于 %@", statistics.startedAt.formatted(.dateTime
                        .year().month(.twoDigits).day(.twoDigits).locale(settings.locale))))
                    Spacer(minLength: 8)
                    Button { showsExplanation.toggle() } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(settings.text("统计说明"))
                    .accessibilityLabel(settings.text("统计说明"))
                    .accessibilityIdentifier("statisticsExplanation")
                    .popover(isPresented: $showsExplanation, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(settings.text("统计说明"))
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                            Text(settings.text("切换窗口、完成布局、添加或打开停靠窗口，各计一次。"))
                            Text(settings.text("取消、失败或只打开面板，不计入次数。"))
                            Text(settings.text("从 %@ 开始统计，仅保存在这台 Mac 上。", fullDate(statistics.startedAt)))
                        }
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 260, alignment: .leading)
                        .padding(16)
                        .environment(\.locale, settings.locale)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("statisticsExplanationPanel")
                    }
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func number(_ value: Int) -> String { value.formatted(.number.locale(settings.locale)) }
    private func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().locale(settings.locale))
    }
    private func fullDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().locale(settings.locale))
    }
}
