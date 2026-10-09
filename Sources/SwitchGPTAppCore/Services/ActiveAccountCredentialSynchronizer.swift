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
    let activeIdentity = try PinnedAuthenticationIdentityReader(
      authenticationFileURL: activeAuthenticationURL
    ).currentIdentity()
    let matchingAccounts = accounts.filter { $0.identityHash == activeIdentity.rawValue }
    guard !matchingAccounts.isEmpty else { return nil }
    guard matchingAccounts.count == 1 else { throw QuotaReadingError.identityMismatch }
    let account = matchingAccounts[0]
    guard case .codexHome(let path) = account.source else { return nil }
    let directory = URL(fileURLWithPath: path).standardizedFileURL
    // Read-only external profiles are not managed by SwitchGPT and must remain untouched.
    guard directory.deletingLastPathComponent() == accountsRootURL,
      UUID(uuidString: directory.lastPathComponent) != nil
    else { return nil }
    guard directory.resolvingSymlinksInPath() == directory,
      accountsRootURL.resolvingSymlinksInPath() == accountsRootURL
    else { throw QuotaReadingError.invalidHomePath }
    try SecureAuthenticationFileInstaller.synchronizePrivateAuthenticationFile(
      from: activeAuthenticationURL,
      to: directory.appendingPathComponent("auth.json"),
      expectedIdentity: activeIdentity
    )
    return account.id
  }
}
