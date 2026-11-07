import CryptoKit
import Foundation
import XCTest

@testable import SwitchGPTDesktopIntegration

final class LocalProjectStateTests: XCTestCase {
  private var temporaryDirectories: [URL] = []

  override func tearDownWithError() throws {
    for directory in temporaryDirectories {
      try? FileManager.default.removeItem(at: directory)
    }
    temporaryDirectories.removeAll()
  }

  func testFirstSwitchPreservesIndependentProjectsAndAccountSpecificState() throws {
    let fixture = try makeFixture(
      sourceProjects: [
        project("source", name: "Source project"),
        project("shared", name: "Active source version"),
        project("g-p-source-cloud", name: "Source cloud mirror"),
      ],
      targetProjects: [
        project("target", name: "Target project"),
        project("shared", name: "Stale target version"),
        project("g-p-target-cloud", name: "Target cloud mirror"),
      ]
    )
    try fixture.editActiveGlobals { globals in
      globals["pinned-project-ids"] = ["source", "g-p-source-cloud"]
      globals["project-appearances"] = ["g-p-source-cloud": ["color": "source-cloud-color"]]
      globals["thread-project-assignments"] = [
        "source-cloud-thread": ["projectKind": "cloud", "projectId": "g-p-source-cloud"]
      ]
      globals["thread-project-membership-host-ids"] = ["source-cloud-thread": "source-cloud-host"]
      globals["app-server-project-id-by-legacy-project-id-by-host"] = [
        "local": ["g-p-source-cloud": "source-cloud-native-id"]
      ]
    }
    var original = try fixture.readState()
    var sourceAtoms = original["electron-persisted-atom-state"] as! [String: Any]
    sourceAtoms["unified-sidebar-project-order-v1"] = ["chatgpt:project:g-p-source-cloud", "codex:project:source"]
    sourceAtoms["unified-sidebar-pinned-order-v1"] = ["chatgpt:thread:source-cloud-thread", "codex:project:source"]
    original["electron-persisted-atom-state"] = sourceAtoms
    try fixture.writeState(original)

    try fixture.prepare(from: .a, to: .b)

    let prepared = try fixture.readState()
    XCTAssertEqual(fixture.owner(in: prepared), fixture.account(.a).owner)
    XCTAssertEqual(try fixture.projectIDs(for: .b), ["g-p-target-cloud", "shared", "source", "target"])
    XCTAssertEqual(try fixture.projectIDs(for: .a), ["g-p-source-cloud", "shared", "source", "target"])
    XCTAssertEqual(try fixture.project("shared", for: .b)["name"] as? String, "Active source version")
    assertJSONEqual(
      try fixture.snapshot(for: .b)["atoms"],
      try fixture.snapshot(for: .b, in: original)["atoms"],
      excluding: localProjectAtomKeys
    )
    let atoms = try XCTUnwrap(prepared["electron-persisted-atom-state"] as? [String: Any])
    let originalAtoms = try XCTUnwrap(original["electron-persisted-atom-state"] as? [String: Any])
    for key in ["local-document-identity", "composer-prompt-drafts-v2", "localeOverride", "chatgpt-sidebar-state-v2"] {
      assertJSONEqual(atoms[key], originalAtoms[key])
    }
    assertJSONEqual(prepared["unrelated-global"], original["unrelated-global"])
    XCTAssertTrue((prepared["pinned-project-ids"] as? [String] ?? []).contains("g-p-source-cloud"))
    assertJSONEqual(prepared["project-appearances"], original["project-appearances"])
    assertJSONEqual(prepared["thread-project-membership-host-ids"], original["thread-project-membership-host-ids"])
    assertJSONEqual(prepared["app-server-project-id-by-legacy-project-id-by-host"], original["app-server-project-id-by-legacy-project-id-by-host"])
    XCTAssertTrue((atoms["unified-sidebar-project-order-v1"] as? [String] ?? []).contains("chatgpt:project:g-p-source-cloud"))
    XCTAssertTrue((atoms["unified-sidebar-pinned-order-v1"] as? [String] ?? []).contains("chatgpt:thread:source-cloud-thread"))
    let target = try fixture.globals(for: .b)
    XCTAssertFalse((target["pinned-project-ids"] as? [String] ?? []).contains("g-p-source-cloud"))
  }

