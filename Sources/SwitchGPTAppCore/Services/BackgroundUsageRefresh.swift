import Foundation
import SwitchGPTDesktopIntegration

public struct BackgroundUsageRefresh: Sendable {
  private let reader: CodexAppServerQuotaReader
  private let stateStore: PreviewStateFileStore
  private let snapshotStore: BackgroundUsageSnapshotStore
  private let activeAuthenticationURL: URL
  private let accountsRootURL: URL

  public init(
    reader: CodexAppServerQuotaReader = CodexAppServerQuotaReader(timeout: .seconds(20)),
    stateStore: PreviewStateFileStore = .defaultStore,
    snapshotStore: BackgroundUsageSnapshotStore = .defaultStore,
    credentialSynchronizer: ActiveAccountCredentialSynchronizer = ActiveAccountCredentialSynchronizer()
  ) {
    self.reader = reader
    self.stateStore = stateStore
    self.snapshotStore = snapshotStore
    activeAuthenticationURL = credentialSynchronizer.activeAuthenticationURL
    accountsRootURL = credentialSynchronizer.accountsRootURL
  }

  public struct Result: Sendable {
    public let updatedCount: Int
    public let failedCount: Int
    public let renewedCount: Int
  }

  public func run() async throws -> Result {
    guard FileManager.default.fileExists(atPath: stateStore.fileURL.path) else {
      return Result(updatedCount: 0, failedCount: 0, renewedCount: 0)
    }
    let appDirectory = stateStore.fileURL.deletingLastPathComponent()
    let lock = try AccountCredentialLock.acquire(appDirectory: appDirectory)
    defer { lock.release() }
    let transactions = appDirectory.appendingPathComponent("Transactions", isDirectory: true)
    if FileManager.default.fileExists(atPath: transactions.path) {
      try RecoveryTransactionPathContract.validateExistingPrivateDirectory(transactions)
      guard try FileManager.default.contentsOfDirectory(atPath: transactions.path).isEmpty else {
        throw BackgroundUsageRefreshError.switchRecoveryPending
      }
    }
    let accounts = try stateStore.load()?.accounts ?? []
    let refreshedAt = Date()
    let profiles = accounts.compactMap { account -> Profile? in
      guard case .codexHome(let path) = account.source else { return nil }
      return Profile(
        account: account, home: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL)
    }
    let authenticationByProfile = profiles.reduce(into: [AccountID: Authentication]()) { result, profile in
      result[profile.account.id] = try? Authentication(at: profile.authenticationURL)
    }
    var snapshots: [AccountID: AccountQuotaSnapshot] = [:]
    var renewedCount = 0
    for profile in profiles {
      try Task.checkCancellation()
      do {
        let activeAuth = try? Authentication(at: activeAuthenticationURL)
        let archived = authenticationByProfile[profile.account.id]
        let probe: ReadOnlyAccountProbe
        if let activeAuth, activeAuth.identity == profile.account.identityHash {
          if let archived {
            guard archived.matchesAccount(activeAuth) else {
              throw QuotaReadingError.identityMismatch
            }
          }
          probe = try await reader.probeActiveProfile(authenticationFileURL: activeAuthenticationURL)
        } else if let archived, let activeAuth, isManaged(profile.home),
          archived.canRenew(while: activeAuth),
          !authenticationByProfile.contains(where: { id, other in
            id != profile.account.id && archived.sharesLogin(with: other)
          })
        {
          guard archived.identity == profile.account.identityHash else {
            throw QuotaReadingError.identityMismatch
          }
          // The app-server can save new credentials even if the subsequent quota read fails.
          let attempt: Swift.Result<ReadOnlyAccountProbe, Error>
          do {
            attempt = .success(try await reader.probeManagedProfile(codexHomePath: profile.home.path))
          } catch {
            attempt = .failure(error)
          }
          let saved = try Authentication(at: profile.authenticationURL)
          guard saved.matchesAccount(archived) else { throw QuotaReadingError.identityMismatch }
          if saved.lastRefresh != archived.lastRefresh { renewedCount += 1 }
          probe = try attempt.get()
        } else {
          probe = try await reader.probe(codexHomePath: profile.home.path)
        }
        guard probe.identityHash == profile.account.identityHash else {
          throw QuotaReadingError.identityMismatch
        }
        snapshots[profile.account.id] = AccountQuotaSnapshot(
          email: probe.email, planName: probe.planName, usage: probe.usage)
      } catch {
        // The scheduled command reports counts only. Errors may contain private account data.
      }
    }
    try snapshotStore.save(snapshots, for: accounts, refreshedAt: refreshedAt)
    return Result(
      updatedCount: snapshots.count, failedCount: profiles.count - snapshots.count,
      renewedCount: renewedCount)
  }

