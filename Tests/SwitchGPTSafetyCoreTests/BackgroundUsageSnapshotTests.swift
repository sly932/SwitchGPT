import XCTest

@testable import SwitchGPTAppCore

final class BackgroundUsageSnapshotTests: XCTestCase {
  @MainActor
  func testDashboardLoadsSuccessfulSnapshotsWithoutChangingSelectionOrSavedAccountState() throws {
    let fixture = makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let savedAt = Date(timeIntervalSince1970: 100)
    let firstRefresh = Date(timeIntervalSince1970: 200.5)
    let partialRefresh = Date(timeIntervalSince1970: 300)
    let accounts = [account("first", at: savedAt), account("second", at: savedAt)]
    let saved = PreviewState(
      accounts: accounts, currentAccountID: accounts[1].id, lastRefreshedAt: savedAt)
    let persistence = PreviewStateFileStore(
      fileURL: fixture.directory.appendingPathComponent("preview-state.json"))
    try persistence.save(saved)
    try fixture.snapshots.save(
      [accounts[0].id: snapshot(20), accounts[1].id: snapshot(21)],
      for: accounts, refreshedAt: firstRefresh)
    try fixture.snapshots.save([accounts[0].id: snapshot(30)], for: accounts, refreshedAt: partialRefresh)

    let store = SwitchGPTAppStore(persistence: persistence, backgroundUsageStore: fixture.snapshots)
    store.reloadBackgroundUsage()

    XCTAssertEqual(store.accounts.map(\.usage.weekly.usedPercent), [30, 21])
    XCTAssertEqual(store.accounts.map(\.usageRefreshedAt), [partialRefresh, firstRefresh])
    XCTAssertEqual(store.lastRefreshedAt, firstRefresh)
    XCTAssertEqual(store.currentAccountID, accounts[1].id)
    XCTAssertEqual(try persistence.load(), saved)
  }

  func testOverlayRejectsOlderAndMismatchedSnapshots() throws {
    let fixture = makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let older = Date(timeIntervalSince1970: 100)
    let refreshed = Date(timeIntervalSince1970: 200)
    let newer = Date(timeIntervalSince1970: 300)
    let accounts = [account("first", at: older), account("second", at: older), account("third", at: older)]
    try fixture.snapshots.save(
      [accounts[0].id: snapshot(20), accounts[1].id: snapshot(20), accounts[2].id: snapshot(20)],
      for: accounts, refreshedAt: refreshed)
    try fixture.snapshots.save([accounts[0].id: snapshot(9)], for: accounts, refreshedAt: older)
    XCTAssertEqual(try fixture.snapshots.overlay(on: accounts).accounts.map(\.usage.weekly.usedPercent), [20, 20, 20])

    let changedAccounts = [account("first", at: newer), account("second", at: older, path: "/relocated"),
      account("third", at: older, identity: "abcdefabcdef"), account("new", at: older)]
    let result = try fixture.snapshots.overlay(on: changedAccounts)
    XCTAssertEqual(result.accounts, changedAccounts)
    XCTAssertNil(result.lastCompleteRefresh)
  }

  func testOverlayIgnoresMissingCacheAndRejectsUntrustedFile() throws {
    let fixture = makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let accounts = [account("first", at: Date(timeIntervalSince1970: 100))]
    XCTAssertEqual(try fixture.snapshots.overlay(on: accounts).accounts, accounts)

    try fixture.snapshots.save([accounts[0].id: snapshot(20)], for: accounts)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: fixture.snapshots.fileURL.path)
    XCTAssertThrowsError(try fixture.snapshots.overlay(on: accounts)) { error in
      XCTAssertEqual(error as? PreviewStatePersistenceError, .insecureFile)
    }
    XCTAssertThrowsError(try fixture.snapshots.save([accounts[0].id: snapshot(30)], for: accounts)) { error in
      XCTAssertEqual(error as? PreviewStatePersistenceError, .insecureFile)
    }

    let target = fixture.directory.appendingPathComponent("original.json")
    try FileManager.default.moveItem(at: fixture.snapshots.fileURL, to: target)
    try FileManager.default.createSymbolicLink(at: fixture.snapshots.fileURL, withDestinationURL: target)
    let original = try Data(contentsOf: target)
    XCTAssertThrowsError(try fixture.snapshots.save([accounts[0].id: snapshot(30)], for: accounts))
    XCTAssertEqual(try Data(contentsOf: target), original)
  }

  func testSaveRebuildsMalformedOwnedCache() throws {
    let fixture = makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let accounts = [account("first", at: Date(timeIntervalSince1970: 100))]
    try fixture.snapshots.save([accounts[0].id: snapshot(20)], for: accounts)
    let malformedCaches = [
      Data("{".utf8),
      Data(#"{"schemaVersion":99,"entries":{}}"#.utf8),
      Data(repeating: 0, count: PreviewStateFileStore.maximumFileSize + 1),
    ]

    for malformedCache in malformedCaches {
      try malformedCache.write(to: fixture.snapshots.fileURL)
      XCTAssertThrowsError(try fixture.snapshots.overlay(on: accounts))
      try fixture.snapshots.save([accounts[0].id: snapshot(30)], for: accounts)
      let updated = try fixture.snapshots.overlay(on: accounts)
      XCTAssertEqual(updated.accounts.map(\.usage.weekly.usedPercent), [30])
    }
  }

  private func makeFixture() -> (directory: URL, snapshots: BackgroundUsageSnapshotStore) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("switchgpt-background-usage-" + UUID().uuidString, isDirectory: true)
    return (directory, BackgroundUsageSnapshotStore(fileURL: directory.appendingPathComponent("usage.json")))
  }

  private func account(
    _ id: String, at date: Date, path: String? = nil, identity: String = "0123456789ab"
  ) -> AccountRecord {
    AccountRecord(
      id: AccountID(id), displayName: id, detail: "", planName: "ChatGPT Plus",
      symbolName: "person", accent: .green, usage: snapshot(10).usage,
      source: .codexHome(path: path ?? "/profiles/" + id), identityHash: identity,
      usageRefreshedAt: date)
  }

  private func snapshot(_ usedPercent: Int) -> AccountQuotaSnapshot {
    AccountQuotaSnapshot(planName: "ChatGPT Pro", usage: AccountUsage(
      weekly: UsageWindow(usedPercent: usedPercent, resetAt: Date(timeIntervalSince1970: 1_000)),
      tokenActivityWasLoaded: true))
  }
}