  func testEditsDeletionsMembershipMovesAndUnpinsSurviveRoundTrips() throws {
    let fixture = try makeFixture(
      sourceProjects: [project("removed"), project("kept")],
      targetProjects: []
    )
    try fixture.editActiveGlobals { globals in
      globals["thread-project-assignments"] = [
        "moving-thread": ["projectKind": "local", "projectId": "removed"]
      ]
      globals["pinned-project-ids"] = ["removed", "kept"]
      globals["project-order"] = ["removed", "kept"]
      globals["sidebar-project-thread-orders"] = ["removed": ["moving-thread"]]
    }
    try fixture.prepare(from: .a, to: .b)
    try fixture.selectOwner(.b)
    try fixture.editActiveGlobals { globals in
      var projects = globals["local-projects"] as! [String: Any]
      projects.removeValue(forKey: "removed")
      projects["kept"] = self.project("kept", name: "Renamed", roots: ["/fixture/new-root"])
      projects["added"] = self.project("added", name: "Created while using B")
      globals["local-projects"] = projects
      globals["thread-project-assignments"] = [
        "moving-thread": ["projectKind": "local", "projectId": "kept"]
      ]
      globals["pinned-project-ids"] = [] as [String]
      globals["project-order"] = ["added", "kept"]
      globals["sidebar-project-thread-orders"] = ["kept": ["moving-thread"]]
    }

    try fixture.prepare(from: .b, to: .a)
    try fixture.selectOwner(.a)

    XCTAssertEqual(try fixture.projectIDs(for: .a), ["added", "kept"])
    let kept = try fixture.project("kept", for: .a)
    XCTAssertEqual(kept["name"] as? String, "Renamed")
    XCTAssertEqual(kept["rootPaths"] as? [String], ["/fixture/new-root"])
    let restored = try fixture.globals(for: .a)
    assertJSONEqual(restored["thread-project-assignments"], [
      "moving-thread": ["projectKind": "local", "projectId": "kept"]
    ])
    XCTAssertEqual(restored["pinned-project-ids"] as? [String], [])
    XCTAssertEqual(restored["project-order"] as? [String], ["added", "kept"])
    assertJSONEqual(restored["sidebar-project-thread-orders"], ["kept": ["moving-thread"]])

    try fixture.prepare(from: .a, to: .b)
    XCTAssertEqual(try fixture.projectIDs(for: .b), ["added", "kept"])
    XCTAssertEqual(try fixture.globals(for: .b)["pinned-project-ids"] as? [String], [])
    try fixture.selectOwner(.b)
    try fixture.editActiveGlobals { globals in
      globals["pinned-project-ids"] = ["kept"]
    }
    try fixture.prepare(from: .b, to: .a)
    XCTAssertEqual(try fixture.globals(for: .a)["pinned-project-ids"] as? [String], ["kept"])
  }

