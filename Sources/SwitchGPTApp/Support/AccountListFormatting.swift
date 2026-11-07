import Foundation
import SwitchGPTAppCore

extension AccountDisplayField {
  var title: String {
    switch self {
    case .plan: return L10n.string("Plan")
    case .weeklyRemaining: return L10n.string("Weekly remaining")
    case .lastUpdated: return L10n.string("Last updated")
    case .fiveHourRemaining: return L10n.string("5-hour remaining")
    case .credits: return L10n.string("Credits balance")
    case .weeklyReset: return L10n.string("Weekly reset")
    case .subscriptionExpiry: return L10n.string("Subscription expiry (manual)")
    }
  }

  func text(
    for account: AccountRecord,
    resetTimeFormat: ResetTimeFormat,
    refreshFailed: Bool = false,
    subscriptionExpiry: String? = nil
  ) -> String {
    switch self {
    case .plan:
      return account.planName
    case .weeklyRemaining:
      return L10n.string("W ") + "\(account.usage.weekly.remainingPercent)%"
    case .fiveHourRemaining:
      guard let window = account.usage.fiveHour else { return L10n.string("5h unavailable") }
      return L10n.string("5h ") + "\(window.remainingPercent)%"
    case .credits:
      guard account.usage.creditsWereLoaded else { return L10n.string("Credits unavailable") }
      guard let credits = account.usage.credits else { return L10n.string("No credits") }
      if credits.unlimited { return L10n.string("Credits unlimited") }
      guard let balance = credits.usdBalance else { return L10n.string("Credits unavailable") }
      let formatter = NumberFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.numberStyle = .decimal
      formatter.minimumFractionDigits = 2
      formatter.maximumFractionDigits = 2
      let amount = formatter.string(from: NSDecimalNumber(decimal: balance)) ?? "—"
      return L10n.string("Credits US$") + amount
    case .weeklyReset:
      return resetTimeFormat.text(for: account.usage.weekly.resetAt)
    case .subscriptionExpiry:
      guard let subscriptionExpiry else { return L10n.string("Expiry · Not recorded") }
      return L10n.format("Expiry %@ · Manual", subscriptionExpiry)
    case .lastUpdated:
      guard let date = account.usageRefreshedAt else {
        return L10n.string(refreshFailed ? "Refresh failed · time unknown" : "Update time unknown")
      }
      let timestamp = Calendar.current.isDateInToday(date)
        ? L10n.date(date, date: .none, time: .short)
        : L10n.date(date, date: .medium, time: .short)
      return L10n.string(refreshFailed ? "Old data · " : "Updated ") + timestamp
    }
  }
}

extension AccountListSettings {
  func summary(
    for account: AccountRecord,
    resetTimeFormat: ResetTimeFormat,
    refreshFailed: Bool = false,
    excludingWeeklyReset: Bool = false,
    excludingSubscriptionExpiry: Bool = false,
    subscriptionExpiry: String? = nil
  ) -> String {
    orderedVisibleFields.filter {
      (!excludingWeeklyReset || $0 != .weeklyReset)
        && (!excludingSubscriptionExpiry || $0 != .subscriptionExpiry)
    }.map {
      $0.text(
        for: account,
        resetTimeFormat: resetTimeFormat,
        refreshFailed: refreshFailed,
        subscriptionExpiry: subscriptionExpiry
      )
    }
      .joined(separator: " · ")
  }

  func subscriptionExpiryText(
    for account: AccountRecord,
    resetTimeFormat: ResetTimeFormat,
    subscriptionExpiry: String?
  ) -> String? {
    guard visibleFields.contains(.subscriptionExpiry) else { return nil }
    return AccountDisplayField.subscriptionExpiry.text(
      for: account, resetTimeFormat: resetTimeFormat, subscriptionExpiry: subscriptionExpiry
    )
  }

  func weeklyResetText(
    for account: AccountRecord,
    resetTimeFormat: ResetTimeFormat
  ) -> String? {
    guard visibleFields.contains(.weeklyReset) else { return nil }
    return resetTimeFormat.text(for: account.usage.weekly.resetAt)
  }
}
