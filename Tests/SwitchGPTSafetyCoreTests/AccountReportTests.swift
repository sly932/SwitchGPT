import XCTest
@testable import SwitchGPTAppCore

final class AccountReportTests: XCTestCase {
  func testFailureDoesNotHideOtherAccountsAndOrderIsStable() async throws {
    let report = await AccountReportService(reader: ReportReader()).report(
      accounts: [account("bad"), account("good"), account("unknown"), account("good2"), account("good3")],
      includeUsage: true)
    XCTAssertEqual(report.accounts.map(\.id), ["bad", "good", "unknown", "good2", "good3"])
    XCTAssertEqual(report.errorCount, 2)
    XCTAssertEqual(report.accounts[0].error?.code, "identity_mismatch")
    XCTAssertNil(report.accounts[0].quota)
    XCTAssertEqual(report.accounts[1].quota?.weekly.remainingPercent, 75)
    XCTAssertEqual(report.accounts[1].planName, "Pro")
    XCTAssertEqual(report.accounts[1].usage?.lifetimeTokens, 123)
    XCTAssertEqual(report.accounts[2].error?.code, "query_failed")
    let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
    XCTAssertFalse(json.contains("SECRET"))
    XCTAssertFalse(json.contains("private/home"))
    XCTAssertFalse(json.contains("identityHash"))
    XCTAssertFalse(json.contains("sourcePath"))
  }

  func testAllFailuresStillProduceReport() async {
    let report = await AccountReportService(reader: ReportReader()).report(
      accounts: [account("bad"), account("unknown")], includeUsage: false)
    XCTAssertEqual(report.totalCount, 2)
    XCTAssertEqual(report.errorCount, 2)
  }

  func testQuotaOmitsTokenActivityAndEncodesRemainingPercent() async throws {
    let report = await AccountReportService(reader: ReportReader()).report(
      accounts: [account("good")], includeUsage: false)
    let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
    XCTAssertFalse(json.contains("tokenActivityWasLoaded"))
    XCTAssertFalse(json.contains("lifetimeTokens"))
    XCTAssertTrue(json.contains("remainingPercent"))
    XCTAssertEqual(report.accounts.first?.quota?.resetCredits?.availableCount, 2)
    XCTAssertEqual(report.accounts.first?.quota?.resetCredits?.missingDetailCount, 1)
  }

  func testCachedDataDoesNotCallReaderAndMissingTimestampIsNotFresh() async {
    let service = AccountReportService(reader: ReportReader())
    let report = await service.report(
      accounts: [account("bad"), account("untimed", timestamp: nil)], includeUsage: true, cached: true)
    XCTAssertEqual(report.source, "cache")
    XCTAssertEqual(report.accounts[0].status, "partial")
    XCTAssertEqual(report.accounts[0].refreshedAt, Date(timeIntervalSince1970: 100))
    XCTAssertNil(report.accounts[0].usage)
    XCTAssertEqual(report.accounts[0].tokenActivityWasLoaded, false)
    XCTAssertEqual(report.accounts[1].error?.code, "no_cached_snapshot")
    XCTAssertNil(report.accounts[1].quota)
  }

  func testEmptyAccountsAndMissingOptionalUsage() async {
    let service = AccountReportService(reader: ReportReader())
    let empty = await service.report(accounts: [], includeUsage: false)
    XCTAssertEqual(empty.totalCount, 0)
    let report = await service.report(accounts: [account("partial")], includeUsage: true)
    XCTAssertEqual(report.partialCount, 1)
    XCTAssertEqual(report.errorCount, 0)
    XCTAssertNotNil(report.accounts[0].quota)
    XCTAssertEqual(report.accounts[0].error?.code, "token_activity_unavailable")
  }

  private func account(_ id: String, timestamp: Date? = Date(timeIntervalSince1970: 100)) -> AccountRecord {
    AccountRecord(
      id: AccountID(id), displayName: id, detail: "", planName: "Saved plan",
      symbolName: "person", accent: .blue,
      usage: AccountUsage(weekly: UsageWindow(usedPercent: 90, resetAt: Date())),
      source: .codexHome(path: "/private/home/SECRET"), identityHash: "012345abcdef",
      usageRefreshedAt: timestamp)
  }
}

private struct ReportReader: QuotaReading {
  struct SecretError: Error { let message = "SECRET /private/home" }

  func fetchSnapshots(for accounts: [AccountRecord]) async throws -> [AccountID: AccountQuotaSnapshot] {
    let account = accounts[0]
    if account.id.rawValue == "bad" { throw QuotaReadingError.identityMismatch }
    if account.id.rawValue == "unknown" { throw SecretError() }
    let activity = AccountTokenActivity(
      lifetimeTokens: 123, peakDailyTokens: nil, longestRunningTurnSec: nil,
      currentStreakDays: nil, longestStreakDays: nil, dailyUsageBuckets: nil)
    return [account.id: AccountQuotaSnapshot(planName: "Pro", usage: AccountUsage(
      weekly: UsageWindow(usedPercent: 25, resetAt: Date(timeIntervalSince1970: 200)),
      resetCredits: .init(availableCount: 2, credits: [.init(expiresAt: nil)]),
      tokenActivity: account.id.rawValue == "partial" ? nil : activity,
      tokenActivityWasLoaded: account.id.rawValue != "partial"))]
  }
}