  func testDeletedProjectDoesNotReturnFromNeverSyncedThirdAccount() throws {
    let fixture = try makeFixture(
      sourceProjects: [project("deleted"), project("kept")],
      targetProjects: [],
      thirdProjects: [project("deleted"), project("third-only")]
    )
    try fixture.editActiveGlobals { globals in
      globals["thread-project-assignments"] = [
        "moving-thread": ["projectKind": "local", "projectId": "deleted"]
      ]
    }
    var state = try fixture.readState()
    var registry = state["electron-account-renderer-state-v1"] as! [String: Any]
    var inactive = registry["inactive"] as! [String: Any]
    var third = inactive[fixture.account(.c).owner] as! [String: Any]
    var thirdGlobals = third["globals"] as! [String: Any]
    thirdGlobals["thread-project-assignments"] = [
      "moving-thread": ["projectKind": "local", "projectId": "third-only"]
    ]
    third["globals"] = thirdGlobals
    inactive[fixture.account(.c).owner] = third
    registry["inactive"] = inactive
    state["electron-account-renderer-state-v1"] = registry
    try fixture.writeState(state)
    try fixture.prepare(from: .a, to: .b)
    try fixture.selectOwner(.b)
    try fixture.editActiveGlobals { globals in
      var projects = globals["local-projects"] as! [String: Any]
      projects.removeValue(forKey: "deleted")
      globals["local-projects"] = projects
      globals["thread-project-assignments"] = [
        "moving-thread": ["projectKind": "local", "projectId": "kept"]
      ]
    }

    try fixture.prepare(from: .b, to: .c)

    XCTAssertEqual(try fixture.projectIDs(for: .c), ["kept", "third-only"])
    assertJSONEqual(try fixture.globals(for: .c)["thread-project-assignments"], [
      "moving-thread": ["projectKind": "local", "projectId": "kept"]
    ])
    try fixture.selectOwner(.c)
    try fixture.prepare(from: .c, to: .a)
    XCTAssertEqual(try fixture.projectIDs(for: .a), ["kept", "third-only"])
    try fixture.selectOwner(.a)
    try fixture.editActiveGlobals { globals in
      var projects = globals["local-projects"] as! [String: Any]
      projects["deleted"] = self.project("deleted", name: "Deliberately recreated")
      globals["local-projects"] = projects
    }
    try fixture.prepare(from: .a, to: .b)
    XCTAssertEqual(try fixture.projectIDs(for: .b), ["deleted", "kept", "third-only"])
    XCTAssertEqual(try fixture.project("deleted", for: .b)["name"] as? String, "Deliberately recreated")
  }

  func testIndependentProjectFieldEditsMergeWithoutOverwritingEitherSide() throws {
    let fixture = try makeFixture(
      sourceProjects: [project("shared", name: "Original", roots: ["/fixture/original"])],
      targetProjects: []
    )
    try fixture.prepare(from: .a, to: .b)
    try fixture.selectOwner(.b)
    try fixture.editProject("shared") { project in
      project["rootPaths"] = ["/fixture/changed-in-b"]
    }
    // Simulate selecting A outside SwitchGPT after B has saved its changes.
    try fixture.selectOwner(.a)
    try fixture.editProject("shared") { project in
      project["name"] = "Renamed in A"
    }

    try fixture.prepare(from: .a, to: .b)

    let result = try fixture.project("shared", for: .b)
    XCTAssertEqual(result["name"] as? String, "Renamed in A")
    XCTAssertEqual(result["rootPaths"] as? [String], ["/fixture/changed-in-b"])
  }

  func testEmptyTrackedSourceDeletesAllProjectsInsteadOfRestoringStaleDestination() throws {
    let fixture = try makeFixture(sourceProjects: [project("deleted")], targetProjects: [])
    try fixture.prepare(from: .a, to: .b)
    try fixture.selectOwner(.b)
    try fixture.editActiveGlobals { globals in
      globals["local-projects"] = [:] as [String: Any]
    }

    try fixture.prepare(from: .b, to: .a)

    XCTAssertEqual(try fixture.projectIDs(for: .a), [])
  }

  func testSourceSnapshotCanBeReadAfterDesktopClearsActiveOwnerOnExit() throws {
    let fixture = try makeFixture(sourceProjects: [project("source")], targetProjects: [])
    try fixture.selectOwner(nil)

    try fixture.prepare(from: .a, to: .b)

    let state = try fixture.readState()
    XCTAssertNil(fixture.owner(in: state))
    XCTAssertEqual(try fixture.projectIDs(for: .b), ["source"])
    XCTAssertEqual(try fixture.projectIDs(for: .a), ["source"])
    XCTAssertNil(state["local-projects"])
  }

