import Foundation
import SwitchGPTDesktopIntegration
import SwitchGPTSafetyCore

public protocol ActiveAccountCredentialSynchronizing: Sendable {
  func synchronize(accounts: [AccountRecord]) throws -> AccountID?
}

/// Keeps demo stores and fixture tests independent of the user's authentication files.
public struct NoopActiveAccountCredentialSynchronizer: ActiveAccountCredentialSynchronizing {
  public init() {}
  public func synchronize(accounts: [AccountRecord]) throws -> AccountID? { nil }
}

/// Copies desktop credentials only into the matching, already configured managed profile.
/// It never changes the active desktop file or refreshes credentials over the network.
public struct ActiveAccountCredentialSynchronizer: ActiveAccountCredentialSynchronizing {
  public let activeAuthenticationURL: URL
  public let accountsRootURL: URL

  public init(
    activeAuthenticationURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex/auth.json"),
    accountsRootURL: URL = CodexManagedAccountOnboarder().accountsRootURL
  ) {
    self.activeAuthenticationURL = activeAuthenticationURL.standardizedFileURL
    self.accountsRootURL = accountsRootURL.standardizedFileURL
  }

  public func synchronize(accounts: [AccountRecord]) throws -> AccountID? {
    guard accounts.contains(where: { if case .codexHome = $0.source { true } else { false } })
    else { return nil }
    let credentialLock = try AccountCredentialLock.acquire(
      appDirectory: accountsRootURL.deletingLastPathComponent())
    defer { credentialLock.release() }
    let activeData = try SecureAuthenticationFileInstaller.readPrivateAuthenticationFile(
      at: activeAuthenticationURL)
    let activeIdentities = try PinnedAuthenticationIdentityReader.identityHashes(
      fromAuthenticationData: activeData)
    let matchingAccounts = accounts.filter { account in
      account.identityHash.map { activeIdentities.contains($0) } ?? false
    }
    guard !matchingAccounts.isEmpty else { return nil }
    guard matchingAccounts.count == 1 else { throw QuotaReadingError.identityMismatch }
    let account = matchingAccounts[0]
    guard case .codexHome(let path) = account.source,
      let hash = account.identityHash, let activeIdentity = IdentityID(rawValue: hash)
    else { return nil }
    guard let archive = try CodexManagedAccountOnboarder(accountsRootURL: accountsRootURL)
      .managedAuthenticationURL(for: path) else { return nil }
    try SecureAuthenticationFileInstaller.synchronizePrivateAuthenticationFile(
      from: activeAuthenticationURL,
      to: archive,
      expectedIdentity: activeIdentity
    )
    return account.id
  }
}
