import CryptoKit
import Darwin
import Foundation
import SwitchGPTSafetyCore
import XCTest

@testable import SwitchGPTDesktopIntegration

final class DesktopIntegrationTests: XCTestCase {
  func testChatGPTCompatibilityClassifiesValidatedAndUnvalidatedVersions() {
    XCTAssertTrue(
      ChatGPTDesktopCompatibility.supports(version: "26.810.52044", build: "6662")
    )
    XCTAssertEqual(
      ChatGPTDesktopCompatibility.assessment(version: "26.810.52044", build: "6662"),
      .validated(ChatGPTDesktopVersion(version: "26.810.52044", build: "6662"))
    )
    XCTAssertFalse(
      ChatGPTDesktopCompatibility.supports(version: "26.810.52044", build: "6663")
    )
    XCTAssertEqual(
      ChatGPTDesktopCompatibility.assessment(version: "26.810.52044", build: "6663"),
      .unvalidated(version: "26.810.52044", build: "6663")
    )
    XCTAssertFalse(
      ChatGPTDesktopCompatibility.supports(version: "26.811.00000", build: "6662")
    )
    XCTAssertEqual(
      ChatGPTDesktopCompatibility.assessment(version: "26.811.00000", build: "6662"),
      .unvalidated(version: "26.811.00000", build: "6662")
    )
    XCTAssertFalse(ChatGPTDesktopCompatibility.supports(version: nil, build: "6662"))
    XCTAssertFalse(ChatGPTDesktopCompatibility.supports(version: "26.810.52044", build: nil))
    XCTAssertEqual(
      ChatGPTDesktopCompatibility.assessment(version: nil, build: "6662"),
      .unvalidated(version: nil, build: "6662")
    )
  }

  private var temporaryDirectories: [URL] = []

  func testShutdownUpgradeStaysWithinConfirmedCompatibilityRisk() {
    let confirmed = ChatGPTDesktopCompatibility.assessment(version: "26.1106.51428", build: "26605")
    let upgrade = ChatGPTDesktopCompatibility.assessment(version: "26.1111.21308", build: "27194")
    let validated = ChatGPTDesktopCompatibility.assessment(version: "26.810.52044", build: "6662")
    XCTAssertTrue(confirmed.allowsUpgradeDuringShutdown(to: upgrade))
    XCTAssertFalse(upgrade.allowsUpgradeDuringShutdown(to: confirmed))
    XCTAssertFalse(confirmed.allowsUpgradeDuringShutdown(to: confirmed))
    XCTAssertFalse(validated.allowsUpgradeDuringShutdown(to: upgrade))
    XCTAssertFalse(confirmed.allowsUpgradeDuringShutdown(to: .unvalidated(version: nil, build: nil)))
  }

  override func tearDownWithError() throws {
    for directory in temporaryDirectories {
      try? FileManager.default.removeItem(at: directory)
    }
    temporaryDirectories.removeAll()
  }

  func testTargetInstallSnapshotsOriginalAndRollbackRestoresIt() throws {
    let fixture = try makeFixture()
    let process = FixtureProcessController()
    let adapter = try RealChatGPTDesktopAdapter(
      sourceIdentity: fixture.identityA,
      profiles: fixture.profiles,
      processController: process,
      identityReader: PinnedAuthenticationIdentityReader(
        authenticationFileURL: fixture.activeAuthenticationURL
      ),
      authenticationInstaller: fixture.installer
    )

    try adapter.stop()
    try adapter.install(identity: fixture.identityB)
    XCTAssertEqual(try adapter.currentIdentity(), fixture.identityB)
    XCTAssertTrue(try fixture.installer.hasRecoverySnapshot())
    try adapter.start()

    try adapter.stop()
    try adapter.install(identity: fixture.identityA)
    XCTAssertEqual(try adapter.currentIdentity(), fixture.identityA)
    try adapter.start()

    XCTAssertEqual(process.stopCount, 2)
    XCTAssertEqual(process.startCount, 2)
  }

  func testRecoveryBeforeTargetInstallIsNoOpForVerifiedSource() throws {
    let fixture = try makeFixture()
    let process = FixtureProcessController()
    let adapter = try RealChatGPTDesktopAdapter(
      sourceIdentity: fixture.identityA,
      profiles: fixture.profiles,
      processController: process,
      identityReader: PinnedAuthenticationIdentityReader(
        authenticationFileURL: fixture.activeAuthenticationURL
      ),
      authenticationInstaller: fixture.installer
    )

    try adapter.install(identity: fixture.identityA)

    XCTAssertFalse(try fixture.installer.hasRecoverySnapshot())
    XCTAssertEqual(try adapter.currentIdentity(), fixture.identityA)
  }