  func testRendererScopesRemainDistinctWhenAccountsShareAnEmail() throws {
    let fixture = try makeFixture(sourceProjects: [project("source")], targetProjects: [])
    let targetAuthenticationURL = fixture.account(.b).authenticationURL
    var authentication = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: targetAuthenticationURL)) as? [String: Any]
    )
    let header = Data("{\"alg\":\"none\"}".utf8).base64EncodedString()
    let payload = try JSONSerialization.data(withJSONObject: [
      "email": "a@example.test",
      "https://api.openai.com/auth": [
        "chatgpt_user_id": fixture.account(.b).userID,
        "chatgpt_account_id": fixture.account(.b).accountID,
      ],
    ]).base64EncodedString()
    authentication["tokens"] = [
      "id_token": "\(header).\(payload).fixture",
      "account_id": fixture.account(.b).accountID,
    ]
    try fixture.writePrivate(
      try JSONSerialization.data(withJSONObject: authentication),
      to: targetAuthenticationURL
    )

    try fixture.prepare(from: .a, to: .b)

    XCTAssertNotEqual(fixture.account(.a).owner, fixture.account(.b).owner)
    XCTAssertEqual(try fixture.projectIDs(for: .b), ["source"])
    let targetAtoms = try XCTUnwrap(try fixture.snapshot(for: .b)["atoms"] as? [String: Any])
    XCTAssertEqual(
      (targetAtoms["local-document-identity"] as? [String: String])?["accountId"],
      fixture.account(.b).accountID
    )
  }

  func testMalformedStateFailsBeforeChangingGlobalOrSharedFiles() throws {
    let fixture = try makeFixture(sourceProjects: [project("source")], targetProjects: [])
    var original = try fixture.readState()
    let malformed = Data("{not-valid-json".utf8)
    try fixture.writePrivate(malformed, to: fixture.globalStateURL)

    XCTAssertThrowsError(try fixture.prepare(from: .a, to: .b))

    XCTAssertEqual(try Data(contentsOf: fixture.globalStateURL), malformed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sharedStateURL.path))

    original["local-projects"] = ["source": ["id": "source", "name": "Invalid roots", "rootPaths": 42]]
    try fixture.writeState(original)
    let malformedRecord = try Data(contentsOf: fixture.globalStateURL)
    XCTAssertThrowsError(try fixture.prepare(from: .a, to: .b))
    XCTAssertEqual(try Data(contentsOf: fixture.globalStateURL), malformedRecord)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sharedStateURL.path))
  }

  func testDesktopGlobalStateWithStandardPermissionsCanBeSynchronized() throws {
    let fixture = try makeFixture(sourceProjects: [project("source")], targetProjects: [])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: fixture.globalStateURL.deletingLastPathComponent().path
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: fixture.globalStateURL.path
    )

    try fixture.prepare(from: .a, to: .b)

    XCTAssertEqual(try fixture.projectIDs(for: .b), ["source"])
  }

  func testProjectlessWritableRootsSurviveSynchronization() throws {
    let fixture = try makeFixture(sourceProjects: [project("source")], targetProjects: [])
    try fixture.editActiveGlobals { globals in
      globals["projectless-thread-ids"] = ["unassigned-thread"]
      globals["thread-writable-roots"] = ["unassigned-thread": ["/fixture/current-draft-workspace"]]
    }

    try fixture.prepare(from: .a, to: .b)

    assertJSONEqual(try fixture.globals(for: .a)["thread-writable-roots"], [
      "unassigned-thread": ["/fixture/current-draft-workspace"]
    ])
    assertJSONEqual(try fixture.globals(for: .b)["thread-writable-roots"], [
      "unassigned-thread": ["/fixture/current-draft-workspace"]
    ])
  }

  func testMissingStateAndLegacyStateWithoutOwnerRegistryRemainUntouched() throws {
    let fixture = try makeFixture(sourceProjects: [], targetProjects: [])
    try FileManager.default.removeItem(at: fixture.globalStateURL)
    try fixture.prepare(from: .a, to: .b)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.globalStateURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sharedStateURL.path))

    let legacy: [String: Any] = ["unrelated-global": ["keep": true]]
    try fixture.writeState(legacy)
    let before = try Data(contentsOf: fixture.globalStateURL)
    try fixture.prepare(from: .a, to: .b)
    XCTAssertEqual(try Data(contentsOf: fixture.globalStateURL), before)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sharedStateURL.path))
  }

  func testRepeatedPreparationAndFreshProcessRecoveryPreserveSourceAndDrafts() throws {
    let fixture = try makeFixture(sourceProjects: [project("source")], targetProjects: [project("target")])
    let transaction = fixture.nextTransactionURL()
    let synchronizer = fixture.synchronizer(transaction: transaction)
    try synchronizer.prepareSwitch(
      sourceAuthenticationURL: fixture.account(.a).authenticationURL,
      targetAuthenticationURL: fixture.account(.b).authenticationURL
    )
    let first = try fixture.readState()
    try synchronizer.prepareSwitch(
      sourceAuthenticationURL: fixture.account(.a).authenticationURL,
      targetAuthenticationURL: fixture.account(.b).authenticationURL
    )
    assertJSONEqual(try fixture.readState(), first)
    try fixture.selectOwner(.b)
    try fixture.editActiveGlobals { globals in
      var projects = globals["local-projects"] as! [String: Any]
      projects["target-runtime-addition"] = self.project("target-runtime-addition")
      globals["local-projects"] = projects
    }
    let beforeRecovery = try fixture.readState()

    let recovery = fixture.synchronizer(transaction: transaction)
    try recovery.recoverSource(sourceAuthenticationURL: fixture.account(.a).authenticationURL)
    XCTAssertTrue(try fixture.projectIDs(for: .a).contains("source"))
    XCTAssertTrue(try fixture.projectIDs(for: .a).contains("target-runtime-addition"))
    let recovered = try fixture.readState()
    let sourceAtoms = try XCTUnwrap(try fixture.snapshot(for: .a)["atoms"] as? [String: Any])
    XCTAssertEqual(
      (sourceAtoms["local-document-identity"] as? [String: String])?["accountId"],
      fixture.account(.a).accountID
    )
    assertJSONEqual(sourceAtoms["composer-prompt-drafts-v2"], ["draft-a": "Unsent A draft"])
    // Replay a durable recovery intent whose global-state write did not reach disk.
    try fixture.writeState(beforeRecovery)
    let resumedRecovery = fixture.synchronizer(transaction: transaction)
    try resumedRecovery.recoverSource(sourceAuthenticationURL: fixture.account(.a).authenticationURL)
    assertJSONEqual(try fixture.readState(), recovered)
    try resumedRecovery.recoverSource(sourceAuthenticationURL: fixture.account(.a).authenticationURL)
    assertJSONEqual(try fixture.readState(), recovered)
  }

  private func makeFixture(
    sourceProjects: [[String: Any]],
    targetProjects: [[String: Any]],
    thirdProjects: [[String: Any]] = []
  ) throws -> LocalProjectFixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("switchgpt-project-state-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    temporaryDirectories.append(directory)
    let fixture = LocalProjectFixture(root: directory)
    try fixture.initialize(sourceProjects: sourceProjects, targetProjects: targetProjects, thirdProjects: thirdProjects)
    return fixture
  }

  private func project(
    _ id: String,
    name: String? = nil,
    roots: [String] = ["/fixture/root"]
  ) -> [String: Any] {
    ["id": id, "name": name ?? id, "rootPaths": roots, "createdAt": 1, "updatedAt": 1]
  }

  private func assertJSONEqual(
    _ actual: Any?,
    _ expected: Any?,
    excluding keys: Set<String> = [],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    var actual = actual
    var expected = expected
    if let dictionary = actual as? [String: Any] {
      actual = dictionary.filter { !keys.contains($0.key) }
    }
    if let dictionary = expected as? [String: Any] {
      expected = dictionary.filter { !keys.contains($0.key) }
    }
    let actualData = try? JSONSerialization.data(withJSONObject: actual ?? NSNull(), options: [.sortedKeys, .fragmentsAllowed])
    let expectedData = try? JSONSerialization.data(withJSONObject: expected ?? NSNull(), options: [.sortedKeys, .fragmentsAllowed])
    XCTAssertEqual(actualData, expectedData, file: file, line: line)
  }
}

