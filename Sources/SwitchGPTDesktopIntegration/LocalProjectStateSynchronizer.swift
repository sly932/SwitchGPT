import CryptoKit
import Darwin
import Foundation

public protocol LocalProjectStateSynchronizing: AnyObject {
  func prepareSwitch(sourceAuthenticationURL: URL, targetAuthenticationURL: URL) throws
  func recoverSource(sourceAuthenticationURL: URL) throws
}

public protocol LocalProjectAuthorityManaging: LocalProjectStateSynchronizing {
  func initializeActive(authenticationURL: URL) throws
  func captureActive(authenticationURL: URL) throws
  func prepareForExit(activeAuthenticationURL: URL, managedAuthenticationURLs: [URL]) throws
  func synchronizeAfterExit(activeAuthenticationURL: URL, managedAuthenticationURLs: [URL]) throws
  func verifyAfterExit(activeAuthenticationURL: URL, managedAuthenticationURLs: [URL]) throws
}

public enum LocalProjectStateSynchronizationError: Error, Equatable {
  case invalidState
  case unsafeStorage
  case identityUnavailable
  case identityMismatch
  case unsupportedSchema
  case transactionConflict
  case stateMismatch
  case missingVerification
}

/// Records changes from the verified active account and distributes that exact local subset.
/// Background capture changes only the private master. Switch verification never repairs state.
public final class LocalProjectStateSynchronizer: LocalProjectAuthorityManaging {
  private let globalStateURL: URL
  private let sharedStateURL: URL
  private let transactionDirectoryURL: URL
  private let registryKey = "electron-account-renderer-state-v1"
  private let atomsKey = "electron-persisted-atom-state"

  private static let mapKeys = [
    "local-projects", "app-server-project-id-by-legacy-project-id-by-host",
    "app-server-projects-migration-by-host", "project-appearances",
    "sidebar-project-thread-orders", "thread-project-assignments",
    "thread-project-membership-host-ids", "thread-writable-roots",
    "thread-workspace-root-hints", "thread-projectless-output-directories",
  ]
  private static let listKeys = [
    "project-order", "pinned-project-ids", "pinned-thread-ids", "projectless-thread-ids",
  ]
  private static let atomKeys = [
    "flat-project-sidebar-preferences-v1", "sidebar-project-list-expanded-v1",
    "pinned-sidebar-sort-mode-v1", "app-server-pinned-thread-order-v1",
    "unified-sidebar-project-order-v1", "unified-sidebar-pinned-order-v1",
  ]
  private static let expandedPrefix = "sidebar-project-expanded-v1-codex:"

  public init(globalStateURL: URL, sharedStateURL: URL, transactionDirectoryURL: URL) {
    self.globalStateURL = globalStateURL.standardizedFileURL
    self.sharedStateURL = sharedStateURL.standardizedFileURL
    self.transactionDirectoryURL = transactionDirectoryURL.standardizedFileURL
  }

  public func initializeActive(authenticationURL: URL) throws {
    try captureActive(authenticationURL: authenticationURL)
  }

  public func captureActive(authenticationURL: URL) throws {
    let owner = try rendererOwner(authenticationURL: authenticationURL)
    let lock = try acquireLock()
    defer { lock.release() }
    guard let (bytes, document) = try readDocument() else { return }
    try requireActiveOwner(owner, document: document)
    let before = try readMaster()
    let current = try snapshot(owner: owner, document: document)
    let master = try accepting(current, owner: owner, previous: before)
    guard master != before else { return }
    try backup(document: document, previous: before, operation: "capture")
    try requireUnchanged(bytes)
    try saveMaster(master)
  }

  public func prepareForExit(
    activeAuthenticationURL: URL, managedAuthenticationURLs: [URL]
  ) throws {
    let owner = try rendererOwner(authenticationURL: activeAuthenticationURL)
    let owners = try managedOwners(managedAuthenticationURLs, including: owner)
    let lock = try acquireLock()
    defer { lock.release() }
    guard let (bytes, document) = try readDocument() else { return }
    try requireActiveOwner(owner, document: document)
    for managed in owners { _ = try snapshot(owner: managed, document: document) }
    let before = try readMaster()
    let current = try snapshot(owner: owner, document: document)
    let master = try accepting(current, owner: owner, previous: before)
    try backup(document: document, previous: before, operation: "prepare-for-exit")
    try requireUnchanged(bytes)
    try saveMaster(master)
    let proof = ProjectVerificationProof(
      activeOwner: owner, managedOwners: owners, revision: master.revision,
      snapshotDigest: try digest(master.canonical), stage: .captured
    )
    try ProjectStateFile.prepareDirectory(transactionDirectoryURL)
    try writeRecord(proof, to: proofURL)
  }

