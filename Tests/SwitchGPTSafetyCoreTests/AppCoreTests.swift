import XCTest

@testable import SwitchGPTAppCore

final class AppCoreTests: XCTestCase {
  func testRealSwitchReceiptStorePersistsMetadataOnlyEvidenceWithoutOverwrite() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("switchgpt-receipt-store-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let store = RealSwitchReceiptStore(
      directoryURL: root.appendingPathComponent("SwitchReceipts", isDirectory: true)
    )
    let id = UUID()
    let receipt = RealSwitchReceipt(
      id: id,
      sourceIdentityHash: "012345abcdef",
      targetIdentityHash: "fedcba543210",
      outcome: .rolledBack,
      finalIdentityHash: "012345abcdef",
      targetLaunchAttempts: 1,
      rollbackLaunchAttempts: 1,
      targetWasInstalled: true,
      failureReason: .targetIdentityMismatch,
      transactionCreatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      recordedAt: Date(timeIntervalSince1970: 1_700_000_010)
    )

    let receiptURL = try store.save(receipt)

    XCTAssertEqual(try store.load(id: id), receipt)
    let attributes = try FileManager.default.attributesOfItem(atPath: receiptURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    let persistedText = try String(contentsOf: receiptURL, encoding: .utf8)
    XCTAssertFalse(persistedText.contains("access_token"))
    XCTAssertFalse(persistedText.contains("refresh_token"))
    XCTAssertFalse(persistedText.contains("auth.json"))
    XCTAssertThrowsError(try store.save(receipt)) { error in
      XCTAssertEqual(error as? RealSwitchReceiptStoreError, .receiptAlreadyExists)
    }
  }

  func testRealSwitchReceiptStoreRejectsInvalidIdentityMetadata() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("switchgpt-invalid-receipt-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RealSwitchReceiptStore(directoryURL: root)
    let receipt = RealSwitchReceipt(
      id: UUID(),
      sourceIdentityHash: "not-a-hash",
      targetIdentityHash: "fedcba543210",
      outcome: .committed,
      finalIdentityHash: "fedcba543210",
      targetLaunchAttempts: 1,
      rollbackLaunchAttempts: 0,
      targetWasInstalled: true,
      failureReason: nil,
      transactionCreatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      recordedAt: Date(timeIntervalSince1970: 1_700_000_001)
    )

    XCTAssertThrowsError(try store.save(receipt)) { error in
      XCTAssertEqual(error as? RealSwitchReceiptStoreError, .invalidReceipt)
    }
  }

  func testMockReaderReturnsUsageForEveryAccount() async throws {
    let accounts = MockAccountCatalog.accounts(now: Date(timeIntervalSince1970: 1_700_000_000))
    let usage = try await MockQuotaReader().fetchUsage(for: accounts)

    XCTAssertEqual(usage.count, accounts.count)
    XCTAssertNotNil(usage[AccountID("personal")])
    XCTAssertNil(usage[AccountID("personal")]?.fiveHour)
    XCTAssertNil(usage[AccountID("work")]?.fiveHour)
  }

