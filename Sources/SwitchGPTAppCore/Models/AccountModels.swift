import Foundation

public struct AccountID: Hashable, Codable, Sendable, Identifiable {
  public let rawValue: String

  public var id: String { rawValue }

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

public enum AccountAccent: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
  case orange
  case blue
  case purple
  case green
}

public enum AccountSource: Codable, Equatable, Hashable, Sendable {
  case mock
  case codexHome(path: String)
}

public struct UsageWindow: Codable, Equatable, Hashable, Sendable {
  public let usedPercent: Int
  public let resetAt: Date

  public var remainingPercent: Int {
    100 - usedPercent
  }

  public init(usedPercent: Int, resetAt: Date) {
    self.usedPercent = min(max(usedPercent, 0), 100)
    self.resetAt = resetAt
  }
}

public struct CreditBalance: Codable, Equatable, Hashable, Sendable {
  public let hasCredits: Bool
  public let unlimited: Bool
  public let points: Decimal?

  public var isDisplayable: Bool {
    unlimited || points != nil || hasCredits
  }

  /// ChatGPT displays 1,000 credit points as US$40.
  public var usdBalance: Decimal? {
    points.map { $0 * Decimal(4) / Decimal(100) }
  }

  public init(hasCredits: Bool, unlimited: Bool, points: Decimal? = nil) {
    self.hasCredits = hasCredits
    self.unlimited = unlimited
    self.points = points
  }

  private enum CodingKeys: String, CodingKey {
    case hasCredits
    case unlimited
    case points
    case legacyBalance = "balance"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    hasCredits = try container.decode(Bool.self, forKey: .hasCredits)
    unlimited = try container.decode(Bool.self, forKey: .unlimited)
    points =
      try container.decodeIfPresent(Decimal.self, forKey: .points)
      ?? container.decodeIfPresent(Decimal.self, forKey: .legacyBalance)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(hasCredits, forKey: .hasCredits)
    try container.encode(unlimited, forKey: .unlimited)
    try container.encodeIfPresent(points, forKey: .points)
  }
}

/// Metadata-only reset-credit detail used by the read-only dashboard.
///
/// The app-server also returns an opaque identifier that can be used to redeem a
/// credit. SwitchGPT intentionally does not model or persist that identifier.
public struct RateLimitResetCredit: Codable, Equatable, Hashable, Sendable {
  public let expiresAt: Date?

  public init(expiresAt: Date?) {
    self.expiresAt = expiresAt
  }
}

public struct RateLimitResetCreditExpirationGroup: Equatable, Hashable, Sendable {
  public let expiresAt: Date?
  public let count: Int

  public init(expiresAt: Date?, count: Int) {
    self.expiresAt = expiresAt
    self.count = max(0, count)
  }
}

public struct RateLimitResetCreditsSummary: Codable, Equatable, Hashable, Sendable {
  public let availableCount: Int

  /// `nil` means the backend returned only the authoritative count. An empty
  /// array means details were loaded and no available detail rows were returned.
  public let credits: [RateLimitResetCredit]?

  public var nearestKnownExpiry: Date? {
    credits?.compactMap(\.expiresAt).min()
  }

  public var knownDetailCount: Int {
    credits?.count ?? 0
  }

  public var missingDetailCount: Int {
    max(availableCount - knownDetailCount, 0)
  }

  public var detailsAreComplete: Bool {
    credits != nil && missingDetailCount == 0
  }

  public var expirationGroups: [RateLimitResetCreditExpirationGroup] {
    let grouped = Dictionary(grouping: credits ?? [], by: \.expiresAt)
    return grouped.map { expiresAt, credits in
      RateLimitResetCreditExpirationGroup(expiresAt: expiresAt, count: credits.count)
    }
    .sorted { lhs, rhs in
      switch (lhs.expiresAt, rhs.expiresAt) {
      case (let left?, let right?):
        return left < right
      case (_?, nil):
        return true
      case (nil, _?):
        return false
      case (nil, nil):
        return false
      }
    }
  }

  public init(availableCount: Int, credits: [RateLimitResetCredit]?) {
    let normalizedAvailableCount = max(0, availableCount)
    self.availableCount = normalizedAvailableCount
    self.credits = credits.map { Array($0.prefix(normalizedAvailableCount)) }
  }

