import CoreFoundation
import Foundation
import SwitchGPTDesktopIntegration
import SwitchGPTSafetyCore

public struct BackgroundUsageRefresh: Sendable {
  private static let renewalWindow: TimeInterval = 3 * 24 * 60 * 60
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
    public let renewalFailedCount: Int
  }

  public func run() async throws -> Result {
    guard FileManager.default.fileExists(atPath: stateStore.fileURL.path) else {
      return Result(updatedCount: 0, failedCount: 0, renewedCount: 0, renewalFailedCount: 0)
    }
    let lock = try acquireCredentialLock()
    defer { lock.release() }
    let accounts = try stateStore.load()?.accounts ?? []
    let refreshedAt = Date()
    let batch = profilesAndCredentials(for: accounts)
    var snapshots: [AccountID: AccountQuotaSnapshot] = [:]
    var renewedCount = 0
    var renewalFailedCount = 0
    for profile in batch.profiles {
      try Task.checkCancellation()
      do {
        let probe: ReadOnlyAccountProbe
        if let active = try? Authentication(at: activeAuthenticationURL),
          let expectedIdentity = profile.account.identityHash, active.identities.contains(expectedIdentity)
        {
          if let archived = batch.credentials[profile.account.id], !archived.matchesAccount(active) {
            throw QuotaReadingError.identityMismatch
          }
          probe = try await reader.probeActiveProfile(authenticationFileURL: activeAuthenticationURL)
        } else if let archived = renewableCredentials(for: profile, in: batch.credentials) {
          let shouldRenew = archived.accessExpiresAt.map {
            $0.timeIntervalSinceNow <= Self.renewalWindow
          } ?? false
          let result = await refreshManaged(profile, previous: archived, forceRenewal: shouldRenew)
          if result.renewed {
            renewedCount += 1
          } else if shouldRenew {
            renewalFailedCount += 1
          }
          probe = try result.probe.get()
        } else {
          probe = try await reader.probe(codexHomePath: profile.home.path)
        }
        snapshots[profile.account.id] = try snapshot(from: probe, for: profile)
      } catch {
        // The scheduled command reports counts only. Errors may contain private account data.
      }
    }
    try snapshotStore.save(snapshots, for: accounts, refreshedAt: refreshedAt)
    return Result(
      updatedCount: snapshots.count, failedCount: batch.profiles.count - snapshots.count,
      renewedCount: renewedCount, renewalFailedCount: renewalFailedCount)
  }

  /// A real switch can need the target between scheduled runs. This only recovers
  /// an expired, independently managed target after its ordinary quota read failed.
  func recoverExpiredSwitchTarget(_ account: AccountRecord) async throws -> AccountQuotaSnapshot? {
    let lock = try acquireCredentialLock()
    defer { lock.release() }
    let batch = profilesAndCredentials(for: try stateStore.load()?.accounts ?? [])
    guard let profile = batch.profiles.first(where: {
      $0.account.id == account.id && $0.account.source == account.source
        && $0.account.identityHash == account.identityHash
    }), let archived = renewableCredentials(for: profile, in: batch.credentials),
      let expiresAt = archived.accessExpiresAt, expiresAt <= Date()
    else { return nil }
    let result = await refreshManaged(profile, previous: archived, forceRenewal: true)
    guard result.renewed else { return nil }
    return try snapshot(from: result.probe.get(), for: profile)
  }

  private func acquireCredentialLock() throws -> TransactionLock {
    let appDirectory = stateStore.fileURL.deletingLastPathComponent()
    let lock = try AccountCredentialLock.acquire(appDirectory: appDirectory)
    let transactions = appDirectory.appendingPathComponent("Transactions", isDirectory: true)
    if FileManager.default.fileExists(atPath: transactions.path) {
      try RecoveryTransactionPathContract.validateExistingPrivateDirectory(transactions)
      guard try FileManager.default.contentsOfDirectory(atPath: transactions.path).isEmpty else {
        throw BackgroundUsageRefreshError.switchRecoveryPending
      }
    }
    return lock
  }

  private func profilesAndCredentials(for accounts: [AccountRecord])
    -> (profiles: [Profile], credentials: [AccountID: Authentication])
  {
    let profiles = accounts.compactMap { account -> Profile? in
      guard case .codexHome(let path) = account.source else { return nil }
      return Profile(
        account: account, home: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL)
    }
    let credentials = profiles.reduce(into: [AccountID: Authentication]()) { result, profile in
      result[profile.account.id] = try? Authentication(at: profile.authenticationURL)
    }
    return (profiles, credentials)
  }

  private func renewableCredentials(for profile: Profile, in credentials: [AccountID: Authentication])
    -> Authentication?
  {
    guard isManaged(profile.home),
      let expectedIdentity = profile.account.identityHash,
      let archived = credentials[profile.account.id], archived.identities.contains(expectedIdentity),
      let active = try? Authentication(at: activeAuthenticationURL), archived.canRenew(while: active),
      !credentials.contains(where: { id, other in
        id != profile.account.id && archived.sharesLogin(with: other)
      })
    else { return nil }
    return archived
  }

  private func refreshManaged(_ profile: Profile, previous: Authentication, forceRenewal: Bool) async
    -> (probe: Swift.Result<ReadOnlyAccountProbe, Error>, renewed: Bool)
  {
    // account/read can succeed even if renewal fails, and the quota query can
    // fail after Codex has already persisted the replacement credentials.
    let attempt: Swift.Result<ReadOnlyAccountProbe, Error>
    do {
      attempt = .success(try await reader.probeManagedProfile(
        codexHomePath: profile.home.path, refreshToken: forceRenewal))
    } catch {
      attempt = .failure(error)
    }
    guard let saved = try? Authentication(at: profile.authenticationURL), saved.matchesAccount(previous)
    else { return (.failure(QuotaReadingError.identityMismatch), false) }
    return (attempt, saved.renewed(since: previous))
  }

  private func snapshot(from probe: ReadOnlyAccountProbe, for profile: Profile) throws -> AccountQuotaSnapshot {
    guard let expected = profile.account.identityHash,
      probe.identityHash == expected || probe.email.map({
        PinnedAuthenticationIdentityReader.identityHashes(forEmail: $0).contains(expected)
      }) == true
    else { throw QuotaReadingError.identityMismatch }
    return AccountQuotaSnapshot(email: probe.email, planName: probe.planName, usage: probe.usage)
  }

  private func isManaged(_ directory: URL) -> Bool {
    (try? CodexManagedAccountOnboarder(accountsRootURL: accountsRootURL)
      .managedAuthenticationURL(for: directory.path)) != nil
  }

  private struct Profile {
    let account: AccountRecord
    let home: URL

    var authenticationURL: URL { home.appendingPathComponent("auth.json") }
  }

  private struct Authentication {
    let identities: Set<String>
    let accountID: String?
    let userID: String?
    let refreshToken: String?
    let loginOwnerID: String?
    let lastRefresh: String?
    let accessExpiresAt: Date?
    let isManaged: Bool

    init(at url: URL) throws {
      let data = try SecureAuthenticationFileInstaller.readPrivateAuthenticationFile(at: url)
      identities = try PinnedAuthenticationIdentityReader.identityHashes(fromAuthenticationData: data)
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let tokens = object["tokens"] as? [String: Any]
      else { throw QuotaReadingError.invalidAuthenticationFile }
      let claims = try CodexCredentialClaims(authenticationData: data)
      if let expiration = claims.accessClaims?["exp"] as? NSNumber,
        CFGetTypeID(expiration) != CFBooleanGetTypeID(),
        expiration.doubleValue.isFinite, expiration.doubleValue > 0
      {
        accessExpiresAt = Date(timeIntervalSince1970: expiration.doubleValue)
      } else {
        accessExpiresAt = nil
      }
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
      return !identities.isDisjoint(with: other.identities)
        && accountID == other.accountID && userID == other.userID
    }

    func sharesLogin(with other: Self) -> Bool {
      (refreshToken?.isEmpty == false && refreshToken == other.refreshToken)
        || (loginOwnerID?.isEmpty == false && loginOwnerID == other.loginOwnerID)
    }

    func renewed(since previous: Self) -> Bool {
      guard let lastRefresh, lastRefresh != previous.lastRefresh else { return false }
      guard let previousExpiry = previous.accessExpiresAt else { return true }
      guard let accessExpiresAt else { return false }
      return accessExpiresAt > previousExpiry && accessExpiresAt > Date()
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
