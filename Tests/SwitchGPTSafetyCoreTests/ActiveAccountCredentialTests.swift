import Foundation
import SwitchGPTDesktopIntegration
import SwitchGPTSafetyCore
import XCTest

@testable import SwitchGPTAppCore

final class ActiveAccountCredentialTests: XCTestCase {
  @MainActor
  func testRefreshCapturesLatestCredentialsBeforeQuotaRequest() async throws {
    let fixture = try CredentialFixture()
    defer { fixture.remove() }
    let store = fixture.store()
    await store.refresh()
    XCTAssertTrue(store.quotaRefreshFailedAccountIDs.isEmpty)
    XCTAssertEqual(try Data(contentsOf: fixture.profileA), fixture.activeA)
    XCTAssertEqual(try Data(contentsOf: fixture.active), fixture.activeA)
    XCTAssertEqual(try Data(contentsOf: fixture.profileB), fixture.savedB)
    XCTAssertNotNil(store.accounts[0].usageRefreshedAt)
    let mode = try FileManager.default.attributesOfItem(atPath: fixture.profileA.path)
    XCTAssertEqual((mode[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  @MainActor
  func testTargetedRefreshPreservesDepartingAccountsNewCredentials() async throws {
    let fixture = try CredentialFixture()
    defer { fixture.remove() }
    let store = fixture.store()
    let refreshed = await store.refreshAccount(fixture.accounts[1].id)
    XCTAssertTrue(refreshed)
    XCTAssertEqual(try Data(contentsOf: fixture.profileA), fixture.activeA)
    XCTAssertEqual(try Data(contentsOf: fixture.profileB), fixture.savedB)
    XCTAssertEqual(store.currentAccountID, fixture.accounts[0].id)
  }

  @MainActor
  func testReconcileSynchronizesCurrentProfileWithoutChangingItsPath() async throws {
    let fixture = try CredentialFixture()
    defer { fixture.remove() }
    let store = fixture.store()
    await store.reconcileCurrentAccountWithDesktop()
    XCTAssertEqual(try Data(contentsOf: fixture.profileA), fixture.activeA)
    XCTAssertEqual(store.currentAccountID, fixture.accounts[0].id)
    XCTAssertEqual(store.accounts[0].source, fixture.accounts[0].source)
  }

  @MainActor
  func testRefreshAfterCommittedSwitchCapturesTargetsNewCredentials() async throws {
    let fixture = try CredentialFixture()
    defer { fixture.remove() }
    let store = fixture.store()
    await store.refresh()
    XCTAssertTrue(store.beginRealSwitch(to: fixture.accounts[1].id))
    // The desktop switches to B and subsequently writes its renewed credentials.
    let renewedB = try CredentialFixture.authentication(email: "b@example.test", generation: "new-b")
    try CredentialFixture.write(renewedB, to: fixture.active)
    store.completeRealSwitch(to: fixture.accounts[1].id, receiptRecorded: true)
    await store.refresh()
    XCTAssertEqual(try Data(contentsOf: fixture.profileB), renewedB)
    XCTAssertEqual(try Data(contentsOf: fixture.profileA), fixture.activeA)
    XCTAssertEqual(store.currentAccountID, fixture.accounts[1].id)
  }

  func testChangedDesktopIdentityIsRejectedBeforeProfileReplacement() throws {
    let fixture = try CredentialFixture()
    defer { fixture.remove() }
    let original = try Data(contentsOf: fixture.profileA)
    XCTAssertThrowsError(
      try SecureAuthenticationFileInstaller.synchronizePrivateAuthenticationFile(
        from: fixture.profileB, to: fixture.profileA,
        expectedIdentity: PinnedAuthenticationIdentityReader(
          authenticationFileURL: fixture.profileA
        ).currentIdentity()
      )
    ) { error in
      XCTAssertEqual(error as? DesktopIntegrationError, .identityMismatch)
    }
    XCTAssertEqual(try Data(contentsOf: fixture.profileA), original)
  }

  func testMismatchedSavedProfileIsNotOverwritten() throws {
    let fixture = try CredentialFixture()
    defer { fixture.remove() }
    try CredentialFixture.write(fixture.savedB, to: fixture.profileA)
    XCTAssertThrowsError(try fixture.synchronizer.synchronize(accounts: fixture.accounts))
    XCTAssertEqual(try Data(contentsOf: fixture.profileA), fixture.savedB)
  }

  func testUnconfiguredAndExternalAccountsRemainUntouched() throws {
    let fixture = try CredentialFixture()
    defer { fixture.remove() }
    XCTAssertNil(try fixture.synchronizer.synchronize(accounts: [fixture.accounts[1]]))
    let external = fixture.accountA(in: fixture.root)
    let externalAuth = fixture.root.appendingPathComponent("auth.json")
    let previous = try CredentialFixture.authentication(email: "a@example.test", generation: "external")
    try CredentialFixture.write(previous, to: externalAuth)
    XCTAssertNil(try fixture.synchronizer.synchronize(accounts: [external]))
    XCTAssertEqual(try Data(contentsOf: externalAuth), previous)
    XCTAssertEqual(try Data(contentsOf: fixture.profileA), fixture.savedA)
  }

  func testSymlinkProfileAndBroadPermissionsAreRejected() throws {
    let fixture = try CredentialFixture()
    defer { fixture.remove() }
    let linkedDirectory = fixture.accountsRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createSymbolicLink(
      at: linkedDirectory, withDestinationURL: fixture.profileA.deletingLastPathComponent()
    )
    let linked = fixture.accountA(in: linkedDirectory)
    XCTAssertThrowsError(try fixture.synchronizer.synchronize(accounts: [linked]))
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.active.path)
    XCTAssertThrowsError(try fixture.synchronizer.synchronize(accounts: fixture.accounts))
    XCTAssertEqual(try Data(contentsOf: fixture.profileA), fixture.savedA)
  }

  @MainActor
  func testUnavailableDesktopDoesNotBlockOtherAccountsQuotaRefresh() async throws {
    let fixture = try CredentialFixture()
    defer { fixture.remove() }
    try FileManager.default.removeItem(at: fixture.active)
    let store = fixture.store()
    await store.refresh()
    XCTAssertEqual(store.quotaRefreshFailedAccountIDs, [fixture.accounts[0].id])
    XCTAssertNotNil(store.accounts[1].usageRefreshedAt)
    XCTAssertEqual(try Data(contentsOf: fixture.profileA), fixture.savedA)
  }

  func testMockAccountsNeverReadDesktopAuthentication() throws {
    let synchronizer = ActiveAccountCredentialSynchronizer(
      activeAuthenticationURL: URL(fileURLWithPath: "/nonexistent-fixture/auth.json"),
      accountsRootURL: URL(fileURLWithPath: "/nonexistent-fixture/Accounts")
    )
    XCTAssertNil(try synchronizer.synchronize(accounts: MockAccountCatalog.accounts()))
  }
}

private struct CredentialFixture {
  let root: URL
  let accountsRoot: URL
  let active: URL
  let profileA: URL
  let profileB: URL
  let savedA: Data
  let savedB: Data
  let activeA: Data
  let accounts: [AccountRecord]

  var synchronizer: ActiveAccountCredentialSynchronizer {
    ActiveAccountCredentialSynchronizer(activeAuthenticationURL: active, accountsRootURL: accountsRoot)
  }

  init() throws {
    root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("switchgpt-credential-fixture-" + UUID().uuidString)
    accountsRoot = root.appendingPathComponent("Accounts")
    active = root.appendingPathComponent("active/auth.json")
    profileA = accountsRoot.appendingPathComponent(UUID().uuidString + "/auth.json")
    profileB = accountsRoot.appendingPathComponent(UUID().uuidString + "/auth.json")
    savedA = try Self.authentication(email: "a@example.test", generation: "old-a")
    savedB = try Self.authentication(email: "b@example.test", generation: "old-b")
    activeA = try Self.authentication(email: "a@example.test", generation: "new-a")
    try Self.write(savedA, to: profileA)
    try Self.write(savedB, to: profileB)
    try Self.write(activeA, to: active)
    let usage = AccountUsage(weekly: UsageWindow(usedPercent: 10, resetAt: Date()))
    accounts = try [profileA, profileB].enumerated().map { index, profile in
      AccountRecord(
        id: AccountID("fixture-\(index)"), displayName: "Fixture \(index)", detail: "",
        planName: "Plus", symbolName: "person", accent: .blue, usage: usage,
        source: .codexHome(path: profile.deletingLastPathComponent().path),
        identityHash: try PinnedAuthenticationIdentityReader(authenticationFileURL: profile)
          .currentIdentity().rawValue
      )
    }
  }

  @MainActor
  func store() -> SwitchGPTAppStore {
    SwitchGPTAppStore(
      quotaReader: FixtureCredentialQuotaReader(expectedActiveA: activeA),
      accountProbe: FixtureCredentialProbe(identityHash: accounts[0].identityHash!),
      initialAccounts: accounts, credentialSynchronizer: synchronizer
    )
  }

  func accountA(in directory: URL) -> AccountRecord {
    let original = accounts[0]
    return AccountRecord(
      id: original.id, displayName: original.displayName, detail: original.detail,
      planName: original.planName, symbolName: original.symbolName, accent: original.accent,
      usage: original.usage, source: .codexHome(path: directory.path),
      identityHash: original.identityHash
    )
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  static func authentication(email: String, generation: String) throws -> Data {
    let payload = try JSONSerialization.data(withJSONObject: ["email": email]).base64EncodedString()
    return try JSONSerialization.data(withJSONObject: [
      "tokens": ["id_token": "fixture.\(payload).fixture", "access_token": generation]
    ], options: [.sortedKeys])
  }

  static func write(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try data.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

private struct FixtureCredentialQuotaReader: QuotaReading {
  let expectedActiveA: Data
  func fetchSnapshots(for accounts: [AccountRecord]) async throws -> [AccountID: AccountQuotaSnapshot] {
    var snapshots: [AccountID: AccountQuotaSnapshot] = [:]
    for account in accounts {
      guard case .codexHome(let path) = account.source else { continue }
      let saved = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("auth.json"))
      // A's old credentials fail exactly like the original regression; B remains usable.
      if account.id == AccountID("fixture-0"), saved != expectedActiveA { continue }
      snapshots[account.id] = AccountQuotaSnapshot(
        planName: "Plus", usage: AccountUsage(weekly: UsageWindow(usedPercent: 20, resetAt: Date()))
      )
    }
    return snapshots
  }
}

private struct FixtureCredentialProbe: ReadOnlyAccountProbing {
  let identityHash: String
  func probe(codexHomePath: String) async throws -> ReadOnlyAccountProbe {
    ReadOnlyAccountProbe(
      identityHash: identityHash, email: "a@example.test", planName: "Plus",
      usage: AccountUsage(weekly: UsageWindow(usedPercent: 20, resetAt: Date()))
    )
  }
}