  /// The caller must have fully stopped ChatGPT before distribution can begin.
  public func synchronizeAfterExit(
    activeAuthenticationURL: URL, managedAuthenticationURLs: [URL]
  ) throws {
    let owner = try rendererOwner(authenticationURL: activeAuthenticationURL)
    let owners = try managedOwners(managedAuthenticationURLs, including: owner)
    let lock = try acquireLock()
    defer { lock.release() }
    guard let (bytes, original) = try readDocument() else { return }
    var proof = try verifyCapturedSource(document: original, owner: owner, expectedOwners: owners)
    guard let master = try readMaster() else {
      throw LocalProjectStateSynchronizationError.missingVerification
    }
    // Inactive partitions are destinations. Their stale contents never supply authority.
    for managed in owners { _ = try snapshot(owner: managed, document: original) }
    var document = original
    for managed in owners { try apply(master.canonical, owner: managed, document: &document) }
    try requireEqualSubsets(document: document, owners: owners, canonical: master.canonical)
    try backup(document: original, previous: master, operation: "synchronize-after-exit")
    try commit(document: document, originalBytes: bytes, master: master)
    guard let (_, written) = try readDocument() else {
      throw LocalProjectStateSynchronizationError.stateMismatch
    }
    _ = try verifyCapturedSource(document: written, owner: owner, expectedOwners: owners)
    try requireEqualSubsets(document: written, owners: owners, canonical: master.canonical)
    proof.stage = .distributed
    try writeRecord(proof, to: proofURL)
  }

  @available(*, deprecated, message: "Use prepareForExit; distribution belongs in synchronizeAfterExit after ChatGPT stops.")
  public func synchronizeAndVerifyAll(
    activeAuthenticationURL: URL, managedAuthenticationURLs: [URL]
  ) throws {
    try prepareForExit(activeAuthenticationURL: activeAuthenticationURL, managedAuthenticationURLs: managedAuthenticationURLs)
  }

  public func verifyAfterExit(
    activeAuthenticationURL: URL, managedAuthenticationURLs: [URL]
  ) throws {
    let owner = try rendererOwner(authenticationURL: activeAuthenticationURL)
    let owners = try managedOwners(managedAuthenticationURLs, including: owner)
    let lock = try acquireLock()
    defer { lock.release() }
    guard let (_, document) = try readDocument() else { return }
    try verify(document: document, owner: owner, expectedOwners: owners)
  }

  public func prepareSwitch(sourceAuthenticationURL: URL, targetAuthenticationURL: URL) throws {
    let source = try rendererOwner(authenticationURL: sourceAuthenticationURL)
    let target = try rendererOwner(authenticationURL: targetAuthenticationURL)
    let lock = try acquireLock()
    defer { lock.release() }
    guard let (_, document) = try readDocument() else { return }
    guard source != target else { throw LocalProjectStateSynchronizationError.identityMismatch }
    let proof = try verify(document: document, owner: source, expectedOwners: nil)
    guard proof.managedOwners.contains(target), var master = try readMaster() else {
      throw LocalProjectStateSynchronizationError.identityMismatch
    }
    master.approvedNextOwner = target
    master.approvalRevision = proof.revision
    master.approvalSnapshotDigest = proof.snapshotDigest
    let journal = ProjectAuthorityJournal(
      sourceOwner: source, targetOwner: target, managedOwners: proof.managedOwners,
      prepared: master
    )
    try ProjectStateFile.prepareDirectory(transactionDirectoryURL)
    try writeRecord(journal, to: journalURL)
    try saveMaster(master)
  }

