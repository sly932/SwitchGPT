import Charts
import SwiftUI
import SwitchGPTAppCore

struct TokenActivityCardView: View {
  let account: AccountRecord

  @State private var mode: ActivityMode = .daily
  @State private var selectedDate: String?
  @Environment(\.colorScheme) private var colorScheme

  private var activity: AccountTokenActivity? { account.usage.tokenActivity }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Token 活动")
            .font(.system(size: 14, weight: .semibold))
          Text("当前所选账号的 Codex 用量")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text("Codex 账号用量")
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
      }

      if let activity {
        summary(activity)
        chartSection(activity)
      } else {
        ContentUnavailableView(
          account.usage.tokenActivityWasLoaded ? "暂无 Token 数据" : "暂时无法读取 Token 活动",
          systemImage: "chart.bar.xaxis",
          description: Text("稍后点击右上角的刷新按钮重试。")
        )
        .frame(maxWidth: .infinity)
        .frame(minHeight: 150)
      }
    }
    .padding(18)
    .background(
      ChatGPTStyle.softSurface(for: colorScheme),
      in: RoundedRectangle(cornerRadius: ChatGPTStyle.panelRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: ChatGPTStyle.panelRadius, style: .continuous)
        .stroke(ChatGPTStyle.border, lineWidth: 1)
    }
    .id(account.id)
  }

  private func summary(_ activity: AccountTokenActivity) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 0) {
        ForEach(Array(metrics(for: activity).enumerated()), id: \.offset) { index, metric in
          metricView(metric)
            .frame(maxWidth: .infinity)
          if index < 4 { Divider().frame(height: 44) }
        }
      }
      .frame(minWidth: 660)

      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 3), spacing: 0)
      {
        ForEach(Array(metrics(for: activity).enumerated()), id: \.offset) { _, metric in
          metricView(metric)
            .frame(maxWidth: .infinity)
        }
      }
    }
    .padding(.vertical, 10)
    .background(
      ChatGPTStyle.surface(for: colorScheme),
      in: RoundedRectangle(cornerRadius: 11, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .stroke(ChatGPTStyle.border, lineWidth: 1)
    }
  }

  private func metricView(_ metric: Metric) -> some View {
    VStack(spacing: 5) {
      Text(metric.value)
        .font(.system(size: 19, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      Text(metric.title)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
    .padding(.horizontal, 6)
    .frame(height: 62)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(metric.title)：\(metric.accessibilityValue)")
  }

  private func chartSection(_ activity: AccountTokenActivity) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("活动分布")
          .font(.system(size: 14, weight: .semibold))
        Spacer()
        Picker("统计方式", selection: $mode) {
          ForEach(ActivityMode.allCases) { option in
            Text(option.rawValue).tag(option)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 200)
      }

      if let buckets = activity.dailyUsageBuckets, !buckets.isEmpty {
        switch mode {
        case .daily:
          dailyHeatmap(buckets)
        case .weekly:
          weeklyChart(buckets)
        case .cumulative:
          cumulativeChart(buckets)
        }
      } else {
        Text("服务端尚未返回每日活动记录")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 120)
      }

      Text(chartExplanation)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
  }

  private func dailyHeatmap(_ buckets: [AccountTokenActivity.DailyBucket]) -> some View {
    let byDate = Dictionary(
      buckets.map { ($0.startDate, $0.tokens) },
      uniquingKeysWith: { _, latest in latest })
    let weeks = makeWeeks()
    let peak = max(buckets.map(\.tokens).max() ?? 0, 1)

    return VStack(alignment: .leading, spacing: 10) {
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          HStack(alignment: .top, spacing: 4) {
            ForEach(weeks, id: \.startDate) { week in
              VStack(spacing: 4) {
                ForEach(week.days, id: \.self) { date in
                  let value = byDate[date]
                  Button {
                    selectedDate = date
                  } label: {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                      .fill(heatColor(value, peak: peak))
                      .frame(width: 14, height: 14)
                      .overlay {
                        if selectedDate == date {
                          RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(ChatGPTStyle.actionBlue, lineWidth: 2)
                        }
                      }
                  }
                  .buttonStyle(.plain)
                  .help("\(date)：\(value.map { numberString($0) + " Token" } ?? "未返回数据")")
                  .accessibilityLabel(
                    "\(date)，\(value.map { numberString($0) + " Token" } ?? "未返回数据")")
                }
                Text(week.monthLabel)
                  .font(.system(size: 10))
                  .foregroundStyle(.secondary)
                  .frame(height: 16)
              }
              .id(week.startDate)
            }
          }
          .padding(2)
        }
        .onAppear {
          if let lastWeek = weeks.last {
            proxy.scrollTo(lastWeek.startDate, anchor: .trailing)
          }
        }
      }

      if let selectedDate {
        Text(
          "\(selectedDate) · \(byDate[selectedDate].map { numberString($0) + " Token" } ?? "未返回数据")"
        )
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
      } else {
        Text("点击日期方格查看数值")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 5) {
        Text("未返回")
        legendSquare(Color.primary.opacity(0.045))
        Text("零")
        legendSquare(Color.primary.opacity(0.09))
        Text("少")
        ForEach(1...4, id: \.self) { level in
          legendSquare(ChatGPTStyle.actionBlue.opacity(Double(level) / 4))
        }
        Text("多")
      }
      .font(.system(size: 10))
      .foregroundStyle(.secondary)
    }
  }

  private func legendSquare(_ color: Color) -> some View {
    RoundedRectangle(cornerRadius: 3, style: .continuous)
      .fill(color)
      .frame(width: 11, height: 11)
  }

  private var chartExplanation: String {
    switch mode {
    case .daily:
      "每日图显示最近一年。未返回的日期不按零用量计算。"
    case .weekly:
      "每周用量只汇总该周已返回的每日记录；没有记录的周不显示。"
    case .cumulative:
      "累计图只相加已返回的每日记录，可能小于上方的全生命周期总量。"
    }
  }

  private func weeklyChart(_ buckets: [AccountTokenActivity.DailyBucket]) -> some View {
    let points = weeklyPoints(buckets)
    let upperBound = Double(max(points.map(\.tokens).max() ?? 0, 1)) * 1.15
    return VStack(spacing: 4) {
      Chart(points) { point in
        BarMark(x: .value("周", point.date), y: .value("Token", point.tokens))
          .foregroundStyle(ChatGPTStyle.actionBlue.gradient)
      }
      .chartXAxis(.hidden)
      .chartYScale(domain: 0...upperBound)
      .chartYAxis { tokenAxis }
      .frame(height: 166)
      chartDateRange(points)
    }
    .accessibilityLabel("每周 Token 活动，共 \(points.count) 个有记录的周")
  }

  private func cumulativeChart(_ buckets: [AccountTokenActivity.DailyBucket]) -> some View {
    let points = cumulativePoints(buckets)
    let upperBound = Double(max(points.map(\.tokens).max() ?? 0, 1)) * 1.15
    return VStack(spacing: 4) {
      Chart(points) { point in
        LineMark(x: .value("日期", point.date), y: .value("Token", point.tokens))
          .foregroundStyle(ChatGPTStyle.actionBlue)
        PointMark(x: .value("日期", point.date), y: .value("Token", point.tokens))
          .foregroundStyle(ChatGPTStyle.actionBlue)
      }
      .chartXAxis(.hidden)
      .chartYScale(domain: 0...upperBound)
      .chartYAxis { tokenAxis }
      .frame(height: 166)
      chartDateRange(points)
    }
    .accessibilityLabel("已返回日期的累计 Token 活动，共 \(points.count) 天")
  }

  private var tokenAxis: some AxisContent {
    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
      AxisGridLine()
      AxisTick()
      AxisValueLabel {
        if let count = value.as(Int.self) {
          Text(compactNumber(count))
        } else if let count = value.as(Double.self) {
          Text(compactNumber(Int(count)))
        }
      }
    }
  }

  private func chartDateRange(_ points: [ChartPoint]) -> some View {
    HStack {
      Text(points.first?.date ?? "")
      Spacer()
      Text(points.last?.date ?? "")
    }
    .font(.system(size: 10))
    .foregroundStyle(.secondary)
  }

  private func metrics(for activity: AccountTokenActivity) -> [Metric] {
    [
      Metric(
        title: "累计 Token 数", value: compactNumber(activity.lifetimeTokens),
        accessibilityValue: activity.lifetimeTokens.map(numberString) ?? "暂无数据"),
      Metric(
        title: "单日峰值 Token", value: compactNumber(activity.peakDailyTokens),
        accessibilityValue: activity.peakDailyTokens.map(numberString) ?? "暂无数据"),
      Metric(
        title: "最长单轮时长", value: durationString(activity.longestRunningTurnSec),
        accessibilityValue: durationString(activity.longestRunningTurnSec)),
      Metric(
        title: "当前连续天数", value: activity.currentStreakDays.map { "\($0) 天" } ?? "—",
        accessibilityValue: activity.currentStreakDays.map { "\($0) 天" } ?? "暂无数据"),
      Metric(
        title: "最长连续天数", value: activity.longestStreakDays.map { "\($0) 天" } ?? "—",
        accessibilityValue: activity.longestStreakDays.map { "\($0) 天" } ?? "暂无数据"),
    ]
  }

  private func heatColor(_ tokens: Int?, peak: Int) -> Color {
    guard let tokens else { return Color.primary.opacity(0.045) }
    guard tokens > 0 else { return Color.primary.opacity(0.09) }
    let fraction = Double(tokens) / Double(peak)
    switch fraction {
    case ..<0.25: return ChatGPTStyle.actionBlue.opacity(0.25)
    case ..<0.5: return ChatGPTStyle.actionBlue.opacity(0.45)
    case ..<0.75: return ChatGPTStyle.actionBlue.opacity(0.7)
    default: return ChatGPTStyle.actionBlue
    }
  }

  private func makeWeeks() -> [Week] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.firstWeekday = 2
    let today = calendar.startOfDay(for: Date())
    let oneYearAgo = calendar.date(byAdding: .day, value: -364, to: today)!
    let firstWeek = calendar.dateInterval(of: .weekOfYear, for: oneYearAgo)!.start
    let lastWeek = calendar.dateInterval(of: .weekOfYear, for: today)!.start
    var result: [Week] = []
    var start = firstWeek
    var previousMonth = 0
    while start <= lastWeek {
      let days = (0..<7).map { offset in
        dateKey(calendar.date(byAdding: .day, value: offset, to: start)!, calendar: calendar)
      }
      let month = calendar.component(.month, from: start)
      let label = month == previousMonth ? "" : "\(month)月"
      result.append(Week(startDate: days[0], days: days, monthLabel: label))
      previousMonth = month
      start = calendar.date(byAdding: .day, value: 7, to: start)!
    }
    return result
  }

  private func weeklyPoints(_ buckets: [AccountTokenActivity.DailyBucket]) -> [ChartPoint] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.firstWeekday = 2
    let byDate = Dictionary(
      buckets.map { ($0.startDate, $0.tokens) },
      uniquingKeysWith: { _, latest in latest })
    var totals: [String: Int] = [:]
    for (day, tokens) in byDate {
      guard let date = parseDate(day, calendar: calendar) else { continue }
      let weekStart = calendar.dateInterval(of: .weekOfYear, for: date)!.start
      totals[dateKey(weekStart, calendar: calendar), default: 0] += tokens
    }
    return totals.keys.sorted().map { ChartPoint(date: $0, tokens: totals[$0] ?? 0) }
  }

  private func cumulativePoints(_ buckets: [AccountTokenActivity.DailyBucket]) -> [ChartPoint] {
    let byDate = Dictionary(
      buckets.map { ($0.startDate, $0.tokens) },
      uniquingKeysWith: { _, latest in latest })
    var total = 0
    return byDate.keys.sorted().map { date in
      total += byDate[date] ?? 0
      return ChartPoint(date: date, tokens: total)
    }
  }

  private func parseDate(_ value: String, calendar: Calendar) -> Date? {
    let parts = value.split(separator: "-")
    guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
      let day = Int(parts[2])
    else { return nil }
    return calendar.date(from: DateComponents(year: year, month: month, day: day))
  }

  private func dateKey(_ date: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  private func numberString(_ value: Int) -> String {
    value.formatted(.number.grouping(.automatic))
  }

  private func compactNumber(_ value: Int?) -> String {
    guard let value else { return "—" }
    if value >= 100_000_000 { return compact(Double(value) / 100_000_000) + "亿" }
    if value >= 10_000 { return compact(Double(value) / 10_000) + "万" }
    return numberString(value)
  }

  private func compact(_ value: Double) -> String {
    let rounded = String(format: "%.1f", value)
    return rounded.hasSuffix(".0") ? String(rounded.dropLast(2)) : rounded
  }

  private func durationString(_ seconds: Int?) -> String {
    guard let seconds else { return "—" }
    if seconds >= 3_600 {
      return "\(seconds / 3_600)时 \((seconds % 3_600) / 60)分"
    }
    return "\(seconds / 60)分 \(seconds % 60)秒"
  }

  private struct Metric {
    let title: String
    let value: String
    let accessibilityValue: String
  }

  private struct Week {
    let startDate: String
    let days: [String]
    let monthLabel: String
  }

  private struct ChartPoint: Identifiable {
    let date: String
    let tokens: Int
    var id: String { date }
  }

  private enum ActivityMode: String, CaseIterable, Identifiable {
    case daily = "每日"
    case weekly = "每周"
    case cumulative = "累计"
    var id: String { rawValue }
  }
}
