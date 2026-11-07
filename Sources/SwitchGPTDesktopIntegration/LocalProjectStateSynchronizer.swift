import CryptoKit
import Darwin
import Foundation

public protocol LocalProjectStateSynchronizing: AnyObject {
  func prepareSwitch(sourceAuthenticationURL: URL, targetAuthenticationURL: URL) throws
  func recoverSource(sourceAuthenticationURL: URL) throws
}

public enum LocalProjectStateSynchronizationError: Error, Equatable {
  case invalidState
  case unsafeStorage
  case identityUnavailable
  case identityMismatch
  case unsupportedSchema
  case transactionConflict
}

/// Shares local project metadata while keeping ChatGPT's account-owned state separate.
/// Call only after the desktop has exited and while the switch transaction is locked.
public final class LocalProjectStateSynchronizer: LocalProjectStateSynchronizing {
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

  public func prepareSwitch(sourceAuthenticationURL: URL, targetAuthenticationURL: URL) throws {
    guard let bytes = try ProjectStateFile.readIfPresent(globalStateURL, requirePrivate: false) else { return }
    var document = try object(bytes)
    guard document[registryKey] != nil else { return }
    try validateRegistry(document)
    let sourceOwner = try rendererOwner(authenticationURL: sourceAuthenticationURL)
    let targetOwner = try rendererOwner(authenticationURL: targetAuthenticationURL)
    guard sourceOwner != targetOwner else {
      throw LocalProjectStateSynchronizationError.identityMismatch
    }
    try requireSourceOwner(sourceOwner, document: document)
    try ProjectStateFile.prepareDirectory(sharedStateURL.deletingLastPathComponent())
    let lock = try ProjectStateLock(url: sharedStateURL.appendingPathExtension("lock"))
    defer { lock.release() }

    if let journal: ProjectSyncJournal = try readRecord(journalURL) {
      guard journal.sourceOwner == sourceOwner, journal.targetOwner == targetOwner else {
        throw LocalProjectStateSynchronizationError.transactionConflict
      }
    }
    var shared: SharedProjectState = try readRecord(sharedStateURL) ?? SharedProjectState()
    let source = try snapshot(owner: sourceOwner, document: document)
    let target = try snapshot(owner: targetOwner, document: document)
    let firstSynchronization = shared.revision == 0
    ingest(target, owner: targetOwner, into: &shared, bootstrapSource: false)
    ingest(source, owner: sourceOwner, into: &shared, bootstrapSource: firstSynchronization)
    sanitize(&shared)
    shared.revision += 1
    try apply(shared.canonical, owner: sourceOwner, document: &document)
    try apply(shared.canonical, owner: targetOwner, document: &document)
    shared.baselines[sourceOwner] = try snapshot(owner: sourceOwner, document: document)
    shared.baselines[targetOwner] = try snapshot(owner: targetOwner, document: document)

    let journal = ProjectSyncJournal(
      sourceOwner: sourceOwner, targetOwner: targetOwner,
      sourceBefore: source, targetBefore: target, prepared: shared
    )
    try ProjectStateFile.prepareDirectory(transactionDirectoryURL)
    if try ProjectStateFile.readIfPresent(backupURL) == nil {
      try writeRecord(journal, to: backupURL)
    }
    let historyDirectory = sharedStateURL.deletingLastPathComponent()
      .appendingPathComponent("Backups", isDirectory: true)
    try ProjectStateFile.prepareDirectory(historyDirectory)
    let historyURL = historyDirectory.appendingPathComponent(transactionDirectoryURL.lastPathComponent + ".json")
    if try ProjectStateFile.readIfPresent(historyURL) == nil {
      try writeRecord(journal, to: historyURL)
    }
    // This durable intent lets a fresh recovery process finish even if either write is interrupted.
    try writeRecord(journal, to: journalURL)
    try commit(document: document, originalBytes: bytes, shared: shared)
  }

