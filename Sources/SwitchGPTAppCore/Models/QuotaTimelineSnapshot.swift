import Foundation

/// The display data sent to the bundled quota timeline.
public struct QuotaTimelineSnapshot: Encodable, Equatable, Sendable {
  struct Row: Encodable, Equatable, Sendable {
    let name: String
    let plan: String
    let remaining: Int?
    let resetAt: Date?
    let cardCount: Int?
    let cards: [Date]
    let failed: Bool
    let refreshedAt: Date?

    init?(account: AccountRecord, failed: Bool) {
      switch account.planName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "pro lite", "chatgpt pro lite", "pro 100", "chatgpt pro 100":
        plan = "Pro 100"
      case "pro", "chatgpt pro", "pro 200", "chatgpt pro 200":
        plan = "Pro 200"
      default:
        return nil
      }

      name = account.accountLabel
      self.failed = failed
      refreshedAt = account.usageRefreshedAt
      // A stored account without a successful read can carry default usage values.
      let usage = refreshedAt.map { _ in account.usage }
      remaining = usage?.weekly.remainingPercent
      resetAt = usage?.weekly.resetAt
      cardCount = usage?.resetCredits?.availableCount
      cards = usage?.resetCredits?.credits?.compactMap(\.expiresAt).sorted() ?? []
    }
  }

  let asOf: Date
  let accounts: [Row]
  let language: String

  public init(
    accounts: [AccountRecord],
    failedAccountIDs: Set<AccountID>,
    lastRefreshedAt: Date?,
    language: String,
    now: Date = Date()
  ) {
    let rows = accounts.compactMap { account in
      Row(account: account, failed: failedAccountIDs.contains(account.id))
    }
    self.accounts = rows
    asOf = rows.compactMap(\.refreshedAt).max() ?? lastRefreshedAt ?? now
    self.language = language
  }
}
