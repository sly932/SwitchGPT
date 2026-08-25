import XCTest

@testable import SwitchGPTAppCore

final class AppUpdateTests: XCTestCase {
  func testStableReleaseVersionComparisonRejectsPrereleaseTags() throws {
    let current = try XCTUnwrap(AppReleaseVersion(rawValue: "0.1.0"))
    let patch = try XCTUnwrap(AppReleaseVersion(rawValue: "v0.1.1"))
    let minor = try XCTUnwrap(AppReleaseVersion(rawValue: "0.2.0"))

    XCTAssertLessThan(current, patch)
    XCTAssertLessThan(patch, minor)
    XCTAssertEqual(patch.displayValue, "0.1.1")
    XCTAssertNil(AppReleaseVersion(rawValue: "0.2.0-alpha.1"))
    XCTAssertNil(AppReleaseVersion(rawValue: "0.2"))
    XCTAssertNil(AppReleaseVersion(rawValue: "0.2.latest"))
  }

  func testGitHubReleaseDecoderAcceptsOnlyOfficialStableReleaseURLs() throws {
    let validPayload = releasePayload(
      tag: "v0.2.0",
      url: "https://github.com/HuipengXu/SwitchGPT/releases/tag/v0.2.0"
    )
    let update = try GitHubLatestReleaseDecoder.decode(validPayload)

    XCTAssertEqual(update.version, AppReleaseVersion(rawValue: "0.2.0"))
    XCTAssertEqual(
      update.releaseURL.absoluteString,
      "https://github.com/HuipengXu/SwitchGPT/releases/tag/v0.2.0"
    )

    XCTAssertThrowsError(
      try GitHubLatestReleaseDecoder.decode(
        releasePayload(
          tag: "v0.2.0",
          url: "https://example.com/HuipengXu/SwitchGPT/releases/tag/v0.2.0"
        )
      )
    )
    XCTAssertThrowsError(
      try GitHubLatestReleaseDecoder.decode(
        releasePayload(
          tag: "v0.2.0",
          url: "https://github.com/HuipengXu/SwitchGPT/releases/tag/v0.3.0"
        )
      )
    )
    XCTAssertThrowsError(
      try GitHubLatestReleaseDecoder.decode(
        releasePayload(
          tag: "v0.2.0-alpha.1",
          url: "https://github.com/HuipengXu/SwitchGPT/releases/tag/v0.2.0-alpha.1",
          prerelease: true
        )
      )
    )
    XCTAssertThrowsError(
      try GitHubLatestReleaseDecoder.decode(
        releasePayload(
          tag: "v0.2.0",
          url: "https://github.com/HuipengXu/SwitchGPT/releases/tag/v0.2.0?redirect=1"
        )
      )
    )
  }

  @MainActor
  func testUpdateStoreShowsOnlyNewerStableVersionsAndCachesSuccessfulChecks() async throws {
    let update = try makeUpdate(version: "0.2.0")
    let fetcher = StubAppReleaseFetcher(update: update)
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var currentDate = Date(timeIntervalSince1970: 1_787_500_000)
    let store = AppUpdateStore(
      releaseFetcher: fetcher,
      currentVersion: try XCTUnwrap(AppReleaseVersion(rawValue: "0.1.0")),
      userDefaults: defaults,
      now: { currentDate }
    )

    await store.checkIfStale()
    await store.checkIfStale()

    XCTAssertEqual(store.availableUpdate, update)
    let firstCallCount = await fetcher.currentCallCount()
    XCTAssertEqual(firstCallCount, 1)

    currentDate.addTimeInterval(AppUpdateStore.automaticCheckInterval + 1)
    await store.checkIfStale()

    let secondCallCount = await fetcher.currentCallCount()
    XCTAssertEqual(secondCallCount, 2)
  }

  @MainActor
  func testFreshStoreRestoresCachedUpdateWithoutAnotherNetworkCheck() async throws {
    let update = try makeUpdate(version: "0.2.0")
    let fetcher = StubAppReleaseFetcher(update: update)
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let currentVersion = try XCTUnwrap(AppReleaseVersion(rawValue: "0.1.0"))

    let firstStore = AppUpdateStore(
      releaseFetcher: fetcher,
      currentVersion: currentVersion,
      userDefaults: defaults
    )
    await firstStore.checkIfStale()

    let relaunchedStore = AppUpdateStore(
      releaseFetcher: fetcher,
      currentVersion: currentVersion,
      userDefaults: defaults
    )
    await relaunchedStore.checkIfStale()

    XCTAssertEqual(relaunchedStore.availableUpdate, update)
    let callCount = await fetcher.currentCallCount()
    XCTAssertEqual(callCount, 1)
  }

  @MainActor
  func testUpdateStoreSnoozesOneVersionButShowsANewerVersionImmediately() async throws {
    let firstUpdate = try makeUpdate(version: "0.2.0")
    let secondUpdate = try makeUpdate(version: "0.2.1")
    let fetcher = StubAppReleaseFetcher(update: firstUpdate)
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let currentDate = Date(timeIntervalSince1970: 1_787_500_000)
    let store = AppUpdateStore(
      releaseFetcher: fetcher,
      currentVersion: try XCTUnwrap(AppReleaseVersion(rawValue: "0.1.0")),
      userDefaults: defaults,
      now: { currentDate }
    )

    await store.checkNow()
    store.snoozeAvailableUpdate()
    await store.checkNow()

    XCTAssertNil(store.availableUpdate)

    await fetcher.setUpdate(secondUpdate)
    await store.checkNow()

    XCTAssertEqual(store.availableUpdate, secondUpdate)
  }