  public func recoverSource(sourceAuthenticationURL: URL) throws {
    let lock = try acquireLock()
    defer { lock.release() }
    var journal: ProjectAuthorityJournal? = try readRecord(journalURL)
    let proof: ProjectVerificationProof? = journal == nil ? try readRecord(proofURL) : nil
    guard journal != nil || proof != nil else { return }
    let source = try rendererOwner(authenticationURL: sourceAuthenticationURL)
    let expectedSource = journal?.sourceOwner ?? proof!.activeOwner
    let owners = journal?.managedOwners ?? proof!.managedOwners
    guard source == expectedSource else {
      throw LocalProjectStateSynchronizationError.identityMismatch
    }
    guard let (bytes, original) = try readDocument() else {
      throw LocalProjectStateSynchronizationError.invalidState
    }
    guard let before = try readMaster() ?? journal?.prepared else {
      throw LocalProjectStateSynchronizationError.missingVerification
    }
    var master = before
    if let approved = journal {
      if let active = original[registryKey]?.object?["owner"]?.string {
        guard active == source || active == approved.targetOwner else {
          throw LocalProjectStateSynchronizationError.identityMismatch
        }
        master = try accepting(snapshot(owner: active, document: original), owner: active, previous: master)
      }
    } else {
      // A failed exit check never authorized the target. A changed source may contain new
      // edits or stale shutdown data. Preserve both versions and require review of that state.
      guard master.activeOwner == source, master.revision == proof!.revision,
        try digest(master.canonical) == proof!.snapshotDigest
      else { throw LocalProjectStateSynchronizationError.stateMismatch }
      try requireSourceOwner(source, document: original)
      let finalSource = try snapshot(owner: source, document: original)
      if finalSource != master.canonical {
        try backup(document: original, previous: before, operation: "source-mismatch")
        try requireUnchanged(bytes)
        master.quarantinedOwner = source
        master.quarantineRevision = master.revision
        master.rejectedSnapshotDigest = try digest(finalSource)
        master.approvedNextOwner = nil
        master.approvalRevision = nil
        master.approvalSnapshotDigest = nil
        try saveMaster(master)
        return
      }
    }
    master.approvedNextOwner = nil
    master.approvalRevision = nil
    master.approvalSnapshotDigest = nil
    var document = original
    for owner in owners { try apply(master.canonical, owner: owner, document: &document) }
    try requireEqualSubsets(document: document, owners: owners, canonical: master.canonical)
    try backup(document: original, previous: before, operation: "recover")
    if journal != nil {
      journal!.prepared = master
      try writeRecord(journal!, to: journalURL)
    } else {
      let intent = ProjectSourceRecoveryIntent(sourceOwner: source, managedOwners: owners, prepared: master)
      try writeRecord(intent, to: transactionDirectoryURL.appendingPathComponent("local-project-source-recovery.json"))
    }
    try commit(document: document, originalBytes: bytes, master: master)
  }

  private var proofURL: URL {
    transactionDirectoryURL.appendingPathComponent("local-project-verification.json")
  }
  private var journalURL: URL {
    transactionDirectoryURL.appendingPathComponent("local-project-sync-journal.json")
  }

  private func acquireLock() throws -> ProjectStateLock {
    try ProjectStateFile.prepareDirectory(sharedStateURL.deletingLastPathComponent())
    return try ProjectStateLock(url: sharedStateURL.appendingPathExtension("lock"))
  }

  private func readDocument() throws -> (Data, [String: ProjectJSON])? {
    guard let bytes = try ProjectStateFile.readIfPresent(globalStateURL, requirePrivate: false) else {
      throw LocalProjectStateSynchronizationError.invalidState
    }
    let document = try object(bytes)
    guard document[registryKey] != nil else { return nil }
    try validateRegistry(document)
    return (bytes, document)
  }

  private func requireActiveOwner(_ owner: String, document: [String: ProjectJSON]) throws {
    guard document[registryKey]?.object?["owner"]?.string == owner else {
      throw LocalProjectStateSynchronizationError.identityMismatch
    }
  }

  private func accepting(
    _ current: ProjectSnapshot, owner: String, previous: ProjectAuthorityState?
  ) throws -> ProjectAuthorityState {
    guard var master = previous else {
      return ProjectAuthorityState(revision: 1, activeOwner: owner, canonical: current)
    }
    if master.quarantinedOwner == owner {
      guard master.canonical == current else {
        throw LocalProjectStateSynchronizationError.stateMismatch
      }
      master.quarantinedOwner = nil
      master.quarantineRevision = nil
      master.rejectedSnapshotDigest = nil
    }
    let canonicalDigest = try digest(master.canonical)
    let approvedHandoff = master.approvedNextOwner == owner
      && master.approvalRevision == master.revision
      && master.approvalSnapshotDigest == canonicalDigest
    if master.activeOwner != owner && master.canonical != current && !approvedHandoff {
      throw LocalProjectStateSynchronizationError.stateMismatch
    }
    if master.activeOwner != owner || master.canonical != current {
      master.revision += 1
      master.activeOwner = owner
      master.canonical = current
      master.approvedNextOwner = nil
      master.approvalRevision = nil
      master.approvalSnapshotDigest = nil
    }
    return master
  }

  private func managedOwners(_ urls: [URL], including active: String) throws -> [String] {
    guard !urls.isEmpty else { throw LocalProjectStateSynchronizationError.identityUnavailable }
    let owners = try urls.map { try rendererOwner(authenticationURL: $0) }
    guard Set(owners).count == owners.count, owners.contains(active) else {
      throw LocalProjectStateSynchronizationError.identityMismatch
    }
    return owners.sorted()
  }

  private func requireEqualSubsets(
    document: [String: ProjectJSON], owners: [String], canonical: ProjectSnapshot
  ) throws {
    for owner in owners {
      guard try snapshot(owner: owner, document: document) == canonical else {
        throw LocalProjectStateSynchronizationError.stateMismatch
      }
    }
  }