  private enum CodingKeys: String, CodingKey {
    case availableCount
    case credits
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let normalizedAvailableCount =
      max(0, try container.decode(Int.self, forKey: .availableCount))
    availableCount = normalizedAvailableCount
    let decodedCredits =
      try container.decodeIfPresent([RateLimitResetCredit].self, forKey: .credits)
    credits = decodedCredits.map { Array($0.prefix(normalizedAvailableCount)) }
  }
}

public struct AccountUsage: Codable, Equatable, Hashable, Sendable {
  public let weekly: UsageWindow
  public let fiveHour: UsageWindow?
  public let credits: CreditBalance?
  public let creditsWereLoaded: Bool
  public let resetCredits: RateLimitResetCreditsSummary?
  public let resetCreditsWereLoaded: Bool
  public let tokenActivity: AccountTokenActivity?
  public let tokenActivityWasLoaded: Bool

  public init(
    weekly: UsageWindow,
    fiveHour: UsageWindow? = nil,
    credits: CreditBalance? = nil,
    creditsWereLoaded: Bool? = nil,
    resetCredits: RateLimitResetCreditsSummary? = nil,
    resetCreditsWereLoaded: Bool? = nil,
    tokenActivity: AccountTokenActivity? = nil,
    tokenActivityWasLoaded: Bool = false
  ) {
    self.weekly = weekly
    self.fiveHour = fiveHour
    self.credits = credits
    self.creditsWereLoaded = creditsWereLoaded ?? (credits != nil)
    self.resetCredits = resetCredits
    self.resetCreditsWereLoaded = resetCreditsWereLoaded ?? (resetCredits != nil)
    self.tokenActivity = tokenActivity
    self.tokenActivityWasLoaded = tokenActivityWasLoaded
  }

  private enum CodingKeys: String, CodingKey {
    case weekly
    case fiveHour
    case credits
    case creditsWereLoaded
    case resetCredits
    case resetCreditsWereLoaded
    case tokenActivity
    case tokenActivityWasLoaded
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    weekly = try container.decode(UsageWindow.self, forKey: .weekly)
    fiveHour = try container.decodeIfPresent(UsageWindow.self, forKey: .fiveHour)
    credits = try container.decodeIfPresent(CreditBalance.self, forKey: .credits)
    creditsWereLoaded =
      try container.decodeIfPresent(Bool.self, forKey: .creditsWereLoaded) ?? false
    resetCredits =
      try container.decodeIfPresent(RateLimitResetCreditsSummary.self, forKey: .resetCredits)
    resetCreditsWereLoaded =
      try container.decodeIfPresent(Bool.self, forKey: .resetCreditsWereLoaded) ?? false
    tokenActivity = try container.decodeIfPresent(AccountTokenActivity.self, forKey: .tokenActivity)
    tokenActivityWasLoaded =
      try container.decodeIfPresent(Bool.self, forKey: .tokenActivityWasLoaded) ?? false
  }

  public func withTokenActivity(_ activity: AccountTokenActivity) -> AccountUsage {
    AccountUsage(
      weekly: weekly,
      fiveHour: fiveHour,
      credits: credits,
      creditsWereLoaded: creditsWereLoaded,
      resetCredits: resetCredits,
      resetCreditsWereLoaded: resetCreditsWereLoaded,
      tokenActivity: activity,
      tokenActivityWasLoaded: true
    )
  }
}

/// The account-level usage returned by Codex services. Missing values are unknown, not zero.
public struct AccountTokenActivity: Codable, Equatable, Hashable, Sendable {
  public struct DailyBucket: Codable, Equatable, Hashable, Sendable {
    public let startDate: String
    public let tokens: Int

    public init(startDate: String, tokens: Int) {
      self.startDate = startDate
      self.tokens = tokens
    }
  }

  public let lifetimeTokens: Int?
  public let peakDailyTokens: Int?
  public let longestRunningTurnSec: Int?
  public let currentStreakDays: Int?
  public let longestStreakDays: Int?
  public let dailyUsageBuckets: [DailyBucket]?