  public func recoverSource(sourceAuthenticationURL: URL) throws {
    guard var journal: ProjectSyncJournal = try readRecord(journalURL) else { return }
    let sourceOwner = try rendererOwner(authenticationURL: sourceAuthenticationURL)
    guard sourceOwner == journal.sourceOwner else {
      throw LocalProjectStateSynchronizationError.identityMismatch
    }
    guard let bytes = try ProjectStateFile.readIfPresent(globalStateURL, requirePrivate: false) else {
      throw LocalProjectStateSynchronizationError.invalidState
    }
    var document = try object(bytes)
    try validateRegistry(document)
    let lock = try ProjectStateLock(url: sharedStateURL.appendingPathExtension("lock"))
    defer { lock.release() }
    let saved: SharedProjectState? = try readRecord(sharedStateURL)
    var shared = saved.flatMap { $0.revision >= journal.prepared.revision ? $0 : nil }
      ?? journal.prepared
    let target = try snapshot(owner: journal.targetOwner, document: document)
    let source = try snapshot(owner: sourceOwner, document: document)
    // An interrupted prepare may not have written either owner yet. That is not a user deletion.
    if target == journal.targetBefore { shared.baselines[journal.targetOwner] = target }
    if source == journal.sourceBefore { shared.baselines[sourceOwner] = source }
    ingest(target, owner: journal.targetOwner, into: &shared, bootstrapSource: false)
    ingest(source, owner: sourceOwner, into: &shared, bootstrapSource: false)
    sanitize(&shared)
    shared.revision += 1
    try apply(shared.canonical, owner: sourceOwner, document: &document)
    try apply(shared.canonical, owner: journal.targetOwner, document: &document)
    shared.baselines[sourceOwner] = try snapshot(owner: sourceOwner, document: document)
    shared.baselines[journal.targetOwner] = try snapshot(owner: journal.targetOwner, document: document)
    journal.sourceBefore = source
    journal.targetBefore = target
    journal.prepared = shared
    try writeRecord(journal, to: journalURL)
    try commit(document: document, originalBytes: bytes, shared: shared)
  }

  private var journalURL: URL {
    transactionDirectoryURL.appendingPathComponent("local-project-sync-journal.json")
  }
  private var backupURL: URL {
    transactionDirectoryURL.appendingPathComponent("local-project-state-before.json")
  }