  private func verifyCapturedSource(
    document: [String: ProjectJSON], owner: String, expectedOwners: [String]?
  ) throws -> ProjectVerificationProof {
    guard let proof: ProjectVerificationProof = try readRecord(proofURL) else {
      throw LocalProjectStateSynchronizationError.missingVerification
    }
    guard proof.activeOwner == owner, expectedOwners == nil || expectedOwners == proof.managedOwners,
      let master = try readMaster(), master.activeOwner == owner,
      master.revision == proof.revision, try digest(master.canonical) == proof.snapshotDigest
    else { throw LocalProjectStateSynchronizationError.stateMismatch }
    try requireSourceOwner(owner, document: document)
    guard try snapshot(owner: owner, document: document) == master.canonical else {
      throw LocalProjectStateSynchronizationError.stateMismatch
    }
    return proof
  }

  @discardableResult
  private func verify(
    document: [String: ProjectJSON], owner: String, expectedOwners: [String]?
  ) throws -> ProjectVerificationProof {
    let proof = try verifyCapturedSource(document: document, owner: owner, expectedOwners: expectedOwners)
    guard proof.stage == .distributed else {
      throw LocalProjectStateSynchronizationError.missingVerification
    }
    guard let master = try readMaster() else {
      throw LocalProjectStateSynchronizationError.missingVerification
    }
    try requireEqualSubsets(document: document, owners: proof.managedOwners, canonical: master.canonical)
    return proof
  }

  private func readMaster() throws -> ProjectAuthorityState? {
    guard let bytes = try ProjectStateFile.readIfPresent(sharedStateURL) else { return nil }
    let json = try object(bytes)
    if json["schemaVersion"]?.number == 1 {
      // Version one combined inactive copies. It is backed up before active initialization writes.
      return nil
    }
    return try readRecord(sharedStateURL)
  }

  private func backup(
    document: [String: ProjectJSON], previous: ProjectAuthorityState?, operation: String
  ) throws {
    let registry = document[registryKey]!.object!
    var owners = Set(registry["inactive"]!.object!.keys)
    if let active = registry["owner"]?.string { owners.insert(active) }
    var snapshots: [String: ProjectSnapshot] = [:]
    for owner in owners { snapshots[owner] = try snapshot(owner: owner, document: document) }
    let history = sharedStateURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
    try ProjectStateFile.prepareDirectory(history)
    if let bytes = try ProjectStateFile.readIfPresent(sharedStateURL),
      try object(bytes)["schemaVersion"]?.number == 1 {
      let legacyURL = history.appendingPathComponent("legacy-shared-state-v1.json")
      if try ProjectStateFile.readIfPresent(legacyURL) == nil { try ProjectStateFile.write(bytes, to: legacyURL) }
    }
    let record = ProjectAuthorityBackup(operation: operation, previous: previous, ownerSnapshots: snapshots)
    try writeRecord(record, to: history.appendingPathComponent(UUID().uuidString + ".json"))
  }

  private func requireUnchanged(_ bytes: Data) throws {
    guard try ProjectStateFile.readIfPresent(globalStateURL, requirePrivate: false) == bytes else {
      throw LocalProjectStateSynchronizationError.transactionConflict
    }
  }

  private func saveMaster(_ master: ProjectAuthorityState) throws {
    try writeRecord(master, to: sharedStateURL.appendingPathExtension("bak"))
    try writeRecord(master, to: sharedStateURL)
  }

  private func commit(
    document: [String: ProjectJSON], originalBytes: Data, master: ProjectAuthorityState
  ) throws {
    try requireUnchanged(originalBytes)
    let data = try encode(ProjectJSON.object(document))
    if data != originalBytes {
      try ProjectStateFile.write(data, to: globalStateURL.appendingPathExtension("bak"), requirePrivate: false)
      try requireUnchanged(originalBytes)
      try ProjectStateFile.write(data, to: globalStateURL, requirePrivate: false)
    }
    try saveMaster(master)
  }

  private func digest(_ snapshot: ProjectSnapshot) throws -> String {
    SHA256.hash(data: try encode(snapshot)).map { String(format: "%02x", $0) }.joined()
  }

  private func object(_ data: Data) throws -> [String: ProjectJSON] {
    guard let result = try? JSONDecoder().decode(ProjectJSON.self, from: data).object else {
      throw LocalProjectStateSynchronizationError.invalidState
    }
    return result
  }

  private func validateRegistry(_ document: [String: ProjectJSON]) throws {
    guard let registry = document[registryKey]?.object,
      let owner = registry["owner"], owner == .null || owner.string != nil,
      let inactive = registry["inactive"]?.object,
      inactive.values.allSatisfy({ $0.object?["globals"]?.object != nil && $0.object?["atoms"]?.object != nil }),
      document[atomsKey] == nil || document[atomsKey]?.object != nil
    else { throw LocalProjectStateSynchronizationError.invalidState }
  }