private let localProjectGlobalKeys = [
  "local-projects", "pinned-project-ids", "pinned-thread-ids", "project-order",
  "thread-project-assignments", "thread-project-membership-host-ids",
  "thread-writable-roots", "project-appearances",
  "app-server-project-id-by-legacy-project-id-by-host",
  "sidebar-project-thread-orders", "thread-projectless-output-directories",
  "thread-workspace-root-hints", "projectless-thread-ids", "selected-project",
]

private let localProjectAtomKeys: Set<String> = [
  "unified-sidebar-project-order-v1", "unified-sidebar-pinned-order-v1",
  "app-server-pinned-thread-order-v1", "flat-project-sidebar-preferences-v1",
  "pinned-sidebar-sort-mode-v1", "sidebar-project-list-expanded-v1",
]

private enum LocalProjectAccount: String, CaseIterable { case a, b, c }

private struct LocalProjectAccountFixture {
  let accountID: String
  let userID: String
  let owner: String
  let authenticationURL: URL
}

private struct LocalProjectFixture {
  let root: URL

  var globalStateURL: URL { root.appendingPathComponent(".codex/.codex-global-state.json") }
  var sharedStateURL: URL { root.appendingPathComponent("shared-project-state.json") }

  func account(_ name: LocalProjectAccount) -> LocalProjectAccountFixture {
    let userID = "user-fixture-\(name.rawValue)"
    let accountID = "workspace-fixture-\(name.rawValue)"
    let bytes = try! JSONSerialization.data(withJSONObject: [userID, accountID], options: [.fragmentsAllowed])
    let owner = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    return LocalProjectAccountFixture(
      accountID: accountID,
      userID: userID,
      owner: owner,
      authenticationURL: root.appendingPathComponent("auth-\(name.rawValue).json")
    )
  }

