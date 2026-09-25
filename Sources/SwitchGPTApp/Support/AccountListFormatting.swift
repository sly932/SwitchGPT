import Foundation
import SwitchGPTAppCore

extension AccountDisplayField {
  var title: String {
    switch self {
    case .plan: return "Plan"
    case .weeklyRemaining: return "Weekly remaining"
    case .lastUpdated: return "Last updated"
    case .fiveHourRemaining: return "5-hour remaining"
    case .credits: return "Credits balance"
    case .weeklyReset: return "Weekly reset"
    }
  }

  func text(for account: AccountRecord, refreshFailed: Bool = false) -> String {
    switch self {
    case .plan:
      return account.planName
    case .weeklyRemaining:
      return "W \(account.usage.weekly.remainingPercent)%"
    case .fiveHourRemaining:
      guard let window = account.usage.fiveHour else { return "5h unavailable" }
      return "5h \(window.remainingPercent)%"
    case .credits:
      guard account.usage.creditsWereLoaded else { return "Credits unavailable" }
      guard let credits = account.usage.credits else { return "No credits" }
      if credits.unlimited { return "Credits unlimited" }
      guard let balance = credits.usdBalance else { return "Credits unavailable" }
      let formatter = NumberFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.numberStyle = .decimal
      formatter.minimumFractionDigits = 2
      formatter.maximumFractionDigits = 2
      let amount = formatter.string(from: NSDecimalNumber(decimal: balance)) ?? "—"
      return "Credits US$" + amount
    case .weeklyReset:
      return "Resets " + account.usage.weekly.resetAt.formatted(date: .abbreviated, time: .shortened)
    case .lastUpdated:
      guard let date = account.usageRefreshedAt else {
        return refreshFailed ? "Refresh failed · time unknown" : "Update time unknown"
      }
      let timestamp = Calendar.current.isDateInToday(date)
        ? date.formatted(date: .omitted, time: .shortened)
        : date.formatted(date: .abbreviated, time: .shortened)
      return (refreshFailed ? "Old data · " : "Updated ") + timestamp
    }
  }
}

extension AccountListSettings {
  func summary(for account: AccountRecord, refreshFailed: Bool = false) -> String {
    orderedVisibleFields.map { $0.text(for: account, refreshFailed: refreshFailed) }
      .joined(separator: " · ")
  }
}