  @MainActor
  func testUpdateStoreShowsSnoozedVersionAgainAfterSevenDays() async throws {
    let update = try makeUpdate(version: "0.2.0")
    let fetcher = StubAppReleaseFetcher(update: update)
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var currentDate = Date(timeIntervalSince1970: 1_787_500_000)
    let store = AppUpdateStore(
      releaseFetcher: fetcher,
      currentVersion: try XCTUnwrap(AppReleaseVersion(rawValue: "0.1.0")),
      userDefaults: defaults,
      now: { currentDate }
    )

    await store.checkNow()
    store.snoozeAvailableUpdate()
    currentDate.addTimeInterval(AppUpdateStore.snoozeInterval + 1)
    await store.checkNow()

    XCTAssertEqual(store.availableUpdate, update)
  }

  @MainActor
  func testUpdateStoreDoesNotShowCurrentOrOlderRelease() async throws {
    let fetcher = StubAppReleaseFetcher(update: try makeUpdate(version: "0.1.0"))
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AppUpdateStore(
      releaseFetcher: fetcher,
      currentVersion: try XCTUnwrap(AppReleaseVersion(rawValue: "0.1.0")),
      userDefaults: defaults
    )

    await store.checkNow()

    XCTAssertNil(store.availableUpdate)
  }

  @MainActor
  func testNoStableReleaseIsCachedWithoutShowingAReminder() async throws {
    let fetcher = StubAppReleaseFetcher(update: nil)
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AppUpdateStore(
      releaseFetcher: fetcher,
      currentVersion: try XCTUnwrap(AppReleaseVersion(rawValue: "0.1.0")),
      userDefaults: defaults
    )

    await store.checkIfStale()
    await store.checkIfStale()

    XCTAssertNil(store.availableUpdate)
    let callCount = await fetcher.currentCallCount()
    XCTAssertEqual(callCount, 1)
  }

  @MainActor
  func testManualUpdateCheckOverridesSnoozeAndReportsUpdate() async throws {
    let update = try makeUpdate(version: "0.2.0")
    let fetcher = StubAppReleaseFetcher(update: update)
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AppUpdateStore(
      releaseFetcher: fetcher,
      currentVersion: try XCTUnwrap(AppReleaseVersion(rawValue: "0.1.0")),
      userDefaults: defaults
    )

    await store.checkNow()
    store.snoozeAvailableUpdate()
    await store.checkManually()

    XCTAssertEqual(store.availableUpdate, update)
    XCTAssertEqual(store.manualCheckNotice?.result, .updateAvailable(update))
  }

  @MainActor
  func testManualUpdateCheckReportsUpToDate() async throws {
    let fetcher = StubAppReleaseFetcher(update: try makeUpdate(version: "0.2.0"))
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AppUpdateStore(
      releaseFetcher: fetcher,
      currentVersion: try XCTUnwrap(AppReleaseVersion(rawValue: "0.2.0")),
      userDefaults: defaults
    )

    await store.checkManually()

    XCTAssertEqual(store.manualCheckNotice?.result, .upToDate)
  }

  @MainActor
  func testManualUpdateCheckReportsFailure() async throws {
    let fetcher = StubAppReleaseFetcher(update: nil, shouldFail: true)
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AppUpdateStore(
      releaseFetcher: fetcher,
      currentVersion: try XCTUnwrap(AppReleaseVersion(rawValue: "0.2.0")),
      userDefaults: defaults
    )

    await store.checkManually()

    XCTAssertEqual(store.manualCheckNotice?.result, .failed)
  }

  private func releasePayload(
    tag: String,
    url: String,
    draft: Bool = false,
    prerelease: Bool = false
  ) -> Data {
    """
    {
      "tag_name": "\(tag)",
      "html_url": "\(url)",
      "draft": \(draft),
      "prerelease": \(prerelease)
    }
    """.data(using: .utf8)!
  }

  private func makeUpdate(version: String) throws -> AppUpdateInfo {
    let parsedVersion = try XCTUnwrap(AppReleaseVersion(rawValue: version))
    let url = try XCTUnwrap(
      URL(string: "https://github.com/HuipengXu/SwitchGPT/releases/tag/v\(version)")
    )
    return try XCTUnwrap(AppUpdateInfo(version: parsedVersion, releaseURL: url))
  }

  private func makeDefaults() -> (UserDefaults, String) {
    let suiteName = "SwitchGPT-AppUpdateTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
  }
}

private actor StubAppReleaseFetcher: AppReleaseFetching {
  private var update: AppUpdateInfo?
  private let shouldFail: Bool
  private(set) var callCount = 0

  init(update: AppUpdateInfo?, shouldFail: Bool = false) {
    self.update = update
    self.shouldFail = shouldFail
  }

  func fetchLatestRelease() async throws -> AppUpdateInfo? {
    callCount += 1
    if shouldFail {
      throw StubAppReleaseError.failed
    }
    return update
  }

  func setUpdate(_ update: AppUpdateInfo?) {
    self.update = update
  }

  func currentCallCount() -> Int {
    callCount
  }
}

private enum StubAppReleaseError: Error {
  case failed
}
