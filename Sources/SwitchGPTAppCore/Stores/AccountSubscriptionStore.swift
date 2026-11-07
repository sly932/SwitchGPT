import CoreFoundation
import Darwin
import Foundation

public enum AccountSubscriptionStoreError: Error, Equatable, LocalizedError, Sendable {
  case invalidEmail
  case invalidSubscription
  case invalidSnapshot
  case unsafeFile
  case unsafeDirectory
  case oversizedSnapshot
  case ioFailure

  public var errorDescription: String? {
    switch self {
    case .invalidEmail: "The account email is invalid."
    case .invalidSubscription: "Use a valid subscription date in YYYY-MM-DD format."
    case .invalidSnapshot: "The saved account snapshot is invalid. It has been preserved."
    case .unsafeFile: "The saved account file is not a private regular file."
    case .unsafeDirectory: "The usage-plan directory is not a private directory."
    case .oversizedSnapshot: "The saved account snapshot is unexpectedly large."
    case .ioFailure: "The subscription information could not be read or saved."
    }
  }
}

/// Shares the usage-plan snapshot and lock with the global plan-update skill.
/// Manual edits preserve quota timestamps, unknown fields and all other accounts.
public struct AccountSubscriptionStore: Sendable {
  public static let maximumFileSize = 1 * 1024 * 1024
  public let fileURL: URL

  public static var defaultStore: AccountSubscriptionStore {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? FileManager.default.temporaryDirectory
    return AccountSubscriptionStore(
      fileURL: root.appendingPathComponent("SwitchGPT-sly/UsagePlan/account-state.json")
    )
  }

  public init(fileURL: URL) {
    self.fileURL = fileURL.standardizedFileURL
  }

  public func read() throws -> [String: AccountSubscription] {
    var info = stat()
    let result = fileURL.deletingLastPathComponent().path.withCString { lstat($0, &info) }
    if result < 0, errno == ENOENT { return [:] }
    guard result == 0 else { throw AccountSubscriptionStoreError.unsafeDirectory }
    return try withLock(createDirectory: false) { directory in
      guard let snapshot = try loadSnapshot(directory: directory) else { return [:] }
      return try subscriptions(in: snapshot)
    }
  }

