import Foundation
@testable import SwitchGPTAppCore
import XCTest

final class QuotaTimelineSnapshotTests: XCTestCase {
  private let recent = Date(timeIntervalSince1970: 1_795_703_400)
  private let older = Date(timeIntervalSince1970: 1_795_702_800)

  func testOnlyPro100And200PlansArePlotted() {
    let snapshot = QuotaTimelineSnapshot(
      accounts: [
        account("one", plan: "Pro", refreshedAt: older),
        account("two", plan: "Pro Lite", refreshedAt: recent),
        account("three", plan: " ChatGPT Pro 200 "),
        account("four", plan: "ChatGPT Pro 100"),
        account("five", plan: "Plus", refreshedAt: recent.addingTimeInterval(60)),
        account("six", plan: "Free"),
        account("seven", plan: "Pro 500"),
      ],
      failedAccountIDs: [],
      lastRefreshedAt: older,
      language: "zh-Hans"
    )

    XCTAssertEqual(snapshot.accounts.map(\.name), ["one", "two", "three", "four"])
    XCTAssertEqual(snapshot.accounts.map(\.plan), ["Pro 200", "Pro 100", "Pro 200", "Pro 100"])
    XCTAssertEqual(snapshot.asOf, recent)
    XCTAssertEqual(snapshot.language, "zh-Hans")
  }

  func testRowIdentitySurvivesDisplayAndUsageChanges() throws {
    let first = account("before", id: "stable", plan: "Pro", refreshedAt: older)
    let updated = account(
      "after", id: "stable", email: "updated@example.test", plan: "Pro",
      refreshedAt: recent, usedPercent: 42
    )
    let distinct = account(
      "after", id: "distinct", email: "updated@example.test", plan: "Pro",
      refreshedAt: recent, usedPercent: 42
    )
    let initial = QuotaTimelineSnapshot(
      accounts: [first], failedAccountIDs: [], lastRefreshedAt: older, language: "zh-Hans"
    )
    let refreshed = QuotaTimelineSnapshot(
      accounts: [distinct, updated], failedAccountIDs: [], lastRefreshedAt: recent,
      language: "en", canRefresh: true
    )

    let originalID = try XCTUnwrap(initial.accounts.first?.id)
    XCTAssertNotNil(originalID.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
    XCTAssertEqual(refreshed.accounts.last?.id, originalID)
    XCTAssertNotEqual(refreshed.accounts.first?.id, originalID)
    XCTAssertEqual(refreshed.accounts.last?.name, "updated@example.test")
    XCTAssertEqual(refreshed.accounts.last?.remaining, 58)
    XCTAssertTrue(refreshed.canRefresh)
    XCTAssertFalse(refreshed.refreshing)
  }

  func testPartialRefreshKeepsLastSuccessfulQuotaAndSeparatesCardCountFromDates() {
    let expiry = recent.addingTimeInterval(3_600)
    let laterExpiry = expiry.addingTimeInterval(3_600)
    let account = account(
      "stale",
      plan: "Pro 100",
      refreshedAt: older,
      resetCredits: RateLimitResetCreditsSummary(
        availableCount: 4,
        credits: [
          RateLimitResetCredit(expiresAt: laterExpiry),
          RateLimitResetCredit(expiresAt: nil),
          RateLimitResetCredit(expiresAt: expiry),
        ]
      )
    )
    let snapshot = QuotaTimelineSnapshot(
      accounts: [account],
      failedAccountIDs: [account.id],
      lastRefreshedAt: older,
      language: "en"
    )

    XCTAssertEqual(snapshot.accounts.first?.remaining, 17)
    XCTAssertEqual(snapshot.accounts.first?.resetAt, recent)
    XCTAssertEqual(snapshot.accounts.first?.refreshedAt, older)
    XCTAssertEqual(snapshot.accounts.first?.failed, true)
    XCTAssertEqual(snapshot.accounts.first?.cardCount, 4)
    XCTAssertEqual(snapshot.accounts.first?.cards, [expiry, laterExpiry])
  }

  func testUnrefreshedAccountsHaveNoSyntheticQuotaOrPrivateAccountMetadata() throws {
    let account = account("unread", plan: "Pro 100")
    let snapshot = QuotaTimelineSnapshot(
      accounts: [account],
      failedAccountIDs: [account.id],
      lastRefreshedAt: nil,
      language: "en",
      refreshing: true,
      canRefresh: false,
      now: recent
    )
    XCTAssertEqual(snapshot.asOf, recent)
    XCTAssertEqual(snapshot.accounts.count, 1)
    XCTAssertNil(snapshot.accounts.first?.remaining)
    XCTAssertNil(snapshot.accounts.first?.resetAt)
    XCTAssertNil(snapshot.accounts.first?.cardCount)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = .withoutEscapingSlashes
    let data = try encoder.encode(snapshot)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let rows = try XCTUnwrap(object["accounts"] as? [[String: Any]])
    let row = try XCTUnwrap(rows.first)
    XCTAssertEqual(Set(row.keys), ["id", "name", "plan", "cards", "failed"])
    XCTAssertEqual(row["id"] as? String, snapshot.accounts.first?.id)
    XCTAssertEqual(object["asOf"] as? String, ISO8601DateFormatter().string(from: recent))
    XCTAssertEqual(object["refreshing"] as? Bool, true)
    XCTAssertEqual(object["canRefresh"] as? Bool, false)

    let serialized = String(decoding: data, as: UTF8.self)
    XCTAssertFalse(serialized.contains("private-id-"))
    XCTAssertFalse(serialized.contains("/private/example"))
    XCTAssertFalse(serialized.contains("private-hash"))
    XCTAssertFalse(serialized.contains("private detail"))
  }

  private func account(
    _ name: String,
    id: String? = nil,
    email: String? = nil,
    plan: String,
    refreshedAt: Date? = nil,
    resetCredits: RateLimitResetCreditsSummary? = nil,
    usedPercent: Int = 83
  ) -> AccountRecord {
    AccountRecord(
      id: AccountID("private-id-" + (id ?? name)),
      displayName: name,
      email: email,
      detail: "private detail",
      planName: plan,
      symbolName: "person",
      accent: .blue,
      usage: AccountUsage(
        weekly: UsageWindow(usedPercent: usedPercent, resetAt: recent),
        resetCredits: resetCredits
      ),
      source: .codexHome(path: "/private/example"),
      identityHash: "private-hash",
      usageRefreshedAt: refreshedAt
    )
  }
}
