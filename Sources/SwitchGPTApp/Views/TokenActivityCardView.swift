import SwiftUI
import SwitchGPTAppCore

struct TokenActivityCardView: View {
  let account: AccountRecord

  @State private var mode: ActivityMode = .daily
  @State private var hoveredCell: String?
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
          L10n.string(account.usage.tokenActivityWasLoaded ? "暂无 Token 数据" : "暂时无法读取 Token 活动"),
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
    .accessibilityLabel(L10n.format("%@: %@", metric.title, metric.accessibilityValue))
  }

  private func chartSection(_ activity: AccountTokenActivity) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("活动分布")
          .font(.system(size: 14, weight: .semibold))
        Spacer()
        Picker("统计方式", selection: $mode) {
          ForEach(ActivityMode.allCases) { option in
            Text(L10n.string(option.rawValue)).tag(option)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 200)
      }

      if let buckets = activity.dailyUsageBuckets, !buckets.isEmpty {
        activityHeatmap(buckets)
      } else {
        Text("服务端尚未返回每日活动记录")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 120)
      }

      Text(L10n.string(chartExplanation))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
    .onChange(of: mode) { _, _ in hoveredCell = nil }
  }

  private func activityHeatmap(_ buckets: [AccountTokenActivity.DailyBucket]) -> some View {
    let byDate = Dictionary(
      buckets.map { ($0.startDate, $0.tokens) },
      uniquingKeysWith: { _, latest in latest })
    let byWeek = Dictionary(uniqueKeysWithValues: weeklyPoints(buckets).map { ($0.date, $0.tokens) })
    let cumulative = Dictionary(uniqueKeysWithValues: cumulativePoints(buckets).map { ($0.date, $0.tokens) })
    let weeks = makeWeeks()
    let peak: Int = switch mode {
    case .daily: max(byDate.values.max() ?? 0, 1)
    case .weekly: max(byWeek.values.max() ?? 0, 1)
    case .cumulative: max(cumulative.values.max() ?? 0, 1)
    }

    return VStack(alignment: .leading, spacing: 10) {
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          HStack(alignment: .top, spacing: 4) {
            ForEach(weeks, id: \.startDate) { week in
              VStack(spacing: 4) {
                ForEach(week.days, id: \.self) { date in
                  let value: Int? = switch mode {
                  case .daily: byDate[date]
                  case .weekly: byWeek[week.startDate]
                  case .cumulative: cumulative[date]
                  }
                  Button {
                    hoveredCell = date
                  } label: {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                      .fill(heatColor(value, peak: peak))
                      .frame(width: 14, height: 14)
                      .overlay {
                        if hoveredCell == date {
                          RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(ChatGPTStyle.actionBlue, lineWidth: 2)
                        }
                      }
                      .contentShape(Rectangle())
                  }
                  .buttonStyle(.plain)
                  .anchorPreference(key: CellAnchorPreference.self, value: .bounds) { [date: $0] }
                  .onHover { isHovered in
                    if isHovered {
                      hoveredCell = date
                    } else if hoveredCell == date {
                      hoveredCell = nil
                    }
                  }
                  .accessibilityLabel(valueLabel(date: date, weekStart: week.startDate, tokens: value))
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
        .overlayPreferenceValue(CellAnchorPreference.self) { anchors in
          GeometryReader { geometry in
            if let hoveredCell, let anchor = anchors[hoveredCell],
              let week = weeks.first(where: { $0.days.contains(hoveredCell) }) {
              let value: Int? = switch mode {
              case .daily: byDate[hoveredCell]
              case .weekly: byWeek[week.startDate]
              case .cumulative: cumulative[hoveredCell]
              }
              let rect = geometry[anchor]
              let tipWidth = min(260.0, max(geometry.size.width - 8, 120))
              Text(valueLabel(date: hoveredCell, weekStart: week.startDate, tokens: value))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 10)
                .frame(width: tipWidth, height: 30)
                .background(Color(red: 0.11, green: 0.13, blue: 0.15),
                  in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 9, y: 4)
                .position(
                  x: min(max(rect.midX, tipWidth / 2), max(geometry.size.width - tipWidth / 2, tipWidth / 2)),
                  y: rect.minY - 19)
                .allowsHitTesting(false)
            }
          }
        }
        .onAppear {
          if let lastWeek = weeks.last {
            proxy.scrollTo(lastWeek.startDate, anchor: .trailing)
          }
        }
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
      "每列代表一周，只汇总该周已返回的每日记录；没有记录的周显示浅灰。"
    case .cumulative:
      "每格代表截至当天已返回记录的累计值；没有记录的日期显示浅灰。此值可能小于上方的全生命周期总量。"
    }
  }

  private func valueLabel(date: String, weekStart: String, tokens: Int?) -> String {
    let label: String = switch mode {
    case .daily: date
    case .weekly: AppLanguage.selected.resourceCode == "zh-Hans"
      ? weekStart + " " + L10n.string("当周") : L10n.string("当周") + " " + weekStart
    case .cumulative: L10n.string("截至") + " " + date
    }
    guard let tokens else { return label + " · " + L10n.string("未返回数据") }
    return label + " · " + compactNumber(tokens) + " Token"
  }

  private func metrics(for activity: AccountTokenActivity) -> [Metric] {
    [
      Metric(
        title: L10n.string("累计 Token 数"), value: compactNumber(activity.lifetimeTokens),
        accessibilityValue: activity.lifetimeTokens.map(numberString) ?? L10n.string("暂无数据")),
      Metric(
        title: L10n.string("单日峰值 Token"), value: compactNumber(activity.peakDailyTokens),
        accessibilityValue: activity.peakDailyTokens.map(numberString) ?? L10n.string("暂无数据")),
      Metric(
        title: L10n.string("最长单轮时长"), value: durationString(activity.longestRunningTurnSec),
        accessibilityValue: durationString(activity.longestRunningTurnSec)),
      Metric(
        title: L10n.string("当前连续天数"), value: activity.currentStreakDays.map { L10n.format("%d days", $0) } ?? "—",
        accessibilityValue: activity.currentStreakDays.map { L10n.format("%d days", $0) } ?? L10n.string("暂无数据")),
      Metric(
        title: L10n.string("最长连续天数"), value: activity.longestStreakDays.map { L10n.format("%d days", $0) } ?? "—",
        accessibilityValue: activity.longestStreakDays.map { L10n.format("%d days", $0) } ?? L10n.string("暂无数据")),
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
      let label = month == previousMonth ? "" : L10n.month(month)
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
    value.formatted(.number.grouping(.automatic).locale(AppLanguage.selected.locale))
  }

  private func compactNumber(_ value: Int?) -> String {
    guard let value else { return "—" }
    let units: [(Int, String)] = AppLanguage.selected.resourceCode == "zh-Hans"
      ? [(100_000_000, "亿"), (10_000_000, "千万"), (1_000_000, "百万"), (10_000, "万"), (1_000, "千")]
      : [(1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")]
    for (threshold, suffix) in units where value >= threshold {
      return compact(Double(value) / Double(threshold)) + suffix
    }
    return numberString(value)
  }

  private func compact(_ value: Double) -> String {
    let digits = value < 10 ? 2 : value < 100 ? 1 : 0
    let rounded = String(format: "%.*f", digits, value)
    guard rounded.contains(".") else { return rounded }
    return rounded.replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression)
  }

  private func durationString(_ seconds: Int?) -> String {
    guard let seconds else { return "—" }
    if seconds >= 3_600 {
      return L10n.format("%d h %d m", seconds / 3_600, (seconds % 3_600) / 60)
    }
    return L10n.format("%d m %d s", seconds / 60, seconds % 60)
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

  private struct CellAnchorPreference: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
      value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
  }

  private enum ActivityMode: String, CaseIterable, Identifiable {
    case daily = "每日"
    case weekly = "每周"
    case cumulative = "累计"
    var id: String { rawValue }
  }
}
