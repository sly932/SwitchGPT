import Foundation
import XCTest

@testable import SwitchGPTAppCore

final class LivePlanTests: XCTestCase {
  @MainActor
  func testLiveFreePlanOverridesOldPaidMetadataAndIsPersisted() async throws {
    let fixture = try LivePlanFixture(rateLimits: [
      "rateLimitsByLimitId": ["codex": LivePlanFixture.limit(plan: "free")],
      "rateLimits": LivePlanFixture.limit(plan: "pro"),
    ])
    defer { fixture.remove() }
    let persistence = PreviewStateFileStore(fileURL: fixture.root.appendingPathComponent("preview-state.json"))
    let store = SwitchGPTAppStore(
      quotaReader: fixture.reader, persistence: persistence, initialAccounts: [fixture.account]
    )
    await store.refresh()
    XCTAssertEqual(store.accounts[0].planName, "Free")
    XCTAssertEqual(store.accounts[0].usage.weekly.usedPercent, 12)
    XCTAssertTrue(store.quotaRefreshFailedAccountIDs.isEmpty)
    XCTAssertEqual(try persistence.load()?.accounts[0].planName, "Free")
  }

  func testLegacyLivePlanAlsoUpdatesAccountProbe() async throws {
    let fixture = try LivePlanFixture(rateLimits: [
      "rateLimits": LivePlanFixture.limit(plan: "free")
    ])
    defer { fixture.remove() }
    let probe = try await fixture.reader.probe(codexHomePath: fixture.home.path)
    XCTAssertEqual(probe.planName, "Free")
    XCTAssertEqual(probe.email, "member@example.test")
  }

  func testMissingNullAndEmptyLivePlanFallBackToAccountMetadata() async throws {
    for plan in [nil, NSNull(), "", "  "] as [Any?] {
      let fixture = try LivePlanFixture(rateLimits: [
        "rateLimitsByLimitId": ["codex": LivePlanFixture.limit(plan: plan)],
        "rateLimits": LivePlanFixture.limit(plan: "free"),
      ])
      defer { fixture.remove() }
      let snapshots = try await fixture.reader.fetchSnapshots(for: [fixture.account])
      // A plan from another snapshot must not be mixed into the selected Codex quota.
      XCTAssertEqual(snapshots[fixture.account.id]?.planName, "Pro Lite")
    }
  }

  func testUnrecognizedLivePlanDoesNotRetainOldPaidPlan() async throws {
    let fixture = try LivePlanFixture(rateLimits: [
      "rateLimits": LivePlanFixture.limit(plan: "future-plan")
    ])
    defer { fixture.remove() }
    let probe = try await fixture.reader.probe(codexHomePath: fixture.home.path)
    XCTAssertEqual(probe.planName, "Unknown")
  }

  func testDirectLegacySnapshotAndSnakeCasePlanAreSupported() throws {
    var limit = LivePlanFixture.limit(plan: nil)
    limit["plan_type"] = " FREE "
    let payload = try JSONSerialization.data(withJSONObject: limit)
    XCTAssertEqual(try CodexRateLimitDecoder.decodePlanName(from: payload, fallback: "Pro Lite"), "Free")
  }
}

private struct LivePlanFixture {
  let root: URL
  let home: URL
  let reader: CodexAppServerQuotaReader
  let account: AccountRecord

  static func limit(plan: Any?) -> [String: Any] {
    var limit: [String: Any] = [
      "primary": ["usedPercent": 12, "windowDurationMins": 10080, "resetsAt": 1_900_000_000]
    ]
    if let plan { limit["planType"] = plan }
    return limit
  }

  init(rateLimits: [String: Any]) throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("switchgpt-live-plan-" + UUID().uuidString)
    home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(
      at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
    )
    let auth = home.appendingPathComponent("auth.json")
    try Data("fixture authentication, no real credentials".utf8).write(to: auth)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
    let accountResult: [String: Any] = [
      "account": ["email": "member@example.test", "planType": "prolite"]
    ]
    let responses: [[String: Any]] = [
      ["id": 1, "result": [:] as [String: Any]],
      ["id": 2, "result": accountResult],
      ["id": 3, "result": rateLimits],
      ["id": 4, "error": ["code": -32601, "message": "Optional usage unavailable"]],
    ]
    let cases = try responses.enumerated().map { index, response in
      let json = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
      let quoted = "'" + json.replacingOccurrences(of: "'", with: "'\\''") + "'"
      return "\(index + 1)) printf '%s\\n' \(quoted) ;;"
    }.joined(separator: "\n")
    let script = """
      #!/bin/bash
      request_count=0
      while IFS= read -r line; do
        [[ "$line" == *'"id":'* ]] || continue
        request_count=$((request_count + 1))
        case "$request_count" in
      \(cases)
        esac
      done
      """
    let binary = root.appendingPathComponent("fixture-codex")
    try Data(script.utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    reader = CodexAppServerQuotaReader(codexBinaryURL: binary, timeout: .seconds(5))
    let identity = try CodexAccountDecoder.decode(
      from: JSONSerialization.data(withJSONObject: accountResult)
    ).identityHash
    account = AccountRecord(
      id: AccountID("fixture-plan"), displayName: "Fixture", detail: "", planName: "Pro Lite",
      symbolName: "person", accent: .blue,
      usage: AccountUsage(weekly: UsageWindow(usedPercent: 30, resetAt: Date())),
      source: .codexHome(path: home.path), identityHash: identity
    )
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
