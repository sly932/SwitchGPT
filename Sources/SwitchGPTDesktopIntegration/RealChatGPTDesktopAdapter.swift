import Foundation
import SwitchGPTSafetyCore

public enum TargetApplicationCheck {
  case afterExit
  case pinnedBuild
}

/// Concrete transaction adapter boundary for complete ChatGPT Desktop switching.
/// This target is intentionally not linked by the default UI until the real gate is authorized.
public final class RealChatGPTDesktopAdapter: TransactionDesktop {
  private let sourceIdentity: IdentityID
  private let profilesByIdentity: [IdentityID: DesktopCredentialProfile]
  private let processController: DesktopProcessControlling
  private let identityReader: InstalledIdentityReading
  private let authenticationInstaller: AuthenticationStateInstalling
  private let projectStateSynchronizer: LocalProjectStateSynchronizing?
  private let activeAuthenticationURL: URL
  private let managedAuthenticationURLs: [URL]
  private let recoveryAuthenticationURL: URL?
  private let preserveDepartingCredentialsAfterExit: Bool
  private let checkTargetApplication: ((TargetApplicationCheck) throws -> Void)?
  private var isStartingTarget = false

  public init(
    sourceIdentity: IdentityID,
    profiles: [DesktopCredentialProfile],
    processController: DesktopProcessControlling,
    identityReader: InstalledIdentityReading,
    authenticationInstaller: AuthenticationStateInstalling,
    projectStateSynchronizer: LocalProjectStateSynchronizing? = nil,
    activeAuthenticationURL: URL? = nil,
    managedAuthenticationURLs: [URL]? = nil,
    recoveryAuthenticationURL: URL? = nil,
    preserveDepartingCredentialsAfterExit: Bool = false,
    checkTargetApplication: ((TargetApplicationCheck) throws -> Void)? = nil
  ) throws {
    var profilesByIdentity: [IdentityID: DesktopCredentialProfile] = [:]
    for profile in profiles {
      guard profilesByIdentity.updateValue(profile, forKey: profile.identity) == nil else {
        throw DesktopIntegrationError.duplicateProfile
      }
    }
    guard profilesByIdentity[sourceIdentity] != nil else {
      throw DesktopIntegrationError.missingProfile
    }
    self.sourceIdentity = sourceIdentity
    self.profilesByIdentity = profilesByIdentity
    self.processController = processController
    self.identityReader = identityReader
    self.authenticationInstaller = authenticationInstaller
    self.projectStateSynchronizer = projectStateSynchronizer
    self.activeAuthenticationURL = activeAuthenticationURL
      ?? profilesByIdentity[sourceIdentity]!.authenticationFileURL
    self.managedAuthenticationURLs = managedAuthenticationURLs
      ?? profiles.map(\.authenticationFileURL)
    self.recoveryAuthenticationURL = recoveryAuthenticationURL
    self.preserveDepartingCredentialsAfterExit = preserveDepartingCredentialsAfterExit
    self.checkTargetApplication = checkTargetApplication
  }

  public func prepareSwitch() throws {
    try (projectStateSynchronizer as? LocalProjectAuthorityManaging)?
      .prepareForExit(
        activeAuthenticationURL: activeAuthenticationURL,
        managedAuthenticationURLs: managedAuthenticationURLs
      )
  }

  public func isRunning() throws -> Bool {
    try processController.isRunning()
  }

  public func currentIdentity() throws -> IdentityID {
    try identityReader.currentIdentity()
  }

  public func stop() throws {
    try processController.terminateAndWait()
  }

  public func install(identity: IdentityID) throws {
    if projectStateSynchronizer != nil, try processController.isRunning() {
      throw DesktopIntegrationError.desktopDidNotTerminate
    }
    if identity == sourceIdentity {
      isStartingTarget = false
      guard let source = profilesByIdentity[sourceIdentity] else {
        throw DesktopIntegrationError.missingProfile
      }
      let hasRecoverySnapshot = try authenticationInstaller.hasRecoverySnapshot()
      let sourceAuthenticationURL = hasRecoverySnapshot
        ? recoveryAuthenticationURL ?? source.authenticationFileURL
        : source.authenticationFileURL
      try projectStateSynchronizer?.recoverSource(
        sourceAuthenticationURL: sourceAuthenticationURL
      )
      if hasRecoverySnapshot {
        try authenticationInstaller.restoreRecoverySnapshot()
        return
      }
      guard try identityReader.currentIdentity() == sourceIdentity else {
        throw DesktopIntegrationError.missingRecoverySnapshot
      }
      return
    }

    guard let profile = profilesByIdentity[identity] else {
      throw DesktopIntegrationError.missingProfile
    }
    guard let source = profilesByIdentity[sourceIdentity] else {
      throw DesktopIntegrationError.missingProfile
    }
    try checkTargetApplication?(.afterExit)
    if let authority = projectStateSynchronizer as? LocalProjectAuthorityManaging {
      try authority.synchronizeAfterExit(
        activeAuthenticationURL: activeAuthenticationURL,
        managedAuthenticationURLs: managedAuthenticationURLs
      )
      try authority.verifyAfterExit(
        activeAuthenticationURL: activeAuthenticationURL,
        managedAuthenticationURLs: managedAuthenticationURLs
      )
    }
    try checkTargetApplication?(.pinnedBuild)
    try projectStateSynchronizer?.prepareSwitch(
      sourceAuthenticationURL: source.authenticationFileURL,
      targetAuthenticationURL: profile.authenticationFileURL
    )
    if projectStateSynchronizer != nil, try processController.isRunning() {
      throw DesktopIntegrationError.desktopDidNotTerminate
    }
    guard try identityReader.currentIdentity() == sourceIdentity else {
      throw DesktopIntegrationError.identityMismatch
    }
    if preserveDepartingCredentialsAfterExit {
      // Desktop may have renewed the source since the pre-quit credential copy.
      try SecureAuthenticationFileInstaller.synchronizePrivateAuthenticationFile(
        from: activeAuthenticationURL, to: source.authenticationFileURL,
        expectedIdentity: sourceIdentity)
    }
    try authenticationInstaller.snapshotActiveStateIfNeeded()
    try authenticationInstaller.installAuthenticationFile(
      from: profile.authenticationFileURL
    )
    guard try identityReader.currentIdentity() == identity else {
      throw DesktopIntegrationError.identityMismatch
    }
    isStartingTarget = true
  }

  public func start() throws {
    if isStartingTarget {
      try checkTargetApplication?(.pinnedBuild)
    }
    try processController.launchAndWait()
  }
}