  private func commit(
    document: [String: ProjectJSON], originalBytes: Data, shared: SharedProjectState
  ) throws {
    guard try ProjectStateFile.readIfPresent(globalStateURL, requirePrivate: false) == originalBytes else {
      throw LocalProjectStateSynchronizationError.transactionConflict
    }
    let data = try encode(ProjectJSON.object(document))
    try ProjectStateFile.write(data, to: globalStateURL.appendingPathExtension("bak"), requirePrivate: false)
    try ProjectStateFile.write(data, to: globalStateURL, requirePrivate: false)
    try writeRecord(shared, to: sharedStateURL.appendingPathExtension("bak"))
    try writeRecord(shared, to: sharedStateURL)
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

  private func ingest(
    _ current: ProjectSnapshot, owner: String, into shared: inout SharedProjectState,
    bootstrapSource: Bool
  ) {
    let baseline = shared.baselines[owner]
    let known = baseline != nil
    mergeObject(current.globals, baseline?.globals ?? [:], path: ["globals"],
      known: known, overwriteUnknown: bootstrapSource, into: &shared)
    mergeObject(current.atoms, baseline?.atoms ?? [:], path: ["atoms"],
      known: known, overwriteUnknown: bootstrapSource, into: &shared)
  }

  private func mergeObject(
    _ current: [String: ProjectJSON], _ baseline: [String: ProjectJSON], path: [String],
    known: Bool, overwriteUnknown: Bool, into shared: inout SharedProjectState
  ) {
    for key in Set(current.keys).union(baseline.keys).sorted() {
      let nextPath = path + [key]
      let old = baseline[key]
      guard let value = current[key] else {
        if known, old != nil { remove(nextPath, from: &shared) }
        continue
      }
      if known, value == old { continue }
      let wasDeleted = shared.isDeleted(nextPath)
      if wasDeleted, !known { continue }
      if known, wasDeleted || old == nil { shared.clearDeletion(nextPath) }
      if let items = value.strings, isMembershipList(nextPath) {
        mergeList(items, baseline: old?.strings ?? [], path: nextPath, known: known, into: &shared)
      } else if let object = value.object {
        var overwrite = overwriteUnknown
        if !known, nextPath.count == 3, path == ["globals", "local-projects"],
          let incomingTime = object["updatedAt"]?.number,
          let existingTime = shared.value(nextPath)?.object?["updatedAt"]?.number {
          overwrite = incomingTime > existingTime
            || incomingTime == existingTime && overwriteUnknown
        }
        mergeObject(object, wasDeleted ? [:] : old?.object ?? [:], path: nextPath, known: known,
          overwriteUnknown: overwrite, into: &shared)
      } else if !shared.isDeleted(nextPath), known || overwriteUnknown || shared.value(nextPath) == nil {
        shared.set(value, at: nextPath)
      }
    }
  }

  private func isMembershipList(_ path: [String]) -> Bool {
    path.count == 2 && (path.first == "globals" && Self.listKeys.contains(path[1])
      || path.first == "atoms" && (path[1].hasPrefix("unified-sidebar-")
        || path[1] == "app-server-pinned-thread-order-v1"))
      || path.first == "globals" && path.contains("pendingThreadAssignmentIds")
  }

  private func mergeList(
    _ current: [String], baseline: [String], path: [String], known: Bool,
    into shared: inout SharedProjectState
  ) {
    let previous = shared.value(path)?.strings ?? []
    let currentSet = Set(current)
    let baselineSet = Set(baseline)
    if known {
      for item in baselineSet.subtracting(currentSet) { shared.tombstones.insert(pathKey(path + [item])) }
      for item in currentSet.subtracting(baselineSet) { shared.clearDeletion(path + [item]) }
    }
    let retained = previous.filter { !shared.isDeleted(path + [$0]) }
    let additions = current.filter { !baselineSet.contains($0) && !shared.isDeleted(path + [$0]) }
    let merged = unique(retained + additions)
    let ordered = known && current != baseline
      ? unique(current.filter { merged.contains($0) } + merged) : merged
    shared.set(.strings(ordered), at: path)
  }

  private func remove(_ path: [String], from shared: inout SharedProjectState) {
    shared.tombstones.insert(pathKey(path))
    shared.set(nil, at: path)
  }

  private func sanitize(_ shared: inout SharedProjectState) {
    let projects = shared.canonical.globals["local-projects"]?.object ?? [:]
    let ids = Set(projects.keys)
    var globals = shared.canonical.globals
    for key in ["project-order", "pinned-project-ids"] {
      globals[key] = .strings((globals[key]?.strings ?? []).filter { ids.contains($0) })
    }
    for key in ["project-appearances", "sidebar-project-thread-orders"] {
      globals[key] = .object((globals[key]?.object ?? [:]).filter { ids.contains($0.key) })
    }
    let memberships = (globals["thread-project-assignments"]?.object ?? [:]).filter {
      ids.contains($0.value.object?["projectId"]?.string ?? "")
    }
    globals["thread-project-assignments"] = .object(memberships)
    globals["projectless-thread-ids"] = .strings((globals["projectless-thread-ids"]?.strings ?? [])
      .filter { memberships[$0] == nil })
    shared.canonical.globals = globals
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
    guard value.schemaVersion == 1 else { throw LocalProjectStateSynchronizationError.unsupportedSchema }
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

private struct SharedProjectState: Codable, ProjectStateVersioned {
  var schemaVersion = 1
  var revision = 0
  var canonical = ProjectSnapshot()
  var baselines: [String: ProjectSnapshot] = [:]
  var tombstones: Set<String> = []

  func validate() throws {
    guard revision >= 0 else { throw LocalProjectStateSynchronizationError.invalidState }
    try canonical.validate()
    for baseline in baselines.values { try baseline.validate() }
  }

  func value(_ path: [String]) -> ProjectJSON? {
    let root: [String: ProjectJSON] = path.first == "globals" ? canonical.globals : canonical.atoms
    return path.dropFirst().reduce(ProjectJSON.object(root) as ProjectJSON?) { $0?.object?[$1] }
  }
  mutating func set(_ value: ProjectJSON?, at path: [String]) {
    var root = path.first == "globals" ? canonical.globals : canonical.atoms
    func update(_ object: inout [String: ProjectJSON], _ remaining: ArraySlice<String>) {
      guard let key = remaining.first else { return }
      if remaining.count == 1 { object[key] = value; return }
      var child = object[key]?.object ?? [:]
      update(&child, remaining.dropFirst())
      object[key] = .object(child)
    }
    update(&root, path.dropFirst())
    if path.first == "globals" { canonical.globals = root } else { canonical.atoms = root }
  }
  func isDeleted(_ path: [String]) -> Bool {
    (1...path.count).contains { tombstones.contains(pathKey(Array(path.prefix($0)))) }
  }
  mutating func clearDeletion(_ path: [String]) {
    let key = pathKey(path)
    tombstones = tombstones.filter { $0 != key && !$0.hasPrefix(key + "/") }
  }
}

private struct ProjectSyncJournal: Codable, ProjectStateVersioned {
  var schemaVersion = 1
  let sourceOwner: String
  let targetOwner: String
  var sourceBefore: ProjectSnapshot
  var targetBefore: ProjectSnapshot
  var prepared: SharedProjectState

  func validate() throws {
    guard !sourceOwner.isEmpty, !targetOwner.isEmpty, sourceOwner != targetOwner else {
      throw LocalProjectStateSynchronizationError.invalidState
    }
    guard prepared.schemaVersion == 1 else { throw LocalProjectStateSynchronizationError.unsupportedSchema }
    try prepared.validate()
    try sourceBefore.validate()
    try targetBefore.validate()
  }
}

private func pathKey(_ path: [String]) -> String {
  path.map { $0.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }.joined(separator: "/")
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
