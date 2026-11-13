import Foundation
import SwitchGPTAppCore
import SwitchGPTDesktopIntegration
import SwitchGPTSafetyCore
import XCTest

final class BackgroundUsageRefreshTests: XCTestCase {
  func testRefreshKeepsRotatedCredentialsWhenQuotaFails() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let result = try await fixture.refresh.run()

    XCTAssertEqual(result.updatedCount, 1)
    XCTAssertEqual(result.failedCount, 1)
    XCTAssertEqual(result.renewedCount, 1)
    XCTAssertEqual(try Data(contentsOf: fixture.active), fixture.activeAuth)
    XCTAssertEqual(try Data(contentsOf: fixture.inactive), fixture.renewedAuth)
    let saved = try fixture.snapshots.overlay(on: fixture.accounts).accounts
    XCTAssertEqual(saved[0].usage.weekly.usedPercent, 12)
    XCTAssertEqual(saved[1].usage, fixture.accounts[1].usage)
  }

  func testSharedLoginUsesAccessOnly() async throws {
    let fixture = try Fixture(sharedLogin: true)
    defer { fixture.remove() }
    let result = try await fixture.refresh.run()

    XCTAssertEqual(result.updatedCount, 2)
    XCTAssertEqual(result.renewedCount, 0)
    XCTAssertEqual(try Data(contentsOf: fixture.inactive), fixture.inactiveAuth)
  }

  func testCredentialLockExcludesASecondJob() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let lock = try AccountCredentialLock.acquire(appDirectory: fixture.root)
    defer { lock.release() }

    do {
      _ = try await fixture.refresh.run()
      XCTFail("A second writer acquired the credential lock")
    } catch SafetyError.lockUnavailable {
      XCTAssertEqual(try Data(contentsOf: fixture.inactive), fixture.inactiveAuth)
    }
  }

  private struct Fixture {
    let root: URL
    let active: URL
    let inactive: URL
    let activeAuth: Data
    let inactiveAuth: Data
    let renewedAuth: Data
    let accounts: [AccountRecord]
    let snapshots: BackgroundUsageSnapshotStore
    let refresh: BackgroundUsageRefresh

    init(sharedLogin: Bool = false) throws {
      root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("switchgpt-job-" + UUID().uuidString, isDirectory: true)
      let accountsRoot = root.appendingPathComponent("Accounts", isDirectory: true)
      let archivedActive = accountsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
      let archivedInactive = accountsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
      active = root.appendingPathComponent("desktop/auth.json")
      inactive = archivedInactive.appendingPathComponent("auth.json")
      let activeEmail = "active@example.test"
      let inactiveEmail = "inactive@example.test"
      activeAuth = try Self.authentication(email: activeEmail, name: "active", refresh: "token-a")
      inactiveAuth = try Self.authentication(
        email: inactiveEmail, name: "inactive", refresh: sharedLogin ? "token-a" : "token-b")
      renewedAuth = try Self.authentication(
        email: inactiveEmail, name: "inactive", refresh: "rotated-b", lastRefresh: "2026-11-14T13:00:00Z")
      try Self.write(activeAuth, to: active)
      try Self.write(activeAuth, to: archivedActive.appendingPathComponent("auth.json"))
      try Self.write(inactiveAuth, to: inactive)
      let renewal = root.appendingPathComponent("renewal.json")
      try Self.write(renewedAuth, to: renewal)
      let fixtureBinary = root.appendingPathComponent("codex-fixture")
      let renewalPath = String(decoding: try JSONEncoder().encode(renewal.path), as: UTF8.self)
      let binaryScript = """
        #!/usr/bin/env python3
        import json, os, shutil, sys
        managed = sys.argv[2] == 'cli_auth_credentials_store="file"'
        for line in sys.stdin:
            request = json.loads(line)
            if "id" not in request:
                continue
            method = request["method"]
            response = {"id": request["id"], "result": {}}
            if method == "account/login/start":
                response["result"] = {"type": "chatgptAuthTokens"}
            if method == "account/read":
                account = {"type": "chatgpt", "planType": "pro"}
                if managed:
                    shutil.copyfile(json.loads(r'''\(renewalPath)'''), os.path.join(os.environ["CODEX_HOME"], "auth.json"))
                    account["email"] = "inactive@example.test"
                response["result"] = {"account": account}
            if method == "account/rateLimits/read":
                if managed:
                    response["error"] = {"code": -32603, "message": "fixture quota failure"}
                else:
                    response["result"] = {"rateLimits": {"primary": {
                        "usedPercent": 12, "windowDurationMins": 10080, "resetsAt": 1900000000,
                    }}}
            print(json.dumps(response), flush=True)
        """
      try binaryScript.write(to: fixtureBinary, atomically: false, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixtureBinary.path)
      let stateStore = PreviewStateFileStore(fileURL: root.appendingPathComponent("preview-state.json"))
      snapshots = BackgroundUsageSnapshotStore(fileURL: root.appendingPathComponent("usage/cache.json"))
      accounts = try [(archivedActive, activeAuth), (archivedInactive, inactiveAuth)].enumerated()
        .map { index, profile in
          AccountRecord(
            id: AccountID("fixture-\(index)"), displayName: "Fixture \(index)", detail: "",
            planName: "Pro", symbolName: "person", accent: .blue,
            usage: AccountUsage(weekly: UsageWindow(usedPercent: 30, resetAt: Date())),
            source: .codexHome(path: profile.0.path),
            identityHash: try PinnedAuthenticationIdentityReader.identity(
              fromAuthenticationData: profile.1).rawValue)
        }
      try stateStore.save(PreviewState(accounts: accounts, currentAccountID: accounts[0].id))
      refresh = BackgroundUsageRefresh(
        reader: CodexAppServerQuotaReader(
          codexBinaryURL: fixtureBinary, timeout: .seconds(2), includeTokenActivity: false),
        stateStore: stateStore, snapshotStore: snapshots,
        credentialSynchronizer: ActiveAccountCredentialSynchronizer(
          activeAuthenticationURL: active, accountsRootURL: accountsRoot))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    static func write(_ data: Data, to url: URL) throws {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try data.write(to: url)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func authentication(
      email: String, name: String, refresh: String, lastRefresh: String = "2026-11-13T13:00:00Z"
    ) throws -> Data {
      let workspace = "workspace-" + name
      let jwt = "fixture." + (try JSONSerialization.data(withJSONObject: [
        "email": email, "https://api.openai.com/auth": [
          "chatgpt_user_id": "user-" + name, "chatgpt_account_id": workspace,
        ],
      ])).base64EncodedString() + ".fixture"
      return try JSONSerialization.data(withJSONObject: [
        "auth_mode": "chatgpt", "last_refresh": lastRefresh,
        "tokens": ["id_token": jwt, "access_token": jwt, "account_id": workspace, "refresh_token": refresh],
      ], options: [.sortedKeys])
    }
  }
}