  public func setExpiry(email: String, expiresOn: String?) throws {
    guard Self.isValidEmail(email) else { throw AccountSubscriptionStoreError.invalidEmail }
    if let expiresOn, !AccountSubscription.isValidDate(expiresOn) {
      throw AccountSubscriptionStoreError.invalidSubscription
    }
    try withLock(createDirectory: true) { directory in
      let existing = try loadSnapshot(directory: directory)
      if existing == nil && expiresOn == nil { return }
      var snapshot = existing ?? emptySnapshot()
      _ = try subscriptions(in: snapshot)
      var accounts = snapshot["accounts"] as! [[String: Any]]
      let index: Int
      if let found = accounts.firstIndex(where: { ($0["email"] as? String)?.lowercased() == email.lowercased() }) {
        index = found
      } else {
        guard expiresOn != nil else { return }
        accounts.append(["email": email, "displayName": email, "status": "unknown"])
        index = accounts.count - 1
      }
      let now = ISO8601DateFormatter().string(from: Date())
      if let expiresOn {
        accounts[index]["subscription"] = [
          "expiresOn": expiresOn, "source": "manual", "updatedAt": now,
        ]
      } else {
        accounts[index].removeValue(forKey: "subscription")
      }
      snapshot["accounts"] = accounts
      snapshot["totalCount"] = accounts.count
      snapshot["revision"] = UUID().uuidString
      snapshot["metadataUpdatedAt"] = now
      let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys, .prettyPrinted])
      guard data.count <= Self.maximumFileSize else {
        throw AccountSubscriptionStoreError.oversizedSnapshot
      }
      try replaceSnapshot(data, directory: directory)
    }
  }

  private func emptySnapshot() -> [String: Any] {
    [
      "schemaVersion": 1, "command": "quota", "source": "manual",
      "generatedAt": NSNull(), "accounts": [[String: Any]](),
      "totalCount": 0, "errorCount": 0, "partialCount": 0,
    ]
  }

  private func subscriptions(in snapshot: [String: Any]) throws -> [String: AccountSubscription] {
    guard let version = snapshot["schemaVersion"] as? NSNumber,
      CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
      let accounts = snapshot["accounts"] as? [[String: Any]]
    else { throw AccountSubscriptionStoreError.invalidSnapshot }
    var result: [String: AccountSubscription] = [:]
    var emails = Set<String>()
    for account in accounts {
      guard let email = account["email"] as? String else {
        guard account["subscription"] == nil else {
          throw AccountSubscriptionStoreError.invalidSnapshot
        }
        continue
      }
      guard Self.isValidEmail(email), emails.insert(email.lowercased()).inserted else {
        throw AccountSubscriptionStoreError.invalidSnapshot
      }
      guard let raw = account["subscription"] else { continue }
      guard let subscription = raw as? [String: Any],
        let expiresOn = subscription["expiresOn"] as? String,
        let source = subscription["source"] as? String,
        let updatedAt = subscription["updatedAt"] as? String
      else { throw AccountSubscriptionStoreError.invalidSubscription }
      result[email.lowercased()] = try AccountSubscription(expiresOn: expiresOn, source: source, updatedAt: updatedAt)
    }
    return result
  }

  private static func isValidEmail(_ email: String) -> Bool {
    !email.isEmpty && email.count <= 320 && email.contains("@")
      && email == email.trimmingCharacters(in: .whitespacesAndNewlines)
      && !email.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private func withLock<T>(createDirectory: Bool, body: (Int32) throws -> T) throws -> T {
    let directoryURL = fileURL.deletingLastPathComponent()
    if createDirectory {
      try FileManager.default.createDirectory(
        at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
      )
    }
    let directory = directoryURL.path.withCString {
      open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard directory >= 0 else { throw AccountSubscriptionStoreError.unsafeDirectory }
    defer { close(directory) }
    var directoryStat = stat()
    guard fstat(directory, &directoryStat) == 0,
      directoryStat.st_uid == getuid(), directoryStat.st_mode & 0o077 == 0
    else { throw AccountSubscriptionStoreError.unsafeDirectory }

    let lock = openat(directory, ".lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { throw AccountSubscriptionStoreError.unsafeFile }
    defer { close(lock) }
    var lockStat = stat()
    guard fstat(lock, &lockStat) == 0, lockStat.st_mode & S_IFMT == S_IFREG,
      lockStat.st_uid == getuid(), lockStat.st_nlink == 1, fchmod(lock, 0o600) == 0
    else { throw AccountSubscriptionStoreError.unsafeFile }
    guard flock(lock, LOCK_EX) == 0 else { throw AccountSubscriptionStoreError.ioFailure }
    defer { _ = flock(lock, LOCK_UN) }
    return try body(directory)
  }

  private func loadSnapshot(directory: Int32) throws -> [String: Any]? {
    let descriptor = openat(directory, fileURL.lastPathComponent, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    if descriptor < 0, errno == ENOENT { return nil }
    guard descriptor >= 0 else { throw AccountSubscriptionStoreError.unsafeFile }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0
    else { throw AccountSubscriptionStoreError.unsafeFile }
    guard info.st_size <= Self.maximumFileSize else {
      throw AccountSubscriptionStoreError.oversizedSnapshot
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count == 0 { break }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw AccountSubscriptionStoreError.ioFailure }
      guard data.count + count <= Self.maximumFileSize else {
        throw AccountSubscriptionStoreError.oversizedSnapshot
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    guard let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw AccountSubscriptionStoreError.invalidSnapshot
    }
    _ = try subscriptions(in: snapshot)
    return snapshot
  }

  private func replaceSnapshot(_ data: Data, directory: Int32) throws {
    let temporaryName = ".account-state-" + UUID().uuidString + ".tmp"
    let descriptor = openat(directory, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw AccountSubscriptionStoreError.ioFailure }
    defer {
      close(descriptor)
      unlinkat(directory, temporaryName, 0)
    }
    try data.withUnsafeBytes { bytes in
      var written = 0
      while written < bytes.count {
        let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw AccountSubscriptionStoreError.ioFailure }
        written += count
      }
    }
    guard fsync(descriptor) == 0,
      renameat(directory, temporaryName, directory, fileURL.lastPathComponent) == 0,
      fsync(directory) == 0
    else { throw AccountSubscriptionStoreError.ioFailure }
  }
}