  func testProjectStateIsSynchronizedWhileStoppedBeforeInstallingAuthentication() throws {
    let fixture = try makeFixture()
    let process = FixtureProcessController()
    let identityReader = PinnedAuthenticationIdentityReader(
      authenticationFileURL: fixture.activeAuthenticationURL
    )
    let projects = FixtureProjectStateSynchronizer(
      prepare: {
        XCTAssertFalse(process.running)
        XCTAssertEqual(try identityReader.currentIdentity(), fixture.identityA)
      },
      recover: {
        XCTAssertFalse(process.running)
        XCTAssertEqual(try identityReader.currentIdentity(), fixture.identityB)
      }
    )
    let adapter = try RealChatGPTDesktopAdapter(
      sourceIdentity: fixture.identityA,
      profiles: fixture.profiles,
      processController: process,
      identityReader: identityReader,
      authenticationInstaller: fixture.installer,
      projectStateSynchronizer: projects
    )

    XCTAssertThrowsError(try adapter.install(identity: fixture.identityB))
    XCTAssertFalse(try fixture.installer.hasRecoverySnapshot())
    try adapter.stop()
    try adapter.install(identity: fixture.identityB)
    XCTAssertEqual(projects.prepareCount, 1)
    XCTAssertEqual(try identityReader.currentIdentity(), fixture.identityB)
    try adapter.install(identity: fixture.identityA)
    XCTAssertEqual(projects.recoveryCount, 1)
    XCTAssertEqual(try identityReader.currentIdentity(), fixture.identityA)
  }

  func testProjectStateFailureDoesNotReplaceAuthentication() throws {
    let fixture = try makeFixture()
    let projects = FixtureProjectStateSynchronizer(
      prepare: { throw DesktopIntegrationError.identityMismatch }
    )
    let adapter = try RealChatGPTDesktopAdapter(
      sourceIdentity: fixture.identityA,
      profiles: fixture.profiles,
      processController: FixtureProcessController(running: false),
      identityReader: PinnedAuthenticationIdentityReader(
        authenticationFileURL: fixture.activeAuthenticationURL
      ),
      authenticationInstaller: fixture.installer,
      projectStateSynchronizer: projects
    )
    let before = try Data(contentsOf: fixture.activeAuthenticationURL)

    XCTAssertThrowsError(try adapter.install(identity: fixture.identityB))

    XCTAssertEqual(try Data(contentsOf: fixture.activeAuthenticationURL), before)
    XCTAssertFalse(try fixture.installer.hasRecoverySnapshot())
    XCTAssertEqual(projects.prepareCount, 1)
  }

  func testApplicationChangeDuringExitSkipsProjectAndCredentialWrites() throws {
    let fixture = try makeFixture()
    let process = FixtureProcessController()
    let projects = FixtureProjectStateSynchronizer()
    let adapter = try RealChatGPTDesktopAdapter(
      sourceIdentity: fixture.identityA,
      profiles: fixture.profiles,
      processController: process,
      identityReader: PinnedAuthenticationIdentityReader(authenticationFileURL: fixture.activeAuthenticationURL),
      authenticationInstaller: fixture.installer,
      projectStateSynchronizer: projects,
      checkTargetApplication: { _ in throw SafetyError.targetApplicationChanged }
    )

    let store = try TransactionStore(directoryURL: fixture.root.appendingPathComponent("switch"))
    let result = try SwitchTransactionEngine(store: store, desktop: adapter)
      .beginSwitch(from: fixture.identityA, to: fixture.identityB)

    XCTAssertEqual(result.failureReason, .targetApplicationChanged)
    XCTAssertEqual(result.phase, .rolledBack)
    XCTAssertEqual(result.targetLaunchAttempts, 0)
    XCTAssertEqual(projects.prepareCount, 0)
    XCTAssertEqual(try adapter.currentIdentity(), fixture.identityA)
    XCTAssertFalse(try fixture.installer.hasRecoverySnapshot())
  }

