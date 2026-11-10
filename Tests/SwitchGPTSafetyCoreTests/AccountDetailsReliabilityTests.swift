import Foundation
import XCTest

@testable import SwitchGPTAppCore

final class AccountDetailsReliabilityTests: XCTestCase {
  func testRetriesCountOnlyResetCreditsAfterReadingTokenActivity() async throws {
    let fixture = try DetailsFixture(responses: DetailsFixture.responses + [
      DetailsFixture.rateLimits(details: true)
    ])
    defer { fixture.remove() }
    let account = try fixture.account()
    let snapshots = try await fixture.reader.fetchSnapshots(for: [account])
    XCTAssertEqual(snapshots[account.id]?.usage.resetCredits?.knownDetailCount, 2)
    XCTAssertEqual(snapshots[account.id]?.usage.tokenActivity?.lifetimeTokens, 123)
    XCTAssertEqual(try fixture.methods(), [
      "initialize", "account/read", "account/rateLimits/read", "account/usage/read",
      "account/rateLimits/read",
    ])
    let sourceAuth = try Data(contentsOf: fixture.home.appendingPathComponent("auth.json"))
    XCTAssertEqual(sourceAuth, Data("fixture only, no real credentials".utf8))
  }

  func testRetriesTransientTokenFailureOnceWithoutLosingQuota() async throws {
    var responses = DetailsFixture.responses
    responses[2] = DetailsFixture.rateLimits(details: true)
    responses[3] = DetailsFixture.error(method: "account/usage/read", code: -32603)
    responses.append(DetailsFixture.tokenActivity)
    let fixture = try DetailsFixture(responses: responses)
    defer { fixture.remove() }
    let account = try fixture.account()
    let snapshots = try await fixture.reader.fetchSnapshots(for: [account])
    XCTAssertEqual(snapshots[account.id]?.usage.weekly.usedPercent, 12)
    XCTAssertEqual(snapshots[account.id]?.usage.tokenActivity?.lifetimeTokens, 123)
    XCTAssertEqual(try fixture.methods().filter { $0 == "account/usage/read" }.count, 2)
  }

  func testUnsupportedTokenMethodIsNotRetriedAndQuotaSurvives() async throws {
    var responses = DetailsFixture.responses
    responses[2] = DetailsFixture.rateLimits(details: true)
    responses[3] = DetailsFixture.error(method: "account/usage/read", code: -32601)
    let fixture = try DetailsFixture(responses: responses)
    defer { fixture.remove() }
    let account = try fixture.account()
    let snapshots = try await fixture.reader.fetchSnapshots(for: [account])
    XCTAssertEqual(snapshots[account.id]?.usage.weekly.usedPercent, 12)
    XCTAssertEqual(snapshots[account.id]?.usage.tokenActivityWasLoaded, false)
    XCTAssertEqual(try fixture.methods().filter { $0 == "account/usage/read" }.count, 1)
  }

  func testTransientTokenFailuresStopAfterOneRetry() async throws {
    var responses = DetailsFixture.responses
    responses[2] = DetailsFixture.rateLimits(details: true)
    responses[3] = DetailsFixture.error(method: "account/usage/read", code: -32603)
    responses.append(responses[3])
    let fixture = try DetailsFixture(responses: responses)
    defer { fixture.remove() }
    let account = try fixture.account()
    let snapshots = try await fixture.reader.fetchSnapshots(for: [account])
    XCTAssertEqual(snapshots[account.id]?.usage.weekly.usedPercent, 12)
    XCTAssertEqual(snapshots[account.id]?.usage.tokenActivityWasLoaded, false)
    XCTAssertEqual(try fixture.methods().filter { $0 == "account/usage/read" }.count, 2)
  }

  func testFailedDetailRetryPreservesQuotaAndSuccessfulTokenRead() async throws {
    let fixture = try DetailsFixture(responses: DetailsFixture.responses + [
      DetailsFixture.error(method: "account/rateLimits/read", code: -32603)
    ])
    defer { fixture.remove() }
    let account = try fixture.account()
    let snapshots = try await fixture.reader.fetchSnapshots(for: [account])
    XCTAssertEqual(snapshots[account.id]?.usage.resetCredits?.availableCount, 2)
    XCTAssertNil(snapshots[account.id]?.usage.resetCredits?.credits)
    XCTAssertEqual(snapshots[account.id]?.usage.tokenActivity?.lifetimeTokens, 123)
    XCTAssertEqual(try fixture.methods().filter { $0 == "account/rateLimits/read" }.count, 2)
  }

