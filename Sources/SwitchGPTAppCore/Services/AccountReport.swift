import Foundation

/// A versioned export contract. Deliberately excludes authentication, identity hashes and home paths.
public struct AccountReport: Encodable, Sendable {
  public let schemaVersion = 1
  public let command: String
  public let source: String
  public let generatedAt: Date
  public let accounts: [AccountReportEntry]
  public var totalCount: Int { accounts.count }
  public var errorCount: Int { accounts.filter { $0.status == "error" }.count }
  public var partialCount: Int { accounts.filter { $0.status == "partial" }.count }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, command, source, generatedAt, accounts, totalCount, errorCount, partialCount
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(schemaVersion, forKey: .schemaVersion)
    try values.encode(command, forKey: .command)
    try values.encode(source, forKey: .source)
    try values.encode(generatedAt, forKey: .generatedAt)
    try values.encode(accounts, forKey: .accounts)
    try values.encode(totalCount, forKey: .totalCount)
    try values.encode(errorCount, forKey: .errorCount)
    try values.encode(partialCount, forKey: .partialCount)
  }
}

public struct AccountReportEntry: Encodable, Sendable {
  public let id: String
  public let displayName: String
  public let email: String?
  /// Live query failures retain only the last saved plan label, never a fresh quota.
  public let planName: String
  public let status: String
  public let refreshedAt: Date?
  public let quota: QuotaReport?
  public let usage: AccountTokenActivity?
  public let tokenActivityWasLoaded: Bool?
  public let error: AccountReportError?
}

public struct QuotaReport: Encodable, Sendable {
  public struct Window: Encodable, Sendable {
    public let usedPercent: Int
    public let remainingPercent: Int
    public let resetAt: Date

    init(_ window: UsageWindow) {
      usedPercent = window.usedPercent
      remainingPercent = window.remainingPercent
      resetAt = window.resetAt
    }
  }

  public let weekly: Window
  public let fiveHour: Window?
  public let credits: CreditBalance?
  public let creditsWereLoaded: Bool
  public let resetCredits: RateLimitResetCreditsSummary?
  public let resetCreditsWereLoaded: Bool

  init(_ usage: AccountUsage) {
    weekly = Window(usage.weekly)
    fiveHour = usage.fiveHour.map(Window.init)
    credits = usage.credits
    creditsWereLoaded = usage.creditsWereLoaded
    resetCredits = usage.resetCredits
    resetCreditsWereLoaded = usage.resetCreditsWereLoaded
  }
}

public struct AccountReportError: Encodable, Sendable {
  public let code: String
  public let message: String

  static func safe(_ error: Error) -> Self {
    guard let error = error as? QuotaReadingError else {
      return Self(code: "query_failed", message: "The account query failed.")
    }
    // Only our own fixed messages reach stdout; upstream errors may contain credentials or paths.
    let code: String
    switch error {
    case .unsupportedSource: code = "unsupported_source"
    case .invalidHomePath: code = "invalid_home_path"
    case .insecureHomePermissions: code = "insecure_home_permissions"
    case .missingAuthenticationFile: code = "missing_authentication_file"
    case .invalidAuthenticationFile: code = "invalid_authentication_file"
    case .identityNotPinned: code = "identity_not_pinned"
    case .identityMismatch: code = "identity_mismatch"
    case .missingCodexBinary: code = "missing_codex_binary"
    case .processLaunchFailed: code = "process_launch_failed"
    case .timedOut: code = "timed_out"
    case .invalidProtocolResponse: code = "invalid_protocol_response"
    case .missingRateLimit: code = "missing_rate_limit"
    }
    return Self(code: code, message: error.localizedDescription)
  }
}

public struct AccountReportService: Sendable {
  private let reader: any QuotaReading

  public init(reader: any QuotaReading) { self.reader = reader }

  /// Query accounts independently, with at most four active app-server processes.
  /// Results retain the saved account order even when requests finish out of order.
  public func report(
    accounts: [AccountRecord], includeUsage: Bool, cached: Bool = false
  ) async -> AccountReport {
    var entries: [AccountReportEntry] = []
    for start in stride(from: 0, to: accounts.count, by: 4) {
      let batch = Array(accounts[start..<min(start + 4, accounts.count)])
      let results = await withTaskGroup(of: (Int, AccountReportEntry).self) { group in
        for (index, account) in batch.enumerated() {
          group.addTask {
            (index, await entry(account, includeUsage: includeUsage, cached: cached))
          }
        }
        var results: [(Int, AccountReportEntry)] = []
        for await result in group { results.append(result) }
        return results.sorted { $0.0 < $1.0 }.map(\.1)
      }
      entries.append(contentsOf: results)
    }
    return AccountReport(
      command: includeUsage ? "usage" : "quota", source: cached ? "cache" : "live",
      generatedAt: Date(), accounts: entries
    )
  }

  private func entry(
    _ account: AccountRecord, includeUsage: Bool, cached: Bool
  ) async -> AccountReportEntry {
    do {
      let snapshot: AccountQuotaSnapshot
      let refreshedAt: Date?
      if cached {
        guard account.usageRefreshedAt != nil else {
          return failure(account, error: .init(
            code: "no_cached_snapshot", message: "No successfully refreshed snapshot is saved."))
        }
        snapshot = AccountQuotaSnapshot(
          email: account.email, planName: account.planName, usage: account.usage)
        refreshedAt = account.usageRefreshedAt
      } else {
        guard case .codexHome = account.source else { throw QuotaReadingError.unsupportedSource }
        guard let value = try await reader.fetchSnapshots(for: [account])[account.id] else {
          throw QuotaReadingError.missingRateLimit
        }
        snapshot = value
        refreshedAt = Date()
      }
      let usage = snapshot.usage
      let partial = includeUsage && !usage.tokenActivityWasLoaded
      return AccountReportEntry(
        id: account.id.rawValue, displayName: account.displayName,
        email: snapshot.email ?? account.email, planName: snapshot.planName,
        status: partial ? "partial" : "ok", refreshedAt: refreshedAt,
        quota: QuotaReport(usage), usage: includeUsage ? usage.tokenActivity : nil,
        tokenActivityWasLoaded: includeUsage ? usage.tokenActivityWasLoaded : nil,
        error: partial ? .init(
          code: "token_activity_unavailable",
          message: "Quota is available, but token activity could not be loaded.") : nil
      )
    } catch {
      return failure(account, error: .safe(error))
    }
  }

  private func failure(_ account: AccountRecord, error: AccountReportError) -> AccountReportEntry {
    AccountReportEntry(
      id: account.id.rawValue, displayName: account.displayName, email: account.email,
      planName: account.planName, status: "error", refreshedAt: account.usageRefreshedAt,
      quota: nil, usage: nil, tokenActivityWasLoaded: nil, error: error
    )
  }
}