  func testApplicationChangeBeforeLaunchAllowsSourceRecovery() throws {
    let fixture = try makeFixture()
    let process = FixtureProcessController()
    var applicationChanged = false
    let adapter = try RealChatGPTDesktopAdapter(
      sourceIdentity: fixture.identityA,
      profiles: fixture.profiles,
      processController: process,
      identityReader: PinnedAuthenticationIdentityReader(authenticationFileURL: fixture.activeAuthenticationURL),
      authenticationInstaller: fixture.installer,
      checkTargetApplication: { _ in
        if applicationChanged { throw DesktopIntegrationError.desktopDidNotLaunch }
      }
    )

    try adapter.stop()
    try adapter.install(identity: fixture.identityB)
    applicationChanged = true
    XCTAssertThrowsError(try adapter.start())
    XCTAssertEqual(process.startCount, 0)

    try adapter.install(identity: fixture.identityA)
    try adapter.start()
    XCTAssertEqual(try adapter.currentIdentity(), fixture.identityA)
    XCTAssertEqual(process.startCount, 1)
  }

  func testUpgradeIsPinnedAfterExitBeforeProjectsAndCredentialHandoff() throws {
    let fixture = try makeFixture()
    let process = FixtureProcessController()
    var pinCaptured = false
    var pinChecks = 0
    let projects = FixtureProjectStateSynchronizer(prepare: {
      XCTAssertTrue(pinCaptured)
      XCTAssertEqual(pinChecks, 1)
    })
    let adapter = try RealChatGPTDesktopAdapter(
      sourceIdentity: fixture.identityA,
      profiles: fixture.profiles,
      processController: process,
      identityReader: PinnedAuthenticationIdentityReader(authenticationFileURL: fixture.activeAuthenticationURL),
      authenticationInstaller: fixture.installer,
      projectStateSynchronizer: projects,
      checkTargetApplication: { check in
        XCTAssertFalse(process.running)
        switch check {
        case .afterExit:
          XCTAssertFalse(pinCaptured)
          pinCaptured = true
        case .pinnedBuild:
          XCTAssertTrue(pinCaptured)
          pinChecks += 1
        }
      }
    )

    let store = try TransactionStore(directoryURL: fixture.root.appendingPathComponent("switch"))
    let result = try SwitchTransactionEngine(store: store, desktop: adapter)
      .beginSwitch(from: fixture.identityA, to: fixture.identityB)
    XCTAssertEqual(result.phase, .committed)
    XCTAssertEqual(try adapter.currentIdentity(), fixture.identityB)
    XCTAssertEqual(process.startCount, 1)
    XCTAssertEqual(pinChecks, 2)
  }

  func testSourceCaptureFailureRejectsBeforeDesktopStops() throws {
    let fixture = try makeFixture()
    let process = FixtureProcessController()
    let managedURLs = (1...6).map { fixture.root.appendingPathComponent("managed-\($0).json") }
    let authority = FixtureProjectAuthority(
      synchronize: { urls in
        XCTAssertTrue(process.running)
        XCTAssertEqual(urls, managedURLs)
        throw LocalProjectStateSynchronizationError.stateMismatch
      }
    )
    let adapter = try RealChatGPTDesktopAdapter(
      sourceIdentity: fixture.identityA,
      profiles: fixture.profiles,
      processController: process,
      identityReader: PinnedAuthenticationIdentityReader(authenticationFileURL: fixture.activeAuthenticationURL),
      authenticationInstaller: fixture.installer,
      projectStateSynchronizer: authority,
      activeAuthenticationURL: fixture.activeAuthenticationURL,
      managedAuthenticationURLs: managedURLs
    )
    let store = try TransactionStore(directoryURL: fixture.root.appendingPathComponent("gate-transaction"))
    let authentication = try Data(contentsOf: fixture.activeAuthenticationURL)

    XCTAssertThrowsError(try SwitchTransactionEngine(store: store, desktop: adapter)
      .beginSwitch(from: fixture.identityA, to: fixture.identityB))

    XCTAssertEqual(process.stopCount, 0)
    XCTAssertEqual(process.startCount, 0)
    XCTAssertNil(try store.load())
    XCTAssertEqual(try Data(contentsOf: fixture.activeAuthenticationURL), authentication)
    XCTAssertFalse(try fixture.installer.hasRecoverySnapshot())
    XCTAssertEqual(authority.synchronizeCount, 1)
  }