  private func requireSourceOwner(_ owner: String, document: [String: ProjectJSON]) throws {
    let registry = document[registryKey]!.object!
    guard registry["owner"]?.string == owner
      || registry["owner"] == .null && registry["inactive"]?.object?[owner] != nil
    else { throw LocalProjectStateSynchronizationError.identityMismatch }
  }

  private func containers(
    owner: String, document: [String: ProjectJSON]
  ) throws -> (globals: [String: ProjectJSON], atoms: [String: ProjectJSON]) {
    let registry = document[registryKey]!.object!
    if registry["owner"]?.string == owner {
      return (document, document[atomsKey]?.object ?? [:])
    }
    guard let value = registry["inactive"]?.object?[owner] else { return ([:], [:]) }
    guard let globals = value.object?["globals"]?.object,
      let atoms = value.object?["atoms"]?.object
    else { throw LocalProjectStateSynchronizationError.invalidState }
    return (globals, atoms)
  }

  private func snapshot(owner: String, document: [String: ProjectJSON]) throws -> ProjectSnapshot {
    let (globals, atoms) = try containers(owner: owner, document: document)
    var result = ProjectSnapshot()
    let projects = globals["local-projects"]?.object ?? [:]
    guard globals["local-projects"] == nil || globals["local-projects"]?.object != nil else {
      throw LocalProjectStateSynchronizationError.invalidState
    }
    for (id, value) in projects where !id.hasPrefix("g-p-") {
      guard let project = value.object, project["id"]?.string == id,
        project["name"]?.string != nil, project["rootPaths"]?.strings != nil
      else { throw LocalProjectStateSynchronizationError.invalidState }
    }
    let localProjects = projects.filter { !isAccountProject(id: $0.key, value: $0.value) }
    let ids = Set(localProjects.keys)
    let memberships = globals["thread-project-assignments"]?.object ?? [:]
    let localMemberships = memberships.filter {
      $0.value.object?["projectKind"]?.string == "local"
        && ids.contains($0.value.object?["projectId"]?.string ?? "")
    }
    for key in Self.mapKeys {
      guard globals[key] == nil || globals[key]?.object != nil else {
        throw LocalProjectStateSynchronizationError.invalidState
      }
      var value = globals[key]?.object ?? [:]
      switch key {
      case "local-projects": value = localProjects
      case "thread-project-assignments": value = localMemberships
      case "project-appearances", "sidebar-project-thread-orders":
        value = value.filter { ids.contains($0.key) }
      case "app-server-project-id-by-legacy-project-id-by-host":
        value = value.mapValues { .object(($0.object ?? [:]).filter { ids.contains($0.key) }) }
          .filter { $0.value.object?.isEmpty == false }
      case "thread-project-membership-host-ids":
        value = value.filter { $0.value.string == "local" }
      default: break
      }
      result.globals[key] = .object(value)
    }
    for key in Self.listKeys {
      guard globals[key] == nil || globals[key]?.strings != nil else {
        throw LocalProjectStateSynchronizationError.invalidState
      }
      let items = globals[key]?.strings ?? []
      result.globals[key] = .strings(key.contains("project") && key != "projectless-thread-ids"
        ? items.filter { ids.contains($0) } : items)
    }
    for key in Self.atomKeys where atoms[key] != nil {
      var value = atoms[key]!
      if key.hasPrefix("unified-sidebar-") {
        guard let items = value.strings else { throw LocalProjectStateSynchronizationError.invalidState }
        value = .strings(items.filter { item in
          item.hasPrefix("codex:project:") && ids.contains(String(item.dropFirst("codex:project:".count)))
            || key == "unified-sidebar-pinned-order-v1" && item.hasPrefix("codex:thread:local:")
        })
      }
      result.atoms[key] = value
    }
    for key in ["unified-sidebar-project-order-v1", "unified-sidebar-pinned-order-v1"]
      where result.atoms[key] == nil {
      result.atoms[key] = .strings([])
    }
    for (key, value) in atoms where key.hasPrefix(Self.expandedPrefix)
      && ids.contains(String(key.dropFirst(Self.expandedPrefix.count))) {
      result.atoms[key] = value
    }
    return result
  }