  private func isManaged(_ directory: URL) -> Bool {
    let root = accountsRootURL
    return directory.deletingLastPathComponent() == root
      && UUID(uuidString: directory.lastPathComponent) != nil
      && directory.resolvingSymlinksInPath().path == directory.path
      && (try? RecoveryTransactionPathContract.validateExistingPrivateDirectory(root)) != nil
      && (try? RecoveryTransactionPathContract.validateExistingPrivateDirectory(directory)) != nil
  }

  private struct Profile {
    let account: AccountRecord
    let home: URL

    var authenticationURL: URL { home.appendingPathComponent("auth.json") }
  }

  private struct Authentication {
    let identity: String
    let accountID: String?
    let userID: String?
    let refreshToken: String?
    let loginOwnerID: String?
    let lastRefresh: String?
    let isManaged: Bool

    init(at url: URL) throws {
      let data = try SecureAuthenticationFileInstaller.readPrivateAuthenticationFile(at: url)
      identity = try PinnedAuthenticationIdentityReader.identity(fromAuthenticationData: data).rawValue
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let tokens = object["tokens"] as? [String: Any]
      else { throw QuotaReadingError.invalidAuthenticationFile }
      let claims = try CodexCredentialClaims(authenticationData: data)
      let accessAuth = claims.accessClaims?["https://api.openai.com/auth"] as? [String: Any]
      let idAuth = claims.idClaims?["https://api.openai.com/auth"] as? [String: Any]
      let accessAccount = accessAuth?["chatgpt_account_id"] as? String
      let idUser = (idAuth?["chatgpt_user_id"] as? String) ?? (idAuth?["user_id"] as? String)
      guard accessAccount == nil || accessAccount == claims.accountID,
        idUser == nil || claims.userID == idUser
      else { throw QuotaReadingError.identityMismatch }
      accountID = claims.accountID
      userID = claims.userID
      refreshToken = tokens["refresh_token"] as? String
      loginOwnerID = tokens["login_owner_id"] as? String
      lastRefresh = object["last_refresh"] as? String
      let explicitMode = object["auth_mode"] as? String
      let otherModes = ["personal_access_token", "bedrock_api_key", "bedrock_access_keys", "OPENAI_API_KEY"]
      let legacyMode = object["auth_mode"] == nil || object["auth_mode"] is NSNull
      let legacyManaged = legacyMode && otherModes.allSatisfy { object[$0] == nil || object[$0] is NSNull }
      let provenance = tokens["oauth_provenance"]
      let issuer = (provenance as? [String: Any])?["issuer"] as? String
      let isProductionIssuer = provenance == nil || provenance is NSNull
        || issuer == "https://auth.openai.com" || issuer == "https://auth.openai.com/"
      isManaged = (explicitMode == "chatgpt" || legacyManaged) && isProductionIssuer
    }

    func matchesAccount(_ other: Self) -> Bool {
      guard let accountID, !accountID.isEmpty, let userID, !userID.isEmpty else { return false }
      return identity == other.identity && accountID == other.accountID && userID == other.userID
    }

    func sharesLogin(with other: Self) -> Bool {
      (refreshToken?.isEmpty == false && refreshToken == other.refreshToken)
        || (loginOwnerID?.isEmpty == false && loginOwnerID == other.loginOwnerID)
    }

    func canRenew(while active: Self) -> Bool {
      guard isManaged, refreshToken?.isEmpty == false,
        accountID?.isEmpty == false, userID?.isEmpty == false,
        active.accountID?.isEmpty == false, active.userID?.isEmpty == false
      else { return false }
      return !sharesLogin(with: active) && userID != active.userID
    }
  }
}

private enum BackgroundUsageRefreshError: Error {
  case switchRecoveryPending
}
