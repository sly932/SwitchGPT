import Foundation

/// A read-only sum of saved snapshots. Reading this value never fetches usage.
/// Accounts whose most recent quota read failed are excluded; missing values remain unknown.
public struct AllAccountsTokenActivity: Equatable, Sendable {
  public let activity: AccountTokenActivity?
  public let eligibleAccountCount: Int
  public let contributingAccountCount: Int
  public let excludedAccountCount: Int
  public let hasMissingData: Bool

  public init(accounts: [AccountRecord], excluding failedAccountIDs: Set<AccountID> = []) {
    let eligible = accounts.filter { !failedAccountIDs.contains($0.id) }
    let activities = eligible.compactMap { $0.usage.tokenActivity }
    eligibleAccountCount = eligible.count
    contributingAccountCount = activities.count
    excludedAccountCount = accounts.count - eligible.count
    hasMissingData = activities.count < eligible.count || activities.contains {
      $0.lifetimeTokens == nil || $0.peakDailyTokens == nil
        || $0.longestRunningTurnSec == nil || $0.currentStreakDays == nil
        || $0.longestStreakDays == nil || $0.dailyUsageBuckets == nil
    }
    guard !activities.isEmpty else {
      activity = nil
      return
    }

    func sum(_ keyPath: KeyPath<AccountTokenActivity, Int?>) -> Int? {
      let values = activities.compactMap { $0[keyPath: keyPath] }
      return values.isEmpty ? nil : values.reduce(0, +)
    }

    var byDate: [String: Int] = [:]
    let dailyRecordsWereReturned = activities.contains { $0.dailyUsageBuckets != nil }
    for item in activities {
      // Match the individual chart: a duplicate date within one snapshot uses the last record.
      let accountDays = Dictionary(
        (item.dailyUsageBuckets ?? []).map { ($0.startDate, $0.tokens) },
        uniquingKeysWith: { _, latest in latest })
      for (date, tokens) in accountDays {
        byDate[date, default: 0] += tokens
      }
    }
    activity = AccountTokenActivity(
      lifetimeTokens: sum(\.lifetimeTokens),
      peakDailyTokens: sum(\.peakDailyTokens),
      longestRunningTurnSec: sum(\.longestRunningTurnSec),
      currentStreakDays: sum(\.currentStreakDays),
      longestStreakDays: sum(\.longestStreakDays),
      dailyUsageBuckets: dailyRecordsWereReturned
        ? byDate.keys.sorted().map { .init(startDate: $0, tokens: byDate[$0]!) } : nil
    )
  }
}