  private func apply(
    _ snapshot: ProjectSnapshot, owner: String, document: inout [String: ProjectJSON]
  ) throws {
    var (globals, atoms) = try containers(owner: owner, document: document)
    let accountProjects = (globals["local-projects"]?.object ?? [:]).filter {
      isAccountProject(id: $0.key, value: $0.value)
    }
    for key in Self.mapKeys {
      let existing = globals[key]?.object ?? [:]
      let incoming = snapshot.globals[key]?.object ?? [:]
      switch key {
      case "local-projects":
        // Account-owned cloud backing records remain with their original account.
        globals[key] = .object(accountProjects.merging(incoming) { _, value in value })
      case "sidebar-project-thread-orders":
        globals[key] = .object(existing.filter {
          $0.key.hasPrefix("linked:") || $0.key.hasPrefix("g-p-") || accountProjects[$0.key] != nil
        }
          .merging(incoming) { _, value in value })
      case "project-appearances":
        globals[key] = .object(existing.filter { $0.key.hasPrefix("g-p-") || accountProjects[$0.key] != nil }
          .merging(incoming) { _, value in value })
      case "thread-project-assignments":
        let excluded = existing.filter { $0.value.object?["projectKind"]?.string != "local"
          || $0.value.object?["projectId"]?.string?.hasPrefix("g-p-") == true }
        globals[key] = .object(excluded.merging(incoming) { _, value in value })
      case "thread-project-membership-host-ids":
        globals[key] = .object(existing.filter { $0.value.string != "local" }
          .merging(incoming) { _, value in value })
      case "app-server-project-id-by-legacy-project-id-by-host":
        var hosts = existing
        for host in Set(existing.keys).union(incoming.keys) {
          let excluded = (existing[host]?.object ?? [:]).filter {
            $0.key.hasPrefix("g-p-") || accountProjects[$0.key] != nil
          }
          hosts[host] = .object(excluded.merging(incoming[host]?.object ?? [:]) { _, value in value })
        }
        globals[key] = .object(hosts)
      default: globals[key] = .object(incoming)
      }
    }
    for key in Self.listKeys {
      let incoming = snapshot.globals[key]?.strings ?? []
      if key == "project-order" || key == "pinned-project-ids" {
        globals[key] = .strings(overlayOrder(existing: globals[key]?.strings ?? [], incoming: incoming) {
          !$0.hasPrefix("g-p-") && accountProjects[$0] == nil
        })
      } else { globals[key] = .strings(incoming) }
    }
    let oldLocalAtomKeys = atoms.keys.filter { $0.hasPrefix(Self.expandedPrefix)
      && !String($0.dropFirst(Self.expandedPrefix.count)).hasPrefix("g-p-")
      && accountProjects[String($0.dropFirst(Self.expandedPrefix.count))] == nil }
    for key in oldLocalAtomKeys { atoms.removeValue(forKey: key) }
    for key in Self.atomKeys {
      if key.hasPrefix("unified-sidebar-") {
        atoms[key] = .strings(overlayOrder(existing: atoms[key]?.strings ?? [], incoming: snapshot.atoms[key]?.strings ?? []) {
          $0.hasPrefix("codex:project:") && !String($0.dropFirst("codex:project:".count)).hasPrefix("g-p-")
            || key == "unified-sidebar-pinned-order-v1" && $0.hasPrefix("codex:thread:local:")
        })
      } else { atoms[key] = snapshot.atoms[key] }
    }
    for (key, value) in snapshot.atoms where key.hasPrefix(Self.expandedPrefix) {
      atoms[key] = value
    }
    // Projectless and assigned are mutually exclusive, including newly added local chats.
    let assigned = Set((globals["thread-project-assignments"]?.object ?? [:]).keys)
    globals["projectless-thread-ids"] = .strings(
      (globals["projectless-thread-ids"]?.strings ?? []).filter { !assigned.contains($0) }
    )
    var registry = document[registryKey]!.object!
    if registry["owner"]?.string == owner {
      for key in Self.mapKeys + Self.listKeys { document[key] = globals[key] }
      document[atomsKey] = .object(atoms)
    } else {
      var inactive = registry["inactive"]!.object!
      var entry = inactive[owner]?.object ?? [:]
      entry["globals"] = .object(globals)
      entry["atoms"] = .object(atoms)
      inactive[owner] = .object(entry)
      registry["inactive"] = .object(inactive)
      document[registryKey] = .object(registry)
    }
  }

  private func isAccountProject(id: String, value: ProjectJSON) -> Bool {
    id.hasPrefix("g-p-") || value.object?.keys.contains(where: {
      $0.hasPrefix("chatGpt") || $0.hasPrefix("retiredChatGpt")
    }) == true
  }

  private func overlayOrder(
    existing: [String], incoming: [String], isLocal: (String) -> Bool
  ) -> [String] {
    var iterator = incoming.makeIterator()
    var result: [String] = []
    for item in existing {
      if isLocal(item) {
        if let replacement = iterator.next() { result.append(replacement) }
      } else { result.append(item) }
    }
    result.append(contentsOf: iterator)
    return unique(result)
  }