  func testMissingSummaryOnRetryDoesNotEraseTheKnownResetCount() async throws {
    var retry = DetailsFixture.rateLimits(details: true)
    var result = retry["result"] as! [String: Any]
    result.removeValue(forKey: "rateLimitResetCredits")
    retry["result"] = result
    let fixture = try DetailsFixture(responses: DetailsFixture.responses + [retry])
    defer { fixture.remove() }
    let account = try fixture.account()
    let snapshots = try await fixture.reader.fetchSnapshots(for: [account])
    XCTAssertEqual(snapshots[account.id]?.usage.resetCredits?.availableCount, 2)
    XCTAssertNil(snapshots[account.id]?.usage.resetCredits?.credits)
    XCTAssertEqual(snapshots[account.id]?.usage.tokenActivity?.lifetimeTokens, 123)
  }

  func testRetryUsesTheNewResetInventoryInsteadOfThePreviousCount() async throws {
    var retry = DetailsFixture.rateLimits(details: true)
    var result = retry["result"] as! [String: Any]
    result["rateLimitResetCredits"] = ["availableCount": 0, "credits": [] as [Any]]
    retry["result"] = result
    let fixture = try DetailsFixture(responses: DetailsFixture.responses + [retry])
    defer { fixture.remove() }
    let account = try fixture.account()
    let snapshots = try await fixture.reader.fetchSnapshots(for: [account])
    XCTAssertEqual(snapshots[account.id]?.usage.resetCredits?.availableCount, 0)
    XCTAssertEqual(snapshots[account.id]?.usage.resetCredits?.knownDetailCount, 0)
    XCTAssertEqual(snapshots[account.id]?.usage.tokenActivity?.lifetimeTokens, 123)
  }

  func testOptionalReadDoesNotExtendTheAccountDeadline() async throws {
    var responses = DetailsFixture.responses
    responses[2] = DetailsFixture.rateLimits(details: true)
    responses[3]["delay"] = 2
    let fixture = try DetailsFixture(responses: responses)
    defer { fixture.remove() }
    let account = try fixture.account()
    let start = Date()
    let snapshots = try await CodexAppServerQuotaReader(
      codexBinaryURL: fixture.binary, timeout: .milliseconds(500)
    ).fetchSnapshots(for: [account])
    XCTAssertTrue(Date().timeIntervalSince(start) < 1.5)
    XCTAssertEqual(snapshots[account.id]?.usage.weekly.usedPercent, 12)
    XCTAssertEqual(snapshots[account.id]?.usage.tokenActivityWasLoaded, false)
    XCTAssertEqual(try fixture.methods().filter { $0 == "account/usage/read" }.count, 1)
  }

  func testMultiAccountReaderLimitsConcurrencyAndQueriesTheQueue() async throws {
    var responses = DetailsFixture.responses
    responses[0]["delay"] = 0.2
    responses[2] = DetailsFixture.rateLimits(details: true)
    let fixture = try DetailsFixture(responses: responses)
    defer { fixture.remove() }
    let accounts = try (0..<9).map { try fixture.account(id: "account-\($0)") }
    let snapshots = try await fixture.reader.fetchSnapshots(for: accounts)
    XCTAssertEqual(Set(snapshots.keys), Set(accounts.map(\.id)))
    var running = 0
    var peak = 0
    for event in try fixture.events() {
      if event["event"] as? String == "start" { running += 1 }
      if event["event"] as? String == "end" { running -= 1 }
      peak = max(peak, running)
    }
    XCTAssertEqual(peak, 4)
    XCTAssertEqual(running, 0)
  }

  func testQueuedHealthyAccountStillRunsWhenFirstAccountsFailIdentityCheck() async throws {
    var responses = DetailsFixture.responses
    responses[2] = DetailsFixture.rateLimits(details: true)
    let fixture = try DetailsFixture(responses: responses)
    defer { fixture.remove() }
    var accounts = try (0..<4).map {
      try fixture.account(id: "mismatch-\($0)", identityHash: "000000000000")
    }
    accounts.append(try fixture.account(id: "healthy"))
    let snapshots = try await fixture.reader.fetchSnapshots(for: accounts)
    XCTAssertEqual(Set(snapshots.keys), [AccountID("healthy")])
  }

  @MainActor
  func testBothRefreshPathsReportMissingDetailsAsPartial() async throws {
    let fixture = try DetailsFixture(responses: [])
    defer { fixture.remove() }
    let account = try fixture.account()
    for missingToken in [true, false] {
      let usage = AccountUsage(
        weekly: account.usage.weekly,
        resetCredits: .init(availableCount: 2, credits: missingToken ? [] : nil),
        tokenActivity: missingToken ? nil : .init(
          lifetimeTokens: 123, peakDailyTokens: nil, longestRunningTurnSec: nil,
          currentStreakDays: nil, longestStreakDays: nil, dailyUsageBuckets: nil),
        tokenActivityWasLoaded: !missingToken)
      let store = SwitchGPTAppStore(
        quotaReader: DetailsReader(usage: usage), initialAccounts: [account])
      await store.refresh()
      XCTAssertEqual(store.activity, .partial(
        message: "Quota updated; some token activity or reset-credit details are unavailable."))
      XCTAssertNil(store.lastRefreshedAt)
      XCTAssertTrue(store.quotaRefreshFailedAccountIDs.isEmpty)
      let refreshed = await store.refreshAccount(account.id)
      XCTAssertTrue(refreshed)
      XCTAssertEqual(store.activity, .partial(
        message: "Quota updated; some token activity or reset-credit details are unavailable."))
      XCTAssertNil(store.lastRefreshedAt)
    }
  }
}