  func testPostExitMismatchRejectsTargetAndReopensSource() throws {
    let fixture = try makeFixture()
    let process = FixtureProcessController()
    let authority = FixtureProjectAuthority(
      synchronize: { _ in XCTAssertTrue(process.running) },
      afterExit: { _ in
        XCTAssertFalse(process.running)
        throw LocalProjectStateSynchronizationError.stateMismatch
      }
    )
    let adapter = try RealChatGPTDesktopAdapter(
      sourceIdentity: fixture.identityA,
      profiles: fixture.profiles,
      processController: process,
      identityReader: PinnedAuthenticationIdentityReader(authenticationFileURL: fixture.activeAuthenticationURL),
      authenticationInstaller: fixture.installer,
      projectStateSynchronizer: authority
    )
    let store = try TransactionStore(directoryURL: fixture.root.appendingPathComponent("post-exit-transaction"))
    let authentication = try Data(contentsOf: fixture.activeAuthenticationURL)

    let result = try SwitchTransactionEngine(store: store, desktop: adapter)
      .beginSwitch(from: fixture.identityA, to: fixture.identityB)

    XCTAssertEqual(result.phase, .rolledBack)
    XCTAssertFalse(result.targetWasInstalled)
    XCTAssertEqual(authority.synchronizeCount, 1)
    XCTAssertEqual(authority.distributeCount, 1)
    XCTAssertEqual(authority.verifyCount, 0)
    XCTAssertEqual(authority.recoverCount, 1)
    XCTAssertEqual(process.stopCount, 1)
    XCTAssertEqual(process.startCount, 1)
    XCTAssertEqual(try Data(contentsOf: fixture.activeAuthenticationURL), authentication)
    XCTAssertFalse(try fixture.installer.hasRecoverySnapshot())
  }

  func testAccountCopiesAreWrittenOnlyAfterExitAndVerifiedBeforeAuthenticationChanges() throws {
    let fixture = try makeFixture()
    let process = FixtureProcessController()
    let reader = PinnedAuthenticationIdentityReader(authenticationFileURL: fixture.activeAuthenticationURL)
    let managedURLs = (1...6).map { fixture.root.appendingPathComponent("managed-\($0).json") }
    var events: [String] = []
    let authority = FixtureProjectAuthority(
      synchronize: { urls in
        XCTAssertTrue(process.running)
        XCTAssertEqual(urls, managedURLs)
        events.append("capture")
      },
      afterExit: { urls in
        XCTAssertFalse(process.running)
        XCTAssertEqual(process.stopCount, 1)
        XCTAssertEqual(urls, managedURLs)
        XCTAssertEqual(try reader.currentIdentity(), fixture.identityA)
        events.append("writeAll")
      },
      verify: {
        XCTAssertFalse(process.running)
        XCTAssertEqual(try reader.currentIdentity(), fixture.identityA)
        events.append("verifyAll")
      },
      approve: { events.append("approve") }
    )
    let adapter = try RealChatGPTDesktopAdapter(
      sourceIdentity: fixture.identityA,
      profiles: fixture.profiles,
      processController: process,
      identityReader: reader,
      authenticationInstaller: fixture.installer,
      projectStateSynchronizer: authority,
      activeAuthenticationURL: fixture.activeAuthenticationURL,
      managedAuthenticationURLs: managedURLs
    )
    let store = try TransactionStore(directoryURL: fixture.root.appendingPathComponent("ordered-transaction"))

    let result = try SwitchTransactionEngine(store: store, desktop: adapter)
      .beginSwitch(from: fixture.identityA, to: fixture.identityB)

    XCTAssertEqual(result.phase, .committed)
    XCTAssertEqual(events, ["capture", "writeAll", "verifyAll", "approve"])
    XCTAssertEqual(try reader.currentIdentity(), fixture.identityB)
    XCTAssertEqual(process.startCount, 1)
  }

  func testSwitchArchivesCredentialsRenewedDuringDesktopExit() throws {
    let fixture = try makeFixture()
    let process = FixtureProcessController()
    let authority = FixtureProjectAuthority(afterExit: { _ in
      let current = try Data(contentsOf: fixture.activeAuthenticationURL)
      try (current + Data("\n".utf8)).write(to: fixture.activeAuthenticationURL)
    })
    let adapter = try RealChatGPTDesktopAdapter(
      sourceIdentity: fixture.identityA,
      profiles: fixture.profiles,
      processController: process,
      identityReader: PinnedAuthenticationIdentityReader(
        authenticationFileURL: fixture.activeAuthenticationURL),
      authenticationInstaller: fixture.installer,
      projectStateSynchronizer: authority,
      activeAuthenticationURL: fixture.activeAuthenticationURL,
      preserveDepartingCredentialsAfterExit: true)
    let store = try TransactionStore(directoryURL: fixture.root.appendingPathComponent("switch"))
    let source = try XCTUnwrap(fixture.profiles.first?.authenticationFileURL)
    let previous = try Data(contentsOf: source)

    let result = try SwitchTransactionEngine(store: store, desktop: adapter)
      .beginSwitch(from: fixture.identityA, to: fixture.identityB)

    XCTAssertEqual(result.phase, .committed)
    XCTAssertEqual(try Data(contentsOf: source), previous + Data("\n".utf8))
    XCTAssertEqual(try Data(contentsOf: fixture.recoverySnapshotURL), try Data(contentsOf: source))
  }

