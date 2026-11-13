import Darwin
import Foundation
import SwitchGPTSafetyCore

/// The background job owns this file. The Dashboard's account list and selection stay in
/// PreviewStateFileStore, so a completed query cannot overwrite account edits from another process.
public struct BackgroundUsageSnapshotStore: Sendable {
  public let fileURL: URL

  public static var defaultStore: Self {
    Self(fileURL: PreviewStateFileStore.defaultStore.fileURL.deletingLastPathComponent()
      .appendingPathComponent("BackgroundUsage", isDirectory: true)
      .appendingPathComponent("snapshots.json"))
  }

  public init(fileURL: URL) {
    self.fileURL = fileURL.standardizedFileURL
  }

  /// Pass all accounts in the batch, including those whose queries failed. Each successful
  /// result replaces only that account's older snapshot. Failed accounts keep their prior value.
  public func save(
    _ snapshots: [AccountID: AccountQuotaSnapshot], for accounts: [AccountRecord],
    refreshedAt: Date = Date()
  ) throws {
    guard !snapshots.isEmpty else { return }
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let lock = try TransactionLock(url: directory.appendingPathComponent(".snapshots.lock"))
    defer { lock.release() }

    var cache = try load()
    let profiles = Set(accounts.compactMap(Profile.init))
    cache.entries = cache.entries.filter { profiles.contains($0.value.profile) }
    for profile in profiles {
      guard let snapshot = snapshots[profile.id],
        cache.entries[profile.id.rawValue].map({ $0.refreshedAt <= refreshedAt }) ?? true
      else { continue }
      cache.entries[profile.id.rawValue] = Entry(
        profile: profile, email: snapshot.email, planName: snapshot.planName,
        usage: snapshot.usage, refreshedAt: refreshedAt)
    }
    if !profiles.isEmpty, profiles.allSatisfy({ profile in
      snapshots[profile.id].map { !$0.usage.hasUnavailableDetails } ?? false
    }), cache.complete.map({ $0.refreshedAt <= refreshedAt }) ?? true {
      cache.complete = Completion(profiles: profiles, refreshedAt: refreshedAt)
    }
    try write(cache, in: directory)
  }

  /// Overlays newer results for the exact profile that was queried. A re-login can retain the
  /// account ID but replace its profile directory, and must never inherit that older result.
  public func overlay(on accounts: [AccountRecord]) throws
    -> (accounts: [AccountRecord], lastCompleteRefresh: Date?)
  {
    let cache = try load()
    let updatedAccounts = accounts.map { account in
      guard let entry = cache.entries[account.id.rawValue], entry.profile == Profile(account),
        account.usageRefreshedAt.map({ $0 < entry.refreshedAt }) ?? true
      else { return account }
      return AccountRecord(
        id: account.id, displayName: account.displayName, email: entry.email ?? account.email,
        detail: account.detail, planName: entry.planName, symbolName: account.symbolName,
        accent: account.accent, usage: entry.usage, source: account.source,
        identityHash: account.identityHash, usageRefreshedAt: entry.refreshedAt)
    }
    let profiles = Set(accounts.compactMap(Profile.init))
    let lastCompleteRefresh = cache.complete.flatMap { complete in
      complete.profiles == profiles ? complete.refreshedAt : nil
    }
    return (updatedAccounts, lastCompleteRefresh)
  }

  private func load() throws -> Cache {
    let descriptor = open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    if descriptor < 0, errno == ENOENT { return Cache() }
    guard descriptor >= 0 else { throw PreviewStatePersistenceError.invalidFile }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }

    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600
    else { throw PreviewStatePersistenceError.insecureFile }
    let limit = PreviewStateFileStore.maximumFileSize
    guard info.st_size <= limit else { throw PreviewStatePersistenceError.oversizedFile }
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw PreviewStatePersistenceError.oversizedFile }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let cache = try decoder.decode(Cache.self, from: data)
    guard cache.schemaVersion == Cache.currentSchemaVersion else {
      throw PreviewStatePersistenceError.unsupportedSchema
    }
    return cache
  }

  private func write(_ cache: Cache, in directory: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let data = try encoder.encode(cache)
    guard data.count <= PreviewStateFileStore.maximumFileSize else {
      throw PreviewStatePersistenceError.oversizedFile
    }
    let temporaryURL = directory.appendingPathComponent(".snapshots-" + UUID().uuidString + ".tmp")
    let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw PreviewStatePersistenceError.invalidFile }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer {
      try? handle.close()
      try? FileManager.default.removeItem(at: temporaryURL)
    }
    guard fchmod(descriptor, 0o600) == 0 else { throw PreviewStatePersistenceError.insecureFile }
    try handle.write(contentsOf: data)
    try handle.synchronize()
    guard rename(temporaryURL.path, fileURL.path) == 0 else {
      throw PreviewStatePersistenceError.invalidFile
    }
  }

  private struct Profile: Codable, Hashable {
    let id: AccountID
    let identityHash: String
    let path: String

    init?(_ account: AccountRecord) {
      guard case .codexHome(let path) = account.source, let identityHash = account.identityHash
      else { return nil }
      self.id = account.id
      self.identityHash = identityHash
      self.path = path
    }
  }

  private struct Entry: Codable {
    let profile: Profile
    let email: String?
    let planName: String
    let usage: AccountUsage
    let refreshedAt: Date
  }

  private struct Completion: Codable {
    let profiles: Set<Profile>
    let refreshedAt: Date
  }

  private struct Cache: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var entries: [String: Entry] = [:]
    var complete: Completion?
  }
}
