import XCTest
@testable import SwitchGPTAppCore

final class AllAccountsTokenActivityTests: XCTestCase {
  func testSumsEveryMetricAndDailyRecordsAcrossAccounts() {
    let first = account("first", activity: activity(100, peak: 70, seconds: 60, current: 2, longest: 4,
      days: [.init(startDate: "2026-10-08", tokens: 20),
        .init(startDate: "2026-10-09", tokens: 50)]))
    let second = account("second", activity: activity(200, peak: 80, seconds: 120, current: 3, longest: 5,
      days: [.init(startDate: "2026-10-07", tokens: 0),
        .init(startDate: "2026-10-08", tokens: 30)]))
    let summary = AllAccountsTokenActivity(accounts: [first, second])
    XCTAssertEqual(summary.activity, activity(300, peak: 150, seconds: 180, current: 5, longest: 9,
      days: [.init(startDate: "2026-10-07", tokens: 0),
        .init(startDate: "2026-10-08", tokens: 50),
        .init(startDate: "2026-10-09", tokens: 50)]))
    XCTAssertEqual(summary.contributingAccountCount, 2)
    XCTAssertFalse(summary.hasMissingData)
  }

  func testExcludesFailedAccountsEvenWhenTheyHaveOldSnapshots() {
    let healthy = account("healthy", activity: activity(100))
    let failed = account("failed", activity: activity(9_000))
    let summary = AllAccountsTokenActivity(accounts: [healthy, failed], excluding: [failed.id])
    XCTAssertEqual(summary.activity?.lifetimeTokens, 100)
    XCTAssertEqual(summary.eligibleAccountCount, 1)
    XCTAssertEqual(summary.excludedAccountCount, 1)
    XCTAssertEqual(summary.contributingAccountCount, 1)
  }

  func testUnknownValuesStayUnknownAndPartialDataIsIdentified() {
    let partial = account("partial", activity: activity(0))
    let missing = account("missing", activity: nil)
    let summary = AllAccountsTokenActivity(accounts: [partial, missing])
    XCTAssertEqual(summary.activity?.lifetimeTokens, 0)
    XCTAssertNil(summary.activity?.peakDailyTokens)
    XCTAssertNil(summary.activity?.dailyUsageBuckets)
    XCTAssertEqual(summary.eligibleAccountCount, 2)
    XCTAssertEqual(summary.contributingAccountCount, 1)
    XCTAssertTrue(summary.hasMissingData)
    XCTAssertNil(AllAccountsTokenActivity(accounts: [missing]).activity)
    XCTAssertNil(AllAccountsTokenActivity(accounts: []).activity)
    XCTAssertNil(AllAccountsTokenActivity(accounts: [partial], excluding: [partial.id]).activity)
  }

  func testDuplicateDateWithinOneAccountUsesLatestValueBeforeSummingAccounts() {
    let first = account("first", activity: activity(100, days: [
      .init(startDate: "2026-10-09", tokens: 10),
      .init(startDate: "2026-10-09", tokens: 20)]))
    let second = account("second", activity: activity(100, days: [
      .init(startDate: "2026-10-09", tokens: 30)]))
    XCTAssertEqual(AllAccountsTokenActivity(accounts: [first, second]).activity?.dailyUsageBuckets,
      [.init(startDate: "2026-10-09", tokens: 50)])
    let emptyDays = account("empty", activity: activity(0, days: []))
    XCTAssertEqual(AllAccountsTokenActivity(accounts: [emptyDays]).activity?.dailyUsageBuckets, [])
  }

  @MainActor
  func testSummaryNeverFetchesAndFollowsBothExistingRefreshPathsAndRemoval() async {
    let first = account("first", activity: activity(10))
    let second = account("second", activity: activity(20))
    let reader = SummaryTestReader()
    let store = SwitchGPTAppStore(quotaReader: reader, initialAccounts: [first, second])
    XCTAssertEqual(store.allAccountsTokenActivity.activity?.lifetimeTokens, 30)
    XCTAssertEqual(store.allAccountsTokenActivity.activity?.lifetimeTokens, 30)
    let initialCalls = await reader.calls
    XCTAssertEqual(initialCalls, 0)

    await reader.set(snapshots: [first.id: snapshot(100), second.id: snapshot(200)])
    await store.refresh()
    XCTAssertEqual(store.allAccountsTokenActivity.activity?.lifetimeTokens, 300)
    let refreshedCalls = await reader.calls
    XCTAssertEqual(refreshedCalls, 1)

    await reader.set(snapshots: [first.id: snapshot(150)])
    await store.refresh()
    XCTAssertEqual(store.accounts[1].usage.tokenActivity?.lifetimeTokens, 200)
    XCTAssertEqual(store.allAccountsTokenActivity.activity?.lifetimeTokens, 150)
    XCTAssertEqual(store.allAccountsTokenActivity.excludedAccountCount, 1)

    await reader.set(snapshots: [second.id: snapshot(250)])
    let refreshed = await store.refreshAccount(second.id)
    XCTAssertTrue(refreshed)
    XCTAssertEqual(store.allAccountsTokenActivity.activity?.lifetimeTokens, 400)
    XCTAssertEqual(store.allAccountsTokenActivity.excludedAccountCount, 0)
    store.removeMockAccount(second.id)
    XCTAssertEqual(store.allAccountsTokenActivity.activity?.lifetimeTokens, 150)
    let finalCalls = await reader.calls
    _ = store.allAccountsTokenActivity
    let afterReadCalls = await reader.calls
    XCTAssertEqual(afterReadCalls, finalCalls)
  }

  private func activity(_ lifetime: Int?, peak: Int? = nil, seconds: Int? = nil,
    current: Int? = nil, longest: Int? = nil, days: [AccountTokenActivity.DailyBucket]? = nil
  ) -> AccountTokenActivity {
    .init(lifetimeTokens: lifetime, peakDailyTokens: peak, longestRunningTurnSec: seconds,
      currentStreakDays: current, longestStreakDays: longest, dailyUsageBuckets: days)
  }

  private func account(_ id: String, activity: AccountTokenActivity?) -> AccountRecord {
    .init(id: AccountID(id), displayName: id, detail: "", planName: "Plus",
      symbolName: "person", accent: .blue,
      usage: .init(weekly: .init(usedPercent: 10, resetAt: Date()), tokenActivity: activity))
  }

  private func snapshot(_ tokens: Int) -> AccountQuotaSnapshot {
    .init(planName: "Plus", usage: account("fixture", activity: activity(tokens)).usage)
  }
}

private actor SummaryTestReader: QuotaReading {
  private(set) var calls = 0
  private var snapshots: [AccountID: AccountQuotaSnapshot] = [:]
  func set(snapshots: [AccountID: AccountQuotaSnapshot]) { self.snapshots = snapshots }
  func fetchSnapshots(for accounts: [AccountRecord]) async throws -> [AccountID: AccountQuotaSnapshot] {
    calls += 1
    return snapshots.filter { key, _ in accounts.contains { $0.id == key } }
  }
}