  func initialize(
    sourceProjects: [[String: Any]],
    targetProjects: [[String: Any]],
    thirdProjects: [[String: Any]]
  ) throws {
    for name in LocalProjectAccount.allCases {
      let identity = account(name)
      let header = base64URL(Data("{\"alg\":\"none\"}".utf8))
      let payload = base64URL(try JSONSerialization.data(withJSONObject: [
        "email": "\(name.rawValue)@example.test",
        "https://api.openai.com/auth": [
          "chatgpt_user_id": identity.userID,
          "chatgpt_account_id": identity.accountID,
        ],
      ]))
      let authentication: [String: Any] = [
        "tokens": ["id_token": "\(header).\(payload).fixture", "account_id": identity.accountID]
      ]
      try writePrivate(try JSONSerialization.data(withJSONObject: authentication), to: identity.authenticationURL)
    }
    let source = snapshot(.a, projects: sourceProjects)
    var state = source["globals"] as! [String: Any]
    state["unrelated-global"] = ["keep": "untouched"]
    state["electron-persisted-atom-state"] = source["atoms"]
    state["electron-account-renderer-state-v1"] = [
      "owner": account(.a).owner,
      "inactive": [
        account(.b).owner: snapshot(.b, projects: targetProjects),
        account(.c).owner: snapshot(.c, projects: thirdProjects),
      ],
    ]
    try writeState(state)
  }

  func snapshot(_ name: LocalProjectAccount, projects: [[String: Any]]) -> [String: Any] {
    let identity = account(name)
    return [
      "atoms": [
        "local-document-identity": ["userId": identity.userID, "accountId": identity.accountID],
        "composer-prompt-drafts-v2": ["draft-\(name.rawValue)": "Unsent \(name.rawValue.uppercased()) draft"],
        "localeOverride": "zh-CN",
        "chatgpt-sidebar-state-v2": [identity.accountID: ["projects": [["id": "g-p-cloud-\(name.rawValue)", "name": "Cloud project"]]]],
      ],
      "globals": [
        "local-projects": Dictionary(uniqueKeysWithValues: projects.map { ($0["id"] as! String, $0) }),
        "thread-project-assignments": [:] as [String: Any],
        "pinned-project-ids": [] as [String],
        "pinned-thread-ids": [] as [String],
        "project-order": projects.map { $0["id"] as! String },
        "sidebar-project-thread-orders": [:] as [String: Any],
      ],
    ]
  }