  private func rendererOwner(authenticationURL: URL) throws -> String {
    let data = try SecureAuthenticationFileInstaller.readPrivateAuthenticationFile(at: authenticationURL)
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tokens = object["tokens"] as? [String: Any]
    else { throw LocalProjectStateSynchronizationError.identityUnavailable }
    for key in ["access_token", "id_token"] {
      guard let token = tokens[key] as? String else { continue }
      let parts = token.split(separator: ".", omittingEmptySubsequences: false)
      guard parts.count == 3 else { continue }
      var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
      payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
      guard let bytes = Data(base64Encoded: payload),
        let claims = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
        let auth = claims["https://api.openai.com/auth"] as? [String: Any],
        let user = auth["chatgpt_user_id"] as? String, !user.isEmpty,
        let account = (tokens["account_id"] as? String) ?? (auth["chatgpt_account_id"] as? String),
        !account.isEmpty
      else { continue }
      let identity = try JSONSerialization.data(withJSONObject: [user, account], options: [.withoutEscapingSlashes])
      return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }
    throw LocalProjectStateSynchronizationError.identityUnavailable
  }

  private func readRecord<T: Codable & ProjectStateVersioned>(_ url: URL) throws -> T? {
    guard let bytes = try ProjectStateFile.readIfPresent(url) else { return nil }
    guard let value = try? JSONDecoder().decode(T.self, from: bytes) else {
      throw LocalProjectStateSynchronizationError.invalidState
    }
    guard value.schemaVersion == 2 else { throw LocalProjectStateSynchronizationError.unsupportedSchema }
    try value.validate()
    return value
  }
  private func writeRecord<T: Encodable>(_ value: T, to url: URL) throws {
    try ProjectStateFile.write(encode(value), to: url)
  }
  private func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
}

private protocol ProjectStateVersioned {
  var schemaVersion: Int { get }
  func validate() throws
}

private struct ProjectSnapshot: Codable, Equatable {
  var globals: [String: ProjectJSON] = [:]
  var atoms: [String: ProjectJSON] = [:]

  func validate() throws {
    if let projects = globals["local-projects"] {
      guard let records = projects.object, records.allSatisfy({ id, value in
        !id.hasPrefix("g-p-") && value.object?["id"]?.string == id
          && value.object?["name"]?.string != nil && value.object?["rootPaths"]?.strings != nil
      }) else { throw LocalProjectStateSynchronizationError.invalidState }
    }
  }
}

private struct ProjectAuthorityState: Codable, Equatable, ProjectStateVersioned {
  var schemaVersion = 2
  var revision: Int
  var activeOwner: String
  var canonical: ProjectSnapshot
  var approvedNextOwner: String?
  var approvalRevision: Int?
  var approvalSnapshotDigest: String?
  var quarantinedOwner: String?
  var quarantineRevision: Int?
  var rejectedSnapshotDigest: String?

  func validate() throws {
    guard revision > 0, !activeOwner.isEmpty else { throw LocalProjectStateSynchronizationError.invalidState }
    if approvedNextOwner != nil {
      guard approvalRevision == revision, approvalSnapshotDigest?.isEmpty == false else {
        throw LocalProjectStateSynchronizationError.invalidState
      }
    }
    if quarantinedOwner != nil {
      guard let quarantinedAt = quarantineRevision, quarantinedAt > 0, quarantinedAt <= revision,
        rejectedSnapshotDigest?.isEmpty == false
      else { throw LocalProjectStateSynchronizationError.invalidState }
    }
    try canonical.validate()
  }
}

private enum ProjectVerificationStage: String, Codable {
  case captured
  case distributed
}

private struct ProjectVerificationProof: Codable, ProjectStateVersioned {
  var schemaVersion = 2
  let activeOwner: String
  let managedOwners: [String]
  let revision: Int
  let snapshotDigest: String
  var stage: ProjectVerificationStage

  func validate() throws {
    guard revision > 0, !activeOwner.isEmpty, !snapshotDigest.isEmpty,
      !managedOwners.isEmpty, Set(managedOwners).count == managedOwners.count,
      managedOwners.contains(activeOwner)
    else { throw LocalProjectStateSynchronizationError.invalidState }
  }
}

private struct ProjectAuthorityJournal: Codable, ProjectStateVersioned {
  var schemaVersion = 2
  let sourceOwner: String
  let targetOwner: String
  let managedOwners: [String]
  var prepared: ProjectAuthorityState

  func validate() throws {
    guard sourceOwner != targetOwner, managedOwners.contains(sourceOwner), managedOwners.contains(targetOwner),
      prepared.schemaVersion == 2
    else { throw LocalProjectStateSynchronizationError.invalidState }
    try prepared.validate()
  }
}

private struct ProjectSourceRecoveryIntent: Codable {
  var schemaVersion = 2
  let sourceOwner: String
  let managedOwners: [String]
  let prepared: ProjectAuthorityState
}

private struct ProjectAuthorityBackup: Codable {
  var schemaVersion = 2
  let operation: String
  let previous: ProjectAuthorityState?
  let ownerSnapshots: [String: ProjectSnapshot]
}

private func unique(_ values: [String]) -> [String] {
  var seen: Set<String> = []
  return values.filter { seen.insert($0).inserted }
}