  func testEarlyArmedRecoveryUsesSnapshotCreatedLaterByTheSwitch() throws {
    let fixture = try makeFixture()
    let projects = FixtureProjectStateSynchronizer()
    let recovery = try RealChatGPTDesktopAdapter(
      sourceIdentity: fixture.identityA,
      profiles: [DesktopCredentialProfile(
        identity: fixture.identityA,
        authenticationFileURL: fixture.activeAuthenticationURL
      )],
      processController: FixtureProcessController(running: false),
      identityReader: PinnedAuthenticationIdentityReader(authenticationFileURL: fixture.activeAuthenticationURL),
      authenticationInstaller: fixture.installer,
      projectStateSynchronizer: projects,
      recoveryAuthenticationURL: fixture.recoverySnapshotURL
    )

    try recovery.install(identity: fixture.identityA)
    XCTAssertEqual(projects.recoverySourceURLs, [fixture.activeAuthenticationURL])
    XCTAssertFalse(try fixture.installer.hasRecoverySnapshot())

    let forward = try RealChatGPTDesktopAdapter(
      sourceIdentity: fixture.identityA,
      profiles: fixture.profiles,
      processController: FixtureProcessController(running: false),
      identityReader: PinnedAuthenticationIdentityReader(authenticationFileURL: fixture.activeAuthenticationURL),
      authenticationInstaller: fixture.installer
    )
    try forward.install(identity: fixture.identityB)
    XCTAssertEqual(try forward.currentIdentity(), fixture.identityB)

    try recovery.install(identity: fixture.identityA)

    XCTAssertEqual(projects.recoverySourceURLs, [fixture.activeAuthenticationURL, fixture.recoverySnapshotURL])
    XCTAssertEqual(try recovery.currentIdentity(), fixture.identityA)
  }

  func testDesktopReopeningDuringDistributionPreventsCredentialReplacement() throws {
    let fixture = try makeFixture()
    let process = FixtureProcessController(running: false)
    let authority = FixtureProjectAuthority(afterExit: { _ in process.running = true })
    let adapter = try RealChatGPTDesktopAdapter(
      sourceIdentity: fixture.identityA,
      profiles: fixture.profiles,
      processController: process,
      identityReader: PinnedAuthenticationIdentityReader(authenticationFileURL: fixture.activeAuthenticationURL),
      authenticationInstaller: fixture.installer,
      projectStateSynchronizer: authority
    )
    let before = try Data(contentsOf: fixture.activeAuthenticationURL)

    XCTAssertThrowsError(try adapter.install(identity: fixture.identityB)) { error in
      XCTAssertEqual(error as? DesktopIntegrationError, .desktopDidNotTerminate)
    }

    XCTAssertEqual(try Data(contentsOf: fixture.activeAuthenticationURL), before)
    XCTAssertFalse(try fixture.installer.hasRecoverySnapshot())
  }

  func testChangedSourceIdentityDuringDistributionPreventsCredentialReplacement() throws {
    let fixture = try makeFixture()
    let process = FixtureProcessController(running: false)
    let externalAuthentication = try Data(contentsOf: fixture.profileBURL)
    let authority = FixtureProjectAuthority(afterExit: { _ in
      try fixture.installer.installAuthenticationFile(from: fixture.profileBURL)
    })
    let adapter = try RealChatGPTDesktopAdapter(
      sourceIdentity: fixture.identityA,
      profiles: fixture.profiles,
      processController: process,
      identityReader: PinnedAuthenticationIdentityReader(authenticationFileURL: fixture.activeAuthenticationURL),
      authenticationInstaller: fixture.installer,
      projectStateSynchronizer: authority
    )

    XCTAssertThrowsError(try adapter.install(identity: fixture.identityB)) { error in
      XCTAssertEqual(error as? DesktopIntegrationError, .identityMismatch)
    }

    XCTAssertEqual(try Data(contentsOf: fixture.activeAuthenticationURL), externalAuthentication)
    XCTAssertFalse(try fixture.installer.hasRecoverySnapshot())
  }

