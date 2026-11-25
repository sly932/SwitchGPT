import Foundation
import SwitchGPTSafetyCore

public enum AccountCredentialLock {
  public static func acquire(
    appDirectory: URL = PreviewStateFileStore.defaultStore.fileURL.deletingLastPathComponent()
  ) throws -> TransactionLock {
    try TransactionLock(url: appDirectory.appendingPathComponent("account-credentials.lock"))
  }

  public static func acquireIfConfigured(for persistence: any PreviewStatePersisting) throws
    -> TransactionLock?
  {
    guard let fileStore = persistence as? PreviewStateFileStore,
      fileStore.fileURL == PreviewStateFileStore.defaultStore.fileURL,
      FileManager.default.fileExists(atPath: fileStore.fileURL.deletingLastPathComponent().path)
    else { return nil }
    return try acquire()
  }
}