  func prepare(from source: LocalProjectAccount, to target: LocalProjectAccount) throws {
    try synchronizer(transaction: nextTransactionURL()).prepareSwitch(
      sourceAuthenticationURL: account(source).authenticationURL,
      targetAuthenticationURL: account(target).authenticationURL
    )
  }

  func nextTransactionURL() -> URL {
    root.appendingPathComponent("transaction-\(UUID().uuidString)", isDirectory: true)
  }

  func synchronizer(transaction: URL) -> LocalProjectStateSynchronizer {
    LocalProjectStateSynchronizer(
      globalStateURL: globalStateURL,
      sharedStateURL: sharedStateURL,
      transactionDirectoryURL: transaction
    )
  }

  func readState() throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: globalStateURL)) as? [String: Any])
  }

  func writeState(_ state: [String: Any]) throws {
    try writePrivate(try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), to: globalStateURL)
  }

  func writePrivate(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  func owner(in state: [String: Any]) -> String? {
    (state["electron-account-renderer-state-v1"] as? [String: Any])?["owner"] as? String
  }

  func snapshot(for name: LocalProjectAccount, in suppliedState: [String: Any]? = nil) throws -> [String: Any] {
    let state = try suppliedState ?? readState()
    if owner(in: state) == account(name).owner {
      return [
        "atoms": state["electron-persisted-atom-state"] ?? [:],
        "globals": state.filter { localProjectGlobalKeys.contains($0.key) },
      ]
    }
    let registry = try XCTUnwrap(state["electron-account-renderer-state-v1"] as? [String: Any])
    let inactive = try XCTUnwrap(registry["inactive"] as? [String: Any])
    return try XCTUnwrap(inactive[account(name).owner] as? [String: Any])
  }

  func globals(for name: LocalProjectAccount) throws -> [String: Any] {
    try XCTUnwrap(try snapshot(for: name)["globals"] as? [String: Any])
  }

  func projectIDs(for name: LocalProjectAccount) throws -> [String] {
    let projects = try XCTUnwrap(try globals(for: name)["local-projects"] as? [String: Any])
    return projects.keys.sorted()
  }

  func project(_ id: String, for name: LocalProjectAccount) throws -> [String: Any] {
    let projects = try XCTUnwrap(try globals(for: name)["local-projects"] as? [String: Any])
    return try XCTUnwrap(projects[id] as? [String: Any])
  }

  func editActiveGlobals(_ edit: (inout [String: Any]) -> Void) throws {
    var state = try readState()
    edit(&state)
    try writeState(state)
  }

  func editProject(_ id: String, edit: (inout [String: Any]) -> Void) throws {
    try editActiveGlobals { state in
      var projects = state["local-projects"] as! [String: Any]
      var project = projects[id] as! [String: Any]
      edit(&project)
      projects[id] = project
      state["local-projects"] = projects
    }
  }

  func selectOwner(_ name: LocalProjectAccount?) throws {
    var state = try readState()
    var registry = state["electron-account-renderer-state-v1"] as! [String: Any]
    var inactive = registry["inactive"] as! [String: Any]
    if let currentOwner = owner(in: state) {
      inactive[currentOwner] = [
        "atoms": state["electron-persisted-atom-state"] ?? [:],
        "globals": state.filter { localProjectGlobalKeys.contains($0.key) },
      ]
    }
    let selectedOwner = name.map { account($0).owner }
    let selected = selectedOwner.flatMap { inactive[$0] as? [String: Any] }
    if let selectedOwner { inactive.removeValue(forKey: selectedOwner) }
    for key in localProjectGlobalKeys { state.removeValue(forKey: key) }
    for (key, value) in selected?["globals"] as? [String: Any] ?? [:] { state[key] = value }
    state["electron-persisted-atom-state"] = selected?["atoms"] ?? [:]
    registry["owner"] = selectedOwner.map { $0 as Any } ?? NSNull()
    registry["inactive"] = inactive
    state["electron-account-renderer-state-v1"] = registry
    try writeState(state)
  }

  private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