  func testCodexQuotaReaderKeepsHealthyAccountWhenAnotherAccountFails() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("switchgpt-partial-quota-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )

    let binaryURL = root.appendingPathComponent("fake-codex")
    let script = #"""
      #!/bin/bash
      marker="$(cat "$CODEX_HOME/auth.json")"
      request_count=0
      while IFS= read -r line; do
        if [[ "$line" != *'"id":'* ]]; then
          continue
        fi
        request_count=$((request_count + 1))
        request_id="$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')"
        if [[ "$request_count" -eq 1 ]]; then
          printf '{"id":%s,"result":{}}\n' "$request_id"
        elif [[ "$request_count" -eq 2 ]]; then
          if [[ "$marker" == *failure* ]]; then
            if [[ "$marker" == *usage-failure* ]]; then
              email="usage-failure@example.com"
            else
              email="failure@example.com"
            fi
          else
            email="success@example.com"
          fi
          printf '{"id":%s,"result":{"account":{"email":"%s","planType":"plus"}}}\n' "$request_id" "$email"
        elif [[ "$request_count" -eq 3 ]]; then
          if [[ "$marker" == failure ]]; then
            printf '{"id":%s,"error":{"code":-32603,"message":"expired"}}\n' "$request_id"
          else
            printf '{"id":%s,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1900000000},"secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1900500000}}}}\n' "$request_id"
          fi
        elif [[ "$request_count" -eq 4 ]]; then
          if [[ "$marker" == *usage-failure* ]]; then
            printf '{"id":%s,"error":{"code":-32601,"message":"method unavailable"}}\n' "$request_id"
          else
            printf '{"id":%s,"result":{"summary":{"lifetimeTokens":1234567,"peakDailyTokens":45678,"longestRunningTurnSec":540,"currentStreakDays":8,"longestStreakDays":14},"dailyUsageBuckets":[{"startDate":"2026-06-18","tokens":12345}]}}\n' "$request_id"
          fi
        fi
      done
      """#
    try Data(script.utf8).write(to: binaryURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binaryURL.path)

    func account(
      id: String,
      marker: String,
      identityHash: String
    ) throws -> AccountRecord {
      let home = root.appendingPathComponent(id, isDirectory: true)
      try FileManager.default.createDirectory(
        at: home,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      let authURL = home.appendingPathComponent("auth.json")
      try Data(marker.utf8).write(to: authURL)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
      return AccountRecord(
        id: AccountID(id),
        displayName: id,
        detail: "",
        planName: "Plus",
        symbolName: "person.crop.circle",
        accent: .orange,
        usage: AccountUsage(
          weekly: UsageWindow(usedPercent: 1, resetAt: Date(timeIntervalSince1970: 1_800_000_000))
        ),
        source: .codexHome(path: home.path),
        identityHash: identityHash
      )
    }

    let healthy = try account(
      id: "healthy",
      marker: "success",
      identityHash: "f562576f3ed3"
    )
    let expired = try account(
      id: "expired",
      marker: "failure",
      identityHash: "965888cf8e95"
    )
    let usageUnavailableIdentity = try CodexAccountDecoder.decode(
      from: Data(#"{"account":{"email":"usage-failure@example.com","planType":"plus"}}"#.utf8)
    ).identityHash
    let usageUnavailable = try account(
      id: "usage-unavailable",
      marker: "usage-failure",
      identityHash: usageUnavailableIdentity
    )
    let snapshots = try await CodexAppServerQuotaReader(
      codexBinaryURL: binaryURL,
      timeout: .seconds(2)
    ).fetchSnapshots(for: [healthy, expired, usageUnavailable])

    XCTAssertEqual(Set(snapshots.keys), [healthy.id, usageUnavailable.id])
    XCTAssertEqual(snapshots[healthy.id]?.usage.fiveHour?.usedPercent, 12)
    XCTAssertEqual(snapshots[healthy.id]?.usage.weekly.usedPercent, 34)
    XCTAssertEqual(snapshots[healthy.id]?.usage.tokenActivity?.lifetimeTokens, 1_234_567)
    XCTAssertEqual(
      snapshots[healthy.id]?.usage.tokenActivity?.dailyUsageBuckets?.first?.tokens,
      12_345
    )
    XCTAssertEqual(snapshots[healthy.id]?.usage.tokenActivityWasLoaded, true)
    XCTAssertEqual(snapshots[usageUnavailable.id]?.usage.weekly.usedPercent, 34)
    XCTAssertNil(snapshots[usageUnavailable.id]?.usage.tokenActivity)
    XCTAssertEqual(snapshots[usageUnavailable.id]?.usage.tokenActivityWasLoaded, false)
  }

  func testTokenActivityDecoderPreservesUnknownFields() throws {
    let data = Data(
      #"""
      {
        "summary": {
          "lifetimeTokens": null,
          "peakDailyTokens": 100,
          "longestRunningTurnSec": null,
          "currentStreakDays": 2,
          "longestStreakDays": 4
        },
        "dailyUsageBuckets": null
      }
      """#.utf8
    )
    let activity = try CodexTokenActivityDecoder.decode(from: data)
    XCTAssertNil(activity.lifetimeTokens)
    XCTAssertEqual(activity.peakDailyTokens, 100)
    XCTAssertNil(activity.dailyUsageBuckets)
  }

  @MainActor
  func testSimulationChangesOnlySelectedInMemoryAccount() async {
    let store = SwitchGPTAppStore(now: Date(timeIntervalSince1970: 1_700_000_000))
    let originalID = store.currentAccountID

    await store.simulateSwitch(to: AccountID("work"))

    XCTAssertEqual(originalID, AccountID("personal"))
    XCTAssertEqual(store.currentAccountID, AccountID("work"))
    XCTAssertEqual(store.activity.message, "Simulation complete — no desktop account changed")
  }

  @MainActor
  func testRefreshKeepsCurrentIdentity() async {
    let store = SwitchGPTAppStore(now: Date(timeIntervalSince1970: 1_700_000_000))
    await store.refresh()

    XCTAssertEqual(store.currentAccountID, AccountID("personal"))
    XCTAssertNotNil(store.lastRefreshedAt)
    XCTAssertEqual(store.accounts.count, 2)
    XCTAssertFalse(store.activity.isFailure)
  }

  @MainActor
  func testRefreshKeepsSuccessfulAccountsWhenOneAccountFails() async throws {
    var initialAccounts = MockAccountCatalog.accounts(
      now: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let previousRefresh = Date(timeIntervalSince1970: 1_700_000_100)
    initialAccounts[1].usageRefreshedAt = previousRefresh
    let originalFailedUsage = initialAccounts[1].usage
    let refreshedUsage = AccountUsage(
      weekly: UsageWindow(usedPercent: 88, resetAt: Date(timeIntervalSince1970: 1_900_000_000))
    )
    let persistence = InMemoryPreviewStateStore(state: nil)
    let store = SwitchGPTAppStore(
      quotaReader: SelectivelyFailingQuotaReader(
        successfulAccountID: initialAccounts[0].id,
        snapshot: AccountQuotaSnapshot(planName: "Plus", usage: refreshedUsage)
      ),
      persistence: persistence,
      initialAccounts: initialAccounts
    )

    await store.refresh()

    XCTAssertEqual(store.accounts[0].usage, refreshedUsage)
    XCTAssertNotNil(store.accounts[0].usageRefreshedAt)
    XCTAssertEqual(store.accounts[1].usage, originalFailedUsage)
    XCTAssertEqual(store.accounts[1].usageRefreshedAt, previousRefresh)
    XCTAssertEqual(store.quotaRefreshFailedAccountIDs, [initialAccounts[1].id])
    XCTAssertNil(store.lastRefreshedAt)
    XCTAssertEqual(
      store.activity,
      .partial(message: "Updated 1 of 2 accounts. 1 account kept previous usage.")
    )
    XCTAssertEqual(try persistence.load()?.accounts, store.accounts)
  }

  @MainActor
  func testRefreshReportsFailureWhenEveryAccountFails() async {
    let initialAccounts = MockAccountCatalog.accounts(
      now: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let store = SwitchGPTAppStore(
      quotaReader: SelectivelyFailingQuotaReader(successfulAccountID: nil, snapshot: nil),
      initialAccounts: initialAccounts
    )

    await store.refresh()

    XCTAssertEqual(store.accounts, initialAccounts)
    XCTAssertEqual(store.quotaRefreshFailedAccountIDs, Set(initialAccounts.map(\.id)))
    XCTAssertNil(store.lastRefreshedAt)
    XCTAssertEqual(store.activity, .failure(message: "Could not refresh usage"))
  }

  @MainActor
  func testTargetedRefreshUpdatesOnlySelectedAccountBeforeSwitching() async {
    let refreshedUsage = AccountUsage(
      weekly: UsageWindow(usedPercent: 88, resetAt: Date(timeIntervalSince1970: 1_900_000_000))
    )
    let store = SwitchGPTAppStore(
      quotaReader: FixedSnapshotQuotaReader(
        snapshot: AccountQuotaSnapshot(planName: "Free", usage: refreshedUsage)
      ),
      now: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let originalCurrentID = store.currentAccountID
    let untouchedUsage = store.accounts[0].usage

    let refreshed = await store.refreshAccount(AccountID("work"))

    XCTAssertTrue(refreshed)
    XCTAssertEqual(store.currentAccountID, originalCurrentID)
    XCTAssertEqual(store.accounts.first { $0.id == AccountID("personal") }?.usage, untouchedUsage)
    XCTAssertEqual(store.accounts.first { $0.id == AccountID("work") }?.usage, refreshedUsage)
    XCTAssertEqual(store.accounts.first { $0.id == AccountID("work") }?.planName, "Free")
    XCTAssertNotNil(store.accounts.first { $0.id == AccountID("work") }?.usageRefreshedAt)
    XCTAssertNil(store.accounts.first { $0.id == AccountID("personal") }?.usageRefreshedAt)
  }

  @MainActor
  func testAccountListPreferencesPersistIndependentFieldAndAccountOrder() {
    let suiteName = "switchgpt-list-settings-" + UUID().uuidString
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Expected isolated defaults")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let accounts = MockAccountCatalog.accounts()
    let preferences = AccountListPreferences(userDefaults: defaults)

    preferences.moveField(.lastUpdated, relativeTo: .plan, after: false, on: .menu)
    preferences.setVisible(false, field: .plan, on: .menu)
    preferences.moveAccount(accounts[1].id, relativeTo: accounts[0].id, after: false,
                            accounts: accounts, on: .menu)
    preferences.setDensity(.compact, on: .menu)

    let restored = AccountListPreferences(userDefaults: defaults)
    XCTAssertEqual(restored.menu.orderedVisibleFields.first, .lastUpdated)
    XCTAssertFalse(restored.menu.visibleFields.contains(.plan))
    XCTAssertEqual(restored.menu.orderedAccounts(accounts).map(\.id), [accounts[1].id, accounts[0].id])
    XCTAssertEqual(restored.menu.density, .compact)
    XCTAssertEqual(restored.sidebar, .standard)
  }

  @MainActor
  func testResetTimeFormatUsesChosenStyleAndLocalTimeZone() throws {
    let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-06T07:00:00Z"))
    let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))

    XCTAssertEqual(
      ResetTimeFormat.chinese.text(for: date, timeZone: shanghai),
      "重置时间：2026年9月6日15:00"
    )
    XCTAssertEqual(
      ResetTimeFormat.english.text(for: date, timeZone: shanghai),
      "Reset at 2026 Sep 6 15:00"
    )
    XCTAssertEqual(
      ResetTimeFormat.compact.text(for: date, timeZone: shanghai),
      "2026 0906 15:00"
    )
  }

  @MainActor
  func testResetTimePreferenceDefaultsToChineseAndPersists() {
    let suiteName = "switchgpt-reset-time-" + UUID().uuidString
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Expected isolated defaults")
      return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let preferences = ResetTimePreferences(userDefaults: defaults)
    XCTAssertEqual(preferences.format, .chinese)

    preferences.setFormat(.compact)
    XCTAssertEqual(ResetTimePreferences(userDefaults: defaults).format, .compact)
  }

  @MainActor
  func testRefreshIfStaleSkipsFreshDataAndRefreshesExpiredData() async {
    let reader = CountingQuotaReader()
    let store = SwitchGPTAppStore(quotaReader: reader)
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    await store.refreshIfStale(maxAge: 10, now: base)
    var refreshCount = await reader.count
    XCTAssertEqual(refreshCount, 1)

    guard let refreshed = store.lastRefreshedAt else {
      XCTFail("Expected refresh timestamp")
      return
    }
    await store.refreshIfStale(maxAge: 10, now: refreshed.addingTimeInterval(9))
    refreshCount = await reader.count
    XCTAssertEqual(refreshCount, 1)

    await store.refreshIfStale(maxAge: 10, now: refreshed.addingTimeInterval(10))
    refreshCount = await reader.count
    XCTAssertEqual(refreshCount, 2)
  }

  @MainActor
  func testStoreSupportsMoreThanTwoAccounts() async {
    let store = SwitchGPTAppStore(now: Date(timeIntervalSince1970: 1_700_000_000))
    let addedID = store.addMockAccount(displayName: "Research", detail: "Reading workspace")

    XCTAssertNotNil(addedID)
    XCTAssertEqual(store.accounts.count, 3)

    guard let addedID else {
      return
    }

    await store.simulateSwitch(to: addedID)
    XCTAssertEqual(store.currentAccountID, addedID)

    store.removeMockAccount(AccountID("personal"))
    XCTAssertEqual(store.accounts.count, 2)
    XCTAssertEqual(store.currentAccountID, addedID)
  }

  func testRateLimitDecoderFallsBackToLegacyWindowOrderWithoutDurations() throws {
    let payload = """
      {
        "rateLimitsByLimitId": {
          "codex": {
            "primary": {"usedPercent": 37, "resetsAt": 1787059702},
            "secondary": {"usedPercent": 12, "resetsAt": 1787000000000}
          }
        }
      }
      """.data(using: .utf8)!

    let usage = try CodexRateLimitDecoder.decodeUsage(from: payload)

    XCTAssertEqual(usage.weekly.usedPercent, 37)
    XCTAssertEqual(usage.fiveHour?.usedPercent, 12)
    XCTAssertNil(usage.credits)
    XCTAssertTrue(usage.creditsWereLoaded)
    XCTAssertNil(usage.resetCredits)
    XCTAssertTrue(usage.resetCreditsWereLoaded)
    XCTAssertEqual(usage.weekly.resetAt.timeIntervalSince1970, 1_787_059_702, accuracy: 0.1)
    XCTAssertEqual(usage.fiveHour?.resetAt.timeIntervalSince1970 ?? 0, 1_787_000_000, accuracy: 0.1)
  }

  func testRateLimitDecoderUsesDurationWhenPrimaryIsFiveHourWindow() throws {
    let payload = """
      {
        "rateLimitsByLimitId": {
          "codex": {
            "primary": {
              "usedPercent": 1,
              "resetsAt": 1787000000,
              "windowDurationMins": 300
            },
            "secondary": {
              "usedPercent": 0,
              "resetsAt": 1787059702,
              "windowDurationMins": 10080
            }
          }
        }
      }
      """.data(using: .utf8)!

    let usage = try CodexRateLimitDecoder.decodeUsage(from: payload)

    XCTAssertEqual(usage.fiveHour?.remainingPercent, 99)
    XCTAssertEqual(usage.weekly.remainingPercent, 100)
    XCTAssertEqual(usage.fiveHour?.resetAt.timeIntervalSince1970 ?? 0, 1_787_000_000, accuracy: 0.1)
    XCTAssertEqual(usage.weekly.resetAt.timeIntervalSince1970, 1_787_059_702, accuracy: 0.1)
  }

  func testRateLimitDecoderPreservesResetCreditCountAndGroupsAvailableDetails() throws {
    let payload = """
      {
        "rateLimits": {
          "primary": {"usedPercent": 42, "resetsAt": 1787059702}
        },
        "rateLimitResetCredits": {
          "availableCount": 5,
          "credits": [
            {
              "id": "opaque-credit-a",
              "status": "available",
              "resetType": "codexRateLimits",
              "grantedAt": 1780000000,
              "expiresAt": 1789000000
            },
            {
              "id": "opaque-credit-b",
              "status": "available",
              "resetType": "codexRateLimits",
              "grantedAt": 1780000001,
              "expiresAt": 1789000000
            },
            {
              "id": "opaque-credit-c",
              "status": "available",
              "resetType": "codexRateLimits",
              "grantedAt": 1780000002,
              "expiresAt": 1790000000
            },
            {
              "id": "opaque-credit-d",
              "status": "available",
              "resetType": "codexRateLimits",
              "grantedAt": 1780000003,
              "expiresAt": null
            },
            {
              "id": "opaque-credit-e",
              "status": "redeemed",
              "resetType": "codexRateLimits",
              "grantedAt": 1780000004,
              "expiresAt": 1788000000
            }
          ]
        }
      }
      """.data(using: .utf8)!

    let usage = try CodexRateLimitDecoder.decodeUsage(from: payload)
    let summary = try XCTUnwrap(usage.resetCredits)

    XCTAssertTrue(usage.resetCreditsWereLoaded)
    XCTAssertEqual(summary.availableCount, 5)
    XCTAssertEqual(summary.knownDetailCount, 4)
    XCTAssertEqual(summary.missingDetailCount, 1)
    XCTAssertFalse(summary.detailsAreComplete)
    XCTAssertEqual(summary.nearestKnownExpiry?.timeIntervalSince1970, 1_789_000_000)
    XCTAssertEqual(
      summary.expirationGroups,
      [
        RateLimitResetCreditExpirationGroup(
          expiresAt: Date(timeIntervalSince1970: 1_789_000_000),
          count: 2
        ),
        RateLimitResetCreditExpirationGroup(
          expiresAt: Date(timeIntervalSince1970: 1_790_000_000),
          count: 1
        ),
        RateLimitResetCreditExpirationGroup(expiresAt: nil, count: 1),
      ]
    )

    let persisted = try JSONEncoder().encode(usage)
    let persistedText = try XCTUnwrap(String(data: persisted, encoding: .utf8))
    XCTAssertFalse(persistedText.contains("opaque-credit"))
  }

  func testRateLimitDecoderDistinguishesCountOnlyResetCreditsFromZeroDetails() throws {
    let countOnlyPayload = """
      {
        "rateLimits": {
          "primary": {"usedPercent": 42, "resetsAt": 1787059702}
        },
        "rateLimitResetCredits": {
          "availableCount": 7,
          "credits": null
        }
      }
      """.data(using: .utf8)!
    let zeroPayload = """
      {
        "rateLimits": {
          "primary": {"usedPercent": 42, "resetsAt": 1787059702}
        },
        "rateLimitResetCredits": {
          "availableCount": 0,
          "credits": []
        }
      }
      """.data(using: .utf8)!

    let countOnly = try XCTUnwrap(
      CodexRateLimitDecoder.decodeUsage(from: countOnlyPayload).resetCredits
    )
    let zero = try XCTUnwrap(CodexRateLimitDecoder.decodeUsage(from: zeroPayload).resetCredits)

    XCTAssertEqual(countOnly.availableCount, 7)
    XCTAssertNil(countOnly.credits)
    XCTAssertEqual(countOnly.missingDetailCount, 7)
    XCTAssertFalse(countOnly.detailsAreComplete)
    XCTAssertEqual(zero.availableCount, 0)
    XCTAssertEqual(zero.credits, [])
    XCTAssertTrue(zero.detailsAreComplete)
  }

  func testMalformedOptionalResetCreditsDoNotDiscardValidUsage() throws {
    let payload = """
      {
        "rateLimits": {
          "primary": {"usedPercent": 42, "resetsAt": 1787059702}
        },
        "rateLimitResetCredits": {
          "availableCount": "unknown",
          "credits": []
        }
      }
      """.data(using: .utf8)!

    let usage = try CodexRateLimitDecoder.decodeUsage(from: payload)

    XCTAssertEqual(usage.weekly.usedPercent, 42)
    XCTAssertNil(usage.resetCredits)
    XCTAssertTrue(usage.resetCreditsWereLoaded)
  }

  func testRateLimitDecoderPreservesCreditsPointsAndConvertsToUSD() throws {
    let payload = """
      {
        "rateLimitsByLimitId": {
          "codex": {
            "primary": {"usedPercent": 100, "resetsAt": 1787059702},
            "credits": {
              "hasCredits": true,
              "unlimited": false,
              "balance": "800.0000000000"
            }
          }
        }
      }
      """.data(using: .utf8)!

    let usage = try CodexRateLimitDecoder.decodeUsage(from: payload)

    XCTAssertEqual(usage.weekly.usedPercent, 100)
    XCTAssertEqual(usage.credits?.hasCredits, true)
    XCTAssertEqual(usage.credits?.unlimited, false)
    XCTAssertEqual(usage.credits?.points, Decimal(800))
    XCTAssertEqual(usage.credits?.usdBalance, Decimal(32))
    XCTAssertTrue(usage.creditsWereLoaded)
  }

  func testRateLimitDecoderSupportsUnlimitedCreditsWithoutBalance() throws {
    let payload = """
      {
        "rateLimits": {
          "primary": {"usedPercent": 100, "resetsAt": 1787059702},
          "credits": {
            "hasCredits": true,
            "unlimited": true,
            "balance": null
          }
        }
      }
      """.data(using: .utf8)!

    let usage = try CodexRateLimitDecoder.decodeUsage(from: payload)

    XCTAssertEqual(usage.credits, CreditBalance(hasCredits: true, unlimited: true))
    XCTAssertEqual(usage.credits?.isDisplayable, true)
    XCTAssertTrue(usage.creditsWereLoaded)
  }

  func testCreditBalanceDecodesPreviouslyPersistedBalanceAsPoints() throws {
    let payload = """
      {
        "hasCredits": true,
        "unlimited": false,
        "balance": 800
      }
      """.data(using: .utf8)!

    let credits = try JSONDecoder().decode(CreditBalance.self, from: payload)
    let encoded = try JSONEncoder().encode(credits)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    XCTAssertEqual(credits.points, Decimal(800))
    XCTAssertEqual(credits.usdBalance, Decimal(32))
    XCTAssertNotNil(object["points"])
    XCTAssertNil(object["balance"])
  }

  func testAccountUsageDecodesLegacyStateWithoutCreditsOrResetCredits() throws {
    let original = AccountUsage(
      weekly: UsageWindow(usedPercent: 37, resetAt: Date(timeIntervalSince1970: 1_787_059_702))
    )
    let encoded = try JSONEncoder().encode(original)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "credits")
    object.removeValue(forKey: "creditsWereLoaded")
    object.removeValue(forKey: "resetCredits")
    object.removeValue(forKey: "resetCreditsWereLoaded")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(AccountUsage.self, from: legacyData)

    XCTAssertEqual(decoded.weekly, original.weekly)
    XCTAssertNil(decoded.credits)
    XCTAssertFalse(decoded.creditsWereLoaded)
    XCTAssertNil(decoded.resetCredits)
    XCTAssertFalse(decoded.resetCreditsWereLoaded)
  }

  func testRateLimitDecoderRejectsMissingPrimaryWindow() {
    let payload = "{\"rateLimits\": {\"secondary\": null}}".data(using: .utf8)!

    XCTAssertThrowsError(try CodexRateLimitDecoder.decodeUsage(from: payload)) { error in
      XCTAssertEqual(error as? QuotaReadingError, .missingRateLimit)
    }
  }

  func testAccountDecoderPreservesFreeMembership() throws {
    let payload = """
      {
        "account": {
          "type": "chatgpt",
          "email": "member@example.com",
          "planType": "free"
        },
        "requiresOpenaiAuth": true
      }
      """.data(using: .utf8)!

    let metadata = try CodexAccountDecoder.decode(from: payload)

    XCTAssertEqual(metadata.identityHash.count, 12)
    XCTAssertEqual(metadata.email, "member@example.com")
    XCTAssertEqual(metadata.planName, "Free")
  }

  func testMembershipNamesCoverCurrentProtocolValues() {
    XCTAssertEqual(ChatGPTMembership.displayName(for: "plus"), "Plus")
    XCTAssertEqual(ChatGPTMembership.displayName(for: "prolite"), "Pro Lite")
    XCTAssertEqual(
      ChatGPTMembership.displayName(for: "self_serve_business_usage_based"),
      "Business"
    )
    XCTAssertEqual(ChatGPTMembership.displayName(for: "enterprise"), "Enterprise")
    XCTAssertEqual(ChatGPTMembership.displayName(for: nil), "Unknown")
  }

  func testLongEmailUsesMiddleTruncationWhilePreservingDomain() {
    let account = AccountRecord(
      id: AccountID("long-email"),
      displayName: "Fallback",
      email: "a-very-long-personal-address@example.com",
      detail: "",
      planName: "Plus",
      symbolName: "person.crop.circle",
      accent: .orange,
      usage: AccountUsage(weekly: UsageWindow(usedPercent: 0, resetAt: Date()))
    )

    let compact = account.compactAccountLabel(maximumLength: 30)

    XCTAssertLessThanOrEqual(compact.count, 30)
    XCTAssertTrue(compact.contains("…"))
    XCTAssertTrue(compact.hasSuffix("@example.com"))
  }

  func testPreviewStateFileStorePersistsReadOnlyMetadataWithoutCredentials() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("switchgpt-preview-state-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let fileURL = root.appendingPathComponent("preview-state.json")
    let persistence = PreviewStateFileStore(fileURL: fileURL)
    let accounts = MockAccountCatalog.accounts(now: Date(timeIntervalSince1970: 1_700_000_000))
    let state = PreviewState(
      accounts: accounts,
      currentAccountID: AccountID("work"),
      lastRefreshedAt: Date(timeIntervalSince1970: 1_700_000_123)
    )

    try persistence.save(state)

    XCTAssertEqual(try persistence.load(), state)
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

    let realAccount = AccountRecord(
      id: AccountID("real"),
      displayName: "Real",
      email: "real@example.com",
      detail: "Read-only quota",
      planName: "ChatGPT Plus",
      symbolName: "person.crop.circle",
      accent: .orange,
      usage: accounts[0].usage,
      source: .codexHome(path: "/private/outside-repository"),
      identityHash: "a1b2c3d4e5f6",
      usageRefreshedAt: Date(timeIntervalSince1970: 1_700_000_123)
    )
    let readOnlyState = PreviewState(
      accounts: [realAccount],
      currentAccountID: realAccount.id
    )

    try persistence.save(readOnlyState)
    XCTAssertEqual(try persistence.load(), readOnlyState)
    let persistedText = try String(contentsOf: fileURL, encoding: .utf8)
    XCTAssertFalse(persistedText.contains("access_token"))
    XCTAssertFalse(persistedText.contains("refresh_token"))

    let invalidAccount = AccountRecord(
      id: AccountID("invalid"),
      displayName: "Invalid",
      detail: "Invalid pin",
      planName: "ChatGPT",
      symbolName: "person.crop.circle",
      accent: .blue,
      usage: accounts[0].usage,
      source: .codexHome(path: "/private/outside-repository"),
      identityHash: "redacted"
    )
    let unsafeState = PreviewState(accounts: [invalidAccount], currentAccountID: invalidAccount.id)

    XCTAssertThrowsError(try persistence.save(unsafeState)) { error in
      XCTAssertEqual(error as? PreviewStatePersistenceError, .unsupportedAccountSource)
    }
  }

  @MainActor
  func testStoreAddsAndRestoresReadOnlyAccountFromPinnedProbe() async {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("switchgpt-readonly-store-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = PreviewStateFileStore(fileURL: root.appendingPathComponent("state.json"))
    let usage = AccountUsage(
      weekly: UsageWindow(usedPercent: 42, resetAt: Date(timeIntervalSince1970: 1_800_000_000)),
      fiveHour: UsageWindow(usedPercent: 7, resetAt: Date(timeIntervalSince1970: 1_790_000_000))
    )
    let store = SwitchGPTAppStore(
      accountProbe: StubAccountProbe(
        result: .success(
          ReadOnlyAccountProbe(identityHash: "012345abcdef", usage: usage)
        )),
      persistence: persistence
    )

    let addedID = await store.addReadOnlyAccount(
      displayName: "Primary",
      detail: "Personal",
      codexHomePath: "/private/account-a"
    )

    XCTAssertNotNil(addedID)
    XCTAssertEqual(store.currentAccountID, AccountID("personal"))
    let addedAccount = store.accounts.first { $0.id == addedID }
    XCTAssertEqual(addedAccount?.usage, usage)
    XCTAssertEqual(addedAccount?.identityHash, "012345abcdef")
    XCTAssertEqual(addedAccount?.planName, "Unknown")
    XCTAssertEqual(store.accounts.count, 3)

    let restored = SwitchGPTAppStore(persistence: persistence)
    XCTAssertEqual(restored.currentAccountID, AccountID("personal"))
    let restoredAccount = restored.accounts.first { $0.id == addedID }
    XCTAssertEqual(restoredAccount?.source, .codexHome(path: "/private/account-a"))
    XCTAssertEqual(restoredAccount?.identityHash, "012345abcdef")
  }

  @MainActor
  func testBootstrapReplacesOnlyUntouchedDemoCatalogWithCurrentRealAccount() async {
    let usage = AccountUsage(
      weekly: UsageWindow(usedPercent: 33, resetAt: Date(timeIntervalSince1970: 1_800_000_000))
    )
    let store = SwitchGPTAppStore(
      accountProbe: StubAccountProbe(
        result: .success(
          ReadOnlyAccountProbe(identityHash: "012345abcdef", usage: usage)
        ))
    )

    await store.bootstrapCurrentAccountIfNeeded()

    XCTAssertEqual(store.accounts.count, 1)
    XCTAssertEqual(store.currentAccount?.displayName, "Current account")
    XCTAssertEqual(store.currentAccount?.usage, usage)
    XCTAssertEqual(store.currentAccount?.identityHash, "012345abcdef")
    XCTAssertEqual(
      store.currentAccount?.source,
      .codexHome(
        path: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)
    )
  }

  @MainActor
  func testProductionStoreStartsWithoutDemoAccounts() {
    let store = SwitchGPTAppStore(
      accountProbe: UnavailableAccountProbe(),
      initialAccounts: []
    )

    XCTAssertTrue(store.accounts.isEmpty)
    XCTAssertNil(store.currentAccountID)
    XCTAssertNil(store.currentAccount)
  }

  @MainActor
  func testProductionBootstrapAddsOnlyTheCurrentRealAccount() async {
    let usage = AccountUsage(
      weekly: UsageWindow(usedPercent: 33, resetAt: Date(timeIntervalSince1970: 1_800_000_000))
    )
    let store = SwitchGPTAppStore(
      accountProbe: StubAccountProbe(
        result: .success(
          ReadOnlyAccountProbe(
            identityHash: "012345abcdef",
            email: "current@example.com",
            planName: "Plus",
            usage: usage
          )
        )
      ),
      initialAccounts: []
    )

    await store.bootstrapCurrentAccountIfNeeded()

    XCTAssertEqual(store.accounts.count, 1)
    XCTAssertEqual(store.currentAccount?.accountLabel, "current@example.com")
    XCTAssertEqual(
      store.currentAccount?.source,
      .codexHome(
        path: FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent(".codex").path
      )
    )
  }

  @MainActor
  func testProductionMigrationRemovesPersistedMockAccounts() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("switchgpt-mock-migration-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let persistence = PreviewStateFileStore(fileURL: root.appendingPathComponent("state.json"))
    let mocks = MockAccountCatalog.accounts(now: Date(timeIntervalSince1970: 1_700_000_000))
    let real = AccountRecord(
      id: AccountID("real-account"),
      displayName: "real@example.com",
      email: "real@example.com",
      detail: "",
      planName: "Plus",
      symbolName: "person.crop.circle",
      accent: .green,
      usage: mocks[0].usage,
      source: .codexHome(path: "/private/managed-real"),
      identityHash: "012345abcdef"
    )
    try persistence.save(
      PreviewState(
        accounts: [mocks[0], mocks[1], real],
        currentAccountID: real.id
      )
    )

    let store = SwitchGPTAppStore(
      accountProbe: UnavailableAccountProbe(),
      persistence: persistence,
      initialAccounts: []
    )

    XCTAssertEqual(store.accounts, [real])
    XCTAssertEqual(store.currentAccountID, real.id)
    XCTAssertEqual(try persistence.load()?.accounts, [real])
  }

  @MainActor
  func testRemoveAccountPersistsBeforeDiscardingManagedProfile() throws {
    let usage = AccountUsage(
      weekly: UsageWindow(usedPercent: 10, resetAt: Date(timeIntervalSince1970: 1_800_000_000))
    )
    let current = AccountRecord(
      id: AccountID("current"),
      displayName: "current@example.com",
      email: "current@example.com",
      detail: "",
      planName: "Plus",
      symbolName: "person.crop.circle",
      accent: .orange,
      usage: usage,
      source: .codexHome(path: "/private/current"),
      identityHash: "111111111111"
    )
    let removable = AccountRecord(
      id: AccountID("removable"),
      displayName: "removable@example.com",
      email: "removable@example.com",
      detail: "",
      planName: "Free",
      symbolName: "person.crop.circle",
      accent: .blue,
      usage: usage,
      source: .codexHome(path: "/private/removable"),
      identityHash: "222222222222"
    )
    let persistence = InMemoryPreviewStateStore(
      state: PreviewState(
        accounts: [current, removable],
        currentAccountID: current.id
      )
    )
    let onboarder = StubManagedAccountOnboarder(path: "/private/new")
    let store = SwitchGPTAppStore(
      accountOnboarder: onboarder,
      persistence: persistence,
      initialAccounts: []
    )

    store.removeAccount(removable.id)

    XCTAssertEqual(store.accounts, [current])
    XCTAssertEqual(store.currentAccountID, current.id)
    XCTAssertEqual(onboarder.discardedPaths, ["/private/removable"])
    XCTAssertEqual(try persistence.load()?.accounts, [current])
  }

  @MainActor
  func testBootstrapPreservesUserCustomizedCatalog() async {
    let probe = StubAccountProbe(
      result: .success(
        ReadOnlyAccountProbe(
          identityHash: "012345abcdef",
          usage: AccountUsage(weekly: UsageWindow(usedPercent: 1, resetAt: Date()))
        )
      ))
    let store = SwitchGPTAppStore(accountProbe: probe)
    _ = store.addMockAccount(displayName: "Research", detail: "Custom")

    await store.bootstrapCurrentAccountIfNeeded()

    XCTAssertEqual(store.accounts.count, 3)
    XCTAssertEqual(store.currentAccountID, AccountID("personal"))
  }

  @MainActor
  func testStorePreservesMutableActiveAccountIntoManagedStorage() async {
    let activePath = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex", isDirectory: true).path
    let managedPath = "/private/managed-active"
    let onboarder = StubManagedAccountOnboarder(
      path: "/private/new-login",
      preservedPath: managedPath
    )
    let probe = StubAccountProbe(
      result: .success(
        ReadOnlyAccountProbe(
          identityHash: "012345abcdef",
          usage: AccountUsage(weekly: UsageWindow(usedPercent: 12, resetAt: Date()))
        )
      ))
    let persistence = InMemoryPreviewStateStore(
      state: PreviewState(
        accounts: [
          AccountRecord(
            id: AccountID("active"),
            displayName: "Current account",
            detail: "Active ChatGPT account",
            planName: "ChatGPT",
            symbolName: "person.crop.circle",
            accent: .orange,
            usage: AccountUsage(weekly: UsageWindow(usedPercent: 20, resetAt: Date())),
            source: .codexHome(path: activePath),
            identityHash: "012345abcdef"
          )
        ],
        currentAccountID: AccountID("active")
      ))
    let store = SwitchGPTAppStore(
      accountProbe: probe,
      accountOnboarder: onboarder,
      persistence: persistence
    )

    await store.preserveActiveAccountForSwitchingIfNeeded()

    XCTAssertEqual(store.currentAccount?.source, .codexHome(path: managedPath))
    XCTAssertEqual(onboarder.preservedSourcePaths, [activePath])
    XCTAssertFalse(store.activity.isFailure)
  }

  @MainActor
  func testStoreRejectsDuplicateReadOnlyIdentity() async {
    let probe = StubAccountProbe(
      result: .success(
        ReadOnlyAccountProbe(
          identityHash: "012345abcdef",
          usage: AccountUsage(weekly: UsageWindow(usedPercent: 1, resetAt: Date()))
        )
      ))
    let store = SwitchGPTAppStore(accountProbe: probe)

    let first = await store.addReadOnlyAccount(
      displayName: "One", detail: "", codexHomePath: "/private/one"
    )
    let second = await store.addReadOnlyAccount(
      displayName: "Two", detail: "", codexHomePath: "/private/two"
    )
    XCTAssertNotNil(first)
    XCTAssertNil(second)
    XCTAssertEqual(store.accounts.count, 3)
    XCTAssertTrue(store.activity.isFailure)
  }

  @MainActor
  func testManagedSignInAddsAccountWithoutUserSuppliedPath() async {
    let onboarder = StubManagedAccountOnboarder(path: "/private/managed-account")
    let usage = AccountUsage(
      weekly: UsageWindow(usedPercent: 22, resetAt: Date(timeIntervalSince1970: 1_800_000_000))
    )
    let store = SwitchGPTAppStore(
      accountProbe: StubAccountProbe(
        result: .success(
          ReadOnlyAccountProbe(
            identityHash: "abcdef012345",
            email: "free@example.com",
            planName: "Free",
            usage: usage
          )
        )),
      accountOnboarder: onboarder
    )

    let accountID = await store.signInAccount()

    XCTAssertNotNil(accountID)
    XCTAssertEqual(store.currentAccountID, AccountID("personal"))
    let addedAccount = store.accounts.first { $0.id == accountID }
    XCTAssertEqual(addedAccount?.accountLabel, "free@example.com")
    XCTAssertEqual(addedAccount?.email, "free@example.com")
    XCTAssertEqual(addedAccount?.detail, "")
    XCTAssertEqual(addedAccount?.source, .codexHome(path: "/private/managed-account"))
    XCTAssertEqual(addedAccount?.usage, usage)
    XCTAssertEqual(addedAccount?.planName, "Free")
    XCTAssertTrue(onboarder.discardedPaths.isEmpty)
    XCTAssertEqual(store.accountOnboardingActivity, .idle)
    XCTAssertFalse(store.activity.isBusy)
  }

  @MainActor
  func testManagedSignInDoesNotBlockUsageRefreshAndCanBeCancelled() async {
    let quotaReader = CountingQuotaReader()
    let store = SwitchGPTAppStore(
      quotaReader: quotaReader,
      accountOnboarder: SlowManagedAccountOnboarder()
    )
    let signInTask = Task { await store.signInAccount() }

    while !store.accountOnboardingActivity.isInProgress {
      await Task.yield()
    }

    XCTAssertFalse(store.activity.isBusy)
    await store.refresh()

    let refreshCount = await quotaReader.count
    XCTAssertEqual(refreshCount, 1)
    XCTAssertTrue(store.accountOnboardingActivity.isInProgress)
    XCTAssertFalse(store.activity.isBusy)

    signInTask.cancel()
    let result = await signInTask.value
    XCTAssertNil(result)
    XCTAssertEqual(store.accountOnboardingActivity, .idle)
  }

  @MainActor
  func testReconcileCurrentAccountUsesActiveDesktopIdentity() async {
    let usage = AccountUsage(
      weekly: UsageWindow(usedPercent: 9, resetAt: Date(timeIntervalSince1970: 1_800_000_000))
    )
    let accounts = [
      AccountRecord(
        id: AccountID("one"),
        displayName: "One",
        detail: "Saved ChatGPT account",
        planName: "Plus",
        symbolName: "person.crop.circle",
        accent: .orange,
        usage: usage,
        source: .codexHome(path: "/private/one"),
        identityHash: "111111111111"
      ),
      AccountRecord(
        id: AccountID("two"),
        displayName: "Two",
        detail: "Saved ChatGPT account",
        planName: "ChatGPT",
        symbolName: "person.crop.circle",
        accent: .blue,
        usage: usage,
        source: .codexHome(path: "/private/two"),
        identityHash: "222222222222"
      ),
    ]
    let persistence = InMemoryPreviewStateStore(
      state: PreviewState(accounts: accounts, currentAccountID: AccountID("one"))
    )
    let store = SwitchGPTAppStore(
      accountProbe: StubAccountProbe(
        result: .success(
          ReadOnlyAccountProbe(
            identityHash: "222222222222",
            email: "two@example.com",
            planName: "Free",
            usage: usage
          )
        )
      ),
      persistence: persistence
    )

    await store.reconcileCurrentAccountWithDesktop()

    XCTAssertEqual(store.currentAccountID, AccountID("two"))
    XCTAssertEqual(store.currentAccount?.accountLabel, "two@example.com")
    XCTAssertEqual(store.currentAccount?.planName, "Free")
  }

  @MainActor
  func testManagedSignInDiscardsDuplicateAccountStorage() async {
    let onboarder = StubManagedAccountOnboarder(path: "/private/managed-duplicate")
    let probe = StubAccountProbe(
      result: .success(
        ReadOnlyAccountProbe(
          identityHash: "abcdef012345",
          usage: AccountUsage(weekly: UsageWindow(usedPercent: 1, resetAt: Date()))
        )
      ))
    let store = SwitchGPTAppStore(accountProbe: probe, accountOnboarder: onboarder)
    _ = await store.addReadOnlyAccount(
      displayName: "Existing",
      detail: "",
      codexHomePath: "/private/existing"
    )

    let duplicate = await store.signInAccount()

    XCTAssertNil(duplicate)
    XCTAssertEqual(onboarder.discardedPaths, ["/private/managed-duplicate"])
    XCTAssertFalse(store.activity.isFailure)
    XCTAssertEqual(
      store.accountOnboardingActivity,
      .failure(message: "This account is already configured")
    )
  }

  func testPreviewStateFileStoreRejectsBroadFilePermissions() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("switchgpt-preview-state-permissions-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let fileURL = root.appendingPathComponent("preview-state.json")
    let persistence = PreviewStateFileStore(fileURL: fileURL)
    let accounts = MockAccountCatalog.accounts()
    try persistence.save(
      PreviewState(accounts: accounts, currentAccountID: accounts[0].id)
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)

    XCTAssertThrowsError(try persistence.load()) { error in
      XCTAssertEqual(error as? PreviewStatePersistenceError, .insecureFile)
    }
  }

  func testPreviewStateFileStoreRejectsSymbolicLink() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("switchgpt-preview-state-symlink-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let targetURL = root.appendingPathComponent("target.json")
    let linkURL = root.appendingPathComponent("preview-state.json")
    let targetStore = PreviewStateFileStore(fileURL: targetURL)
    let accounts = MockAccountCatalog.accounts()
    try targetStore.save(PreviewState(accounts: accounts, currentAccountID: accounts[0].id))
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

    XCTAssertThrowsError(try PreviewStateFileStore(fileURL: linkURL).load()) { error in
      XCTAssertEqual(error as? PreviewStatePersistenceError, .invalidFile)
    }
  }

  func testPreviewStateFileStoreRejectsCorruptedJSON() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("switchgpt-preview-state-corrupt-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let fileURL = root.appendingPathComponent("preview-state.json")
    let persistence = PreviewStateFileStore(fileURL: fileURL)
    let accounts = MockAccountCatalog.accounts()
    try persistence.save(PreviewState(accounts: accounts, currentAccountID: accounts[0].id))
    try Data("{not-json".utf8).write(to: fileURL)

    XCTAssertThrowsError(try persistence.load()) { error in
      XCTAssertEqual(error as? PreviewStatePersistenceError, .invalidFile)
    }
  }

  @MainActor
  func testStoreRestoresPersistedMockAccountsAndSelection() async {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("switchgpt-store-state-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let persistence = PreviewStateFileStore(
      fileURL: root.appendingPathComponent("preview-state.json")
    )
    let firstStore = SwitchGPTAppStore(
      now: Date(timeIntervalSince1970: 1_700_000_000),
      persistence: persistence
    )
    let addedID = firstStore.addMockAccount(
      displayName: "Research",
      detail: "Reading workspace"
    )
    XCTAssertNotNil(addedID)

    if let addedID {
      await firstStore.simulateSwitch(to: addedID)
    }

    let restoredStore = SwitchGPTAppStore(
      now: Date(timeIntervalSince1970: 1_700_000_000),
      persistence: persistence
    )
    XCTAssertEqual(restoredStore.accounts.count, 3)
    XCTAssertEqual(restoredStore.currentAccountID, addedID)
    XCTAssertNil(restoredStore.lastPersistenceError)
  }
}

private struct StubAccountProbe: ReadOnlyAccountProbing {
  let result: Result<ReadOnlyAccountProbe, QuotaReadingError>

  func probe(codexHomePath: String) async throws -> ReadOnlyAccountProbe {
    try result.get()
  }
}

private actor CountingQuotaReader: QuotaReading {
  private(set) var count = 0

  func fetchSnapshots(for accounts: [AccountRecord]) async throws
    -> [AccountID: AccountQuotaSnapshot]
  {
    count += 1
    return Dictionary(
      uniqueKeysWithValues: accounts.map {
        ($0.id, AccountQuotaSnapshot(planName: $0.planName, usage: $0.usage))
      })
  }
}

private struct FixedSnapshotQuotaReader: QuotaReading {
  let snapshot: AccountQuotaSnapshot

  func fetchSnapshots(for accounts: [AccountRecord]) async throws
    -> [AccountID: AccountQuotaSnapshot]
  {
    Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, snapshot) })
  }
}

private struct SelectivelyFailingQuotaReader: QuotaReading {
  let successfulAccountID: AccountID?
  let snapshot: AccountQuotaSnapshot?

  func fetchSnapshots(for accounts: [AccountRecord]) async throws
    -> [AccountID: AccountQuotaSnapshot]
  {
    guard let successfulAccountID, let snapshot,
      accounts.contains(where: { $0.id == successfulAccountID })
    else {
      throw QuotaReadingError.invalidProtocolResponse
    }
    return [successfulAccountID: snapshot]
  }
}

private final class StubManagedAccountOnboarder: ManagedAccountOnboarding, @unchecked Sendable {
  let path: String
  let preservedPath: String
  private let lock = NSLock()
  private var storedDiscardedPaths: [String] = []
  private var storedPreservedSourcePaths: [String] = []

  var discardedPaths: [String] {
    lock.withLock { storedDiscardedPaths }
  }

  var preservedSourcePaths: [String] {
    lock.withLock { storedPreservedSourcePaths }
  }

  init(path: String, preservedPath: String? = nil) {
    self.path = path
    self.preservedPath = preservedPath ?? path
  }

  func signIn() async throws -> String { path }

  func preserveAccount(from codexHomePath: String) throws -> String {
    lock.withLock { storedPreservedSourcePaths.append(codexHomePath) }
    return preservedPath
  }

  func discardManagedAccount(at path: String) throws {
    lock.withLock { storedDiscardedPaths.append(path) }
  }
}

private struct SlowManagedAccountOnboarder: ManagedAccountOnboarding {
  func signIn() async throws -> String {
    try await Task.sleep(for: .seconds(30))
    return "/private/slow-managed-account"
  }

  func preserveAccount(from codexHomePath: String) throws -> String {
    codexHomePath
  }

  func discardManagedAccount(at path: String) throws {}
}

private final class InMemoryPreviewStateStore: PreviewStatePersisting, @unchecked Sendable {
  private let lock = NSLock()
  private var state: PreviewState?

  init(state: PreviewState?) {
    self.state = state
  }

  func load() throws -> PreviewState? {
    lock.withLock { state }
  }

  func save(_ state: PreviewState) throws {
    lock.withLock { self.state = state }
  }

  func remove() throws {
    lock.withLock { state = nil }
  }
}