private enum ProjectJSON: Codable, Equatable {
  case object([String: ProjectJSON]), array([ProjectJSON]), string(String)
  case integer(Int64), unsignedInteger(UInt64), number(Double), bool(Bool), null
  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null }
    else if let value = try? container.decode(Bool.self) { self = .bool(value) }
    else if let value = try? container.decode(String.self) { self = .string(value) }
    else if let value = try? container.decode(Int64.self) { self = .integer(value) }
    else if let value = try? container.decode(UInt64.self) { self = .unsignedInteger(value) }
    else if let value = try? container.decode(Double.self) { self = .number(value) }
    else if let value = try? container.decode([String: ProjectJSON].self) { self = .object(value) }
    else { self = .array(try container.decode([ProjectJSON].self)) }
  }
  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .unsignedInteger(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
  var object: [String: ProjectJSON]? { if case .object(let value) = self { value } else { nil } }
  var string: String? { if case .string(let value) = self { value } else { nil } }
  var number: Double? {
    switch self {
    case .number(let value): value
    case .integer(let value): Double(value)
    case .unsignedInteger(let value): Double(value)
    default: nil
    }
  }
  var strings: [String]? {
    guard case .array(let values) = self else { return nil }
    let strings = values.compactMap(\.string)
    return strings.count == values.count ? strings : nil
  }
  static func strings(_ values: [String]) -> ProjectJSON { .array(values.map(ProjectJSON.string)) }
}

private enum ProjectStateFile {
  private static let maximumBytes = 64 * 1024 * 1024
  static func readIfPresent(_ url: URL, requirePrivate: Bool = true) throws -> Data? {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0 {
      if errno == ENOENT { return nil }
      throw LocalProjectStateSynchronizationError.unsafeStorage
    }
    defer { close(fd) }
    var status = stat()
    guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(), status.st_nlink == 1,
      status.st_mode & (requirePrivate ? 0o077 : 0o022) == 0,
      status.st_size >= 0, status.st_size <= maximumBytes
    else { throw LocalProjectStateSynchronizationError.unsafeStorage }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
      let count = read(fd, &buffer, buffer.count)
      if count == 0 { return result }
      if count < 0 {
        if errno == EINTR { continue }
        throw LocalProjectStateSynchronizationError.unsafeStorage
      }
      guard result.count + count <= maximumBytes else {
        throw LocalProjectStateSynchronizationError.invalidState
      }
      result.append(buffer, count: count)
    }
  }
  static func prepareDirectory(_ url: URL, requirePrivate: Bool = true) throws {
    var status = stat()
    if lstat(url.path, &status) == 0 {
      guard status.st_mode & S_IFMT == S_IFDIR, status.st_uid == geteuid(),
        status.st_mode & (requirePrivate ? 0o077 : 0o022) == 0
      else { throw LocalProjectStateSynchronizationError.unsafeStorage }
      return
    }
    guard errno == ENOENT else { throw LocalProjectStateSynchronizationError.unsafeStorage }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try prepareDirectory(url, requirePrivate: requirePrivate)
  }
  static func write(_ data: Data, to url: URL, requirePrivate: Bool = true) throws {
    guard data.count <= maximumBytes else { throw LocalProjectStateSynchronizationError.invalidState }
    try prepareDirectory(url.deletingLastPathComponent(), requirePrivate: requirePrivate)
    _ = try readIfPresent(url, requirePrivate: requirePrivate)
    let temporary = url.deletingLastPathComponent().appendingPathComponent(".local-project-sync-\(UUID().uuidString).tmp")
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw LocalProjectStateSynchronizationError.unsafeStorage }
    defer { close(fd); try? FileManager.default.removeItem(at: temporary) }
    try data.withUnsafeBytes { buffer in
      guard var pointer = buffer.baseAddress else { return }
      var remaining = buffer.count
      while remaining > 0 {
        let count = Darwin.write(fd, pointer, remaining)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw LocalProjectStateSynchronizationError.unsafeStorage }
        remaining -= count
        pointer = pointer.advanced(by: count)
      }
    }
    guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else {
      throw LocalProjectStateSynchronizationError.unsafeStorage
    }
    let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw LocalProjectStateSynchronizationError.unsafeStorage }
    defer { close(directory) }
    guard fsync(directory) == 0 else { throw LocalProjectStateSynchronizationError.unsafeStorage }
  }
}

private final class ProjectStateLock {
  private let descriptor: Int32
  init(url: URL) throws {
    descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw LocalProjectStateSynchronizationError.unsafeStorage }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(), status.st_nlink == 1, status.st_mode & 0o077 == 0,
      flock(descriptor, LOCK_EX) == 0
    else { close(descriptor); throw LocalProjectStateSynchronizationError.unsafeStorage }
  }
  func release() { _ = flock(descriptor, LOCK_UN) }
  deinit { close(descriptor) }
}