  func testMissingSnapshotFailsClosedWhenActiveIdentityIsNotSource() throws {
    let fixture = try makeFixture(activeIdentity: .b)
    let adapter = try RealChatGPTDesktopAdapter(
      sourceIdentity: fixture.identityA,
      profiles: fixture.profiles,
      processController: FixtureProcessController(),
      identityReader: PinnedAuthenticationIdentityReader(
        authenticationFileURL: fixture.activeAuthenticationURL
      ),
      authenticationInstaller: fixture.installer
    )

    XCTAssertThrowsError(try adapter.install(identity: fixture.identityA)) { error in
      XCTAssertEqual(error as? DesktopIntegrationError, .missingRecoverySnapshot)
    }
    XCTAssertEqual(try adapter.currentIdentity(), fixture.identityB)
  }

  func testInstallerRejectsBroadPermissionsBeforeCreatingSnapshot() throws {
    let fixture = try makeFixture()
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: fixture.activeAuthenticationURL.path
    )

    XCTAssertThrowsError(try fixture.installer.snapshotActiveStateIfNeeded()) { error in
      XCTAssertEqual(error as? DesktopIntegrationError, .insecureAuthenticationFile)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.recoverySnapshotURL.path))
  }

  func testInstallerRejectsSymlinkSourceWithoutChangingActiveState() throws {
    let fixture = try makeFixture()
    let symlink = fixture.root.appendingPathComponent("linked-auth.json")
    try FileManager.default.createSymbolicLink(
      at: symlink,
      withDestinationURL: fixture.profileBURL
    )
    let before = try Data(contentsOf: fixture.activeAuthenticationURL)

    XCTAssertThrowsError(try fixture.installer.installAuthenticationFile(from: symlink))
    XCTAssertEqual(try Data(contentsOf: fixture.activeAuthenticationURL), before)
  }

  func testIdentityReaderRejectsSymlinkBeforeTransactionCanStart() throws {
    let fixture = try makeFixture()
    let link = fixture.root.appendingPathComponent("active-link.json")
    try FileManager.default.createSymbolicLink(
      at: link,
      withDestinationURL: fixture.activeAuthenticationURL
    )
    let reader = PinnedAuthenticationIdentityReader(authenticationFileURL: link)

    XCTAssertThrowsError(try reader.currentIdentity()) { error in
      XCTAssertEqual(error as? DesktopIntegrationError, .invalidAuthenticationFile)
    }
  }

  func testPrivateProfileArchiveAndSynchronizationRemainPrivateAndAtomic() throws {
    let fixture = try makeFixture()
    let profileDirectory = fixture.root.appendingPathComponent("managed-profile", isDirectory: true)
    try FileManager.default.createDirectory(
      at: profileDirectory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let archivedURL = profileDirectory.appendingPathComponent("auth.json")

    try SecureAuthenticationFileInstaller.archivePrivateAuthenticationFile(
      from: fixture.activeAuthenticationURL,
      to: archivedURL
    )

    XCTAssertEqual(
      try PinnedAuthenticationIdentityReader(authenticationFileURL: archivedURL)
        .currentIdentity(),
      fixture.identityA
    )
    let attributes = try FileManager.default.attributesOfItem(atPath: archivedURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

    try SecureAuthenticationFileInstaller.synchronizePrivateAuthenticationFile(
      from: fixture.profileBURL,
      to: archivedURL
    )
    XCTAssertEqual(
      try PinnedAuthenticationIdentityReader(authenticationFileURL: archivedURL)
        .currentIdentity(),
      fixture.identityB
    )
  }

  func testTerminationFallbackTargetsOnlyOriginalProcessesStillRunning() {
    XCTAssertEqual(
      MacOSChatGPTProcessController.originalProcessesStillRunning(
        original: [101, 102],
        current: [102, 999]
      ),
      [102]
    )
  }

  func testEmptyAppListDoesNotMeanTheObservedProcessExited() {
    var observation = DesktopProcessObservation()
    let start = ContinuousClock.now
    let stabilityPeriod: Duration = .milliseconds(500)
    observation.update(registered: [101], at: start, isAlive: { _ in true })

    let listBecameEmpty = start.advanced(by: .seconds(1))
    observation.update(registered: [], at: listBecameEmpty, isAlive: { _ in true })
    XCTAssertEqual(observation.processIdentifiers, [101])
    XCTAssertFalse(observation.hasStopped(at: listBecameEmpty, stabilityPeriod: stabilityPeriod))

    let processExited = start.advanced(by: .seconds(2))
    observation.update(registered: [], at: processExited, isAlive: { _ in false })
    XCTAssertFalse(observation.hasStopped(at: processExited, stabilityPeriod: stabilityPeriod))
    XCTAssertTrue(observation.hasStopped(
      at: processExited.advanced(by: stabilityPeriod), stabilityPeriod: stabilityPeriod))
  }

  func testAnotherProcessAppearingRestartsTheExitObservationWindow() {
    var observation = DesktopProcessObservation()
    let start = ContinuousClock.now
    let stabilityPeriod: Duration = .milliseconds(500)
    observation.update(registered: [101], at: start, isAlive: { _ in true })
    observation.update(registered: [], at: start.advanced(by: .milliseconds(100)), isAlive: { _ in false })
    observation.update(registered: [102], at: start.advanced(by: .milliseconds(300)), isAlive: { _ in true })

    let later = start.advanced(by: .milliseconds(700))
    XCTAssertFalse(observation.hasStopped(at: later, stabilityPeriod: stabilityPeriod))
    observation.update(registered: [], at: later, isAlive: { _ in false })
    XCTAssertFalse(observation.hasStopped(at: later, stabilityPeriod: stabilityPeriod))
    XCTAssertTrue(observation.hasStopped(at: later.advanced(by: stabilityPeriod), stabilityPeriod: stabilityPeriod))
  }

  func testFreshRecoveryProcessRestoresSnapshotAfterTargetInstallCrash() throws {
    let fixture = try makeFixture()
    let transactionStore = try TransactionStore(
      directoryURL: fixture.root.appendingPathComponent("switch-transaction")
    )
    let firstAdapter = try RealChatGPTDesktopAdapter(
      sourceIdentity: fixture.identityA,
      profiles: fixture.profiles,
      processController: FixtureProcessController(),
      identityReader: PinnedAuthenticationIdentityReader(
        authenticationFileURL: fixture.activeAuthenticationURL
      ),
      authenticationInstaller: fixture.installer
    )
    let engine = SwitchTransactionEngine(
      store: transactionStore,
      desktop: firstAdapter
    ) { point in
      if point == .afterTargetInstalled {
        throw SimulatedProcessExit(at: point)
      }
    }

    XCTAssertThrowsError(
      try engine.beginSwitch(from: fixture.identityA, to: fixture.identityB)
    )
    XCTAssertEqual(
      try PinnedAuthenticationIdentityReader(
        authenticationFileURL: fixture.activeAuthenticationURL
      ).currentIdentity(),
      fixture.identityB
    )

    let recoveryProcess = FixtureProcessController(running: false)
    let recoveryAdapter = try RealChatGPTDesktopAdapter(
      sourceIdentity: fixture.identityA,
      profiles: fixture.profiles,
      processController: recoveryProcess,
      identityReader: PinnedAuthenticationIdentityReader(
        authenticationFileURL: fixture.activeAuthenticationURL
      ),
      authenticationInstaller: try SecureAuthenticationFileInstaller(
        activeAuthenticationURL: fixture.activeAuthenticationURL,
        recoverySnapshotURL: fixture.recoverySnapshotURL
      )
    )

    let recovered = try SwitchTransactionEngine(
      store: transactionStore,
      desktop: recoveryAdapter
    ).recover()

    XCTAssertEqual(recovered.phase, .rolledBack)
    XCTAssertEqual(try recoveryAdapter.currentIdentity(), fixture.identityA)
    XCTAssertEqual(recoveryProcess.startCount, 1)
  }

  private func makeFixture(activeIdentity: FixtureIdentity = .a) throws -> IntegrationFixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("switchgpt-integration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    temporaryDirectories.append(root)

    let activeURL = root.appendingPathComponent("active-auth.json")
    let profileAURL = root.appendingPathComponent("account-a-auth.json")
    let profileBURL = root.appendingPathComponent("account-b-auth.json")
    try writeAuthentication(email: "a@example.test", to: profileAURL)
    try writeAuthentication(email: "b@example.test", to: profileBURL)
    try FileManager.default.copyItem(
      at: activeIdentity == .a ? profileAURL : profileBURL,
      to: activeURL
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activeURL.path)

    let identityA = identity(for: "a@example.test")
    let identityB = identity(for: "b@example.test")
    let recoveryURL = root.appendingPathComponent("transaction/recovery-auth.json")
    return IntegrationFixture(
      root: root,
      identityA: identityA,
      identityB: identityB,
      activeAuthenticationURL: activeURL,
      profileBURL: profileBURL,
      recoverySnapshotURL: recoveryURL,
      profiles: [
        DesktopCredentialProfile(identity: identityA, authenticationFileURL: profileAURL),
        DesktopCredentialProfile(identity: identityB, authenticationFileURL: profileBURL),
      ],
      installer: try SecureAuthenticationFileInstaller(
        activeAuthenticationURL: activeURL,
        recoverySnapshotURL: recoveryURL
      )
    )
  }

  private func writeAuthentication(email: String, to url: URL) throws {
    let header = Data("{\"alg\":\"none\"}".utf8).base64URLEncodedString()
    let payload = try JSONSerialization.data(withJSONObject: [
      "email": email,
      "https://api.openai.com/auth": [
        "chatgpt_user_id": "user-\(email)", "chatgpt_account_id": "workspace-\(email)",
      ],
    ])
      .base64URLEncodedString()
    let object: [String: Any] = [
      "auth_mode": "chatgpt",
      "tokens": ["id_token": header + "." + payload + ".fixture"],
    ]
    try JSONSerialization.data(withJSONObject: object).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func identity(for email: String) -> IdentityID {
    let digest = SHA256.hash(data: Data(email.utf8))
    return IdentityID(
      rawValue: digest.map { String(format: "%02x", $0) }.joined().prefix(12).description)!
  }
}

private enum FixtureIdentity { case a, b }

private final class FixtureProjectStateSynchronizer: LocalProjectStateSynchronizing {
  var prepareCount = 0
  var recoveryCount = 0
  var recoverySourceURLs: [URL] = []
  let prepare: () throws -> Void
  let recover: () throws -> Void

  init(prepare: @escaping () throws -> Void = {}, recover: @escaping () throws -> Void = {}) {
    self.prepare = prepare
    self.recover = recover
  }

  func prepareSwitch(sourceAuthenticationURL: URL, targetAuthenticationURL: URL) throws {
    prepareCount += 1
    try prepare()
  }

  func recoverSource(sourceAuthenticationURL: URL) throws {
    recoveryCount += 1
    recoverySourceURLs.append(sourceAuthenticationURL)
    try recover()
  }
}

private final class FixtureProjectAuthority: LocalProjectAuthorityManaging {
  var synchronizeCount = 0
  var distributeCount = 0
  var verifyCount = 0
  var recoverCount = 0
  let synchronize: ([URL]) throws -> Void
  let verify: () throws -> Void
  let afterExit: ([URL]) throws -> Void
  let approve: () throws -> Void

  init(
    synchronize: @escaping ([URL]) throws -> Void = { _ in },
    afterExit: @escaping ([URL]) throws -> Void = { _ in },
    verify: @escaping () throws -> Void = {},
    approve: @escaping () throws -> Void = {}
  ) {
    self.synchronize = synchronize
    self.verify = verify
    self.afterExit = afterExit
    self.approve = approve
  }

  func initializeActive(authenticationURL: URL) throws {}
  func captureActive(authenticationURL: URL) throws {}
  func synchronizeAndVerifyAll(activeAuthenticationURL: URL, managedAuthenticationURLs: [URL]) throws {
    try prepareForExit(activeAuthenticationURL: activeAuthenticationURL, managedAuthenticationURLs: managedAuthenticationURLs)
  }
  func prepareForExit(activeAuthenticationURL: URL, managedAuthenticationURLs: [URL]) throws {
    synchronizeCount += 1
    try synchronize(managedAuthenticationURLs)
  }
  func synchronizeAfterExit(activeAuthenticationURL: URL, managedAuthenticationURLs: [URL]) throws {
    distributeCount += 1
    try afterExit(managedAuthenticationURLs)
  }
  func verifyAfterExit(activeAuthenticationURL: URL, managedAuthenticationURLs: [URL]) throws {
    verifyCount += 1
    try verify()
  }
  func prepareSwitch(sourceAuthenticationURL: URL, targetAuthenticationURL: URL) throws { try approve() }
  func recoverSource(sourceAuthenticationURL: URL) throws { recoverCount += 1 }
}

private final class FixtureProcessController: DesktopProcessControlling {
  var running: Bool
  var stopCount = 0
  var startCount = 0

  init(running: Bool = true) {
    self.running = running
  }

  func isRunning() throws -> Bool { running }
  func terminateAndWait() throws {
    running = false
    stopCount += 1
  }
  func launchAndWait() throws {
    running = true
    startCount += 1
  }
}

private struct IntegrationFixture {
  let root: URL
  let identityA: IdentityID
  let identityB: IdentityID
  let activeAuthenticationURL: URL
  let profileBURL: URL
  let recoverySnapshotURL: URL
  let profiles: [DesktopCredentialProfile]
  let installer: SecureAuthenticationFileInstaller
}

extension Data {
  fileprivate func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