  public init(
    lifetimeTokens: Int?,
    peakDailyTokens: Int?,
    longestRunningTurnSec: Int?,
    currentStreakDays: Int?,
    longestStreakDays: Int?,
    dailyUsageBuckets: [DailyBucket]?
  ) {
    self.lifetimeTokens = lifetimeTokens
    self.peakDailyTokens = peakDailyTokens
    self.longestRunningTurnSec = longestRunningTurnSec
    self.currentStreakDays = currentStreakDays
    self.longestStreakDays = longestStreakDays
    self.dailyUsageBuckets = dailyUsageBuckets
  }
}

public struct AccountRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
  public let id: AccountID
  public let displayName: String
  public let email: String?
  public let detail: String
  public let planName: String
  public let symbolName: String
  public let accent: AccountAccent
  public let source: AccountSource
  public let identityHash: String?
  public var usage: AccountUsage

  public init(
    id: AccountID,
    displayName: String,
    email: String? = nil,
    detail: String,
    planName: String,
    symbolName: String,
    accent: AccountAccent,
    usage: AccountUsage,
    source: AccountSource = .mock,
    identityHash: String? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.email = email
    self.detail = detail
    self.planName = planName
    self.symbolName = symbolName
    self.accent = accent
    self.source = source
    self.identityHash = identityHash
    self.usage = usage
  }

  public var accountLabel: String {
    let normalizedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return normalizedEmail.isEmpty ? displayName : normalizedEmail
  }

  public func compactAccountLabel(maximumLength: Int = 30) -> String {
    let label = accountLabel
    guard maximumLength >= 8, label.count > maximumLength else { return label }

    if let atIndex = label.lastIndex(of: "@") {
      let domain = String(label[atIndex...])
      let localPart = String(label[..<atIndex])
      let availableLocalCharacters = maximumLength - domain.count - 1
      if availableLocalCharacters >= 4 {
        return String(localPart.prefix(availableLocalCharacters)) + "…" + domain
      }
    }

    let prefixCount = (maximumLength - 1) / 2
    let suffixCount = maximumLength - prefixCount - 1
    return String(label.prefix(prefixCount)) + "…" + String(label.suffix(suffixCount))
  }
}

public enum MockAccountCatalog {
  public static func accounts(now: Date = Date()) -> [AccountRecord] {
    let calendar = Calendar.autoupdatingCurrent
    let personalWeeklyReset = calendar.date(byAdding: .day, value: 4, to: now) ?? now
    let workWeeklyReset = calendar.date(byAdding: .day, value: 3, to: now) ?? now

    return [
      AccountRecord(
        id: AccountID("personal"),
        displayName: "Personal",
        detail: "Private workspace",
        planName: "ChatGPT Plus",
        symbolName: "person.crop.circle.fill",
        accent: .orange,
        usage: AccountUsage(
          weekly: UsageWindow(usedPercent: 21, resetAt: personalWeeklyReset)
        )
      ),
      AccountRecord(
        id: AccountID("work"),
        displayName: "Work",
        detail: "Team workspace",
        planName: "ChatGPT Plus",
        symbolName: "briefcase.circle.fill",
        accent: .blue,
        usage: AccountUsage(
          weekly: UsageWindow(usedPercent: 64, resetAt: workWeeklyReset)
        )
      ),
    ]
  }

  public static func makeAdditionalAccount(
    displayName: String,
    detail: String,
    ordinal: Int,
    now: Date = Date()
  ) -> AccountRecord {
    let calendar = Calendar.autoupdatingCurrent
    let resetDays = 2 + (ordinal % 4)
    let weeklyReset = calendar.date(byAdding: .day, value: resetDays, to: now) ?? now
    let accentIndex = max(0, ordinal) % AccountAccent.allCases.count
    let usedPercent = min(20 + (max(0, ordinal - 2) * 17), 84)

    return AccountRecord(
      id: AccountID("mock-" + UUID().uuidString.lowercased()),
      displayName: displayName,
      detail: detail,
      planName: "ChatGPT Plus",
      symbolName: "person.crop.circle.badge.plus",
      accent: AccountAccent.allCases[accentIndex],
      usage: AccountUsage(
        weekly: UsageWindow(usedPercent: usedPercent, resetAt: weeklyReset)
      )
    )
  }
}