private struct DetailsReader: QuotaReading {
  let usage: AccountUsage
  func fetchSnapshots(for accounts: [AccountRecord]) async throws
    -> [AccountID: AccountQuotaSnapshot]
  {
    Dictionary(uniqueKeysWithValues: accounts.map {
      ($0.id, AccountQuotaSnapshot(planName: "Pro", usage: usage))
    })
  }
}

private struct DetailsFixture {
  let root: URL
  let home: URL
  let binary: URL
  let eventsURL: URL

  var reader: CodexAppServerQuotaReader {
    CodexAppServerQuotaReader(codexBinaryURL: binary, timeout: .seconds(5))
  }

  static var tokenActivity: [String: Any] {
    ["method": "account/usage/read", "result": [
      "summary": ["lifetimeTokens": 123], "dailyUsageBuckets": [] as [Any],
    ]]
  }

  static var responses: [[String: Any]] {
    [
      ["method": "initialize", "result": [:] as [String: Any]],
      ["method": "account/read", "result": [
        "account": ["email": "fixture@example.test", "planType": "pro"]
      ]],
      rateLimits(details: false), tokenActivity,
    ]
  }

  static func rateLimits(details: Bool) -> [String: Any] {
    ["method": "account/rateLimits/read", "result": [
      "rateLimits": ["primary": [
        "usedPercent": 12, "windowDurationMins": 10080, "resetsAt": 1_900_000_000
      ]],
      "rateLimitResetCredits": [
        "availableCount": 2,
        "credits": details ? [
          ["status": "available", "expiresAt": 1_900_000_001],
          ["status": "available", "expiresAt": 1_900_000_002],
        ] as Any : NSNull(),
      ],
    ]]
  }

  static func error(method: String, code: Int) -> [String: Any] {
    ["method": method, "error": ["code": code, "message": "fixture error"]]
  }

  init(responses: [[String: Any]]) throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("switchgpt-detail-fixture-" + UUID().uuidString)
    home = root.appendingPathComponent("home")
    binary = root.appendingPathComponent("fixture-codex")
    eventsURL = root.appendingPathComponent("events.jsonl")
    try FileManager.default.createDirectory(
      at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let auth = home.appendingPathComponent("auth.json")
    try Data("fixture only, no real credentials".utf8).write(to: auth)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
    let encoded = String(decoding: try JSONSerialization.data(withJSONObject: responses), as: UTF8.self)
    let logPath = String(decoding: try JSONEncoder().encode(eventsURL.path), as: UTF8.self)
    let script = """
      #!/usr/bin/python3
      import json, sys, time, os, signal, fcntl
      responses = json.loads(r'''\(encoded)''')
      def event(value):
          with open(json.loads(r'''\(logPath)'''), 'a') as f:
              fcntl.flock(f, fcntl.LOCK_EX)
              f.write(json.dumps(value) + '\\n')
              f.flush()
      def stop(*args):
          event({'event':'end', 'pid':os.getpid()})
          sys.exit(0)
      signal.signal(signal.SIGTERM, stop)
      event({'event':'start', 'pid':os.getpid()})
      index = 0
      for line in sys.stdin:
          request = json.loads(line)
          if 'id' not in request:
              continue
          method = request['method']
          event({'method':method})
          response = responses[index] if index < len(responses) else {}
          index += 1
          if response.get('method') != method:
              result = {'error':{'code':-32601, 'message':'unexpected fixture request'}}
          else:
              time.sleep(response.get('delay', 0))
              result = {k:v for k,v in response.items() if k in ['result','error']}
          result['id'] = request['id']
          print(json.dumps(result), flush=True)
      stop()
      """
    try Data(script.utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
  }

  func account(id: String = "fixture", identityHash: String? = nil) throws -> AccountRecord {
    let data = try JSONSerialization.data(withJSONObject: [
      "account": ["email": "fixture@example.test", "planType": "pro"]
    ])
    let identity = try CodexAccountDecoder.decode(from: data).identityHash
    return AccountRecord(
      id: AccountID(id), displayName: "Fixture", detail: "", planName: "Pro",
      symbolName: "person", accent: .blue,
      usage: AccountUsage(weekly: .init(usedPercent: 20, resetAt: Date())),
      source: .codexHome(path: home.path), identityHash: identityHash ?? identity)
  }

  func events() throws -> [[String: Any]] {
    try String(contentsOf: eventsURL, encoding: .utf8).split(separator: "\n").map {
      try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
    }
  }

  func methods() throws -> [String] { try events().compactMap { $0["method"] as? String } }
  func remove() { try? FileManager.default.removeItem(at: root) }
}
